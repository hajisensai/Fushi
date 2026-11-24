//! 正文内联读音 → 音节 ruby：LRC / 纯文本歌词（LRCLIB 等）常把读音直接写在正文括号里，
//! 如「彗星(すいせい)の停留所(バスストップ)で」。
//!
//! 判据收得很严（拍板台 AG4dD0xUhE 方案 a）：**连续汉字（可含 `々` `ヶ`）紧跟半角或全角左括号、
//! 括号里全是平假名 / 片假名（含 `ー`）、同型右括号收尾**，才把括号内容挂成这串汉字的 ruby 并从
//! 正文删掉括号；其余括号（`(woo)`、英文、汉字假名混写、嵌套、汉字与括号间有空格、半角全角
//! 混配）一律原样保留。
//!
//! 读音来自歌词源文件本身，不是机器推断——属于「来源自带的 ruby」，不是自动注音
//! （见 `docs/agent/feature-blacklist.md`）。
//!
//! 汉字串跨了几个音节（ESLyric 逐字 LRC）就并成一个音节（起点取第一个、终点取最后一个），
//! 与 QRC `[kana:]` 注音轨的挂法一致；一个音节被拆成几段时各段共享原起点，由调用方在行终点
//! 已知后用 [super::model::spread_shared_starts] 按字数平分。

use super::model::*;

fn is_kanji(c: char) -> bool {
    matches!(c,
        '\u{3005}' // 々
        | '\u{30F6}' // ヶ
        | '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{20000}'..='\u{3FFFF}')
}

fn is_kana(c: char) -> bool {
    matches!(c,
        '\u{3041}'..='\u{3096}' // 平假名（含小写）
        | '\u{309D}'..='\u{309E}' // ゝゞ
        | '\u{30A1}'..='\u{30FA}' // 片假名（含小写、ヴヵヶ）
        | '\u{30FC}'..='\u{30FE}') // ー ヽヾ
}

fn closing(c: char) -> Option<char> {
    match c {
        '(' => Some(')'),
        '（' => Some('）'),
        _ => None,
    }
}

/// 一处命中：`chars[kanji_start..paren_open]` 是汉字串，`chars[paren_open+1..paren_close]` 是读音。
struct Hit {
    kanji_start: usize,
    paren_open: usize,
    paren_close: usize,
}

