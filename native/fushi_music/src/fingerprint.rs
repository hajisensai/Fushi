//! 声纹（chromaprint）+「短音频在长音轨上滑窗对齐」。
//!
//! 用途（设计：`docs/specs/2026-10-24-cross-media-links.md` §2、音乐方案 §8.3 第 1 条）：
//! - 动画 OP / ED：歌曲声纹在整集音轨声纹上对齐 → 这一集里 OP / ED 的起止；
//! - MV 偏移：本地音频声纹在 MV 视频音轨声纹上对齐 → MV 相对音频的偏移。
//!
//! 两件事是同一个比对，所以只有一组函数。**解码不在这里**：Dart 经统一 FFmpeg 后端把音轨
//! 解成 PCM（建议直接解成 [SAMPLE_RATE] 单声道 s16，免得 Rust 侧再重采样），一集一次
//! [ffm_fp_compute] 调用把整段 PCM 交过来；对齐是 [ffm_fp_align]，两段声纹各传一次指针。
//!
//! 声纹算法用 [rusty_chromaprint]（MIT，chromaprint 的纯 Rust 移植）的 `preset_test2`
//! （= chromaprint / AcoustID 默认配置）：每个声纹项是一个 32 位字，步进
//! [ITEM_HOP_SAMPLES] / [SAMPLE_RATE] ≈ 123.8 ms，覆盖从项起点开始的 [window_samples]
//! ≈ 2.72 s 音频（FFT 帧 + 色度滤波 + 分类器的 16 帧上下文）。
//!
//! 对齐（[align]）：对每个整项偏移 `o`（needle 项 k ↔ haystack 项 k+o）逐项比汉明距离；
//! 距离 ≤ [MATCH_BIT_ERRORS] 的项记作「命中」。随机 32 位字的汉明距离 ~ B(32, ½)，≤ 10 的
//! 概率约 2.5%；同一段音频（含有损重编码）通常 0–6。沿重叠区找「命中项之间的空档 ≤
//! [MAX_GAP_ITEMS]」的最长连续段，按段内命中数取全局最优偏移。整个比对是
//! O(len(needle) × len(haystack)) 次 popcount：90 s 歌 × 24 min 集约 840 万次，毫秒级。
//!
//! 精度（合成样本实测，见单测）：
//! - **偏移**是最准的量：整项量化，误差 ≤ 半项（≈ 62 ms）。MV 偏移直接用它。
//! - **段端点**分两种：命中段一直延伸到 needle 的端点（OP 从歌的第一拍开始 / 一直唱到最后）
//!   时，端点由偏移 + needle 的真实端点推出，误差同偏移；端点落在 needle 中间（TV size
//!   剪掉了后半首、MV 只截了一段）时，只能从「项命中与否」的翻转处估：一项覆盖 2.72 s，
//!   命中与否取决于窗内多数音频是不是歌，所以翻转发生在窗中点越过歌曲边界处，按
//!   [interior_boundary_ms] 换算，实测误差 ≲ 0.6 s。

use rusty_chromaprint::{Configuration, Fingerprinter};

use crate::{guard, hand_over_bytes, status};

/// 声纹内部采样率（chromaprint 固定值）。Dart 侧按这个采样率解码可以免掉 Rust 重采样。
pub const SAMPLE_RATE: u32 = 11025;

/// 每个声纹项的步进样本数（frame 4096、overlap 4096 − 4096/3）。
pub const ITEM_HOP_SAMPLES: u32 = 4096 / 3;

/// 汉明距离 ≤ 它的项算「命中」。
pub const MATCH_BIT_ERRORS: u32 = 10;

/// 命中段内允许的最长连续未命中项数（≈ 1 s）：歌曲上叠了台词 / 音效时个别项会失配，
/// 不能因此把一首 OP 劈成几段。
pub const MAX_GAP_ITEMS: usize = 8;

