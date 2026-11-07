//! 远程曲库扫描（SFTP / WebDAV / AList 来源，反馈 QAondMh4M5）：网络 I/O 留在 Dart 现有的
//! 来源访问层（`SourceFileSystem` / 字节区间读取），这里只做**分类、CUE 拆轨、uid 与标签
//! 解析**——与本地扫描（[crate::scan]）同一套记录构造、同一套 uid 规则。
//!
//! 输入是 Dart 列好的**文件清单**（路径原文 + 修改时刻 + 大小）和清单里每张 `.cue` 的
//! **原始字节**（编码由 [cue::decode_text] 判，Shift-JIS 的日文 CUE 不经 UTF-8 转一手）。
//! 路径是不透明串，只按最后一个 `/` 切目录与文件名（`https://…` / `sftp://…` 都适用）。
//!
//! 标签解析需要文件字节：游标是一个**请求-喂数据**的状态机。[RemoteScanner::step] 要么交回
//! 一批记录（与本地扫描同一批次格式），要么交回「当前文件缺这几段字节」（NEED）；Dart 按
//! 区间取回后 [RemoteScanner::feed]，再 step。解析跑在稀疏缓冲（[SparseReader]）上：lofty
//! 读到没取到的区间时记下缺口，整次解析作废、取回后从头再解析（lofty 吞掉 IO 错误继续
//! 走的情况也按缺口处理，不会拿残缺数据出结果）。首轮先取文件头 256 KiB + 尾 128 KiB，
//! 绝大多数格式一轮收敛；单文件累计取数超过 [FETCH_CAP] 时按扩展名推断收尾（与 lofty 认
//! 不出的格式同语义），不无限取。
//!
//! 远程文件没有本地路径可供之后再读内嵌封面：解析时顺带取出封面字节，作为一条
//! [Record::Cover] 排在该文件的曲目记录之前交给 Dart 落进封面缓存。

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::{self, Read, Seek, SeekFrom};

use crate::cue::{self, CueSheet};
use crate::scan::{self, Loc};
use crate::tags::{self, FileMeta};
use crate::wire::{self, KnownFiles, Reader, Record, Writer};

/// 清单格式版本（[parse_listing]）。
pub const LISTING_FORMAT_VERSION: u32 = 1;

/// 首轮预取：文件头。
pub const HEAD_PREFETCH: u64 = 256 << 10;

/// 首轮预取：文件尾（ID3v1 / APEv2 / MP4 尾部 moov / Ogg 末页）。
pub const TAIL_PREFETCH: u64 = 128 << 10;

/// 缺口补取的最小块，之后每轮翻倍（上限 [MAX_CHUNK]）。
pub const MIN_CHUNK: u64 = 64 << 10;
const MAX_CHUNK: u64 = 4 << 20;

/// 单文件累计取数上限（与本地 FLAC 头读 16 MiB 封顶一致：前面可能有大 PICTURE 块）。
pub const FETCH_CAP: u64 = 16 << 20;

/// 清单里的一个文件。`mtime_ms` / `size` 为负 = 来源没给（这样的文件每次都重新解析）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListedFile {
    pub path: String,
    pub mtime_ms: i64,
    pub size: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Listing {
    pub root: String,
    pub files: Vec<ListedFile>,
    /// `.cue` 路径 → 原始字节。
    pub cues: HashMap<String, Vec<u8>>,
}

/// ```text
/// listing := u32 version (= LISTING_FORMAT_VERSION) | str root
///            | u32 count | (str path | i64 mtimeMs | i64 size)*count
///            | u32 cueCount | (str cuePath | u32 byteLen | bytes)*cueCount
/// ```
pub fn parse_listing(bytes: &[u8]) -> Option<Listing> {
    let mut r = Reader::new(bytes);
    if r.u32()? != LISTING_FORMAT_VERSION {
        return None;
    }
    let root = r.str()?;
    let count = r.u32()? as usize;
    let mut files = Vec::with_capacity(count.min(1 << 20));
    for _ in 0..count {
        files.push(ListedFile {
            path: r.str()?,
            mtime_ms: r.i64()?,
            size: r.i64()?,
        });
    }
    let cue_count = r.u32()? as usize;
    let mut cues = HashMap::with_capacity(cue_count.min(1 << 16));
    for _ in 0..cue_count {
        let path = r.str()?;
        let bytes = r.bytes()?;
        cues.insert(path, bytes);
    }
    r.at_end().then_some(Listing { root, files, cues })
}

