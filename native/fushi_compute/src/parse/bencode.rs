//! `ffc_parse_bencode_*`：种子元数据（.torrent）的 bencode 校验 + info hash + 文件清单。
//!
//! 口径来自原 Dart `inspectTorrentMetainfo`（packages/fushi_engine/lib/media/torrent/
//! torrent_metainfo.dart 的 `_BencodeReader` / `_inspectFiles`，解析部分已删除；冻结的对拍
//! 摘要见 packages/fushi_engine/test/media/torrent/torrent_metainfo_native_test.dart）。逐条保持：
//! - 严格 bencode：整数不许前导 0 / `-0` / 空，超出 i64 判「outside supported range」；字节串
//!   长度不许前导 0；字典键不许重复（按**解码后**的字符串判，见下）；根后不许有尾随字节；
//!   嵌套深度 > 100、值总数 > 1_000_000 拒绝；错误消息与判定先后与旧实现逐字相同。
//! - 字典键与所有文本字段按 Dart `utf8.decode(allowMalformed: true)` 解码：非法序列按「最大
//!   合法子段」各换一个 U+FFFD（与 Rust `from_utf8_lossy` 相同），**开头的 UTF-8 BOM
//!   （EF BB BF）被剥掉**（Dart 解码器行为；所以键 `\u{FEFF}info` 等同 `info`）。
//! - 旧实现里非 TorrentMetainfoException 的异常一律被改写成「truncated or malformed
//!   bencode」；唯一能走到那里的路径是字节串长度让 `index + length` 溢出 i64（Dart 回绕成负数，
//!   `sublistView` 抛 RangeError），这里同样映射。
//! - 旧实现用 `is List<Object?>` 判列表，而 Dart 的字节串是 `Uint8List`——**也是**
//!   `List<Object?>`（元素是 int）。所以 `files` / `path` 是字节串时按「元素全是整数的列表」
//!   处理（见 [ListLike]）。
//! - info hash = 根字典 `info` 值的**原始字节区间**的 SHA-1（有 `pieces` 字节串时，v1）与
//!   SHA-256（`meta version == 2` 时，v2）。
//!
//! 实现：先一遍**只校验不建树**（每层复用一份键集合判重，不为每个值分配），再只把用得到的
//! 部分（info 字典的顶层键、文件清单的每个条目）在已校验的字节上就地读出来，路径直接写进
//! 输出的 UTF-16 池。旧实现建整棵值树，十万个文件的种子上分配与释放就占大头。
//!
//! 留在 Dart 的只有与 bencode 无关的部分：空 / 超过 16 MiB 的入口检查、`expectedInfoHash`
//! 的规范化与比对、`suggestedName` 的 `trim()`。文件清单错误在这里只「记下」，由 Dart 在
//! hash 比对之后再抛，保持旧实现的报错先后。
//!
//! 输出布局见 [ffc_parse_bencode_inspect_torrent]。

use std::borrow::Cow;
use std::collections::HashSet;

use sha1::{Digest, Sha1};
use sha2::Sha256;

use crate::{guard, hand_over_bytes, status};

const MAX_DEPTH: u32 = 100;
const MAX_VALUES: u32 = 1_000_000;

/// 旧实现把非 TorrentMetainfoException 的异常改写成的消息。
const MALFORMED: &str = "truncated or malformed bencode";

/// 与 Dart `TorrentMetainfoErrorCode` 的下标一致。
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetainfoErrorCode {
    Empty = 0,
    TooLarge = 1,
    InvalidBencode = 2,
    MissingInfo = 3,
    UnsupportedVersion = 4,
    HashMismatch = 5,
}

/// Dart `utf8.decode(bytes, allowMalformed: true)`：最大子段替换 + 剥掉开头的 BOM。
pub fn decode_dart_utf8(bytes: &[u8]) -> Cow<'_, str> {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(&bytes[3..]);
    }
    String::from_utf8_lossy(bytes)
}

/// 已校验输入上的一个值：标量直接带上，容器只记起点（指向 `l` / `d`）。
#[derive(Clone, Copy, Debug)]
enum Lite<'a> {
    Bytes(&'a [u8]),
    Int(i64),
    List(usize),
    Dict(usize),
}

/// 一层字典的判重集合（按深度复用，少量键时线性比对）。
#[derive(Default)]
struct KeySet<'a> {
    keys: Vec<Cow<'a, str>>,
    hashed: HashSet<Cow<'a, str>>,
}

