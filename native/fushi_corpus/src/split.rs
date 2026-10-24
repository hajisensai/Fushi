//! 句子切分：一段正文（一章 / 一段字幕文本）→ 句子区间（UTF-16 码元偏移）。
//!
//! 不分语言：句末标点按 Unicode 各文字的通用写法一张表（中日 `。！？`、西文 `.!?`、
//! 阿拉伯 `؟`、天城文 `।`、埃塞俄比亚 `።`、高棉 `។`、缅甸 `။`…），换行是硬断句。
//! 西文句点只在后面跟空白 / 收尾标点 / 文末时才算句末（`3.14`、`e.g.x` 不断）。
//! 句末标点后紧跟的收尾引号 / 括号并进本句（`「…。」`）。过长的句子（> `max_units`）
//! 先在逗号类标点处断，没有就硬切——索引只拿来当例句，几百字的一段话当例句没有意义，
//! 但内容不能丢（每一段都要能被搜到）。没有任何字母 / 数字的段（纯标点、空白）丢弃。

/// 一个句子：`[start, end)`，UTF-16 码元偏移（调用方是 Dart 字符串）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub end: u32,
}

fn is_terminator(c: char) -> bool {
    matches!(
        c,
        '。' | '｡' | '！' | '？' | '!' | '?' | '…' | '‥' | '؟' | '۔' | '।' | '॥' | '።' | '፧' | '។' | '៕' | '။'
            | '‼' | '⁇' | '⁈' | '⁉'
    )
}

fn is_hard_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}' | '\u{85}')
}

fn is_closer(c: char) -> bool {
    matches!(
        c,
        '」' | '』' | '）' | ')' | '】' | '］' | ']' | '》' | '〉' | '〕' | '〙' | '〛' | '｝' | '}' | '"' | '\''
            | '”' | '’' | '»' | '›' | '｣'
    )
}

fn is_soft_break(c: char) -> bool {
    matches!(c, '、' | '，' | ',' | '；' | ';' | '：' | ':' | '،' | '؛')
}

fn is_content(c: char) -> bool {
    c.is_alphanumeric()
}

struct Unit {
    ch: char,
    /// 本码点的 UTF-16 起点。
    at: u32,
}

/// 切分 [text]；`max_units` = 单句最多多少个 UTF-16 码元（0 = 不限）。
pub fn split_sentences(text: &str, max_units: u32) -> Vec<Span> {
    let mut units: Vec<Unit> = Vec::with_capacity(text.len());
    let mut at = 0u32;
    for ch in text.chars() {
        units.push(Unit { ch, at });
        at += ch.len_utf16() as u32;
    }
    let total = at;
    let mut out = Vec::new();
    let mut start_idx = 0usize; // 当前句的第一个码点下标
    let mut i = 0usize;
    while i < units.len() {
        let c = units[i].ch;
        let mut end_idx: Option<usize> = None; // 句子的最后一个码点（含）
        let mut next_idx = i + 1;
        if is_hard_break(c) {
            // 换行本身不属于句子。
            emit(&units, total, start_idx, i, max_units, &mut out);
            start_idx = i + 1;
            i += 1;
            continue;
        } else if is_terminator(c) {
            let mut j = i + 1;
            while j < units.len() && (is_terminator(units[j].ch) || units[j].ch == '.') {
                j += 1;
            }
            while j < units.len() && is_closer(units[j].ch) {
                j += 1;
            }
            end_idx = Some(j - 1);
            next_idx = j;
        } else if c == '.' {
            let mut j = i + 1;
            while j < units.len() && units[j].ch == '.' {
                j += 1;
            }
            while j < units.len() && is_closer(units[j].ch) {
                j += 1;
            }
            let followed_by_break =
                j >= units.len() || units[j].ch.is_whitespace() || is_hard_break(units[j].ch);
            let decimal = i > 0
                && units[i - 1].ch.is_ascii_digit()
                && i + 1 < units.len()
                && units[i + 1].ch.is_ascii_digit();
            if followed_by_break && !decimal {
                end_idx = Some(j - 1);
                next_idx = j;
            }
        }
        if let Some(end) = end_idx {
            emit(&units, total, start_idx, end + 1, max_units, &mut out);
            start_idx = next_idx;
            i = next_idx;
        } else {
            i += 1;
        }
    }
    emit(&units, total, start_idx, units.len(), max_units, &mut out);
    out
}

