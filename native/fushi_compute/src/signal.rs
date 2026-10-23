//! `ffc_signal_*`：音频 / 字幕信号处理（字幕自动对轴互相关、逐窗 RMS、ffmpeg 逐帧 RMS
//! 日志解析、能量包络降采样、有声书 cue 能量吸附）。
//!
//! 全部从纯 Dart 搬来（fushi 的 `subtitle_auto_align.dart` / `galgame_waveform.dart` /
//! `audio_energy_probe.dart`，fushi_audio 的 `cue_energy_snapper.dart`），Dart 实现已删除；
//! 删除前的输出冻结成 `packages/fushi_compute/test/fixtures/signal_vectors.json`。
//!
//! **逐位一致**：浮点运算按旧 Dart 实现的顺序逐项复现（累加次序、先整数乘再转 double、
//! `(a / b).ceil()` 之类的整除 / 浮点除区别都照抄），不做向量化重排。`pow` / `ln` / `sqrt`
//! 与 Dart VM 一样调平台 libm（Rust 的 `powf` / `ln` 下沉到同一个 C `pow` / `log`），所以在
//! 同一平台上与旧实现逐位一致；Dart 的 `num.clamp` / `List<double>.sort` 的 NaN / −0.0 语义
//! 由 [dart_clamp] / [dart_compare] 复现。
//!
//! 每个导出函数一次处理一整批（整条包络 / 整本书的 cue），不做逐元素 FFI 调用。

use std::cmp::Ordering;

use crate::{guard, hand_over_bytes, status};

/// Dart `double.compareTo`：−0.0 < 0.0；NaN 与 NaN 相等、比任何非 NaN 都大。
fn dart_compare(a: f64, b: f64) -> Ordering {
    match (a.is_nan(), b.is_nan()) {
        (true, true) => Ordering::Equal,
        (true, false) => Ordering::Greater,
        (false, true) => Ordering::Less,
        (false, false) => {
            if a < b {
                Ordering::Less
            } else if a > b {
                Ordering::Greater
            } else if a == 0.0 {
                // ±0：负零在前。
                match (a.is_sign_negative(), b.is_sign_negative()) {
                    (true, false) => Ordering::Less,
                    (false, true) => Ordering::Greater,
                    _ => Ordering::Equal,
                }
            } else {
                Ordering::Equal
            }
        }
    }
}

/// Dart `double.clamp(lo, hi)`（调用方保证 `lo <= hi` 且都不是 NaN）：
/// `this < lo` → lo；`this > hi` → hi（NaN 比 hi 大，所以 NaN → hi）；否则原值。
fn dart_clamp(v: f64, lo: f64, hi: f64) -> f64 {
    if dart_compare(v, lo) == Ordering::Less {
        lo
    } else if dart_compare(v, hi) == Ordering::Greater {
        hi
    } else {
        v
    }
}

/// # Safety
/// `len > 0` 时 `ptr` 至少 `len` 个元素可读。
unsafe fn slice_in<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len))
    }
}

/// # Safety
/// `len > 0` 时 `ptr` 至少 `len` 个元素可写。
unsafe fn slice_out<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [T]> {
    if len == 0 {
        Some(&mut [])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts_mut(ptr, len))
    }
}

// ── 字幕自动对轴：互相关 ──────────────────────────────────────────────────────

/// 互相关结果：`None` = 输入不足（对应 Dart 的 `noData`）。
pub fn xcorr_best_shift(
    audio: &[f64],
    cue: &[f64],
    bin_ms: i64,
    max_shift_ms: i64,
) -> Option<(i64, f64)> {
    if bin_ms <= 0 || audio.is_empty() || cue.is_empty() || max_shift_ms < 0 {
        return None;
    }
    let active = |xs: &[f64]| {
        let mut sum = 0.0f64;
        for &v in xs {
            if v > 0.0 {
                sum += v;
            }
        }
        sum
    };
    let audio_active = active(audio);
    let cue_active = active(cue);
    // `<= 0` 对 NaN 为假（Dart 同）：活动和不可能是 NaN（只累加 > 0 的值），这里照抄。
    if audio_active <= 0.0 || cue_active <= 0.0 {
        return None;
    }
    // Dart `math.min`：两者都是正有限数（或 +inf），直接取小。
    let max_overlap = if cue_active < audio_active {
        cue_active
    } else {
        audio_active
    };
    let max_shift_bins = max_shift_ms / bin_ms;
    let m = cue.len() as i64;
    // 只有 audio[i] > 0 的项才可能累加（a > 0 && c > 0）；预先取出这些下标，按升序走，
    // 与逐个 i 判断再累加是同一串加法、同一顺序（跳过的都是不加的项）。
    let active_idx: Vec<i64> = (0..audio.len())
        .filter(|&i| audio[i] > 0.0)
        .map(|i| i as i64)
        .collect();
    let mut best_shift: i64 = 0;
    let mut best_overlap: f64 = -1.0;
    for shift in -max_shift_bins..=max_shift_bins {
        // audio[i] 对 cue[i - shift]；只走 0 <= i - shift < m 的 i。
        let lo = shift.max(0);
        let hi = m + shift;
        let from = active_idx.partition_point(|&i| i < lo);
        let mut overlap = 0.0f64;
        for &i in &active_idx[from..] {
            if i >= hi {
                break;
            }
            let c = cue[(i - shift) as usize];
            if c > 0.0 {
                overlap += audio[i as usize] * c;
            }
        }
        if overlap > best_overlap || (overlap == best_overlap && shift.abs() < best_shift.abs()) {
            best_overlap = overlap;
            best_shift = shift;
        }
    }
    let confidence = if max_overlap > 0.0 {
        dart_clamp(best_overlap / max_overlap, 0.0, 1.0)
    } else {
        0.0
    };
    Some((best_shift, confidence))
}

/// 字幕自动对轴：在 ±`max_shift_ms` 内滑动求 `audio` 与 `cue` 两条活动序列的互相关峰值。
///
/// `*out_has_data` = 0 表示输入不足（`bin_ms <= 0`、任一序列为空或没有活动格、
/// `max_shift_ms < 0`），此时 `*out_shift_bins` = 0、`*out_confidence` = 0。否则 1，
/// `*out_shift_bins` 为最佳平移格数（正 = 字幕延后；平手取 |shift| 小者），
/// `*out_confidence` 为归一化峰值（0..1）。
///
/// # Safety
/// `audio` / `cue` 各至少 `*_len` 个 f64 可读；三个输出指针可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_xcorr_best_shift(
    audio: *const f64,
    audio_len: usize,
    cue: *const f64,
    cue_len: usize,
    bin_ms: i64,
    max_shift_ms: i64,
    out_has_data: *mut i32,
    out_shift_bins: *mut i64,
    out_confidence: *mut f64,
) -> i32 {
    guard(|| {
        let (Some(audio), Some(cue)) = (slice_in(audio, audio_len), slice_in(cue, cue_len)) else {
            return status::NULL_ARGUMENT;
        };
        if out_has_data.is_null() || out_shift_bins.is_null() || out_confidence.is_null() {
            return status::NULL_ARGUMENT;
        }
        match xcorr_best_shift(audio, cue, bin_ms, max_shift_ms) {
            Some((shift, confidence)) => {
                *out_has_data = 1;
                *out_shift_bins = shift;
                *out_confidence = confidence;
            }
            None => {
                *out_has_data = 0;
                *out_shift_bins = 0;
                *out_confidence = 0.0;
            }
        }
        status::OK
    })
}

