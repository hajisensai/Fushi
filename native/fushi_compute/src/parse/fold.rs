//! `ffc_parse_fold_*`：有声书 / 阅读器匹配坐标系的日文正文归一化（原 Dart
//! `AudioTextNormalizer.foldCodePoint` / `normalize` / `normalizeWithOffsets`，
//! packages/fushi_audio/lib/src/matching/audio_text_normalizer.dart）。
//!
//! 口径（逐码点、上下文无关）：
//! 1. 白名单：只保留假名 / 汉字 / CJK 扩展 / 字母数字（[is_keepable]），其余丢弃；
//! 2. 全角 ASCII（U+FF01..U+FF5E）→ 半角（白名单内实际只有全角字母数字）；
//! 3. A-Z → a-z（含全角大写折成半角后的）；
//! 4. 半角片假名 U+FF66..U+FF9D → 全角片假名（查 [HALFWIDTH_KATAKANA_TO_FULLWIDTH]）；
//! 5. 片假名基本区 U+30A1..U+30F6 → 平假名（-0x60）。
//!
//! 这是 sasayaki 匹配坐标系：任何输出变化都会改变既有匹配 / 高亮落点。阅读器注入 JS
//! （`reader_pagination_scripts.dart` 的 `foldCodePoint`）持有同口径的 JS 副本，由
//! fushi/test 下的 parity 测试对拍。逐码点输出由 [tests::fold_matches_dart_digest]
//! 钉住旧 Dart 实现生成的 FNV-1a 摘要。
//!
//! 输入是 UTF-16 码元，解码规则与 Dart `String.runes` 一致：合法代理对合成一个码点，
//! 孤立代理按其码元值本身折叠（落在白名单外 → 丢弃）。BMP 码点只会折成 BMP 码点，补充平面
//! 码点只会原样保留或丢弃，所以输出码元数永远不超过输入码元数，且被保留码点的输出宽度
//! 等于输入宽度。

use crate::parse::{study_char_class, StudyCharClass};
use crate::{guard, status};

/// 半角片假名 U+FF66..U+FF9D → 全角片假名（索引 = 码点 - 0xFF66，56 项）。
/// 与 fushi_core `kHalfwidthKatakanaToFullwidth` 逐项一致。
const HALFWIDTH_KATAKANA_TO_FULLWIDTH: [u16; 56] = [
    // ｦｧｨｩｪｫｬｭ
    0x30F2, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30E3, 0x30E5,
    // ｮｯｰｱｲｳｴｵ
    0x30E7, 0x30C3, 0x30FC, 0x30A2, 0x30A4, 0x30A6, 0x30A8, 0x30AA,
    // ｶｷｸｹｺｻｼｽ
    0x30AB, 0x30AD, 0x30AF, 0x30B1, 0x30B3, 0x30B5, 0x30B7, 0x30B9,
    // ｾｿﾀﾁﾂﾃﾄﾅ
    0x30BB, 0x30BD, 0x30BF, 0x30C1, 0x30C4, 0x30C6, 0x30C8, 0x30CA,
    // ﾆﾇﾈﾉﾊﾋﾌﾍ
    0x30CB, 0x30CC, 0x30CD, 0x30CE, 0x30CF, 0x30D2, 0x30D5, 0x30D8,
    // ﾎﾏﾐﾑﾒﾓﾔﾕ
    0x30DB, 0x30DE, 0x30DF, 0x30E0, 0x30E1, 0x30E2, 0x30E4, 0x30E6,
    // ﾖﾗﾘﾙﾚﾛﾜﾝ
    0x30E8, 0x30E9, 0x30EA, 0x30EB, 0x30EC, 0x30ED, 0x30EF, 0x30F3,
];

/// 白名单（与 JS `__fushiIsSkippable` / `isMatchableChar` 严格镜像）。
#[inline]
fn is_keepable(c: u32) -> bool {
    matches!(c,
        0x30..=0x39 // 0-9
        | 0x41..=0x5A // A-Z
        | 0x61..=0x7A // a-z
        | 0x3005..=0x3007 // 々〆〇
        | 0x3041..=0x3096 // ひらがな
        | 0x309D..=0x309F // ゝゞゟ
        | 0x30A1..=0x30FA // カタカナ
        | 0x30FC..=0x30FF // ーヽヾヿ
        | 0x3400..=0x4DBF // CJK 拡張 A
        | 0x4E00..=0x9FFF // CJK 統合漢字
        | 0x25CB | 0x25EF // ○◯
        | 0x303B // 〻
        | 0x2E80..=0x2EFF // CJK 部首補助
        | 0x2F00..=0x2FDF // 康煕部首
        | 0xF900..=0xFAFF // CJK 互換漢字
        | 0x20000..=0x2A6DF // CJK 拡張 B
        | 0x2A700..=0x2EBE0 // CJK 拡張 C-F
        | 0x2F800..=0x2FA1F // CJK 互換漢字補助
        | 0x30000..=0x323AF // CJK 拡張 G-H
        | 0xFF10..=0xFF19 // ０-９
        | 0xFF21..=0xFF3A // Ａ-Ｚ
        | 0xFF41..=0xFF5A // ａ-ｚ
        | 0xFF66..=0xFF9D // 半角カタカナ
    )
}

