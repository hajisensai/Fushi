//! 云同步「防扫盘」混淆（`fushi/lib/src/sync/sync_obfuscator.dart` 的字节变换）。
//!
//! 不是加密：固定 keystream = SHA-256("hibiki")（32 字节）循环 XOR，第 `i` 个正文字节
//! XOR `keystream[i % 32]`，`i` 是正文（不含 8 字节魔数）里的全局偏移。混淆与还原是同一个
//! 操作。已同步到云端的文件靠这份 keystream 解开——**永远不能改**。

use std::fs::File;
use std::io::{self, Read, Write};
use std::path::PathBuf;

use sha2::{Digest, Sha256};

use crate::{guard, status};

/// 混淆产物的 8 字节魔数（`HBKOBF` + 版本 `0x01` + 保留 `0x00`），与 Dart
/// `SyncObfuscator.magicHeader` 同值，**永远不能改**。
pub const MAGIC_HEADER: [u8; 8] = [0x48, 0x42, 0x4B, 0x4F, 0x42, 0x46, 0x01, 0x00];

/// 文件读写失败（打不开 / 读写出错）。
pub const SYNC_IO_ERROR: i32 = -30;

const FILE_CHUNK: usize = 1 << 20;

fn keystream() -> &'static [u8; 32] {
    static KEYSTREAM: std::sync::OnceLock<[u8; 32]> = std::sync::OnceLock::new();
    KEYSTREAM.get_or_init(|| Sha256::digest(b"hibiki").into())
}

/// 原地 XOR：`data[i] ^= keystream[(body_offset + i) % 32]`。
pub fn xor_in_place(data: &mut [u8], body_offset: u64) {
    let key = keystream();
    let phase = (body_offset % 32) as usize;
    let mut rotated = [0u8; 32];
    for (j, b) in rotated.iter_mut().enumerate() {
        *b = key[(phase + j) % 32];
    }
    // 定长 32 字节块：编译器能展开成整宽向量 XOR（逐字节 zip 切片时不会）。
    let mut chunks = data.chunks_exact_mut(32);
    for chunk in &mut chunks {
        let block: &mut [u8; 32] = chunk.try_into().expect("chunks_exact");
        for j in 0..32 {
            block[j] ^= rotated[j];
        }
    }
    for (b, k) in chunks.into_remainder().iter_mut().zip(&rotated) {
        *b ^= *k;
    }
}

/// 读满 [buf]（或到 EOF），返回读到的字节数。
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match r.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

/// 从 [input] 当前位置起逐块 XOR（正文偏移从 [offset] 起）写到 [out]，直到 EOF。
fn xor_copy(input: &mut impl Read, out: &mut impl Write, mut offset: u64) -> io::Result<()> {
    let mut buf = vec![0u8; FILE_CHUNK];
    loop {
        let n = read_full(input, &mut buf)?;
        if n == 0 {
            return Ok(());
        }
        xor_in_place(&mut buf[..n], offset);
        out.write_all(&buf[..n])?;
        offset += n as u64;
    }
}

/// 混淆整个文件：[dst] 写成 `MAGIC_HEADER + XOR(src)`（创建或截断，与 Dart
/// `File.openWrite()` 同语义）。
pub fn obfuscate_file(src: &std::path::Path, dst: &std::path::Path) -> io::Result<()> {
    let mut input = File::open(src)?;
    let mut out = File::create(dst)?;
    out.write_all(&MAGIC_HEADER)?;
    xor_copy(&mut input, &mut out, 0)?;
    out.flush()
}

/// 还原整个文件：[src] 以 [MAGIC_HEADER] 开头则去头后 XOR 写到 [dst]；否则（旧明文 /
/// 短于魔数）原样复制（混读向后兼容）。[dst] 创建或截断。
pub fn deobfuscate_file(src: &std::path::Path, dst: &std::path::Path) -> io::Result<()> {
    let mut input = File::open(src)?;
    let mut head = [0u8; MAGIC_HEADER.len()];
    let got = read_full(&mut input, &mut head)?;
    let mut out = File::create(dst)?;
    if got == MAGIC_HEADER.len() && head == MAGIC_HEADER {
        xor_copy(&mut input, &mut out, 0)?;
    } else {
        out.write_all(&head[..got])?;
        io::copy(&mut input, &mut out)?;
    }
    out.flush()
}

unsafe fn utf8_path(ptr: *const u8, len: usize) -> Option<PathBuf> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    std::str::from_utf8(std::slice::from_raw_parts(ptr, len))
        .ok()
        .map(PathBuf::from)
}

unsafe fn file_op(
    src: *const u8,
    src_len: usize,
    dst: *const u8,
    dst_len: usize,
    op: fn(&std::path::Path, &std::path::Path) -> io::Result<()>,
) -> i32 {
    guard(|| {
        let (Some(src), Some(dst)) = (utf8_path(src, src_len), utf8_path(dst, dst_len)) else {
            return status::INVALID_ARGUMENT;
        };
        match op(&src, &dst) {
            Ok(()) => status::OK,
            Err(_) => SYNC_IO_ERROR,
        }
    })
}

/// [obfuscate_file] 的 C ABI：路径是 UTF-8 字节（不含结尾 NUL）。
///
/// # Safety
/// `src` / `dst` 各至少 `*_len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_sync_obfuscate_file(
    src: *const u8,
    src_len: usize,
    dst: *const u8,
    dst_len: usize,
) -> i32 {
    file_op(src, src_len, dst, dst_len, obfuscate_file)
}

/// [deobfuscate_file] 的 C ABI：路径是 UTF-8 字节（不含结尾 NUL）。
///
/// # Safety
/// `src` / `dst` 各至少 `*_len` 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_sync_deobfuscate_file(
    src: *const u8,
    src_len: usize,
    dst: *const u8,
    dst_len: usize,
) -> i32 {
    file_op(src, src_len, dst, dst_len, deobfuscate_file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn position_bound_and_involutive() {
        let original: Vec<u8> = (0..100u32).map(|i| i as u8).collect();
        let mut whole = original.clone();
        xor_in_place(&mut whole, 0);
        let mut tail = original[37..].to_vec();
        xor_in_place(&mut tail, 37);
        assert_eq!(&whole[37..], &tail[..]);
        xor_in_place(&mut whole, 0);
        assert_eq!(whole, original);
    }

    #[test]
    fn file_roundtrip_and_plain_passthrough() {
        let dir = std::env::temp_dir().join(format!("ffc_sync_xor_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let plain: Vec<u8> = (0..(FILE_CHUNK * 2 + 77))
            .map(|i| (i * 131 + 17) as u8)
            .collect();
        let (a, b, c) = (dir.join("a"), dir.join("b"), dir.join("c"));
        std::fs::write(&a, &plain).unwrap();
        obfuscate_file(&a, &b).unwrap();
        let obf = std::fs::read(&b).unwrap();
        assert_eq!(&obf[..8], &MAGIC_HEADER);
        let mut expect = plain.clone();
        xor_in_place(&mut expect, 0);
        assert_eq!(&obf[8..], &expect[..]);
        deobfuscate_file(&b, &c).unwrap();
        assert_eq!(std::fs::read(&c).unwrap(), plain);
        // 无魔数 / 短于魔数：原样复制。
        for raw in [&plain[..], &plain[..3], &[][..]] {
            std::fs::write(&a, raw).unwrap();
            deobfuscate_file(&a, &c).unwrap();
            assert_eq!(std::fs::read(&c).unwrap(), raw);
        }
        assert!(deobfuscate_file(&dir.join("missing"), &c).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
