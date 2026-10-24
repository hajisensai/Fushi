//! 目录扫描游标：深度优先、按名字排序（同一棵树每次产出同一顺序），每次 [Scanner::next_batch]
//! 至多吐 [MAX_BATCH] 条记录。
//!
//! 一个目录展开时先认 `.cue`：被 CUE 引用的整轨文件按 CUE 拆成虚拟曲目、不再作为普通
//! 文件出现；其余音频文件各成一首（FLAC 内嵌 CUESHEET 也在这里拆）。

use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::cue::{self, CueSheet, CueTrack};
use crate::tags::{self, FileMeta};
use crate::uid::{self, AudioFingerprint};
use crate::wire::{self, Credit, KnownFiles, Record, TrackRecord};

/// 每批记录上限（设计 §4.1：每批 ≥256 条的粗粒度；这里取上限 256，调用方可以要更少）。
pub const MAX_BATCH: usize = 256;

/// 目录封面候选名（不含扩展名，小写），按优先级。
const COVER_STEMS: &[&str] = &["cover", "folder", "front", "album", "albumart"];
const COVER_EXTS: &[&str] = &["jpg", "jpeg", "png", "webp"];

enum Item {
    Audio {
        path: PathBuf,
        folder_cover: Option<String>,
    },
    Cue {
        audio: PathBuf,
        sheet: Box<CueSheet>,
        file_index: usize,
        cue_path: PathBuf,
        cue_mtime_ms: i64,
        folder_cover: Option<String>,
    },
    Error {
        path: PathBuf,
        message: String,
    },
}

pub struct Scanner {
    dirs: Vec<PathBuf>,
    recursive: bool,
    pending: VecDeque<Item>,
    /// 一个条目可能展开成多条记录（一张 CUE = N 首）；超出本批上限的留到下一批，
    /// 批次上限是硬上限。
    ready: VecDeque<Record>,
    known: KnownFiles,
}

fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn ext_lower(p: &Path) -> String {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default()
}

