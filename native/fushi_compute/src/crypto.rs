//! `ffc_crypto_*`：AES 解密内核（AACS 蓝光内容解密 / HLS AES-128 分片解密）。
//!
//! 取代原先 pointycastle 的纯 Dart 实现（Dart 侧已删，不保留回退）。AES 用 RustCrypto
//! `aes`（x86 运行时检测 AES-NI，aarch64 用 ARMv8 AES 指令，其它退回常数时间软件实现），
//! CBC 用 `cbc`。输出与原 Dart 实现逐字节一致，由
//! packages/fushi_compute/test/crypto/ 的固定向量钉死。
//!
//! 返回码在 [crate::status] 之外另有本域的：
//! - [AACS_CLEAR_UNIT_INVALID]：未加密单元（首字节高两位为 0）的 TS 同步字节不对；
//! - [AACS_NO_MATCHING_KEY]：所有 unit key 都解不出合法 TS（盘密钥不符 / 不支持的保护）。

use aes::cipher::{
    block_padding::{NoPadding, Pkcs7},
    BlockDecrypt, BlockDecryptMut, BlockEncrypt, KeyInit, KeyIvInit,
};
use aes::{Aes128, Aes192, Aes256};

use crate::{guard, status};

/// AACS 对齐单元长度（32 个 192 字节源包）。
pub const AACS_UNIT_LEN: usize = 6144;
const SOURCE_PACKET_LEN: usize = 192;

pub const AACS_CLEAR_UNIT_INVALID: i32 = -20;
pub const AACS_NO_MATCHING_KEY: i32 = -21;

/// AACS 1 aligned-unit 内容加密的固定 IV（libaacs crypto.c 同值）。
const AACS_IV: [u8; 16] = [
    0x0b, 0xa0, 0xf8, 0xdd, 0xfe, 0xa6, 0x1f, 0xb3, 0xd8, 0xdf, 0x9f, 0x56, 0x6a, 0x05, 0x0f,
    0x78,
];

/// 一张盘的 unit key 集合 + 上次命中的 key（下一单元从它开始试）。
pub struct AacsDecoder {
    keys: Vec<Aes128>,
    last_key: usize,
    candidate: Box<[u8; AACS_UNIT_LEN]>,
}

impl AacsDecoder {
    pub fn new(unit_keys: &[[u8; 16]]) -> Self {
        AacsDecoder {
            keys: unit_keys
                .iter()
                .map(|k| Aes128::new(k.into()))
                .collect(),
            last_key: 0,
            candidate: Box::new([0u8; AACS_UNIT_LEN]),
        }
    }

    /// 原地解一个单元；失败时 [unit] 保持原样。
    pub fn decrypt_unit(&mut self, unit: &mut [u8]) -> i32 {
        debug_assert_eq!(unit.len(), AACS_UNIT_LEN);
        if unit[0] & 0xc0 == 0 {
            return if valid_transport(unit) {
                status::OK
            } else {
                AACS_CLEAR_UNIT_INVALID
            };
        }
        let count = self.keys.len();
        for attempt in 0..count {
            let index = (self.last_key + attempt) % count;
            let mut content_key = [0u8; 16];
            self.keys[index].encrypt_block_b2b(
                (&unit[..16]).into(),
                (&mut content_key).into(),
            );
            for (k, u) in content_key.iter_mut().zip(&unit[..16]) {
                *k ^= *u;
            }
            let candidate = &mut self.candidate[..];
            candidate[..16].copy_from_slice(&unit[..16]);
            let ok = cbc::Decryptor::<Aes128>::new((&content_key).into(), (&AACS_IV).into())
                .decrypt_padded_b2b_mut::<NoPadding>(&unit[16..], &mut candidate[16..])
                .is_ok();
            content_key.fill(0);
            if !ok || !valid_transport(candidate) {
                continue;
            }
            for offset in (0..AACS_UNIT_LEN).step_by(SOURCE_PACKET_LEN) {
                candidate[offset] &= 0x3f;
            }
            unit.copy_from_slice(candidate);
            self.last_key = index;
            return status::OK;
        }
        AACS_NO_MATCHING_KEY
    }
}

