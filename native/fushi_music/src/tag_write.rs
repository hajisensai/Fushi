//! 「写回文件标签」（音乐方案 §8.1：识别结果写 DB，写回文件是**显式**操作，带 diff 预览）。
//!
//! 两个粗粒度调用：
//! - [read_fields]：读出文件主标签里本模块管的那组字段（diff 预览的「当前值」）；
//! - [write_fields]：一次把一组字段改写进文件主标签（值为空串 = 删除该字段）。
//!
//! 字段集合是固定白名单（[FIELDS]），名字即 wire 键、Dart 侧
//! `packages/fushi_music/lib/src/music_tag_fields.dart` 逐字对应，**不得改名**。
//!
//! 线格式（小端）：`u32 count | (str key | str value)*count`，`str := u32 len | utf8`。
//!
//! 曲目身份不受写回影响：`track_uid` 取的是路径 + CUE 起点 + 音频属性（uid.rs），改标签不变。
//! CUE 虚拟曲目由调用方拒绝（一份整轨文件只有一组标签，写进去会改到同盘所有曲目）。

use std::path::Path;

use lofty::config::{ParseOptions, WriteOptions};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey, Tag, TagType};

/// 白名单字段：wire 键 → lofty 通用键。`track_no` / `disc_no` 走专用访问器。
pub const FIELDS: &[(&str, Option<ItemKey>)] = &[
    ("title", Some(ItemKey::TrackTitle)),
    ("artist", Some(ItemKey::TrackArtist)),
    ("album", Some(ItemKey::AlbumTitle)),
    ("album_artist", Some(ItemKey::AlbumArtist)),
    ("date", Some(ItemKey::RecordingDate)),
    ("track_no", None),
    ("disc_no", None),
    ("catalog_no", Some(ItemKey::CatalogNumber)),
    ("mb_recording_id", Some(ItemKey::MusicBrainzRecordingId)),
    ("mb_release_id", Some(ItemKey::MusicBrainzReleaseId)),
    ("mb_release_group_id", Some(ItemKey::MusicBrainzReleaseGroupId)),
    ("mb_work_id", Some(ItemKey::MusicBrainzWorkId)),
    ("mb_artist_id", Some(ItemKey::MusicBrainzArtistId)),
];

/// 写回失败原因。
#[derive(Debug, PartialEq, Eq)]
pub enum TagWriteError {
    /// 线格式坏了 / 键不在白名单 / 数字字段不是数字。
    BadInput(String),
    /// 文件读不了或格式不认识。
    Unreadable(String),
    /// 写盘失败（只读、被占用、格式不支持写）。
    WriteFailed(String),
}

fn field_key(name: &str) -> Option<&'static Option<ItemKey>> {
    FIELDS.iter().find(|(k, _)| *k == name).map(|(_, v)| v)
}

/// 解析 `u32 count | (str key | str value)*count`。
pub fn parse_kv(bytes: &[u8]) -> Option<Vec<(String, String)>> {
    let mut pos = 0usize;
    let mut take = |n: usize| -> Option<&[u8]> {
        let end = pos.checked_add(n)?;
        let slice = bytes.get(pos..end)?;
        pos = end;
        Some(slice)
    };
    let count = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
    let mut out = Vec::with_capacity(count.min(64));
    for _ in 0..count {
        let klen = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
        let key = std::str::from_utf8(take(klen)?).ok()?.to_owned();
        let vlen = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
        let value = std::str::from_utf8(take(vlen)?).ok()?.to_owned();
        out.push((key, value));
    }
    if pos != bytes.len() {
        return None;
    }
    Some(out)
}

/// [parse_kv] 的逆。
pub fn encode_kv(pairs: &[(String, String)]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(pairs.len() as u32).to_le_bytes());
    for (k, v) in pairs {
        out.extend_from_slice(&(k.len() as u32).to_le_bytes());
        out.extend_from_slice(k.as_bytes());
        out.extend_from_slice(&(v.len() as u32).to_le_bytes());
        out.extend_from_slice(v.as_bytes());
    }
    out
}