impl<'a> KeySet<'a> {
    fn clear(&mut self) {
        self.keys.clear();
        self.hashed.clear();
    }

    /// 加入 [key]；已存在返回 false。
    fn insert(&mut self, key: Cow<'a, str>) -> bool {
        if self.keys.len() < 16 {
            if self.keys.contains(&key) {
                return false;
            }
            self.keys.push(key);
            if self.keys.len() == 16 {
                self.hashed.extend(self.keys.iter().cloned());
            }
            return true;
        }
        self.hashed.insert(key)
    }
}

type Parse<T> = Result<T, &'static str>;

/// 校验器：语义与旧 `_BencodeReader` 一致，但不建值树。
struct Validator<'a> {
    bytes: &'a [u8],
    index: usize,
    value_count: u32,
    /// 下标 = 字典所在深度（`read_dict(depth)` 的 depth）。
    key_sets: Vec<KeySet<'a>>,
}

impl<'a> Validator<'a> {
    fn peek(&self) -> Parse<u8> {
        self.bytes
            .get(self.index)
            .copied()
            .ok_or("unexpected end of input")
    }

    fn take(&mut self) -> Parse<u8> {
        let value = self.peek()?;
        self.index += 1;
        Ok(value)
    }

    /// 根字典；返回 info 值的原始字节区间（没有 info 时为 None）。
    fn read_root(&mut self) -> Parse<Option<(usize, usize)>> {
        if self.take()? != b'd' {
            return Err("root value must be a dictionary");
        }
        let mut info = None;
        let mut keys: HashSet<Cow<'a, str>> = HashSet::new();
        while self.peek()? != b'e' {
            let key = self.read_key()?;
            let is_info = key == "info";
            if !keys.insert(key) {
                return Err("duplicate root key");
            }
            let value_start = self.index;
            let value = self.read_value(1)?;
            if is_info {
                match value {
                    Lite::Dict(_) => info = Some((value_start, self.index)),
                    _ => return Err("info must be a dictionary"),
                }
            }
        }
        self.index += 1;
        if self.index != self.bytes.len() {
            return Err("trailing bytes after root value");
        }
        Ok(info)
    }

    fn read_value(&mut self, depth: u32) -> Parse<Lite<'a>> {
        if depth > MAX_DEPTH {
            return Err("maximum nesting depth exceeded");
        }
        self.value_count += 1;
        if self.value_count > MAX_VALUES {
            return Err("too many bencode values");
        }
        match self.peek()? {
            b'0'..=b'9' => Ok(Lite::Bytes(self.read_bytes()?)),
            b'i' => Ok(Lite::Int(self.read_integer()?)),
            b'l' => {
                let start = self.index;
                self.read_list(depth + 1)?;
                Ok(Lite::List(start))
            }
            b'd' => {
                let start = self.index;
                self.read_dict(depth + 1)?;
                Ok(Lite::Dict(start))
            }
            _ => Err("unknown bencode marker"),
        }
    }

    fn read_integer(&mut self) -> Parse<i64> {
        self.index += 1;
        let start = self.index;
        while self.peek()? != b'e' {
            let byte = self.take()?;
            if byte != b'-' && !byte.is_ascii_digit() {
                return Err("invalid integer");
            }
        }
        let raw = &self.bytes[start..self.index];
        self.index += 1;
        parse_integer(raw)
    }

    fn read_bytes(&mut self) -> Parse<&'a [u8]> {
        let length_start = self.index;
        while self.peek()? != b':' {
            let byte = self.take()?;
            if !byte.is_ascii_digit() {
                return Err("invalid byte string length");
            }
        }
        let raw = &self.bytes[length_start..self.index];
        self.index += 1;
        if raw.is_empty() || (raw[0] == b'0' && raw.len() > 1) {
            return Err("non-canonical byte string length");
        }
        let length: i64 = std::str::from_utf8(raw)
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .ok_or("byte string exceeds input")?;
        // Dart 的 `index + length` 在 i64 上回绕：溢出时比较判不出越界，随后 sublistView 抛
        // RangeError，被根上的 catch 改写成 MALFORMED。
        let end = (self.index as i64).checked_add(length).ok_or(MALFORMED)?;
        if end > self.bytes.len() as i64 {
            return Err("byte string exceeds input");
        }
        let end = end as usize;
        let value = &self.bytes[self.index..end];
        self.index = end;
        Ok(value)
    }

    fn read_list(&mut self, depth: u32) -> Parse<()> {
        self.index += 1;
        while self.peek()? != b'e' {
            self.read_value(depth)?;
        }
        self.index += 1;
        Ok(())
    }

    fn read_dict(&mut self, depth: u32) -> Parse<()> {
        self.index += 1;
        let level = depth as usize;
        if self.key_sets.len() <= level {
            self.key_sets.resize_with(level + 1, KeySet::default);
        }
        // 外层字典用的是更浅一层的集合，嵌套只会更深，所以这一层的集合可以直接清空复用。
        let mut keys = std::mem::take(&mut self.key_sets[level]);
        keys.clear();
        let result = (|| {
            while self.peek()? != b'e' {
                let key = self.read_key()?;
                if !keys.insert(key) {
                    return Err("duplicate dictionary key");
                }
                self.read_value(depth)?;
            }
            self.index += 1;
            Ok(())
        })();
        self.key_sets[level] = keys;
        result
    }

    fn read_key(&mut self) -> Parse<Cow<'a, str>> {
        let raw = self.read_bytes()?;
        Ok(decode_dart_utf8(raw))
    }
}