fn mtime_ms(meta: &fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn file_stem(p: &Path) -> String {
    p.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

impl Scanner {
    pub fn open(root: &str, recursive: bool) -> Option<Self> {
        let root = PathBuf::from(root);
        if !root.is_dir() {
            return None;
        }
        Some(Self {
            dirs: vec![root],
            recursive,
            pending: VecDeque::new(),
            ready: VecDeque::new(),
            known: KnownFiles::new(),
        })
    }

    pub fn set_known(&mut self, known: KnownFiles) {
        self.known = known;
    }

    /// 下一批（编码好的批次字节）。
    pub fn next_batch(&mut self, max: usize) -> Vec<u8> {
        let max = if max == 0 || max > MAX_BATCH {
            MAX_BATCH
        } else {
            max
        };
        let mut out: Vec<Record> = Vec::new();
        loop {
            while out.len() < max {
                match self.ready.pop_front() {
                    Some(r) => out.push(r),
                    None => break,
                }
            }
            if out.len() >= max {
                break;
            }
            let Some(item) = self.pending.pop_front() else {
                match self.dirs.pop() {
                    Some(dir) => {
                        self.expand_dir(&dir);
                        continue;
                    }
                    None => break,
                }
            };
            let produced = self.process(item);
            self.ready.extend(produced);
        }
        let done = self.ready.is_empty() && self.pending.is_empty() && self.dirs.is_empty();
        wire::encode_batch(&out, done)
    }

    fn expand_dir(&mut self, dir: &Path) {
        let entries = match fs::read_dir(dir) {
            Ok(rd) => rd,
            Err(e) => {
                self.pending.push_back(Item::Error {
                    path: dir.to_path_buf(),
                    message: e.to_string(),
                });
                return;
            }
        };
        let mut files: Vec<PathBuf> = Vec::new();
        let mut subdirs: Vec<PathBuf> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            match entry.file_type() {
                Ok(t) if t.is_dir() => subdirs.push(path),
                Ok(t) if t.is_file() => files.push(path),
                // 符号链接：跟随到文件（目录链接不跟，避免环）。
                Ok(t) if t.is_symlink() && path.is_file() => files.push(path),
                _ => {}
            }
        }
        files.sort();
        subdirs.sort();
        if self.recursive {
            // 栈：逆序压入，按名字顺序弹出。
            for d in subdirs.into_iter().rev() {
                self.dirs.push(d);
            }
        }

        let folder_cover = find_folder_cover(&files);
        let mut covered: HashSet<PathBuf> = HashSet::new();
        let mut items: Vec<Item> = Vec::new();
        for cue_path in files.iter().filter(|p| ext_lower(p) == "cue") {
            let (bytes, cue_mtime) = match fs::read(cue_path)
                .and_then(|b| fs::metadata(cue_path).map(|m| (b, mtime_ms(&m))))
            {
                Ok(v) => v,
                Err(e) => {
                    items.push(Item::Error {
                        path: cue_path.clone(),
                        message: e.to_string(),
                    });
                    continue;
                }
            };
            let Some(sheet) = cue::parse(&cue::decode_text(&bytes)) else {
                continue;
            };
            for (file_index, f) in sheet.files.iter().enumerate() {
                let Some(audio) = resolve_cue_audio(&f.name, &files) else {
                    continue;
                };
                if !covered.insert(audio.clone()) {
                    continue; // 同一个整轨被两张 CUE 引用：先到先得。
                }
                items.push(Item::Cue {
                    audio,
                    sheet: Box::new(sheet.clone()),
                    file_index,
                    cue_path: cue_path.clone(),
                    cue_mtime_ms: cue_mtime,
                    folder_cover: folder_cover.clone(),
                });
            }
        }
        for f in &files {
            if covered.contains(f) || !tags::is_audio_extension(&ext_lower(f)) {
                continue;
            }
            items.push(Item::Audio {
                path: f.clone(),
                folder_cover: folder_cover.clone(),
            });
        }
        // 按音频路径排序，CUE 与普通文件交错时顺序仍稳定。
        items.sort_by(|a, b| item_path(a).cmp(item_path(b)));
        self.pending.extend(items);
    }

    fn is_unchanged(&self, path: &str, mtime: i64, size: i64) -> bool {
        self.known.get(path) == Some(&(mtime, size))
    }

    fn process(&self, item: Item) -> Vec<Record> {
        match item {
            Item::Error { path, message } => vec![Record::Error {
                path: path_str(&path),
                message,
            }],
            Item::Audio { path, folder_cover } => {
                let ps = path_str(&path);
                let fs_meta = match fs::metadata(&path) {
                    Ok(m) => m,
                    Err(e) => {
                        return vec![Record::Error {
                            path: ps,
                            message: e.to_string(),
                        }]
                    }
                };
                let (mtime, size) = (mtime_ms(&fs_meta), fs_meta.len() as i64);
                if self.is_unchanged(&ps, mtime, size) {
                    return vec![Record::Unchanged(ps)];
                }
                let meta = match tags::read_file_meta(&path) {
                    Ok(m) => m,
                    Err(message) => return vec![Record::Error { path: ps, message }],
                };
                if let Some(tracks) = embedded_cue_tracks(&path, &meta) {
                    let sheet = meta
                        .embedded_cuesheet
                        .as_deref()
                        .and_then(cue::parse)
                        .unwrap_or_default();
                    return tracks
                        .iter()
                        .map(|t| {
                            Record::Track(Box::new(cue_track_record(
                                &path,
                                &meta,
                                &sheet,
                                t,
                                mtime,
                                size,
                                folder_cover.clone(),
                                None,
                            )))
                        })
                        .collect();
                }
                vec![Record::Track(Box::new(plain_record(
                    &path,
                    &meta,
                    mtime,
                    size,
                    folder_cover,
                )))]
            }
            Item::Cue {
                audio,
                sheet,
                file_index,
                cue_path,
                cue_mtime_ms,
                folder_cover,
            } => {
                let ps = path_str(&audio);
                let fs_meta = match fs::metadata(&audio) {
                    Ok(m) => m,
                    Err(e) => {
                        return vec![Record::Error {
                            path: ps,
                            message: e.to_string(),
                        }]
                    }
                };
                // 改 CUE 也要重解析：有效修改时刻取两者较新的。
                let mtime = mtime_ms(&fs_meta).max(cue_mtime_ms);
                let size = fs_meta.len() as i64;
                if self.is_unchanged(&ps, mtime, size) {
                    return vec![Record::Unchanged(ps)];
                }
                let meta = match tags::read_file_meta(&audio) {
                    Ok(m) => m,
                    Err(message) => return vec![Record::Error { path: ps, message }],
                };
                let cue_ps = path_str(&cue_path);
                sheet.files[file_index]
                    .tracks
                    .iter()
                    .map(|t| {
                        Record::Track(Box::new(cue_track_record(
                            &audio,
                            &meta,
                            &sheet,
                            t,
                            mtime,
                            size,
                            folder_cover.clone(),
                            Some(cue_ps.clone()),
                        )))
                    })
                    .collect()
            }
        }
    }
}

fn item_path(i: &Item) -> &Path {
    match i {
        Item::Audio { path, .. } | Item::Error { path, .. } => path,
        Item::Cue { audio, .. } => audio,
    }
}

fn find_folder_cover(files: &[PathBuf]) -> Option<String> {
    for stem in COVER_STEMS {
        for f in files {
            let ext = ext_lower(f);
            if COVER_EXTS.contains(&ext.as_str()) && file_stem(f).eq_ignore_ascii_case(stem) {
                return Some(path_str(f));
            }
        }
    }
    None
}

/// CUE 的 FILE 名 → 目录里实际的音频文件。原名找不到时按同名换扩展名找（CUE 写
/// `x.wav`、实际转成了 `x.flac` 是最常见的情况）；大小写不敏感。
fn resolve_cue_audio(name: &str, files: &[PathBuf]) -> Option<PathBuf> {
    let base = Path::new(name)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())?;
    if let Some(f) = files.iter().find(|f| {
        f.file_name()
            .map(|n| n.to_string_lossy().eq_ignore_ascii_case(&base))
            .unwrap_or(false)
    }) {
        if tags::is_audio_extension(&ext_lower(f)) {
            return Some(f.clone());
        }
    }
    let stem = file_stem(Path::new(&base));
    files
        .iter()
        .find(|f| {
            file_stem(f).eq_ignore_ascii_case(&stem) && tags::is_audio_extension(&ext_lower(f))
        })
        .cloned()
}

