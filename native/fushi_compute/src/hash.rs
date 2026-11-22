//! `ffc_hash_*`：流式哈希（AniDB ED2K、SHA-256）与 CRC-32（zip / IEEE 802.3）。
//!
//! 形态：`new` 建上下文 → 任意次 `update(ptr, len)` → `finish` 写结果 → `free`。
//! 流式接口只做纯算术，读文件、取消、进度与「读的过程中文件被改」的判定留在 Dart 侧（调用方 isolate）；
//! 唯一例外是整文件一次算完的 `ffc_hash_*_file`（读盘也在这里，原因见 [hash_file]；可取消的
//! 那一个见 [ffc_hash_sha256_file_cancellable]）。原先的纯 Dart 实现（fushi_engine 的 `_Md4` / `AnidbEd2kAccumulator`、
//! fushi 的 `package:crypto` sha256）已删除；它们对确定性输入的输出冻结成
//! `packages/fushi_compute/test/ffi_hash_test.dart` 的回归向量（ED2K 红 / 蓝两种整块边界
//! 变体，见 https://wiki.anidb.net/Ed2k-hash）。
//!
//! 上下文指针只能被一个线程同时使用；`finish` 之后再 `update` / `finish` 返回
//! [INVALID_ARGUMENT](crate::status::INVALID_ARGUMENT)，`free` 恒可调。

use std::sync::atomic::{AtomicU32, Ordering};

use md4::{Digest, Md4};
use sha1::Sha1;
use sha2::Sha256;

use crate::{guard, status};

/// AniDB ED2K 块大小（9500 KiB）。
pub const ED2K_CHUNK_SIZE: usize = 9_728_000;

/// ED2K 增量状态：内存与文件大小无关。
pub struct Ed2kState {
    chunk: Md4,
    chunk_bytes: usize,
    /// 红变体：所有块哈希 + 末块（可能是空块）哈希的 MD4。
    red: Md4,
    /// 蓝变体：只有满块哈希的 MD4（整块倍数时才有意义）。
    blue: Md4,
    first: Option<[u8; 16]>,
    chunks: u64,
    finished: bool,
}

impl Ed2kState {
    pub fn new() -> Self {
        Self {
            chunk: Md4::new(),
            chunk_bytes: 0,
            red: Md4::new(),
            blue: Md4::new(),
            first: None,
            chunks: 0,
            finished: false,
        }
    }

    pub fn update(&mut self, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let take = bytes.len().min(ED2K_CHUNK_SIZE - self.chunk_bytes);
            self.chunk.update(&bytes[..take]);
            self.chunk_bytes += take;
            bytes = &bytes[take..];
            if self.chunk_bytes == ED2K_CHUNK_SIZE {
                let hash: [u8; 16] = std::mem::replace(&mut self.chunk, Md4::new())
                    .finalize()
                    .into();
                self.first.get_or_insert(hash);
                self.red.update(hash);
                self.blue.update(hash);
                self.chunks += 1;
                self.chunk_bytes = 0;
            }
        }
    }

    /// 返回（红，蓝）；蓝只在文件长度恰为块大小的非零整数倍时存在。
    pub fn finish(&mut self) -> ([u8; 16], Option<[u8; 16]>) {
        self.finished = true;
        let tail: [u8; 16] = std::mem::replace(&mut self.chunk, Md4::new())
            .finalize()
            .into();
        if self.chunks == 0 {
            return (tail, None);
        }
        let mut red = std::mem::replace(&mut self.red, Md4::new());
        red.update(tail);
        let red: [u8; 16] = red.finalize().into();
        if self.chunk_bytes != 0 {
            return (red, None);
        }
        let blue: [u8; 16] = if self.chunks == 1 {
            self.first.expect("one full chunk recorded")
        } else {
            std::mem::replace(&mut self.blue, Md4::new())
                .finalize()
                .into()
        };
        (red, Some(blue))
    }
}

impl Default for Ed2kState {
    fn default() -> Self {
        Self::new()
    }
}

/// SHA-256 增量状态。
pub struct Sha256State {
    inner: Sha256,
    finished: bool,
}

