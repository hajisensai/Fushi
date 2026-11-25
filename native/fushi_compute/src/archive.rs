//! 归档探测与解包（zip / 7z，含密码），C ABI `ffc_archive_*`。
//!
//! 导入链路（书 / 漫画 / 有声书 / 游戏 / 发现页下载）唯一的 zip / 7z 解包实现：Dart 侧
//! `packages/fushi_engine` 的 `ArchiveUnpacker` 先 [ffc_archive_probe] 定性（格式、是否加密、
//! 归档指纹），再 [ffc_archive_extract] 解进它自己建的暂存目录；失败时由 Dart 删掉暂存目录，
//! 所以这里不回滚已写出的文件。RAR 不在这里解（UnRAR 许可不能链进 GPL 本体），探测只报
//! [format::RAR]，Dart 侧交给随包 7-Zip 命令行。
//!
//! 加密：
//! - zip：传统 ZipCrypto 与 WinZip AES-128/192/256（`zip` crate）。ZipCrypto 的口令校验字节
//!   只有 1/256 的区分度，错口令漏过去的那 1/256 在条目读完时由 CRC 判出，同样报
//!   [archive_status::WRONG_PASSWORD]。
//! - 7z：AES-256 + SHA-256，含「加密文件名」（`-mhe=on`，不给口令连条目表都读不出）。
//!
//! 分卷：7-Zip「分卷」是把整个归档按字节切成 `name.7z.001`、`.002`…（zip 同理），这里把
//! 第一卷及其后连续编号的各卷拼成一个连续的 `Read + Seek` 流（[VolumeReader]）再照常探测 /
//! 解包，指纹也按拼接后的流算。只认第一卷（`.001`）：给的是后续卷、或拼出来的流比条目表声明
//! 的短（缺卷），报 [archive_status::MISSING_VOLUME]。
//!
//! 安全：条目路径一律相对、不含 `..` / 盘符 / 绝对路径 / `:`（NTFS 备用流）/ NUL，否则整包
//! 报 [archive_status::UNSAFE_ENTRY]（下载物与用户拖进来的包都是不可信输入）；符号链接条目
//! 跳过不写；解出总字节数与文件数按调用方给的上限**按实际写出量**强制（声明大小可以谎报）。

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use sha2::{Digest, Sha256};

use crate::hash::{cancel_flag, input};
use crate::{guard, status};

/// [ffc_archive_probe] 报的容器格式。
pub mod format {
    /// 不认识（不是 zip / 7z / rar）。
    pub const UNKNOWN: i32 = 0;
    pub const ZIP: i32 = 1;
    pub const SEVEN_Z: i32 = 2;
    /// RAR（4.x / 5.x）：只认出来，不在本库解。
    pub const RAR: i32 = 3;
}

/// [ffc_archive_probe] 报的加密情况。
pub mod encryption {
    pub const NONE: i32 = 0;
    /// 条目内容加密（条目表可读）。
    pub const ENTRIES: i32 = 1;
    /// 条目表本身加密（7z `-mhe=on`）：不给口令什么都读不出，条目数 / 大小报 0。
    pub const HEADERS: i32 = 2;
}

/// 归档专用的返回码（与 [crate::status] 的通用码不重叠）。
pub mod archive_status {
    /// 包加密了、调用方没给口令。
    pub const PASSWORD_REQUIRED: i32 = -20;
    /// 给的口令不对（或加密数据损坏——两者在密码学上分不开，7-Zip 也报「口令错误？」）。
    pub const WRONG_PASSWORD: i32 = -21;
    /// 条目路径不安全（zip-slip 等），整包拒绝。
    pub const UNSAFE_ENTRY: i32 = -22;
    /// 解出的总字节数或文件数超过调用方给的上限。
    pub const TOO_LARGE: i32 = -23;
    /// 格式或压缩方法本库不支持（含 RAR、未编进的压缩算法）。
    pub const UNSUPPORTED: i32 = -24;
    /// 分卷包拼不全：给的不是第一卷（`.001`），或后面缺卷。
    pub const MISSING_VOLUME: i32 = -25;
}

/// 指纹取样：文件头尾各这么多字节。
const FINGERPRINT_SAMPLE: u64 = 1 << 20;

/// 解包时的拷贝块大小。
const COPY_CHUNK: usize = 256 * 1024;

/// 7z 解码器（条目表缓冲、LZMA 字典、PPMd 模型）的内存上限，KiB。`sevenz-rust2` 缺省不设
/// 上限：PPMd 模型按头里声明的大小一次分配，不可信的包声明几 GB 会让分配失败直接 abort
/// 整个进程（`catch_unwind` 兜不住）。2 GiB 与 RAR 走 7-Zip 命令行时的 `-smemx2g` 一致，
/// 盖得住 7-Zip 最大的 1536 MiB 字典；超了报 [archive_status::TOO_LARGE]。
const SEVEN_Z_MEMORY_LIMIT_KB: usize = 2 * 1024 * 1024;

const ZIP_MAGICS: [&[u8]; 3] = [b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"];
const SEVEN_Z_MAGIC: &[u8] = b"7z\xBC\xAF\x27\x1C";
const RAR_MAGIC: &[u8] = b"Rar!\x1A\x07";

/// 探测结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveInfo {
    pub format: i32,
    pub encryption: i32,
    /// 文件条目数（不含目录）。
    pub entry_count: u64,
    /// 条目表声明的解出总字节数（只作预检，可谎报）。
    pub unpacked_size: u64,
    /// 归档指纹：`SHA-256("fushi-archive-fp-v1" ‖ 文件长度 u64 LE ‖ 头 1 MiB ‖ 尾 1 MiB)`。
    /// 记住的口令按它找；整文件哈希对几 GB 的包太慢，头尾 + 长度对「同一个包」足够稳定。
    pub fingerprint: [u8; 32],
}