/// [parse_listing] 的逆（测试与 Dart 侧编码对照用）。
pub fn encode_listing(l: &Listing) -> Vec<u8> {
    let mut w = Writer::new();
    w.u32(LISTING_FORMAT_VERSION);
    w.str(&l.root);
    w.u32(l.files.len() as u32);
    for f in &l.files {
        w.str(&f.path);
        w.i64(f.mtime_ms);
        w.i64(f.size);
    }
    let mut cues: Vec<(&String, &Vec<u8>)> = l.cues.iter().collect();
    cues.sort();
    w.u32(cues.len() as u32);
    for (p, b) in cues {
        w.str(p);
        w.bytes(b);
    }
    w.into_bytes()
}

fn split_dir(path: &str) -> (&str, &str) {
    match path.rfind('/') {
        Some(i) => (&path[..i], &path[i + 1..]),
        None => ("", path),
    }
}

fn stem_ext(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_owned(), name[i + 1..].to_ascii_lowercase()),
        _ => (name.to_owned(), String::new()),
    }
}

/// 根以下任何一段以 `.` 开头（隐藏文件 / 目录）：与本地扫描同样跳过。
fn is_hidden(root: &str, path: &str) -> bool {
    let rel = path
        .strip_prefix(root.trim_end_matches('/'))
        .unwrap_or_else(|| split_dir(path).1);
    rel.split('/').any(|seg| seg.starts_with('.'))
}

#[derive(Debug, Clone)]
struct FileRef {
    path: String,
    name: String,
    stem: String,
    ext: String,
    mtime_ms: i64,
    size: i64,
}

impl FileRef {
    fn loc(&self) -> Loc {
        Loc {
            path: self.path.clone(),
            stem: self.stem.clone(),
            dir: split_dir(&self.path).0.to_owned(),
        }
    }
}

enum Item {
    Audio {
        file: FileRef,
        folder_cover: Option<String>,
    },
    Cue {
        audio: FileRef,
        sheet: Box<CueSheet>,
        file_index: usize,
        cue_path: String,
        cue_mtime_ms: i64,
        folder_cover: Option<String>,
    },
    Error {
        path: String,
        message: String,
    },
}

impl Item {
    fn audio(&self) -> Option<&FileRef> {
        match self {
            Item::Audio { file, .. } => Some(file),
            Item::Cue { audio, .. } => Some(audio),
            Item::Error { .. } => None,
        }
    }

    /// 判「没变」用的（修改时刻, 大小）：改 CUE 也要重解析，修改时刻取两者较新的；
    /// 任一方不知道就当不知道。
    fn version(&self) -> (i64, i64) {
        match self {
            Item::Audio { file, .. } => (file.mtime_ms, file.size),
            Item::Cue {
                audio,
                cue_mtime_ms,
                ..
            } => {
                let m = if audio.mtime_ms < 0 || *cue_mtime_ms < 0 {
                    -1
                } else {
                    audio.mtime_ms.max(*cue_mtime_ms)
                };
                (m, audio.size)
            }
            Item::Error { .. } => (-1, -1),
        }
    }
}

