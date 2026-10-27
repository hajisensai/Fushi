// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: the small RWKV network ("w64", JSchoreels/anki-rwkv release
//! `small-model-sm56-2026-10-24`, package sm56; same architecture as
//! sm40v2) and its batched replay / query engine.
//!
//! The executable spec is the package's NumPy reference
//! (`reference/small_model_recurrent.py`, `RecurrentModel.step`) and
//! INTEGRATION.md §7–§9; comments below name the reference's variables.
//!
//! Engine: rows are processed a chunk at a time, one step of the 13-step
//! interleaved layer schedule after the other over every row of the chunk.
//! Within a step all per-row maths (norms, lerps, projections) is
//! independent across rows; only the WKV recurrence is sequential, and only
//! per entity (card, deck, note, preset, user), so entities run in parallel.
//! A row either commits (an answered review) or not (a query); the result is
//! exactly the one-row-at-a-time reference: a row reads the states left by
//! the committed rows before it, and a committed card/note state is rounded
//! to its storage precision before the next row reads it.

use std::collections::HashMap;
use std::io;

use half::f16;
use rayon::prelude::*;

use super::super::{add_scaled_in_place, dot_product, sigmoid, StatePrecision, CARD_FEATURES};
use super::super::slots::SlotStore;
use super::weights::Weights;

pub(super) const D: usize = 64;
const HEADS: usize = 4;
const K: usize = D / HEADS;
const MATRIX: usize = HEADS * K * K;
const FC: usize = 128;
pub(super) const STREAMS: usize = 5;
/// `zero_features`: the card-state input (scaled revlog type) is ignored.
const ZERO_FEATURE: usize = 22;
const LAYER_NORM_EPS: f32 = 1e-5;
const GROUP_NORM_EPS: f32 = 6.4e-4;
const NORMALIZE_EPS: f32 = 1e-12;
const MAX_LORA_RANK: usize = 16;
const MAX_CHANNEL_HIDDEN: usize = 256;
const SOFTPLUS_THRESHOLD: f32 = 20.0;
pub(super) const PROB_CLAMP: f32 = 1e-5;
/// Card and note streams: the ones kept at the runtime's state precision
/// (deck, preset and user states are few and stay f32).
pub(super) const COMPACT_STREAMS: [usize; 2] = [0, 2];

type V = [f32; D];
type HeadV = [f32; K];

/// Rows per block of the per-row maths: each weight column is streamed once
/// per block (`Linear::apply_rows`), and a block's scratch stays in L1/L2.
const BLOCK: usize = 32;

/// Per-task scratch of the block maths, on the heap: rayon threads run
/// stolen tasks on top of a waiting one, so big stack frames nest and
/// overflow.
struct Scratch {
    mix: Vec<f32>,
    r: Vec<f32>,
    k: Vec<f32>,
    v: Vec<f32>,
    a: Vec<f32>,
    g: Vec<f32>,
    tmp: Vec<f32>,
    out: Vec<f32>,
    delta: Vec<f32>,
    k_scale: Vec<f32>,
    v_scale: Vec<f32>,
    lora: Vec<f32>,
    features: Vec<f32>,
    hidden: Vec<f32>,
    normed: Vec<f32>,
    wide: Vec<f32>,
    gathered: Vec<V>,
}

impl Scratch {
    fn new() -> Self {
        let rows = |width: usize| vec![0.0f32; BLOCK * width];
        Self {
            mix: rows(8 * D),
            r: rows(D),
            k: rows(D),
            v: rows(D),
            a: rows(D),
            g: rows(D),
            tmp: rows(D),
            out: rows(D),
            delta: rows(D),
            k_scale: rows(HEADS),
            v_scale: rows(HEADS),
            lora: rows(MAX_LORA_RANK),
            features: rows(CARD_FEATURES),
            hidden: rows(FC),
            normed: rows(FC),
            wide: rows(MAX_CHANNEL_HIDDEN),
            gathered: vec![[0.0; D]; BLOCK],
        }
    }
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

struct Linear {
    output: usize,
    input: usize,
    /// `[output, input]`, row-major (PyTorch layout): `y = W x + b`.
    weight: Vec<f32>,
    /// The same, `[input, output]`: one column per input for [Self::apply_rows].
    weight_by_input: Vec<f32>,
    bias: Option<Vec<f32>>,
}

impl Linear {
    fn load(w: &mut Weights, name: &str, output: usize, input: usize, bias: bool) -> io::Result<Self> {
        let weight = w.matrix(&format!("{name}.weight"), output, input)?;
        let bias_name = format!("{name}.bias");
        let bias = if bias || w.contains(&bias_name) {
            Some(w.take(&bias_name, output)?)
        } else {
            None
        };
        Ok(Self::new(output, input, weight, bias))
    }

    fn new(output: usize, input: usize, weight: Vec<f32>, bias: Option<Vec<f32>>) -> Self {
        let mut weight_by_input = vec![0.0; weight.len()];
        for o in 0..output {
            for i in 0..input {
                weight_by_input[i * output + o] = weight[o * input + i];
            }
        }
        Self {
            output,
            input,
            weight,
            weight_by_input,
            bias,
        }
    }

    /// A low-rank matrix whose rank is read from the file.
    fn load_rank(w: &mut Weights, name: &str, output: usize, input: usize, rows: bool) -> io::Result<Self> {
        let shape = w
            .shape(&format!("{name}.weight"))
            .ok_or_else(|| invalid(format!("missing weight: {name}.weight")))?
            .to_vec();
        let rank = if rows { shape.first() } else { shape.get(1) }.copied().unwrap_or(0);
        if rank == 0 || rank > MAX_LORA_RANK || shape.len() != 2 {
            return Err(invalid(format!("weight {name} has shape {shape:?}")));
        }
        let (output, input) = if rows { (rank, input) } else { (output, rank) };
        Self::load(w, name, output, input, false)
    }

    #[inline]
    fn apply(&self, x: &[f32], y: &mut [f32]) {
        debug_assert_eq!(x.len(), self.input);
        debug_assert_eq!(y.len(), self.output);
        for (o, out) in y.iter_mut().enumerate() {
            let value = dot_product(x, &self.weight[o * self.input..(o + 1) * self.input]);
            *out = match &self.bias {
                Some(bias) => value + bias[o],
                None => value,
            };
        }
    }