// ── galgame 波形：裸 PCM 逐窗 RMS dBFS ──────────────────────────────────────────

/// 采样解码器；不支持的格式为 `None`。
#[derive(Clone, Copy)]
enum PcmDecode {
    F32,
    I16,
    I32,
}

struct PcmPlan {
    decode: PcmDecode,
    bytes_per_sample: usize,
    channels: usize,
    total_frames: usize,
    frames_per_window: usize,
}

/// 与旧 Dart 的早退判定逐条一致；`None` = 输出空包络。
fn pcm_plan(
    len: usize,
    sample_rate: i64,
    channels: i64,
    bits_per_sample: i64,
    is_float: bool,
    window_ms: i64,
) -> Option<PcmPlan> {
    // Dart `~/` 向零截断；bits 为负时 bytes 为负 / 0，下面的 <= 0 判定吃掉。
    let bytes_per_sample = bits_per_sample / 8;
    if len == 0 || channels <= 0 || bytes_per_sample <= 0 || sample_rate <= 0 || window_ms <= 0 {
        return None;
    }
    let decode = if is_float && bits_per_sample == 32 {
        PcmDecode::F32
    } else if !is_float && bits_per_sample == 16 {
        PcmDecode::I16
    } else if !is_float && bits_per_sample == 32 {
        PcmDecode::I32
    } else {
        return None;
    };
    let frame_bytes = (channels * bytes_per_sample) as usize;
    let total_frames = len / frame_bytes;
    if total_frames == 0 {
        return None;
    }
    let frames_per_window = ((sample_rate * window_ms) / 1000).max(1) as usize;
    Some(PcmPlan {
        decode,
        bytes_per_sample: bytes_per_sample as usize,
        channels: channels as usize,
        total_frames,
        frames_per_window,
    })
}

impl PcmPlan {
    fn windows(&self) -> usize {
        self.total_frames.div_ceil(self.frames_per_window)
    }
}

fn pcm_rms_db_into(pcm: &[u8], plan: &PcmPlan, silence_db: f64, out: &mut [f64]) {
    let frame_bytes = plan.channels * plan.bytes_per_sample;
    let floor_amp = 10.0f64.powf(silence_db / 20.0);
    // 一个窗的字节 = 连续的 [f0 * frame_bytes, f1 * frame_bytes)，帧内声道相邻：按字节顺序逐个
    // 采样累加，与旧实现「帧外层、声道内层」的累加顺序相同。格式分派放在循环外。
    fn sum_squares(bytes: &[u8], decode: PcmDecode) -> f64 {
        let mut sum_sq = 0.0f64;
        match decode {
            PcmDecode::F32 => {
                for c in bytes.chunks_exact(4) {
                    let s = f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64;
                    sum_sq += s * s;
                }
            }
            PcmDecode::I16 => {
                for c in bytes.chunks_exact(2) {
                    let s = i16::from_le_bytes([c[0], c[1]]) as f64 / 32768.0;
                    sum_sq += s * s;
                }
            }
            PcmDecode::I32 => {
                for c in bytes.chunks_exact(4) {
                    let s = i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64 / 2147483648.0;
                    sum_sq += s * s;
                }
            }
        }
        sum_sq
    }
    let mut w = 0usize;
    let mut f0 = 0usize;
    while f0 < plan.total_frames {
        let f1 = plan.total_frames.min(f0 + plan.frames_per_window);
        let sum_sq = sum_squares(&pcm[f0 * frame_bytes..f1 * frame_bytes], plan.decode);
        let count = ((f1 - f0) * plan.channels) as i64;
        let rms = if count > 0 {
            (sum_sq / count as f64).sqrt()
        } else {
            0.0
        };
        let amp = if rms < floor_amp { floor_amp } else { rms };
        let mut db = 20.0 * (amp.ln() / std::f64::consts::LN_10);
        if db > 0.0 {
            db = 0.0;
        }
        if db < silence_db {
            db = silence_db;
        }
        out[w] = db;
        w += 1;
        f0 += plan.frames_per_window;
    }
}

/// 裸 PCM（小端；16 / 32 位整型、32 位 float）按 `window_ms` 切窗，逐窗算 RMS 并转 dBFS
/// （≤ 0，夹到 [`silence_db`, 0]）。
///
/// 两段式：`*out_len` 总是写入需要的帧数；`out` 为 NULL 或 `out_cap` 不够时返回
/// [BUFFER_TOO_SMALL](status::BUFFER_TOO_SMALL)（需要 0 帧时恒 OK）。格式不支持 / 参数非正 /
/// 不足一帧时需要 0 帧。
///
/// # Safety
/// `pcm` 至少 `len` 字节可读；`out` 非 NULL 时至少 `out_cap` 个 f64 可写；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_pcm_rms_db(
    pcm: *const u8,
    len: usize,
    sample_rate: i64,
    channels: i64,
    bits_per_sample: i64,
    is_float: i32,
    window_ms: i64,
    silence_db: f64,
    out: *mut f64,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(pcm) = slice_in(pcm, len) else {
            return status::NULL_ARGUMENT;
        };
        let Some(plan) = pcm_plan(
            len,
            sample_rate,
            channels,
            bits_per_sample,
            is_float != 0,
            window_ms,
        ) else {
            *out_len = 0;
            return status::OK;
        };
        let need = plan.windows();
        *out_len = need;
        if out.is_null() || out_cap < need {
            return status::BUFFER_TOO_SMALL;
        }
        pcm_rms_db_into(
            pcm,
            &plan,
            silence_db,
            std::slice::from_raw_parts_mut(out, need),
        );
        status::OK
    })
}

// ── ffmpeg ametadata 逐帧 RMS 日志 ────────────────────────────────────────────

const RMS_KEY: &[u8] = b"lavfi.astats.Overall.RMS_level";