/// 按目录分组成扫描条目（目录按路径排序、目录内按音频路径排序，同一份清单每次同序）。
fn plan_items(listing: &Listing) -> VecDeque<Item> {
    let mut dirs: BTreeMap<String, Vec<FileRef>> = BTreeMap::new();
    for f in &listing.files {
        if is_hidden(&listing.root, &f.path) {
            continue;
        }
        let (dir, name) = split_dir(&f.path);
        if name.is_empty() {
            continue;
        }
        let (stem, ext) = stem_ext(name);
        dirs.entry(dir.to_owned()).or_default().push(FileRef {
            path: f.path.clone(),
            name: name.to_owned(),
            stem,
            ext,
            mtime_ms: f.mtime_ms,
            size: f.size,
        });
    }
    let mut out = VecDeque::new();
    for (_, mut files) in dirs {
        files.sort_by(|a, b| a.path.cmp(&b.path));
        let folder_cover = scan::choose_folder_cover(&files, |f| (f.stem.clone(), f.ext.clone()))
            .map(|f| f.path.clone());
        let mut covered: Vec<String> = Vec::new();
        let mut items: Vec<Item> = Vec::new();
        for cue_file in files.iter().filter(|f| f.ext == "cue") {
            let Some(bytes) = listing.cues.get(&cue_file.path) else {
                items.push(Item::Error {
                    path: cue_file.path.clone(),
                    message: "cue sheet bytes were not provided".into(),
                });
                continue;
            };
            let Some(sheet) = cue::parse(&cue::decode_text(bytes)) else {
                continue;
            };
            for (file_index, cf) in sheet.files.iter().enumerate() {
                let Some(audio) = scan::choose_cue_audio(&cf.name, &files, |f| {
                    (f.name.clone(), f.stem.clone(), f.ext.clone())
                }) else {
                    continue;
                };
                if covered.contains(&audio.path) {
                    continue; // 同一个整轨被两张 CUE 引用：先到先得。
                }
                covered.push(audio.path.clone());
                items.push(Item::Cue {
                    audio: audio.clone(),
                    sheet: Box::new(sheet.clone()),
                    file_index,
                    cue_path: cue_file.path.clone(),
                    cue_mtime_ms: cue_file.mtime_ms,
                    folder_cover: folder_cover.clone(),
                });
            }
        }
        for f in &files {
            if covered.contains(&f.path) || !tags::is_audio_extension(&f.ext) {
                continue;
            }
            items.push(Item::Audio {
                file: f.clone(),
                folder_cover: folder_cover.clone(),
            });
        }
        items.sort_by(|a, b| item_path(a).cmp(item_path(b)));
        out.extend(items);
    }
    out
}

fn item_path(i: &Item) -> &str {
    match i {
        Item::Audio { file, .. } => &file.path,
        Item::Cue { audio, .. } => &audio.path,
        Item::Error { path, .. } => path,
    }
}

/// 已取到的字节区间（按起点排序、互不重叠——插入时合并）。
#[derive(Debug, Default)]
pub struct SparseBuf {
    chunks: Vec<(u64, Vec<u8>)>,
    fetched: u64,
}

impl SparseBuf {
    pub fn insert(&mut self, offset: u64, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        self.fetched += data.len() as u64;
        let end = offset + data.len() as u64;
        let mut start = offset;
        let mut merged_end = end;
        let mut keep: Vec<(u64, Vec<u8>)> = Vec::new();
        let mut overlapping: Vec<(u64, Vec<u8>)> = Vec::new();
        for (s, d) in self.chunks.drain(..) {
            let e = s + d.len() as u64;
            if e < start || s > merged_end {
                keep.push((s, d));
            } else {
                start = start.min(s);
                merged_end = merged_end.max(e);
                overlapping.push((s, d));
            }
        }
        let mut buf = vec![0u8; (merged_end - start) as usize];
        for (s, d) in &overlapping {
            let o = (s - start) as usize;
            buf[o..o + d.len()].copy_from_slice(d);
        }
        // 新数据覆盖旧数据。
        let o = (offset - start) as usize;
        buf[o..o + data.len()].copy_from_slice(data);
        keep.push((start, buf));
        keep.sort_by_key(|(s, _)| *s);
        self.chunks = keep;
    }

    fn find(&self, pos: u64) -> Option<(u64, &[u8])> {
        let idx = self.chunks.partition_point(|(s, _)| *s <= pos);
        let (s, d) = self.chunks.get(idx.checked_sub(1)?)?;
        (pos < s + d.len() as u64).then_some((*s, d.as_slice()))
    }

    /// 累计喂进来的字节数（含重叠部分）。
    pub fn fetched(&self) -> u64 {
        self.fetched
    }
}

/// 稀疏缓冲上的 Read + Seek：读到没取到的区间时记下第一个缺口并返回 IO 错误。
pub struct SparseReader<'a> {
    buf: &'a SparseBuf,
    size: u64,
    pos: u64,
    missing: Option<(u64, u64)>,
}

impl<'a> SparseReader<'a> {
    pub fn new(buf: &'a SparseBuf, size: u64) -> Self {
        Self {
            buf,
            size,
            pos: 0,
            missing: None,
        }
    }

    /// 第一个缺口（起点, 想读的长度）。
    pub fn missing(&self) -> Option<(u64, u64)> {
        self.missing
    }
}

impl Read for SparseReader<'_> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() || self.pos >= self.size {
            return Ok(0);
        }
        let want = (out.len() as u64).min(self.size - self.pos);
        match self.buf.find(self.pos) {
            Some((start, data)) => {
                let off = (self.pos - start) as usize;
                let n = ((data.len() - off) as u64).min(want) as usize;
                out[..n].copy_from_slice(&data[off..off + n]);
                self.pos += n as u64;
                Ok(n)
            }
            None => {
                if self.missing.is_none() {
                    self.missing = Some((self.pos, want));
                }
                Err(io::Error::other("fushi_music: byte range not fetched yet"))
            }
        }
    }
}