/// # Safety
/// `len > 0` 时 `data` 必须指向至少 `len` 个可读字节。
unsafe fn input<'a>(data: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        Some(&[])
    } else if data.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(data, len))
    }
}

/// 新建 ED2K 上下文；失败（panic）返回 NULL。用 [ffc_hash_ed2k_free] 释放。
#[no_mangle]
pub extern "C" fn ffc_hash_ed2k_new() -> *mut Ed2kState {
    std::panic::catch_unwind(|| Box::into_raw(Box::new(Ed2kState::new())))
        .unwrap_or(std::ptr::null_mut())
}

/// 追加 `len` 字节。
///
/// # Safety
/// `state` 来自 [ffc_hash_ed2k_new] 且未释放；`data` 至少 `len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_ed2k_update(
    state: *mut Ed2kState,
    data: *const u8,
    len: usize,
) -> i32 {
    guard(|| {
        let Some(state) = state.as_mut() else {
            return status::NULL_ARGUMENT;
        };
        let Some(bytes) = input(data, len) else {
            return status::NULL_ARGUMENT;
        };
        if state.finished {
            return status::INVALID_ARGUMENT;
        }
        state.update(bytes);
        status::OK
    })
}

/// 结束并写结果：`out[0..16]` = 红变体（AniDB 采用的那个），`out[16..32]` = 蓝变体；
/// `*out_has_alternative` = 1 表示蓝变体有效（长度恰为块大小的非零整数倍），否则 0、
/// `out[16..32]` 清零。
///
/// # Safety
/// `state` 同上；`out` 至少 32 字节可写；`out_has_alternative` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_ed2k_finish(
    state: *mut Ed2kState,
    out: *mut u8,
    out_has_alternative: *mut i32,
) -> i32 {
    guard(|| {
        let Some(state) = state.as_mut() else {
            return status::NULL_ARGUMENT;
        };
        if out.is_null() || out_has_alternative.is_null() {
            return status::NULL_ARGUMENT;
        }
        if state.finished {
            return status::INVALID_ARGUMENT;
        }
        let (red, blue) = state.finish();
        let out = std::slice::from_raw_parts_mut(out, 32);
        out[..16].copy_from_slice(&red);
        match blue {
            Some(blue) => {
                out[16..].copy_from_slice(&blue);
                *out_has_alternative = 1;
            }
            None => {
                out[16..].fill(0);
                *out_has_alternative = 0;
            }
        }
        status::OK
    })
}

/// 释放 ED2K 上下文；NULL 无操作。
///
/// # Safety
/// `state` 来自 [ffc_hash_ed2k_new] 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_ed2k_free(state: *mut Ed2kState) {
    if !state.is_null() {
        drop(Box::from_raw(state));
    }
}

