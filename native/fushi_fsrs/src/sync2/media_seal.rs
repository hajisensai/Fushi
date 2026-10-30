//! 加密位置上媒体的封装格式（审查 S-9）：分块流式 AEAD，内存只占一两个块，大文件不整份读进内存。
//!
//! 新格式（`FSM2`）：
//! ```text
//! 头 27 字节 = "FSM2" | u32 块大小（小端） | 19 字节随机 nonce 前缀
//! 之后每块 = XChaCha20-Poly1305(明文块)（密文 + 16 字节 tag）
//!   块 i 的 nonce = 前缀(19) | u32 i（大端） | 末块标记（末块 1，否则 0）
//!   AAD = 头 | 调用方的 AAD（内容哈希 / 文件名）
//! ```
//! 每块明文正好 [MEDIA_CHUNK] 字节，末块**严格更短**（明文长度是块大小整数倍时末块为空）：读者读到不满一整块的
//! 就是末块。截断在块边界上 → 读到的「末块」带的是非末块的 tag，解密失败；块被挪位 / 换序 → nonce 计数对不上，
//! 失败；换头（改块大小 / 前缀）→ AAD 不同，失败。即 STREAM 构造（Hoang–Reyhanitabar–Rogaway–Vizár 2015）。
//!
//! 存储位置上只有这一种格式（协议 2，2026-10-30 断代）。S-9 之前的整份格式（[CollectionKey::seal]：`24 字节 nonce |
//! 整份密文 + tag`，AAD 是文件名）只出现在 v1 位置的按名字目录里，只有一次性迁移（Dart
//! `srs_location_migration.dart`）经 [open_v1] 读它，读出的明文按内容哈希重新封成本格式；正常收发路径不认它。

use std::fs::File;
use std::io::{self, Read, Write};
use std::path::Path;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use sha2::{Digest, Sha256};

use super::keys::{CollectionKey, NONCE_LEN, TAG_LEN};

pub const MEDIA_MAGIC: &[u8; 4] = b"FSM2";
/// 明文块大小：64 KiB。tag 开销 16 / 65536 ≈ 0.02%。
pub const MEDIA_CHUNK: usize = 64 * 1024;
const PREFIX_LEN: usize = 19;
const HEADER_LEN: usize = 4 + 4 + PREFIX_LEN;
/// 读者接受的块大小上限（防恶意头让读者一次分配巨块）。
const MAX_CHUNK: usize = 16 * 1024 * 1024;

/// 封 / 解的结果：明文字节数与明文 sha256（内容寻址：调用方据此核对内容，不必再把文件读一遍）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sealed {
    pub plain_len: u64,
    pub sha256: [u8; 32],
}

fn nonce(prefix: &[u8; PREFIX_LEN], i: u32, last: bool) -> XNonce {
    let mut n = [0u8; NONCE_LEN];
    n[..PREFIX_LEN].copy_from_slice(prefix);
    n[PREFIX_LEN..PREFIX_LEN + 4].copy_from_slice(&i.to_be_bytes());
    n[NONCE_LEN - 1] = u8::from(last);
    XNonce::from(n)
}