impl Seek for SparseReader<'_> {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let next = match to {
            SeekFrom::Start(p) => p as i128,
            SeekFrom::End(d) => self.size as i128 + d as i128,
            SeekFrom::Current(d) => self.pos as i128 + d as i128,
        };
        if next < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek before start",
            ));
        }
        self.pos = next as u64;
        Ok(self.pos)
    }
}

/// FLAC 元数据块里只拼出 STREAMINFO + CUESHEET（跳过中间可能很大的 PICTURE / PADDING），
/// 交给 [cue::parse_flac_cuesheet_block]。
fn flac_cue_head<R: Read + Seek>(r: &mut R) -> Option<Vec<u8>> {
    r.seek(SeekFrom::Start(0)).ok()?;
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic).ok()?;
    if &magic != b"fLaC" {
        return None;
    }
    let mut blocks: Vec<(u8, Vec<u8>)> = Vec::new();
    loop {
        let mut h = [0u8; 4];
        r.read_exact(&mut h).ok()?;
        let last = h[0] & 0x80 != 0;
        let kind = h[0] & 0x7F;
        let len = ((h[1] as u64) << 16) | ((h[2] as u64) << 8) | h[3] as u64;
        if kind == 0 || kind == 5 {
            let mut body = vec![0u8; len as usize];
            r.read_exact(&mut body).ok()?;
            blocks.push((kind, body));
            if kind == 5 {
                break;
            }
        } else {
            r.seek(SeekFrom::Current(len as i64)).ok()?;
        }
        if last {
            break;
        }
    }
    let mut head = b"fLaC".to_vec();
    let n = blocks.len();
    for (i, (kind, body)) in blocks.into_iter().enumerate() {
        let flag = if i + 1 == n { 0x80 } else { 0 };
        head.push(flag | kind);
        let len = body.len() as u32;
        head.extend_from_slice(&len.to_be_bytes()[1..]);
        head.extend_from_slice(&body);
    }
    Some(head)
}

struct Work {
    item: Item,
    buf: SparseBuf,
    chunk: u64,
    /// 上一次 NEED 之后还没喂过字节（调用方取数失败 / 交回空）：再 step 时这个文件记一条
    /// 错误记录跳过，不原地反复要同一段。
    awaiting: bool,
}

/// 一次 step 的结果。
#[derive(Debug, PartialEq)]
pub enum Step {
    /// 当前文件缺这些（起点, 长度）区间。
    Need {
        path: String,
        ranges: Vec<(u64, u64)>,
    },
    /// 一批记录（与本地扫描同一批次格式）。
    Batch(Vec<u8>),
}

pub struct RemoteScanner {
    pending: VecDeque<Item>,
    ready: VecDeque<Record>,
    out: Vec<Record>,
    current: Option<Box<Work>>,
    known: KnownFiles,
}

impl RemoteScanner {
    pub fn new(listing: &Listing) -> Self {
        Self {
            pending: plan_items(listing),
            ready: VecDeque::new(),
            out: Vec::new(),
            current: None,
            known: KnownFiles::new(),
        }
    }

    pub fn set_known(&mut self, known: KnownFiles) {
        self.known = known;
    }

    /// 喂当前文件 [offset, offset+len) 的字节。没有进行中的文件时忽略（返回 false）。
    pub fn feed(&mut self, offset: u64, data: &[u8]) -> bool {
        match self.current.as_mut() {
            Some(w) => {
                if !data.is_empty() {
                    w.awaiting = false;
                }
                w.buf.insert(offset, data);
                true
            }
            None => false,
        }
    }

    fn is_done(&self) -> bool {
        self.ready.is_empty() && self.pending.is_empty() && self.current.is_none()
    }

