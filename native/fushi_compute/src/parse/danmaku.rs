//! `ffc_parse_danmaku_*`：弹幕 sidecar（Bilibili XML / 弹弹play JSON）解析。
//!
//! 这是弹幕解析**唯一**的实现（原 Dart `parseBilibiliDanmakuXml` /
//! `parseDandanplayDanmakuJson` / `dandanplayCommentsToDanmaku`，
//! fushi/lib/src/media/video/video_danmaku_source.dart）。结果逐条、逐字段与旧实现一致，
//! 靠的是把旧实现依赖的每一层语义原样复刻：
//! - XML 文法与校验 = `package:xml` 6.6.1（[danmaku_xml]）；
//! - JSON 文法、数值、重复键、错误文案 = Dart VM `jsonDecode`（[danmaku_json]）；
//! - `double.tryParse` / `int.tryParse` / `round` / `toInt` / `toString` / `trim` /
//!   `toLowerCase` = Dart VM（[danmaku_dart]）；
//! - 排序 = Dart `List.sort` 的不稳定双枢轴快排（[danmaku_sort]）。
//!
//! 冻结的输入 → 输出向量在 `packages/fushi_compute/test/danmaku_parity_test.dart`。
//!
//! # 输出缓冲区（[hand_over_bytes] 交出，Dart 用 `ffc_free_bytes` 释放）
//! 全部是本机字节序：
//! - 头部 6 × u32：`outcome`、`error_code`、`error_offset`、`count`、`pool_len`、保留 0。
//!   - `outcome`：0 成功；1 语法 / 校验错误；2 JSON 形状不对（根不是对象或 `comments`
//!     不是数组）；3 数值非有限（Dart 侧 `UnsupportedError('Infinity or NaN toInt')`）。
//!   - `error_code` / `error_offset`：JSON 语法错误的 Dart 文案编号（见
//!     [danmaku_json::JsonErrorKind]）与 `FormatException.offset`；其余情况为 0。
//! - `count` 条记录，每条 4 × u32：`start_ms`（0..=2^30）、`color_argb`、`mode`
//!   （0 滚动 / 1 顶部 / 2 底部，即 `VideoDanmakuMode` 的 index）、`text_len`。
//! - 文本池 `pool_len` 个 u16：各条文本按记录顺序首尾相接。
//!
//! 头部与记录都是 4 字节对齐的整数个 u32，所以文本池的起点也是偶数偏移。

// 子模块与本文件同目录（src/parse/danmaku_*.rs）。
#[path = "danmaku_dart.rs"]
mod danmaku_dart;
#[path = "danmaku_json.rs"]
mod danmaku_json;
#[path = "danmaku_sort.rs"]
mod danmaku_sort;
#[path = "danmaku_xml.rs"]
mod danmaku_xml;

use danmaku_dart::{
    double_try_parse, int_try_parse, lower_eq_ascii_keyword, round, to_int, trim, NonFinite,
};
use danmaku_json::{JsonDoc, Node};

use crate::{guard, hand_over_bytes, status};

pub const OUTCOME_OK: u32 = 0;
pub const OUTCOME_SYNTAX_ERROR: u32 = 1;
pub const OUTCOME_SHAPE_ERROR: u32 = 2;
pub const OUTCOME_NON_FINITE: u32 = 3;

pub const MODE_SCROLL: u32 = 0;
pub const MODE_TOP: u32 = 1;
pub const MODE_BOTTOM: u32 = 2;

const HEADER_WORDS: usize = 6;
const RECORD_WORDS: usize = 4;
const MAX_START_MS: i64 = 1 << 30;

/// 一条弹幕；文本是 [Texts] 里某个来源的一段。
#[derive(Clone, Copy, Debug)]
struct Item {
    start_ms: i64,
    color_argb: u32,
    mode: u32,
    text: TextRef,
}

#[derive(Clone, Copy, Debug)]
struct TextRef {
    source: u8,
    start: u32,
    len: u32,
}