impl Drop for AacsDecoder {
    fn drop(&mut self) {
        // 明文残留不留在堆上（keys 由 aes 的 zeroize feature 在 drop 时清零）。
        self.candidate.fill(0);
    }
}

fn valid_transport(unit: &[u8]) -> bool {
    (4..AACS_UNIT_LEN)
        .step_by(SOURCE_PACKET_LEN)
        .all(|offset| unit[offset] == 0x47)
}

/// 建一个 AACS 解码器。`unit_keys` 是 `key_count` 个紧挨着的 16 字节 unit key。
/// 成功时 `*out_handle` 指向新对象，用 [ffc_crypto_aacs_close] 释放。
///
/// # Safety
/// `unit_keys` 至少 `16 * key_count` 字节可读；`out_handle` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_aacs_open(
    unit_keys: *const u8,
    key_count: usize,
    out_handle: *mut *mut AacsDecoder,
) -> i32 {
    guard(|| {
        if unit_keys.is_null() || out_handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        if key_count == 0 {
            return status::INVALID_ARGUMENT;
        }
        let raw = std::slice::from_raw_parts(unit_keys, key_count * 16);
        let keys: Vec<[u8; 16]> = raw
            .chunks_exact(16)
            .map(|c| c.try_into().unwrap())
            .collect();
        *out_handle = Box::into_raw(Box::new(AacsDecoder::new(&keys)));
        status::OK
    })
}

/// 释放 [ffc_crypto_aacs_open] 建的解码器（空指针无操作）。
///
/// # Safety
/// `handle` 必须是 [ffc_crypto_aacs_open] 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_aacs_close(handle: *mut AacsDecoder) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// 原地解 `len / 6144` 个连续单元（`len` 必须是 6144 的正整数倍）。
///
/// 按顺序处理；某个单元失败就停下，返回本域错误码，`*out_done` = 已成功的单元数
/// （= 失败单元的下标），失败单元及其后的字节保持原样。全部成功时 `*out_done` = 单元数。
///
/// # Safety
/// `handle` 有效；`buf` 至少 `len` 字节可读写；`out_done` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_aacs_decrypt_units(
    handle: *mut AacsDecoder,
    buf: *mut u8,
    len: usize,
    out_done: *mut usize,
) -> i32 {
    guard(|| {
        if handle.is_null() || buf.is_null() || out_done.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out_done = 0;
        if len == 0 || len % AACS_UNIT_LEN != 0 {
            return status::INVALID_ARGUMENT;
        }
        let decoder = &mut *handle;
        let data = std::slice::from_raw_parts_mut(buf, len);
        for (index, unit) in data.chunks_exact_mut(AACS_UNIT_LEN).enumerate() {
            let code = decoder.decrypt_unit(unit);
            if code != status::OK {
                *out_done = index;
                return code;
            }
        }
        *out_done = len / AACS_UNIT_LEN;
        status::OK
    })
}

/// AES-128 ECB 原地解 `len` 字节（16 的倍数）。AACS unit key 表解密用。
///
/// # Safety
/// `key` 16 字节可读；`data` 至少 `len` 字节可读写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_aes128_ecb_decrypt(
    key: *const u8,
    data: *mut u8,
    len: usize,
) -> i32 {
    guard(|| {
        if key.is_null() || (data.is_null() && len != 0) {
            return status::NULL_ARGUMENT;
        }
        if len % 16 != 0 {
            return status::INVALID_ARGUMENT;
        }
        let key: &[u8; 16] = &*(key as *const [u8; 16]);
        let aes = Aes128::new(key.into());
        if len > 0 {
            for block in std::slice::from_raw_parts_mut(data, len).chunks_exact_mut(16) {
                aes.decrypt_block(block.into());
            }
        }
        status::OK
    })
}

macro_rules! cbc_pkcs7 {
    ($cipher:ty, $key:expr, $iv:expr, $data:expr) => {
        cbc::Decryptor::<$cipher>::new_from_slices($key, $iv)
            .ok()
            .and_then(|d| d.decrypt_padded_mut::<Pkcs7>($data).ok())
            .map(|plain| plain.len())
    };
}