/// 单码点折叠：不在白名单返回 `None`，否则返回归一化后的码点。
#[inline]
pub fn fold_code_point(cp: u32) -> Option<u32> {
    if !is_keepable(cp) {
        return None;
    }
    let mut out = cp;
    if (0xFF01..=0xFF5E).contains(&out) {
        out -= 0xFEE0;
    }
    if (0x41..=0x5A).contains(&out) {
        out += 0x20;
    }
    if (0xFF66..=0xFF9D).contains(&out) {
        out = u32::from(HALFWIDTH_KATAKANA_TO_FULLWIDTH[(out - 0xFF66) as usize]);
    }
    if (0x30A1..=0x30F6).contains(&out) {
        out -= 0x60;
    }
    Some(out)
}

/// 归一化 [units]：折叠结果写进 [out]，若给了 [starts] 则同时写每个输出码元对应输入码点的
/// 起始码元下标（补充平面码点的两个输出码元写同一个下标）。返回输出码元数。
///
/// [out] / [starts] 至少 `units.len()` 长（输出不会更长）。
pub fn fold_utf16(units: &[u16], out: &mut [u16], mut starts: Option<&mut [u32]>) -> usize {
    let len = units.len();
    let mut i = 0usize;
    let mut n = 0usize;
    while i < len {
        let unit = u32::from(units[i]);
        let mut cp = unit;
        let mut width = 1usize;
        if (0xD800..=0xDBFF).contains(&unit) && i + 1 < len {
            let low = u32::from(units[i + 1]);
            if (0xDC00..=0xDFFF).contains(&low) {
                cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                width = 2;
            }
        }
        if let Some(folded) = fold_code_point(cp) {
            if folded > 0xFFFF {
                let v = folded - 0x10000;
                out[n] = (0xD800 + (v >> 10)) as u16;
                out[n + 1] = (0xDC00 + (v & 0x3FF)) as u16;
                if let Some(s) = starts.as_deref_mut() {
                    s[n] = i as u32;
                    s[n + 1] = i as u32;
                }
                n += 2;
            } else {
                out[n] = folded as u16;
                if let Some(s) = starts.as_deref_mut() {
                    s[n] = i as u32;
                }
                n += 1;
            }
        }
        i += width;
    }
    n
}

/// 整段归一化：读 `units[0..len]`，写 `out[0..*out_len]`；`starts` 非空时同时写每个输出
/// 码元对应输入码点的起始 UTF-16 下标（调用方据此还原原文区间）。
///
/// `out` / `starts` 的容量 `cap` 必须 ≥ `len`（输出永远不比输入长），否则返回
/// `BUFFER_TOO_SMALL`、不写任何东西。`len == 0` 时指针可为空。
///
/// # Safety
/// `out_len` 非空可写；`len > 0` 时 `units` 指向 `len` 个可读 `u16`，`out` 指向 `cap` 个
/// 可写 `u16`，`starts`（若非空）指向 `cap` 个可写 `u32`；三者互不重叠。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_fold_audio_utf16(
    units: *const u16,
    len: usize,
    out: *mut u16,
    starts: *mut u32,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() || (len > 0 && (units.is_null() || out.is_null())) {
        return status::NULL_ARGUMENT;
    }
    if cap < len {
        return status::BUFFER_TOO_SMALL;
    }
    guard(|| {
        if len == 0 {
            *out_len = 0;
            return status::OK;
        }
        let input = std::slice::from_raw_parts(units, len);
        let output = std::slice::from_raw_parts_mut(out, len);
        let starts = if starts.is_null() {
            None
        } else {
            Some(std::slice::from_raw_parts_mut(starts, len))
        };
        *out_len = fold_utf16(input, output, starts);
        status::OK
    })
}