/// JS / Dart 正则 `\s`：ASCII 空白 + U+00A0、U+1680、U+2000–U+200A、U+2028、U+2029、
/// U+202F、U+205F、U+3000、U+FEFF（不含 U+0085、U+200B）。
fn is_dart_regexp_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0b}' | '\u{0c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

/// 从 `at` 起吃掉 `\s*`，返回新位置。
fn skip_spaces(text: &str, mut at: usize) -> usize {
    while let Some(c) = text[at..].chars().next() {
        if !is_dart_regexp_space(c) {
            break;
        }
        at += c.len_utf8();
    }
    at
}

fn digits_end(bytes: &[u8], mut at: usize) -> usize {
    while at < bytes.len() && bytes[at].is_ascii_digit() {
        at += 1;
    }
    at
}

/// 在 `at`（紧跟 `\s*=\s*` 之后）匹配 `(-?\d+(?:\.\d+)?|-?inf)`，返回捕获组的结束位置。
fn match_value(bytes: &[u8], at: usize) -> Option<usize> {
    let mut p = at;
    if p < bytes.len() && bytes[p] == b'-' {
        p += 1;
    }
    let d = digits_end(bytes, p);
    if d > p {
        // 第一个分支：可选的 `.\d+`。
        if d < bytes.len() && bytes[d] == b'.' {
            let frac = digits_end(bytes, d + 1);
            if frac > d + 1 {
                return Some(frac);
            }
        }
        return Some(d);
    }
    // 第二个分支：`-?inf`。
    if bytes[p..].starts_with(b"inf") {
        return Some(p + 3);
    }
    None
}

/// 与旧 Dart `RegExp(r'lavfi\.astats\.Overall\.RMS_level\s*=\s*(-?\d+(?:\.\d+)?|-?inf)')
/// .allMatches` 逐值一致的解析；`-inf` / `inf` / 解析出非有限值都记成 `silence_db`。
pub fn parse_rms_log(text: &str, silence_db: f64) -> Vec<f64> {
    let bytes = text.as_bytes();
    let mut values = Vec::new();
    let mut from = 0usize;
    while let Some(rel) = find(&bytes[from..], RMS_KEY) {
        let key_at = from + rel;
        let mut p = skip_spaces(text, key_at + RMS_KEY.len());
        let matched = if p < bytes.len() && bytes[p] == b'=' {
            p = skip_spaces(text, p + 1);
            match_value(bytes, p).map(|end| (p, end))
        } else {
            None
        };
        match matched {
            Some((start, end)) => {
                let raw = &text[start..end];
                if raw == "-inf" || raw == "inf" {
                    values.push(silence_db);
                } else if let Ok(v) = raw.parse::<f64>() {
                    values.push(if v.is_finite() { v } else { silence_db });
                }
                from = end;
            }
            // 失败的匹配从下一个字符继续找（键是纯 ASCII，+1 不会落进多字节字符中间）。
            None => from = key_at + 1,
        }
    }
    values
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// 解析 ffmpeg `ametadata=print` 的逐帧 RMS 输出（stderr 或 `file=` 写出的文件，UTF-8 字节）。
///
/// 结果是按出现顺序的 f64 数组（小端字节），经 `*out_ptr` / `*out_len`（字节数）交给调用方，
/// 用 [ffc_free_bytes](crate::ffc_free_bytes) 释放；没有值时 `*out_ptr` = NULL、`*out_len` = 0。
/// 输入不是合法 UTF-8 返回 [BAD_INPUT](status::BAD_INPUT)（与 Dart 的
/// `readAsStringSync` / `utf8.decode` 抛 `FormatException` 对应）。
///
/// # Safety
/// `text` 至少 `len` 字节可读；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_parse_rms_log(
    text: *const u8,
    len: usize,
    silence_db: f64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out_ptr = std::ptr::null_mut();
        *out_len = 0;
        let Some(bytes) = slice_in(text, len) else {
            return status::NULL_ARGUMENT;
        };
        let Ok(text) = std::str::from_utf8(bytes) else {
            return status::BAD_INPUT;
        };
        let values = parse_rms_log(text, silence_db);
        if values.is_empty() {
            return status::OK;
        }
        let mut out = Vec::with_capacity(values.len() * 8);
        for v in values {
            out.extend_from_slice(&v.to_le_bytes());
        }
        hand_over_bytes(out, out_ptr, out_len);
        status::OK
    })
}

// ── 能量包络（dB）→ 波形桶 ─────────────────────────────────────────────────────

/// dB → 线性振幅 `10^(dB/20)`，逐个写进 `out`（可与 `db` 是同一块内存）。
///
/// # Safety
/// `db` / `out` 各至少 `len` 个 f64；两者要么完全重合，要么互不重叠。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_db_to_amplitude(
    db: *const f64,
    out: *mut f64,
    len: usize,
) -> i32 {
    guard(|| {
        if len == 0 {
            return status::OK;
        }
        if db.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        for i in 0..len {
            let v = *db.add(i);
            *out.add(i) = 10.0f64.powf(v / 20.0);
        }
        status::OK
    })
}

/// 降采样 + 归一化（输入已是线性振幅）：返回桶数（`target_buckets >= n` 时为 n）。
pub fn downsample_peaks(amp: &[f64], target_buckets: i64, percentile: f64, out: &mut Vec<f64>) {
    out.clear();
    let n = amp.len();
    if n == 0 || target_buckets <= 0 {
        return;
    }
    let buckets = if target_buckets as u64 >= n as u64 {
        n
    } else {
        target_buckets as usize
    };
    let mut min_peak = f64::INFINITY;
    for b in 0..buckets {
        let start = ((b as u128 * n as u128) / buckets as u128) as usize;
        let end = (((b + 1) as u128 * n as u128) / buckets as u128) as usize;
        let mut peak = amp[start];
        for &a in &amp[start + 1..end] {
            if a > peak {
                peak = a;
            }
        }
        out.push(peak);
        if peak < min_peak {
            min_peak = peak;
        }
    }
    // 上限 = 第 percentile 分位（Dart `clamp` + `sort` + `round` 语义）。
    let p = dart_clamp(percentile, 0.0, 1.0);
    let mut sorted = out.clone();
    sorted.sort_by(|a, b| dart_compare(*a, *b));
    let idx = ((sorted.len() - 1) as f64 * p).round() as usize;
    let ceiling = sorted[idx];
    let range = ceiling - min_peak;
    if range <= 0.0 {
        out.iter_mut().for_each(|v| *v = 0.0);
        return;
    }
    for v in out.iter_mut() {
        let x = (*v - min_peak) / range;
        *v = if x < 0.0 {
            0.0
        } else if x > 1.0 {
            1.0
        } else {
            x
        };
    }
}

/// 把线性振幅包络 `amp`（[ffc_signal_db_to_amplitude] 的输出）降到 `target_buckets` 个桶：
/// 桶 b 覆盖 `[b*n/B, (b+1)*n/B)`、取桶内峰值，再以「最小桶峰值」为地基、第 `percentile`
/// 分位（夹到 0..1）为上限线性归一化到 0..1；上限不高于地基时全 0。
/// `target_buckets >= n` 时每帧一桶；`n == 0` 或 `target_buckets <= 0` 时 0 桶。
///
/// 两段式：`*out_len` 写需要的桶数；`out` 为 NULL 或 `out_cap` 不够时返回
/// [BUFFER_TOO_SMALL](status::BUFFER_TOO_SMALL)。
///
/// `percentile` 为 NaN 时与 Dart `NaN.clamp(0, 1)` 一样取 1。
///
/// # Safety
/// `amp` 至少 `len` 个 f64 可读；`out` 非 NULL 时至少 `out_cap` 个 f64 可写；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_downsample_peaks(
    amp: *const f64,
    len: usize,
    target_buckets: i64,
    percentile: f64,
    out: *mut f64,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(amp) = slice_in(amp, len) else {
            return status::NULL_ARGUMENT;
        };
        let need = if len == 0 || target_buckets <= 0 {
            0
        } else if target_buckets as u64 >= len as u64 {
            len
        } else {
            target_buckets as usize
        };
        *out_len = need;
        if need == 0 {
            return status::OK;
        }
        if out.is_null() || out_cap < need {
            return status::BUFFER_TOO_SMALL;
        }
        let mut peaks = Vec::with_capacity(need);
        downsample_peaks(amp, target_buckets, percentile, &mut peaks);
        std::slice::from_raw_parts_mut(out, need).copy_from_slice(&peaks);
        status::OK
    })
}

