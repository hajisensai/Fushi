//! 语料库本体：磁盘上一文档一文件，内存里一份倒排。
//!
//! ## 为什么不进 Drift 数据库
//!
//! 索引是**派生数据**：内容全部来自用户库（书 / 字幕 / 歌词）与游戏文本，丢了可以按库重建，
//! 不该进备份、不该随同步走，也不该和 UI 的写事务抢同一个 SQLite 写锁（首次建索引要写上
//! 百万句）。状态与查询逻辑按「Rust 胖核心」归 Rust：Dart 只送原文、取结果，不另存镜像。
//! 唯一的例外是游戏台词——文本钩子历史只活在会话内存里（`TexthookerService` 上限 500 行），
//! 这里落盘的那份就是它唯一的持久副本，「重建」不会删它（见 `remove_kind`）。
//!
//! ## 磁盘格式（`<目录>/<身份哈希>-<序号>.fcd`，小端）
//!
//! ```text
//! b"FCRP" u32 版本
//! u8 kind, str key, i32 part, str title, str fingerprint, str normalizer, i64 updatedAt
//! u32 T, T × str 词典形                     ← 文档内词表（局部下标 → 字符串）
//! u32 N, N × 记录 {
//!   i32 section, i64 pos, i64 len, u32 units(UTF-16), str text,
//!   u32 M, M × { u32 start16, u32 len16, u32 局部词下标 }
//! }
//! ```
//!
//! 写入走「临时文件 → rename」，每次写新文件名（身份哈希 + 递增序号），换入内存后才删旧
//! 文件：在飞的查询（持读锁）读的永远是自己那一代文件。打开时同一身份有两份（上次在
//! rename 与删旧之间退出）取 updatedAt 新的一份；损坏的文件丢弃（派生数据，Dart 侧按指纹
//! 发现缺失后重新喂入）。
//!
//! ## 内存
//!
//! 只常驻倒排与每句 12 字节的元数据（所属文档、记录在文件里的偏移、UTF-16 长度）；句子
//! 原文与词元只在查询选中后按偏移回读，一次查询读十几条。

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;

use crate::wire::{self, json_str, Reader, Writer, WireError};

pub const FILE_MAGIC: &[u8; 4] = b"FCRP";
pub const FILE_VERSION: u32 = 1;
const FILE_EXT: &str = "fcd";

/// 一个文档的身份：(kind, key, part)。
type Identity = (u8, String, i32);

struct Doc {
    kind: u8,
    key: String,
    part: i32,
    title: String,
    fingerprint: String,
    normalizer: String,
    updated_at: i64,
    path: PathBuf,
    first_sentence: u32,
    sentence_count: u32,
    /// 文档内词表：局部下标 → 全局词 id。
    local_terms: Vec<u32>,
}

#[derive(Clone, Copy)]
struct SentenceMeta {
    doc: u32,
    rec_off: u32,
    units: u16,
}

#[derive(Default)]
struct State {
    docs: Vec<Option<Doc>>,
    by_identity: HashMap<Identity, u32>,
    sentences: Vec<SentenceMeta>,
    term_ids: HashMap<Box<str>, u32>,
    /// 全局词 id → 句子 id（升序、无重复）。
    postings: Vec<Vec<u32>>,
    live_docs: usize,
    live_sentences: usize,
}

pub struct Corpus {
    dir: PathBuf,
    state: RwLock<State>,
    seq: AtomicU64,
    dropped_on_open: usize,
}

/// 解析好的一份文件（加载与写入共用同一个解析器，保证内存与磁盘口径一致）。
struct ParsedDoc {
    kind: u8,
    key: String,
    part: i32,
    title: String,
    fingerprint: String,
    normalizer: String,
    updated_at: i64,
    terms: Vec<String>,
    /// (记录偏移, UTF-16 长度, 去重后的局部词下标)
    records: Vec<(u32, u16, Vec<u32>)>,
}

