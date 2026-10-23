//! 批次二进制格式（小端，Dart 侧 `packages/fushi_music/lib/src/scan_wire.dart` 逐字段对应）。
//!
//! ```text
//! batch   := u32 version (= BATCH_FORMAT_VERSION) | u8 done | u32 count | record*count
//! record  := u8 kind | body
//!   kind 0 track     := str path | str trackUid | opt_i64 cueStartMs | opt_i64 cueEndMs
//!                       | opt_i64 durationMs | opt_str codec | opt_i64 sampleRate
//!                       | opt_i64 bitDepth | opt_i64 channels | opt_i64 bitrateKbps
//!                       | u8 isLossless | str title | opt_str titleSort | opt_str artistCredit
//!                       | opt_str albumTitle | opt_str albumTitleSort | opt_str albumArtist
//!                       | opt_str albumUid | opt_i64 discNo | opt_i64 discTotal
//!                       | opt_i64 trackNo | opt_i64 year | opt_str releaseDate
//!                       | opt_str genre | opt_str catalogNo
//!                       | opt_f64 rgTrackGain | opt_f64 rgTrackPeak
//!                       | opt_f64 rgAlbumGain | opt_f64 rgAlbumPeak
//!                       | opt_str mbRecordingId | opt_str mbWorkId
//!                       | opt_str mbReleaseId | opt_str mbReleaseGroupId
//!                       | i64 fileMtimeMs | i64 fileSize | u8 hasEmbeddedCover
//!                       | opt_str folderCoverPath | opt_str cueSheetPath
//!                       | u32 creditCount | (str role | str name | str artistUid)*creditCount
//!   kind 1 unchanged := str path            （已知文件没变：只报「还在」）
//!   kind 2 error     := str path | str message
//! str     := u32 byteLen | utf8 bytes
//! opt_str := u32 byteLen（0xFFFFFFFF = null）| utf8 bytes
//! opt_i64 := u8 present | i64（present = 0 时仍写 8 字节 0，定长便于读）
//! opt_f64 := u8 present | f64
//! ```
//!
//! 已知文件清单（Dart → Rust，[parse_known_files]）：
//! `u32 count | (str path | i64 mtimeMs | i64 size)*count`。

use std::collections::HashMap;

/// 批次格式版本；改字段必须同时升它与 [crate::ABI_VERSION]。
pub const BATCH_FORMAT_VERSION: u32 = 1;

pub const KIND_TRACK: u8 = 0;
pub const KIND_UNCHANGED: u8 = 1;
pub const KIND_ERROR: u8 = 2;

/// 一首曲目（普通文件或 CUE 虚拟曲目）的扫描结果。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TrackRecord {
    pub path: String,
    pub track_uid: String,
    pub cue_start_ms: Option<i64>,
    pub cue_end_ms: Option<i64>,
    pub duration_ms: Option<i64>,
    pub codec: Option<String>,
    pub sample_rate: Option<i64>,
    pub bit_depth: Option<i64>,
    pub channels: Option<i64>,
    pub bitrate_kbps: Option<i64>,
    pub is_lossless: bool,
    pub title: String,
    pub title_sort: Option<String>,
    pub artist_credit: Option<String>,
    pub album_title: Option<String>,
    pub album_title_sort: Option<String>,
    pub album_artist: Option<String>,
    pub album_uid: Option<String>,
    pub disc_no: Option<i64>,
    pub disc_total: Option<i64>,
    pub track_no: Option<i64>,
    pub year: Option<i64>,
    pub release_date: Option<String>,
    pub genre: Option<String>,
    pub catalog_no: Option<String>,
    pub rg_track_gain: Option<f64>,
    pub rg_track_peak: Option<f64>,
    pub rg_album_gain: Option<f64>,
    pub rg_album_peak: Option<f64>,
    pub mb_recording_id: Option<String>,
    pub mb_work_id: Option<String>,
    pub mb_release_id: Option<String>,
    pub mb_release_group_id: Option<String>,
    pub file_mtime_ms: i64,
    pub file_size: i64,
    pub has_embedded_cover: bool,
    pub folder_cover_path: Option<String>,
    pub cue_sheet_path: Option<String>,
    pub credits: Vec<Credit>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credit {
    pub role: String,
    pub name: String,
    pub artist_uid: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Record {
    Track(Box<TrackRecord>),
    Unchanged(String),
    Error { path: String, message: String },
}

/// 库里已有文件的（修改时刻毫秒, 大小）。
pub type KnownFiles = HashMap<String, (i64, i64)>;

#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn str(&mut self, v: &str) {
        self.u32(v.len() as u32);
        self.buf.extend_from_slice(v.as_bytes());
    }

    pub fn opt_str(&mut self, v: Option<&str>) {
        match v {
            Some(s) => self.str(s),
            None => self.u32(u32::MAX),
        }
    }

    pub fn opt_i64(&mut self, v: Option<i64>) {
        self.u8(v.is_some() as u8);
        self.i64(v.unwrap_or(0));
    }

    pub fn opt_f64(&mut self, v: Option<f64>) {
        self.u8(v.is_some() as u8);
        self.buf.extend_from_slice(&v.unwrap_or(0.0).to_le_bytes());
    }
}