    pub fn step(&mut self, max: usize) -> Step {
        let max = if max == 0 || max > scan::MAX_BATCH {
            scan::MAX_BATCH
        } else {
            max
        };
        loop {
            while self.out.len() < max {
                match self.ready.pop_front() {
                    Some(r) => self.out.push(r),
                    None => break,
                }
            }
            if self.out.len() >= max {
                break;
            }
            if let Some(mut work) = self.current.take() {
                if work.awaiting {
                    let path = work
                        .item
                        .audio()
                        .map(|f| f.path.clone())
                        .unwrap_or_default();
                    self.ready.push_back(Record::Error {
                        path,
                        message: "no bytes were provided for the requested range".into(),
                    });
                    continue;
                }
                match attempt(&mut work) {
                    Attempt::Need(ranges) => {
                        work.awaiting = true;
                        let path = work
                            .item
                            .audio()
                            .map(|f| f.path.clone())
                            .unwrap_or_default();
                        self.current = Some(work);
                        return Step::Need { path, ranges };
                    }
                    Attempt::Done(records) => {
                        self.ready.extend(records);
                        continue;
                    }
                }
            }
            let Some(item) = self.pending.pop_front() else {
                break;
            };
            match self.start(item) {
                Started::Records(records) => self.ready.extend(records),
                Started::Fetch(mut work, ranges) => {
                    work.awaiting = true;
                    let path = work
                        .item
                        .audio()
                        .map(|f| f.path.clone())
                        .unwrap_or_default();
                    self.current = Some(work);
                    return Step::Need { path, ranges };
                }
            }
        }
        let records = std::mem::take(&mut self.out);
        let done = self.is_done();
        Step::Batch(wire::encode_batch(&records, done))
    }

    fn start(&self, item: Item) -> Started {
        let Some(audio) = item.audio() else {
            if let Item::Error { path, message } = item {
                return Started::Records(vec![Record::Error { path, message }]);
            }
            return Started::Records(Vec::new());
        };
        let (mtime, size) = item.version();
        if mtime >= 0 && size >= 0 && self.known.get(&audio.path) == Some(&(mtime, size)) {
            return Started::Records(vec![Record::Unchanged(audio.path.clone())]);
        }
        if audio.size <= 0 {
            // 来源没报大小：读不了文件尾，按扩展名推断（与 lofty 认不出的格式同语义）。
            let meta = tags::meta_from_extension(&audio.ext);
            return Started::Records(records_of(&item, &meta));
        }
        let size = audio.size as u64;
        let mut ranges = vec![(0, HEAD_PREFETCH.min(size))];
        if size > HEAD_PREFETCH {
            let tail_start = size.saturating_sub(TAIL_PREFETCH).max(HEAD_PREFETCH);
            ranges.push((tail_start, size - tail_start));
        }
        Started::Fetch(
            Box::new(Work {
                item,
                buf: SparseBuf::default(),
                chunk: MIN_CHUNK,
                awaiting: false,
            }),
            ranges,
        )
    }
}

enum Started {
    Records(Vec<Record>),
    Fetch(Box<Work>, Vec<(u64, u64)>),
}

enum Attempt {
    Need(Vec<(u64, u64)>),
    Done(Vec<Record>),
}

fn attempt(work: &mut Work) -> Attempt {
    let Some(audio) = work.item.audio() else {
        return Attempt::Done(Vec::new());
    };
    let size = audio.size as u64;
    let ext = audio.ext.clone();
    let mut missing: Option<(u64, u64)>;
    let parsed = {
        let mut r = SparseReader::new(&work.buf, size);
        let res = tags::read_meta_from(&mut r, &ext, true);
        missing = r.missing();
        res
    };
    let mut cue_tracks = None;
    if missing.is_none() {
        if let (Ok((meta, _)), Item::Audio { .. }) = (&parsed, &work.item) {
            let buf = &work.buf;
            let mut head_missing = None;
            let stem = work
                .item
                .audio()
                .map(|a| a.stem.clone())
                .unwrap_or_default();
            cue_tracks = scan::embedded_split_tracks_with(&stem, meta, || {
                let mut r = SparseReader::new(buf, size);
                let head = flac_cue_head(&mut r);
                head_missing = r.missing();
                head
            });
            missing = head_missing;
        }
    }
    if let Some((pos, want)) = missing {
        if work.buf.fetched() >= FETCH_CAP {
            // 取数封顶：按扩展名推断收尾（标题回落文件名），不无限取。
            let meta = tags::meta_from_extension(&ext);
            return Attempt::Done(records_of(&work.item, &meta));
        }
        let len = want.max(work.chunk).min(size.saturating_sub(pos)).max(1);
        work.chunk = (work.chunk * 2).min(MAX_CHUNK);
        return Attempt::Need(vec![(pos, len)]);
    }
    match parsed {
        Ok((meta, cover)) => {
            let mut records = Vec::new();
            if let Some(data) = cover {
                records.push(Record::Cover {
                    path: audio.path.clone(),
                    data,
                });
            }
            match (&work.item, cue_tracks) {
                (
                    Item::Audio {
                        file, folder_cover, ..
                    },
                    Some((sheet, tracks)),
                ) => {
                    let loc = file.loc();
                    for t in &tracks {
                        records.push(Record::Track(Box::new(scan::cue_track_record(
                            &loc,
                            &meta,
                            &sheet,
                            t,
                            file.mtime_ms,
                            file.size,
                            folder_cover.clone(),
                            None,
                        ))));
                    }
                }
                _ => records.extend(records_of(&work.item, &meta)),
            }
            Attempt::Done(records)
        }
        Err(message) => Attempt::Done(vec![Record::Error {
            path: audio.path.clone(),
            message,
        }]),
    }
}