fn parse_file(bytes: &[u8]) -> Result<ParsedDoc, WireError> {
    if bytes.len() < 8 || &bytes[..4] != FILE_MAGIC {
        return Err(WireError("bad magic"));
    }
    let mut r = Reader::new(&bytes[4..]);
    if r.u32()? != FILE_VERSION {
        return Err(WireError("unsupported file version"));
    }
    let kind = r.u8()?;
    let key = r.str()?.to_owned();
    let part = r.i32()?;
    let title = r.str()?.to_owned();
    let fingerprint = r.str()?.to_owned();
    let normalizer = r.str()?.to_owned();
    let updated_at = r.i64()?;
    let t = r.u32()? as usize;
    let mut terms = Vec::with_capacity(t.min(1 << 20));
    for _ in 0..t {
        terms.push(r.str()?.to_owned());
    }
    let n = r.u32()? as usize;
    let mut records = Vec::with_capacity(n.min(1 << 20));
    for _ in 0..n {
        let rec_off = (r.position() + 4) as u32;
        r.i32()?;
        r.i64()?;
        r.i64()?;
        let units = r.u32()?.min(u16::MAX as u32) as u16;
        r.skip_str()?;
        let m = r.u32()? as usize;
        let mut locals: Vec<u32> = Vec::with_capacity(m);
        for _ in 0..m {
            r.u32()?;
            r.u32()?;
            let local = r.u32()?;
            if local as usize >= terms.len() {
                return Err(WireError("term index out of range"));
            }
            locals.push(local);
        }
        locals.sort_unstable();
        locals.dedup();
        records.push((rec_off, units, locals));
    }
    if !r.is_empty() {
        return Err(WireError("trailing bytes in file"));
    }
    Ok(ParsedDoc { kind, key, part, title, fingerprint, normalizer, updated_at, terms, records })
}

/// 文档 + 词元 → 文件字节。
fn encode_file(doc: &wire::InDocument<'_>, tokens: &[Vec<wire::InToken<'_>>]) -> Vec<u8> {
    let mut local: HashMap<&str, u32> = HashMap::new();
    let mut table: Vec<&str> = Vec::new();
    let mut per_sentence: Vec<Vec<(u32, u32, u32)>> = Vec::with_capacity(doc.sentences.len());
    for (s, toks) in doc.sentences.iter().zip(tokens.iter()) {
        let units = s.text.encode_utf16().count() as u32;
        let mut out = Vec::with_capacity(toks.len());
        for t in toks {
            if t.lemma.is_empty() || t.len == 0 || t.start >= units || t.start + t.len > units {
                continue;
            }
            let id = *local.entry(t.lemma).or_insert_with(|| {
                table.push(t.lemma);
                (table.len() - 1) as u32
            });
            out.push((t.start, t.len, id));
        }
        per_sentence.push(out);
    }
    let mut w = Writer::default();
    w.buf.extend_from_slice(FILE_MAGIC);
    w.u32(FILE_VERSION);
    w.u8(doc.kind);
    w.str(doc.key);
    w.i32(doc.part);
    w.str(doc.title);
    w.str(doc.fingerprint);
    w.str(doc.normalizer);
    w.i64(doc.updated_at);
    w.u32(table.len() as u32);
    for t in &table {
        w.str(t);
    }
    w.u32(doc.sentences.len() as u32);
    for (s, toks) in doc.sentences.iter().zip(per_sentence.iter()) {
        w.i32(s.section);
        w.i64(s.pos);
        w.i64(s.len);
        w.u32(s.text.encode_utf16().count() as u32);
        w.str(s.text);
        w.u32(toks.len() as u32);
        for &(start, len, id) in toks {
            w.u32(start);
            w.u32(len);
            w.u32(id);
        }
    }
    w.buf
}

/// FNV-1a 64：文件名里的身份哈希（只用来分散文件名，身份以文件内容为准）。
fn identity_hash(kind: u8, key: &str, part: i32) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    let mut feed = |b: u8| {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x100000001b3);
    };
    feed(kind);
    for b in key.as_bytes() {
        feed(*b);
    }
    for b in part.to_le_bytes() {
        feed(b);
    }
    h
}

/// 查询选中后回读的一条记录。
struct Record {
    section: i32,
    pos: i64,
    len: i64,
    text: String,
    tokens: Vec<(u32, u32, u32)>,
}

fn read_exact_at(file: &mut File, buf: &mut [u8]) -> std::io::Result<()> {
    file.read_exact(buf)
}