/// 解包选项。
pub struct ExtractOptions<'a> {
    /// 口令（UTF-8）；`None` = 不给口令。
    pub password: Option<&'a str>,
    /// 只解这些扩展名（小写、带点）；空 = 全解。
    pub include_extensions: Vec<String>,
    /// 解出总字节数上限（0 = 不限）。
    pub max_total_bytes: u64,
    /// 解出文件数上限（0 = 不限）。
    pub max_entries: u64,
    pub cancel: Option<&'a AtomicU32>,
}

/// 解包统计。
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ExtractStats {
    pub files: u64,
    pub bytes: u64,
}

/// 归档指纹（见 [ArchiveInfo::fingerprint]）；分卷按拼接后的流算。
pub fn fingerprint(path: &Path) -> Result<[u8; 32], i32> {
    let mut source = open_source(path)?;
    fingerprint_of(&mut source.reader).map_err(|_| status::IO_ERROR)
}

fn fingerprint_of<R: Read + Seek>(file: &mut R) -> io::Result<[u8; 32]> {
    let len = file.seek(SeekFrom::End(0))?;
    let mut hasher = Sha256::new();
    hasher.update(b"fushi-archive-fp-v1");
    hasher.update(len.to_le_bytes());
    let head = len.min(FINGERPRINT_SAMPLE);
    feed_range(file, 0, head, &mut hasher)?;
    if len > head {
        let tail_start = len.saturating_sub(FINGERPRINT_SAMPLE).max(head);
        feed_range(file, tail_start, len - tail_start, &mut hasher)?;
    }
    Ok(hasher.finalize().into())
}

fn feed_range<R: Read + Seek>(
    file: &mut R,
    start: u64,
    len: u64,
    hasher: &mut Sha256,
) -> io::Result<()> {
    file.seek(SeekFrom::Start(start))?;
    let mut limited = file.take(len);
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = limited.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        hasher.update(&buf[..n]);
    }
}

/// 按魔数定格式；都不是时再试一次 zip 中央目录（自解压 exe 等前面带东西的 zip）。
pub fn sniff_format(path: &Path) -> Result<i32, i32> {
    let mut source = open_source(path)?;
    sniff_format_of(&mut source.reader).map_err(|_| status::IO_ERROR)
}

fn sniff_format_of(file: &mut VolumeReader) -> io::Result<i32> {
    let mut head = [0u8; 8];
    file.seek(SeekFrom::Start(0))?;
    let mut filled = 0;
    while filled < head.len() {
        let n = file.read(&mut head[filled..])?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    let head = &head[..filled];
    if head.starts_with(SEVEN_Z_MAGIC) {
        return Ok(format::SEVEN_Z);
    }
    if head.starts_with(RAR_MAGIC) {
        return Ok(format::RAR);
    }
    if ZIP_MAGICS.iter().any(|m| head.starts_with(m)) {
        return Ok(format::ZIP);
    }
    file.seek(SeekFrom::Start(0))?;
    Ok(if zip::ZipArchive::new(&mut *file).is_ok() {
        format::ZIP
    } else {
        format::UNKNOWN
    })
}

/// 探测：格式、加密情况、条目数、声明大小、指纹。读不了文件 → `Err(IO_ERROR)`；格式认出来
/// 但条目表坏 → `Err(BAD_INPUT)`。
pub fn probe(path: &Path) -> Result<ArchiveInfo, i32> {
    let mut source = open_source(path)?;
    let fp = fingerprint_of(&mut source.reader).map_err(|_| status::IO_ERROR)?;
    let fmt = sniff_format_of(&mut source.reader).map_err(|_| status::IO_ERROR)?;
    source.check_complete(fmt)?;
    let mut info = ArchiveInfo {
        format: fmt,
        encryption: encryption::NONE,
        entry_count: 0,
        unpacked_size: 0,
        fingerprint: fp,
    };
    match fmt {
        format::ZIP => {
            let archive = source.open_zip()?;
            for i in 0..archive.len() {
                let entry = archive.by_index_data(i).map_err(|_| status::BAD_INPUT)?;
                if entry.encrypted() {
                    info.encryption = encryption::ENTRIES;
                }
                if entry.is_file() {
                    info.entry_count += 1;
                    info.unpacked_size = info.unpacked_size.saturating_add(entry.size());
                }
            }
        }
        format::SEVEN_Z => match open_7z_archive(path)? {
            Ok(archive) => {
                for (i, entry) in archive.files.iter().enumerate() {
                    if archive.is_file_encrypted(i) {
                        info.encryption = encryption::ENTRIES;
                    }
                    if !entry.is_directory && !entry.is_anti_item {
                        info.entry_count += 1;
                        info.unpacked_size = info.unpacked_size.saturating_add(entry.size);
                    }
                }
            }
            Err(sevenz_rust2::Error::PasswordRequired) => info.encryption = encryption::HEADERS,
            Err(sevenz_rust2::Error::MaxMemLimited { .. }) => {
                return Err(archive_status::TOO_LARGE);
            }
            Err(_) => return Err(status::BAD_INPUT),
        },
        _ => {}
    }
    Ok(info)
}

/// 解包到 `dest`（不存在会建）。失败返回状态码（[status] 或 [archive_status]），已写出的文件
/// 留给调用方清理。
pub fn extract(path: &Path, dest: &Path, opts: &ExtractOptions<'_>) -> Result<ExtractStats, i32> {
    fs::create_dir_all(dest).map_err(|_| status::IO_ERROR)?;
    let mut source = open_source(path)?;
    let fmt = sniff_format_of(&mut source.reader).map_err(|_| status::IO_ERROR)?;
    source.check_complete(fmt)?;
    let mut sink = Sink::new(dest, opts);
    match fmt {
        format::ZIP => extract_zip(source, opts.password, &mut sink)?,
        format::SEVEN_Z => extract_7z(path, opts.password, &mut sink)?,
        _ => return Err(archive_status::UNSUPPORTED),
    }
    Ok(sink.stats)
}

/// 条目写出端：路径校验、扩展名过滤、上限、取消。
struct Sink<'a> {
    dest: &'a Path,
    include: &'a [String],
    max_total_bytes: u64,
    max_entries: u64,
    cancel: Option<&'a AtomicU32>,
    stats: ExtractStats,
    buf: Vec<u8>,
}

