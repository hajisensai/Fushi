//! 内容派生身份（设计 §10「`track_uid`：路径 + 起止样本 + 文件指纹」）。
//!
//! **文件指纹取音频属性而不是文件字节**：改标签（Picard / foobar 写回）会改写 FLAC / MP3
//! 文件头、APE / WavPack 文件尾的标签块，字节级指纹会让每次改标签都换一个 uid，歌单 /
//! 歌词 / 播放记录跟着全断。音频属性（时长到毫秒、采样率、声道数）在改标签时不变，
//! 换成另一段录音时几乎必变——它回答的正是「这个路径上还是不是那段音频」。
//! 属性读不出的格式（没有时长）退化为路径 + 起点。

use sha1::{Digest, Sha1};

/// uid 命名空间版本：派生规则变了就升，旧 uid 与新 uid 不会撞。
const TRACK_NS: &str = "fushi-music-track-v1";
const ALBUM_NS: &str = "fushi-music-album-v1";
const ARTIST_NS: &str = "fushi-music-artist-v1";

fn digest(parts: &[&str]) -> String {
    let mut h = Sha1::new();
    for (i, p) in parts.iter().enumerate() {
        if i > 0 {
            h.update([0u8]);
        }
        h.update(p.as_bytes());
    }
    let out = h.finalize();
    // 128 bit 足够（同一台设备的曲库规模远小于碰撞域）。
    out[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// 音频属性指纹（见模块文档）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AudioFingerprint {
    pub duration_ms: Option<i64>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
}

impl AudioFingerprint {
    fn encode(&self) -> String {
        fn f(v: Option<i64>) -> String {
            v.map(|x| x.to_string()).unwrap_or_default()
        }
        format!(
            "{}/{}/{}",
            f(self.duration_ms),
            f(self.sample_rate),
            f(self.channels)
        )
    }
}

/// 曲目 uid：路径 + CUE 起点（普通文件为空）+ 音频属性指纹。
pub fn track_uid(path: &str, cue_start_ms: Option<i64>, fp: AudioFingerprint) -> String {
    let start = cue_start_ms.map(|v| v.to_string()).unwrap_or_default();
    digest(&[TRACK_NS, path, &start, &fp.encode()])
}

/// 归一化名字：去首尾空白、连续空白折成一个、全角 ASCII 折成半角、ASCII 小写。
/// 只做这几步（不做 NFKC / 假名折叠）：目的是让「同一个人的标签写法差异」聚到一起，
/// 不是做模糊匹配——那是刮削层的事。
pub fn normalize_name(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for ch in s.trim().chars() {
        let ch = match ch {
            '\u{3000}' => ' ',
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(ch as u32 - 0xFEE0).unwrap_or(ch),
            _ => ch,
        };
        if ch.is_whitespace() {
            pending_space = true;
            continue;
        }
        if pending_space && !out.is_empty() {
            out.push(' ');
        }
        pending_space = false;
        out.extend(ch.to_lowercase());
    }
    out
}

pub fn artist_uid(name: &str) -> String {
    digest(&[ARTIST_NS, &normalize_name(name)])
}

/// 专辑 uid：有专辑艺人标签时按（专辑艺人, 专辑名）——同一张专辑散在几个目录（分碟
/// 目录）也聚成一张；没有专辑艺人时按（专辑名, 所在目录）——合辑每首艺人不同，按艺人
/// 分组会把一张合辑拆成十几张。
pub fn album_uid(album_title: &str, album_artist: Option<&str>, directory: &str) -> String {
    match album_artist.filter(|a| !a.trim().is_empty()) {
        Some(artist) => digest(&[
            ALBUM_NS,
            "artist",
            &normalize_name(artist),
            &normalize_name(album_title),
        ]),
        None => digest(&[ALBUM_NS, "dir", directory, &normalize_name(album_title)]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_folds_width_case_and_spaces() {
        assert_eq!(
            normalize_name("  ＹＯＡＳＯＢＩ\u{3000} feat.  X "),
            "yoasobi feat. x"
        );
        assert_eq!(normalize_name("宇多田ヒカル"), "宇多田ヒカル");
    }

    #[test]
    fn track_uid_is_stable_and_discriminating() {
        let fp = AudioFingerprint {
            duration_ms: Some(200_000),
            sample_rate: Some(44_100),
            channels: Some(2),
        };
        let a = track_uid("/m/a.flac", None, fp);
        assert_eq!(a, track_uid("/m/a.flac", None, fp));
        assert_eq!(a.len(), 32);
        assert_ne!(a, track_uid("/m/a.flac", Some(0), fp));
        assert_ne!(a, track_uid("/m/b.flac", None, fp));
        let other = AudioFingerprint {
            duration_ms: Some(199_000),
            ..fp
        };
        assert_ne!(a, track_uid("/m/a.flac", None, other));
    }

    /// 固定向量（由独立的 Python hashlib 实现算出）：派生规则一改，同步 / 歌单里已存的
    /// uid 全部失配，必须升命名空间版本而不是悄悄改算法。
    #[test]
    fn uid_derivation_is_frozen() {
        let fp = AudioFingerprint {
            duration_ms: Some(200_000),
            sample_rate: Some(44_100),
            channels: Some(2),
        };
        assert_eq!(
            track_uid("/music/a.flac", None, fp),
            "7a6ac5b52ad4a08b5c59225598a9d43c"
        );
        assert_eq!(
            track_uid("/music/a.flac", Some(240_000), fp),
            "f2dd5c9f872577f46511bdaa9628deeb"
        );
        assert_eq!(
            album_uid("Album A", Some("Singer X"), "/ignored"),
            "d029cd99e496f6b2216696bfc43fe00f"
        );
        assert_eq!(artist_uid(" YOASOBI "), "cd539c8393c331620bcc2e9fbfb12f79");
    }

    #[test]
    fn album_uid_prefers_album_artist() {
        assert_eq!(
            album_uid("Album", Some("Artist"), "/x/CD1"),
            album_uid("ALBUM", Some("artist"), "/x/CD2"),
        );
        assert_ne!(
            album_uid("Album", None, "/x/CD1"),
            album_uid("Album", None, "/x/CD2"),
        );
    }
}