fn read_record(file: &mut File, off: u32) -> std::io::Result<Record> {
    file.seek(SeekFrom::Start(u64::from(off)))?;
    let mut head = [0u8; 4 + 8 + 8 + 4 + 4];
    read_exact_at(file, &mut head)?;
    let section = i32::from_le_bytes([head[0], head[1], head[2], head[3]]);
    let mut b8 = [0u8; 8];
    b8.copy_from_slice(&head[4..12]);
    let pos = i64::from_le_bytes(b8);
    b8.copy_from_slice(&head[12..20]);
    let len = i64::from_le_bytes(b8);
    let text_len = u32::from_le_bytes([head[24], head[25], head[26], head[27]]) as usize;
    let mut text = vec![0u8; text_len];
    read_exact_at(file, &mut text)?;
    let mut m = [0u8; 4];
    read_exact_at(file, &mut m)?;
    let m = u32::from_le_bytes(m) as usize;
    let mut raw = vec![0u8; m * 12];
    read_exact_at(file, &mut raw)?;
    let mut tokens = Vec::with_capacity(m);
    for c in raw.chunks_exact(12) {
        tokens.push((
            u32::from_le_bytes([c[0], c[1], c[2], c[3]]),
            u32::from_le_bytes([c[4], c[5], c[6], c[7]]),
            u32::from_le_bytes([c[8], c[9], c[10], c[11]]),
        ));
    }
    let text = String::from_utf8(text).map_err(|_| std::io::Error::other("invalid utf-8 in record"))?;
    Ok(Record { section, pos, len, text, tokens })
}

/// 句子作为例句的「好用程度」：越小越靠前。太短（一两个字）的没有上下文，太长的读不完。
fn length_penalty(units: u16) -> u32 {
    let u = u32::from(units);
    if u < 4 {
        100 + (4 - u)
    } else if u < 8 {
        8 - u
    } else if u <= 48 {
        0
    } else {
        (u - 48) / 4
    }
}

impl State {
    fn intern(&mut self, term: &str) -> u32 {
        if let Some(&id) = self.term_ids.get(term) {
            return id;
        }
        let id = self.postings.len() as u32;
        self.postings.push(Vec::new());
        self.term_ids.insert(term.into(), id);
        id
    }

    fn install(&mut self, parsed: ParsedDoc, path: PathBuf) -> u32 {
        let doc_id = self.docs.len() as u32;
        let first = self.sentences.len() as u32;
        let local_terms: Vec<u32> = parsed.terms.iter().map(|t| self.intern(t)).collect();
        for (i, (rec_off, units, locals)) in parsed.records.iter().enumerate() {
            let sid = first + i as u32;
            self.sentences.push(SentenceMeta { doc: doc_id, rec_off: *rec_off, units: *units });
            for &l in locals {
                self.postings[local_terms[l as usize] as usize].push(sid);
            }
        }
        let count = parsed.records.len() as u32;
        let identity = (parsed.kind, parsed.key.clone(), parsed.part);
        self.docs.push(Some(Doc {
            kind: parsed.kind,
            key: parsed.key,
            part: parsed.part,
            title: parsed.title,
            fingerprint: parsed.fingerprint,
            normalizer: parsed.normalizer,
            updated_at: parsed.updated_at,
            path,
            first_sentence: first,
            sentence_count: count,
            local_terms,
        }));
        self.by_identity.insert(identity, doc_id);
        self.live_docs += 1;
        self.live_sentences += count as usize;
        doc_id
    }

    /// 摘掉一个文档（倒排里它的句子区间整段删掉），返回它的文件路径。
    fn remove(&mut self, doc_id: u32) -> Option<PathBuf> {
        let doc = self.docs.get_mut(doc_id as usize)?.take()?;
        self.by_identity.remove(&(doc.kind, doc.key.clone(), doc.part));
        let lo = doc.first_sentence;
        let hi = doc.first_sentence + doc.sentence_count;
        let mut seen = HashSet::new();
        for &t in &doc.local_terms {
            if !seen.insert(t) {
                continue;
            }
            let list = &mut self.postings[t as usize];
            let a = list.partition_point(|&s| s < lo);
            let b = list.partition_point(|&s| s < hi);
            list.drain(a..b);
        }
        self.live_docs -= 1;
        self.live_sentences -= doc.sentence_count as usize;
        Some(doc.path)
    }
}

/// 一次查询的条目（JSON 输出前的形态）。
struct Hit {
    doc: u32,
    record: Record,
}