/// 读满 [buf]（或读到流尾）；返回读到的字节数。
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut at = 0;
    while at < buf.len() {
        match r.read(&mut buf[at..]) {
            Ok(0) => break,
            Ok(n) => at += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(at)
}

/// 把 [r] 的明文流式封成新格式写进 [w]。
pub fn seal_stream(key: &CollectionKey, r: &mut impl Read, w: &mut impl Write, aad: &[u8]) -> Result<Sealed, String> {
    let mut prefix = [0u8; PREFIX_LEN];
    getrandom::fill(&mut prefix).map_err(|e| e.to_string())?;
    let mut ad = Vec::with_capacity(HEADER_LEN + aad.len());
    ad.extend_from_slice(MEDIA_MAGIC);
    ad.extend_from_slice(&(MEDIA_CHUNK as u32).to_le_bytes());
    ad.extend_from_slice(&prefix);
    w.write_all(&ad).map_err(|e| e.to_string())?;
    ad.extend_from_slice(aad);
    let cipher = XChaCha20Poly1305::new((&key.0).into());
    let mut sha = Sha256::new();
    let mut total = 0u64;
    let mut buf = vec![0u8; MEDIA_CHUNK];
    let mut i = 0u32;
    loop {
        let n = read_full(r, &mut buf).map_err(|e| e.to_string())?;
        let last = n < MEDIA_CHUNK;
        sha.update(&buf[..n]);
        total += n as u64;
        let ct = cipher
            .encrypt(&nonce(&prefix, i, last), Payload { msg: &buf[..n], aad: &ad })
            .map_err(|_| "media seal failed".to_owned())?;
        w.write_all(&ct).map_err(|e| e.to_string())?;
        if last {
            break;
        }
        i = i.checked_add(1).ok_or("media too large")?;
    }
    w.flush().map_err(|e| e.to_string())?;
    Ok(Sealed { plain_len: total, sha256: sha.finalize().into() })
}

/// 解不开的原因。媒体对账（Dart `srsSyncMedia`）据此决定要不要怪位置上那份对象：只有「对象本身坏了」才记可疑、
/// 让持有原文的设备覆盖重传；密钥证明不了是对的就不怪对象（否则口令 / 密钥出问题的读者每轮记可疑、持有者每轮覆盖，
/// 来回不停），本机读写出错更不该怪对象。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenError {
    /// 第一块就认证不过：密钥不对，或不是按这个名字（AAD）封的。AEAD 分不出这两种，也分不出
    /// 第一块被改坏——都证明不了密钥是对的。
    Unauthenticated,
    /// 前面的块已经认证通过（密钥与名字都对），后面的块认证不过 / 截断 / 被挪位，或者没有魔数 / 头的块大小不合法 /
    /// 短到连头都不够：位置上的对象（或这次下载）坏了。
    Corrupt,
    /// 本机读写失败（打不开源文件、写不了目标）。
    Io(String),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::Unauthenticated => f.write_str("media decrypt failed"),
            OpenError::Corrupt => f.write_str("media envelope corrupt"),
            OpenError::Io(e) => f.write_str(e),
        }
    }
}

impl From<String> for OpenError {
    fn from(e: String) -> OpenError {
        OpenError::Io(e)
    }
}

impl From<OpenError> for String {
    fn from(e: OpenError) -> String {
        e.to_string()
    }
}

/// 新格式流式解封：[head] 是已经读出的头，其余从 [r] 读。失败时 [w] 里可能已有部分明文，调用方丢弃。
fn open_chunked(
    key: &CollectionKey,
    head: &[u8; HEADER_LEN],
    r: &mut impl Read,
    w: &mut impl Write,
    aad: &[u8],
) -> Result<Sealed, OpenError> {
    let chunk = u32::from_le_bytes(head[4..8].try_into().expect("4 bytes")) as usize;
    if chunk == 0 || chunk > MAX_CHUNK {
        return Err(OpenError::Corrupt);
    }
    let prefix: [u8; PREFIX_LEN] = head[8..].try_into().expect("19 bytes");
    let mut ad = head.to_vec();
    ad.extend_from_slice(aad);
    let cipher = XChaCha20Poly1305::new((&key.0).into());
    let mut sha = Sha256::new();
    let mut total = 0u64;
    let mut buf = vec![0u8; chunk + TAG_LEN];
    let mut i = 0u32;
    loop {
        let n = read_full(r, &mut buf).map_err(|e| OpenError::Io(e.to_string()))?;
        let last = n < buf.len();
        let pt = cipher.decrypt(&nonce(&prefix, i, last), Payload { msg: &buf[..n], aad: &ad }).map_err(|_| {
            // 第一块：密钥 / 名字还没被证明是对的。之后：前面的块已证明了，坏的是对象。
            if i == 0 { OpenError::Unauthenticated } else { OpenError::Corrupt }
        })?;
        sha.update(&pt);
        total += pt.len() as u64;
        w.write_all(&pt).map_err(|e| OpenError::Io(e.to_string()))?;
        if last {
            break;
        }
        i = i.checked_add(1).ok_or(OpenError::Corrupt)?;
    }
    w.flush().map_err(|e| OpenError::Io(e.to_string()))?;
    Ok(Sealed { plain_len: total, sha256: sha.finalize().into() })
}