/// 普通文件一首、CUE 条目拆 N 首（内嵌 CUESHEET 由 [attempt] 另拆）。
fn records_of(item: &Item, meta: &FileMeta) -> Vec<Record> {
    let (mtime, size) = item.version();
    match item {
        Item::Audio { file, folder_cover } => vec![Record::Track(Box::new(scan::plain_record(
            &file.loc(),
            meta,
            mtime,
            size,
            folder_cover.clone(),
        )))],
        Item::Cue {
            audio,
            sheet,
            file_index,
            cue_path,
            folder_cover,
            ..
        } => {
            let loc = audio.loc();
            sheet.files[*file_index]
                .tracks
                .iter()
                .map(|t| {
                    Record::Track(Box::new(scan::cue_track_record(
                        &loc,
                        meta,
                        sheet,
                        t,
                        mtime,
                        size,
                        folder_cover.clone(),
                        Some(cue_path.clone()),
                    )))
                })
                .collect()
        }
        Item::Error { path, message } => vec![Record::Error {
            path: path.clone(),
            message: message.clone(),
        }],
    }
}

/// NEED / BATCH 的线格式：
/// ```text
/// step := u8 0 | str path | u32 n | (i64 offset | i64 len)*n     （NEED）
///       | u8 1 | batch                                         （BATCH，见 wire.rs）
/// ```
pub fn encode_step(step: &Step) -> Vec<u8> {
    match step {
        Step::Need { path, ranges } => {
            let mut w = Writer::new();
            w.u8(0);
            w.str(path);
            w.u32(ranges.len() as u32);
            for (o, l) in ranges {
                w.i64(*o as i64);
                w.i64(*l as i64);
            }
            w.into_bytes()
        }
        Step::Batch(batch) => {
            let mut out = Vec::with_capacity(batch.len() + 1);
            out.push(1);
            out.extend_from_slice(batch);
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sparse_buf_merges_and_reads() {
        let mut b = SparseBuf::default();
        b.insert(10, &[1, 2, 3]);
        b.insert(13, &[4, 5]);
        b.insert(0, &[9; 4]);
        let mut r = SparseReader::new(&b, 20);
        let mut out = [0u8; 4];
        r.read_exact(&mut out).unwrap();
        assert_eq!(out, [9; 4]);
        assert!(r.read(&mut out).is_err());
        assert_eq!(r.missing(), Some((4, 4)));
        r.seek(SeekFrom::Start(11)).unwrap();
        let mut out = [0u8; 4];
        r.read_exact(&mut out).unwrap();
        assert_eq!(out, [2, 3, 4, 5]);
        assert_eq!(b.fetched(), 9);
    }

    #[test]
    fn listing_roundtrip_and_hidden_paths() {
        let mut cues = HashMap::new();
        cues.insert("https://h/m/a.cue".to_string(), vec![0x82, 0xA0]);
        let l = Listing {
            root: "https://h/m".into(),
            files: vec![ListedFile {
                path: "https://h/m/a.flac".into(),
                mtime_ms: 5,
                size: 6,
            }],
            cues,
        };
        assert_eq!(parse_listing(&encode_listing(&l)), Some(l));
        assert!(is_hidden("https://h/m", "https://h/m/.x/a.flac"));
        assert!(is_hidden("https://h/m/", "https://h/m/a/.b.flac"));
        assert!(!is_hidden("https://h/m", "https://h/m/a/b.flac"));
        assert!(parse_listing(&[2, 0, 0, 0]).is_none());
    }
}
