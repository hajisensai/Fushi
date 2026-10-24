//! `ffc_signal_*`：音频 / 字幕信号处理（字幕自动对轴互相关、逐窗 RMS、ffmpeg 逐帧 RMS
//! 日志解析、能量包络降采样）。有声书 cue 能量吸附 / 修边 / 显示余量已迁到上游
//! hajisensai/fushi-subtitles 的 `native/asr_cue_post`（`fcp_*`，经 `lib.rs` 链进本库）。
//!
//! 全部从纯 Dart 搬来（fushi 的 `subtitle_auto_align.dart` / `galgame_waveform.dart` /
//! `audio_energy_probe.dart`），Dart 实现已删除；
//! 删除前的输出冻结成 `packages/fushi_compute/test/fixtures/signal_vectors.json`。
//!
//! **逐位一致**：浮点运算按旧 Dart 实现的顺序逐项复现（累加次序、先整数乘再转 double、
//! `(a / b).ceil()` 之类的整除 / 浮点除区别都照抄），不做向量化重排。`pow` / `ln` / `sqrt`
//! 与 Dart VM 一样调平台 libm（Rust 的 `powf` / `ln` 下沉到同一个 C `pow` / `log`），所以在
//! 同一平台上与旧实现逐位一致；Dart 的 `num.clamp` / `List<double>.sort` 的 NaN / −0.0 语义
//! 由 [dart_clamp] / [dart_compare] 复现。
//!
//! 每个导出函数一次处理一整批（整条包络 / 整段 PCM），不做逐元素 FFI 调用。

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
}