/// 整数串（只含 ASCII 数字与 `-`）的规范性检查与解析，消息与旧实现一致。
fn parse_integer(raw: &[u8]) -> Parse<i64> {
    if raw.is_empty()
        || raw == b"-"
        || raw == b"-0"
        || (raw[0] == b'0' && raw.len() > 1)
        || (raw.starts_with(b"-0") && raw.len() > 2)
    {
        return Err("non-canonical integer");
    }
    // i64 解析失败（多个 `-`、`-` 在中间、超范围）与 Dart `int.tryParse` 返回 null 同一分支。
    std::str::from_utf8(raw)
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .ok_or("integer is outside supported range")
}

/// 已校验字节上的就地读取（不再做任何检查）。
struct Walker<'a> {
    bytes: &'a [u8],
}

impl<'a> Walker<'a> {
    /// [at] 处的值及其结束位置。
    fn value(&self, at: usize) -> (Lite<'a>, usize) {
        match self.bytes[at] {
            b'i' => {
                let mut end = at + 1;
                while self.bytes[end] != b'e' {
                    end += 1;
                }
                let value = parse_integer(&self.bytes[at + 1..end]).unwrap_or(0);
                (Lite::Int(value), end + 1)
            }
            b'l' => (Lite::List(at), self.skip_container(at)),
            b'd' => (Lite::Dict(at), self.skip_container(at)),
            _ => {
                let (bytes, end) = self.bytes_at(at);
                (Lite::Bytes(bytes), end)
            }
        }
    }

    fn bytes_at(&self, at: usize) -> (&'a [u8], usize) {
        let mut colon = at;
        let mut length = 0usize;
        while self.bytes[colon] != b':' {
            length = length * 10 + usize::from(self.bytes[colon] - b'0');
            colon += 1;
        }
        let start = colon + 1;
        (&self.bytes[start..start + length], start + length)
    }

    fn skip_container(&self, at: usize) -> usize {
        let mut pos = at + 1;
        while self.bytes[pos] != b'e' {
            pos = self.value(pos).1;
        }
        pos + 1
    }

    /// 列表 [at] 的元素。
    fn list_items(&self, at: usize, out: &mut Vec<Lite<'a>>) {
        out.clear();
        let mut pos = at + 1;
        while self.bytes[pos] != b'e' {
            let (value, end) = self.value(pos);
            out.push(value);
            pos = end;
        }
    }

    /// 字典 [at] 的（解码后的键, 值）。
    fn dict_entries(&self, at: usize, out: &mut Vec<(Cow<'a, str>, Lite<'a>)>) {
        out.clear();
        let mut pos = at + 1;
        while self.bytes[pos] != b'e' {
            let (key, value_at) = self.bytes_at(pos);
            let (value, end) = self.value(value_at);
            out.push((decode_dart_utf8(key), value));
            pos = end;
        }
    }
}