/// 码点区间 `[from, to)` 去首尾空白后成句；过长的按 [is_soft_break] / 硬切再拆。
fn emit(units: &[Unit], total: u32, mut from: usize, mut to: usize, max_units: u32, out: &mut Vec<Span>) {
    while from < to && units[from].ch.is_whitespace() {
        from += 1;
    }
    while to > from && units[to - 1].ch.is_whitespace() {
        to -= 1;
    }
    if from >= to {
        return;
    }
    let pos = |idx: usize| -> u32 {
        if idx < units.len() {
            units[idx].at
        } else {
            total
        }
    };
    if max_units > 0 && pos(to) - pos(from) > max_units {
        // 从 from 起找不超过上限的最后一个软断点。
        let limit = pos(from) + max_units;
        let mut cut: Option<usize> = None;
        let mut k = from + 1;
        while k < to && pos(k) <= limit {
            if is_soft_break(units[k - 1].ch) {
                cut = Some(k);
            }
            k += 1;
        }
        let cut = cut.unwrap_or_else(|| {
            // 硬切：落在上限处（不切开代理对：按码点下标走）。
            let mut c = from + 1;
            while c < to && pos(c + 1) <= limit {
                c += 1;
            }
            c.max(from + 1)
        });
        emit(units, total, from, cut, max_units, out);
        emit(units, total, cut, to, max_units, out);
        return;
    }
    if !units[from..to].iter().any(|u| is_content(u.ch)) {
        return;
    }
    out.push(Span { start: pos(from), end: pos(to) });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(text: &str, max: u32) -> Vec<String> {
        let u16: Vec<u16> = text.encode_utf16().collect();
        split_sentences(text, max)
            .into_iter()
            .map(|s| String::from_utf16(&u16[s.start as usize..s.end as usize]).unwrap())
            .collect()
    }

    #[test]
    fn japanese_with_quotes() {
        assert_eq!(
            texts("「行こう。」と彼は言った。雨だ！本当？", 0),
            vec!["「行こう。」", "と彼は言った。", "雨だ！", "本当？"]
        );
    }

    #[test]
    fn latin_period_rules() {
        assert_eq!(
            texts("Pi is 3.14 today. Really?! Yes... \"Fine.\" Next", 0),
            vec!["Pi is 3.14 today.", "Really?!", "Yes...", "\"Fine.\"", "Next"]
        );
    }

    #[test]
    fn hard_breaks_and_punctuation_only() {
        assert_eq!(texts("一行目\n\n――\n二行目", 0), vec!["一行目", "二行目"]);
    }

    #[test]
    fn other_scripts() {
        assert_eq!(texts("كيف حالك؟ أنا بخير", 0), vec!["كيف حالك؟", "أنا بخير"]);
        assert_eq!(texts("यह है। वह है।", 0), vec!["यह है।", "वह है।"]);
    }

    #[test]
    fn long_sentence_cut_at_soft_break_then_hard() {
        let s = "あいうえお、かきくけこ、さしすせそ";
        assert_eq!(texts(s, 8), vec!["あいうえお、", "かきくけこ、", "さしすせそ"]);
        assert_eq!(texts("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
    }

    #[test]
    fn utf16_offsets_with_supplementary_plane() {
        let spans = split_sentences("𠮷野家。好き。", 0);
        assert_eq!(spans, vec![Span { start: 0, end: 5 }, Span { start: 5, end: 8 }]);
    }
}