/// 解析结果（Rust 侧的公开形态，测试与 FFI 共用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DanmakuParse {
    pub outcome: u32,
    pub error_code: u32,
    pub error_offset: u32,
    /// (start_ms, text, mode, color_argb)，已按 Dart 算法排序。
    pub items: Vec<(i64, Vec<u16>, u32, u32)>,
}

fn mode_from_raw(raw: i64) -> Option<u32> {
    match raw {
        1..=3 => Some(MODE_SCROLL),
        4 => Some(MODE_BOTTOM),
        5 => Some(MODE_TOP),
        _ => None,
    }
}

fn mode_from_string(raw: &[u16]) -> Option<u32> {
    if lower_eq_ascii_keyword(raw, b"scroll")
        || lower_eq_ascii_keyword(raw, b"rolling")
        || lower_eq_ascii_keyword(raw, b"right")
    {
        Some(MODE_SCROLL)
    } else if lower_eq_ascii_keyword(raw, b"top") {
        Some(MODE_TOP)
    } else if lower_eq_ascii_keyword(raw, b"bottom") {
        Some(MODE_BOTTOM)
    } else {
        None
    }
}

#[inline]
fn argb_from_rgb(rgb: i64) -> u32 {
    0xFF00_0000 | (rgb & 0x00FF_FFFF) as u32
}

#[inline]
fn clamp_ms(ms: i64) -> i64 {
    ms.clamp(0, MAX_START_MS)
}

/// `_itemFromParts(p.split(','), text, colorIndex: color_index)`：返回 (start_ms, mode, color)。
/// [text] 已 trim。
fn item_from_parts(
    p: &[u16],
    text: &[u16],
    color_index: usize,
) -> Result<Option<(i64, u32, u32)>, NonFinite> {
    // split(',') 只需要第 0、1、color_index 段，以及「段数 > color_index」。
    let mut fields: [&[u16]; 4] = [&[]; 4];
    let mut count = 0usize;
    let mut start = 0usize;
    for (i, &unit) in p.iter().enumerate() {
        if unit == b',' as u16 {
            if count <= color_index {
                fields[count] = &p[start..i];
            }
            count += 1;
            start = i + 1;
        }
    }
    if count <= color_index {
        fields[count] = &p[start..];
    }
    let parts = count + 1;
    if parts <= color_index || trim(text).is_empty() {
        return Ok(None);
    }
    let seconds = double_try_parse(trim(fields[0]));
    let raw_mode = int_try_parse(trim(fields[1]), None);
    let color = int_try_parse(trim(fields[color_index]), None);
    let (Some(seconds), Some(raw_mode), Some(color)) = (seconds, raw_mode, color) else {
        return Ok(None);
    };
    let Some(mode) = mode_from_raw(raw_mode) else {
        return Ok(None);
    };
    let start_ms = clamp_ms(round(seconds * 1000.0)?);
    Ok(Some((start_ms, mode, argb_from_rgb(color))))
}

/// 文本来源：0 = 输入本身，1 = 解析器的字符串池（XML 文本 / JSON 转义串），
/// 2 = `toString()` 现算的串。
struct Texts<'a> {
    sources: [&'a [u16]; 3],
}

impl Texts<'_> {
    fn get(&self, r: TextRef) -> &[u16] {
        &self.sources[r.source as usize][r.start as usize..(r.start + r.len) as usize]
    }
}

fn sort_items(items: &mut [Item]) {
    danmaku_sort::dart_sort(items, &|a: &Item, b: &Item| a.start_ms.cmp(&b.start_ms));
}

fn finish(
    outcome: u32,
    error_code: u32,
    error_offset: u32,
    items: &[Item],
    texts: &Texts,
) -> DanmakuParse {
    DanmakuParse {
        outcome,
        error_code,
        error_offset,
        items: items
            .iter()
            .map(|it| {
                (
                    it.start_ms,
                    texts.get(it.text).to_vec(),
                    it.mode,
                    it.color_argb,
                )
            })
            .collect(),
    }
}

fn failure(outcome: u32) -> DanmakuParse {
    DanmakuParse {
        outcome,
        error_code: 0,
        error_offset: 0,
        items: Vec::new(),
    }
}