fn get<'v, 'a>(entries: &'v [(Cow<'a, str>, Lite<'a>)], key: &str) -> Option<&'v Lite<'a>> {
    entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// 旧实现眼里的「列表」：真列表，或字节串（`Uint8List` 也是 `List<Object?>`，元素全是 int）。
enum ListLike {
    /// 列表的起点。
    List(usize),
    /// 字节串当列表：长度即元素个数。
    Bytes(usize),
}

fn as_list_like(value: Option<&Lite<'_>>) -> Option<ListLike> {
    match value {
        Some(Lite::List(at)) => Some(ListLike::List(*at)),
        Some(Lite::Bytes(bytes)) => Some(ListLike::Bytes(bytes.len())),
        _ => None,
    }
}

/// UTF-16 池中的一段（起点, 码元数）。
pub type PoolRange = (u32, u32);

/// 一个文件条目：长度 + 路径在池中的位置（各段按 Dart 规则解码、用 `/` 连接）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MetainfoFile {
    pub length: i64,
    pub path: PoolRange,
}

/// 解析成功的结果（与 bencode 有关的部分）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metainfo {
    pub v1_info_hash: Option<[u8; 20]>,
    pub v2_info_hash: Option<[u8; 32]>,
    /// `info.name.utf-8 ?? info.name` 是非空字节串时的解码结果（**未 trim**）。
    pub name: Option<PoolRange>,
    /// 文件清单，或清单不合法时的错误消息（错误码一律 invalidBencode）。
    pub files: Result<Vec<MetainfoFile>, String>,
    /// name 与路径的 UTF-16 码元。
    pub pool: Vec<u16>,
}

impl Metainfo {
    /// 池中一段的文本（测试与调试用）。
    pub fn text(&self, range: PoolRange) -> String {
        String::from_utf16_lossy(&self.pool[range.0 as usize..(range.0 + range.1) as usize])
    }
}

/// 致命错误（对应旧实现在 hash 比对之前抛出的异常）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetainfoError {
    pub code: MetainfoErrorCode,
    pub detail: &'static str,
}

fn push_utf16(pool: &mut Vec<u16>, text: &str) {
    pool.extend(text.encode_utf16());
}

fn pool_range(pool: &[u16], start: usize) -> PoolRange {
    (start as u32, (pool.len() - start) as u32)
}

/// 校验 bencode、算 info hash、读文件清单。空 / 超大的入口检查由调用方先做。
pub fn inspect_metainfo(bytes: &[u8]) -> Result<Metainfo, MetainfoError> {
    let mut validator = Validator {
        bytes,
        index: 0,
        value_count: 0,
        key_sets: Vec::new(),
    };
    let info = validator.read_root().map_err(|detail| MetainfoError {
        code: MetainfoErrorCode::InvalidBencode,
        detail,
    })?;
    let Some((start, end)) = info else {
        return Err(MetainfoError {
            code: MetainfoErrorCode::MissingInfo,
            detail: "root dictionary has no info dictionary",
        });
    };
    let walker = Walker { bytes };
    let mut info = Vec::new();
    walker.dict_entries(start, &mut info);
    let has_v1 = matches!(get(&info, "pieces"), Some(Lite::Bytes(_)));
    let has_v2 = matches!(get(&info, "meta version"), Some(Lite::Int(2)));
    if !has_v1 && !has_v2 {
        return Err(MetainfoError {
            code: MetainfoErrorCode::UnsupportedVersion,
            detail: "info dictionary is neither v1 nor v2",
        });
    }
    let raw_info = &bytes[start..end];
    let v1_info_hash = has_v1.then(|| Sha1::digest(raw_info).into());
    let v2_info_hash = has_v2.then(|| Sha256::digest(raw_info).into());

    let mut pool = Vec::new();
    let name = match get(&info, "name.utf-8").or_else(|| get(&info, "name")) {
        Some(Lite::Bytes(raw)) if !raw.is_empty() => {
            push_utf16(&mut pool, &decode_dart_utf8(raw));
            Some(pool_range(&pool, 0))
        }
        _ => None,
    };
    let files = inspect_files(&walker, &info, &mut pool);
    Ok(Metainfo {
        v1_info_hash,
        v2_info_hash,
        name,
        files,
        pool,
    })
}