// ── 有声书 cue 能量吸附 ────────────────────────────────────────────────────────

/// `CueEnergySnapper` 的参数，按 [SNAP_PARAM_COUNT] 个 f64 的数组传（整数参数是精确整数）。
pub struct SnapParams {
    pub frame_ms: i64,
    pub max_gap_ms: i64,
    pub window_ms: i64,
    pub min_valley_ms: i64,
    pub distance_penalty: f64,
    pub tail_ms: i64,
    pub lead_ms: i64,
    pub min_duration_ms: i64,
    pub floor_margin_db: f64,
    pub min_threshold_db: f64,
    pub max_threshold_db: f64,
    pub token_guard_ms: i64,
    pub edge_max_shift_ms: i64,
    pub edge_min_voice_ms: i64,
    pub edge_lead_ms: i64,
    pub edge_tail_ms: i64,
}

/// 参数数组长度。顺序即 [SnapParams] 的字段顺序。
pub const SNAP_PARAM_COUNT: usize = 16;

/// 每条 cue 在 i64 数组里占的槽数：`[start, end, audioFileIndex, hasTokens, firstOffset, lastOffset]`。
pub const SNAP_CUE_STRIDE: usize = 6;

impl SnapParams {
    fn from_slice(p: &[f64]) -> Option<Self> {
        let int = |v: f64| -> Option<i64> {
            (v.is_finite() && v.fract() == 0.0 && v.abs() < 9.0e15).then_some(v as i64)
        };
        let params = Self {
            frame_ms: int(p[0])?,
            max_gap_ms: int(p[1])?,
            window_ms: int(p[2])?,
            min_valley_ms: int(p[3])?,
            distance_penalty: p[4],
            tail_ms: int(p[5])?,
            lead_ms: int(p[6])?,
            min_duration_ms: int(p[7])?,
            floor_margin_db: p[8],
            min_threshold_db: p[9],
            max_threshold_db: p[10],
            token_guard_ms: int(p[11])?,
            edge_max_shift_ms: int(p[12])?,
            edge_min_voice_ms: int(p[13])?,
            edge_lead_ms: int(p[14])?,
            edge_tail_ms: int(p[15])?,
        };
        // Dart：`~/ frameMs` 遇 0 抛异常；clamp 的上下限反了抛 ArgumentError。
        let ok = params.frame_ms > 0
            && !params.min_threshold_db.is_nan()
            && !params.max_threshold_db.is_nan()
            && params.min_threshold_db <= params.max_threshold_db;
        ok.then_some(params)
    }
}

/// 一条 cue 的可变视图。token 偏移只需要首 / 末两个（平移规则 `max(0, o - delta)` 单调，
/// 首末位置不变）。
#[derive(Clone, Copy)]
struct SnapCue {
    start: i64,
    end: i64,
    file: i64,
    has_tokens: bool,
    first: i64,
    last: i64,
}

impl SnapCue {
    fn read(c: &[i64]) -> Self {
        Self {
            start: c[0],
            end: c[1],
            file: c[2],
            has_tokens: c[3] != 0,
            first: c[4],
            last: c[5],
        }
    }

    fn write(&self, c: &mut [i64]) {
        c[0] = self.start;
        c[1] = self.end;
        c[4] = self.first;
        c[5] = self.last;
    }

    fn first_token_ms(&self) -> Option<i64> {
        self.has_tokens.then_some(self.start + self.first)
    }

    fn last_token_ms(&self) -> Option<i64> {
        self.has_tokens.then_some(self.start + self.last)
    }

    /// `_shiftStart`：挪起点时 token 偏移一起平移（夹到 ≥ 0），绝对发射时刻不变。
    fn shift_start(&mut self, start: i64) {
        let delta = start - self.start;
        self.start = start;
        if !self.has_tokens || delta == 0 {
            return;
        }
        self.first = (self.first - delta).max(0);
        self.last = (self.last - delta).max(0);
    }
}

const FLOOR_BLOCK_FRAMES: usize = 250;
const FLOOR_SPAN_FRAMES: usize = 750;

/// 每帧门限：按 250 帧一块，取前后 750 帧内已知电平的第 10 百分位 + margin，夹到上下限。
fn thresholds(db: &[i8], p: &SnapParams) -> Vec<f64> {
    thresholds_with(
        db,
        p.floor_margin_db,
        p.min_threshold_db,
        p.max_threshold_db,
    )
}

fn thresholds_with(db: &[i8], floor_margin_db: f64, min_db: f64, max_db: f64) -> Vec<f64> {
    let n = db.len();
    let mut out = vec![0.0f64; n];
    let mut b0 = 0usize;
    while b0 < n {
        let lo = b0.saturating_sub(FLOOR_SPAN_FRAMES);
        let hi = n.min(b0 + FLOOR_BLOCK_FRAMES + FLOOR_SPAN_FRAMES);
        // 计数排序取第 k 小（与 Dart 的 sort + 下标同值）。
        let mut hist = [0usize; 256];
        let mut count = 0usize;
        for &v in &db[lo..hi] {
            if v != 0 {
                hist[(v as i16 + 128) as usize] += 1;
                count += 1;
            }
        }
        let mut t = max_db;
        if count > 0 {
            // Dart：`((len - 1) * 10 / 100).round()`——先整数乘，再浮点除。
            let k = (((count - 1) * 10) as f64 / 100.0).round() as usize;
            let mut seen = 0usize;
            let mut floor = 0i16;
            for (bucket, &c) in hist.iter().enumerate() {
                seen += c;
                if seen > k {
                    floor = bucket as i16 - 128;
                    break;
                }
            }
            t = dart_clamp(floor as f64 + floor_margin_db, min_db, max_db);
        }
        let end = n.min(b0 + FLOOR_BLOCK_FRAMES);
        out[b0..end].iter_mut().for_each(|x| *x = t);
        b0 += FLOOR_BLOCK_FRAMES;
    }
    out
}

/// Dart `(a / b).ceil()`（int / int → double → ceil）。
fn ceil_div_f64(a: i64, b: i64) -> i64 {
    (a as f64 / b as f64).ceil() as i64
}

