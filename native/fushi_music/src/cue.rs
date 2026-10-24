//! CUE 表：整轨 + `.cue` 与 FLAC 内嵌 CUESHEET（Vorbis 注释里的 `CUESHEET` 文本，或
//! FLAC 元数据块类型 5 的二进制 CUESHEET）拆成虚拟曲目（起止毫秒）。
//!
//! 时间：`INDEX 01 mm:ss:ff`（75 帧 / 秒）是曲目起点；`INDEX 00`（pregap）不当起点——
//! 播放器从 INDEX 01 播，与 foobar2000 / EAC 的默认一致。一个 FILE 里的曲目终点 = 下一
//! 首的起点；文件最后一首没有终点（播到文件尾）。

use encoding_rs::{BIG5, GBK, SHIFT_JIS, UTF_16BE, UTF_16LE};

/// 一张 CUE 表里属于同一个音频文件的一首曲目。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CueTrack {
    pub number: u32,
    pub title: Option<String>,
    pub performer: Option<String>,
    pub songwriter: Option<String>,
    pub isrc: Option<String>,
    pub start_ms: i64,
    pub end_ms: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct CueFile {
    /// `FILE` 行里的文件名（相对 CUE 所在目录，原样）。
    pub name: String,
    pub tracks: Vec<CueTrack>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct CueSheet {
    pub title: Option<String>,
    pub performer: Option<String>,
    pub songwriter: Option<String>,
    pub date: Option<String>,
    pub genre: Option<String>,
    pub catalog: Option<String>,
    pub disc_number: Option<i64>,
    pub total_discs: Option<i64>,
    pub album_gain: Option<f64>,
    pub album_peak: Option<f64>,
    pub files: Vec<CueFile>,
}

/// 把 CUE 文件字节解成文本：BOM（UTF-8 / UTF-16）→ 严格 UTF-8 → Shift_JIS → GBK → Big5，
/// 取第一个零错误的解码。与 `text_file_io.dart` 的 Unicode 判据同序；传统多字节编码
/// 之间本就无法靠字节可靠区分，按本仓用户群（日语资源为主）把 Shift_JIS 排第一。
pub fn decode_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return UTF_16LE.decode_with_bom_removal(bytes).0.into_owned();
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return UTF_16BE.decode_with_bom_removal(bytes).0.into_owned();
    }
    if let Ok(s) = std::str::from_utf8(bytes) {
        return s.to_owned();
    }
    for enc in [SHIFT_JIS, GBK, BIG5] {
        let (text, had_errors) = enc.decode_without_bom_handling(bytes);
        if !had_errors {
            return text.into_owned();
        }
    }
    String::from_utf8_lossy(bytes).into_owned()
}

/// 拆一行里的参数：引号包住的整段算一个，其余按空白分。
fn split_args(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = line.chars().peekable();
    loop {
        while matches!(chars.peek(), Some(c) if c.is_whitespace()) {
            chars.next();
        }
        let Some(&c) = chars.peek() else { break };
        let mut cur = String::new();
        if c == '"' {
            chars.next();
            for ch in chars.by_ref() {
                if ch == '"' {
                    break;
                }
                cur.push(ch);
            }
        } else {
            while let Some(&ch) = chars.peek() {
                if ch.is_whitespace() {
                    break;
                }
                cur.push(ch);
                chars.next();
            }
        }
        out.push(cur);
    }
    out
}

/// `mm:ss:ff` → 毫秒（75 帧 / 秒，向下取整到毫秒）。
pub fn msf_to_ms(s: &str) -> Option<i64> {
    let mut it = s.split(':');
    let m: i64 = it.next()?.trim().parse().ok()?;
    let sec: i64 = it.next()?.trim().parse().ok()?;
    let f: i64 = it.next()?.trim().parse().ok()?;
    if it.next().is_some() || sec >= 60 || f >= 75 || m < 0 || sec < 0 || f < 0 {
        return None;
    }
    Some(((m * 60 + sec) * 75 + f) * 1000 / 75)
}

fn non_empty(s: String) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_owned())
}

fn parse_gain(s: &str) -> Option<f64> {
    s.trim()
        .trim_end_matches("dB")
        .trim_end_matches("db")
        .trim()
        .parse()
        .ok()
}