fn find_hits(chars: &[char]) -> Vec<Hit> {
    let mut hits = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !is_kanji(chars[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && is_kanji(chars[i]) {
            i += 1;
        }
        let Some(close) = chars.get(i).copied().and_then(closing) else {
            continue;
        };
        let open = i;
        let mut j = open + 1;
        while j < chars.len() && is_kana(chars[j]) {
            j += 1;
        }
        if j > open + 1 && chars.get(j) == Some(&close) {
            hits.push(Hit {
                kanji_start: start,
                paren_open: open,
                paren_close: j,
            });
            i = j + 1;
        }
    }
    hits
}

/// 把一行里的「漢字(かな)」改写成 ruby 音节。行里已有 ruby（来源结构化注音）不动。
/// 返回是否改了。
pub fn apply(line: &mut Line) -> bool {
    if line.syllables.iter().any(|s| s.ruby.is_some()) {
        return false;
    }
    // 逐字记下所属音节。
    let mut chars: Vec<char> = Vec::new();
    let mut owner: Vec<usize> = Vec::new();
    for (k, s) in line.syllables.iter().enumerate() {
        for c in s.text.chars() {
            chars.push(c);
            owner.push(k);
        }
    }
    let hits = find_hits(&chars);
    if hits.is_empty() {
        return false;
    }

    let old = std::mem::take(&mut line.syllables);
    let mut out: Vec<Syllable> = Vec::with_capacity(old.len() + hits.len() * 2);
    // 普通字：同一原音节的连续字并成一段，起止沿用原音节。
    let push_plain = |out: &mut Vec<Syllable>, c: char, k: usize, fresh: &mut bool| {
        if !*fresh {
            if let Some(last) = out.last_mut() {
                last.text.push(c);
                return;
            }
        }
        let src = &old[k];
        let mut s = Syllable::new(c.to_string(), src.start_ms, src.end_ms);
        s.fill = src.fill;
        out.push(s);
        *fresh = false;
    };
    let mut hit_iter = hits.iter().peekable();
    let mut i = 0;
    let mut prev_owner: Option<usize> = None;
    let mut fresh = true;
    while i < chars.len() {
        if let Some(h) = hit_iter.next_if(|h| h.kanji_start == i) {
            let first = &old[owner[h.kanji_start]];
            let last = &old[owner[h.paren_close]];
            let mut s = Syllable::new(
                chars[h.kanji_start..h.paren_open]
                    .iter()
                    .collect::<String>(),
                first.start_ms,
                last.end_ms,
            );
            s.fill = first.fill;
            s.ruby = Some(chars[h.paren_open + 1..h.paren_close].iter().collect());
            out.push(s);
            i = h.paren_close + 1;
            // 括号后面的字即便同属一个原音节也另起一段（不能并进 ruby 音节）。
            fresh = true;
            prev_owner = None;
            continue;
        }
        if prev_owner != Some(owner[i]) {
            fresh = true;
        }
        prev_owner = Some(owner[i]);
        push_plain(&mut out, chars[i], owner[i], &mut fresh);
        i += 1;
    }
    line.syllables = out;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rubies(l: &Line) -> Vec<(&str, Option<&str>)> {
        l.syllables
            .iter()
            .map(|s| (s.text.as_str(), s.ruby.as_deref()))
            .collect()
    }

    fn applied(text: &str) -> Line {
        let mut l = Line::whole(text, 1000, 0);
        apply(&mut l);
        l
    }

    #[test]
    fn hiragana_and_katakana_readings_half_and_full_width() {
        let l = applied("彗星(すいせい)の停留所（バスストップ）で");
        assert_eq!(
            rubies(&l),
            vec![
                ("彗星", Some("すいせい")),
                ("の", None),
                ("停留所", Some("バスストップ")),
                ("で", None),
            ]
        );
        assert_eq!(l.text(), "彗星の停留所で");
        assert!(l.syllables.iter().all(|s| s.start_ms == 1000));
    }

    #[test]
    fn iteration_marks_and_long_vowel() {
        let l = applied("時々(ときどき)一ヶ月(いっかげつ)ケーキ屋(や)");
        assert_eq!(
            rubies(&l),
            vec![
                ("時々", Some("ときどき")),
                ("一ヶ月", Some("いっかげつ")),
                ("ケーキ", None),
                ("屋", Some("や")),
            ]
        );
        let l = applied("未来(ミライー)");
        assert_eq!(rubies(&l), vec![("未来", Some("ミライー"))]);
    }

    #[test]
    fn non_reading_parens_stay_verbatim() {
        for text in [
            "(woo) 夜(yeah)", // 英文
            "愛してる (Ah)",  // 英文
            "君(きみ と)",    // 空格
            "君(きみ1)",      // 数字
            "君(君の)",       // 汉字假名混写
            "君(き(み))",     // 嵌套
            "君((きみ))",     // 嵌套
            "君(きみ）",      // 半角开全角收
            "君（きみ)",      // 全角开半角收
            "君 (きみ)",      // 汉字与括号间有空格
            "の(きみ)",       // 括号前不是汉字
            "君()",           // 空读音
            "君(きみ",        // 不闭合
            "(きみ)",         // 行首括号
            "ハロー(はろー)", // 片假名后接读音不算
        ] {
            let mut l = Line::whole(text, 0, 0);
            assert!(!apply(&mut l), "{text}");
            assert_eq!(l.text(), text);
            assert!(l.syllables.iter().all(|s| s.ruby.is_none()), "{text}");
        }
    }

    #[test]
    fn mixed_line_only_converts_strict_hits() {
        let l = applied("夢(ゆめ)を見た(woo) 涙(なみだ)(Oh)");
        assert_eq!(
            rubies(&l),
            vec![
                ("夢", Some("ゆめ")),
                ("を見た(woo) ", None),
                ("涙", Some("なみだ")),
                ("(Oh)", None),
            ]
        );
    }

    #[test]
    fn kanji_run_across_syllables_merges_with_timing() {
        // ESLyric 逐字：汉字串和读音跨音节。
        let mut l = Line::default();
        l.start_ms = 1000;
        l.syllables = vec![
            Syllable::new("の彗", 1000, 1200),
            Syllable::new("星", 1200, 1400),
            Syllable::new("(すい", 1400, 1600),
            Syllable::new("せい)が", 1600, 2000),
        ];
        assert!(apply(&mut l));
        let got: Vec<_> = l
            .syllables
            .iter()
            .map(|s| (s.text.as_str(), s.ruby.as_deref(), s.start_ms, s.end_ms))
            .collect();
        assert_eq!(
            got,
            vec![
                ("の", None, 1000, 1200),
                ("彗星", Some("すいせい"), 1000, 2000),
                ("が", None, 1600, 2000),
            ]
        );
    }

    #[test]
    fn existing_structured_ruby_is_left_alone() {
        let mut l = Line::whole("世界(せかい)", 0, 0);
        l.syllables[0].ruby = Some("x".into());
        assert!(!apply(&mut l));
        assert_eq!(l.text(), "世界(せかい)");
    }
}