/// `CueEnergySnapper.snap`：把紧挨着的两条 cue 之间的切点吸到能量谷上，返回挪动的切点数。
fn snap_cues(cues: &mut [SnapCue], db: &[i8], p: &SnapParams) -> i64 {
    let n = db.len() as i64;
    if n == 0 || cues.len() < 2 {
        return 0;
    }
    let threshold = thresholds(db, p);
    let quiet = |f: i64| -> bool {
        let v = db[f as usize];
        v != 0 && (v as f64) < threshold[f as usize]
    };
    let min_valley = ceil_div_f64(p.min_valley_ms, p.frame_ms);
    let mut moved = 0i64;
    for i in 0..cues.len() - 1 {
        let cur = cues[i];
        let mut next = cues[i + 1];
        if cur.file != next.file {
            continue;
        }
        let gap = next.start - cur.end;
        if gap < 0 || gap > p.max_gap_ms {
            continue;
        }
        let b = (cur.end + next.start) / 2;
        let f0 = ((b - p.window_ms) / p.frame_ms).max(0);
        let f1 = ((b + p.window_ms) / p.frame_ms).min(n);
        let mut best: i64 = -1;
        let mut best_len: i64 = 0;
        let mut best_score: f64 = 0.0;
        let mut f = f0;
        while f < f1 {
            if !quiet(f) {
                f += 1;
                continue;
            }
            let mut s = f;
            while s > 0 && quiet(s - 1) {
                s -= 1;
            }
            while f < n && quiet(f) {
                f += 1;
            }
            let len = f - s;
            if len < min_valley {
                continue;
            }
            let center = ((s + f) * p.frame_ms) as f64 / 2.0;
            let score = (len * p.frame_ms) as f64 - p.distance_penalty * (center - b as f64).abs();
            if best < 0 || score > best_score {
                best = s;
                best_len = len;
                best_score = score;
            }
        }
        if best < 0 {
            continue;
        }
        let valley_start = best * p.frame_ms;
        let valley_end = (best + best_len) * p.frame_ms;
        let end = (valley_start + p.tail_ms).min(valley_end);
        let start = (valley_end - p.lead_ms).max(valley_start).max(end);
        if end - cur.start < p.min_duration_ms || next.end - start < p.min_duration_ms {
            continue;
        }
        if let Some(first) = next.first_token_ms() {
            if start > first + p.token_guard_ms {
                continue;
            }
        }
        next.shift_start(start);
        cues[i + 1] = next;
        cues[i].end = end;
        moved += 1;
    }
    moved
}

/// `CueEnergySnapper.refineEdges`：起止点落在静音里时收回到真实有声处，返回挪动的边数。
fn refine_edges(cues: &mut [SnapCue], db: &[i8], p: &SnapParams) -> i64 {
    let n = db.len() as i64;
    if n == 0 || cues.is_empty() {
        return 0;
    }
    let threshold = thresholds(db, p);
    let quiet = |f: i64| -> bool {
        let v = db[f as usize];
        v != 0 && (v as f64) < threshold[f as usize]
    };
    let max_shift = p.edge_max_shift_ms / p.frame_ms;
    let min_voice = ceil_div_f64(p.edge_min_voice_ms, p.frame_ms);
    let mut moved = 0i64;
    for cue in cues.iter_mut() {
        let fs = cue.start / p.frame_ms;
        if fs >= 0 && fs < n && quiet(fs) {
            let mut f = fs;
            let limit = n.min(fs + max_shift);
            let mut onset: i64 = -1;
            while f < limit {
                if quiet(f) {
                    f += 1;
                    continue;
                }
                let mut g = f;
                while g < n && !quiet(g) && g - f < min_voice {
                    g += 1;
                }
                if g - f >= min_voice {
                    onset = f;
                    break;
                }
                f = g;
            }
            if onset >= 0 {
                let start = cue.start.max(onset * p.frame_ms - p.edge_lead_ms);
                if start > cue.start && cue.end - start >= p.min_duration_ms {
                    cue.shift_start(start);
                    moved += 1;
                }
            }
        }
        let fe = (cue.end - 1) / p.frame_ms;
        if fe >= 0 && fe < n && quiet(fe) {
            let mut f = fe;
            let limit = (-1i64).max(fe - max_shift);
            let mut offset: i64 = -1;
            while f > limit {
                if quiet(f) {
                    f -= 1;
                    continue;
                }
                let mut g = f;
                while g >= 0 && !quiet(g) && f - g < min_voice {
                    g -= 1;
                }
                if f - g >= min_voice {
                    offset = f;
                    break;
                }
                f = g;
            }
            if offset >= 0 {
                let end = cue.end.min((offset + 1) * p.frame_ms + p.edge_tail_ms);
                let last_ok = match cue.last_token_ms() {
                    None => true,
                    Some(last) => end >= last - p.token_guard_ms,
                };
                if end < cue.end && end - cue.start >= p.min_duration_ms && last_ok {
                    cue.end = end;
                    moved += 1;
                }
            }
        }
    }
    moved
}

/// 共用的入参解包：成功时跑 `body`，把 cue 写回并写 `*out_moved`。
unsafe fn with_snap_cues(
    energy: *const i8,
    energy_len: usize,
    cues: *mut i64,
    cue_count: usize,
    params: *const f64,
    out_moved: *mut i64,
    body: fn(&mut [SnapCue], &[i8], &SnapParams) -> i64,
) -> i32 {
    if out_moved.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(db) = slice_in(energy, energy_len) else {
        return status::NULL_ARGUMENT;
    };
    let Some(raw) = slice_out(cues, cue_count * SNAP_CUE_STRIDE) else {
        return status::NULL_ARGUMENT;
    };
    let Some(param_slice) = slice_in(params, SNAP_PARAM_COUNT) else {
        return status::NULL_ARGUMENT;
    };
    let Some(p) = SnapParams::from_slice(param_slice) else {
        return status::INVALID_ARGUMENT;
    };
    let mut list: Vec<SnapCue> = raw
        .chunks_exact(SNAP_CUE_STRIDE)
        .map(SnapCue::read)
        .collect();
    let moved = body(&mut list, db, &p);
    for (cue, slot) in list.iter().zip(raw.chunks_exact_mut(SNAP_CUE_STRIDE)) {
        cue.write(slot);
    }
    *out_moved = moved;
    status::OK
}

/// 有声书 cue 能量吸附（`CueEnergySnapper.snap`），一次处理整本书。
///
/// - `energy`：从时间 0 起每 `frame_ms` 一帧的整数 dBFS（0 = 未知，按有声处理）。
/// - `cues`：`cue_count` × [SNAP_CUE_STRIDE] 个 i64，每条
///   `[startMs, endMs, audioFileIndex, hasTokens(0/1), 首 token 偏移, 末 token 偏移]`；
///   就地改写起止与两个偏移（偏移按 `max(0, o − Δstart)` 平移；Δ = 0 时不动）。
/// - `params`：[SNAP_PARAM_COUNT] 个 f64，顺序 `frameMs, maxGapMs, windowMs, minValleyMs,
///   distancePenalty, tailMs, leadMs, minDurationMs, floorMarginDb, minThresholdDb,
///   maxThresholdDb, tokenGuardMs, edgeMaxShiftMs, edgeMinVoiceMs, edgeLeadMs, edgeTailMs`；
///   整数参数必须是精确整数、`frameMs > 0`、`minThresholdDb <= maxThresholdDb`，否则
///   [INVALID_ARGUMENT](status::INVALID_ARGUMENT)。
/// - `*out_moved`：挪动的切点数。
///
/// 每条 cue 的起点在一次调用里最多被挪一次（作为「后句」时）。
///
/// # Safety
/// 各指针按上面的长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_cue_energy_snap(
    energy: *const i8,
    energy_len: usize,
    cues: *mut i64,
    cue_count: usize,
    params: *const f64,
    out_moved: *mut i64,
) -> i32 {
    guard(|| {
        with_snap_cues(
            energy, energy_len, cues, cue_count, params, out_moved, snap_cues,
        )
    })
}