/// 新建 SHA-256 上下文；失败（panic）返回 NULL。用 [ffc_hash_sha256_free] 释放。
#[no_mangle]
pub extern "C" fn ffc_hash_sha256_new() -> *mut Sha256State {
    std::panic::catch_unwind(|| {
        Box::into_raw(Box::new(Sha256State {
            inner: Sha256::new(),
            finished: false,
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// 追加 `len` 字节。
///
/// # Safety
/// `state` 来自 [ffc_hash_sha256_new] 且未释放；`data` 至少 `len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_sha256_update(
    state: *mut Sha256State,
    data: *const u8,
    len: usize,
) -> i32 {
    guard(|| {
        let Some(state) = state.as_mut() else {
            return status::NULL_ARGUMENT;
        };
        let Some(bytes) = input(data, len) else {
            return status::NULL_ARGUMENT;
        };
        if state.finished {
            return status::INVALID_ARGUMENT;
        }
        state.inner.update(bytes);
        status::OK
    })
}

/// 结束并把 32 字节摘要写进 `out`。
///
/// # Safety
/// `state` 同上；`out` 至少 32 字节可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_sha256_finish(state: *mut Sha256State, out: *mut u8) -> i32 {
    guard(|| {
        let Some(state) = state.as_mut() else {
            return status::NULL_ARGUMENT;
        };
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        if state.finished {
            return status::INVALID_ARGUMENT;
        }
        state.finished = true;
        let digest = std::mem::take(&mut state.inner).finalize();
        std::slice::from_raw_parts_mut(out, 32).copy_from_slice(&digest);
        status::OK
    })
}

/// 释放 SHA-256 上下文；NULL 无操作。
///
/// # Safety
/// `state` 来自 [ffc_hash_sha256_new] 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_sha256_free(state: *mut Sha256State) {
    if !state.is_null() {
        drop(Box::from_raw(state));
    }
}

/// 整文件哈希（`ffc_hash_*_file`）每次读盘的块大小。
const FILE_CHUNK: usize = 1 << 20;

/// 读盘 + 哈希整个文件的接口（`ffc_hash_sha256_file` / `ffc_hash_crc32_file`）为什么在这里读盘：
/// Dart 逐块 `RandomAccessFile.readIntoSync(buffer)` 时，VM 经 `Dart_TypedDataAcquireData` 持有目标
/// 数组，整段磁盘读期间该线程**不进 GC 安全点**；后台 isolate 与 UI isolate 同属一个 isolate group，
/// UI isolate 每次 GC 都得等这块读完，慢盘上单次能等一秒多（BUG-5088：后台视频指纹预热让整个界面
/// 掉帧 / 卡死）。整段放进一次非叶 FFI 调用，线程全程处于 native 态，GC 不必等它。
///
/// 路径是 UTF-8 字节（`path_len` 字节，不要求 NUL 结尾）。失败：空指针 →
/// [NULL_ARGUMENT](crate::status::NULL_ARGUMENT)；路径不是 UTF-8 →
/// [INVALID_ARGUMENT](crate::status::INVALID_ARGUMENT)；打不开 / 读失败 →
/// [IO_ERROR](crate::status::IO_ERROR)。读到的总字节数写进 `out_len`。
///
/// # Safety
/// `path` 至少 `path_len` 字节可读；`out_len` 可写。
unsafe fn hash_file(
    path: *const u8,
    path_len: usize,
    out_len: *mut u64,
    cancel: Option<&AtomicU32>,
    mut feed: impl FnMut(&[u8]),
) -> i32 {
    let Some(path) = input(path, path_len) else {
        return status::NULL_ARGUMENT;
    };
    if out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Ok(path) = std::str::from_utf8(path) else {
        return status::INVALID_ARGUMENT;
    };
    match read_chunks(std::path::Path::new(path), cancel, &mut feed) {
        Ok(Some(len)) => {
            *out_len = len;
            status::OK
        }
        Ok(None) => status::CANCELLED,
        Err(_) => status::IO_ERROR,
    }
}

/// 逐 [FILE_CHUNK] 读完整个文件喂给 `feed`，返回总字节数。每读一块之前查一次 `cancel`，
/// 已置位就立即关文件返回 `None`（取消的延迟最多一块的读 + 哈希）。
fn read_chunks(
    path: &std::path::Path,
    cancel: Option<&AtomicU32>,
    feed: &mut impl FnMut(&[u8]),
) -> std::io::Result<Option<u64>> {
    use std::io::Read;
    let cancelled = || cancel.is_some_and(|flag| flag.load(Ordering::Acquire) != 0);
    if cancelled() {
        return Ok(None);
    }
    let mut file = std::fs::File::open(path)?;
    let mut buf = vec![0u8; FILE_CHUNK];
    let mut total = 0u64;
    loop {
        if cancelled() {
            return Ok(None);
        }
        let n = match file.read(&mut buf) {
            Ok(0) => return Ok(Some(total)),
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        feed(&buf[..n]);
        total += n as u64;
    }
}

/// 把调用方给的取消标志指针看成原子量（NULL = 不可取消）。
///
/// # Safety
/// 非 NULL 时 `flag` 指向 4 字节对齐、调用期间一直有效的 `u32`。
unsafe fn cancel_flag<'a>(flag: *const u32) -> Option<&'a AtomicU32> {
    if flag.is_null() {
        None
    } else {
        // AtomicU32 与 u32 布局相同（标准库保证）。
        Some(&*(flag as *const AtomicU32))
    }
}

/// 置位取消标志（Release 存储；重复调用无害，NULL 无操作）。标志是调用方分配的一个
/// 4 字节对齐 `u32`、初值 0，传给 [ffc_hash_sha256_file_cancellable]；正在跑的那次调用
/// 在读下一块之前看到它，立即关文件返回 [CANCELLED](crate::status::CANCELLED)。
/// 可以从任何线程 / isolate 调——典型用法是 UI isolate 取消后台 isolate 里的整文件哈希。
///
/// # Safety
/// 非 NULL 时 `flag` 指向 4 字节对齐、仍有效的 `u32`。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_cancel(flag: *mut u32) {
    if let Some(flag) = cancel_flag(flag) {
        flag.store(1, Ordering::Release);
    }
}

/// 整个文件的 SHA-256（读盘也在这里，见 [hash_file]），32 字节摘要写进 `out`。
///
/// # Safety
/// 同 [hash_file]；`out` 至少 32 字节可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_sha256_file(
    path: *const u8,
    path_len: usize,
    out: *mut u8,
    out_len: *mut u64,
) -> i32 {
    ffc_hash_sha256_file_cancellable(path, path_len, std::ptr::null(), out, out_len)
}

/// 可取消的整文件 SHA-256：同 [ffc_hash_sha256_file]，另带一个取消标志 `cancel`（NULL =
/// 不可取消）。每读一块（[FILE_CHUNK]）之前查一次，被 [ffc_hash_cancel] 置位后立即关文件
/// 返回 [CANCELLED](crate::status::CANCELLED)，`out` / `out_len` 不写。互联 host 停机时
/// 用它打断正在算的几 GB 视频指纹，停机不必等整文件读完（拍板台 host-stop-fingerprint-cancel）。
///
/// # Safety
/// 同 [ffc_hash_sha256_file]；非 NULL 时 `cancel` 指向 4 字节对齐、调用期间一直有效的 `u32`。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_sha256_file_cancellable(
    path: *const u8,
    path_len: usize,
    cancel: *const u32,
    out: *mut u8,
    out_len: *mut u64,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let mut hasher = Sha256::new();
        let rc = hash_file(path, path_len, out_len, cancel_flag(cancel), |b| {
            hasher.update(b)
        });
        if rc == status::OK {
            std::slice::from_raw_parts_mut(out, 32).copy_from_slice(&hasher.finalize());
        }
        rc
    })
}