/// FLAC 内嵌 CUE：先认 Vorbis 注释里的 `CUESHEET` 文本（有标题），没有再读元数据块里的
/// 二进制 CUESHEET（只有起点）。只有一首、从 0 开始的不算拆轨（那就是普通单曲）。
fn embedded_cue_tracks(path: &Path, meta: &FileMeta) -> Option<Vec<CueTrack>> {
    if meta.codec.as_deref() != Some("flac") {
        return None;
    }
    let tracks = match meta.embedded_cuesheet.as_deref().and_then(cue::parse) {
        Some(sheet) => sheet.files.into_iter().next().map(|f| f.tracks),
        None => read_flac_head(path).and_then(|h| cue::parse_flac_cuesheet_block(&h)),
    }?;
    if tracks.len() < 2 && tracks.first().map(|t| t.start_ms) == Some(0) {
        return None;
    }
    Some(tracks)
}

fn read_flac_head(path: &Path) -> Option<Vec<u8>> {
    use std::io::Read;
    // 元数据块都在文件头；CUESHEET 很小，但前面可能有大 PICTURE 块，读 16 MiB 封顶。
    let mut f = fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    f.by_ref().take(16 << 20).read_to_end(&mut buf).ok()?;
    Some(buf)
}

fn credits_of(meta: &FileMeta, artists: &[String], album_artist: Option<&str>) -> Vec<Credit> {
    let mut out: Vec<Credit> = Vec::new();
    let mut push = |role: &str, name: &str| {
        let artist_uid = uid::artist_uid(name);
        if out
            .iter()
            .any(|c| c.role == role && c.artist_uid == artist_uid)
        {
            return;
        }
        out.push(Credit {
            role: role.into(),
            name: name.into(),
            artist_uid,
        });
    };
    for a in artists {
        push("artist", a);
    }
    if let Some(a) = album_artist {
        push("album_artist", a);
    }
    for c in &meta.composers {
        push("composer", c);
    }
    for l in &meta.lyricists {
        push("lyricist", l);
    }
    for a in &meta.arrangers {
        push("arranger", a);
    }
    out
}

fn fingerprint(meta: &FileMeta) -> AudioFingerprint {
    AudioFingerprint {
        duration_ms: meta.duration_ms,
        sample_rate: meta.sample_rate,
        channels: meta.channels,
    }
}

fn dir_of(path: &Path) -> String {
    path.parent().map(path_str).unwrap_or_default()
}