/// 阅读器有声书坐标（原 Dart `ReaderAudioPositionIndex.fromChapterHtml` 的逐节点循环）：
/// 一次走完 [fold_utf16] 的归一化，并给每个输出码元写它所在输入码点的**学习单位起点**
/// （`offsets`）与**终点**（`ends`，起点 + 该码点是否收尾一个单位），返回输出码元数，
/// 学习单位总数写进 `total`。
///
/// 学习单位按 [study_char_class] 分类、从右往左判收尾：每码点计 1 的码点自己收尾；
/// 连续串的最后一个码点收尾（右边第一个非透明码点不是连续串，或到了文本末尾）；透明码点
/// 不更新「右边的类别」。调用方把各 DOM 文本节点用 U+0000 连接后整段传进来：U+0000 是
/// 断词码点、不在归一化白名单里，所以整段一次扫描与逐节点各扫一次（节点末尾右边按断词处理、
/// 码点按节点各自 `runes` 解码）结果相同。
pub fn fold_study_utf16(
    units: &[u16],
    out: &mut [u16],
    offsets: &mut [u32],
    ends: &mut [u32],
) -> (usize, u32) {
    let len = units.len();
    // (码点, 宽度, 是否收尾)
    let mut runes: Vec<(u32, u8, bool)> = Vec::with_capacity(len);
    let mut i = 0usize;
    while i < len {
        let unit = u32::from(units[i]);
        let mut cp = unit;
        let mut width = 1u8;
        if (0xD800..=0xDBFF).contains(&unit) && i + 1 < len {
            let low = u32::from(units[i + 1]);
            if (0xDC00..=0xDFFF).contains(&low) {
                cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                width = 2;
            }
        }
        runes.push((cp, width, false));
        i += usize::from(width);
    }
    let mut next = StudyCharClass::Breaker;
    for r in runes.iter_mut().rev() {
        let class = study_char_class(r.0);
        r.2 = match class {
            StudyCharClass::PerCodePoint => true,
            StudyCharClass::Word => next != StudyCharClass::Word,
            _ => false,
        };
        if class != StudyCharClass::Transparent {
            next = class;
        }
    }
    let mut study = 0u32;
    let mut n = 0usize;
    for &(cp, _, end) in &runes {
        let study_end = study + u32::from(end);
        if let Some(folded) = fold_code_point(cp) {
            if folded > 0xFFFF {
                let v = folded - 0x10000;
                out[n] = (0xD800 + (v >> 10)) as u16;
                out[n + 1] = (0xDC00 + (v & 0x3FF)) as u16;
                offsets[n] = study;
                offsets[n + 1] = study;
                ends[n] = study_end;
                ends[n + 1] = study_end;
                n += 2;
            } else {
                out[n] = folded as u16;
                offsets[n] = study;
                ends[n] = study_end;
                n += 1;
            }
        }
        study = study_end;
    }
    (n, study)
}