/// 有声书 cue 起止点收回到真实有声处（`CueEnergySnapper.refineEdges`），参数与
/// [ffc_signal_cue_energy_snap] 相同；`*out_moved` 为挪动的边数。
///
/// # Safety
/// 同 [ffc_signal_cue_energy_snap]。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_cue_refine_edges(
    energy: *const i8,
    energy_len: usize,
    cues: *mut i64,
    cue_count: usize,
    params: *const f64,
    out_moved: *mut i64,
) -> i32 {
    guard(|| {
        with_snap_cues(
            energy,
            energy_len,
            cues,
            cue_count,
            params,
            out_moved,
            refine_edges,
        )
    })
}

/// `CueEnergySnapper.displayMargins` 的参数，按 [DISPLAY_PARAM_COUNT] 个 f64 传。
pub struct DisplayParams {
    pub frame_ms: i64,
    pub floor_margin_db: f64,
    pub min_threshold_db: f64,
    pub max_threshold_db: f64,
    pub min_voice_ms: i64,
    pub slow_cps: f64,
    pub fast_cps: f64,
    /// 起点提前量，按档 `[慢, 正常, 快]`。
    pub head_ms: [i64; 3],
    /// 收声后续显的基础量，按档 `[慢, 正常, 快]`。
    pub tail_ms: [i64; 3],
    pub gap_tail_ratio: f64,
    pub tail_cap_ms: i64,
    pub glue_ms: i64,
    pub tail_safety_ms: i64,
}

/// 参数数组长度：`frameMs, floorMarginDb, minThresholdDb, maxThresholdDb, minVoiceMs,
/// slowCps, fastCps, headSlowMs, headNormalMs, headFastMs, tailSlowMs, tailNormalMs,
/// tailFastMs, gapTailRatio, tailCapMs, glueMs, tailSafetyMs`。
pub const DISPLAY_PARAM_COUNT: usize = 17;

/// 每条 cue 的槽数：`[startMs, endMs, audioFileIndex, 正文字数]`。
pub const DISPLAY_CUE_STRIDE: usize = 4;

impl DisplayParams {
    fn from_slice(p: &[f64]) -> Option<Self> {
        let int = |v: f64| -> Option<i64> {
            (v.is_finite() && v.fract() == 0.0 && v.abs() < 9.0e15).then_some(v as i64)
        };
        let num = |v: f64| -> Option<f64> { v.is_finite().then_some(v) };
        let params = Self {
            frame_ms: int(p[0])?,
            floor_margin_db: num(p[1])?,
            min_threshold_db: num(p[2])?,
            max_threshold_db: num(p[3])?,
            min_voice_ms: int(p[4])?,
            slow_cps: num(p[5])?,
            fast_cps: num(p[6])?,
            head_ms: [int(p[7])?, int(p[8])?, int(p[9])?],
            tail_ms: [int(p[10])?, int(p[11])?, int(p[12])?],
            gap_tail_ratio: num(p[13])?,
            tail_cap_ms: int(p[14])?,
            glue_ms: int(p[15])?,
            tail_safety_ms: int(p[16])?,
        };
        let ok = params.frame_ms > 0
            && params.min_voice_ms >= 0
            && params.min_threshold_db <= params.max_threshold_db
            && params.slow_cps <= params.fast_cps;
        ok.then_some(params)
    }
}

/// `[from_ms, to_ms)` 内第一段有声的起点与最后一段有声的终点（毫秒）；一段至少
/// `min_voice` 帧连续有声才算。
fn voice_span(
    voiced: &dyn Fn(i64) -> bool,
    n: i64,
    from_ms: i64,
    to_ms: i64,
    frame_ms: i64,
    min_voice: i64,
) -> Option<(i64, i64)> {
    let f0 = (from_ms / frame_ms).max(0);
    let f1 = (to_ms / frame_ms).min(n);
    let mut onset = None;
    let mut run = 0i64;
    for f in f0..f1 {
        run = if voiced(f) { run + 1 } else { 0 };
        if run >= min_voice {
            onset = Some((f - run + 1) * frame_ms);
            break;
        }
    }
    let onset = onset?;
    run = 0;
    let mut f = f1 - 1;
    while f >= f0 {
        run = if voiced(f) { run + 1 } else { 0 };
        if run >= min_voice {
            return Some((onset, (f + run) * frame_ms));
        }
        f -= 1;
    }
    None
}