/// 流式解封：边读边解边写 [w]。失败时 [w] 里可能已有部分明文，调用方丢弃。
pub fn open_stream(key: &CollectionKey, r: &mut impl Read, w: &mut impl Write, aad: &[u8]) -> Result<Sealed, OpenError> {
    let mut head = [0u8; HEADER_LEN];
    let n = read_full(r, &mut head).map_err(|e| OpenError::Io(e.to_string()))?;
    if n < HEADER_LEN || &head[..4] != MEDIA_MAGIC {
        return Err(OpenError::Corrupt);
    }
    open_chunked(key, &head, r, w, aad)
}

/// v1 位置上按名字存的整份封装（S-9 之前的 [CollectionKey::seal]）：只给一次性迁移用（见模块注释）。解不开为 None。
pub fn open_v1(key: &CollectionKey, sealed: &[u8], aad: &[u8]) -> Option<Vec<u8>> {
    key.open(sealed, aad)
}

/// 内存里封（小内容）。输出与 [seal_stream] 同格式。
pub fn seal_bytes(key: &CollectionKey, plain: &[u8], aad: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(HEADER_LEN + plain.len() + (plain.len() / MEDIA_CHUNK + 1) * TAG_LEN);
    seal_stream(key, &mut io::Cursor::new(plain), &mut out, aad)?;
    Ok(out)
}