/// 整个文件的 CRC-32（IEEE，zip 用的那个；读盘也在这里，见 [hash_file]），写进 `out`。
///
/// # Safety
/// 同 [hash_file]；`out` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_crc32_file(
    path: *const u8,
    path_len: usize,
    out: *mut u32,
    out_len: *mut u64,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let mut hasher = crc32fast::Hasher::new();
        let rc = hash_file(path, path_len, out_len, None, |b| hasher.update(b));
        if rc == status::OK {
            *out = hasher.finalize();
        }
        rc
    })
}

/// CRC-32（IEEE，zip / PNG 用的那个）：在 `crc`（上一段的结果，首段传 0）之上续算
/// `len` 字节，返回新值。与 `package:archive` 的 `getCrc32(data, crc)` 同语义，可分段链式调用。
/// `data` 为 NULL 且 `len > 0` 时原样返回 `crc`（调用方保证不会出现）。
///
/// # Safety
/// `len > 0` 时 `data` 至少 `len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_crc32(crc: u32, data: *const u8, len: usize) -> u32 {
    let Some(bytes) = input(data, len) else {
        return crc;
    };
    let mut hasher = crc32fast::Hasher::new_with_initial(crc);
    hasher.update(bytes);
    hasher.finalize()
}

/// 打包字符串表：第 `i` 项是 `data[offsets[i]..offsets[i + 1]]`（`offsets` 共 `n + 1` 个）。
///
/// # Safety
/// `offsets` 至少 `n + 1` 个；`data` 覆盖 `offsets[n]` 字节。
unsafe fn packed<'a>(data: *const u8, offsets: *const u64, n: usize) -> Option<Vec<&'a [u8]>> {
    if offsets.is_null() {
        return None;
    }
    let offsets = std::slice::from_raw_parts(offsets, n + 1);
    let total = offsets[n] as usize;
    let all = input(data, total)?;
    let mut out = Vec::with_capacity(n);
    for w in offsets.windows(2) {
        let (a, b) = (w[0] as usize, w[1] as usize);
        if a > b || b > total {
            return None;
        }
        out.push(&all[a..b]);
    }
    Some(out)
}