/// 跟读显示余量：按 cue 有声跨度的字速分慢 / 正常 / 快三档，起点在开口前、终点在
/// 收声后各留一段（快档几乎不留，慢档前后一两百毫秒），句间停顿越长尾巴越宽
/// （`gapTailRatio × (停顿 − glue)`，封顶 `tailCapMs`；快档不吃这一项）。
///
/// - 只外扩、不内收：吸附 / 修边给出的边界已经贴声音，这里只决定要不要多留；
/// - 与前一条的空地 ≤ `glueMs`（连读 / 窄缝）不提前起点，与后一条停顿 ≤ `glueMs` 不延尾；
/// - 起点不早于前一条（已处理后的）终点 + 1 ms，终点不晚于后一条起点 − `tailSafetyMs`；
///   跨音频文件的邻居不参与；
/// - 没有有声帧（全静音）或没有正文字数的 cue 不动。
///
/// 返回动过的边数。
fn display_margins(raw: &mut [i64], db: &[i8], p: &DisplayParams) -> i64 {
    let n = db.len() as i64;
    let count = raw.len() / DISPLAY_CUE_STRIDE;
    if n == 0 || count == 0 {
        return 0;
    }
    let threshold = thresholds_with(
        db,
        p.floor_margin_db,
        p.min_threshold_db,
        p.max_threshold_db,
    );
    let voiced = |f: i64| -> bool {
        let v = db[f as usize];
        v == 0 || (v as f64) >= threshold[f as usize]
    };
    let min_voice = ceil_div_f64(p.min_voice_ms.max(1), p.frame_ms);
    let orig_starts: Vec<i64> = (0..count).map(|i| raw[i * DISPLAY_CUE_STRIDE]).collect();
    let mut moved = 0i64;
    for i in 0..count {
        let at = i * DISPLAY_CUE_STRIDE;
        let (start, end, file, chars) = (raw[at], raw[at + 1], raw[at + 2], raw[at + 3]);
        let Some((on, off)) = voice_span(&voiced, n, start, end, p.frame_ms, min_voice) else {
            continue;
        };
        if off <= on || chars <= 0 {
            continue;
        }
        let cps = chars as f64 / ((off - on) as f64 / 1000.0);
        let tier = if cps >= p.fast_cps {
            2
        } else if cps >= p.slow_cps {
            1
        } else {
            0
        };
        let prev_end = (i > 0 && raw[at - DISPLAY_CUE_STRIDE + 2] == file)
            .then(|| raw[at - DISPLAY_CUE_STRIDE + 1]);
        let room = prev_end.map_or(i64::MAX, |e| on - e);
        if room > p.glue_ms {
            let floor = prev_end.map_or(0, |e| e + 1);
            let s = start.min((on - p.head_ms[tier]).max(floor));
            if s < start {
                raw[at] = s;
                moved += 1;
            }
        }
        let next_start =
            (i + 1 < count && raw[at + DISPLAY_CUE_STRIDE + 2] == file).then(|| orig_starts[i + 1]);
        let gap = next_start.map_or(i64::MAX, |s| s - off);
        if gap > p.glue_ms {
            let tail = if tier == 2 {
                p.tail_ms[2]
            } else {
                let by_gap = match next_start {
                    None => p.tail_cap_ms as f64,
                    Some(_) => p.gap_tail_ratio * (gap - p.glue_ms) as f64,
                };
                (p.tail_ms[tier] as f64)
                    .max(by_gap)
                    .min(p.tail_cap_ms as f64)
                    .round() as i64
            };
            let ceiling = next_start.map_or(i64::MAX, |s| s - p.tail_safety_ms);
            let e = end.max((off + tail).min(ceiling));
            if e > end {
                raw[at + 1] = e;
                moved += 1;
            }
        }
    }
    moved
}