/// 命中段离 needle 端点不超过这么多项，就认为它延伸到了端点（有损重编码偶尔让最边上
/// 一两项失配）。必须远小于 [window_samples] 的项数（≈ 22 项）：再大就会把「歌从第 3 秒
/// 开始」的 TV 剪辑误吸附成「从第 0 秒开始」。
pub const EDGE_SNAP_ITEMS: usize = 2;

/// 声纹算法 / 对齐判据版本。Dart 侧缓存按它失效：改了常数或算法必须升。
pub const FINGERPRINT_VERSION: u32 = 1;

/// 一个声纹项的时长（毫秒，浮点）。
pub fn item_ms() -> f64 {
    f64::from(ITEM_HOP_SAMPLES) * 1000.0 / f64::from(SAMPLE_RATE)
}

/// 一个声纹项覆盖的音频样本数（= chromaprint 的 delay + 一个步进）。
pub fn window_samples() -> usize {
    Configuration::preset_test2().delay() + ITEM_HOP_SAMPLES as usize
}

fn window_ms() -> f64 {
    window_samples() as f64 * 1000.0 / f64::from(SAMPLE_RATE)
}

/// 端点落在 needle 中间时，「第 `first_hit` 项起命中」对应的 needle 时间：前一项（未命中）
/// 与这一项（命中）的窗中点的中点。段尾同理传「最后一个命中项 + 1」。
pub fn interior_boundary_ms(first_hit: usize) -> f64 {
    (first_hit as f64 - 0.5) * item_ms() + window_ms() / 2.0
}

/// 声纹计算失败原因。
#[derive(Debug, PartialEq, Eq)]
pub enum FingerprintError {
    /// 采样率过低（≤ 1000 Hz）或声道数为 0。
    BadFormat,
    /// 样本数不是声道数的整数倍。
    Misaligned,
}

/// 整段交错 s16 PCM → 声纹。
pub fn compute(pcm: &[i16], sample_rate: u32, channels: u32) -> Result<Vec<u32>, FingerprintError> {
    if channels == 0 || sample_rate <= 1000 {
        return Err(FingerprintError::BadFormat);
    }
    if !pcm.len().is_multiple_of(channels as usize) {
        return Err(FingerprintError::Misaligned);
    }
    let mut printer = Fingerprinter::new(&Configuration::preset_test2());
    printer
        .start(sample_rate, channels)
        .map_err(|_| FingerprintError::BadFormat)?;
    printer.consume(pcm);
    printer.finish();
    Ok(printer.fingerprint().to_vec())
}

/// 一次对齐的结果。needle 时间 t ↔ haystack 时间 `t + offset_ms`。
#[derive(Debug, Clone, PartialEq)]
pub struct Alignment {
    /// needle 时间 0 在 haystack 里的位置（毫秒，可负）。
    pub offset_ms: f64,
    /// 命中段在 needle 里的起止（毫秒）。
    pub needle_start_ms: f64,
    pub needle_end_ms: f64,
    /// 命中段起止是否延伸到了 needle 的端点（true = 端点由偏移推出，精度同偏移）。
    pub start_at_edge: bool,
    pub end_at_edge: bool,
    /// 命中段内的命中项数。
    pub matched_items: usize,
    /// 命中段长度（项，含段内未命中项）。
    pub run_items: usize,
    /// 命中段内平均汉明距离（0..32，随机 ≈ 16）。
    pub mean_bit_error: f64,
    /// 置信度 0..1：`(1 − 平均距离/16) × 命中率`，截到 [0, 1]。
    pub confidence: f64,
}

impl Alignment {
    pub fn haystack_start_ms(&self) -> f64 {
        self.offset_ms + self.needle_start_ms
    }

    pub fn haystack_end_ms(&self) -> f64 {
        self.offset_ms + self.needle_end_ms
    }
}

#[derive(Clone, Copy)]
struct Run {
    start: usize,
    end: usize,
    matched: usize,
    error_sum: u64,
}