/// 写一个条目失败的原因：读端（解码 / 解密）出错要由调用方按「是否加密」定性。
enum WriteError {
    Status(i32),
    Read,
}

impl<'a> Sink<'a> {
    fn new(dest: &'a Path, opts: &'a ExtractOptions<'a>) -> Self {
        Self {
            dest,
            include: &opts.include_extensions,
            max_total_bytes: opts.max_total_bytes,
            max_entries: opts.max_entries,
            cancel: opts.cancel,
            stats: ExtractStats::default(),
            buf: vec![0u8; COPY_CHUNK],
        }
    }

    fn cancelled(&self) -> bool {
        self.cancel
            .is_some_and(|flag| flag.load(Ordering::Acquire) != 0)
    }

    /// 校验条目路径并按扩展名过滤：不安全 → `Err(UNSAFE_ENTRY)`；过滤掉 → `Ok(None)`。
    fn admit(&self, name: &str) -> Result<Option<PathBuf>, i32> {
        let rel = safe_relative_path(name).ok_or(archive_status::UNSAFE_ENTRY)?;
        let Some(rel) = rel else { return Ok(None) };
        if !self.include.is_empty() {
            let lower = name.to_lowercase();
            if !self.include.iter().any(|ext| lower.ends_with(ext.as_str())) {
                return Ok(None);
            }
        }
        Ok(Some(rel))
    }

    fn write(&mut self, rel: &Path, reader: &mut dyn Read) -> Result<(), WriteError> {
        if self.cancelled() {
            return Err(WriteError::Status(status::CANCELLED));
        }
        self.stats.files += 1;
        if self.max_entries > 0 && self.stats.files > self.max_entries {
            return Err(WriteError::Status(archive_status::TOO_LARGE));
        }
        let target = self.dest.join(rel);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|_| WriteError::Status(status::IO_ERROR))?;
        }
        let mut out = File::create(&target).map_err(|_| WriteError::Status(status::IO_ERROR))?;
        loop {
            let n = match reader.read(&mut self.buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(WriteError::Read),
            };
            self.stats.bytes += n as u64;
            if self.max_total_bytes > 0 && self.stats.bytes > self.max_total_bytes {
                return Err(WriteError::Status(archive_status::TOO_LARGE));
            }
            if self.cancelled() {
                return Err(WriteError::Status(status::CANCELLED));
            }
            out.write_all(&self.buf[..n])
                .map_err(|_| WriteError::Status(status::IO_ERROR))?;
        }
        Ok(())
    }
}

/// 归一条目路径：`\` 当分隔符，去掉空段与 `.`。返回 `None` = 不安全；`Some(None)` = 空路径
/// （只有分隔符 / `.`，没有可写的东西）。
pub fn safe_relative_path(name: &str) -> Option<Option<PathBuf>> {
    let normalized = name.replace('\\', "/");
    if normalized.starts_with('/') || normalized.contains('\0') {
        return None;
    }
    let bytes = normalized.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return None;
    }
    let mut out = PathBuf::new();
    let mut any = false;
    for segment in normalized.split('/') {
        match segment {
            "" | "." => continue,
            ".." => return None,
            s if s.contains(':') => return None,
            s => {
                out.push(s);
                any = true;
            }
        }
    }
    Some(any.then_some(out))
}

// ── zip ────────────────────────────────────────────────────────────────────────────────

/// 条目名：合法 UTF-8 原样用；其余（老式日文包的 Shift_JIS 等）整批交 [crate::legacy_text]
/// 判编码，判不出再退回 zip 规范的 CP437。
fn zip_entry_names<R: Read + Seek>(archive: &zip::ZipArchive<R>) -> Result<Vec<String>, i32> {
    let mut names: Vec<Option<String>> = Vec::with_capacity(archive.len());
    let mut legacy_raw: Vec<Vec<u8>> = Vec::new();
    let mut legacy_index: Vec<usize> = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index_data(i).map_err(|_| status::BAD_INPUT)?;
        let raw = entry.name_raw();
        match std::str::from_utf8(raw) {
            Ok(s) => names.push(Some(s.to_owned())),
            Err(_) => {
                legacy_index.push(i);
                legacy_raw.push(raw.to_vec());
                names.push(None);
            }
        }
    }
    if !legacy_raw.is_empty() {
        let slices: Vec<&[u8]> = legacy_raw.iter().map(|v| v.as_slice()).collect();
        if let Some((_, decoded)) = crate::legacy_text::decode_batch(&slices) {
            for (slot, name) in legacy_index.iter().zip(decoded) {
                names[*slot] = Some(name);
            }
        }
    }
    let mut out = Vec::with_capacity(names.len());
    for (i, name) in names.into_iter().enumerate() {
        out.push(match name {
            Some(n) => n,
            None => archive
                .by_index_data(i)
                .map_err(|_| status::BAD_INPUT)?
                .name()
                .map_err(|_| status::BAD_INPUT)?
                .into_owned(),
        });
    }
    Ok(out)
}