    /// `rows * input` -> `rows * output`. Wide outputs stream each weight
    /// column once per block of rows (SIMD axpy, the fork's batched layout);
    /// narrow ones (LoRA ranks, per-head scales) take a dot product per row.
    fn apply_rows(&self, xs: &[f32], ys: &mut [f32]) {
        let rows = xs.len() / self.input;
        debug_assert_eq!(xs.len(), rows * self.input);
        debug_assert_eq!(ys.len(), rows * self.output);
        if self.output < 16 {
            for (x, y) in xs.chunks_exact(self.input).zip(ys.chunks_exact_mut(self.output)) {
                self.apply(x, y);
            }
            return;
        }
        for y in ys.chunks_exact_mut(self.output) {
            match &self.bias {
                Some(bias) => y.copy_from_slice(bias),
                None => y.fill(0.0),
            }
        }
        for (column, weights) in self.weight_by_input.chunks_exact(self.output).enumerate() {
            for (x, y) in xs.chunks_exact(self.input).zip(ys.chunks_exact_mut(self.output)) {
                let scale = x[column];
                if scale != 0.0 {
                    add_scaled_in_place(y, weights, scale);
                }
            }
        }
    }
}

struct Norm {
    weight: Vec<f32>,
    bias: Vec<f32>,
    eps: f32,
    /// Values per group (the whole vector for a LayerNorm).
    group: usize,
}

impl Norm {
    fn load(w: &mut Weights, name: &str, dim: usize, eps: f32, group: usize) -> io::Result<Self> {
        Ok(Self {
            weight: w.take(&format!("{name}.weight"), dim)?,
            bias: w.take(&format!("{name}.bias"), dim)?,
            eps,
            group,
        })
    }

    #[inline]
    fn apply(&self, x: &[f32], y: &mut [f32]) {
        for (start, (xs, ys)) in x
            .chunks_exact(self.group)
            .zip(y.chunks_exact_mut(self.group))
            .enumerate()
        {
            let n = self.group as f32;
            let mean = xs.iter().sum::<f32>() / n;
            let var = xs.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / n;
            let inv = 1.0 / (var + self.eps).sqrt();
            let offset = start * self.group;
            for (j, (x, y)) in xs.iter().zip(ys.iter_mut()).enumerate() {
                *y = (x - mean) * inv * self.weight[offset + j] + self.bias[offset + j];
            }
        }
    }
}

struct TimeMixer {
    norm: Norm,
    /// `rkvdag_lerp`: mix weights for r, k, v, d, a, g, k_scale, v_scale.
    lerp: Vec<f32>,
    bonus: Vec<f32>,
    w_r: Linear,
    w_k: Linear,
    w_v: Linear,
    w_o: Linear,
    k_scale: Linear,
    v_scale: Linear,
    /// `v_lora_simple` (layer 0 has none: its v becomes the stream's v0).
    v_lora: Option<(Linear, Linear)>,
    a_lora: (Linear, Linear),
    d_lora: (Linear, Linear),
    g_lora: (Linear, Linear),
    group_norm: Norm,
}

impl TimeMixer {
    fn load(w: &mut Weights, p: &str, layer: usize) -> io::Result<Self> {
        let lora = |w: &mut Weights, a: &str, b: &str| -> io::Result<(Linear, Linear)> {
            let first = Linear::load_rank(w, &format!("{p}.{a}"), 0, D, true)?;
            let rank = first.output;
            let second = Linear::load(w, &format!("{p}.{b}"), D, rank, false)?;
            Ok((first, second))
        };
        Ok(Self {
            norm: Norm::load(w, &format!("{p}.layer_norm"), D, LAYER_NORM_EPS, D)?,
            lerp: w.take(&format!("{p}.rkvdag_lerp"), 8 * D)?,
            bonus: w.take(&format!("{p}.bonus"), D)?,
            w_r: Linear::load(w, &format!("{p}.W_r"), D, D, false)?,
            w_k: Linear::load(w, &format!("{p}.W_k"), D, D, false)?,
            w_v: Linear::load(w, &format!("{p}.W_v"), D, D, false)?,
            w_o: Linear::load(w, &format!("{p}.W_o"), D, D, false)?,
            k_scale: Linear::load(w, &format!("{p}.k_scale_linear"), HEADS, D, true)?,
            v_scale: Linear::load(w, &format!("{p}.v_scale_linear"), HEADS, D, true)?,
            v_lora: if layer == 0 {
                None
            } else {
                Some(lora(w, "v_lora_simple.A", "v_lora_simple.B_and_lamb")?)
            },
            a_lora: lora(w, "a_lora_simple.A", "a_lora_simple.B_and_lamb")?,
            d_lora: lora(w, "d_lora_mlp.A", "d_lora_mlp.B_and_lamb")?,
            g_lora: lora(w, "lora_A_g", "lora_B_g")?,
            group_norm: Norm::load(w, &format!("{p}.out_group_norm"), D, GROUP_NORM_EPS, K)?,
        })
    }

    /// Everything of the time mixer that does not need the recurrent
    /// matrix, for a block of rows. `v0` is the stream's layer-0 value of
    /// each row (written by layer 0, read by the later layers).
    fn prepare_rows(&self, xl: &[V], xs: &[V], v0: &mut [V], out: &mut [Prepared], scratch: &mut Scratch) {
        let n = xl.len();
        debug_assert!(n <= BLOCK);
        let Scratch {
            mix,
            r,
            k,
            v,
            a,
            g,
            tmp,
            k_scale,
            v_scale,
            lora,
            ..
        } = scratch;
        let rows = n * D;
        for j in 0..8 {
            let weights = &self.lerp[j * D..(j + 1) * D];
            let m = &mut mix[j * BLOCK * D..j * BLOCK * D + rows];
            for row in 0..n {
                for c in 0..D {
                    m[row * D + c] = torch_lerp(xl[row][c], xs[row][c], weights[c]);
                }
            }
        }
        let m = |j: usize| &mix[j * BLOCK * D..j * BLOCK * D + rows];
        self.w_r.apply_rows(m(0), &mut r[..rows]);
        self.w_k.apply_rows(m(1), &mut k[..rows]);
        self.w_v.apply_rows(m(2), &mut v[..rows]);
        self.k_scale.apply_rows(m(6), &mut k_scale[..n * HEADS]);
        self.v_scale.apply_rows(m(7), &mut v_scale[..n * HEADS]);
        match &self.v_lora {
            None => {
                for row in 0..n {
                    v0[row].copy_from_slice(&v[row * D..(row + 1) * D]);
                }
            }
            Some((first, second)) => {
                lora_rows(first, second, m(2), &mut tmp[..rows], Activation::None, lora);
                for row in 0..n {
                    for c in 0..D {
                        let i = row * D + c;
                        v[i] = torch_lerp(v[i], v0[row][c], sigmoid(tmp[i]));
                    }
                }
            }
        }
        lora_rows(&self.a_lora.0, &self.a_lora.1, m(4), &mut a[..rows], Activation::None, lora);
        lora_rows(&self.g_lora.0, &self.g_lora.1, m(5), &mut g[..rows], Activation::Sigmoid, lora);
        lora_rows(&self.d_lora.0, &self.d_lora.1, m(3), &mut tmp[..rows], Activation::Tanh, lora);
        for (row, p) in out.iter_mut().enumerate().take(n) {
            let at = row * D;
            p.r.copy_from_slice(&r[at..at + D]);
            p.g.copy_from_slice(&g[at..at + D]);
            for c in 0..D {
                p.a[c] = sigmoid(a[at + c]);
                let dd = -0.5 - softplus(-tmp[at + c]);
                p.w[c] = (-dd.exp()).exp();
            }
            for h in 0..HEADS {
                let range = h * K..(h + 1) * K;
                let src = at + h * K..at + (h + 1) * K;
                normalize_scaled(&k[src.clone()], sigmoid(k_scale[row * HEADS + h]), &mut p.kk[range.clone()]);
                normalize_scaled(&v[src], sigmoid(v_scale[row * HEADS + h]), &mut p.vv[range]);
            }
        }
    }