pub fn encode_batch(records: &[Record], done: bool) -> Vec<u8> {
    let mut w = Writer::new();
    w.u32(BATCH_FORMAT_VERSION);
    w.u8(done as u8);
    w.u32(records.len() as u32);
    for r in records {
        match r {
            Record::Track(t) => {
                w.u8(KIND_TRACK);
                write_track(&mut w, t);
            }
            Record::Unchanged(path) => {
                w.u8(KIND_UNCHANGED);
                w.str(path);
            }
            Record::Error { path, message } => {
                w.u8(KIND_ERROR);
                w.str(path);
                w.str(message);
            }
        }
    }
    w.into_bytes()
}

fn write_track(w: &mut Writer, t: &TrackRecord) {
    w.str(&t.path);
    w.str(&t.track_uid);
    w.opt_i64(t.cue_start_ms);
    w.opt_i64(t.cue_end_ms);
    w.opt_i64(t.duration_ms);
    w.opt_str(t.codec.as_deref());
    w.opt_i64(t.sample_rate);
    w.opt_i64(t.bit_depth);
    w.opt_i64(t.channels);
    w.opt_i64(t.bitrate_kbps);
    w.u8(t.is_lossless as u8);
    w.str(&t.title);
    w.opt_str(t.title_sort.as_deref());
    w.opt_str(t.artist_credit.as_deref());
    w.opt_str(t.album_title.as_deref());
    w.opt_str(t.album_title_sort.as_deref());
    w.opt_str(t.album_artist.as_deref());
    w.opt_str(t.album_uid.as_deref());
    w.opt_i64(t.disc_no);
    w.opt_i64(t.disc_total);
    w.opt_i64(t.track_no);
    w.opt_i64(t.year);
    w.opt_str(t.release_date.as_deref());
    w.opt_str(t.genre.as_deref());
    w.opt_str(t.catalog_no.as_deref());
    w.opt_f64(t.rg_track_gain);
    w.opt_f64(t.rg_track_peak);
    w.opt_f64(t.rg_album_gain);
    w.opt_f64(t.rg_album_peak);
    w.opt_str(t.mb_recording_id.as_deref());
    w.opt_str(t.mb_work_id.as_deref());
    w.opt_str(t.mb_release_id.as_deref());
    w.opt_str(t.mb_release_group_id.as_deref());
    w.i64(t.file_mtime_ms);
    w.i64(t.file_size);
    w.u8(t.has_embedded_cover as u8);
    w.opt_str(t.folder_cover_path.as_deref());
    w.opt_str(t.cue_sheet_path.as_deref());
    w.u32(t.credits.len() as u32);
    for c in &t.credits {
        w.str(&c.role);
        w.str(&c.name);
        w.str(&c.artist_uid);
    }
}