/// 子串在 [base] 里的偏移（[sub] 必须是 [base] 的切片）。
fn offset_in(base: &[u16], sub: &[u16]) -> u32 {
    ((sub.as_ptr() as usize - base.as_ptr() as usize) / 2) as u32
}

/// `parseBilibiliDanmakuXml`：语法 / 校验失败或数值非有限时 `outcome != 0` 且无条目
/// （旧实现整份返回空表）。
pub fn parse_bilibili_xml(input: &[u16]) -> DanmakuParse {
    let Some(doc) = danmaku_xml::parse_danmaku_xml(input) else {
        return failure(OUTCOME_SYNTAX_ERROR);
    };
    let mut items: Vec<Item> = Vec::new();
    for element in &doc.elements {
        let text = trim(&doc.text[element.text_start..element.text_end]);
        let Some(p) = element.p.as_deref() else {
            continue;
        };
        match item_from_parts(p, text, 3) {
            Err(NonFinite) => return failure(OUTCOME_NON_FINITE),
            Ok(None) => {}
            Ok(Some((start_ms, mode, color_argb))) => items.push(Item {
                start_ms,
                color_argb,
                mode,
                text: TextRef {
                    source: 1,
                    start: offset_in(&doc.text, text),
                    len: text.len() as u32,
                },
            }),
        }
    }
    sort_items(&mut items);
    let texts = Texts {
        sources: [input, &doc.text, &[]],
    };
    finish(OUTCOME_OK, 0, 0, &items, &texts)
}

/// 弹弹play 时间偏移：已算好的毫秒数，或 `(shiftSeconds * 1000)` 非有限（旧在线路径在
/// 形状校验之后、逐条转换之前 `.round()` 抛 `UnsupportedError`）。
#[derive(Clone, Copy, Debug)]
pub enum Shift {
    Ms(i64),
    NonFinite,
}

/// `jsonDecode` + 形状校验 + `dandanplayCommentsToDanmaku`。
pub fn parse_dandanplay_json(input: &[u16], shift: Shift) -> DanmakuParse {
    let doc = match danmaku_json::parse_json(input) {
        Ok(doc) => doc,
        Err(e) => {
            return DanmakuParse {
                outcome: OUTCOME_SYNTAX_ERROR,
                error_code: e.kind as u32,
                error_offset: e.offset as u32,
                items: Vec::new(),
            }
        }
    };
    let Node::Map { start, len } = doc.root() else {
        return failure(OUTCOME_SHAPE_ERROR);
    };
    let Some(Node::List {
        start: list_start,
        len: list_len,
    }) = doc.map_get(start, len, b"comments")
    else {
        return failure(OUTCOME_SHAPE_ERROR);
    };
    let shift_ms = match shift {
        Shift::Ms(ms) => ms,
        Shift::NonFinite => return failure(OUTCOME_NON_FINITE),
    };
    let mut computed: Vec<u16> = Vec::new();
    let mut items: Vec<Item> = Vec::new();
    for &row_id in doc.list(list_start, list_len) {
        match dandanplay_row(&doc, doc.node(row_id), input, &mut computed) {
            Err(NonFinite) => return failure(OUTCOME_NON_FINITE),
            Ok(None) => {}
            Ok(Some(mut item)) => {
                item.start_ms = clamp_ms(item.start_ms.wrapping_add(shift_ms));
                items.push(item);
            }
        }
    }
    sort_items(&mut items);
    let texts = Texts {
        sources: [input, doc_pool(&doc), &computed],
    };
    finish(OUTCOME_OK, 0, 0, &items, &texts)
}

fn doc_pool<'d>(doc: &'d JsonDoc<'_>) -> &'d [u16] {
    doc.pool_units()
}

/// `row['k1'] ?? row['k2'] ?? …`：第一个存在且不是 JSON null 的值。
fn first_non_null(doc: &JsonDoc, start: u32, len: u32, keys: &[&[u8]]) -> Option<Node> {
    keys.iter()
        .find_map(|key| match doc.map_get(start, len, key) {
            None | Some(Node::Null) => None,
            Some(node) => Some(node),
        })
}

