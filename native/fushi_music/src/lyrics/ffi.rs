//! 歌词 C ABI（Dart 侧 `packages/fushi_music/lib/src/lyrics_ffi.dart`）。全部粗粒度：一次调用
//! 处理整首；输入输出都是一块字节（时间轴线格式见 [super::wire]）。
//!
//! | 符号 | 作用 |
//! |---|---|
//! | `ffm_lyrics_parser_version() -> u32` | 解析器版本（缓存失效判据） |
//! | `ffm_lyrics_parse(data, len, hint, hint_len, duration_ms, out, out_len) -> i32` | 解析；失败时 out 是 UTF-8 错误信息、返回 -3 |
//! | `ffm_lyrics_embedded(path, path_len, duration_ms, out, out_len) -> i32` | 读文件内嵌歌词（列表） |
//! | `ffm_lyrics_merge(primary, len, secondary, len, lang, lang_len, out, out_len) -> i32` | 翻译按时间配对 |
//! | `ffm_lyrics_export(timeline, len, format, format_len, out, out_len) -> i32` | 导出 `ttml` / `lrc` |
//!
//! `duration_ms < 0` = 曲长未知。

use super::embedded::{self, Embedded};
use super::wire::{self, Writer};
use crate::{guard, hand_over_bytes, slice_arg, status};

unsafe fn str_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    let b = slice_arg(ptr, len).ok_or(status::NULL_ARGUMENT)?;
    std::str::from_utf8(b).map_err(|_| status::INVALID_ARGUMENT)
}

fn duration(d: i64) -> Option<i64> {
    (d > 0).then_some(d)
}

#[no_mangle]
pub extern "C" fn ffm_lyrics_parser_version() -> u32 {
    super::PARSER_VERSION
}

/// # Safety
/// 各指针指向对应长度的可读内存；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_lyrics_parse(
    data_ptr: *const u8,
    data_len: usize,
    hint_ptr: *const u8,
    hint_len: usize,
    duration_ms: i64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(data) = slice_arg(data_ptr, data_len) else { return status::NULL_ARGUMENT };
        let hint = match str_arg(hint_ptr, hint_len) {
            Ok(h) => h,
            Err(code) => return code,
        };
        match super::parse(data, hint, duration(duration_ms)) {
            Ok(t) => {
                hand_over_bytes(wire::encode(&t), out_ptr, out_len);
                status::OK
            }
            Err(msg) => {
                hand_over_bytes(msg.into_bytes(), out_ptr, out_len);
                status::BAD_INPUT
            }
        }
    })
}

/// 内嵌歌词列表：`u32 count | (str key | str format | u32 rawLen | raw | u32 tlLen | timeline)*`。
/// `key` 是来源键（`lyrics` / `unsyncedlyrics` / `sylt`），`raw` 是可回存 DB 的原文（SYLT 导出成
/// 增强 LRC 文本）。读不了文件返回 -3（out 为错误信息）。
///
/// # Safety
/// 同 [ffm_lyrics_parse]。
#[no_mangle]
pub unsafe extern "C" fn ffm_lyrics_embedded(
    path_ptr: *const u8,
    path_len: usize,
    duration_ms: i64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let path = match str_arg(path_ptr, path_len) {
            Ok(p) => p,
            Err(code) => return code,
        };
        let items = match embedded::read(std::path::Path::new(path)) {
            Ok(v) => v,
            Err(msg) => {
                hand_over_bytes(msg.into_bytes(), out_ptr, out_len);
                return status::BAD_INPUT;
            }
        };
        let mut w = Writer::new();
        let mut entries: Vec<(String, super::model::Timeline, Vec<u8>)> = Vec::new();
        for item in items {
            match item {
                Embedded::Text { key, text } => {
                    if let Ok(t) = super::parse(text.as_bytes(), "", duration(duration_ms)) {
                        entries.push((key, t, text.into_bytes()));
                    }
                }
                Embedded::Sylt { language, events } => {
                    let t = embedded::sylt_timeline(&language, &events, duration(duration_ms));
                    let raw = super::export::to_lrc(&t).into_bytes();
                    entries.push(("sylt".to_owned(), t, raw));
                }
            }
        }
        w.u32(entries.len() as u32);
        for (key, t, raw) in entries {
            w.str(&key);
            w.str(&t.meta.format);
            w.u32(raw.len() as u32);
            w.buf.extend_from_slice(&raw);
            let tl = wire::encode(&t);
            w.u32(tl.len() as u32);
            w.buf.extend_from_slice(&tl);
        }
        hand_over_bytes(w.buf, out_ptr, out_len);
        status::OK
    })
}

/// # Safety
/// 同 [ffm_lyrics_parse]。
#[no_mangle]
pub unsafe extern "C" fn ffm_lyrics_merge(
    primary_ptr: *const u8,
    primary_len: usize,
    secondary_ptr: *const u8,
    secondary_len: usize,
    lang_ptr: *const u8,
    lang_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (Some(p), Some(s)) = (slice_arg(primary_ptr, primary_len), slice_arg(secondary_ptr, secondary_len)) else {
            return status::NULL_ARGUMENT;
        };
        let lang = match str_arg(lang_ptr, lang_len) {
            Ok(l) => l,
            Err(code) => return code,
        };
        let (Some(p), Some(s)) = (wire::decode(p), wire::decode(s)) else { return status::BAD_INPUT };
        hand_over_bytes(wire::encode(&super::merge::merge_translation(&p, &s, lang)), out_ptr, out_len);
        status::OK
    })
}

/// # Safety
/// 同 [ffm_lyrics_parse]。
#[no_mangle]
pub unsafe extern "C" fn ffm_lyrics_export(
    timeline_ptr: *const u8,
    timeline_len: usize,
    format_ptr: *const u8,
    format_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(tb) = slice_arg(timeline_ptr, timeline_len) else { return status::NULL_ARGUMENT };
        let format = match str_arg(format_ptr, format_len) {
            Ok(f) => f,
            Err(code) => return code,
        };
        let Some(t) = wire::decode(tb) else { return status::BAD_INPUT };
        let out = match format.to_ascii_lowercase().as_str() {
            "ttml" => super::export::to_ttml(&t),
            "lrc" => super::export::to_lrc(&t),
            _ => return status::INVALID_ARGUMENT,
        };
        hand_over_bytes(out.into_bytes(), out_ptr, out_len);
        status::OK
    })
}