fn read_tag_fields(tag: &Tag) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (name, key) in FIELDS {
        let value = match (name, key) {
            (&"track_no", None) => tag.track().map(|n| n.to_string()),
            (&"disc_no", None) => tag.disk().map(|n| n.to_string()),
            (_, Some(k)) => tag
                .get_string(k)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            _ => None,
        };
        if let Some(v) = value {
            out.push(((*name).to_owned(), v));
        }
    }
    out
}

/// 读出文件主标签里的白名单字段（没有标签 → 空表）。
pub fn read_fields(path: &Path) -> Result<Vec<(String, String)>, TagWriteError> {
    let tagged = Probe::open(path)
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?
        .options(ParseOptions::new().read_cover_art(false))
        .guess_file_type()
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?
        .read()
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?;
    Ok(tagged
        .primary_tag()
        .or_else(|| tagged.first_tag())
        .map(read_tag_fields)
        .unwrap_or_default())
}

/// 把 [pairs] 写进文件主标签（没有主标签就按该格式的主标签类型新建一个）。值为空串 =
/// 删除。整组先校验再动文件：任何一个键不认识 / 数字字段非法，文件一个字节都不改。
pub fn write_fields(path: &Path, pairs: &[(String, String)]) -> Result<(), TagWriteError> {
    for (k, v) in pairs {
        let Some(key) = field_key(k) else {
            return Err(TagWriteError::BadInput(format!("unknown field {k}")));
        };
        if key.is_none() && !v.is_empty() && v.trim().parse::<u32>().is_err() {
            return Err(TagWriteError::BadInput(format!("{k} is not a number: {v}")));
        }
    }
    let mut tagged = Probe::open(path)
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?
        .options(ParseOptions::new())
        .guess_file_type()
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?
        .read()
        .map_err(|e| TagWriteError::Unreadable(e.to_string()))?;
    if tagged.primary_tag().is_none() {
        let tag_type = tagged.primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }
    let Some(tag) = tagged.primary_tag_mut() else {
        return Err(TagWriteError::WriteFailed("no writable tag".into()));
    };
    let mut ufid: Option<String> = None;
    let clears_ufid = pairs
        .iter()
        .any(|(k, v)| k == "mb_recording_id" && v.trim().is_empty());
    let is_id3v2 = tag.tag_type() == TagType::Id3v2;
    for (k, v) in pairs {
        let value = v.trim();
        match (k.as_str(), field_key(k).and_then(|o| o.as_ref())) {
            ("track_no", None) => {
                if value.is_empty() {
                    tag.remove_track();
                } else {
                    tag.set_track(value.parse::<u32>().unwrap_or(0));
                }
            }
            ("disc_no", None) => {
                if value.is_empty() {
                    tag.remove_disk();
                } else {
                    tag.set_disk(value.parse::<u32>().unwrap_or(0));
                }
            }
            (_, Some(item)) => {
                tag.remove_key(item);
                if value.is_empty() || tag.insert_text(item.clone(), value.to_owned()) {
                    continue;
                }
                // ID3v2 的录音 MBID 不是文本帧而是 UFID（owner `http://musicbrainz.org`），
                // 通用 Tag 写不出它：留到通用写盘之后，用 MPEG 专用 API 单独补（见下）。
                if *item == ItemKey::MusicBrainzRecordingId && tag.tag_type() == TagType::Id3v2 {
                    ufid = Some(value.to_owned());
                    continue;
                }
                return Err(TagWriteError::WriteFailed(format!(
                    "{k} is not supported by this tag format"
                )));
            }
            _ => unreachable!("validated above"),
        }
    }
    tagged
        .save_to_path(path, WriteOptions::default())
        .map_err(|e| TagWriteError::WriteFailed(e.to_string()))?;
    if is_id3v2 && (ufid.is_some() || clears_ufid) {
        write_id3v2_ufid(path, ufid.as_deref())?;
    }
    Ok(())
}

/// MusicBrainz 在 ID3v2 里用的 UFID owner（Picard 同值）。
const MUSICBRAINZ_UFID_OWNER: &str = "http://musicbrainz.org";