/// 在一个偏移上，沿重叠区找最长的命中段（按命中数）。
fn best_run_at(needle: &[u32], haystack: &[u32], offset: i64) -> Option<Run> {
    let n = needle.len() as i64;
    let m = haystack.len() as i64;
    let k_begin = (-offset).max(0);
    let k_end = n.min(m - offset);
    if k_begin >= k_end {
        return None;
    }
    let mut best: Option<Run> = None;
    let mut cur: Option<Run> = None;
    let mut last_hit: usize = 0;
    for k in k_begin as usize..k_end as usize {
        let h = (k as i64 + offset) as usize;
        let err = (needle[k] ^ haystack[h]).count_ones();
        if err > MATCH_BIT_ERRORS {
            continue;
        }
        match cur.as_mut() {
            Some(run) if k - last_hit - 1 <= MAX_GAP_ITEMS => {
                // 空档里的未命中项也计进误差和：平均距离反映整段，而不只是命中项。
                let gap_h = (last_hit as i64 + 1 + offset) as usize;
                run.error_sum += needle[last_hit + 1..k]
                    .iter()
                    .zip(&haystack[gap_h..])
                    .map(|(a, b)| u64::from((a ^ b).count_ones()))
                    .sum::<u64>();
                run.end = k + 1;
                run.matched += 1;
                run.error_sum += u64::from(err);
            }
            _ => {
                if let Some(done) = cur.take() {
                    best = Some(pick(best, done));
                }
                cur = Some(Run {
                    start: k,
                    end: k + 1,
                    matched: 1,
                    error_sum: u64::from(err),
                });
            }
        }
        last_hit = k;
    }
    if let Some(done) = cur {
        best = Some(pick(best, done));
    }
    best
}

fn pick(best: Option<Run>, candidate: Run) -> Run {
    match best {
        Some(b) if !better(&candidate, &b) => b,
        _ => candidate,
    }
}

/// 命中数多者胜；相同时平均误差低者胜（交叉相乘比较，避免浮点）。
fn better(a: &Run, b: &Run) -> bool {
    if a.matched != b.matched {
        return a.matched > b.matched;
    }
    let a_len = (a.end - a.start) as u64;
    let b_len = (b.end - b.start) as u64;
    a.error_sum * b_len < b.error_sum * a_len
}

/// needle（短：歌曲 / 本地音频）在 haystack（长：整集 / MV 音轨）上的最佳对齐。
///
/// `min_matched_items`：命中数低于它视为「没出现」（返回 None）。传 0 按 1 处理。
pub fn align(needle: &[u32], haystack: &[u32], min_matched_items: usize) -> Option<Alignment> {
    if needle.is_empty() || haystack.is_empty() {
        return None;
    }
    let n = needle.len() as i64;
    let m = haystack.len() as i64;
    let mut best: Option<(i64, Run)> = None;
    for offset in -(n - 1)..m {
        if let Some(run) = best_run_at(needle, haystack, offset) {
            let replace = match &best {
                None => true,
                Some((_, b)) => better(&run, b),
            };
            if replace {
                best = Some((offset, run));
            }
        }
    }
    let (offset, run) = best?;
    if run.matched < min_matched_items.max(1) {
        return None;
    }
    let run_items = run.end - run.start;
    let mean = run.error_sum as f64 / run_items as f64;
    let hit_rate = run.matched as f64 / run_items as f64;
    let confidence = ((1.0 - mean / 16.0) * hit_rate).clamp(0.0, 1.0);

    let item = item_ms();
    // 重叠区（needle 项下标）：needle 在 haystack 外的部分不可能命中，也不能吸附过去。
    let overlap_begin = (-offset).max(0) as usize;
    let overlap_end = n.min(m - offset) as usize;
    let start_at_edge = run.start <= overlap_begin + EDGE_SNAP_ITEMS;
    let end_at_edge = run.end + EDGE_SNAP_ITEMS >= overlap_end;
    let needle_start_ms = if start_at_edge {
        overlap_begin as f64 * item
    } else {
        interior_boundary_ms(run.start)
    };
    // 最后一项覆盖到 (end − 1)·步进 + 窗长。
    let needle_end_ms = if end_at_edge {
        (overlap_end as f64 - 1.0) * item + window_ms()
    } else {
        interior_boundary_ms(run.end)
    };
    Some(Alignment {
        offset_ms: offset as f64 * item,
        needle_start_ms,
        needle_end_ms,
        start_at_edge,
        end_at_edge,
        matched_items: run.matched,
        run_items,
        mean_bit_error: mean,
        confidence,
    })
}