impl Corpus {
    /// 打开（不存在则建）语料目录并载入全部文档。
    pub fn open(dir: &Path) -> std::io::Result<Corpus> {
        fs::create_dir_all(dir)?;
        let mut state = State::default();
        let mut dropped = 0usize;
        let mut candidates: Vec<(PathBuf, ParsedDoc)> = Vec::new();
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext == "tmp" {
                let _ = fs::remove_file(&path);
                continue;
            }
            if ext != FILE_EXT {
                continue;
            }
            match fs::read(&path).map_err(|_| WireError("read")).and_then(|b| parse_file(&b)) {
                Ok(parsed) => candidates.push((path, parsed)),
                Err(_) => {
                    let _ = fs::remove_file(&path);
                    dropped += 1;
                }
            }
        }
        // 同一身份多份：保留 updatedAt 最新（并列取文件名大的，即序号新的）。
        candidates.sort_by(|a, b| {
            (a.1.kind, &a.1.key, a.1.part, a.1.updated_at, &a.0).cmp(&(b.1.kind, &b.1.key, b.1.part, b.1.updated_at, &b.0))
        });
        let mut keep: Vec<(PathBuf, ParsedDoc)> = Vec::with_capacity(candidates.len());
        for item in candidates {
            if let Some(last) = keep.last() {
                if last.1.kind == item.1.kind && last.1.key == item.1.key && last.1.part == item.1.part {
                    let stale = keep.pop().unwrap();
                    let _ = fs::remove_file(&stale.0);
                    dropped += 1;
                }
            }
            keep.push(item);
        }
        for (path, parsed) in keep {
            state.install(parsed, path);
        }
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        Ok(Corpus { dir: dir.to_path_buf(), state: RwLock::new(state), seq: AtomicU64::new(seed), dropped_on_open: dropped })
    }

    /// 写入（替换）一个文档。[doc] / [terms] 是 [wire] 里的两份线格式。
    pub fn put(&self, doc_bytes: &[u8], terms_bytes: &[u8]) -> Result<(), PutError> {
        let doc = wire::read_document(doc_bytes).map_err(PutError::BadInput)?;
        let tokens = wire::read_terms(terms_bytes, doc.sentences.len()).map_err(PutError::BadInput)?;
        let bytes = encode_file(&doc, &tokens);
        let parsed = parse_file(&bytes).map_err(PutError::BadInput)?;
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let stem = format!("{:016x}-{:016x}", identity_hash(doc.kind, doc.key, doc.part), seq);
        let tmp = self.dir.join(format!("{stem}.tmp"));
        let path = self.dir.join(format!("{stem}.{FILE_EXT}"));
        {
            let mut f = File::create(&tmp).map_err(PutError::Io)?;
            f.write_all(&bytes).map_err(PutError::Io)?;
            f.sync_all().map_err(PutError::Io)?;
        }
        fs::rename(&tmp, &path).map_err(PutError::Io)?;
        let old = {
            let mut st = self.state.write().unwrap_or_else(|e| e.into_inner());
            let identity = (parsed.kind, parsed.key.clone(), parsed.part);
            let old = st.by_identity.get(&identity).copied().and_then(|id| st.remove(id));
            st.install(parsed, path);
            old
        };
        if let Some(old) = old {
            let _ = fs::remove_file(old);
        }
        Ok(())
    }

    /// 删除文档：`part = None` 删该条目的全部 part。返回删掉的文档数。
    pub fn remove(&self, kind: u8, key: &str, part: Option<i32>) -> usize {
        let paths = {
            let mut st = self.state.write().unwrap_or_else(|e| e.into_inner());
            let ids: Vec<u32> = st
                .by_identity
                .iter()
                .filter(|((k, key2, p), _)| *k == kind && key2 == key && part.is_none_or(|want| want == *p))
                .map(|(_, &id)| id)
                .collect();
            ids.into_iter().filter_map(|id| st.remove(id)).collect::<Vec<_>>()
        };
        let n = paths.len();
        for p in paths {
            let _ = fs::remove_file(p);
        }
        n
    }

    /// 删除某些 kind 的全部文档（[kind_mask] 第 k 位 = kind k）。返回删掉的文档数。
    pub fn remove_kinds(&self, kind_mask: u32) -> usize {
        let paths = {
            let mut st = self.state.write().unwrap_or_else(|e| e.into_inner());
            let ids: Vec<u32> = st
                .by_identity
                .iter()
                .filter(|((k, _, _), _)| *k < 32 && kind_mask & (1 << k) != 0)
                .map(|(_, &id)| id)
                .collect();
            ids.into_iter().filter_map(|id| st.remove(id)).collect::<Vec<_>>()
        };
        let n = paths.len();
        for p in paths {
            let _ = fs::remove_file(p);
        }
        n
    }

    /// 文档清单 JSON：`[{kind,key,part,title,fingerprint,normalizer,updatedAt,sentences}]`。
    /// [kind] = None 列全部；[key] 非空时只列这个条目。
    pub fn docs_json(&self, kind: Option<u8>, key: Option<&str>) -> String {
        let st = self.state.read().unwrap_or_else(|e| e.into_inner());
        let mut docs: Vec<&Doc> = st
            .docs
            .iter()
            .flatten()
            .filter(|d| kind.is_none_or(|k| d.kind == k) && key.is_none_or(|k| d.key == k))
            .collect();
        docs.sort_by(|a, b| (a.kind, &a.key, a.part).cmp(&(b.kind, &b.key, b.part)));
        let mut out = String::from("[");
        for (i, d) in docs.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("{{\"kind\":{},\"key\":", d.kind));
            json_str(&mut out, &d.key);
            out.push_str(&format!(",\"part\":{},\"title\":", d.part));
            json_str(&mut out, &d.title);
            out.push_str(",\"fingerprint\":");
            json_str(&mut out, &d.fingerprint);
            out.push_str(",\"normalizer\":");
            json_str(&mut out, &d.normalizer);
            out.push_str(&format!(",\"updatedAt\":{},\"sentences\":{}}}", d.updated_at, d.sentence_count));
        }
        out.push(']');
        out
    }

    /// 读回一份文档的原文（文档线格式，与 [wire::read_document] 对称），给「词典换了、
    /// 词元过期」的重新归一用：游戏台词 / 播放列表各集字幕在别处没有持久副本，只能从这里
    /// 取回原句重新分词。文档不存在返回 None。
    pub fn export(&self, kind: u8, key: &str, part: i32) -> std::io::Result<Option<Vec<u8>>> {
        let st = self.state.read().unwrap_or_else(|e| e.into_inner());
        let Some(&id) = st.by_identity.get(&(kind, key.to_owned(), part)) else { return Ok(None) };
        let Some(doc) = st.docs[id as usize].as_ref() else { return Ok(None) };
        let mut file = File::open(&doc.path)?;
        let mut w = Writer::default();
        w.u8(doc.kind);
        w.str(&doc.key);
        w.i32(doc.part);
        w.str(&doc.title);
        w.str(&doc.fingerprint);
        w.str(&doc.normalizer);
        w.i64(doc.updated_at);
        w.u32(doc.sentence_count);
        for sid in doc.first_sentence..doc.first_sentence + doc.sentence_count {
            let record = read_record(&mut file, st.sentences[sid as usize].rec_off)?;
            w.i32(record.section);
            w.i64(record.pos);
            w.i64(record.len);
            w.str(&record.text);
        }
        Ok(Some(w.buf))
    }

    pub fn stats_json(&self) -> String {
        let st = self.state.read().unwrap_or_else(|e| e.into_inner());
        let postings: usize = st.postings.iter().map(Vec::len).sum();
        format!(
            "{{\"docs\":{},\"sentences\":{},\"terms\":{},\"postings\":{},\"droppedOnOpen\":{}}}",
            st.live_docs,
            st.live_sentences,
            st.term_ids.len(),
            postings,
            self.dropped_on_open
        )
    }

    /// 查询：返回 JSON
    /// `{"total":N,"groups":[{"kind":k,"total":T,"items":[{key,part,title,section,pos,len,text,hl:[[s,l]]}]}]}`。
    ///
    /// 排序：句长惩罚（[length_penalty]）→ 文档新的在前 → 句子在库里的先后；每个 kind 至多
    /// `per_kind` 条、每个文档至多 `per_doc` 条，原文相同的句子只出一次（同一首 OP 每集都有）。
    pub fn query_json(&self, query_bytes: &[u8]) -> Result<String, WireError> {
        let q = wire::read_query(query_bytes)?;
        let st = self.state.read().unwrap_or_else(|e| e.into_inner());
        let term_set: HashSet<u32> = q.keys.iter().filter_map(|k| st.term_ids.get(*k).copied()).collect();
        let mut ids: Vec<u32> = Vec::new();
        for &t in &term_set {
            ids.extend_from_slice(&st.postings[t as usize]);
        }
        ids.sort_unstable();
        ids.dedup();
        // kind → 候选
        let mut by_kind: HashMap<u8, Vec<u32>> = HashMap::new();
        for &sid in &ids {
            let meta = st.sentences[sid as usize];
            let Some(doc) = st.docs[meta.doc as usize].as_ref() else { continue };
            if doc.kind >= 32 || q.kind_mask & (1 << doc.kind) == 0 {
                continue;
            }
            by_kind.entry(doc.kind).or_default().push(sid);
        }
        let mut kinds: Vec<u8> = by_kind.keys().copied().collect();
        kinds.sort_unstable();
        let mut files: HashMap<u32, File> = HashMap::new();
        let mut out = String::new();
        let mut grand_total = 0usize;
        let mut groups = String::new();
        for kind in kinds {
            let mut list = by_kind.remove(&kind).unwrap_or_default();
            grand_total += list.len();
            list.sort_by_key(|&sid| {
                let meta = st.sentences[sid as usize];
                let updated = st.docs[meta.doc as usize].as_ref().map_or(0, |d| d.updated_at);
                (length_penalty(meta.units), std::cmp::Reverse(updated), sid)
            });
            let total = list.len();
            let mut per_doc: HashMap<u32, usize> = HashMap::new();
            let mut seen_text: HashSet<String> = HashSet::new();
            let mut hits: Vec<Hit> = Vec::new();
            for sid in list {
                if hits.len() >= q.per_kind {
                    break;
                }
                let meta = st.sentences[sid as usize];
                let used = per_doc.get(&meta.doc).copied().unwrap_or(0);
                if q.per_doc > 0 && used >= q.per_doc {
                    continue;
                }
                let Some(doc) = st.docs[meta.doc as usize].as_ref() else { continue };
                let file = match files.entry(meta.doc) {
                    std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
                    std::collections::hash_map::Entry::Vacant(e) => match File::open(&doc.path) {
                        Ok(f) => e.insert(f),
                        Err(_) => continue,
                    },
                };
                let Ok(record) = read_record(file, meta.rec_off) else { continue };
                if !seen_text.insert(record.text.trim().to_owned()) {
                    continue;
                }
                per_doc.insert(meta.doc, used + 1);
                hits.push(Hit { doc: meta.doc, record });
            }
            if !groups.is_empty() {
                groups.push(',');
            }
            groups.push_str(&format!("{{\"kind\":{kind},\"total\":{total},\"items\":["));
            for (i, hit) in hits.iter().enumerate() {
                let Some(doc) = st.docs[hit.doc as usize].as_ref() else { continue };
                if i > 0 {
                    groups.push(',');
                }
                groups.push_str("{\"key\":");
                json_str(&mut groups, &doc.key);
                groups.push_str(&format!(",\"part\":{},\"title\":", doc.part));
                json_str(&mut groups, &doc.title);
                groups.push_str(&format!(
                    ",\"section\":{},\"pos\":{},\"len\":{},\"text\":",
                    hit.record.section, hit.record.pos, hit.record.len
                ));
                json_str(&mut groups, &hit.record.text);
                groups.push_str(",\"hl\":[");
                let mut first = true;
                for &(start, len, local) in &hit.record.tokens {
                    let Some(&global) = doc.local_terms.get(local as usize) else { continue };
                    if !term_set.contains(&global) {
                        continue;
                    }
                    if !first {
                        groups.push(',');
                    }
                    first = false;
                    groups.push_str(&format!("[{start},{len}]"));
                }
                groups.push_str("]}");
            }
            groups.push_str("]}");
        }
        out.push_str(&format!("{{\"total\":{grand_total},\"groups\":["));
        out.push_str(&groups);
        out.push_str("]}");
        Ok(out)
    }
}

#[derive(Debug)]
pub enum PutError {
    BadInput(WireError),
    Io(std::io::Error),
}