/// 有声书 cue 跟读显示余量（`CueEnergySnapper.displayMargins`），整本书一次调用。
///
/// - `energy`：同 [ffc_signal_cue_energy_snap]；
/// - `cues`：`cue_count` × [DISPLAY_CUE_STRIDE] 个 i64，按时间排序，就地改写起止；
/// - `params`：[DISPLAY_PARAM_COUNT] 个 f64（顺序见常量注释）；整数参数必须是精确整数、
///   `frameMs > 0`、门限上下限不颠倒、`slowCps <= fastCps`，否则
///   [INVALID_ARGUMENT](status::INVALID_ARGUMENT)；
/// - `*out_moved`：动过的边数。
///
/// # Safety
/// 各指针按上面的长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_signal_cue_display_margins(
    energy: *const i8,
    energy_len: usize,
    cues: *mut i64,
    cue_count: usize,
    params: *const f64,
    out_moved: *mut i64,
) -> i32 {
    guard(|| {
        if out_moved.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(db) = slice_in(energy, energy_len) else {
            return status::NULL_ARGUMENT;
        };
        let Some(raw) = slice_out(cues, cue_count * DISPLAY_CUE_STRIDE) else {
            return status::NULL_ARGUMENT;
        };
        let Some(param_slice) = slice_in(params, DISPLAY_PARAM_COUNT) else {
            return status::NULL_ARGUMENT;
        };
        let Some(p) = DisplayParams::from_slice(param_slice) else {
            return status::INVALID_ARGUMENT;
        };
        *out_moved = display_margins(raw, db, &p);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dart_clamp_and_compare_semantics() {
        assert_eq!(dart_clamp(f64::NAN, 0.0, 1.0), 1.0);
        assert!(dart_clamp(-0.0, 0.0, 1.0).is_sign_positive());
        assert_eq!(dart_clamp(0.5, 0.0, 1.0), 0.5);
        assert_eq!(dart_compare(f64::NAN, f64::INFINITY), Ordering::Greater);
        assert_eq!(dart_compare(-0.0, 0.0), Ordering::Less);
    }

    #[test]
    fn xcorr_finds_shift_and_prefers_small_shift_on_tie() {
        let audio = [0.0, 0.0, 1.0, 1.0, 0.0];
        let cue = [1.0, 1.0, 0.0];
        assert_eq!(xcorr_best_shift(&audio, &cue, 10, 100_000), Some((2, 1.0)));
        let periodic = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
        assert_eq!(
            xcorr_best_shift(&periodic, &periodic, 100, 400),
            Some((0, 1.0))
        );
        assert_eq!(xcorr_best_shift(&[], &cue, 10, 100), None);
        assert_eq!(xcorr_best_shift(&audio, &cue, 0, 100), None);
        assert_eq!(xcorr_best_shift(&audio, &cue, 10, -1), None);
    }

    #[test]
    fn pcm_rms_db_two_phase_and_values() {
        let pcm: Vec<u8> = [16384i16, -16384, 0, 0]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();
        let mut need = 0usize;
        unsafe {
            assert_eq!(
                ffc_signal_pcm_rms_db(
                    pcm.as_ptr(),
                    pcm.len(),
                    100,
                    1,
                    16,
                    0,
                    20,
                    -120.0,
                    std::ptr::null_mut(),
                    0,
                    &mut need
                ),
                status::BUFFER_TOO_SMALL
            );
            assert_eq!(need, 2);
            let mut out = [0.0f64; 2];
            assert_eq!(
                ffc_signal_pcm_rms_db(
                    pcm.as_ptr(),
                    pcm.len(),
                    100,
                    1,
                    16,
                    0,
                    20,
                    -120.0,
                    out.as_mut_ptr(),
                    2,
                    &mut need
                ),
                status::OK
            );
            assert!((out[0] - (-6.020_599_913_279_624)).abs() < 1e-12);
            // 全零窗：振幅取地板 1e-6，log 换算回来比 -120 高 1 ULP（旧 Dart 同值）。
            assert!((out[1] + 120.0).abs() < 1e-9);
            // 24 位：不支持，0 帧。
            assert_eq!(
                ffc_signal_pcm_rms_db(
                    pcm.as_ptr(),
                    pcm.len(),
                    100,
                    1,
                    24,
                    0,
                    20,
                    -120.0,
                    std::ptr::null_mut(),
                    0,
                    &mut need
                ),
                status::OK
            );
            assert_eq!(need, 0);
        }
    }

    #[test]
    fn parse_rms_log_matches_regexp_semantics() {
        let key = "lavfi.astats.Overall.RMS_level";
        let text = format!(
            "frame:0\n{key}=-30.5\n{key} = -inf\n{key}\u{3000}=\u{a0}12.\n{key}\u{85}=-1\n{key}=nan\n{key}={key}=7\n"
        );
        assert_eq!(parse_rms_log(&text, -120.0), vec![-30.5, -120.0, 12.0, 7.0]);
        unsafe {
            let mut ptr = std::ptr::null_mut();
            let mut len = 0usize;
            let bad = [b'a', 0xff];
            assert_eq!(
                ffc_signal_parse_rms_log(bad.as_ptr(), 2, -120.0, &mut ptr, &mut len),
                status::BAD_INPUT
            );
            let ok = format!("{key}=-2.5");
            assert_eq!(
                ffc_signal_parse_rms_log(ok.as_ptr(), ok.len(), -120.0, &mut ptr, &mut len),
                status::OK
            );
            assert_eq!(len, 8);
            assert_eq!(
                f64::from_le_bytes(std::slice::from_raw_parts(ptr, 8).try_into().unwrap()),
                -2.5
            );
            crate::ffc_free_bytes(ptr, len);
        }
    }

    #[test]
    fn downsample_normalizes_between_floor_and_percentile() {
        let amp: Vec<f64> = [-30.0f64, -20.0, -10.0]
            .iter()
            .map(|d| 10f64.powf(d / 20.0))
            .collect();
        let mut out = Vec::new();
        downsample_peaks(&amp, 3, 0.99, &mut out);
        assert_eq!(out[0], 0.0);
        assert_eq!(out[2], 1.0);
        downsample_peaks(&amp, 0, 0.99, &mut out);
        assert!(out.is_empty());
        downsample_peaks(&[0.5, 0.5], 2, 0.99, &mut out);
        assert_eq!(out, vec![0.0, 0.0]);
    }

    fn params() -> Vec<f64> {
        vec![
            20.0, 400.0, 600.0, 120.0, 0.5, 80.0, 40.0, 500.0, 16.0, -50.0, -30.0, 200.0, 600.0,
            60.0, 150.0, 80.0,
        ]
    }

    fn energy(total_ms: usize, silences: &[(usize, usize)]) -> Vec<i8> {
        let mut e = vec![-20i8; total_ms / 20];
        for &(a, b) in silences {
            e[a / 20..b / 20].iter_mut().for_each(|v| *v = -70);
        }
        e
    }

    fn display_params() -> Vec<f64> {
        vec![
            20.0, 16.0, -50.0, -30.0, 60.0, 5.5, 7.0, 120.0, 80.0, 40.0, 180.0, 100.0, 20.0, 0.18,
            250.0, 400.0, 50.0,
        ]
    }

    fn margins(e: &[i8], cues: &mut [i64]) -> i64 {
        let mut moved = 0i64;
        let p = display_params();
        unsafe {
            assert_eq!(
                ffc_signal_cue_display_margins(
                    e.as_ptr(),
                    e.len(),
                    cues.as_mut_ptr(),
                    cues.len() / DISPLAY_CUE_STRIDE,
                    p.as_ptr(),
                    &mut moved
                ),
                status::OK
            );
        }
        moved
    }

    #[test]
    fn display_margins_by_tempo() {
        // 有声 [1000, 3000) 与 [5000, 7000)，其余静音。
        let e = energy(9000, &[(0, 1000), (3000, 5000), (7000, 9000)]);
        // 慢：10 字 / 2 s = 5 cps → 头 120；尾 max(180, 0.18 × (2000 − 400) = 288) 封顶 250。
        let mut slow = vec![1000i64, 3080, 0, 10, 5000, 7080, 0, 10];
        assert_eq!(margins(&e, &mut slow), 4);
        assert_eq!(&slow[..2], &[880, 3250]);
        // 第二条后面没有邻居：尾按封顶 250。
        assert_eq!(&slow[4..6], &[4880, 7250]);
        // 快：20 字 / 2 s = 10 cps → 头 40、尾 20（只外扩：原终点 3080 更晚，不动）。
        let mut fast = vec![1000i64, 3080, 0, 20, 5000, 7080, 0, 20];
        margins(&e, &mut fast);
        assert_eq!(&fast[..2], &[960, 3080]);
        // 连读：停顿只有 300 ms → 前条不延尾、后条不提前。
        let e = energy(9000, &[(0, 1000), (3000, 3300), (5300, 9000)]);
        let mut glued = vec![1000i64, 3000, 0, 10, 3300, 5300, 0, 10];
        margins(&e, &mut glued);
        assert_eq!(glued[1], 3000);
        assert_eq!(glued[4], 3300);
    }

    #[test]
    fn display_margins_never_cross_neighbours_or_files() {
        let e = energy(9000, &[(0, 1000), (3000, 3600), (5600, 9000)]);
        // 停顿 500 ms：尾 180，且不越过下一条起点 − 50；后条提前也不压前条新终点。
        let mut cues = vec![1000i64, 3000, 0, 10, 3500, 5600, 0, 10];
        margins(&e, &mut cues);
        assert_eq!(cues[1], 3180);
        assert_eq!(cues[4], 3480);
        // 不同文件的邻居不参与：尾按「后面没人」封顶。
        let mut cross = vec![1000i64, 3000, 0, 10, 3500, 5600, 1, 10];
        margins(&e, &mut cross);
        assert_eq!(cross[1], 3250);
    }

    #[test]
    fn display_margins_rejects_bad_params() {
        let e = energy(3000, &[]);
        let mut cues = vec![0i64, 2000, 0, 10];
        let mut moved = 0i64;
        let mut p = display_params();
        p[5] = 8.0; // slowCps > fastCps
        unsafe {
            assert_eq!(
                ffc_signal_cue_display_margins(
                    e.as_ptr(),
                    e.len(),
                    cues.as_mut_ptr(),
                    1,
                    p.as_ptr(),
                    &mut moved
                ),
                status::INVALID_ARGUMENT
            );
        }
    }

    #[test]
    fn snap_moves_boundary_into_valley() {
        let e = energy(6000, &[(2300, 2700)]);
        let mut cues = vec![0i64, 2000, 0, 0, 0, 0, 2000, 5000, 0, 0, 0, 0];
        let mut moved = 0i64;
        unsafe {
            assert_eq!(
                ffc_signal_cue_energy_snap(
                    e.as_ptr(),
                    e.len(),
                    cues.as_mut_ptr(),
                    2,
                    params().as_ptr(),
                    &mut moved
                ),
                status::OK
            );
        }
        assert_eq!(moved, 1);
        assert_eq!(cues[1], 2380);
        assert_eq!(cues[6], 2660);
    }

    #[test]
    fn snap_rejects_bad_params() {
        let e = energy(6000, &[]);
        let mut cues = vec![0i64, 2000, 0, 0, 0, 0];
        let mut moved = 0i64;
        let mut p = params();
        p[0] = 0.0;
        unsafe {
            assert_eq!(
                ffc_signal_cue_refine_edges(
                    e.as_ptr(),
                    e.len(),
                    cues.as_mut_ptr(),
                    1,
                    p.as_ptr(),
                    &mut moved
                ),
                status::INVALID_ARGUMENT
            );
        }
        let mut p = params();
        p[9] = -10.0; // min > max
        unsafe {
            assert_eq!(
                ffc_signal_cue_energy_snap(
                    e.as_ptr(),
                    e.len(),
                    cues.as_mut_ptr(),
                    1,
                    p.as_ptr(),
                    &mut moved
                ),
                status::INVALID_ARGUMENT
            );
        }
    }
}