fn plain_record(
    path: &Path,
    meta: &FileMeta,
    mtime: i64,
    size: i64,
    folder_cover: Option<String>,
) -> TrackRecord {
    let ps = path_str(path);
    let album_uid = meta
        .album
        .as_deref()
        .map(|a| uid::album_uid(a, meta.album_artist.as_deref(), &dir_of(path)));
    TrackRecord {
        track_uid: uid::track_uid(&ps, None, fingerprint(meta)),
        path: ps,
        cue_start_ms: None,
        cue_end_ms: None,
        duration_ms: meta.duration_ms,
        codec: meta.codec.clone(),
        sample_rate: meta.sample_rate,
        bit_depth: meta.bit_depth,
        channels: meta.channels,
        bitrate_kbps: meta.bitrate_kbps,
        is_lossless: meta.is_lossless,
        title: meta.title.clone().unwrap_or_else(|| file_stem(path)),
        title_sort: meta.title_sort.clone(),
        artist_credit: (!meta.artists.is_empty()).then(|| meta.artists.join(" / ")),
        album_title: meta.album.clone(),
        album_title_sort: meta.album_sort.clone(),
        album_artist: meta.album_artist.clone(),
        album_uid,
        disc_no: meta.disc_no,
        disc_total: meta.disc_total,
        track_no: meta.track_no,
        year: meta.year,
        release_date: meta.release_date.clone(),
        genre: meta.genre.clone(),
        catalog_no: meta.catalog_no.clone(),
        rg_track_gain: meta.rg_track_gain,
        rg_track_peak: meta.rg_track_peak,
        rg_album_gain: meta.rg_album_gain,
        rg_album_peak: meta.rg_album_peak,
        mb_recording_id: meta.mb_recording_id.clone(),
        mb_work_id: meta.mb_work_id.clone(),
        mb_release_id: meta.mb_release_id.clone(),
        mb_release_group_id: meta.mb_release_group_id.clone(),
        file_mtime_ms: mtime,
        file_size: size,
        has_embedded_cover: meta.has_embedded_cover,
        folder_cover_path: folder_cover,
        cue_sheet_path: None,
        credits: credits_of(meta, &meta.artists, meta.album_artist.as_deref()),
    }
}

#[allow(clippy::too_many_arguments)]
fn cue_track_record(
    audio: &Path,
    meta: &FileMeta,
    sheet: &CueSheet,
    t: &CueTrack,
    mtime: i64,
    size: i64,
    folder_cover: Option<String>,
    cue_sheet_path: Option<String>,
) -> TrackRecord {
    let ps = path_str(audio);
    let artists: Vec<String> = match t.performer.clone().or_else(|| sheet.performer.clone()) {
        Some(p) => vec![p],
        None => meta.artists.clone(),
    };
    let album = sheet.title.clone().or_else(|| meta.album.clone());
    let album_artist = sheet
        .performer
        .clone()
        .or_else(|| meta.album_artist.clone());
    let album_uid = album
        .as_deref()
        .map(|a| uid::album_uid(a, album_artist.as_deref(), &dir_of(audio)));
    let duration = match t.end_ms {
        Some(end) => Some(end - t.start_ms),
        None => meta.duration_ms.map(|d| (d - t.start_ms).max(0)),
    };
    let release_date = sheet.date.clone().or_else(|| meta.release_date.clone());
    let mut file_meta_for_credits = meta.clone();
    if let Some(sw) = t.songwriter.clone().or_else(|| sheet.songwriter.clone()) {
        file_meta_for_credits.composers = vec![sw];
    }
    TrackRecord {
        track_uid: uid::track_uid(&ps, Some(t.start_ms), fingerprint(meta)),
        path: ps,
        cue_start_ms: Some(t.start_ms),
        cue_end_ms: t.end_ms,
        duration_ms: duration,
        codec: meta.codec.clone(),
        sample_rate: meta.sample_rate,
        bit_depth: meta.bit_depth,
        channels: meta.channels,
        bitrate_kbps: meta.bitrate_kbps,
        is_lossless: meta.is_lossless,
        title: t
            .title
            .clone()
            .unwrap_or_else(|| format!("Track {:02}", t.number)),
        title_sort: None,
        artist_credit: (!artists.is_empty()).then(|| artists.join(" / ")),
        album_title: album,
        album_title_sort: None,
        album_artist: album_artist.clone(),
        album_uid,
        disc_no: sheet.disc_number.or(meta.disc_no),
        disc_total: sheet.total_discs.or(meta.disc_total),
        track_no: Some(t.number as i64),
        year: release_date
            .as_deref()
            .and_then(tags::year_of)
            .or(meta.year),
        release_date,
        genre: sheet.genre.clone().or_else(|| meta.genre.clone()),
        catalog_no: sheet.catalog.clone().or_else(|| meta.catalog_no.clone()),
        // 整轨文件的 track gain 量的是整张碟，不适用于其中一段：不继承。
        rg_track_gain: None,
        rg_track_peak: None,
        rg_album_gain: sheet.album_gain.or(meta.rg_album_gain),
        rg_album_peak: sheet.album_peak.or(meta.rg_album_peak),
        mb_recording_id: None,
        mb_work_id: None,
        mb_release_id: meta.mb_release_id.clone(),
        mb_release_group_id: meta.mb_release_group_id.clone(),
        file_mtime_ms: mtime,
        file_size: size,
        has_embedded_cover: meta.has_embedded_cover,
        folder_cover_path: folder_cover,
        cue_sheet_path,
        credits: credits_of(&file_meta_for_credits, &artists, album_artist.as_deref()),
    }
}