// ── C ABI ────────────────────────────────────────────────────────────────

/// [ffm_fp_align] 的输出。字段按对齐从大到小排，Dart `Struct` 同序声明即可。
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct FfmFpMatch {
    /// needle 时间 0 在 haystack 里的毫秒位置（可负）。MV 偏移就是它。
    pub offset_ms: i64,
    pub haystack_start_ms: i64,
    pub haystack_end_ms: i64,
    pub needle_start_ms: i64,
    pub needle_end_ms: i64,
    pub mean_bit_error: f64,
    pub confidence: f64,
    pub matched_items: u32,
    pub run_items: u32,
    /// 1 = 找到；0 = 没出现（其余字段全零）。
    pub found: u8,
    /// bit0 = 段首延伸到 needle 端点；bit1 = 段尾延伸到 needle 端点。
    pub edge_flags: u8,
}

/// 声纹算法版本（[FINGERPRINT_VERSION]）。
#[no_mangle]
pub extern "C" fn ffm_fp_version() -> u32 {
    FINGERPRINT_VERSION
}

/// 一个声纹项的时长（毫秒）。
#[no_mangle]
pub extern "C" fn ffm_fp_item_ms() -> f64 {
    item_ms()
}

/// 整段交错 s16 PCM（`sample_count` 个样本，含全部声道）→ 声纹，输出为小端 u32 数组的
/// 字节（长度 = 4 × 项数），用 `ffm_free_bytes` 释放。采样率 / 声道非法返回
/// [status::INVALID_ARGUMENT]。
///
/// # Safety
/// `pcm` 为空（且 `sample_count == 0`）或指向 `sample_count` 个 i16；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_fp_compute(
    pcm: *const i16,
    sample_count: usize,
    sample_rate: u32,
    channels: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() || (pcm.is_null() && sample_count != 0) {
            return status::NULL_ARGUMENT;
        }
        let samples: &[i16] = if sample_count == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(pcm, sample_count)
        };
        match compute(samples, sample_rate, channels) {
            Ok(fp) => {
                let mut bytes = Vec::with_capacity(fp.len() * 4);
                for word in fp {
                    bytes.extend_from_slice(&word.to_le_bytes());
                }
                hand_over_bytes(bytes, out_ptr, out_len);
                status::OK
            }
            Err(_) => status::INVALID_ARGUMENT,
        }
    })
}

/// needle 声纹在 haystack 声纹上对齐，结果写 `out`（没出现时 `found = 0`，返回 OK）。
///
/// # Safety
/// `needle` / `haystack` 各指向对应个数的 u32（个数为 0 时可空）；`out` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_fp_align(
    needle: *const u32,
    needle_len: usize,
    haystack: *const u32,
    haystack_len: usize,
    min_matched_items: u32,
    out: *mut FfmFpMatch,
) -> i32 {
    guard(|| {
        if out.is_null()
            || (needle.is_null() && needle_len != 0)
            || (haystack.is_null() && haystack_len != 0)
        {
            return status::NULL_ARGUMENT;
        }
        let n: &[u32] = if needle_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(needle, needle_len)
        };
        let h: &[u32] = if haystack_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(haystack, haystack_len)
        };
        *out = match align(n, h, min_matched_items as usize) {
            None => FfmFpMatch::default(),
            Some(a) => FfmFpMatch {
                offset_ms: a.offset_ms.round() as i64,
                haystack_start_ms: a.haystack_start_ms().round() as i64,
                haystack_end_ms: a.haystack_end_ms().round() as i64,
                needle_start_ms: a.needle_start_ms.round() as i64,
                needle_end_ms: a.needle_end_ms.round() as i64,
                mean_bit_error: a.mean_bit_error,
                confidence: a.confidence,
                matched_items: a.matched_items as u32,
                run_items: a.run_items as u32,
                found: 1,
                edge_flags: u8::from(a.start_at_edge) | (u8::from(a.end_at_edge) << 1),
            },
        };
        status::OK
    })
}

