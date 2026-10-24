//! UltraStar `.txt`（卡拉 OK 歌曲文件）：只取歌词与时间做逐字显示，音高忽略（设计 §5.1）。
//!
//! 头：`#BPM:`（可用逗号小数）、`#GAP:`（毫秒）、`#RELATIVE:yes`。音符行
//! `: 起拍 拍数 音高 文本`（`*` 金音符、`F` / `R` / `G` 自由 / 说唱同形）；`- 拍[ 拍]` 换行；
//! `P1` / `P2` 切对唱声部；`E` 结束。一拍 = 60000 / (BPM × 4) 毫秒（UltraStar 的 BPM 按
//! 四分之一拍计）。

use super::model::*;

pub fn looks_like_ultrastar(text: &str) -> bool {
    let mut has_header = false;
    let mut has_note = false;
    for l in text.lines().take(400) {
        let l = l.trim_start();
        if l.starts_with("#BPM:") || l.starts_with("#bpm:") {
            has_header = true;
        }
        if l.len() > 2 && matches!(l.as_bytes()[0], b':' | b'*' | b'F' | b'R' | b'G') && l.as_bytes()[1] == b' ' {
            has_note = true;
        }
    }
    has_header && has_note
}

fn header_f64(v: &str) -> Option<f64> {
    v.trim().replace(',', ".").parse().ok()
}

pub fn parse(text: &str, duration_ms: Option<i64>) -> Timeline {
    let mut t = Timeline::new("ultrastar", TimingQuality::SyllablePitch);
    let mut bpm = 0f64;
    let mut gap = 0f64;
    let mut relative = false;
    let mut rel_base = 0i64;
    let mut agent: Option<usize> = None;
    let mut cur = Line::default();

    let beat_ms = |bpm: f64, beat: i64| -> f64 { if bpm > 0.0 { beat as f64 * 60_000.0 / (bpm * 4.0) } else { 0.0 } };

    for raw in text.lines() {
        let l = raw.trim_end_matches('\r');
        if let Some(h) = l.strip_prefix('#') {
            if let Some((k, v)) = h.split_once(':') {
                match k.trim().to_ascii_uppercase().as_str() {
                    "BPM" => bpm = header_f64(v).unwrap_or(0.0),
                    "GAP" => gap = header_f64(v).unwrap_or(0.0),
                    "RELATIVE" => relative = v.trim().eq_ignore_ascii_case("yes"),
                    "TITLE" => t.meta.title = Some(v.trim().to_owned()).filter(|s| !s.is_empty()),
                    "ARTIST" => t.meta.artist = Some(v.trim().to_owned()).filter(|s| !s.is_empty()),
                    "LANGUAGE" => {}
                    _ => {}
                }
            }
            continue;
        }
        let trimmed = l.trim_start();
        let Some(&kind) = trimmed.as_bytes().first() else { continue };
        match kind {
            b'E' => break,
            b'P' => {
                flush(&mut t, &mut cur);
                let id = trimmed.trim();
                agent = Some(t.agent_index(id, AgentKind::Person));
            }
            b'-' => {
                let nums: Vec<i64> = trimmed[1..].split_whitespace().filter_map(|n| n.parse().ok()).collect();
                if let Some(&b) = nums.first() {
                    let at = (gap + beat_ms(bpm, rel_base + b)).round() as i64;
                    if cur.end_ms <= cur.start_ms {
                        cur.end_ms = at;
                    }
                }
                if relative {
                    rel_base += nums.get(1).or(nums.first()).copied().unwrap_or(0);
                }
                flush(&mut t, &mut cur);
            }
            b':' | b'*' | b'F' | b'R' | b'G' => {
                // `: 起拍 拍数 音高 文本`——文本可以以空格开头（词间隔），只按前三个空白切。
                let body = &trimmed[1..];
                let mut it = body.splitn(5, ' ');
                let _ = it.next(); // 记号后的那个空格
                let (Some(s), Some(d), Some(_pitch)) = (it.next(), it.next(), it.next()) else { continue };
                let (Ok(s), Ok(d)) = (s.trim().parse::<i64>(), d.trim().parse::<i64>()) else { continue };
                let txt = it.next().unwrap_or("");
                let start = (gap + beat_ms(bpm, rel_base + s)).round() as i64;
                let end = (gap + beat_ms(bpm, rel_base + s + d)).round() as i64;
                if cur.syllables.is_empty() {
                    cur.start_ms = start;
                    cur.agent = agent;
                }
                // `~` 是同一音节换音高的延长，并进前一个音节。
                if txt.trim() == "~" {
                    if let Some(prev) = cur.syllables.last_mut() {
                        prev.end_ms = end;
                        continue;
                    }
                }
                cur.syllables.push(Syllable::new(txt, start, end));
                cur.end_ms = cur.end_ms.max(end);
            }
            _ => {}
        }
    }
    flush(&mut t, &mut cur);
    t.finalize(duration_ms);
    t
}

fn flush(t: &mut Timeline, cur: &mut Line) {
    if cur.syllables.is_empty() {
        *cur = Line::default();
        return;
    }
    let mut line = std::mem::take(cur);
    if let Some(f) = line.syllables.first_mut() {
        f.text = f.text.trim_start().to_owned();
    }
    line.end_ms = line.syllables.iter().map(|s| s.end_ms).max().unwrap_or(line.end_ms);
    t.lines.push(line);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notes_lines_and_duet() {
        let txt = "#TITLE:Song\n#BPM:300\n#GAP:1000\nP1\n: 0 4 60 Hel\n: 4 4 62 lo\n* 8 2 64  world\n- 12\nP2\n: 16 4 60 Bye\n: 20 2 60 ~\nE\n";
        assert!(looks_like_ultrastar(txt));
        let t = parse(txt, None);
        // 一拍 = 60000 / 1200 = 50 ms。
        assert_eq!(t.lines.len(), 2);
        let s: Vec<_> = t.lines[0].syllables.iter().map(|s| (s.text.as_str(), s.start_ms, s.end_ms)).collect();
        assert_eq!(s, vec![("Hel", 1000, 1200), ("lo", 1200, 1400), (" world", 1400, 1500)]);
        assert_eq!(t.agents[t.lines[0].agent.unwrap()].id, "P1");
        assert_eq!(t.agents[t.lines[1].agent.unwrap()].id, "P2");
        assert_eq!(t.lines[1].syllables[0].end_ms, 2100);
        assert_eq!(t.timing_quality, TimingQuality::SyllablePitch);
    }
}