fn extract_zip(source: Source, password: Option<&str>, sink: &mut Sink<'_>) -> Result<(), i32> {
    let mut archive = source.open_zip()?;
    let names = zip_entry_names(&archive)?;
    let mut any_encrypted = false;
    // 先整包过一遍路径与加密：不安全的包、缺口令的包一个文件都不写。
    for (i, name) in names.iter().enumerate() {
        let entry = archive.by_index_data(i).map_err(|_| status::BAD_INPUT)?;
        safe_relative_path(name).ok_or(archive_status::UNSAFE_ENTRY)?;
        any_encrypted |= entry.encrypted();
    }
    if any_encrypted && password.is_none() {
        return Err(archive_status::PASSWORD_REQUIRED);
    }
    for (i, name) in names.iter().enumerate() {
        let (is_file, encrypted) = {
            let entry = archive.by_index_data(i).map_err(|_| status::BAD_INPUT)?;
            (entry.is_file(), entry.encrypted())
        };
        if !is_file {
            continue;
        }
        let Some(rel) = sink.admit(name)? else {
            continue;
        };
        let mut reader = if encrypted {
            let pw = password.unwrap_or_default();
            archive
                .by_index_decrypt(i, pw.as_bytes())
                .map_err(zip_open_status)?
        } else {
            archive.by_index(i).map_err(zip_open_status)?
        };
        match sink.write(&rel, &mut reader) {
            Ok(()) => {}
            Err(WriteError::Status(s)) => return Err(s),
            // AES 的 HMAC / ZipCrypto 漏过校验字节后的 CRC 都在读到条目末尾时才判出。
            Err(WriteError::Read) if encrypted => return Err(archive_status::WRONG_PASSWORD),
            Err(WriteError::Read) => return Err(status::BAD_INPUT),
        }
    }
    Ok(())
}

fn zip_open_status(e: zip::result::ZipError) -> i32 {
    use zip::result::ZipError;
    match e {
        ZipError::InvalidPassword => archive_status::WRONG_PASSWORD,
        ZipError::UnsupportedArchive(_) | ZipError::CompressionMethodNotSupported(_) => {
            archive_status::UNSUPPORTED
        }
        ZipError::Io(_) => status::IO_ERROR,
        _ => status::BAD_INPUT,
    }
}

// ── 7z ─────────────────────────────────────────────────────────────────────────────────

/// 7z 条目是不是符号链接：Windows 重解析点属性，或高 16 位带 Unix 模式且是 `S_IFLNK`。
fn sevenz_is_symlink(entry: &sevenz_rust2::ArchiveEntry) -> bool {
    if !entry.has_windows_attributes {
        return false;
    }
    let attrs = entry.windows_attributes;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const UNIX_EXTENSION: u32 = 0x8000;
    if attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return true;
    }
    attrs & UNIX_EXTENSION != 0 && (attrs >> 16) & 0o170000 == 0o120000
}

fn extract_7z(path: &Path, password: Option<&str>, sink: &mut Sink<'_>) -> Result<(), i32> {
    use sevenz_rust2::{ArchiveReader, Error, Password};
    let pw = password.map(Password::new).unwrap_or_else(Password::empty);
    let file = open_source(path)?.reader;
    let mut reader = match ArchiveReader::new_with_memory_limit(file, pw, SEVEN_Z_MEMORY_LIMIT_KB) {
        Ok(r) => r,
        Err(Error::PasswordRequired) => return Err(archive_status::PASSWORD_REQUIRED),
        Err(Error::MaxMemLimited { .. }) => return Err(archive_status::TOO_LARGE),
        Err(Error::UnsupportedCompressionMethod(_)) | Err(Error::Unsupported(_)) => {
            return Err(archive_status::UNSUPPORTED);
        }
        Err(Error::Io(..)) | Err(Error::FileOpen(..)) if !path.is_file() => {
            return Err(status::IO_ERROR);
        }
        Err(_) if password.is_some() && sevenz_headers_encrypted(path) => {
            // 条目表加密的包：错口令解出来的条目表是乱码，报什么错都有可能。
            return Err(archive_status::WRONG_PASSWORD);
        }
        Err(_) => return Err(status::BAD_INPUT),
    };
    let archive = reader.archive();
    let any_encrypted = (0..archive.files.len()).any(|i| archive.is_file_encrypted(i));
    for entry in &archive.files {
        safe_relative_path(&entry.name).ok_or(archive_status::UNSAFE_ENTRY)?;
    }
    if any_encrypted && password.is_none() {
        return Err(archive_status::PASSWORD_REQUIRED);
    }
    let mut abort: Option<i32> = None;
    let result = reader.for_each_entries(|entry, rd| {
        if entry.is_directory || entry.is_anti_item || sevenz_is_symlink(entry) {
            return Ok(true);
        }
        let rel = match sink.admit(&entry.name) {
            Ok(Some(rel)) => rel,
            Ok(None) => return Ok(true),
            Err(s) => {
                abort = Some(s);
                return Err(Error::Other("aborted".into()));
            }
        };
        match sink.write(&rel, rd) {
            Ok(()) => Ok(true),
            Err(WriteError::Status(s)) => {
                abort = Some(s);
                Err(Error::Other("aborted".into()))
            }
            Err(WriteError::Read) => {
                abort = Some(if any_encrypted {
                    archive_status::WRONG_PASSWORD
                } else {
                    status::BAD_INPUT
                });
                Err(Error::Other("aborted".into()))
            }
        }
    });
    if let Some(s) = abort {
        return Err(s);
    }
    match result {
        Ok(()) => Ok(()),
        Err(Error::PasswordRequired) => Err(archive_status::PASSWORD_REQUIRED),
        Err(Error::UnsupportedCompressionMethod(_)) | Err(Error::Unsupported(_)) => {
            Err(archive_status::UNSUPPORTED)
        }
        Err(Error::MaxMemLimited { .. }) => Err(archive_status::TOO_LARGE),
        Err(_) if any_encrypted => Err(archive_status::WRONG_PASSWORD),
        Err(_) => Err(status::BAD_INPUT),
    }
}