/// [fold_study_utf16] 的 C ABI：读 `units[0..len]`，写 `out` / `offsets` / `ends` 的前
/// `*out_len` 项与学习单位总数 `*total`。三块输出容量 `cap` 必须 ≥ `len`（输出不比输入长），
/// 否则返回 `BUFFER_TOO_SMALL`、不写任何东西。`len == 0` 时指针可为空。
///
/// # Safety
/// `out_len` / `total` 非空可写；`len > 0` 时 `units` 指向 `len` 个可读 `u16`，`out` 指向
/// `cap` 个可写 `u16`，`offsets` / `ends` 各指向 `cap` 个可写 `u32`；互不重叠。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_fold_audio_study_utf16(
    units: *const u16,
    len: usize,
    out: *mut u16,
    offsets: *mut u32,
    ends: *mut u32,
    cap: usize,
    out_len: *mut usize,
    total: *mut u32,
) -> i32 {
    if out_len.is_null()
        || total.is_null()
        || (len > 0 && (units.is_null() || out.is_null() || offsets.is_null() || ends.is_null()))
    {
        return status::NULL_ARGUMENT;
    }
    if cap < len {
        return status::BUFFER_TOO_SMALL;
    }
    guard(|| {
        if len == 0 {
            *out_len = 0;
            *total = 0;
            return status::OK;
        }
        let (n, study) = fold_study_utf16(
            std::slice::from_raw_parts(units, len),
            std::slice::from_raw_parts_mut(out, len),
            std::slice::from_raw_parts_mut(offsets, len),
            std::slice::from_raw_parts_mut(ends, len),
        );
        *out_len = n;
        *total = study;
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 旧 Dart `AudioTextNormalizer.foldCodePoint` 对 0..=0x10FFFF 每个码点的结果
    /// （丢弃记 -1）按小端 i32 四字节喂 FNV-1a 32 位得到的摘要；Dart 侧回归测试
    /// （packages/fushi_audio/test/matching/audio_text_normalizer_native_test.dart）钉同一个值。
    const FOLD_FNV1A: u32 = 0x078e_ced4;

    fn fnv_i32(hash: &mut u32, v: i32) {
        for b in v.to_le_bytes() {
            *hash ^= u32::from(b);
            *hash = hash.wrapping_mul(0x0100_0193);
        }
    }

    /// 原 Dart `ReaderAudioPositionIndex.fromChapterHtml` 的逐节点算法（每个文本节点各自
    /// 解码、各自从右往左判收尾，节点末尾右边按断词）。
    fn study_reference(nodes: &[Vec<u16>]) -> (Vec<u16>, Vec<u32>, Vec<u32>, u32) {
        let (mut text, mut offsets, mut ends) = (Vec::new(), Vec::new(), Vec::new());
        let mut study = 0u32;
        for node in nodes {
            let runes: Vec<u32> = char::decode_utf16(node.iter().copied())
                .map(|r| r.map_or_else(|e| u32::from(e.unpaired_surrogate()), u32::from))
                .collect();
            let kinds: Vec<StudyCharClass> = runes.iter().map(|&c| study_char_class(c)).collect();
            let mut is_end = vec![false; runes.len()];
            let mut next = StudyCharClass::Breaker;
            for k in (0..runes.len()).rev() {
                is_end[k] = kinds[k] == StudyCharClass::PerCodePoint
                    || (kinds[k] == StudyCharClass::Word && next != StudyCharClass::Word);
                if kinds[k] != StudyCharClass::Transparent {
                    next = kinds[k];
                }
            }
            for (k, &cp) in runes.iter().enumerate() {
                let end = study + u32::from(is_end[k]);
                if let Some(f) = fold_code_point(cp) {
                    if f > 0xFFFF {
                        let v = f - 0x10000;
                        text.push((0xD800 + (v >> 10)) as u16);
                        text.push((0xDC00 + (v & 0x3FF)) as u16);
                        offsets.extend([study, study]);
                        ends.extend([end, end]);
                    } else {
                        text.push(f as u16);
                        offsets.push(study);
                        ends.push(end);
                    }
                }
                study = end;
            }
        }
        (text, offsets, ends, study)
    }

    #[test]
    fn separator_is_a_breaker() {
        assert_eq!(study_char_class(0), StudyCharClass::Breaker);
        assert_eq!(fold_code_point(0), None);
    }

    #[test]
    fn fold_study_matches_per_node_reference() {
        let alphabet: Vec<u16> = "漢字かなカナｶﾅabcXYZ１２ ,。、'\u{301}\u{200d}é"
            .encode_utf16()
            .chain([
                0xD842, 0xDFB7, 0xD800, 0xDC00, 0xD83D, 0xDE00, 0x0E01, 0x0E31,
            ])
            .collect();
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        let mut rand = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..3000 {
            let node_count = rand() % 6;
            let nodes: Vec<Vec<u16>> = (0..node_count)
                .map(|_| {
                    let n = rand() % 12;
                    (0..n)
                        .map(|_| alphabet[(rand() % alphabet.len() as u64) as usize])
                        .collect()
                })
                .collect();
            let mut joined: Vec<u16> = Vec::new();
            for (k, node) in nodes.iter().enumerate() {
                if k > 0 {
                    joined.push(0);
                }
                joined.extend_from_slice(node);
            }
            let (text, offsets, ends, total) = study_reference(&nodes);
            let mut out = vec![0u16; joined.len()];
            let mut o = vec![0u32; joined.len()];
            let mut e = vec![0u32; joined.len()];
            let (n, study) = fold_study_utf16(&joined, &mut out, &mut o, &mut e);
            assert_eq!(&out[..n], &text[..], "{nodes:?}");
            assert_eq!(&o[..n], &offsets[..], "{nodes:?}");
            assert_eq!(&e[..n], &ends[..], "{nodes:?}");
            assert_eq!(study, total, "{nodes:?}");
            let mut plain = vec![0u16; joined.len()];
            assert_eq!(fold_utf16(&joined, &mut plain, None), n);
            assert_eq!(&plain[..n], &out[..n]);
        }
    }

    #[test]
    fn fold_study_ffi_entry_point() {
        let units: Vec<u16> = "ア、ab c".encode_utf16().collect();
        let mut out = vec![0u16; units.len()];
        let mut o = vec![0u32; units.len()];
        let mut e = vec![0u32; units.len()];
        let (mut n, mut total) = (99usize, 99u32);
        let rc = unsafe {
            ffc_parse_fold_audio_study_utf16(
                units.as_ptr(),
                units.len(),
                out.as_mut_ptr(),
                o.as_mut_ptr(),
                e.as_mut_ptr(),
                units.len(),
                &mut n,
                &mut total,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(&out[..n], &[0x3042, b'a' as u16, b'b' as u16, b'c' as u16]);
        assert_eq!(&o[..n], &[0, 1, 1, 2]);
        assert_eq!(&e[..n], &[1, 1, 2, 3]);
        assert_eq!(total, 3);
        let rc = unsafe {
            ffc_parse_fold_audio_study_utf16(
                units.as_ptr(),
                units.len(),
                out.as_mut_ptr(),
                o.as_mut_ptr(),
                e.as_mut_ptr(),
                units.len() - 1,
                &mut n,
                &mut total,
            )
        };
        assert_eq!(rc, status::BUFFER_TOO_SMALL);
        let rc = unsafe {
            ffc_parse_fold_audio_study_utf16(
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                &mut n,
                &mut total,
            )
        };
        assert_eq!((rc, n, total), (status::OK, 0, 0));
    }

    #[test]
    fn fold_matches_dart_digest() {
        let mut hash: u32 = 0x811c_9dc5;
        for cp in 0..0x110000u32 {
            let v = fold_code_point(cp).map_or(-1, |c| c as i32);
            fnv_i32(&mut hash, v);
        }
        assert_eq!(hash, FOLD_FNV1A, "got {hash:#010x}");
    }

    fn fold_str(s: &str) -> (String, Vec<u32>) {
        let units: Vec<u16> = s.encode_utf16().collect();
        let mut out = vec![0u16; units.len()];
        let mut starts = vec![0u32; units.len()];
        let n = fold_utf16(&units, &mut out, Some(&mut starts));
        out.truncate(n);
        starts.truncate(n);
        (String::from_utf16(&out).unwrap(), starts)
    }

    #[test]
    fn samples() {
        assert_eq!(
            fold_str("「カタカナ、ＡＢＣ」ｶﾀｶﾅabcDEF１２３").0,
            "かたかなabcかたかなabcdef123"
        );
        assert_eq!(fold_str("ヴァー・ヽヾ").0, "ゔぁーヽヾ");
        let (text, starts) = fold_str("a𠮷、b");
        assert_eq!(text, "a𠮷b");
        assert_eq!(starts, vec![0, 1, 1, 4]);
        // 不在白名单的补充平面码点丢弃。
        assert_eq!(fold_str("😀x").0, "x");
    }

    #[test]
    fn lone_surrogates_are_dropped() {
        let units = [b'a' as u16, 0xD800, b'b' as u16, 0xDC00, 0xD840];
        let mut out = [0u16; 5];
        let mut starts = [0u32; 5];
        let n = fold_utf16(&units, &mut out, Some(&mut starts));
        assert_eq!(&out[..n], &[b'a' as u16, b'b' as u16]);
        assert_eq!(&starts[..n], &[0, 2]);
    }

    #[test]
    fn ffi_entry_point() {
        let units: Vec<u16> = "ア、b".encode_utf16().collect();
        let mut out = vec![0u16; 3];
        let mut starts = vec![0u32; 3];
        let mut n = 99usize;
        let rc = unsafe {
            ffc_parse_fold_audio_utf16(
                units.as_ptr(),
                units.len(),
                out.as_mut_ptr(),
                starts.as_mut_ptr(),
                3,
                &mut n,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(n, 2);
        assert_eq!(&out[..2], &[0x3042, b'b' as u16]);
        assert_eq!(&starts[..2], &[0, 2]);
        let rc = unsafe {
            ffc_parse_fold_audio_utf16(
                units.as_ptr(),
                units.len(),
                out.as_mut_ptr(),
                std::ptr::null_mut(),
                2,
                &mut n,
            )
        };
        assert_eq!(rc, status::BUFFER_TOO_SMALL);
        let rc = unsafe {
            ffc_parse_fold_audio_utf16(
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                &mut n,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(n, 0);
        let rc = unsafe {
            ffc_parse_fold_audio_utf16(
                std::ptr::null(),
                1,
                out.as_mut_ptr(),
                std::ptr::null_mut(),
                3,
                &mut n,
            )
        };
        assert_eq!(rc, status::NULL_ARGUMENT);
    }
}