#[cfg(test)]
pub(crate) mod synth {
    //! 确定性合成样本（测试与回归向量共用）：LCG 选音高的和弦序列 + 低电平噪声。

    use super::SAMPLE_RATE;

    pub struct Lcg(pub u64);

    impl Lcg {
        pub fn next_u32(&mut self) -> u32 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (self.0 >> 33) as u32
        }
    }

    /// `seconds` 秒的「音乐」：每 `note_ms` 换一组三音和弦（音高由种子决定）。
    pub fn music(seed: u64, seconds: f64, note_ms: u32, amplitude: f64) -> Vec<i16> {
        let total = (seconds * f64::from(SAMPLE_RATE)) as usize;
        let per_note = (u64::from(note_ms) * u64::from(SAMPLE_RATE) / 1000) as usize;
        let mut rng = Lcg(seed);
        let mut out = Vec::with_capacity(total);
        let mut freqs = [0.0f64; 3];
        let mut phase = [0.0f64; 3];
        for i in 0..total {
            if i % per_note == 0 {
                for f in freqs.iter_mut() {
                    // 110 Hz × 2^(半音/12)，半音 0..36。
                    let semitone = rng.next_u32() % 37;
                    *f = 110.0 * 2f64.powf(f64::from(semitone) / 12.0);
                }
            }
            let mut v = 0.0;
            for (f, p) in freqs.iter().zip(phase.iter_mut()) {
                *p += 2.0 * std::f64::consts::PI * f / f64::from(SAMPLE_RATE);
                v += p.sin();
            }
            let noise = (f64::from(rng.next_u32() % 2001) - 1000.0) / 1000.0 * 0.02;
            out.push(((v / 3.0 + noise) * amplitude * 32767.0) as i16);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::synth::music;
    use super::*;
    use sha1::{Digest, Sha1};

    /// 端点延伸到 needle 端点时的容差：半项量化 + 1 ms 舍入。
    fn edge_tol() -> f64 {
        item_ms() / 2.0 + 1.0
    }

    /// 端点落在 needle 中间时的容差（见模块文档「精度」）。
    const INTERIOR_TOL_MS: f64 = 650.0;

    fn sec(s: f64) -> usize {
        (s * f64::from(SAMPLE_RATE)) as usize
    }

    /// 把 `song[from..to)` 覆盖进 `base` 的 `at` 秒处（模拟 OP 段只有歌）。
    fn splice(base: &mut [i16], song: &[i16], from: f64, to: f64, at: f64) {
        let piece = &song[sec(from)..sec(to)];
        base[sec(at)..sec(at) + piece.len()].copy_from_slice(piece);
    }

    fn fp(pcm: &[i16]) -> Vec<u32> {
        compute(pcm, SAMPLE_RATE, 1).unwrap()
    }

    #[test]
    fn item_duration_matches_chromaprint_hop() {
        assert_eq!(ITEM_HOP_SAMPLES, 1365);
        assert!((item_ms() - 123.809_523_8).abs() < 1e-6);
        // FFT 帧 4096 + 色度滤波 5 帧 + 分类器 16 帧 → 19 个步进 + 一帧。
        assert_eq!(window_samples(), 19 * 1365 + 4096);
    }

    #[test]
    fn rejects_bad_formats() {
        assert_eq!(compute(&[0; 10], 0, 1), Err(FingerprintError::BadFormat));
        assert_eq!(
            compute(&[0; 10], 11025, 0),
            Err(FingerprintError::BadFormat)
        );
        assert_eq!(
            compute(&[0; 3], 11025, 2),
            Err(FingerprintError::Misaligned)
        );
    }

    /// 回归向量：固定合成输入 → 声纹长度 + 前 4 项 + 全体 SHA-1。换 crate 版本 / 改配置
    /// 让这里变了，就必须升 [FINGERPRINT_VERSION]（Dart 侧缓存按它失效）。
    #[test]
    fn fingerprint_regression_vector() {
        let fp = fp(&music(0x5eed_0001, 12.0, 400, 0.6));
        let mut hasher = Sha1::new();
        for w in &fp {
            hasher.update(w.to_le_bytes());
        }
        let digest: String = hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let head: Vec<String> = fp.iter().take(4).map(|w| format!("{w:08x}")).collect();
        assert_eq!(
            (fp.len(), head.join(",").as_str(), digest.as_str()),
            (
                75,
                "a00662a8,a0c632a8,a08602a9,a19c02aa",
                "7e6f806305369bc930039ce739e58845f0267067"
            ),
            "fingerprint changed: bump FINGERPRINT_VERSION and refresh the golden"
        );
    }

    /// 对齐回归向量：(歌曲片段 from..to 秒, 插入位置 at 秒) → 期望的 haystack 起止，
    /// 以及端点是否延伸到 needle 端点。覆盖整首、开头被剪、结尾被剪、两头都剪、
    /// 插在整集开头。
    #[test]
    fn alignment_regression_vectors() {
        // (种子, from, to, at)
        let cases: [(u64, f64, f64, f64); 7] = [
            (1, 0.0, 30.0, 47.3),
            (2, 5.0, 30.0, 20.0),
            (3, 0.0, 17.0, 33.3),
            (4, 3.3, 21.7, 12.1),
            (5, 0.0, 30.0, 0.0),
            (6, 7.7, 30.0, 40.0),
            (7, 0.0, 12.9, 50.0),
        ];
        for (seed, from, to, at) in cases {
            let song = music(seed, 30.0, 350, 0.5);
            let mut episode = music(seed + 100, 90.0, 500, 0.5);
            splice(&mut episode, &song, from, to, at);
            let a = align(&fp(&song), &fp(&episode), 40)
                .unwrap_or_else(|| panic!("case {seed}: song must be found"));
            let case = format!("case {seed} {a:?}");
            assert!(
                (a.offset_ms - (at - from) * 1000.0).abs() <= edge_tol(),
                "offset {case}"
            );
            assert_eq!(a.start_at_edge, from == 0.0, "start edge {case}");
            assert_eq!(a.end_at_edge, to == 30.0, "end edge {case}");
            let start_tol = if a.start_at_edge {
                edge_tol()
            } else {
                INTERIOR_TOL_MS
            };
            let end_tol = if a.end_at_edge {
                edge_tol()
            } else {
                INTERIOR_TOL_MS
            };
            assert!(
                (a.haystack_start_ms() - at * 1000.0).abs() <= start_tol,
                "start {case}"
            );
            assert!(
                (a.haystack_end_ms() - (at + to - from) * 1000.0).abs() <= end_tol,
                "end {case}"
            );
            assert!(a.confidence > 0.6, "confidence {case}");
        }
    }

    /// 歌不在里面：不报命中。
    #[test]
    fn absent_song_is_not_found() {
        let song = music(0xA11CE, 30.0, 350, 0.5);
        let episode = music(0xB0B, 120.0, 500, 0.5);
        assert_eq!(align(&fp(&song), &fp(&episode), 40), None);
    }

    /// 歌上叠了一段对白（另一套合成信号、电平一半）：仍找得到，起点不变。
    #[test]
    fn survives_overlaid_dialogue() {
        let song = music(0x1234, 30.0, 350, 0.5);
        let mut episode = music(0x5678, 100.0, 500, 0.5);
        splice(&mut episode, &song, 0.0, 30.0, 20.0);
        let talk = music(0x9999, 4.0, 120, 0.25);
        let at = sec(30.0);
        for (i, s) in talk.iter().enumerate() {
            episode[at + i] = episode[at + i].saturating_add(*s);
        }
        let a = align(&fp(&song), &fp(&episode), 40).expect("song must still be found");
        assert!(
            (a.haystack_start_ms() - 20_000.0).abs() <= edge_tol(),
            "{a:?}"
        );
        assert!(
            (a.haystack_end_ms() - 50_000.0).abs() <= edge_tol(),
            "{a:?}"
        );
    }

    /// MV：视频音轨 = 8 s 前奏剧情 + 整首歌；偏移 = +8 s。
    #[test]
    fn mv_offset_is_intro_length() {
        let song = music(0x4D56, 25.0, 300, 0.5);
        let mut mv = music(0x1A7, 8.0, 600, 0.4);
        mv.extend_from_slice(&song);
        let a = align(&fp(&song), &fp(&mv), 40).expect("mv must match");
        assert!((a.offset_ms - 8_000.0).abs() <= edge_tol(), "{a:?}");
    }

    /// MV 比音频先结束 / 音频比 MV 长：needle 有一截在 haystack 外，起点仍按偏移推出。
    #[test]
    fn needle_overhanging_haystack_start() {
        let song = music(0x0F0F, 30.0, 300, 0.5);
        // MV 从歌的第 6 秒才开始。
        let mv: Vec<i16> = song[sec(6.0)..].to_vec();
        let a = align(&fp(&song), &fp(&mv), 40).expect("must match");
        assert!((a.offset_ms + 6_000.0).abs() <= edge_tol(), "{a:?}");
        assert!(a.start_at_edge, "{a:?}");
        assert!(a.haystack_start_ms().abs() <= edge_tol(), "{a:?}");
    }

    #[test]
    fn c_abi_round_trip() {
        let song = music(0xA11CE, 30.0, 350, 0.5);
        let mut episode = music(0xB0B, 120.0, 500, 0.5);
        splice(&mut episode, &song, 0.0, 30.0, 47.3);
        let via_abi = |pcm: &[i16]| -> Vec<u32> {
            let mut ptr: *mut u8 = std::ptr::null_mut();
            let mut len: usize = 0;
            let rc = unsafe {
                ffm_fp_compute(pcm.as_ptr(), pcm.len(), SAMPLE_RATE, 1, &mut ptr, &mut len)
            };
            assert_eq!(rc, status::OK);
            let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
            crate::ffm_free_bytes(ptr, len);
            bytes
                .chunks_exact(4)
                .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect()
        };
        let needle = via_abi(&song);
        assert_eq!(needle, fp(&song));
        let hay = via_abi(&episode);
        let mut out = FfmFpMatch::default();
        let rc = unsafe {
            ffm_fp_align(
                needle.as_ptr(),
                needle.len(),
                hay.as_ptr(),
                hay.len(),
                40,
                &mut out,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(out.found, 1);
        assert_eq!(out.edge_flags, 0b11);
        assert!((out.haystack_start_ms - 47_300).abs() <= 63, "{out:?}");
        assert!((out.haystack_end_ms - 77_300).abs() <= 63, "{out:?}");

        let mut none = FfmFpMatch::default();
        let rc = unsafe {
            ffm_fp_align(
                needle.as_ptr(),
                needle.len(),
                std::ptr::null(),
                0,
                40,
                &mut none,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(none.found, 0);

        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let rc = unsafe { ffm_fp_compute(song.as_ptr(), 3, SAMPLE_RATE, 2, &mut ptr, &mut len) };
        assert_eq!(rc, status::INVALID_ARGUMENT);
        let rc = unsafe { ffm_fp_compute(std::ptr::null(), 5, SAMPLE_RATE, 1, &mut ptr, &mut len) };
        assert_eq!(rc, status::NULL_ARGUMENT);
    }
}
