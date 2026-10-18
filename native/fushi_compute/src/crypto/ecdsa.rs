//! P-256 ECDSA/SHA-256（RustCrypto `p256`）：排行榜账户 / 安装身份、互联设备钥匙、host
//! 自签 TLS 证书共用。
//!
//! - 私钥：32 字节大端标量，须在 [1, n-1]；
//! - 公钥：65 字节未压缩点 `04‖x‖y`（SPKI 由 Dart 侧拼固定前缀）；
//! - 签名：RFC 6979 确定性 k，P1363 `r‖s`（各 32 字节大端），**不做 low-s 归一**——与原
//!   pointycastle 实现逐字节一致（同一钥匙同一消息恒同一签名），验签也接受 high-s。

use p256::ecdsa::{
    signature::{Signer, Verifier},
    Signature, SigningKey, VerifyingKey,
};

use crate::{guard, status};

/// 验签不通过（签名格式合法但不对，或 r / s 不在 [1, n-1]）。
pub const P256_SIGNATURE_INVALID: i32 = -22;

unsafe fn signing_key(d: *const u8) -> Option<SigningKey> {
    let d: &[u8; 32] = &*(d as *const [u8; 32]);
    SigningKey::from_bytes(d.into()).ok()
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// 私钥 → 65 字节未压缩公钥点。标量不在 [1, n-1] 返回 [status::INVALID_ARGUMENT]。
///
/// # Safety
/// `d` 32 字节可读；`out_point` 65 字节可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_p256_public_key(d: *const u8, out_point: *mut u8) -> i32 {
    guard(|| {
        if d.is_null() || out_point.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(key) = signing_key(d) else {
            return status::INVALID_ARGUMENT;
        };
        let point = key.verifying_key().to_encoded_point(false);
        std::slice::from_raw_parts_mut(out_point, 65).copy_from_slice(point.as_bytes());
        status::OK
    })
}

/// ECDSA/SHA-256 签 `msg`，输出 P1363 `r‖s` 64 字节。
///
/// # Safety
/// `d` 32 字节、`msg` `len` 字节可读；`out_sig` 64 字节可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_p256_sign_sha256(
    d: *const u8,
    msg: *const u8,
    len: usize,
    out_sig: *mut u8,
) -> i32 {
    guard(|| {
        if d.is_null() || out_sig.is_null() || (msg.is_null() && len != 0) {
            return status::NULL_ARGUMENT;
        }
        let Some(key) = signing_key(d) else {
            return status::INVALID_ARGUMENT;
        };
        let sig: Signature = key.sign(bytes(msg, len));
        std::slice::from_raw_parts_mut(out_sig, 64).copy_from_slice(&sig.to_bytes());
        status::OK
    })
}

/// 用 65 字节未压缩点验 `msg` 的 P1363 签名。通过返回 [status::OK]，不对返回
/// [P256_SIGNATURE_INVALID]，点不合法（不在曲线上 / 不是 `04` 前缀）返回 [status::BAD_INPUT]。
///
/// # Safety
/// `point` 65 字节、`msg` `len` 字节、`sig` 64 字节可读。
#[no_mangle]
pub unsafe extern "C" fn ffc_crypto_p256_verify_sha256(
    point: *const u8,
    msg: *const u8,
    len: usize,
    sig: *const u8,
) -> i32 {
    guard(|| {
        if point.is_null() || sig.is_null() || (msg.is_null() && len != 0) {
            return status::NULL_ARGUMENT;
        }
        let point = std::slice::from_raw_parts(point, 65);
        if point[0] != 0x04 {
            return status::BAD_INPUT;
        }
        let Ok(key) = VerifyingKey::from_sec1_bytes(point) else {
            return status::BAD_INPUT;
        };
        let Ok(sig) = Signature::from_slice(std::slice::from_raw_parts(sig, 64)) else {
            return P256_SIGNATURE_INVALID;
        };
        if key.verify(bytes(msg, len), &sig).is_ok() {
            status::OK
        } else {
            P256_SIGNATURE_INVALID
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_verify_roundtrip_and_range_check() {
        let mut d = [0u8; 32];
        d[31] = 7;
        let mut point = [0u8; 65];
        let mut sig = [0u8; 64];
        unsafe {
            assert_eq!(ffc_crypto_p256_public_key(d.as_ptr(), point.as_mut_ptr()), status::OK);
            assert_eq!(
                ffc_crypto_p256_sign_sha256(d.as_ptr(), b"hi".as_ptr(), 2, sig.as_mut_ptr()),
                status::OK
            );
            assert_eq!(
                ffc_crypto_p256_verify_sha256(point.as_ptr(), b"hi".as_ptr(), 2, sig.as_ptr()),
                status::OK
            );
            assert_eq!(
                ffc_crypto_p256_verify_sha256(point.as_ptr(), b"ho".as_ptr(), 2, sig.as_ptr()),
                P256_SIGNATURE_INVALID
            );
            let zero = [0u8; 32];
            assert_eq!(
                ffc_crypto_p256_public_key(zero.as_ptr(), point.as_mut_ptr()),
                status::INVALID_ARGUMENT
            );
        }
    }
}