/// 解析 CUE 文本。没有任何 FILE / TRACK 的表返回 None。
pub fn parse(text: &str) -> Option<CueSheet> {
    let mut sheet = CueSheet::default();
    let mut cur_file: Option<CueFile> = None;
    let mut cur_track: Option<CueTrack> = None;
    let mut track_has_start = false;

    fn flush_track(file: &mut Option<CueFile>, track: &mut Option<CueTrack>, has_start: bool) {
        if let (Some(f), Some(t)) = (file.as_mut(), track.take()) {
            if has_start {
                f.tracks.push(t);
            }
        }
    }

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let args = split_args(line);
        let Some(cmd) = args.first().map(|s| s.to_ascii_uppercase()) else {
            continue;
        };
        let arg = |i: usize| args.get(i).cloned().unwrap_or_default();
        match cmd.as_str() {
            "FILE" => {
                flush_track(&mut cur_file, &mut cur_track, track_has_start);
                if let Some(f) = cur_file.take() {
                    sheet.files.push(f);
                }
                cur_file = Some(CueFile {
                    name: arg(1),
                    tracks: Vec::new(),
                });
            }
            "TRACK" => {
                flush_track(&mut cur_file, &mut cur_track, track_has_start);
                track_has_start = false;
                if args.get(2).map(|s| s.eq_ignore_ascii_case("AUDIO")) == Some(true) {
                    cur_track = Some(CueTrack {
                        number: arg(1).parse().unwrap_or(0),
                        ..Default::default()
                    });
                }
            }
            "INDEX" => {
                if let Some(t) = cur_track.as_mut() {
                    if arg(1).parse::<u32>().ok() == Some(1) {
                        if let Some(ms) = msf_to_ms(&arg(2)) {
                            t.start_ms = ms;
                            track_has_start = true;
                        }
                    }
                }
            }
            "TITLE" => match cur_track.as_mut() {
                Some(t) => t.title = non_empty(arg(1)),
                None => sheet.title = non_empty(arg(1)),
            },
            "PERFORMER" => match cur_track.as_mut() {
                Some(t) => t.performer = non_empty(arg(1)),
                None => sheet.performer = non_empty(arg(1)),
            },
            "SONGWRITER" => match cur_track.as_mut() {
                Some(t) => t.songwriter = non_empty(arg(1)),
                None => sheet.songwriter = non_empty(arg(1)),
            },
            "ISRC" => {
                if let Some(t) = cur_track.as_mut() {
                    t.isrc = non_empty(arg(1));
                }
            }
            "CATALOG" => sheet.catalog = non_empty(arg(1)),
            "REM" => {
                let key = arg(1).to_ascii_uppercase();
                let value = args[2.min(args.len())..].join(" ");
                match key.as_str() {
                    "DATE" => sheet.date = non_empty(value),
                    "GENRE" => sheet.genre = non_empty(value),
                    "DISCNUMBER" => sheet.disc_number = value.trim().parse().ok(),
                    "TOTALDISCS" => sheet.total_discs = value.trim().parse().ok(),
                    "REPLAYGAIN_ALBUM_GAIN" => sheet.album_gain = parse_gain(&value),
                    "REPLAYGAIN_ALBUM_PEAK" => sheet.album_peak = parse_gain(&value),
                    _ => {}
                }
            }
            _ => {}
        }
    }
    flush_track(&mut cur_file, &mut cur_track, track_has_start);
    if let Some(f) = cur_file.take() {
        sheet.files.push(f);
    }
    sheet.files.retain(|f| !f.tracks.is_empty());
    if sheet.files.is_empty() {
        return None;
    }
    for f in &mut sheet.files {
        f.tracks.sort_by_key(|t| t.start_ms);
        let starts: Vec<i64> = f.tracks.iter().map(|t| t.start_ms).collect();
        for (i, t) in f.tracks.iter_mut().enumerate() {
            t.end_ms = starts.get(i + 1).copied();
        }
    }
    Some(sheet)
}

/// 解析 FLAC 元数据块里的二进制 CUESHEET（块类型 5）。只拿起点（无标题）；`sample_rate`
/// 来自 STREAMINFO。返回各曲目（含终点）；没有该块 / 格式不对返回 None。
pub fn parse_flac_cuesheet_block(file_head: &[u8]) -> Option<Vec<CueTrack>> {
    if !file_head.starts_with(b"fLaC") {
        return None;
    }
    let mut pos = 4usize;
    let mut sample_rate: Option<u64> = None;
    loop {
        let header = file_head.get(pos..pos + 4)?;
        let last = header[0] & 0x80 != 0;
        let kind = header[0] & 0x7F;
        let len = ((header[1] as usize) << 16) | ((header[2] as usize) << 8) | header[3] as usize;
        let body = file_head.get(pos + 4..pos + 4 + len)?;
        match kind {
            0 if body.len() >= 18 => {
                // STREAMINFO：第 10 字节起 20 bit 采样率。
                let sr =
                    ((body[10] as u64) << 12) | ((body[11] as u64) << 4) | (body[12] as u64 >> 4);
                sample_rate = Some(sr);
            }
            5 => return parse_cuesheet_body(body, sample_rate?),
            _ => {}
        }
        if last {
            return None;
        }
        pos += 4 + len;
    }
}