/// AES-CBC + PKCS7 原地解一个 HLS 分片：`data`（`len` 字节，16 的正整数倍）解完后前
/// `*out_len` 字节是明文。key 长度 16 / 24 / 32（AES-128/192/256）。
///
/// 返回 [status::INVALID_ARGUMENT]：key / 长度非法；[status::BAD_INPUT]：填充非法
/// （此时 `data` 内容未定义）。
///
/// # Safety
/// `key` `key_len` 字节、`iv` 16 字节可读；`data` `len` 字节可读写；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_aes_cbc_pkcs7_decrypt(
    key: *const u8,
    key_len: usize,
    iv: *const u8,
    data: *mut u8,
    len: usize,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if key.is_null() || iv.is_null() || data.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out_len = 0;
        if len == 0 || len % 16 != 0 {
            return status::INVALID_ARGUMENT;
        }
        let key = std::slice::from_raw_parts(key, key_len);
        let iv: &[u8; 16] = &*(iv as *const [u8; 16]);
        let data = std::slice::from_raw_parts_mut(data, len);
        let plain = match key_len {
            16 => cbc_pkcs7!(Aes128, key, iv, data),
            24 => cbc_pkcs7!(Aes192, key, iv, data),
            32 => cbc_pkcs7!(Aes256, key, iv, data),
            _ => return status::INVALID_ARGUMENT,
        };
        match plain {
            Some(n) => {
                *out_len = n;
                status::OK
            }
            None => status::BAD_INPUT,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockEncryptMut;

    fn encrypt_unit(unit_key: &[u8; 16], plain: &[u8]) -> Vec<u8> {
        let mut out = plain.to_vec();
        let mut ck = [0u8; 16];
        Aes128::new(unit_key.into()).encrypt_block_b2b((&plain[..16]).into(), (&mut ck).into());
        for (k, u) in ck.iter_mut().zip(&plain[..16]) {
            *k ^= *u;
        }
        cbc::Encryptor::<Aes128>::new((&ck).into(), (&AACS_IV).into())
            .encrypt_padded_mut::<NoPadding>(&mut out[16..], AACS_UNIT_LEN - 16)
            .unwrap();
        out
    }

    fn plain_unit(seed: u8) -> Vec<u8> {
        let mut unit: Vec<u8> = (0..AACS_UNIT_LEN).map(|i| (i as u8) ^ seed).collect();
        for offset in (0..AACS_UNIT_LEN).step_by(SOURCE_PACKET_LEN) {
            unit[offset] = 0xc0 | (seed & 0x3f);
            unit[offset + 4] = 0x47;
        }
        unit
    }

    #[test]
    fn decrypts_with_second_key_and_clears_cpi() {
        let k1 = [1u8; 16];
        let k2 = [2u8; 16];
        let plain = plain_unit(7);
        let mut unit = encrypt_unit(&k2, &plain);
        let mut dec = AacsDecoder::new(&[k1, k2]);
        assert_eq!(dec.decrypt_unit(&mut unit), status::OK);
        assert_eq!(dec.last_key, 1);
        for offset in (0..AACS_UNIT_LEN).step_by(SOURCE_PACKET_LEN) {
            assert_eq!(unit[offset], plain[offset] & 0x3f);
        }
        assert_eq!(unit[1..192], plain[1..192]);
    }

    #[test]
    fn no_key_leaves_unit_unchanged() {
        let plain = plain_unit(3);
        let mut unit = encrypt_unit(&[9u8; 16], &plain);
        let original = unit.clone();
        let mut dec = AacsDecoder::new(&[[1u8; 16]]);
        assert_eq!(dec.decrypt_unit(&mut unit), AACS_NO_MATCHING_KEY);
        assert_eq!(unit, original);
    }

    #[test]
    fn hls_rejects_bad_padding() {
        let key = [5u8; 16];
        let iv = [6u8; 16];
        let mut data = vec![0u8; 32];
        cbc::Encryptor::<Aes128>::new((&key).into(), (&iv).into())
            .encrypt_padded_mut::<NoPadding>(&mut data, 32)
            .unwrap();
        let mut n = 0usize;
        let code = unsafe {
            ffc_crypto_aes_cbc_pkcs7_decrypt(key.as_ptr(), 16, iv.as_ptr(), data.as_mut_ptr(), 32, &mut n)
        };
        assert_eq!(code, status::BAD_INPUT);
    }
}
