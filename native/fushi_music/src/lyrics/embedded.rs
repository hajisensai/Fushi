//! 音频文件内嵌歌词：ID3v2 `USLT` / `SYLT`、Vorbis `LYRICS` / `UNSYNCEDLYRICS`、MP4 `©lyr`、
//! APE `Lyrics`（lofty 统一成 [ItemKey::Lyrics]）。
//!
//! 文本型内嵌（USLT / Vorbis / ©lyr）常常就是一整份 LRC：交给 [super::parse] 按内容嗅探，
//! 嗅不出时间就是纯文本（`Unsynced`）。`SYLT` 是逐事件时间（毫秒制才收；MPEG 帧制需要帧长，
//! 罕见，跳过并在结果里标明）。

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::id3::v2::{Frame, SyncTextContentType, SynchronizedTextFrame, TimestampFormat};
use lofty::mpeg::MpegFile;
use lofty::probe::Probe;
use lofty::tag::ItemKey;

use super::model::*;

/// 一条内嵌歌词。
#[derive(Debug, Clone, PartialEq)]
pub enum Embedded {
    /// 文本（可能是 LRC）：(来源键, 文本)。
    Text { key: String, text: String },
    /// ID3v2 SYLT（毫秒制）：(语言, 事件)。
    Sylt { language: String, events: Vec<(u32, String)> },
}

pub fn read(path: &Path) -> Result<Vec<Embedded>, String> {
    let mut out = Vec::new();
    let tagged = Probe::open(path)
        .map_err(|e| e.to_string())?
        .options(ParseOptions::new().read_properties(false).read_cover_art(false))
        .guess_file_type()
        .map_err(|e| e.to_string())?
        .read()
        .map_err(|e| e.to_string())?;
    let unsynced = ItemKey::Unknown("UNSYNCEDLYRICS".to_owned());
    for tag in tagged.tags() {
        for key in [&ItemKey::Lyrics, &unsynced] {
            for v in tag.get_strings(key) {
                let v = v.trim_matches('\0');
                if !v.trim().is_empty() && !out.iter().any(|e| matches!(e, Embedded::Text { text, .. } if text == v)) {
                    out.push(Embedded::Text {
                        key: match key {
                            ItemKey::Lyrics => "lyrics".to_owned(),
                            _ => "unsyncedlyrics".to_owned(),
                        },
                        text: v.to_owned(),
                    });
                }
            }
        }
    }
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    if ext == "mp3" {
        if let Ok(f) = File::open(path) {
            let mut r = BufReader::new(f);
            if let Ok(mpeg) = MpegFile::read_from(&mut r, ParseOptions::new().read_properties(false).read_cover_art(false)) {
                if let Some(id3) = mpeg.id3v2() {
                    for frame in id3 {
                        let Frame::Binary(bin) = frame else { continue };
                        if frame.id_str() != "SYLT" {
                            continue;
                        }
                        let Ok(sylt) = SynchronizedTextFrame::parse(&bin.data, frame.flags()) else { continue };
                        if sylt.timestamp_format != TimestampFormat::MS {
                            continue;
                        }
                        if !matches!(sylt.content_type, SyncTextContentType::Lyrics | SyncTextContentType::TextTranscription) {
                            continue;
                        }
                        out.push(Embedded::Sylt {
                            language: String::from_utf8_lossy(&sylt.language).trim_matches('\0').to_owned(),
                            events: sylt.content,
                        });
                    }
                }
            }
        }
    }
    Ok(out)
}

/// SYLT 事件 → 时间轴：事件文本以换行开头（或上一事件以换行结尾）= 新行；每个事件一个音节。
pub fn sylt_timeline(language: &str, events: &[(u32, String)], duration_ms: Option<i64>) -> Timeline {
    let mut t = Timeline::new("sylt", TimingQuality::Word);
    t.meta.language = (!language.is_empty() && language != "XXX").then(|| language.to_owned());
    let mut cur = Line::default();
    let mut break_after = false;
    let mut multi = false;
    for (ms, raw) in events {
        let ms = *ms as i64;
        let starts_new = raw.starts_with(['\n', '\r']) || break_after;
        break_after = raw.ends_with(['\n', '\r']);
        let body = raw.trim_matches(['\n', '\r']);
        if starts_new && !cur.syllables.is_empty() {
            if let Some(last) = cur.syllables.last_mut() {
                if last.end_ms <= last.start_ms {
                    last.end_ms = ms;
                }
            }
            t.lines.push(std::mem::take(&mut cur));
        }
        if body.is_empty() {
            continue;
        }
        if cur.syllables.is_empty() {
            cur.start_ms = ms;
        } else {
            multi = true;
            if let Some(last) = cur.syllables.last_mut() {
                last.end_ms = ms;
            }
        }
        cur.syllables.push(Syllable::new(body, ms, 0));
    }
    if !cur.syllables.is_empty() {
        t.lines.push(cur);
    }
    if !multi {
        t.timing_quality = TimingQuality::Line;
    }
    t.finalize(duration_ms);
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sylt_events_to_lines() {
        let ev = vec![
            (1000, "Hel".to_string()),
            (1300, "lo".to_string()),
            (2000, "\nWorld".to_string()),
        ];
        let t = sylt_timeline("eng", &ev, Some(4000));
        assert_eq!(t.timing_quality, TimingQuality::Word);
        assert_eq!(t.lines.len(), 2);
        assert_eq!(t.lines[0].text(), "Hello");
        assert_eq!(t.lines[0].syllables[1].end_ms, 2000);
        assert_eq!((t.lines[1].start_ms, t.lines[1].end_ms), (2000, 4000));
    }
}