/// 批量 RFC 9562 UUIDv5：第 `i` 个 = SHA-1(namespaces[16i..16i+16] ‖ name_i) 取前 16 字节，
/// 置版本 5 与 RFC 变体位，写进 `out[16i..16i+16]`。名字是调用方给的 UTF-8 字节。
///
/// # Safety
/// `namespaces` 至少 `16n` 字节；`names` / `offsets` 见 [packed]；`out` 至少 `16n` 字节可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_uuid_v5_batch(
    namespaces: *const u8,
    names: *const u8,
    offsets: *const u64,
    n: usize,
    out: *mut u8,
) -> i32 {
    guard(|| {
        if n == 0 {
            return status::OK;
        }
        if namespaces.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(items) = packed(names, offsets, n) else {
            return status::INVALID_ARGUMENT;
        };
        let ns = std::slice::from_raw_parts(namespaces, 16 * n);
        let out = std::slice::from_raw_parts_mut(out, 16 * n);
        for (i, name) in items.iter().enumerate() {
            let mut h = Sha1::new();
            h.update(&ns[16 * i..16 * i + 16]);
            h.update(name);
            let d = h.finalize();
            let b = &mut out[16 * i..16 * i + 16];
            b.copy_from_slice(&d[..16]);
            b[6] = (b[6] & 0x0f) | 0x50;
            b[8] = (b[8] & 0x3f) | 0x80;
        }
        status::OK
    })
}

/// 53 位确定性正整数：SHA-256 前 7 字节大端，取低 53 位，0 记作 1（Fushi SRS 的 `hash53`）。
pub fn hash53(bytes: &[u8]) -> u64 {
    let d = Sha256::digest(bytes);
    let mut v = 0u64;
    for &b in &d[..7] {
        v = (v << 8) | b as u64;
    }
    v &= (1u64 << 53) - 1;
    if v == 0 { 1 } else { v }
}

/// 批量 [hash53]：第 `i` 项写进 `out[i]`。
///
/// # Safety
/// `data` / `offsets` 见 [packed]；`out` 至少 `n` 个可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_hash53_batch(
    data: *const u8,
    offsets: *const u64,
    n: usize,
    out: *mut u64,
) -> i32 {
    guard(|| {
        if n == 0 {
            return status::OK;
        }
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(items) = packed(data, offsets, n) else {
            return status::INVALID_ARGUMENT;
        };
        let out = std::slice::from_raw_parts_mut(out, n);
        for (slot, item) in out.iter_mut().zip(items) {
            *slot = hash53(item);
        }
        status::OK
    })
}

/// 摘要是否至少有 `bits` 个前导零位。
fn leading_zero_bits(digest: &[u8], bits: u32) -> bool {
    let mut remaining = i64::from(bits);
    for &b in digest {
        if remaining <= 0 {
            return true;
        }
        if remaining >= 8 {
            if b != 0 {
                return false;
            }
            remaining -= 8;
        } else {
            return (b >> (8 - remaining)) == 0;
        }
    }
    remaining <= 0
}

fn pow_digest(prefix: &[u8], nonce: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(prefix);
    h.update(nonce);
    h.finalize().into()
}

/// 十进制写进 `buf` 尾部，返回那一段。
fn decimal(mut v: u64, buf: &mut [u8; 20]) -> &[u8] {
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    &buf[i..]
}

/// 工作量证明求解：从 0 起找最小的 nonce，使 SHA-256(prefix ‖ 十进制 ascii(nonce)) 至少有
/// `bits` 个前导零位，写进 `*out_nonce`。`bits > 64` 返回 INVALID_ARGUMENT（解不完）。
///
/// # Safety
/// `prefix` 至少 `len` 字节；`out_nonce` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_pow_solve(
    prefix: *const u8,
    len: usize,
    bits: u32,
    out_nonce: *mut u64,
) -> i32 {
    guard(|| {
        let Some(prefix) = input(prefix, len) else {
            return status::NULL_ARGUMENT;
        };
        if out_nonce.is_null() {
            return status::NULL_ARGUMENT;
        }
        if bits > 64 {
            return status::INVALID_ARGUMENT;
        }
        let mut base = Sha256::new();
        base.update(prefix);
        let mut digits = [0u8; 20];
        for nonce in 0u64.. {
            let mut h = base.clone();
            h.update(decimal(nonce, &mut digits));
            let d: [u8; 32] = h.finalize().into();
            if leading_zero_bits(&d, bits) {
                *out_nonce = nonce;
                return status::OK;
            }
        }
        status::INVALID_ARGUMENT
    })
}

