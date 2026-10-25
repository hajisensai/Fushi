//! 原文 + 翻译文件按时间戳配对（设计 §5.2）：起点相差 ≤ 300 ms 的视为同一行，挂成该行的
//! 翻译；对不上的作为独立行插进时间轴。

use super::model::*;

pub const PAIR_WINDOW_MS: i64 = 300;

pub fn merge_translation(primary: &Timeline, secondary: &Timeline, lang: &str) -> Timeline {
    if primary.timing_quality == TimingQuality::Unsynced {
        // 原文没有时间：无法按时间配对，原样返回原文。
        return primary.clone();
    }
    let mut out = primary.clone();
    let mut used = vec![false; out.lines.len()];
    let mut extra: Vec<Line> = Vec::new();
    for sec in secondary.lines.iter().filter(|l| l.role == Role::Main) {
        let txt = sec.text();
        let txt = txt.trim();
        if txt.is_empty() {
            continue;
        }
        let hit = out
            .lines
            .iter()
            .enumerate()
            .filter(|(i, l)| !used[*i] && l.role == Role::Main && (l.start_ms - sec.start_ms).abs() <= PAIR_WINDOW_MS)
            .min_by_key(|(_, l)| (l.start_ms - sec.start_ms).abs())
            .map(|(i, _)| i);
        match hit {
            Some(i) => {
                used[i] = true;
                out.lines[i].add_translation(lang, txt);
            }
            None => {
                let mut l = Line::whole(txt, sec.start_ms, sec.end_ms);
                l.agent = None;
                extra.push(l);
            }
        }
    }
    out.lines.extend(extra);
    out.finalize(None);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairs_within_window_and_keeps_strays() {
        let mut p = Timeline::new("lrc", TimingQuality::Line);
        p.lines.push(Line::whole("a", 1000, 2000));
        p.lines.push(Line::whole("b", 3000, 4000));
        let mut s = Timeline::new("lrc", TimingQuality::Line);
        s.lines.push(Line::whole("A", 1250, 2000));
        s.lines.push(Line::whole("X", 5000, 6000));
        s.lines.push(Line::whole("B", 3400, 4000));
        let m = merge_translation(&p, &s, "zh");
        let texts: Vec<_> = m.lines.iter().map(|l| l.text()).collect();
        assert_eq!(texts, vec!["a", "b", "B", "X"]);
        assert_eq!(m.lines[0].translations, vec![("zh".to_string(), "A".to_string())]);
        assert!(m.lines[1].translations.is_empty(), "400 ms 超出窗口，成独立行");
    }
}
