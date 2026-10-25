//! MIDI / `.kar` 歌词事件：只取歌词与时间（音高忽略，设计 §5.1）。
//!
//! - 时间：合并所有轨的 tempo 事件（`FF 51`）建速度表，tick → 毫秒；SMPTE 分辨率直接按帧率换算；
//! - `.kar`（Soft Karaoke）：歌词在文本事件（`FF 01`）里，`@` 开头是头信息（跳过），`/` 开头换行、
//!   `\` 开头换段；
//! - 标准 MIDI 歌词事件（`FF 05`）：文本里的 `\r` / `\n` 表示行尾，`/` `\` 同上。
//!
//! 有 `@KMIDI` 或 `@` 头的文件优先用文本事件，否则用歌词事件；都有时取事件多的那种。

use super::model::*;

pub fn is_midi(b: &[u8]) -> bool {
    b.starts_with(b"MThd")
}

struct Ev {
    tick: u64,
    kind: u8, // 0x01 文本 / 0x05 歌词
    text: Vec<u8>,
}

fn read_vlq(b: &[u8], pos: &mut usize) -> Option<u64> {
    let mut v: u64 = 0;
    for _ in 0..4 {
        let c = *b.get(*pos)?;
        *pos += 1;
        v = (v << 7) | (c & 0x7F) as u64;
        if c & 0x80 == 0 {
            return Some(v);
        }
    }
    None
}

/// 解析 SMF：返回 (division, tempo 表 [(tick, 微秒/四分音符)], 文本 / 歌词事件)。
fn read_smf(b: &[u8]) -> Option<(u16, Vec<(u64, u32)>, Vec<Ev>)> {
    if !is_midi(b) || b.len() < 14 {
        return None;
    }
    let hlen = u32::from_be_bytes(b[4..8].try_into().ok()?) as usize;
    let ntracks = u16::from_be_bytes(b[10..12].try_into().ok()?);
    let division = u16::from_be_bytes(b[12..14].try_into().ok()?);
    let mut pos = 8 + hlen;
    let mut tempos: Vec<(u64, u32)> = Vec::new();
    let mut evs: Vec<Ev> = Vec::new();
    for _ in 0..ntracks {
        if b.get(pos..pos + 4)? != b"MTrk" {
            break;
        }
        let len = u32::from_be_bytes(b.get(pos + 4..pos + 8)?.try_into().ok()?) as usize;
        let start = pos + 8;
        let end = (start + len).min(b.len());
        let trk = &b[start..end];
        let mut p = 0usize;
        let mut tick = 0u64;
        let mut running: u8 = 0;
        while p < trk.len() {
            tick += read_vlq(trk, &mut p)?;
            let mut status = *trk.get(p)?;
            if status & 0x80 != 0 {
                p += 1;
            } else {
                status = running;
            }
            match status {
                0xFF => {
                    let ty = *trk.get(p)?;
                    p += 1;
                    let l = read_vlq(trk, &mut p)? as usize;
                    let data = trk.get(p..p + l)?;
                    p += l;
                    match ty {
                        0x51 if l == 3 => {
                            tempos.push((tick, ((data[0] as u32) << 16) | ((data[1] as u32) << 8) | data[2] as u32));
                        }
                        0x01 | 0x05 => evs.push(Ev { tick, kind: ty, text: data.to_vec() }),
                        0x2F => break,
                        _ => {}
                    }
                }
                0xF0 | 0xF7 => {
                    let l = read_vlq(trk, &mut p)? as usize;
                    p += l;
                }
                s if s >= 0x80 => {
                    running = s;
                    let n = match s & 0xF0 {
                        0xC0 | 0xD0 => 1,
                        _ => 2,
                    };
                    p += n;
                }
                _ => return None,
            }
        }
        pos = end;
    }
    tempos.sort_by_key(|t| t.0);
    evs.sort_by_key(|e| e.tick);
    Some((division, tempos, evs))
}

fn tick_to_ms(tick: u64, division: u16, tempos: &[(u64, u32)]) -> i64 {
    if division & 0x8000 != 0 {
        // SMPTE：高字节是负的帧率，低字节是每帧 tick。
        let fps = -((division >> 8) as i8) as f64;
        let tpf = (division & 0xFF) as f64;
        if fps <= 0.0 || tpf <= 0.0 {
            return 0;
        }
        return (tick as f64 / (fps * tpf) * 1000.0).round() as i64;
    }
    let tpq = division.max(1) as f64;
    let mut us = 0f64;
    let mut last_tick = 0u64;
    let mut tempo = 500_000f64;
    for &(t, v) in tempos {
        if t >= tick {
            break;
        }
        us += (t - last_tick) as f64 * tempo / tpq;
        last_tick = t;
        tempo = v as f64;
    }
    us += (tick - last_tick) as f64 * tempo / tpq;
    (us / 1000.0).round() as i64
}