/// `dandanplayCommentsToDanmaku` 的单行（未加 shift）。
fn dandanplay_row(
    doc: &JsonDoc,
    row: Node,
    input: &[u16],
    computed: &mut Vec<u16>,
) -> Result<Option<Item>, NonFinite> {
    let Node::Map { start, len } = row else {
        return Ok(None);
    };
    // (row['m'] ?? row['text'] ?? '').toString().trim()
    let text: TextRef = match first_non_null(doc, start, len, &[b"m", b"text"]) {
        None => return Ok(None),
        Some(Node::Str(r)) => {
            let units = doc.str_units(r);
            let trimmed = trim(units);
            let skipped = offset_in(units, trimmed);
            TextRef {
                source: if r.pooled { 1 } else { 0 },
                start: r.start + skipped,
                len: trimmed.len() as u32,
            }
        }
        Some(node) => {
            let from = computed.len();
            doc.write_dart_string(node, computed);
            let trimmed = trim(&computed[from..]);
            let skipped = offset_in(&computed[from..], trimmed) as usize;
            TextRef {
                source: 2,
                start: (from + skipped) as u32,
                len: trimmed.len() as u32,
            }
        }
    };
    if text.len == 0 {
        return Ok(None);
    }
    let text_units: &[u16] = match text.source {
        0 => &input[text.start as usize..(text.start + text.len) as usize],
        1 => &doc.pool_units()[text.start as usize..(text.start + text.len) as usize],
        _ => &computed[text.start as usize..(text.start + text.len) as usize],
    };
    let parsed = match doc.map_get(start, len, b"p") {
        Some(Node::Str(p)) => item_from_parts(doc.str_units(p), text_units, 2)?,
        _ => item_from_object(doc, start, len)?,
    };
    Ok(parsed.map(|(start_ms, mode, color_argb)| Item {
        start_ms,
        color_argb,
        mode,
        text,
    }))
}

/// `_itemFromObject`：返回 (start_ms, mode, color)。
fn item_from_object(
    doc: &JsonDoc,
    start: u32,
    len: u32,
) -> Result<Option<(i64, u32, u32)>, NonFinite> {
    let seconds = match first_non_null(doc, start, len, &[b"time", b"t", b"start"]) {
        Some(Node::Int(i)) => Some(i as f64),
        Some(Node::Double(d)) => Some(d),
        Some(Node::Str(r)) => double_try_parse(doc.str_units(r)),
        _ => None,
    };
    let Some(seconds) = seconds else {
        return Ok(None);
    };
    let mode = match first_non_null(doc, start, len, &[b"mode", b"type"]) {
        Some(Node::Int(i)) => mode_from_raw(i),
        Some(Node::Double(d)) => mode_from_raw(to_int(d)?),
        Some(Node::Str(r)) => mode_from_string(doc.str_units(r)),
        _ => Some(MODE_SCROLL),
    };
    let Some(mode) = mode else {
        return Ok(None);
    };
    let color = match doc.map_get(start, len, b"color") {
        Some(Node::Int(i)) => i,
        Some(Node::Double(d)) => to_int(d)?,
        _ => 0xFF_FFFF,
    };
    let start_ms = clamp_ms(round(seconds * 1000.0)?);
    Ok(Some((start_ms, mode, argb_from_rgb(color))))
}

/// 把 [DanmakuParse] 编成输出缓冲区（布局见模块注释）。
fn encode(parse: &DanmakuParse) -> Vec<u8> {
    let pool_len: usize = parse.items.iter().map(|it| it.1.len()).sum();
    let words = HEADER_WORDS + RECORD_WORDS * parse.items.len();
    let mut out = Vec::with_capacity(words * 4 + pool_len * 2);
    let word = |out: &mut Vec<u8>, v: u32| out.extend_from_slice(&v.to_ne_bytes());
    word(&mut out, parse.outcome);
    word(&mut out, parse.error_code);
    word(&mut out, parse.error_offset);
    word(&mut out, parse.items.len() as u32);
    word(&mut out, pool_len as u32);
    word(&mut out, 0);
    for (start_ms, text, mode, color) in &parse.items {
        word(&mut out, *start_ms as u32);
        word(&mut out, *color);
        word(&mut out, *mode);
        word(&mut out, text.len() as u32);
    }
    for (_, text, _, _) in &parse.items {
        for &unit in text {
            out.extend_from_slice(&unit.to_ne_bytes());
        }
    }
    out
}