fn inspect_files<'a>(
    walker: &Walker<'a>,
    info: &[(Cow<'a, str>, Lite<'a>)],
    pool: &mut Vec<u16>,
) -> Result<Vec<MetainfoFile>, String> {
    if let Some(raw_files) = as_list_like(get(info, "files")) {
        let raw_files_at = match raw_files {
            ListLike::List(at) => at,
            ListLike::Bytes(0) => return Ok(Vec::new()),
            ListLike::Bytes(_) => return Err("info.files[0] must be a dictionary".to_string()),
        };
        let mut items = Vec::new();
        walker.list_items(raw_files_at, &mut items);
        let mut files = Vec::with_capacity(items.len());
        let mut entries = Vec::new();
        let mut components = Vec::new();
        for (index, raw_file) in items.iter().enumerate() {
            let Lite::Dict(file_at) = raw_file else {
                return Err(format!("info.files[{index}] must be a dictionary"));
            };
            walker.dict_entries(*file_at, &mut entries);
            let raw_length = get(&entries, "length");
            let raw_path =
                as_list_like(get(&entries, "path.utf-8").or_else(|| get(&entries, "path")));
            let (Some(Lite::Int(length)), Some(raw_path)) = (raw_length, raw_path) else {
                return Err(format!("info.files[{index}] has an invalid length or path"));
            };
            if *length < 0 {
                return Err(format!("info.files[{index}] has an invalid length or path"));
            }
            let path_at = match raw_path {
                ListLike::List(at) => at,
                ListLike::Bytes(0) => return Err(format!("info.files[{index}] has an empty path")),
                ListLike::Bytes(_) => {
                    return Err(format!("info.files[{index}] has an invalid path component"))
                }
            };
            walker.list_items(path_at, &mut components);
            let start = pool.len();
            for (n, component) in components.iter().enumerate() {
                let Lite::Bytes(component) = component else {
                    return Err(format!("info.files[{index}] has an invalid path component"));
                };
                if component.is_empty() {
                    return Err(format!("info.files[{index}] has an invalid path component"));
                }
                if n > 0 {
                    pool.push(u16::from(b'/'));
                }
                push_utf16(pool, &decode_dart_utf8(component));
            }
            if components.is_empty() {
                return Err(format!("info.files[{index}] has an empty path"));
            }
            files.push(MetainfoFile {
                length: *length,
                path: pool_range(pool, start),
            });
        }
        return Ok(files);
    }

    let raw_name = get(info, "name.utf-8").or_else(|| get(info, "name"));
    if let (Some(Lite::Int(length)), Some(Lite::Bytes(name))) = (get(info, "length"), raw_name) {
        if *length >= 0 && !name.is_empty() {
            let start = pool.len();
            push_utf16(pool, &decode_dart_utf8(name));
            return Ok(vec![MetainfoFile {
                length: *length,
                path: pool_range(pool, start),
            }]);
        }
    }
    // 纯 v2 种子靠 `file tree` 描述文件；旧实现刻意不给猜测的文件下标（见 Dart 侧注释）。
    Ok(Vec::new())
}

/// 输出头的字节数（见 [ffc_parse_bencode_inspect_torrent]）。
pub const RESULT_HEADER_BYTES: usize = 80;
/// 每个文件记录的字节数。
pub const FILE_RECORD_BYTES: usize = 16;