/// 不给口令读 7z 条目表（带 [SEVEN_Z_MEMORY_LIMIT_KB] 上限）。外层 `Err` 是打不开源文件 /
/// 拼不全分卷（状态码），内层是 7z 解析结果。
fn open_7z_archive(path: &Path) -> Result<Result<sevenz_rust2::Archive, sevenz_rust2::Error>, i32> {
    let mut file = open_source(path)?.reader;
    Ok(sevenz_rust2::Archive::read_with_memory_limit(
        &mut file,
        &sevenz_rust2::Password::empty(),
        SEVEN_Z_MEMORY_LIMIT_KB,
    ))
}

fn sevenz_headers_encrypted(path: &Path) -> bool {
    matches!(
        open_7z_archive(path),
        Ok(Err(sevenz_rust2::Error::PasswordRequired))
    )
}

// ── 分卷 ───────────────────────────────────────────────────────────────────────────────

/// 分卷编号：文件名形如 `<名>.<归档扩展名>.<至少 3 位数字>`（`book.7z.001`），返回
/// （去掉编号的文件名 `book.7z`、编号位数、编号）。`book.001`（编号前没有扩展名）不认。
fn volume_number(path: &Path) -> Option<(String, usize, u64)> {
    let name = path.file_name()?.to_str()?;
    let (stem, digits) = name.rsplit_once('.')?;
    if digits.len() < 3 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let (base, ext) = stem.rsplit_once('.')?;
    if base.is_empty() || ext.is_empty() {
        return None;
    }
    Some((stem.to_string(), digits.len(), digits.parse().ok()?))
}

/// 打开的归档源：单文件或拼好的分卷。
struct Source {
    reader: VolumeReader,
    /// 来自 `*.NNN` 分卷（哪怕只有一卷）。
    volumes: bool,
}

/// 打开 `path`：`*.001` 连同其后连续编号的各卷拼成一个流；给的是后续卷报
/// [archive_status::MISSING_VOLUME]。
fn open_source(path: &Path) -> Result<Source, i32> {
    let Some((stem, width, number)) = volume_number(path) else {
        let file = File::open(path).map_err(|_| status::IO_ERROR)?;
        return Ok(Source {
            reader: VolumeReader::new(vec![file]).map_err(|_| status::IO_ERROR)?,
            volumes: false,
        });
    };
    if number != 1 {
        return Err(archive_status::MISSING_VOLUME);
    }
    let mut files = Vec::new();
    for k in 1u64.. {
        let part = path.with_file_name(format!("{stem}.{k:0width$}"));
        if !part.is_file() {
            break;
        }
        files.push(File::open(&part).map_err(|_| status::IO_ERROR)?);
    }
    if files.is_empty() {
        return Err(status::IO_ERROR);
    }
    Ok(Source {
        reader: VolumeReader::new(files).map_err(|_| status::IO_ERROR)?,
        volumes: true,
    })
}

impl Source {
    /// 分卷拼出来的流够不够长：7z 起始头声明了条目表的偏移与长度，流比它短就是缺卷；zip 的
    /// 中央目录在最后一卷，缺卷时读不出来。单文件不在这里判（截断的单文件照旧报坏包）。
    fn check_complete(&mut self, fmt: i32) -> Result<(), i32> {
        if !self.volumes {
            return Ok(());
        }
        match fmt {
            format::SEVEN_Z => {
                let mut head = [0u8; 32];
                self.reader
                    .seek(SeekFrom::Start(0))
                    .and_then(|_| self.reader.read_exact(&mut head))
                    .map_err(|_| archive_status::MISSING_VOLUME)?;
                let offset = u64::from_le_bytes(head[12..20].try_into().unwrap());
                let size = u64::from_le_bytes(head[20..28].try_into().unwrap());
                let needed = 32u64.saturating_add(offset).saturating_add(size);
                if needed > self.reader.total {
                    return Err(archive_status::MISSING_VOLUME);
                }
                Ok(())
            }
            format::ZIP => {
                self.reader
                    .seek(SeekFrom::Start(0))
                    .map_err(|_| status::IO_ERROR)?;
                zip::ZipArchive::new(&mut self.reader)
                    .map(|_| ())
                    .map_err(|_| archive_status::MISSING_VOLUME)
            }
            // 首卷认不出格式：不是分卷归档，交给调用方按「不认识」处理。
            _ => Ok(()),
        }
    }

    fn open_zip(mut self) -> Result<zip::ZipArchive<VolumeReader>, i32> {
        self.reader
            .seek(SeekFrom::Start(0))
            .map_err(|_| status::IO_ERROR)?;
        zip::ZipArchive::new(self.reader).map_err(|_| status::BAD_INPUT)
    }
}

/// 把若干文件按顺序当成一个连续流读（单文件 = 一卷）。
struct VolumeReader {
    files: Vec<File>,
    /// 每卷在拼接流里的起点（升序）。
    starts: Vec<u64>,
    total: u64,
    pos: u64,
    /// 文件读指针已对齐到 `pos` 的那一卷（`None` = 下次读前先定位）。
    cursor: Option<usize>,
}

impl VolumeReader {
    fn new(files: Vec<File>) -> io::Result<Self> {
        let mut starts = Vec::with_capacity(files.len());
        let mut total = 0u64;
        for file in &files {
            starts.push(total);
            total = total.saturating_add(file.metadata()?.len());
        }
        Ok(Self {
            files,
            starts,
            total,
            pos: 0,
            cursor: None,
        })
    }
}