/// FFI 公共校验：返回输入切片或状态码。
///
/// # Safety
/// 同各导出函数。
unsafe fn ffi_input<'a>(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> Result<&'a [u16], i32> {
    if out_ptr.is_null() || out_len.is_null() || (len > 0 && units.is_null()) {
        return Err(status::NULL_ARGUMENT);
    }
    // 偏移、长度在记录里是 u32；20 MiB 上限的 sidecar 远小于此。
    if len > u32::MAX as usize / 2 {
        return Err(status::INVALID_ARGUMENT);
    }
    Ok(if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(units, len)
    })
}

/// Bilibili XML 弹幕（`units[0..len]` 为 UTF-16 码元）。成功返回 [status::OK] 并把结果
/// 缓冲区写进 `*out_ptr` / `*out_len`（布局见模块注释，用 `ffc_free_bytes` 释放）；
/// XML 本身坏掉不是 FFI 错误，体现在 `outcome` 里。
///
/// # Safety
/// `out_ptr` / `out_len` 非空可写；`len > 0` 时 `units` 指向 `len` 个可读 `u16`。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_danmaku_bilibili_xml(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let input = match ffi_input(units, len, out_ptr, out_len) {
        Ok(input) => input,
        Err(code) => return code,
    };
    guard(|| {
        hand_over_bytes(encode(&parse_bilibili_xml(input)), out_ptr, out_len);
        status::OK
    })
}