    /// `x + W_o(g * (GroupNorm(S_new r) + bonus))` for a block of rows;
    /// `wkv[row]` is `S_new r` of that row, head after head.
    fn finish_rows(&self, x: &mut [V], wkv: &[V], p: &[Prepared], scratch: &mut Scratch) {
        let n = x.len();
        let Scratch { out, delta, .. } = scratch;
        for row in 0..n {
            let out = &mut out[row * D..(row + 1) * D];
            self.group_norm.apply(&wkv[row], out);
            let p = &p[row];
            for h in 0..HEADS {
                let mut bonus = 0.0;
                for j in h * K..(h + 1) * K {
                    bonus += p.r[j] * self.bonus[j] * p.kk[j] * p.a[j];
                }
                for i in h * K..(h + 1) * K {
                    out[i] = p.g[i] * (out[i] + bonus * p.vv[i]);
                }
            }
        }
        self.w_o.apply_rows(&out[..n * D], &mut delta[..n * D]);
        for (row, x) in x.iter_mut().enumerate() {
            for c in 0..D {
                x[c] += delta[row * D + c];
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Activation {
    None,
    Sigmoid,
    Tanh,
}

fn lora_rows(
    first: &Linear,
    second: &Linear,
    xs: &[f32],
    out: &mut [f32],
    between: Activation,
    hidden: &mut [f32],
) {
    let rows = xs.len() / first.input;
    let hidden = &mut hidden[..rows * first.output];
    first.apply_rows(xs, hidden);
    match between {
        Activation::None => {}
        Activation::Sigmoid => hidden.iter_mut().for_each(|h| *h = sigmoid(*h)),
        Activation::Tanh => hidden.iter_mut().for_each(|h| *h = h.tanh()),
    }
    second.apply_rows(hidden, out);
}

/// `torch.lerp`'s two-branch formula (the reference's `_lerp`).
#[inline]
fn torch_lerp(start: f32, end: f32, weight: f32) -> f32 {
    if weight.abs() < 0.5 {
        start + weight * (end - start)
    } else {
        end - (end - start) * (1.0 - weight)
    }
}

#[inline]
fn softplus(x: f32) -> f32 {
    if x > SOFTPLUS_THRESHOLD {
        x
    } else {
        x.exp().ln_1p()
    }
}

/// `scale * x / max(|x|, 1e-12)` over one head.
fn normalize_scaled(x: &[f32], scale: f32, out: &mut [f32]) {
    let norm = x.iter().map(|v| v * v).sum::<f32>().sqrt().max(NORMALIZE_EPS);
    for (o, v) in out.iter_mut().zip(x) {
        *o = scale * (v / norm);
    }
}

struct ChannelMixer {
    norm: Norm,
    lerp: Vec<f32>,
    w_k: Linear,
    w_v: Linear,
}

impl ChannelMixer {
    /// `None` for a stripped layer (its tensors are 1-element dummies).
    fn load(w: &mut Weights, p: &str) -> io::Result<Option<Self>> {
        let shape = w
            .shape(&format!("{p}.W_k.weight"))
            .ok_or_else(|| invalid(format!("missing weight: {p}.W_k.weight")))?
            .to_vec();
        if shape == [1, 1] {
            return Ok(None);
        }
        let hidden = shape[0];
        if hidden > MAX_CHANNEL_HIDDEN {
            return Err(invalid(format!("{p}.W_k is wider than {MAX_CHANNEL_HIDDEN}")));
        }
        Ok(Some(Self {
            norm: Norm::load(w, &format!("{p}.layer_norm"), D, LAYER_NORM_EPS, D)?,
            lerp: w.take(&format!("{p}.lerp_k"), D)?,
            w_k: Linear::load(w, &format!("{p}.W_k"), hidden, D, false)?,
            w_v: Linear::load(w, &format!("{p}.W_v"), D, hidden, false)?,
        }))
    }

    fn apply_rows(&self, x: &mut [V], xl: &[V], xs: &[V], scratch: &mut Scratch) {
        let n = x.len();
        let hidden = self.w_k.output;
        let Scratch {
            tmp: mixed,
            wide: k,
            delta,
            ..
        } = scratch;
        for row in 0..n {
            for c in 0..D {
                mixed[row * D + c] = torch_lerp(xl[row][c], xs[row][c], self.lerp[c]);
            }
        }
        let k = &mut k[..n * hidden];
        self.w_k.apply_rows(&mixed[..n * D], k);
        k.iter_mut().for_each(|k| *k = k.max(0.0) * k.max(0.0));
        self.w_v.apply_rows(k, &mut delta[..n * D]);
        for (row, x) in x.iter_mut().enumerate() {
            for c in 0..D {
                x[c] += delta[row * D + c];
            }
        }
    }
}

struct Layer {
    time: TimeMixer,
    channel: Option<ChannelMixer>,
}

/// The heads of one row. `p_logits` always; the curve head only on request
/// (replay / R queries read the instant head; scheduling reads the curve of a
/// what-if answer, INTEGRATION.md §9.2).
#[derive(Clone, Copy, Debug, Default)]
pub struct SmallHeads {
    pub p_logits: [f32; 4],
    /// `w_logits`, `s_raw`, `d_raw` (3 each) of the power-curve mixture.
    pub curve: [f32; 9],
}

impl SmallHeads {
    /// `p_curve(t)`, INTEGRATION.md §9.1 (with the zero ahead residual,
    /// `sigmoid(logit + 1e-5)`): R `seconds` after this row's answer,
    /// non-increasing in `seconds` (clamped to >= 1).
    pub fn curve_retrievability(&self, seconds: f32) -> f32 {
        let w = &self.curve[0..3];
        let max = w.iter().copied().fold(f32::NEG_INFINITY, f32::max);
        let e = [(w[0] - max).exp(), (w[1] - max).exp(), (w[2] - max).exp()];
        let sum = e[0] + e[1] + e[2];
        let t = seconds.max(1.0);
        let mut r = 0.0f32;
        for (i, weight) in e.iter().enumerate() {
            let s = self.curve[3 + i].clamp(-25.0, 25.0).exp();
            let d = self.curve[6 + i].clamp(-25.0, 25.0).exp();
            r += weight / sum * (-d * (t / (1e-7 + s)).ln_1p()).exp();
        }
        let raw = 1e-5 + (1.0 - 2e-5) * r;
        let logit = (raw / (1.0 - raw)).ln() + 1e-5;
        1.0 / (1.0 + (-logit).exp())
    }

    /// `p_imm`: 1 - P(Again), clamped to [1e-5, 1 - 1e-5].
    pub fn retrievability(&self) -> f32 {
        let p = softmax4(&self.p_logits);
        (1.0 - p[0]).clamp(PROB_CLAMP, 1.0 - PROB_CLAMP)
    }

    pub fn rating_probabilities(&self) -> [f32; 4] {
        softmax4(&self.p_logits)
    }
}

fn softmax4(x: &[f32; 4]) -> [f32; 4] {
    let max = x.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let e = x.map(|v| (v - max).exp());
    let sum: f32 = e.iter().sum();
    e.map(|v| v / sum)
}

struct CurveHead {
    w0: Linear,
    norm: Norm,
    w4: Linear,
    gru: [Linear; 3],
}

pub struct SmallNet {
    features_0: Linear,
    features_norm: Norm,
    features_3: Linear,
    streams: Vec<Vec<Layer>>,
    /// `layer_steps`: (stream, layer) in execution order.
    steps: Vec<(usize, usize)>,
    prehead: Norm,
    head_p0: Linear,
    p_linear: Linear,
    curve: CurveHead,
}

impl SmallNet {
    /// True when the weight file has the small model's tensors (the big
    /// model's file has no power-curve head).
    pub(super) fn is_small(weights: &Weights) -> bool {
        weights.contains("gru_w_weight") && weights.shape("features2card.3.weight") == Some(&[D, FC][..])
    }

    pub(super) fn load(mut w: Weights) -> io::Result<Self> {
        let w = &mut w;
        let mut streams = Vec::with_capacity(STREAMS);
        for stream in 0..STREAMS {
            let mut layers = Vec::new();
            while w.contains(&format!("rwkv_modules.{stream}.blocks.{}.time_mixer.W_r.weight", layers.len())) {
                let layer = layers.len();
                let p = format!("rwkv_modules.{stream}.blocks.{layer}");
                layers.push(Layer {
                    time: TimeMixer::load(w, &format!("{p}.time_mixer"), layer)?,
                    channel: ChannelMixer::load(w, &format!("{p}.channel_mixer"))?,
                });
            }
            if layers.is_empty() {
                return Err(invalid(format!("small model stream {stream} has no layers")));
            }
            streams.push(layers);
        }
        // The "interleaved" schedule is layer-major: every stream's layer 0,
        // then every stream's layer 1, ... (architecture.json `layer_steps`).
        let depth = streams.iter().map(Vec::len).max().unwrap_or(0);
        let steps = (0..depth)
            .flat_map(|layer| {
                streams
                    .iter()
                    .enumerate()
                    .filter(move |(_, layers)| layer < layers.len())
                    .map(move |(stream, _)| (stream, layer))
            })
            .collect();
        let gru = |w: &mut Weights, name: &str| -> io::Result<Linear> {
            Ok(Linear::new(
                3,
                FC,
                w.matrix(&format!("gru_{name}_weight"), 3, FC)?,
                Some(w.take(&format!("gru_{name}_bias"), 3)?),
            ))
        };
        Ok(Self {
            features_0: Linear::load(w, "features2card.0", FC, CARD_FEATURES, true)?,
            features_norm: Norm::load(w, "features2card.2", FC, LAYER_NORM_EPS, FC)?,
            features_3: Linear::load(w, "features2card.3", D, FC, true)?,
            streams,
            steps,
            prehead: Norm::load(w, "prehead_norm", D, LAYER_NORM_EPS, D)?,
            head_p0: Linear::load(w, "head_p.0", FC, D, true)?,
            p_linear: Linear::load(w, "p_linear", 4, FC, true)?,
            curve: CurveHead {
                w0: Linear::load(w, "head_w.0", D, D, true)?,
                norm: Norm::load(w, "head_w.2", D, LAYER_NORM_EPS, D)?,
                w4: Linear::load(w, "head_w.4", FC, D, true)?,
                gru: [gru(w, "w")?, gru(w, "s")?, gru(w, "d")?],
            },
        })
    }

    pub(super) fn steps(&self) -> &[(usize, usize)] {
        &self.steps
    }

    pub(super) fn layout(&self, stream: usize, precision: StatePrecision) -> Layout {
        let shift = shift_bytes(precision);
        let matrix = matrix_bytes(precision);
        let mut layers = Vec::new();
        let mut offset = 0;
        for layer in &self.streams[stream] {
            let entry = LayerLayout {
                shift: offset,
                matrix: offset + shift,
                channel: layer.channel.as_ref().map(|_| offset + shift + matrix),
            };
            offset += shift + matrix + if layer.channel.is_some() { shift } else { 0 };
            layers.push(entry);
        }
        Layout {
            precision,
            layers,
            slot_len: offset,
        }
    }

    fn feature_mlp_rows(&self, features: &[f32], out: &mut [V], scratch: &mut Scratch) {
        let n = out.len();
        let Scratch {
            features: f,
            hidden,
            normed,
            tmp: x,
            ..
        } = scratch;
        f[..n * CARD_FEATURES].copy_from_slice(features);
        for row in 0..n {
            f[row * CARD_FEATURES + ZERO_FEATURE] = 0.0;
        }
        self.features_0.apply_rows(&f[..n * CARD_FEATURES], &mut hidden[..n * FC]);
        silu(&mut hidden[..n * FC]);
        for row in 0..n {
            self.features_norm.apply(&hidden[row * FC..(row + 1) * FC], &mut normed[row * FC..(row + 1) * FC]);
        }
        self.features_3.apply_rows(&normed[..n * FC], &mut x[..n * D]);
        silu(&mut x[..n * D]);
        for (row, out) in out.iter_mut().enumerate() {
            out.copy_from_slice(&x[row * D..(row + 1) * D]);
        }
    }

    fn heads(&self, x: &V, curve: bool) -> SmallHeads {
        let mut h = [0.0; D];
        self.prehead.apply(x, &mut h);
        let mut hidden = [0.0; FC];
        self.head_p0.apply(&h, &mut hidden);
        hidden.iter_mut().for_each(|v| *v = v.max(0.0));
        let mut heads = SmallHeads::default();
        self.p_linear.apply(&hidden, &mut heads.p_logits);
        if curve {
            let mut hw = [0.0; D];
            self.curve.w0.apply(&h, &mut hw);
            hw.iter_mut().for_each(|v| *v = v.max(0.0));
            let mut normed = [0.0; D];
            self.curve.norm.apply(&hw, &mut normed);
            let mut u = [0.0; FC];
            self.curve.w4.apply(&normed, &mut u);
            for (i, gru) in self.curve.gru.iter().enumerate() {
                gru.apply(&u, &mut heads.curve[3 * i..3 * i + 3]);
            }
        }
        heads
    }
}

fn silu(values: &mut [f32]) {
    values.iter_mut().for_each(|v| *v *= sigmoid(*v));
}

// ---------------------------------------------------------------------------
// State layout and codecs
// ---------------------------------------------------------------------------

/// Where each layer's parts sit in an entity's state bytes. Per layer:
/// time shift (64 values), WKV matrix (4 x 16 x 16), channel shift (64,
/// only for a layer with a channel mixer). f32: raw little-endian floats.
/// int8 / int4: shifts as float16, the matrix by rows of 16 as a float32
/// scale + 16 codes (8 or 4 bits, two's complement), as the fork's
/// `precision.rs` stores card and note states.
#[derive(Clone)]
pub(super) struct Layout {
    pub precision: StatePrecision,
    layers: Vec<LayerLayout>,
    pub slot_len: usize,
}

#[derive(Clone, Copy)]
struct LayerLayout {
    shift: usize,
    matrix: usize,
    channel: Option<usize>,
}

fn shift_bytes(precision: StatePrecision) -> usize {
    match precision {
        StatePrecision::F32 => D * 4,
        _ => D * 2,
    }
}

fn row_bytes(precision: StatePrecision) -> usize {
    match precision {
        StatePrecision::F32 => K * 4,
        StatePrecision::Int8 => 4 + K,
        StatePrecision::Int4 => 4 + K / 2,
    }
}

fn matrix_bytes(precision: StatePrecision) -> usize {
    MATRIX / K * row_bytes(precision)
}

fn limit(precision: StatePrecision) -> f32 {
    match precision {
        StatePrecision::Int8 => 127.0,
        StatePrecision::Int4 => 7.0,
        StatePrecision::F32 => unreachable!(),
    }
}

impl Layout {
    fn read_shift(&self, bytes: &[u8], at: usize, out: &mut V) {
        let bytes = &bytes[at..at + shift_bytes(self.precision)];
        match self.precision {
            StatePrecision::F32 => {
                for (o, b) in out.iter_mut().zip(bytes.chunks_exact(4)) {
                    *o = f32::from_le_bytes([b[0], b[1], b[2], b[3]]);
                }
            }
            _ => {
                for (o, b) in out.iter_mut().zip(bytes.chunks_exact(2)) {
                    *o = f16::from_bits(u16::from_le_bytes([b[0], b[1]])).to_f32();
                }
            }
        }
    }

    fn write_shift(&self, values: &V, bytes: &mut [u8], at: usize) {
        let bytes = &mut bytes[at..at + shift_bytes(self.precision)];
        match self.precision {
            StatePrecision::F32 => {
                for (v, b) in values.iter().zip(bytes.chunks_exact_mut(4)) {
                    b.copy_from_slice(&v.to_le_bytes());
                }
            }
            _ => {
                for (v, b) in values.iter().zip(bytes.chunks_exact_mut(2)) {
                    b.copy_from_slice(&f16::from_f32(*v).to_bits().to_le_bytes());
                }
            }
        }
    }

    /// The value a stored shift reads back as.
    fn round_shift(&self, values: &V) -> V {
        match self.precision {
            StatePrecision::F32 => *values,
            _ => values.map(|v| f16::from_f32(v).to_f32()),
        }
    }

    /// Bytes of `rows` stored matrix rows.
    fn rows_bytes(&self, rows: usize) -> usize {
        rows * row_bytes(self.precision)
    }

    /// Decodes stored matrix rows (`out.len() / K` of them).
    fn read_rows(&self, bytes: &[u8], out: &mut [f32]) {
        let row = row_bytes(self.precision);
        for (values, encoded) in out.chunks_exact_mut(K).zip(bytes.chunks_exact(row)) {
            match self.precision {
                StatePrecision::F32 => {
                    for (o, b) in values.iter_mut().zip(encoded.chunks_exact(4)) {
                        *o = f32::from_le_bytes([b[0], b[1], b[2], b[3]]);
                    }
                }
                StatePrecision::Int8 => {
                    let scale = f32::from_le_bytes(encoded[..4].try_into().unwrap());
                    for (o, &code) in values.iter_mut().zip(&encoded[4..]) {
                        *o = code as i8 as f32 * scale;
                    }
                }
                StatePrecision::Int4 => {
                    let scale = f32::from_le_bytes(encoded[..4].try_into().unwrap());
                    for (column, o) in values.iter_mut().enumerate() {
                        let nibble = (encoded[4 + column / 2] >> (4 * (column % 2))) & 15;
                        *o = (((nibble as i8) << 4) >> 4) as f32 * scale;
                    }
                }
            }
        }
    }

    /// Stores matrix rows and replaces them with what they read back as.
    /// Rows: `scale = max|row| / limit` (1 for an all-zero row),
    /// codes `round_half_even(v / scale)` clipped to ±limit.
    fn write_rows(&self, values: &mut [f32], bytes: &mut [u8]) {
        let row = row_bytes(self.precision);
        for (values, encoded) in values.chunks_exact_mut(K).zip(bytes.chunks_exact_mut(row)) {
            if self.precision == StatePrecision::F32 {
                for (v, b) in values.iter().zip(encoded.chunks_exact_mut(4)) {
                    b.copy_from_slice(&v.to_le_bytes());
                }
                continue;
            }
            let limit = limit(self.precision);
            let maximum = values.iter().fold(0.0f32, |m, v| m.max(v.abs()));
            let step = if maximum == 0.0 {
                1.0
            } else {
                (maximum / limit).max(f32::from_bits(1))
            };
            let mut codes = [0i8; K];
            for (code, v) in codes.iter_mut().zip(values.iter()) {
                *code = (*v / step).round_ties_even().clamp(-limit, limit) as i8;
            }
            // The scale is refitted to the codes by least squares, so the stored
            // row is the orthogonal projection of the exact row onto its codes:
            // never longer than the exact row. With the plain `max / limit`
            // scale, rounding lifts components between half a step and a step
            // to a full step (up to 2x) at every committed answer; the card
            // stream's first layer does not damp that, and on a 1.2M-review
            // history 101 heavily reviewed cards grew x1.06 per review under
            // int4 (0.25 -> 7,962 in 175 reviews, on the way to f32 overflow).
            let (dot, norm) = codes
                .iter()
                .zip(values.iter())
                .fold((0.0f32, 0.0f32), |(dot, norm), (&c, &v)| {
                    (dot + c as f32 * v, norm + (c as f32) * (c as f32))
                });
            let scale = if norm == 0.0 {
                1.0
            } else {
                (dot / norm).max(f32::from_bits(1))
            };
            encoded[..4].copy_from_slice(&scale.to_le_bytes());
            for (code, v) in codes.iter().zip(values.iter_mut()) {
                *v = *code as f32 * scale;
            }
            if self.precision == StatePrecision::Int8 {
                for (b, code) in encoded[4..].iter_mut().zip(codes) {
                    *b = code as u8;
                }
            } else {
                for (index, b) in encoded[4..].iter_mut().enumerate() {
                    *b = (codes[2 * index] as u8 & 15) | ((codes[2 * index + 1] as u8 & 15) << 4);
                }
            }
        }
    }

    /// Checks stored bytes before they are trusted (snapshots): finite
    /// shifts and values, positive finite scales, no code outside ±limit.
    pub(super) fn validate(&self, bytes: &[u8]) -> io::Result<()> {
        let damaged = || invalid("damaged small-model RWKV state");
        if bytes.len() != self.slot_len {
            return Err(damaged());
        }
        let row = row_bytes(self.precision);
        for layer in &self.layers {
            let mut shift = [0.0; D];
            for at in std::iter::once(layer.shift).chain(layer.channel) {
                self.read_shift(bytes, at, &mut shift);
                if shift.iter().any(|v| !v.is_finite()) {
                    return Err(damaged());
                }
            }
            let encoded = &bytes[layer.matrix..layer.matrix + matrix_bytes(self.precision)];
            for encoded in encoded.chunks_exact(row) {
                if self.precision != StatePrecision::F32 {
                    let scale = f32::from_le_bytes(encoded[..4].try_into().unwrap());
                    let bad_code = match self.precision {
                        StatePrecision::Int8 => encoded[4..].contains(&128),
                        _ => encoded[4..].iter().any(|b| b & 15 == 8 || b >> 4 == 8),
                    };
                    if !scale.is_finite() || scale <= 0.0 || bad_code {
                        return Err(damaged());
                    }
                }
            }
            let mut matrix = [0.0; MATRIX];
            self.read_rows(&bytes[layer.matrix..], &mut matrix);
            if matrix.iter().any(|v| !v.is_finite()) {
                return Err(damaged());
            }
        }
        Ok(())
    }

    /// Largest absolute WKV matrix value of each layer (diagnostics and the
    /// long-history stability tests).
    pub(super) fn matrix_peaks(&self, bytes: &[u8]) -> Vec<f32> {
        let mut matrix = [0.0; MATRIX];
        self.layers
            .iter()
            .map(|layer| {
                self.read_rows(&bytes[layer.matrix..], &mut matrix);
                matrix.iter().fold(0.0f32, |m, v| m.max(v.abs()))
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Rows of one engine call.
pub(super) struct Rows<'a> {
    /// `rows * 92` model inputs.
    pub features: &'a [f32],
    /// Entity key per stream (card, deck, note, preset, user).
    pub keys: &'a [[i64; STREAMS]],
    /// Answered review: its states are committed. Otherwise a query.
    pub commit: &'a [bool],
    /// Rows whose heads are wanted.
    pub heads: &'a [bool],
}

#[derive(Clone)]
struct Prepared {
    r: V,
    kk: V,
    vv: V,
    w: V,
    a: V,
    g: V,
}

impl Default for Prepared {
    fn default() -> Self {
        let zero = [0.0; D];
        Self {
            r: zero,
            kk: zero,
            vv: zero,
            w: zero,
            a: zero,
            g: zero,
        }
    }
}

const NONE: u32 = u32::MAX;

/// One stream's entities in this call.
struct StreamPlan {
    keys: Vec<i64>,
    /// Rows of each entity, concatenated in entity order; entity `e` owns
    /// `order[ranges[e]..ranges[e + 1]]`.
    order: Vec<u32>,
    ranges: Vec<usize>,
    /// Position of each row in `order`.
    position: Vec<u32>,
    entity_of_row: Vec<u32>,
    /// The last committed row of the same entity before this row.
    prev_commit: Vec<u32>,
    /// The entity had a state before this call.
    stored: Vec<bool>,
    /// The entity's last committed row in this call.
    last_commit: Vec<u32>,
    /// Working state bytes, `slot_len` per entity: what the store holds,
    /// updated at every committed row.
    state: Vec<u8>,
}

impl StreamPlan {
    fn build(stream: usize, rows: &Rows<'_>, store: &SlotStore) -> Self {
        let n = rows.keys.len();
        let mut entity_by_key: HashMap<i64, u32> = HashMap::new();
        let mut keys = Vec::new();
        let mut entity_of_row = Vec::with_capacity(n);
        let mut counts: Vec<usize> = Vec::new();
        for key in rows.keys.iter().map(|keys| keys[stream]) {
            let entity = *entity_by_key.entry(key).or_insert_with(|| {
                keys.push(key);
                counts.push(0);
                (keys.len() - 1) as u32
            });
            counts[entity as usize] += 1;
            entity_of_row.push(entity);
        }
        let mut ranges = Vec::with_capacity(keys.len() + 1);
        ranges.push(0);
        for count in &counts {
            ranges.push(ranges.last().unwrap() + count);
        }
        let mut fill = ranges[..keys.len()].to_vec();
        let mut order = vec![0u32; n];
        let mut position = vec![0u32; n];
        let mut prev_commit = vec![NONE; n];
        let mut last_commit = vec![NONE; keys.len()];
        for (row, &entity) in entity_of_row.iter().enumerate() {
            let e = entity as usize;
            order[fill[e]] = row as u32;
            position[row] = fill[e] as u32;
            fill[e] += 1;
            prev_commit[row] = last_commit[e];
            if rows.commit[row] {
                last_commit[e] = row as u32;
            }
        }
        let slot_len = store.slot_len();
        let mut state = vec![0u8; keys.len() * slot_len];
        let mut stored = vec![false; keys.len()];
        for (e, key) in keys.iter().enumerate() {
            if let Some(bytes) = store.get(*key) {
                state[e * slot_len..(e + 1) * slot_len].copy_from_slice(bytes);
                stored[e] = true;
            }
        }
        Self {
            keys,
            order,
            ranges,
            position,
            entity_of_row,
            prev_commit,
            stored,
            last_commit,
            state,
        }
    }

    /// The "previous token" every row of this step sees: the committed row
    /// before it (as stored), else the entity's stored shift, else its own.
    fn shifts(&self, layout: &Layout, at: usize, xl: &[V]) -> Vec<V> {
        let slot_len = layout.slot_len;
        (0..xl.len())
            .into_par_iter()
            .map(|row| {
                let prev = self.prev_commit[row];
                if prev != NONE {
                    layout.round_shift(&xl[prev as usize])
                } else {
                    let e = self.entity_of_row[row] as usize;
                    if self.stored[e] {
                        let mut shift = [0.0; D];
                        layout.read_shift(&self.state[e * slot_len..(e + 1) * slot_len], at, &mut shift);
                        shift
                    } else {
                        xl[row]
                    }
                }
            })
            .collect()
    }
}

/// Runs `rows` through the network. Committed rows update the states the
/// later rows of this call read; with `persist` they are also written back to
/// `stores` (without it, a what-if). The heads of rows with `heads[row]` are
/// returned (default elsewhere).
pub(super) fn run(
    net: &SmallNet,
    layouts: &[Layout; STREAMS],
    stores: &mut [SlotStore; STREAMS],
    rows: &Rows<'_>,
    curve: bool,
    persist: bool,
) -> Vec<SmallHeads> {
    let n = rows.keys.len();
    debug_assert_eq!(rows.features.len(), n * CARD_FEATURES);
    let mut x: Vec<V> = vec![[0.0; D]; n];
    x.par_chunks_mut(BLOCK)
        .enumerate()
        .for_each_init(Scratch::new, |scratch, (block, x)| {
            let start = block * BLOCK * CARD_FEATURES;
            net.feature_mlp_rows(&rows.features[start..start + x.len() * CARD_FEATURES], x, scratch)
        });

    let mut plans: Vec<StreamPlan> = (0..STREAMS)
        .into_par_iter()
        .map(|stream| StreamPlan::build(stream, rows, &stores[stream]))
        .collect();
    let mut v0: Vec<Vec<V>> = vec![vec![[0.0; D]; n]; STREAMS];
    let mut xl: Vec<V> = vec![[0.0; D]; n];
    let mut prepared: Vec<Prepared> = vec![Prepared::default(); n];
    // `S_new r` per head, rows in the stream plan's entity order.
    let mut wkv: Vec<Vec<HeadV>> = vec![vec![[0.0; K]; n]; HEADS];

    for &(stream, layer_id) in net.steps() {
        let layer = &net.streams[stream][layer_id];
        let layout = &layouts[stream];
        let at = layout.layers[layer_id];
        let plan = &mut plans[stream];

        // Time mixer, per block of rows.
        xl.par_iter_mut()
            .zip(&x)
            .for_each(|(xl, x)| layer.time.norm.apply(x, xl));
        let xs = plan.shifts(layout, at.shift, &xl);
        prepared
            .par_chunks_mut(BLOCK)
            .zip(v0[stream].par_chunks_mut(BLOCK))
            .zip(xl.par_chunks(BLOCK).zip(xs.par_chunks(BLOCK)))
            .for_each_init(Scratch::new, |scratch, ((p, v0), (xl, xs))| {
                layer.time.prepare_rows(xl, xs, v0, p, scratch)
            });

        // WKV recurrence: sequential per entity and head, parallel across them.
        scan(plan, layout, at, &prepared, rows.commit, &mut wkv);
        plan.store_shift(layout, at.shift, &xl);

        let position = &plan.position;
        x.par_chunks_mut(BLOCK)
            .zip(prepared.par_chunks(BLOCK))
            .enumerate()
            .for_each_init(Scratch::new, |scratch, (block, (x, p))| {
                let mut gathered = std::mem::take(&mut scratch.gathered);
                for (offset, out) in gathered.iter_mut().take(x.len()).enumerate() {
                    let pos = position[block * BLOCK + offset] as usize;
                    for (h, wkv) in wkv.iter().enumerate() {
                        out[h * K..(h + 1) * K].copy_from_slice(&wkv[pos]);
                    }
                }
                layer.time.finish_rows(x, &gathered[..x.len()], p, scratch);
                scratch.gathered = gathered;
            });

        // Channel mixer, per block of rows; its shift is committed like the
        // time shift.
        if let (Some(channel), Some(channel_at)) = (&layer.channel, at.channel) {
            xl.par_iter_mut()
                .zip(&x)
                .for_each(|(xl, x)| channel.norm.apply(x, xl));
            let xs = plan.shifts(layout, channel_at, &xl);
            x.par_chunks_mut(BLOCK)
                .zip(xl.par_chunks(BLOCK).zip(xs.par_chunks(BLOCK)))
                .for_each_init(Scratch::new, |scratch, (x, (xl, xs))| {
                    channel.apply_rows(x, xl, xs, scratch)
                });
            plan.store_shift(layout, channel_at, &xl);
        }
    }

    let heads: Vec<SmallHeads> = x
        .par_iter()
        .zip(rows.heads)
        .map(|(x, &wanted)| {
            if wanted {
                net.heads(x, curve)
            } else {
                SmallHeads::default()
            }
        })
        .collect();

    if !persist {
        return heads;
    }
    for (stream, plan) in plans.into_iter().enumerate() {
        let slot_len = layouts[stream].slot_len;
        let store = &mut stores[stream];
        for (e, key) in plan.keys.iter().enumerate() {
            if plan.last_commit[e] != NONE {
                store
                    .get_or_insert(*key)
                    .copy_from_slice(&plan.state[e * slot_len..(e + 1) * slot_len]);
            }
        }
    }
    heads
}

impl StreamPlan {
    /// After a step: each entity's stored shift is the (rounded) input of
    /// its last committed row. Rows of this call read earlier committed
    /// rows' shifts from `xl` directly ([Self::shifts]).
    fn store_shift(&mut self, layout: &Layout, at: usize, xl: &[V]) {
        let slot_len = layout.slot_len;
        self.state
            .par_chunks_mut(slot_len)
            .zip(self.last_commit.par_iter())
            .for_each(|(state, &row)| {
                if row != NONE {
                    layout.write_shift(&xl[row as usize], state, at);
                }
            });
    }
}

/// `S_new = S diag(w) - (S kk)(a kk)^T + vv (kk a)^T` and `out = S_new r`
/// per head, row after row of each entity. Heads are independent, so every
/// (entity, head) pair is its own sequential task: even the user stream (one
/// entity) runs on four threads. Committed rows store `S_new` rounded to the
/// stream's precision (the row's own output uses it unrounded).
fn scan(
    plan: &mut StreamPlan,
    layout: &Layout,
    at: LayerLayout,
    prepared: &[Prepared],
    commit: &[bool],
    wkv: &mut [Vec<HeadV>],
) {
    let slot_len = layout.slot_len;
    let head_bytes = layout.rows_bytes(K);
    let entities = plan.keys.len();
    // Each entity's matrix bytes, one slice per head.
    let mut matrices: Vec<&mut [u8]> = Vec::with_capacity(entities * HEADS);
    for slot in plan.state.chunks_mut(slot_len) {
        let matrix = &mut slot[at.matrix..at.matrix + HEADS * head_bytes];
        matrices.extend(matrix.chunks_mut(head_bytes));
    }
    // Each head's outputs, one slice per entity.
    let mut outputs: Vec<Vec<&mut [HeadV]>> = Vec::with_capacity(HEADS);
    for wkv in wkv.iter_mut() {
        let mut per_entity = Vec::with_capacity(entities);
        let mut rest = wkv.as_mut_slice();
        for e in 0..entities {
            let (head, tail) = rest.split_at_mut(plan.ranges[e + 1] - plan.ranges[e]);
            per_entity.push(head);
            rest = tail;
        }
        outputs.push(per_entity);
    }
    let mut tasks: Vec<(usize, usize, &mut [u8], &mut [HeadV])> = Vec::with_capacity(entities * HEADS);
    let mut outputs: Vec<_> = outputs.into_iter().map(Vec::into_iter).collect();
    for (index, matrix) in matrices.into_iter().enumerate() {
        let (e, h) = (index / HEADS, index % HEADS);
        tasks.push((e, h, matrix, outputs[h].next().unwrap()));
    }
    let order = &plan.order;
    let ranges = &plan.ranges;
    let stored = &plan.stored;
    tasks.into_par_iter().for_each(|(e, h, matrix, outputs)| {
        let mut s = [0.0f32; K * K];
        if stored[e] {
            layout.read_rows(matrix, &mut s);
        }
        let mut next = [0.0f32; K * K];
        for (out, &row) in outputs.iter_mut().zip(&order[ranges[e]..ranges[e + 1]]) {
            let row = row as usize;
            step_head(&s, &prepared[row], h, &mut next, out);
            if commit[row] {
                s = next;
                layout.write_rows(&mut s, matrix);
            }
        }
    });
}

#[inline]
fn step_head(s: &[f32; K * K], p: &Prepared, h: usize, next: &mut [f32; K * K], out: &mut HeadV) {
    let base = h * K;
    let kk: &[f32; K] = p.kk[base..base + K].try_into().unwrap();
    let w: &[f32; K] = p.w[base..base + K].try_into().unwrap();
    let r: &[f32; K] = p.r[base..base + K].try_into().unwrap();
    let mut kb = [0.0f32; K];
    for j in 0..K {
        kb[j] = kk[j] * p.a[base + j];
    }
    for i in 0..K {
        let row: &[f32; K] = s[i * K..(i + 1) * K].try_into().unwrap();
        let mut s_kk = 0.0f32;
        for j in 0..K {
            s_kk += row[j] * kk[j];
        }
        let vv = p.vv[base + i];
        let new: &mut [f32; K] = (&mut next[i * K..(i + 1) * K]).try_into().unwrap();
        let mut acc = 0.0f32;
        for j in 0..K {
            new[j] = row[j] * w[j] - s_kk * kb[j] + vv * kb[j];
            acc += new[j] * r[j];
        }
        out[i] = acc;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(precision: StatePrecision) -> Layout {
        Layout {
            precision,
            layers: Vec::new(),
            slot_len: 0,
        }
    }

    /// The stored row is never longer than the exact row (L2), for any row:
    /// quantization must not feed energy into the recurrent state (see
    /// `write_rows`). Rows mix a dominant value with small components just
    /// above half a step, the case max-scaled rounding lifted to a full step.
    #[test]
    fn quantization_never_lengthens_a_row() {
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed >> 11) as f32 / (1u64 << 53) as f32
        };
        for precision in [StatePrecision::Int8, StatePrecision::Int4] {
            let layout = layout(precision);
            let mut bytes = vec![0u8; layout.rows_bytes(1)];
            for case in 0..20_000 {
                let mut row = [0.0f32; K];
                let big = (next() - 0.5) * 10f32.powi((case % 7) as i32 - 3);
                for (j, v) in row.iter_mut().enumerate() {
                    *v = if j == case % K {
                        big
                    } else {
                        let step = big.abs() / limit(precision);
                        (0.5 + next()) * step * if next() < 0.5 { -1.0 } else { 1.0 }
                    };
                }
                let before: f32 = row.iter().map(|v| v * v).sum();
                let mut stored = row;
                layout.write_rows(&mut stored, &mut bytes);
                let after: f32 = stored.iter().map(|v| v * v).sum();
                assert!(
                    after <= before * (1.0 + 1e-5),
                    "{precision:?} case {case}: |q(x)|² {after} > |x|² {before} for {row:?}"
                );
                let mut decoded = [0.0f32; K];
                layout.read_rows(&bytes, &mut decoded);
                assert_eq!(decoded, stored, "{precision:?}: stored values read back differently");
            }
        }
    }
}