impl Read for VolumeReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos >= self.total {
            return Ok(0);
        }
        // 起点 <= pos 的最后一卷（自然跳过长度为 0 的卷）。
        let idx = self.starts.partition_point(|&s| s <= self.pos) - 1;
        let end = self.starts.get(idx + 1).copied().unwrap_or(self.total);
        if self.cursor != Some(idx) {
            self.files[idx].seek(SeekFrom::Start(self.pos - self.starts[idx]))?;
            self.cursor = Some(idx);
        }
        let want = (end - self.pos).min(buf.len() as u64) as usize;
        let n = self.files[idx].read(&mut buf[..want])?;
        if n == 0 {
            // 打开之后卷被截短了。
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.pos += n as u64;
        if self.pos == end {
            self.cursor = None;
        }
        Ok(n)
    }
}

impl Seek for VolumeReader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(n) => Some(n),
            SeekFrom::End(d) => self.total.checked_add_signed(d),
            SeekFrom::Current(d) => self.pos.checked_add_signed(d),
        }
        .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
        if target != self.pos {
            self.pos = target;
            self.cursor = None;
        }
        Ok(self.pos)
    }
}

// ── C ABI ──────────────────────────────────────────────────────────────────────────────

unsafe fn utf8_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    let bytes = input(ptr, len).ok_or(status::NULL_ARGUMENT)?;
    std::str::from_utf8(bytes).map_err(|_| status::INVALID_ARGUMENT)
}

/// 探测归档：格式（[format]）、加密（[encryption]）、文件条目数、声明的解出总字节数、32 字节
/// 指纹（见 [ArchiveInfo::fingerprint]）。RAR / 不认识的格式也返回 OK（格式字段说明）。
///
/// 失败：路径空 / 出参空 → NULL_ARGUMENT；路径非 UTF-8 → INVALID_ARGUMENT；读不了 →
/// IO_ERROR；zip / 7z 条目表坏 → BAD_INPUT。
///
/// # Safety
/// `path` 至少 `path_len` 字节可读；各出参可写，`out_fingerprint` 至少 32 字节。
#[no_mangle]
pub unsafe extern "C" fn ffc_archive_probe(
    path: *const u8,
    path_len: usize,
    out_format: *mut i32,
    out_encryption: *mut i32,
    out_entry_count: *mut u64,
    out_unpacked_size: *mut u64,
    out_fingerprint: *mut u8,
) -> i32 {
    guard(|| {
        if out_format.is_null()
            || out_encryption.is_null()
            || out_entry_count.is_null()
            || out_unpacked_size.is_null()
            || out_fingerprint.is_null()
        {
            return status::NULL_ARGUMENT;
        }
        let path = match utf8_arg(path, path_len) {
            Ok(p) => p,
            Err(s) => return s,
        };
        match probe(Path::new(path)) {
            Ok(info) => {
                *out_format = info.format;
                *out_encryption = info.encryption;
                *out_entry_count = info.entry_count;
                *out_unpacked_size = info.unpacked_size;
                std::slice::from_raw_parts_mut(out_fingerprint, 32)
                    .copy_from_slice(&info.fingerprint);
                status::OK
            }
            Err(s) => s,
        }
    })
}