fn parse_cuesheet_body(body: &[u8], sample_rate: u64) -> Option<Vec<CueTrack>> {
    if sample_rate == 0 {
        return None;
    }
    // 128 字节目录号 + 8 字节 lead-in + 1 字节标志 + 258 保留 = 395，然后 1 字节曲目数。
    let n = *body.get(395)? as usize;
    let mut pos = 396usize;
    let mut tracks = Vec::new();
    for _ in 0..n {
        let offset = u64::from_be_bytes(body.get(pos..pos + 8)?.try_into().ok()?);
        let number = *body.get(pos + 8)?;
        // 12 ISRC + 1 标志 + 13 保留
        let n_idx = *body.get(pos + 8 + 1 + 12 + 1 + 13)? as usize;
        let mut idx_pos = pos + 36;
        let mut start: Option<u64> = None;
        for _ in 0..n_idx {
            let idx_off = u64::from_be_bytes(body.get(idx_pos..idx_pos + 8)?.try_into().ok()?);
            let idx_no = *body.get(idx_pos + 8)?;
            if idx_no == 1 {
                start = Some(offset + idx_off);
            }
            idx_pos += 12;
        }
        pos = idx_pos;
        // 170（CD）/ 255（非 CD）是 lead-out，不是曲目。
        if number == 170 || number == 255 {
            continue;
        }
        if let Some(s) = start {
            tracks.push(CueTrack {
                number: number as u32,
                start_ms: (s * 1000 / sample_rate) as i64,
                ..Default::default()
            });
        }
    }
    if tracks.is_empty() {
        return None;
    }
    tracks.sort_by_key(|t| t.start_ms);
    let starts: Vec<i64> = tracks.iter().map(|t| t.start_ms).collect();
    for (i, t) in tracks.iter_mut().enumerate() {
        t.end_ms = starts.get(i + 1).copied();
    }
    Some(tracks)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"REM GENRE "J-Pop"
REM DATE 2019
REM DISCNUMBER 1
REM REPLAYGAIN_ALBUM_GAIN -8.50 dB
PERFORMER "Album Artist"
TITLE "The Album"
FILE "full.flac" WAVE
  TRACK 01 AUDIO
    TITLE "One"
    PERFORMER "A"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Two"
    INDEX 00 03:59:70
    INDEX 01 04:00:00
  TRACK 03 AUDIO
    TITLE "Three"
    INDEX 01 08:30:37
"#;

    #[test]
    fn parses_sheet_with_pregap_and_end_times() {
        let s = parse(SAMPLE).unwrap();
        assert_eq!(s.title.as_deref(), Some("The Album"));
        assert_eq!(s.performer.as_deref(), Some("Album Artist"));
        assert_eq!(s.date.as_deref(), Some("2019"));
        assert_eq!(s.genre.as_deref(), Some("J-Pop"));
        assert_eq!(s.disc_number, Some(1));
        assert_eq!(s.album_gain, Some(-8.5));
        assert_eq!(s.files.len(), 1);
        let t = &s.files[0].tracks;
        assert_eq!(t.len(), 3);
        assert_eq!((t[0].start_ms, t[0].end_ms), (0, Some(240_000)));
        assert_eq!(t[1].start_ms, 240_000, "INDEX 00 不是起点");
        assert_eq!(t[2].start_ms, 510_493);
        assert_eq!(t[2].end_ms, None);
        assert_eq!(t[0].performer.as_deref(), Some("A"));
    }

    #[test]
    fn msf_rejects_bad_fields() {
        assert_eq!(msf_to_ms("01:00:74"), Some(60_986));
        assert_eq!(msf_to_ms("01:60:00"), None);
        assert_eq!(msf_to_ms("01:00:75"), None);
        assert_eq!(msf_to_ms("x"), None);
    }

    #[test]
    fn decodes_shift_jis() {
        let (bytes, _, _) = SHIFT_JIS.encode("TITLE \"夜に駆ける\"");
        assert_eq!(decode_text(&bytes), "TITLE \"夜に駆ける\"");
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice("曲".as_bytes());
        assert_eq!(decode_text(&bom), "曲");
    }

    #[test]
    fn data_tracks_are_skipped() {
        let s = parse("FILE \"a.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n");
        assert!(s.is_none());
    }
}