/// 小端读取器（测试与已知文件清单解析用）。越界返回 None。
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    pub fn at_end(&self) -> bool {
        self.pos == self.buf.len()
    }

    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }

    pub fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }

    pub fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }

    pub fn i64(&mut self) -> Option<i64> {
        Some(i64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }

    pub fn f64(&mut self) -> Option<f64> {
        Some(f64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }

    pub fn str(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        String::from_utf8(self.take(n)?.to_vec()).ok()
    }

    pub fn opt_str(&mut self) -> Option<Option<String>> {
        let n = self.u32()?;
        if n == u32::MAX {
            return Some(None);
        }
        Some(Some(
            String::from_utf8(self.take(n as usize)?.to_vec()).ok()?,
        ))
    }

    pub fn opt_i64(&mut self) -> Option<Option<i64>> {
        let present = self.u8()?;
        let v = self.i64()?;
        Some((present != 0).then_some(v))
    }

    pub fn opt_f64(&mut self) -> Option<Option<f64>> {
        let present = self.u8()?;
        let v = self.f64()?;
        Some((present != 0).then_some(v))
    }
}

pub fn parse_known_files(bytes: &[u8]) -> Option<KnownFiles> {
    if bytes.is_empty() {
        return Some(KnownFiles::new());
    }
    let mut r = Reader::new(bytes);
    let count = r.u32()? as usize;
    let mut out = KnownFiles::with_capacity(count.min(1 << 20));
    for _ in 0..count {
        let path = r.str()?;
        let mtime = r.i64()?;
        let size = r.i64()?;
        out.insert(path, (mtime, size));
    }
    r.at_end().then_some(out)
}

/// 解码一个批次（测试用；Dart 侧有自己的解码器）。
pub fn decode_batch(bytes: &[u8]) -> Option<(bool, Vec<Record>)> {
    let mut r = Reader::new(bytes);
    if r.u32()? != BATCH_FORMAT_VERSION {
        return None;
    }
    let done = r.u8()? != 0;
    let count = r.u32()? as usize;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        match r.u8()? {
            KIND_TRACK => out.push(Record::Track(Box::new(read_track(&mut r)?))),
            KIND_UNCHANGED => out.push(Record::Unchanged(r.str()?)),
            KIND_ERROR => out.push(Record::Error {
                path: r.str()?,
                message: r.str()?,
            }),
            _ => return None,
        }
    }
    r.at_end().then_some((done, out))
}

fn read_track(r: &mut Reader<'_>) -> Option<TrackRecord> {
    let mut t = TrackRecord {
        path: r.str()?,
        track_uid: r.str()?,
        cue_start_ms: r.opt_i64()?,
        cue_end_ms: r.opt_i64()?,
        duration_ms: r.opt_i64()?,
        codec: r.opt_str()?,
        sample_rate: r.opt_i64()?,
        bit_depth: r.opt_i64()?,
        channels: r.opt_i64()?,
        bitrate_kbps: r.opt_i64()?,
        is_lossless: r.u8()? != 0,
        title: r.str()?,
        title_sort: r.opt_str()?,
        artist_credit: r.opt_str()?,
        album_title: r.opt_str()?,
        album_title_sort: r.opt_str()?,
        album_artist: r.opt_str()?,
        album_uid: r.opt_str()?,
        disc_no: r.opt_i64()?,
        disc_total: r.opt_i64()?,
        track_no: r.opt_i64()?,
        year: r.opt_i64()?,
        release_date: r.opt_str()?,
        genre: r.opt_str()?,
        catalog_no: r.opt_str()?,
        rg_track_gain: r.opt_f64()?,
        rg_track_peak: r.opt_f64()?,
        rg_album_gain: r.opt_f64()?,
        rg_album_peak: r.opt_f64()?,
        mb_recording_id: r.opt_str()?,
        mb_work_id: r.opt_str()?,
        mb_release_id: r.opt_str()?,
        mb_release_group_id: r.opt_str()?,
        file_mtime_ms: r.i64()?,
        file_size: r.i64()?,
        has_embedded_cover: r.u8()? != 0,
        folder_cover_path: r.opt_str()?,
        cue_sheet_path: r.opt_str()?,
        credits: Vec::new(),
    };
    let n = r.u32()? as usize;
    for _ in 0..n {
        t.credits.push(Credit {
            role: r.str()?,
            name: r.str()?,
            artist_uid: r.str()?,
        });
    }
    Some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_roundtrip() {
        let t = TrackRecord {
            path: "/a/b.flac".into(),
            track_uid: "uid".into(),
            cue_start_ms: Some(0),
            rg_track_gain: Some(-7.5),
            title: "曲".into(),
            credits: vec![Credit {
                role: "artist".into(),
                name: "X".into(),
                artist_uid: "u".into(),
            }],
            ..Default::default()
        };
        let records = vec![
            Record::Track(Box::new(t)),
            Record::Unchanged("/c.mp3".into()),
            Record::Error {
                path: "/d.ape".into(),
                message: "bad".into(),
            },
        ];
        let bytes = encode_batch(&records, true);
        assert_eq!(decode_batch(&bytes), Some((true, records)));
    }

    #[test]
    fn known_files_parse() {
        let mut w = Writer::new();
        w.u32(1);
        w.str("/x.flac");
        w.i64(5);
        w.i64(6);
        let known = parse_known_files(&w.into_bytes()).unwrap();
        assert_eq!(known.get("/x.flac"), Some(&(5, 6)));
        assert!(parse_known_files(&[1, 0, 0]).is_none());
    }
}