/// 解包 zip / 7z 到 `dest`。
///
/// - `password` / `password_len`：UTF-8 口令；长度 0 = 不给口令。
/// - `include` / `include_len`：只解的扩展名，UTF-8、`\n` 分隔、小写带点（`.png\n.jpg`）；
///   长度 0 = 全解。
/// - `max_total_bytes` / `max_entries`：按实际写出量强制的上限，0 = 不限。
/// - `cancel`：可空的取消标志（与 `ffc_hash_cancel` 同一种），每个条目、每块拷贝前查一次。
/// - 成功时 `out_files` / `out_bytes` 写解出的文件数与字节数。
///
/// 返回 OK，或 [archive_status] / [status] 的负数码。失败时已写出的文件不回滚。
///
/// # Safety
/// 各指针按长度可读；`cancel` 非空时指向 4 字节对齐、调用期间有效的 `u32`；出参可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_archive_extract(
    path: *const u8,
    path_len: usize,
    dest: *const u8,
    dest_len: usize,
    password: *const u8,
    password_len: usize,
    include: *const u8,
    include_len: usize,
    max_total_bytes: u64,
    max_entries: u64,
    cancel: *const u32,
    out_files: *mut u64,
    out_bytes: *mut u64,
) -> i32 {
    guard(|| {
        if out_files.is_null() || out_bytes.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (path, dest) = match (utf8_arg(path, path_len), utf8_arg(dest, dest_len)) {
            (Ok(p), Ok(d)) => (p, d),
            (Err(s), _) | (_, Err(s)) => return s,
        };
        if path.is_empty() || dest.is_empty() {
            return status::INVALID_ARGUMENT;
        }
        let password = if password_len == 0 {
            None
        } else {
            match utf8_arg(password, password_len) {
                Ok(p) => Some(p),
                Err(s) => return s,
            }
        };
        let include = match utf8_arg(include, include_len) {
            Ok(s) => s,
            Err(s) => return s,
        };
        let opts = ExtractOptions {
            password,
            include_extensions: include
                .split('\n')
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect(),
            max_total_bytes,
            max_entries,
            cancel: cancel_flag(cancel),
        };
        match extract(Path::new(path), Path::new(dest), &opts) {
            Ok(stats) => {
                *out_files = stats.files;
                *out_bytes = stats.bytes;
                status::OK
            }
            Err(s) => s,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWORD: &str = "fushi-pw";

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/fushi_compute/test/fixtures/archive")
            .join(name)
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ffc_archive_{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn opts(password: Option<&str>) -> ExtractOptions<'_> {
        ExtractOptions {
            password,
            include_extensions: Vec::new(),
            max_total_bytes: 0,
            max_entries: 0,
            cancel: None,
        }
    }

    fn assert_pages(dir: &Path) {
        for page in ["001.png", "002.png", "003.png"] {
            let bytes = fs::read(dir.join("卷1").join(page)).unwrap();
            assert!(bytes.starts_with(b"\x89PNG"), "{page} 不是 PNG");
        }
        let text = fs::read_to_string(dir.join("卷1").join("读我.txt")).unwrap();
        assert!(text.starts_with("パスワード保護テスト"));
    }

    #[test]
    fn probe_reports_format_and_encryption() {
        let cases = [
            ("plain.zip", format::ZIP, encryption::NONE, 4),
            ("aes256.zip", format::ZIP, encryption::ENTRIES, 4),
            ("zipcrypto.zip", format::ZIP, encryption::ENTRIES, 4),
            ("plain.7z", format::SEVEN_Z, encryption::NONE, 4),
            (
                "content_encrypted.7z",
                format::SEVEN_Z,
                encryption::ENTRIES,
                4,
            ),
            (
                "header_encrypted.7z",
                format::SEVEN_Z,
                encryption::HEADERS,
                0,
            ),
        ];
        for (name, fmt, enc, count) in cases {
            let info = probe(&fixture(name)).unwrap();
            assert_eq!(info.format, fmt, "{name}");
            assert_eq!(info.encryption, enc, "{name}");
            assert_eq!(info.entry_count, count, "{name}");
        }
    }

    /// 把夹具按字节切成 `name.001`、`.002`…（7-Zip「分卷」的切法），返回各卷路径。
    fn split_fixture(name: &str, dir: &Path, parts: usize) -> Vec<PathBuf> {
        let bytes = fs::read(fixture(name)).unwrap();
        let chunk = bytes.len().div_ceil(parts);
        bytes
            .chunks(chunk)
            .enumerate()
            .map(|(i, part)| {
                let path = dir.join(format!("{name}.{:03}", i + 1));
                fs::write(&path, part).unwrap();
                path
            })
            .collect()
    }

    #[test]
    fn split_volumes_probe_and_extract_like_the_whole_archive() {
        for name in [
            "plain.7z",
            "plain.zip",
            "content_encrypted.7z",
            "header_encrypted.7z",
            "aes256.zip",
        ] {
            let src = temp_dir("split_src");
            let volumes = split_fixture(name, &src, 3);
            let whole = probe(&fixture(name)).unwrap();
            let split = probe(&volumes[0]).unwrap();
            assert_eq!(split.format, whole.format, "{name}");
            assert_eq!(split.encryption, whole.encryption, "{name}");
            assert_eq!(split.entry_count, whole.entry_count, "{name}");
            // 指纹按拼接后的流算：分卷与整包是同一个包，记住的口令通用。
            assert_eq!(split.fingerprint, whole.fingerprint, "{name}");
            let dir = temp_dir("split_out");
            let password = (whole.encryption != encryption::NONE).then_some(PASSWORD);
            let stats = extract(&volumes[0], &dir, &opts(password)).unwrap();
            assert_eq!(stats.files, 4, "{name}");
            assert_pages(&dir);
            fs::remove_dir_all(dir).ok();
            fs::remove_dir_all(src).ok();
        }
    }

    #[test]
    fn split_volumes_need_first_volume_and_all_parts() {
        for name in ["plain.7z", "header_encrypted.7z", "plain.zip"] {
            let src = temp_dir("split_missing");
            let volumes = split_fixture(name, &src, 3);
            let dir = temp_dir("split_missing_out");
            assert_eq!(
                probe(&volumes[1]).map(|_| ()),
                Err(archive_status::MISSING_VOLUME),
                "{name} 给了第二卷"
            );
            assert_eq!(
                extract(&volumes[1], &dir, &opts(None)).map(|_| ()),
                Err(archive_status::MISSING_VOLUME),
                "{name} 给了第二卷"
            );
            fs::remove_file(&volumes[2]).unwrap();
            assert_eq!(
                probe(&volumes[0]).map(|_| ()),
                Err(archive_status::MISSING_VOLUME),
                "{name} 缺最后一卷"
            );
            assert_eq!(
                extract(&volumes[0], &dir, &opts(Some(PASSWORD))).map(|_| ()),
                Err(archive_status::MISSING_VOLUME),
                "{name} 缺最后一卷"
            );
            fs::remove_dir_all(dir).ok();
            fs::remove_dir_all(src).ok();
        }
    }

    #[test]
    fn volume_names_need_an_archive_extension_before_the_number() {
        assert_eq!(
            volume_number(Path::new("a/book.7z.001")),
            Some(("book.7z".into(), 3, 1))
        );
        assert_eq!(
            volume_number(Path::new("book.zip.0002")),
            Some(("book.zip".into(), 4, 2))
        );
        assert_eq!(volume_number(Path::new("book.001")), None);
        assert_eq!(volume_number(Path::new("book.7z.01")), None);
        assert_eq!(volume_number(Path::new("book.7z")), None);
    }

    #[test]
    fn fingerprint_is_stable_and_distinguishes_files() {
        let a = probe(&fixture("aes256.zip")).unwrap().fingerprint;
        assert_eq!(a, probe(&fixture("aes256.zip")).unwrap().fingerprint);
        assert_ne!(a, probe(&fixture("zipcrypto.zip")).unwrap().fingerprint);
    }

    #[test]
    fn plain_archives_extract_without_password() {
        for name in ["plain.zip", "plain.7z"] {
            let dir = temp_dir("plain");
            let stats = extract(&fixture(name), &dir, &opts(None)).unwrap();
            assert_eq!(stats.files, 4, "{name}");
            assert_pages(&dir);
            fs::remove_dir_all(dir).ok();
        }
    }

    #[test]
    fn encrypted_archives_need_password_then_reject_wrong_then_accept_right() {
        for name in [
            "aes256.zip",
            "zipcrypto.zip",
            "content_encrypted.7z",
            "header_encrypted.7z",
        ] {
            let dir = temp_dir("enc");
            assert_eq!(
                extract(&fixture(name), &dir, &opts(None)),
                Err(archive_status::PASSWORD_REQUIRED),
                "{name} 无口令"
            );
            let wrong = temp_dir("wrong");
            assert_eq!(
                extract(&fixture(name), &wrong, &opts(Some("not-it"))),
                Err(archive_status::WRONG_PASSWORD),
                "{name} 错口令"
            );
            let stats = extract(&fixture(name), &dir, &opts(Some(PASSWORD))).unwrap();
            assert_eq!(stats.files, 4, "{name}");
            assert_pages(&dir);
            fs::remove_dir_all(dir).ok();
            fs::remove_dir_all(wrong).ok();
        }
    }

    #[test]
    fn include_filter_and_limits() {
        let dir = temp_dir("filter");
        let mut o = opts(Some(PASSWORD));
        o.include_extensions = vec![".png".into()];
        let stats = extract(&fixture("content_encrypted.7z"), &dir, &o).unwrap();
        assert_eq!(stats.files, 3);
        assert!(!dir.join("卷1").join("读我.txt").exists());
        fs::remove_dir_all(&dir).ok();

        let dir = temp_dir("limit");
        let mut o = opts(Some(PASSWORD));
        o.max_entries = 2;
        assert_eq!(
            extract(&fixture("aes256.zip"), &dir, &o),
            Err(archive_status::TOO_LARGE)
        );
        let mut o = opts(None);
        o.max_total_bytes = 10;
        assert_eq!(
            extract(&fixture("plain.7z"), &dir, &o),
            Err(archive_status::TOO_LARGE)
        );
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn cancel_flag_stops_extraction() {
        let flag = AtomicU32::new(1);
        let dir = temp_dir("cancel");
        let mut o = opts(None);
        o.cancel = Some(&flag);
        assert_eq!(
            extract(&fixture("plain.zip"), &dir, &o),
            Err(status::CANCELLED)
        );
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn unsafe_entry_paths_are_rejected_before_writing() {
        let dir = temp_dir("slip");
        let archive = dir.join("slip.zip");
        {
            let mut w = zip::ZipWriter::new(File::create(&archive).unwrap());
            let o = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored);
            w.start_file("ok.txt", o).unwrap();
            w.write_all(b"ok").unwrap();
            w.start_file("../evil.txt", o).unwrap();
            w.write_all(b"evil").unwrap();
            w.finish().unwrap();
        }
        let out = dir.join("out");
        assert_eq!(
            extract(&archive, &out, &opts(None)),
            Err(archive_status::UNSAFE_ENTRY)
        );
        assert!(!out.join("ok.txt").exists());
        assert!(!dir.join("evil.txt").exists());
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn safe_relative_path_rules() {
        assert_eq!(
            safe_relative_path("a/b.png"),
            Some(Some(PathBuf::from("a").join("b.png")))
        );
        assert_eq!(
            safe_relative_path("a\\.\\b.png"),
            Some(Some(PathBuf::from("a").join("b.png")))
        );
        assert_eq!(safe_relative_path("dir/"), Some(Some(PathBuf::from("dir"))));
        assert_eq!(safe_relative_path("./"), Some(None));
        assert_eq!(safe_relative_path("../x"), None);
        assert_eq!(safe_relative_path("a/../../x"), None);
        assert_eq!(safe_relative_path("/etc/passwd"), None);
        assert_eq!(safe_relative_path("C:/x"), None);
        assert_eq!(safe_relative_path("a.txt:stream"), None);
    }

    #[test]
    fn non_archives_are_unknown_and_unsupported() {
        let dir = temp_dir("unknown");
        let path = dir.join("not.zip");
        fs::write(&path, b"hello, not an archive").unwrap();
        assert_eq!(probe(&path).unwrap().format, format::UNKNOWN);
        assert_eq!(
            extract(&path, &dir.join("out"), &opts(None)),
            Err(archive_status::UNSUPPORTED)
        );
        let rar = dir.join("x.rar");
        fs::write(&rar, b"Rar!\x1A\x07\x01\x00rest").unwrap();
        assert_eq!(probe(&rar).unwrap().format, format::RAR);
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn ffi_probe_and_extract_roundtrip() {
        let path = fixture("header_encrypted.7z");
        let path_s = path.to_str().unwrap();
        let (mut fmt, mut enc, mut count, mut size) = (0i32, 0i32, 0u64, 0u64);
        let mut fp = [0u8; 32];
        let rc = unsafe {
            ffc_archive_probe(
                path_s.as_ptr(),
                path_s.len(),
                &mut fmt,
                &mut enc,
                &mut count,
                &mut size,
                fp.as_mut_ptr(),
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!((fmt, enc), (format::SEVEN_Z, encryption::HEADERS));

        let dir = temp_dir("ffi");
        let dest = dir.to_str().unwrap();
        let (mut files, mut bytes) = (0u64, 0u64);
        let run = |pw: &str, files: &mut u64, bytes: &mut u64| unsafe {
            ffc_archive_extract(
                path_s.as_ptr(),
                path_s.len(),
                dest.as_ptr(),
                dest.len(),
                pw.as_ptr(),
                pw.len(),
                std::ptr::null(),
                0,
                0,
                0,
                std::ptr::null(),
                files,
                bytes,
            )
        };
        assert_eq!(
            run("", &mut files, &mut bytes),
            archive_status::PASSWORD_REQUIRED
        );
        assert_eq!(
            run("nope", &mut files, &mut bytes),
            archive_status::WRONG_PASSWORD
        );
        assert_eq!(run(PASSWORD, &mut files, &mut bytes), status::OK);
        assert_eq!(files, 4);
        assert_pages(&dir);
        fs::remove_dir_all(dir).ok();
    }
}