/// 内存里解。
pub fn open_bytes(key: &CollectionKey, sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>, OpenError> {
    let mut out = Vec::new();
    open_stream(key, &mut io::Cursor::new(sealed), &mut out, aad)?;
    Ok(out)
}

/// 文件到文件地封：[src] 明文 → [dst] 新格式（先写同目录临时文件再改名，读者看不到半截）。
pub fn seal_file(key: &CollectionKey, src: &Path, dst: &Path, aad: &[u8]) -> Result<Sealed, String> {
    let file = File::open(src).map_err(|e| format!("open {}: {e}", src.display()))?;
    let mut r = io::BufReader::with_capacity(MEDIA_CHUNK, file);
    write_atomically(dst, |w| seal_stream(key, &mut r, w, aad))
}

/// 文件到文件地解：解不开不留下 [dst]，也不留临时文件。
pub fn open_file(key: &CollectionKey, src: &Path, dst: &Path, aad: &[u8]) -> Result<Sealed, OpenError> {
    let file = File::open(src).map_err(|e| OpenError::Io(format!("open {}: {e}", src.display())))?;
    let mut r = io::BufReader::with_capacity(MEDIA_CHUNK, file);
    write_atomically(dst, |w| open_stream(key, &mut r, w, aad))
}

/// 写 [dst] 同目录的临时文件 → 成功才改名到 [dst]；失败删掉临时文件。
fn write_atomically<E: From<String>>(
    dst: &Path,
    body: impl FnOnce(&mut TempOut) -> Result<Sealed, E>,
) -> Result<Sealed, E> {
    let mut rnd = [0u8; 6];
    getrandom::fill(&mut rnd).map_err(|e| e.to_string())?;
    let mut name = dst.file_name().ok_or_else(|| "bad destination".to_owned())?.to_os_string();
    name.push(format!(".part-{}", rnd.iter().map(|b| format!("{b:02x}")).collect::<String>()));
    let tmp = dst.with_file_name(name);
    let file = File::create(&tmp).map_err(|e| format!("create {}: {e}", tmp.display()))?;
    let mut out = TempOut(io::BufWriter::with_capacity(MEDIA_CHUNK, file));
    let done = body(&mut out).and_then(|s| {
        out.0.flush().map_err(|e| e.to_string())?;
        out.0.get_ref().sync_all().map_err(|e| e.to_string())?;
        Ok(s)
    });
    drop(out);
    let renamed = done.and_then(|s| {
        std::fs::rename(&tmp, dst).map(|_| s).map_err(|e| E::from(format!("rename to {}: {e}", dst.display())))
    });
    if renamed.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    renamed
}

/// 临时输出文件。
pub struct TempOut(io::BufWriter<File>);

impl Write for TempOut {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> CollectionKey {
        CollectionKey([7u8; 32])
    }

    #[test]
    fn round_trips_every_length_around_chunk_boundaries() {
        for len in [0, 1, MEDIA_CHUNK - 1, MEDIA_CHUNK, MEDIA_CHUNK + 1, 3 * MEDIA_CHUNK, 3 * MEDIA_CHUNK + 17] {
            let plain: Vec<u8> = (0..len).map(|i| (i * 31 % 251) as u8).collect();
            let sealed = seal_bytes(&key(), &plain, b"aad").unwrap();
            assert_eq!(&sealed[..4], MEDIA_MAGIC);
            assert_eq!(sealed.len(), HEADER_LEN + len + (len / MEDIA_CHUNK + 1) * TAG_LEN, "len {len}");
            assert_eq!(open_bytes(&key(), &sealed, b"aad").unwrap(), plain, "len {len}");
        }
    }

    #[test]
    fn rejects_truncation_reordering_header_edits_wrong_aad_and_wrong_key() {
        let plain: Vec<u8> = (0..3 * MEDIA_CHUNK + 5).map(|i| i as u8).collect();
        let sealed = seal_bytes(&key(), &plain, b"aad").unwrap();
        let ct = MEDIA_CHUNK + TAG_LEN;
        let cut_boundary = sealed[..HEADER_LEN + 3 * ct].to_vec();
        let cut_middle = sealed[..sealed.len() - 3].to_vec();
        let mut dropped = sealed[..HEADER_LEN + ct].to_vec();
        dropped.extend_from_slice(&sealed[HEADER_LEN + 2 * ct..]);
        let mut swapped = sealed[..HEADER_LEN].to_vec();
        swapped.extend_from_slice(&sealed[HEADER_LEN + ct..HEADER_LEN + 2 * ct]);
        swapped.extend_from_slice(&sealed[HEADER_LEN..HEADER_LEN + ct]);
        swapped.extend_from_slice(&sealed[HEADER_LEN + 2 * ct..]);
        let mut edited = sealed.clone();
        edited[10] ^= 1;
        for (what, bytes) in [
            ("boundary truncation", &cut_boundary),
            ("mid truncation", &cut_middle),
            ("dropped chunk", &dropped),
            ("swapped chunks", &swapped),
            ("edited header", &edited),
        ] {
            assert!(open_bytes(&key(), bytes, b"aad").is_err(), "{what} must not open");
        }
        assert!(open_bytes(&key(), &sealed, b"other").is_err());
        assert!(open_bytes(&CollectionKey([8u8; 32]), &sealed, b"aad").is_err());
    }

    /// 解不开的原因：密钥 / 名字不对、第一块被改 = 证明不了密钥（[OpenError::Unauthenticated]，不怪对象）；前面的块
    /// 认证过之后坏了、头的块大小非法、短到不像任何封装 = 对象坏了（[OpenError::Corrupt]）。
    #[test]
    fn open_errors_tell_an_unproven_key_from_a_corrupt_object() {
        let plain: Vec<u8> = (0..3 * MEDIA_CHUNK + 5).map(|i| i as u8).collect();
        let sealed = seal_bytes(&key(), &plain, b"aad").unwrap();
        let ct = MEDIA_CHUNK + TAG_LEN;
        let open = |b: &[u8], k: &CollectionKey, aad: &[u8]| open_bytes(k, b, aad).unwrap_err();
        assert_eq!(open(&sealed, &CollectionKey([8u8; 32]), b"aad"), OpenError::Unauthenticated, "wrong key");
        assert_eq!(open(&sealed, &key(), b"other"), OpenError::Unauthenticated, "wrong name");
        let mut first = sealed.clone();
        first[HEADER_LEN + 3] ^= 1;
        assert_eq!(open(&first, &key(), b"aad"), OpenError::Unauthenticated, "first chunk edited");
        let mut later = sealed.clone();
        later[HEADER_LEN + 2 * ct + 3] ^= 1;
        assert_eq!(open(&later, &key(), b"aad"), OpenError::Corrupt, "later chunk edited");
        assert_eq!(open(&sealed[..sealed.len() - 3], &key(), b"aad"), OpenError::Corrupt, "truncated");
        assert_eq!(open(&sealed[..HEADER_LEN + 2 * ct], &key(), b"aad"), OpenError::Corrupt, "cut at a boundary");
        let mut size = sealed.clone();
        size[4..8].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(open(&size, &key(), b"aad"), OpenError::Corrupt, "bad chunk size");
        assert_eq!(open(&[], &key(), b"aad"), OpenError::Corrupt, "empty placeholder");
        assert_eq!(open(&sealed[..10], &key(), b"aad"), OpenError::Corrupt, "shorter than any envelope");
        // 本机读写失败不是对象的错。
        let missing = std::env::temp_dir().join("fushi_media_seal_no_such_file");
        assert!(matches!(
            open_file(&key(), &missing, &missing.with_extension("out"), b"aad"),
            Err(OpenError::Io(_))
        ));
    }

    /// S-9 之前的整份封装（v1 位置的按名字目录）：正常解封路径不认（没有魔数 = 对象坏了），只有迁移用的 [open_v1]
    /// 解得开，且 AAD（文件名）照样绑定。
    #[test]
    fn v1_envelopes_open_only_through_the_migrator() {
        let plain = b"old media".repeat(1000);
        let v1 = key().seal(&plain, b"aad");
        assert_eq!(open_bytes(&key(), &v1, b"aad").unwrap_err(), OpenError::Corrupt);
        assert_eq!(open_v1(&key(), &v1, b"aad").unwrap(), plain);
        assert!(open_v1(&key(), &v1, b"other").is_none());
        assert!(open_v1(&CollectionKey([8u8; 32]), &v1, b"aad").is_none());
    }

    #[test]
    fn files_seal_and_open_with_the_plaintext_hash_and_leave_nothing_on_failure() {
        let dir = std::env::temp_dir().join(format!("fushi_media_seal_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let plain: Vec<u8> = (0..5 * MEDIA_CHUNK / 2).map(|i| (i % 253) as u8).collect();
        let (src, sealed, back) = (dir.join("a.bin"), dir.join("a.sealed"), dir.join("a.out"));
        std::fs::write(&src, &plain).unwrap();
        let s = seal_file(&key(), &src, &sealed, b"aad").unwrap();
        let want: [u8; 32] = Sha256::digest(&plain).into();
        assert_eq!(s, Sealed { plain_len: plain.len() as u64, sha256: want });
        assert_eq!(open_file(&key(), &sealed, &back, b"aad").unwrap(), s);
        assert_eq!(std::fs::read(&back).unwrap(), plain);
        // 解不开：不留目标、不留临时文件。
        std::fs::remove_file(&back).unwrap();
        assert!(open_file(&key(), &sealed, &back, b"wrong").is_err());
        let left: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(left.len(), 2, "{left:?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