/// 工作量证明校验：SHA-256(prefix ‖ nonce) 是否至少有 `bits` 个前导零位。
/// 返回 1 = 满足，0 = 不满足，负数 = 参数错误。nonce 的格式由调用方先校验。
///
/// # Safety
/// `prefix` / `nonce` 分别至少 `len` / `nonce_len` 字节。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_pow_check(
    prefix: *const u8,
    len: usize,
    nonce: *const u8,
    nonce_len: usize,
    bits: u32,
) -> i32 {
    guard(|| {
        let (Some(prefix), Some(nonce)) = (input(prefix, len), input(nonce, nonce_len)) else {
            return status::NULL_ARGUMENT;
        };
        i32::from(leading_zero_bits(&pow_digest(prefix, nonce), bits))
    })
}

/// 两段字节是否完全相同（长度不同即不同）：1 = 相同，0 = 不同，负数 = 参数错误。
///
/// # Safety
/// `a` / `b` 分别至少 `a_len` / `b_len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_hash_bytes_equal(
    a: *const u8,
    a_len: usize,
    b: *const u8,
    b_len: usize,
) -> i32 {
    guard(|| {
        let (Some(a), Some(b)) = (input(a, a_len), input(b, b_len)) else {
            return status::NULL_ARGUMENT;
        };
        i32::from(a == b)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn ed2k_zero(size: usize) -> (String, Option<String>) {
        let mut state = Ed2kState::new();
        let block = vec![0u8; 65_536];
        let mut left = size;
        while left > 0 {
            let n = left.min(block.len());
            state.update(&block[..n]);
            left -= n;
        }
        let (red, blue) = state.finish();
        (hex(&red), blue.map(|b| hex(&b)))
    }

    #[test]
    fn md4_vectors_below_one_chunk() {
        assert_eq!(ed2k_zero(0).0, "31d6cfe0d16ae931b73c59d7e0c089c0");
        let mut s = Ed2kState::new();
        for b in b"abc" {
            s.update(std::slice::from_ref(b));
        }
        assert_eq!(hex(&s.finish().0), "a448017aaf21d8525fc10ae87aa6729d");
    }

    #[test]
    fn anidb_published_boundary_vectors() {
        assert_eq!(
            ed2k_zero(ED2K_CHUNK_SIZE),
            (
                "fc21d9af828f92a8df64beac3357425d".into(),
                Some("d7def262a127cd79096a108e7a9fc138".into())
            )
        );
        assert_eq!(
            ed2k_zero(ED2K_CHUNK_SIZE * 2),
            (
                "114b21c63a74b6ca922291a11177dd5c".into(),
                Some("194ee9e4fa79b2ee9f8829284c466051".into())
            )
        );
        assert_eq!(ed2k_zero(ED2K_CHUNK_SIZE + 1).1, None);
    }

    #[test]
    fn uuid_v5_and_hash53_batches() {
        // RFC 9562 附录 A.4：DNS 命名空间 + "www.example.com"。
        let ns: [u8; 16] = [
            0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4,
            0x30, 0xc8,
        ];
        let name = b"www.example.com";
        let offsets = [0u64, name.len() as u64];
        let mut out = [0u8; 16];
        let st = unsafe {
            ffc_hash_uuid_v5_batch(
                ns.as_ptr(),
                name.as_ptr(),
                offsets.as_ptr(),
                1,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(st, status::OK);
        assert_eq!(hex(&out), "2ed6657de927568b95e12665a8aea6a2");
        // SHA-256("") = e3b0c44298fc1c…：前 7 字节 e3b0c44298fc1c 取低 53 位。
        assert_eq!(hash53(b""), 0x00e3_b0c4_4298_fc1c & ((1 << 53) - 1));
        let bad = [5u64, 1];
        let mut o = [0u64; 1];
        let st = unsafe { ffc_hash_hash53_batch(name.as_ptr(), bad.as_ptr(), 1, o.as_mut_ptr()) };
        assert_eq!(st, status::INVALID_ARGUMENT);
    }

    #[test]
    fn pow_solves_the_smallest_nonce() {
        let prefix = b"fip1|test|";
        let mut nonce = 0u64;
        let st = unsafe { ffc_hash_pow_solve(prefix.as_ptr(), prefix.len(), 8, &mut nonce) };
        assert_eq!(st, status::OK);
        let mut digits = [0u8; 20];
        for smaller in 0..nonce {
            assert!(!leading_zero_bits(
                &pow_digest(prefix, decimal(smaller, &mut digits)),
                8
            ));
        }
        let text = nonce.to_string();
        let ok = unsafe {
            ffc_hash_pow_check(prefix.as_ptr(), prefix.len(), text.as_ptr(), text.len(), 8)
        };
        assert_eq!(ok, 1);
        assert!(leading_zero_bits(&[0xff], 0));
        assert!(!leading_zero_bits(&[0x7f], 2));
        assert!(leading_zero_bits(&[0x3f], 2));
    }

    #[test]
    fn crc32_matches_zip_vectors_and_chains() {
        unsafe {
            assert_eq!(ffc_hash_crc32(0, std::ptr::null(), 0), 0);
            assert_eq!(ffc_hash_crc32(0, b"123456789".as_ptr(), 9), 0xcbf4_3926);
            let first = ffc_hash_crc32(0, b"1234".as_ptr(), 4);
            assert_eq!(ffc_hash_crc32(first, b"56789".as_ptr(), 5), 0xcbf4_3926);
        }
    }

    #[test]
    fn ffi_rejects_reuse_after_finish_and_nulls() {
        unsafe {
            let st = ffc_hash_ed2k_new();
            assert_eq!(ffc_hash_ed2k_update(st, b"abc".as_ptr(), 3), status::OK);
            let mut out = [0u8; 32];
            let mut alt = -1;
            assert_eq!(
                ffc_hash_ed2k_finish(st, out.as_mut_ptr(), &mut alt),
                status::OK
            );
            assert_eq!(alt, 0);
            assert_eq!(hex(&out[..16]), "a448017aaf21d8525fc10ae87aa6729d");
            assert_eq!(
                ffc_hash_ed2k_update(st, b"a".as_ptr(), 1),
                status::INVALID_ARGUMENT
            );
            assert_eq!(
                ffc_hash_ed2k_update(st, std::ptr::null(), 1),
                status::NULL_ARGUMENT
            );
            ffc_hash_ed2k_free(st);
            ffc_hash_ed2k_free(std::ptr::null_mut());

            let sh = ffc_hash_sha256_new();
            assert_eq!(ffc_hash_sha256_update(sh, b"abc".as_ptr(), 3), status::OK);
            let mut digest = [0u8; 32];
            assert_eq!(ffc_hash_sha256_finish(sh, digest.as_mut_ptr()), status::OK);
            assert_eq!(
                hex(&digest),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            );
            assert_eq!(
                ffc_hash_sha256_finish(sh, digest.as_mut_ptr()),
                status::INVALID_ARGUMENT
            );
            ffc_hash_sha256_free(sh);
        }
    }
    /// 整文件 SHA-256 / CRC-32：与内存里同一份字节的结果一致（跨 1 MiB 块边界、空文件），读到的字节数如实回报；
    /// 打不开的路径回 IO_ERROR、非 UTF-8 回 INVALID_ARGUMENT、空指针回 NULL_ARGUMENT。
    #[test]
    fn whole_file_hashes_match_in_memory_digests_and_report_errors() {
        let dir = std::env::temp_dir().join(format!("ffc_sha256_file_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for size in [0usize, 1, FILE_CHUNK, FILE_CHUNK * 2 + 7] {
            let bytes: Vec<u8> = (0..size).map(|i| (i * 31 % 251) as u8).collect();
            let path = dir.join(format!("f{size}.bin"));
            std::fs::write(&path, &bytes).unwrap();
            let p = path.to_str().unwrap().as_bytes();
            let mut out = [0u8; 32];
            let mut len = u64::MAX;
            let rc =
                unsafe { ffc_hash_sha256_file(p.as_ptr(), p.len(), out.as_mut_ptr(), &mut len) };
            assert_eq!(rc, status::OK, "size {size}");
            assert_eq!(len, size as u64);
            let expected: [u8; 32] = Sha256::digest(&bytes).into();
            assert_eq!(hex(&out), hex(&expected), "size {size}");
            let (mut crc, mut crc_len) = (0u32, u64::MAX);
            let rc = unsafe { ffc_hash_crc32_file(p.as_ptr(), p.len(), &mut crc, &mut crc_len) };
            assert_eq!(rc, status::OK, "crc size {size}");
            assert_eq!(crc_len, size as u64);
            assert_eq!(crc, crc32fast::hash(&bytes), "crc size {size}");
        }
        let missing = dir.join("missing.bin");
        let p = missing.to_str().unwrap().as_bytes();
        let (mut out, mut len) = ([0u8; 32], 0u64);
        assert_eq!(
            unsafe { ffc_hash_sha256_file(p.as_ptr(), p.len(), out.as_mut_ptr(), &mut len) },
            status::IO_ERROR
        );
        let bad = [0xffu8, 0xfe];
        assert_eq!(
            unsafe { ffc_hash_sha256_file(bad.as_ptr(), bad.len(), out.as_mut_ptr(), &mut len) },
            status::INVALID_ARGUMENT
        );
        assert_eq!(
            unsafe { ffc_hash_sha256_file(p.as_ptr(), p.len(), std::ptr::null_mut(), &mut len) },
            status::NULL_ARGUMENT
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 可取消的整文件 SHA-256：标志没置位时与不可取消的结果一致；调用前已置位 → 不开文件、
    /// 回 CANCELLED 且不写输出；读到一半置位 → 下一块之前停下（不读完整个文件）。
    #[test]
    fn cancellable_whole_file_sha256_stops_between_chunks() {
        let dir = std::env::temp_dir().join(format!("ffc_sha256_cancel_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let size = FILE_CHUNK * 3 + 5;
        let bytes: Vec<u8> = (0..size).map(|i| (i * 7 % 253) as u8).collect();
        let path = dir.join("big.bin");
        std::fs::write(&path, &bytes).unwrap();
        let p = path.to_str().unwrap().as_bytes();

        let mut flag = 0u32;
        let (mut out, mut len) = ([0u8; 32], 0u64);
        let rc = unsafe {
            ffc_hash_sha256_file_cancellable(p.as_ptr(), p.len(), &flag, out.as_mut_ptr(), &mut len)
        };
        assert_eq!(rc, status::OK);
        assert_eq!(len, size as u64);
        let expected: [u8; 32] = Sha256::digest(&bytes).into();
        assert_eq!(hex(&out), hex(&expected));

        unsafe { ffc_hash_cancel(&mut flag) };
        unsafe { ffc_hash_cancel(&mut flag) };
        unsafe { ffc_hash_cancel(std::ptr::null_mut()) };
        let (mut out, mut len) = ([0u8; 32], 7u64);
        let rc = unsafe {
            ffc_hash_sha256_file_cancellable(p.as_ptr(), p.len(), &flag, out.as_mut_ptr(), &mut len)
        };
        assert_eq!(rc, status::CANCELLED);
        assert_eq!(len, 7, "取消时不写 out_len");
        assert_eq!(out, [0u8; 32], "取消时不写摘要");

        // 读完第一块后置位：第二块之前停下，只喂进去一块。
        let live = AtomicU32::new(0);
        let mut fed = 0usize;
        let result = read_chunks(&path, Some(&live), &mut |b: &[u8]| {
            fed += b.len();
            live.store(1, Ordering::Release);
        })
        .unwrap();
        assert_eq!(result, None);
        assert_eq!(fed, FILE_CHUNK);
        std::fs::remove_dir_all(&dir).ok();
    }
}