/// 改写 MPEG 文件 ID3v2 里的 MusicBrainz UFID 帧（`None` = 删除）。
fn write_id3v2_ufid(path: &Path, recording_id: Option<&str>) -> Result<(), TagWriteError> {
    use lofty::id3::v2::{Frame, UniqueFileIdentifierFrame};
    use lofty::mpeg::MpegFile;
    use std::fs::OpenOptions;

    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|e| TagWriteError::WriteFailed(e.to_string()))?;
    let mut mpeg = MpegFile::read_from(&mut file, ParseOptions::new())
        .map_err(|e| TagWriteError::WriteFailed(format!("ID3v2 MBID needs an MPEG file: {e}")))?;
    let Some(tag) = mpeg.id3v2_mut() else {
        return Err(TagWriteError::WriteFailed("no ID3v2 tag".into()));
    };
    tag.retain(|f| {
        !matches!(f, Frame::UniqueFileIdentifier(u) if u.owner == MUSICBRAINZ_UFID_OWNER)
    });
    if let Some(id) = recording_id {
        if !id.is_ascii() {
            return Err(TagWriteError::BadInput("mb_recording_id must be ASCII".into()));
        }
        tag.insert(Frame::UniqueFileIdentifier(UniqueFileIdentifierFrame::new(
            MUSICBRAINZ_UFID_OWNER.to_owned(),
            id.as_bytes().to_vec(),
        )));
    }
    drop(file);
    mpeg.save_to_path(path, WriteOptions::default())
        .map_err(|e| TagWriteError::WriteFailed(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/library")
            .join(name)
    }

    fn copy_to_temp(src: &str, name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ffm_tag_write_{}_{}",
            std::process::id(),
            name.replace(['/', '.', ' '], "_")
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let dst = dir.join(std::path::Path::new(src).file_name().unwrap());
        std::fs::copy(fixture(src), &dst).unwrap();
        dst
    }

    #[test]
    fn kv_round_trip() {
        let pairs = vec![
            ("title".to_owned(), "曲名".to_owned()),
            ("track_no".to_owned(), String::new()),
        ];
        assert_eq!(parse_kv(&encode_kv(&pairs)).unwrap(), pairs);
        assert!(parse_kv(&[1, 0, 0]).is_none());
        let mut trailing = encode_kv(&pairs);
        trailing.push(0);
        assert!(parse_kv(&trailing).is_none());
    }

    #[test]
    fn write_then_read_flac_and_mp3() {
        for src in ["Album A/01 First Song.flac", "Album A/02 Second Song.mp3"] {
            let path = copy_to_temp(src, src);
            let pairs = vec![
                ("title".to_owned(), "新しい曲名".to_owned()),
                ("artist".to_owned(), "歌手".to_owned()),
                ("track_no".to_owned(), "7".to_owned()),
                (
                    "mb_recording_id".to_owned(),
                    "b1a9c0e9-d987-4042-ae91-78d6a3267d69".to_owned(),
                ),
                ("catalog_no".to_owned(), "LACA-15000".to_owned()),
            ];
            write_fields(&path, &pairs).unwrap();
            let back = read_fields(&path).unwrap();
            for (k, v) in &pairs {
                assert!(
                    back.iter().any(|(bk, bv)| bk == k && bv == v),
                    "{src}: {k} missing in {back:?}"
                );
            }
            // 删除：空串。
            write_fields(&path, &[("catalog_no".to_owned(), String::new())]).unwrap();
            let back = read_fields(&path).unwrap();
            assert!(!back.iter().any(|(k, _)| k == "catalog_no"), "{src}: {back:?}");
            // 音频属性不变（track_uid 依赖它们）。
            let before = crate::tags::read_file_meta(&fixture(src)).unwrap();
            let after = crate::tags::read_file_meta(&path).unwrap();
            assert_eq!(before.duration_ms, after.duration_ms);
            assert_eq!(before.sample_rate, after.sample_rate);
            assert_eq!(before.channels, after.channels);
        }
    }

    #[test]
    fn invalid_input_leaves_file_untouched() {
        let path = copy_to_temp("Album A/01 First Song.flac", "invalid");
        let before = std::fs::read(&path).unwrap();
        assert!(matches!(
            write_fields(&path, &[("nope".to_owned(), "x".to_owned())]),
            Err(TagWriteError::BadInput(_))
        ));
        assert!(matches!(
            write_fields(
                &path,
                &[
                    ("title".to_owned(), "x".to_owned()),
                    ("track_no".to_owned(), "seven".to_owned())
                ]
            ),
            Err(TagWriteError::BadInput(_))
        ));
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
}