pub fn parse(b: &[u8], duration_ms: Option<i64>) -> Option<Timeline> {
    let (division, tempos, evs) = read_smf(b)?;
    let kar = evs.iter().any(|e| e.kind == 0x01 && e.text.first() == Some(&b'@'));
    let n_text = evs.iter().filter(|e| e.kind == 0x01).count();
    let n_lyric = evs.iter().filter(|e| e.kind == 0x05).count();
    let use_kind = if kar || (n_text > n_lyric) { 0x01 } else { 0x05 };
    let mut t = Timeline::new(if kar { "kar" } else { "midi" }, TimingQuality::SyllablePitch);
    let mut cur = Line::default();
    for e in evs.iter().filter(|e| e.kind == use_kind) {
        let raw = super::text::decode_text(&e.text);
        if raw.starts_with('@') {
            if let Some(ti) = raw.strip_prefix("@T") {
                if t.meta.title.is_none() && !ti.trim().is_empty() {
                    t.meta.title = Some(ti.trim().to_owned());
                }
            }
            continue;
        }
        let ms = tick_to_ms(e.tick, division, &tempos);
        let mut txt = raw.as_str();
        let mut new_line = false;
        if let Some(r) = txt.strip_prefix('/').or_else(|| txt.strip_prefix('\\')) {
            new_line = true;
            txt = r;
        }
        let ends_line = txt.ends_with('\r') || txt.ends_with('\n');
        let body = txt.trim_end_matches(['\r', '\n']);
        if new_line {
            flush(&mut t, &mut cur, ms);
        }
        if !body.is_empty() {
            if cur.syllables.is_empty() {
                cur.start_ms = ms;
            }
            if let Some(prev) = cur.syllables.last_mut() {
                if prev.end_ms <= prev.start_ms {
                    prev.end_ms = ms;
                }
            }
            cur.syllables.push(Syllable::new(body, ms, 0));
        }
        if ends_line {
            flush(&mut t, &mut cur, ms);
        }
    }
    flush(&mut t, &mut cur, i64::MAX);
    // 行尾音节的终点：到下一行起点为止，最长 1 s。
    let starts: Vec<i64> = t.lines.iter().map(|l| l.start_ms).collect();
    for (i, l) in t.lines.iter_mut().enumerate() {
        let next = starts.get(i + 1).copied();
        if let Some(last) = l.syllables.last_mut() {
            if last.end_ms <= last.start_ms {
                let cap = last.start_ms + 1000;
                last.end_ms = next.map(|n| n.min(cap)).unwrap_or(cap).max(last.start_ms + 1);
            }
        }
        l.end_ms = l.syllables.iter().map(|s| s.end_ms).max().unwrap_or(l.end_ms);
    }
    t.finalize(duration_ms);
    Some(t)
}

fn flush(t: &mut Timeline, cur: &mut Line, at: i64) {
    if cur.syllables.is_empty() {
        return;
    }
    let mut line = std::mem::take(cur);
    if let Some(last) = line.syllables.last_mut() {
        if last.end_ms <= last.start_ms && at != i64::MAX && at > last.start_ms {
            last.end_ms = at;
        }
    }
    t.lines.push(line);
}

/// 测试用：用给定 (tick, 类型, 文本) 生成单轨 SMF（tpq 480，可带一个 tempo）。
pub fn build_smf(tempo_us: Option<u32>, events: &[(u64, u8, &[u8])]) -> Vec<u8> {
    fn vlq(mut v: u64, out: &mut Vec<u8>) {
        let mut stack = vec![(v & 0x7F) as u8];
        v >>= 7;
        while v > 0 {
            stack.push(((v & 0x7F) as u8) | 0x80);
            v >>= 7;
        }
        out.extend(stack.iter().rev());
    }
    let mut trk = Vec::new();
    let mut last = 0u64;
    if let Some(tp) = tempo_us {
        trk.extend_from_slice(&[0x00, 0xFF, 0x51, 0x03, (tp >> 16) as u8, (tp >> 8) as u8, tp as u8]);
    }
    for &(tick, ty, text) in events {
        vlq(tick - last, &mut trk);
        last = tick;
        trk.extend_from_slice(&[0xFF, ty]);
        vlq(text.len() as u64, &mut trk);
        trk.extend_from_slice(text);
    }
    trk.extend_from_slice(&[0x00, 0xFF, 0x2F, 0x00]);
    let mut out = b"MThd".to_vec();
    out.extend_from_slice(&6u32.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&1u16.to_be_bytes());
    out.extend_from_slice(&480u16.to_be_bytes());
    out.extend_from_slice(b"MTrk");
    out.extend_from_slice(&(trk.len() as u32).to_be_bytes());
    out.extend(trk);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kar_text_events() {
        // 120 BPM（500000 µs）：480 tick = 500 ms。
        let smf = build_smf(
            Some(500_000),
            &[(0, 1, b"@KMIDI KARAOKE FILE"), (0, 1, b"@TSong"), (480, 1, b"\\Hel"), (720, 1, b"lo"), (960, 1, b"/World")],
        );
        let t = parse(&smf, None).unwrap();
        assert_eq!(t.meta.format, "kar");
        assert_eq!(t.meta.title.as_deref(), Some("Song"));
        assert_eq!(t.lines.len(), 2);
        let s: Vec<_> = t.lines[0].syllables.iter().map(|s| (s.text.as_str(), s.start_ms, s.end_ms)).collect();
        assert_eq!(s, vec![("Hel", 500, 750), ("lo", 750, 1000)]);
        assert_eq!(t.lines[1].start_ms, 1000);
    }

    #[test]
    fn lyric_meta_events_with_cr() {
        let smf = build_smf(None, &[(0, 5, b"La "), (240, 5, b"la\r"), (960, 5, b"Next")]);
        let t = parse(&smf, None).unwrap();
        assert_eq!(t.meta.format, "midi");
        assert_eq!(t.lines.len(), 2);
        assert_eq!(t.lines[0].text(), "La la");
        assert_eq!(t.lines[1].start_ms, 1000);
    }
}