fn put32(out: &mut [u8], at: usize, value: u32) {
    out[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

/// 结果序列化成 [ffc_parse_bencode_inspect_torrent] 的输出布局。
pub fn encode_result(result: &Result<Metainfo, MetainfoError>) -> Vec<u8> {
    match result {
        Err(error) => {
            let detail: Vec<u16> = error.detail.encode_utf16().collect();
            let mut out = vec![0u8; RESULT_HEADER_BYTES];
            put32(&mut out, 0, 1);
            put32(&mut out, 4, error.code as u32);
            put32(&mut out, 64, 0);
            put32(&mut out, 68, detail.len() as u32);
            for unit in detail {
                out.extend_from_slice(&unit.to_le_bytes());
            }
            out
        }
        Ok(meta) => {
            let mut pool_extra: Vec<u16> = Vec::new();
            let file_count = meta.files.as_ref().map_or(0, Vec::len);
            let mut out = Vec::with_capacity(
                RESULT_HEADER_BYTES + file_count * FILE_RECORD_BYTES + meta.pool.len() * 2 + 64,
            );
            out.resize(RESULT_HEADER_BYTES, 0);
            let mut flags = 0u32;
            if let Some(hash) = &meta.v1_info_hash {
                flags |= 1;
                out[8..28].copy_from_slice(hash);
            }
            if let Some(hash) = &meta.v2_info_hash {
                flags |= 2;
                out[28..60].copy_from_slice(hash);
            }
            if let Some((off, len)) = meta.name {
                flags |= 4;
                put32(&mut out, 72, off);
                put32(&mut out, 76, len);
            }
            match &meta.files {
                Err(detail) => {
                    flags |= 8;
                    put32(&mut out, 64, meta.pool.len() as u32);
                    pool_extra.extend(detail.encode_utf16());
                    put32(&mut out, 68, pool_extra.len() as u32);
                }
                Ok(files) => {
                    put32(&mut out, 60, files.len() as u32);
                    for file in files {
                        out.extend_from_slice(&file.length.to_le_bytes());
                        out.extend_from_slice(&file.path.0.to_le_bytes());
                        out.extend_from_slice(&file.path.1.to_le_bytes());
                    }
                }
            }
            put32(&mut out, 4, flags);
            for unit in meta.pool.iter().chain(pool_extra.iter()) {
                out.extend_from_slice(&unit.to_le_bytes());
            }
            out
        }
    }
}

/// 检查一份 .torrent（`data[0..len]`，调用方已排除空 / 超过 16 MiB）。
///
/// 输出（Rust 分配，[crate::ffc_free_bytes] 释放），小端：
/// - `[0..4)` outcome：0 = 解析成功，1 = 致命错误；
/// - 致命错误：`[4..8)` 错误码（Dart `TorrentMetainfoErrorCode` 下标），`[64..72)` 消息在
///   UTF-16 池里的（起点, 码元数）；
/// - 成功：`[4..8)` flags（bit0 有 v1、bit1 有 v2、bit2 有 name、bit3 文件清单不合法），
///   `[8..28)` v1 SHA-1，`[28..60)` v2 SHA-256，`[60..64)` 文件数，`[64..72)` 文件清单错误消息
///   （bit3），`[72..80)` name（bit2）；之后是文件数个 16 字节记录（i64 长度、u32 路径起点、
///   u32 路径码元数）；
/// - 最后是 UTF-16 池（码元，起点从 0 计，相对于池首）。
///
/// # Safety
/// `data` 可读 `len` 字节；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_bencode_inspect_torrent(
    data: *const u8,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if data.is_null() || out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    if len == 0 {
        return status::INVALID_ARGUMENT;
    }
    guard(|| {
        let bytes = std::slice::from_raw_parts(data, len);
        let encoded = encode_result(&inspect_metainfo(bytes));
        hand_over_bytes(encoded, out_ptr, out_len);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(input: &[u8]) -> (MetainfoErrorCode, &'static str) {
        let e = inspect_metainfo(input).unwrap_err();
        (e.code, e.detail)
    }

    fn invalid(input: &[u8]) -> &'static str {
        let (code, detail) = err(input);
        assert_eq!(code, MetainfoErrorCode::InvalidBencode, "{detail}");
        detail
    }

    fn files(input: &[u8]) -> Result<Vec<(String, i64)>, String> {
        let meta = inspect_metainfo(input).unwrap();
        meta.files.clone().map(|files| {
            files
                .iter()
                .map(|f| (meta.text(f.path), f.length))
                .collect()
        })
    }

    #[test]
    fn strict_bencode_errors_match_the_old_messages() {
        assert_eq!(invalid(b"le"), "root value must be a dictionary");
        assert_eq!(invalid(b"d"), "unexpected end of input");
        assert_eq!(invalid(b"d1:ai-0ee"), "non-canonical integer");
        assert_eq!(invalid(b"d1:ai03ee"), "non-canonical integer");
        assert_eq!(invalid(b"d1:aiee"), "non-canonical integer");
        assert_eq!(invalid(b"d1:ai-ee"), "non-canonical integer");
        assert_eq!(invalid(b"d1:ai-01ee"), "non-canonical integer");
        assert_eq!(invalid(b"d1:ai1-2ee"), "integer is outside supported range");
        assert_eq!(
            invalid(b"d1:ai9223372036854775808ee"),
            "integer is outside supported range"
        );
        assert_eq!(invalid(b"d1:ai1xee"), "invalid integer");
        assert_eq!(invalid(b"d1:a02:abe"), "non-canonical byte string length");
        assert_eq!(invalid(b"d:e"), "non-canonical byte string length");
        assert_eq!(invalid(b"d1:a5:abe"), "byte string exceeds input");
        assert_eq!(
            invalid(b"d1:a99999999999999999999:e"),
            "byte string exceeds input"
        );
        assert_eq!(invalid(b"d1:a9223372036854775807:e"), MALFORMED);
        assert_eq!(invalid(b"d1:ax1:be"), "unknown bencode marker");
        assert_eq!(invalid(b"dxe"), "invalid byte string length");
        assert_eq!(invalid(b"d1:ai1e1:ai2ee"), "duplicate root key");
        assert_eq!(invalid(b"d1:ad1:bi1e1:bi2eee"), "duplicate dictionary key");
        assert_eq!(invalid(b"d4:infoi1ee"), "info must be a dictionary");
        assert_eq!(invalid(b"d1:ai1eex"), "trailing bytes after root value");
        // 解码后相同的键算重复：两个不同的非法字节都解成 U+FFFD；BOM 被剥掉。
        assert_eq!(invalid(b"d1:\xffi1e1:\xfei2ee"), "duplicate root key");
        assert_eq!(
            invalid(b"d4:infod6:pieces0:e7:\xef\xbb\xbfinfod6:pieces0:ee"),
            "duplicate root key"
        );
        // 同名键出现在不同层级、或兄弟字典里不算重复（判重集合按层复用）。
        assert_eq!(
            err(b"d1:ad1:ai1ee1:bd1:ai1eee").0,
            MetainfoErrorCode::MissingInfo
        );
        assert_eq!(
            err(b"d1:ald1:ai1eed1:ai1eeee").0,
            MetainfoErrorCode::MissingInfo
        );
    }

    #[test]
    fn duplicate_detection_in_large_dictionaries() {
        let mut dict = b"d1:ad".to_vec();
        for i in 0..40 {
            dict.extend_from_slice(format!("2:{i:02}i1e").as_bytes());
        }
        let mut ok = dict.clone();
        ok.extend_from_slice(b"ee");
        assert_eq!(err(&ok).0, MetainfoErrorCode::MissingInfo);
        dict.extend_from_slice(b"2:07i1eee");
        assert_eq!(invalid(&dict), "duplicate dictionary key");
    }

    #[test]
    fn depth_and_value_limits() {
        let mut deep = b"d1:a".to_vec();
        deep.extend(std::iter::repeat_n(b'l', 100));
        deep.extend(std::iter::repeat_n(b'e', 100));
        deep.push(b'e');
        assert_eq!(err(&deep).1, "root dictionary has no info dictionary");
        let mut deeper = b"d1:a".to_vec();
        deeper.extend(std::iter::repeat_n(b'l', 101));
        deeper.extend(std::iter::repeat_n(b'e', 101));
        deeper.push(b'e');
        assert_eq!(invalid(&deeper), "maximum nesting depth exceeded");
        let mut many = b"d1:al".to_vec();
        many.extend(std::iter::repeat_n(*b"i1e", 999_999).flatten());
        many.extend_from_slice(b"ee");
        assert_eq!(err(&many).1, "root dictionary has no info dictionary");
        let mut too_many = b"d1:al".to_vec();
        too_many.extend(std::iter::repeat_n(*b"i1e", 1_000_000).flatten());
        too_many.extend_from_slice(b"ee");
        assert_eq!(invalid(&too_many), "too many bencode values");
    }

    #[test]
    fn hashes_files_and_names() {
        let info = b"d5:filesld6:lengthi3e4:pathl1:a2:b\xffeed6:lengthi0e10:path.utf-8l1:ceee4:name5:\xef\xbb\xbf x12:piece lengthi16384e6:pieces0:e";
        let mut torrent = b"d4:info".to_vec();
        torrent.extend_from_slice(info);
        torrent.push(b'e');
        let meta = inspect_metainfo(&torrent).unwrap();
        assert_eq!(
            meta.v1_info_hash.unwrap(),
            <[u8; 20]>::from(Sha1::digest(info))
        );
        assert!(meta.v2_info_hash.is_none());
        assert_eq!(meta.text(meta.name.unwrap()), " x");
        assert_eq!(
            files(&torrent).unwrap(),
            vec![("a/b\u{FFFD}".to_string(), 3), ("c".to_string(), 0)]
        );
        assert_eq!(
            files(b"d4:infod5:filesli1ee6:pieces0:ee").unwrap_err(),
            "info.files[0] must be a dictionary"
        );
        // 字节串在旧实现里也是 List：files / path 为字节串的形态。
        assert_eq!(
            files(b"d4:infod5:files4:nope6:lengthi9e4:name1:z6:pieces0:ee").unwrap_err(),
            "info.files[0] must be a dictionary"
        );
        assert_eq!(
            files(b"d4:infod5:files0:6:lengthi9e4:name1:z6:pieces0:ee").unwrap(),
            vec![]
        );
        assert_eq!(
            files(b"d4:infod5:filesld6:lengthi1e4:path1:aee6:pieces0:ee").unwrap_err(),
            "info.files[0] has an invalid path component"
        );
        assert_eq!(
            files(b"d4:infod5:filesld6:lengthi1e4:path0:ee6:pieces0:ee").unwrap_err(),
            "info.files[0] has an empty path"
        );
        let v2 = b"d4:infod12:meta versioni2e4:name1:yee";
        let meta = inspect_metainfo(v2).unwrap();
        assert!(meta.v1_info_hash.is_none());
        assert!(meta.v2_info_hash.is_some());
        assert_eq!(meta.files.unwrap(), vec![]);
        assert_eq!(
            err(b"d4:infod4:name1:yee").0,
            MetainfoErrorCode::UnsupportedVersion
        );
        assert_eq!(
            files(b"d4:infod6:lengthi-1e4:name1:a6:pieces0:ee").unwrap(),
            vec![]
        );
        assert_eq!(
            files(b"d4:infod6:lengthi9e4:name1:a6:pieces0:ee").unwrap(),
            vec![("a".to_string(), 9)]
        );
    }

    #[test]
    fn ffi_layout() {
        let input = b"d4:infod6:lengthi7e4:name1:z6:pieces0:ee";
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe {
            ffc_parse_bencode_inspect_torrent(input.as_ptr(), input.len(), &mut ptr, &mut len)
        };
        assert_eq!(rc, status::OK);
        let out = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        crate::ffc_free_bytes(ptr, len);
        let word = |at: usize| u32::from_le_bytes(out[at..at + 4].try_into().unwrap());
        assert_eq!(word(0), 0);
        assert_eq!(word(4), 1 | 4);
        assert_eq!(word(60), 1);
        assert_eq!(len, RESULT_HEADER_BYTES + FILE_RECORD_BYTES + 4);
        assert_eq!(i64::from_le_bytes(out[80..88].try_into().unwrap()), 7);
        let rc =
            unsafe { ffc_parse_bencode_inspect_torrent(input.as_ptr(), 0, &mut ptr, &mut len) };
        assert_eq!(rc, status::INVALID_ARGUMENT);
        // 文件清单错误：消息接在池尾。
        let bad = b"d4:infod5:filesli1ee4:name2:ab6:pieces0:ee";
        let rc = unsafe {
            ffc_parse_bencode_inspect_torrent(bad.as_ptr(), bad.len(), &mut ptr, &mut len)
        };
        assert_eq!(rc, status::OK);
        let out = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        crate::ffc_free_bytes(ptr, len);
        let word = |at: usize| u32::from_le_bytes(out[at..at + 4].try_into().unwrap());
        assert_eq!(word(4), 1 | 4 | 8);
        assert_eq!((word(72), word(76)), (0, 2));
        let pool: Vec<u16> = out[RESULT_HEADER_BYTES..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let (off, n) = (word(64) as usize, word(68) as usize);
        assert_eq!(
            String::from_utf16(&pool[off..off + n]).unwrap(),
            "info.files[0] must be a dictionary"
        );
    }

    /// 分阶段计时（`cargo test --release -- --ignored --nocapture phase_timing`）。
    #[test]
    #[ignore]
    fn phase_timing() {
        let mut files = b"l".to_vec();
        for i in 0..100_000u32 {
            let comp = format!("第{}巻 {}.flac", i / 100, i * 7919 % 1_000_000);
            let disk = format!("ディスク{}", i % 7);
            files.extend_from_slice(
                format!(
                    "d6:lengthi{}e4:pathl{}:{}{}:{}ee",
                    i,
                    disk.len(),
                    disk,
                    comp.len(),
                    comp
                )
                .as_bytes(),
            );
        }
        files.push(b'e');
        let mut torrent = b"d4:infod5:files".to_vec();
        torrent.extend_from_slice(&files);
        torrent.extend_from_slice(b"4:name1:x6:pieces0:ee");
        for _ in 0..3 {
            let t0 = std::time::Instant::now();
            let meta = inspect_metainfo(&torrent);
            let t1 = t0.elapsed();
            let out = encode_result(&meta);
            let t2 = t0.elapsed();
            println!(
                "{} B: inspect {:?} encode {:?} -> {} B",
                torrent.len(),
                t1,
                t2 - t1,
                out.len()
            );
        }
    }
}
