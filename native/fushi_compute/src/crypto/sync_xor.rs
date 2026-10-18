//! 云同步「防扫盘」混淆（`fushi/lib/src/sync/sync_obfuscator.dart` 的字节变换）。
//!
//! 不是加密：固定 keystream = SHA-256("hibiki")（32 字节）循环 XOR，第 `i` 个正文字节
//! XOR `keystream[i % 32]`，`i` 是正文（不含 8 字节魔数）里的全局偏移。混淆与还原是同一个
//! 操作。已同步到云端的文件靠这份 keystream 解开——**永远不能改**。

use sha2::{Digest, Sha256};

use crate::{guard, status};

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

/// [xor_in_place] 的 C ABI。
///
/// # Safety
/// `data` 至少 `len` 字节可读写（`len == 0` 时可为空）。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_sync_xor(data: *mut u8, len: usize, body_offset: u64) -> i32 {
    guard(|| {
        if len == 0 {
            return status::OK;
        }
        if data.is_null() {
            return status::NULL_ARGUMENT;
        }
        xor_in_place(std::slice::from_raw_parts_mut(data, len), body_offset);
        status::OK
    })
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
}
