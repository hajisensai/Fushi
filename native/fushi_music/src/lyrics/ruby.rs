//! 自动注音与音节对齐（设计 §5.3）：读音来自 Dart 侧「当前学习语言」的既有分词 / 读音能力
//! （本模块**不认识任何语言**，只做字符区间对齐），整首一次传进来：每行一串
//! `(表层形, 读音)`。
//!
//! 规则：
//! - 行里任何音节已有 ruby（源文件自带）→ 整行不动；
//! - 表层形 == 读音的 token 不注；读音与表层形首尾相同的字符（送假名 / 前缀）剥掉，只给
//!   中间不同的部分注音（`食べる/たべる` → `食` 注 `た`）；
//! - 注音区间落在一个音节内部 → 在区间边界把音节切开（时间按字数比例分），注音挂在中间那段；
//! - 注音区间跨多个音节 → 先在边界切开，再把读音按各音节字数比例分给它们（字级卡拉 OK
//!   里一个汉字一个音节、读音没有逐字边界时的近似）。

use super::model::*;

/// 每行的 token：(表层形, 读音)。`lines[i]` 对应时间轴第 i 个**主行或和声行**（按时间轴顺序）。
pub type LineTokens = Vec<(String, String)>;

pub fn align(t: &Timeline, lines: &[LineTokens]) -> Timeline {
    let mut out = t.clone();
    for (line, tokens) in out.lines.iter_mut().zip(lines.iter()) {
        if line.syllables.iter().any(|s| s.ruby.is_some()) || tokens.is_empty() {
            continue;
        }
        align_line(line, tokens);
    }
    out
}

fn align_line(line: &mut Line, tokens: &[(String, String)]) {
    let text: Vec<char> = line.text().chars().collect();
    // 注音区间（字符下标，半开）。
    let mut spans: Vec<(usize, usize, String)> = Vec::new();
    let mut cursor = 0usize;
    for (surface, reading) in tokens {
        let sc: Vec<char> = surface.chars().collect();
        if sc.is_empty() {
            continue;
        }
        let Some(pos) = find_chars(&text, &sc, cursor) else { continue };
        cursor = pos + sc.len();
        let rc: Vec<char> = reading.chars().collect();
        if rc.is_empty() || rc == sc {
            continue;
        }
        // 剥共同前后缀。
        let mut pre = 0;
        while pre < sc.len() && pre < rc.len() && sc[pre] == rc[pre] {
            pre += 1;
        }
        let mut suf = 0;
        while suf < sc.len() - pre && suf < rc.len() - pre && sc[sc.len() - 1 - suf] == rc[rc.len() - 1 - suf] {
            suf += 1;
        }
        let base = (pos + pre, pos + sc.len() - suf);
        let r: String = rc[pre..rc.len() - suf].iter().collect();
        if base.0 >= base.1 || r.trim().is_empty() {
            continue;
        }
        spans.push((base.0, base.1, r));
    }
    for (s, e, reading) in spans {
        split_at_char(line, s);
        split_at_char(line, e);
        let covered = syllables_in(line, s, e);
        if covered.is_empty() {
            continue;
        }
        let weights: Vec<usize> = covered.iter().map(|&i| line.syllables[i].text.chars().count()).collect();
        let total: usize = weights.iter().sum::<usize>().max(1);
        let rchars: Vec<char> = reading.chars().collect();
        let mut taken = 0usize;
        let mut acc = 0usize;
        for (k, &i) in covered.iter().enumerate() {
            acc += weights[k];
            let upto = if k + 1 == covered.len() {
                rchars.len()
            } else {
                ((rchars.len() * acc + total / 2) / total).max(taken + 1).min(rchars.len())
            };
            let piece: String = rchars[taken.min(upto)..upto].iter().collect();
            taken = upto;
            if !piece.is_empty() {
                line.syllables[i].ruby = Some(piece);
            }
        }
    }
}

fn find_chars(hay: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    (from..=hay.len() - needle.len()).find(|&i| hay[i..i + needle.len()] == *needle)
}

/// 音节在整行里的字符区间。
fn ranges(line: &Line) -> Vec<(usize, usize)> {
    let mut out = Vec::with_capacity(line.syllables.len());
    let mut at = 0;
    for s in &line.syllables {
        let n = s.text.chars().count();
        out.push((at, at + n));
        at += n;
    }
    out
}

fn syllables_in(line: &Line, s: usize, e: usize) -> Vec<usize> {
    ranges(line)
        .iter()
        .enumerate()
        .filter(|(_, (a, b))| *a >= s && *b <= e && a < b)
        .map(|(i, _)| i)
        .collect()
}

/// 在整行第 `at` 个字符处把所在音节切成两段（时间按字数比例）。`at` 恰在边界时不动。
fn split_at_char(line: &mut Line, at: usize) {
    let rs = ranges(line);
    let Some(i) = rs.iter().position(|(a, b)| *a < at && at < *b) else { return };
    let (a, b) = rs[i];
    let syl = line.syllables[i].clone();
    let chars: Vec<char> = syl.text.chars().collect();
    let k = at - a;
    let total = (b - a) as i64;
    let dur = (syl.end_ms - syl.start_ms).max(0);
    let mid = syl.start_ms + dur * k as i64 / total;
    let mut left = syl.clone();
    left.text = chars[..k].iter().collect();
    left.end_ms = mid;
    let mut right = syl;
    right.text = chars[k..].iter().collect();
    right.start_ms = mid;
    line.syllables[i] = left;
    line.syllables.insert(i + 1, right);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tok(v: &[(&str, &str)]) -> LineTokens {
        v.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn line_level_syllable_is_split_and_okurigana_stripped() {
        let mut t = Timeline::new("lrc", TimingQuality::Line);
        t.lines.push(Line::whole("夜空を食べる", 0, 6000));
        let out = align(&t, &[tok(&[("夜空", "よぞら"), ("を", "を"), ("食べる", "たべる")])]);
        let s: Vec<_> = out.lines[0]
            .syllables
            .iter()
            .map(|s| (s.text.as_str(), s.start_ms, s.end_ms, s.ruby.as_deref()))
            .collect();
        assert_eq!(
            s,
            vec![
                ("夜空", 0, 2000, Some("よぞら")),
                ("を", 2000, 3000, None),
                ("食", 3000, 4000, Some("た")),
                ("べる", 4000, 6000, None),
            ]
        );
    }

    #[test]
    fn reading_is_distributed_over_char_syllables() {
        let mut t = Timeline::new("lrc", TimingQuality::Syllable);
        let mut l = Line::default();
        l.syllables = vec![Syllable::new("漢", 0, 500), Syllable::new("字", 500, 1000)];
        t.lines.push(l);
        let out = align(&t, &[tok(&[("漢字", "かんじ")])]);
        let r: Vec<_> = out.lines[0].syllables.iter().map(|s| s.ruby.clone().unwrap()).collect();
        assert_eq!(r.concat(), "かんじ");
        assert_eq!(r.len(), 2);
    }

    #[test]
    fn existing_ruby_is_kept() {
        let mut t = Timeline::new("ttml", TimingQuality::Syllable);
        let mut l = Line::whole("漢字", 0, 1000);
        l.syllables[0].ruby = Some("かんじ".into());
        t.lines.push(l);
        let out = align(&t, &[tok(&[("漢字", "おとこ")])]);
        assert_eq!(out.lines[0].syllables[0].ruby.as_deref(), Some("かんじ"));
    }
}