/// 弹弹play JSON 弹幕。`shift_ms` 加到每条的 `start_ms` 上（int64 回绕后再 clamp 到
/// 0..=2^30，同 Dart）；`shift_non_finite != 0` 表示调用方的 `(shiftSeconds * 1000)`
/// 不是有限数，此时形状校验通过后报 `outcome = 3`（旧在线路径在同一时序点抛
/// `UnsupportedError`），`shift_ms` 被忽略。其余同 [ffc_parse_danmaku_bilibili_xml]。
///
/// # Safety
/// 同 [ffc_parse_danmaku_bilibili_xml]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_danmaku_dandanplay_json(
    units: *const u16,
    len: usize,
    shift_ms: i64,
    shift_non_finite: u8,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let input = match ffi_input(units, len, out_ptr, out_len) {
        Ok(input) => input,
        Err(code) => return code,
    };
    let shift = if shift_non_finite != 0 {
        Shift::NonFinite
    } else {
        Shift::Ms(shift_ms)
    };
    guard(|| {
        hand_over_bytes(
            encode(&parse_dandanplay_json(input, shift)),
            out_ptr,
            out_len,
        );
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn simple(p: &DanmakuParse) -> Vec<(i64, String, u32, u32)> {
        p.items
            .iter()
            .map(|(ms, t, m, c)| (*ms, String::from_utf16(t).unwrap(), *m, *c))
            .collect()
    }

    #[test]
    fn bilibili_sample() {
        let xml = "<i>\n  <d p=\"1.25,1,25,16777215,0,0,abc,1\">こんにちは &amp; テスト</d>\n  \
                   <d p=\"2.5,5,25,16711680,0,0,abc,2\">上固定</d>\n</i>\n";
        let got = parse_bilibili_xml(&u(xml));
        assert_eq!(got.outcome, OUTCOME_OK);
        assert_eq!(
            simple(&got),
            vec![
                (1250, "こんにちは & テスト".into(), MODE_SCROLL, 0xFFFF_FFFF),
                (2500, "上固定".into(), MODE_TOP, 0xFFFF_0000),
            ]
        );
    }

    #[test]
    fn bilibili_non_finite_time_empties_everything() {
        let got = parse_bilibili_xml(&u(
            "<i><d p=\"1,1,25,255\">ok</d><d p=\"Infinity,1,25,255\">x</d></i>",
        ));
        assert_eq!(got.outcome, OUTCOME_NON_FINITE);
        assert!(got.items.is_empty());
        // 模式非法时不会走到 round，不抛。
        let got = parse_bilibili_xml(&u(
            "<i><d p=\"1,1,25,255\">ok</d><d p=\"NaN,7,25,255\">x</d></i>",
        ));
        assert_eq!(got.outcome, OUTCOME_OK);
        assert_eq!(got.items.len(), 1);
    }

    #[test]
    fn dandanplay_tolerant_rows() {
        let json = r#"{"comments": [
            {"time": 3.25, "mode": 4, "color": 255, "text": "底"},
            {"time": "4.5", "type": "scroll", "text": "文字列時間"},
            {"time": null, "text": "bad"},
            {"time": 6, "mode": 7, "text": "positioned"},
            {"p": "1.00,5,255,100", "m": [1, 2.5, {"a": null}]},
            {"m": "", "text": "fallback?"},
            {"m": null, "text": " fb ", "t": 1}
        ]}"#;
        let got = parse_dandanplay_json(&u(json), Shift::Ms(-500));
        assert_eq!(got.outcome, OUTCOME_OK);
        assert_eq!(
            simple(&got),
            vec![
                // ≤ 33 条走插入排序（稳定），同毫秒保持原顺序。
                (500, "[1, 2.5, {a: null}]".into(), MODE_TOP, 0xFF00_00FF),
                (500, "fb".into(), MODE_SCROLL, 0xFFFF_FFFF),
                (2750, "底".into(), MODE_BOTTOM, 0xFF00_00FF),
                (4000, "文字列時間".into(), MODE_SCROLL, 0xFFFF_FFFF),
            ]
        );
    }

    #[test]
    fn dandanplay_outcomes() {
        assert_eq!(
            parse_dandanplay_json(&u("[]"), Shift::Ms(0)).outcome,
            OUTCOME_SHAPE_ERROR
        );
        assert_eq!(
            parse_dandanplay_json(&u("{\"comments\":{}}"), Shift::Ms(0)).outcome,
            OUTCOME_SHAPE_ERROR
        );
        assert_eq!(
            parse_dandanplay_json(&u("{\"comments\":[]}"), Shift::NonFinite).outcome,
            OUTCOME_NON_FINITE
        );
        assert_eq!(
            parse_dandanplay_json(&u("[]"), Shift::NonFinite).outcome,
            OUTCOME_SHAPE_ERROR
        );
        let bad = parse_dandanplay_json(&u("{\"comments\":[}"), Shift::Ms(0));
        assert_eq!(
            (bad.outcome, bad.error_code, bad.error_offset),
            (OUTCOME_SYNTAX_ERROR, 1, 13)
        );
        let nf = parse_dandanplay_json(
            &u(r#"{"comments":[{"m":"x","time":1,"color":1e400}]}"#),
            Shift::Ms(0),
        );
        assert_eq!(nf.outcome, OUTCOME_NON_FINITE);
    }

    #[test]
    fn ffi_roundtrip() {
        let units = u("<i><d p=\"1,4,25,255\">x</d></i>");
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe {
            ffc_parse_danmaku_bilibili_xml(units.as_ptr(), units.len(), &mut ptr, &mut len)
        };
        assert_eq!(rc, status::OK);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        let word = |i: usize| u32::from_ne_bytes(bytes[i * 4..i * 4 + 4].try_into().unwrap());
        assert_eq!((word(0), word(3), word(4)), (OUTCOME_OK, 1, 1));
        assert_eq!(
            (word(6), word(7), word(8), word(9)),
            (1000, 0xFF00_00FF, MODE_BOTTOM, 1)
        );
        assert_eq!(
            u16::from_ne_bytes(bytes[40..42].try_into().unwrap()),
            b'x' as u16
        );
        crate::ffc_free_bytes(ptr, len);
        let rc = unsafe {
            ffc_parse_danmaku_dandanplay_json(std::ptr::null(), 1, 0, 0, &mut ptr, &mut len)
        };
        assert_eq!(rc, status::NULL_ARGUMENT);
    }
}
