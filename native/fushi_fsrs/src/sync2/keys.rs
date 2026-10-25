//! 密钥（设计 §7.4、§9）：设备签名密钥（Ed25519）与可选的集合加密密钥（XChaCha20-Poly1305，
//! 口令经 Argon2id 派生）。
//!
//! 签名不论加不加密都做：防损坏、防拿到网盘写权限的第三方注入操作；加密是每个存储位置的可选开关。

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

/// 设备签名密钥（种子 32 字节，存在 srs.db 本机表里，不进同步）。
#[derive(Clone)]
pub struct DeviceKey(SigningKey);

impl DeviceKey {
    pub fn generate() -> DeviceKey {
        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).expect("system random source");
        DeviceKey(SigningKey::from_bytes(&seed))
    }

    pub fn from_seed(seed: &[u8; 32]) -> DeviceKey {
        DeviceKey(SigningKey::from_bytes(seed))
    }

    pub fn seed(&self) -> [u8; 32] {
        self.0.to_bytes()
    }

    pub fn public(&self) -> [u8; 32] {
        self.0.verifying_key().to_bytes()
    }

    pub fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.0.sign(msg).to_bytes()
    }
}

/// 用公钥验签（严格模式：拒绝可塑签名）。
pub fn verify(public: &[u8; 32], msg: &[u8], sig: &[u8; 64]) -> bool {
    match VerifyingKey::from_bytes(public) {
        Ok(k) => k.verify_strict(msg, &Signature::from_bytes(sig)).is_ok(),
        Err(_) => false,
    }
}

/// Argon2id 参数（写进存储位置的 `meta.json`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KdfParams {
    pub m_kib: u32,
    pub t: u32,
    pub p: u32,
}

impl KdfParams {
    /// 默认：64 MiB、3 轮、单线程（低端机首次派生约 1 s；只在开加密时跑）。
    pub const DEFAULT: KdfParams = KdfParams { m_kib: 64 * 1024, t: 3, p: 1 };

    /// 参数上下限（P2-7）：参数来自位置上的 `meta.json`，是不可信输入。上限挡住「改 meta 让每台设备派生时
    /// 吃光内存 / 卡死几分钟」；下限挡住「改 meta 把派生降到几乎不花力气、方便离线猜口令」。Dart 侧
    /// `srs_location_crypto.dart` 的 `SrsKdf.fromJson` 用同一组常量，越界即报错、不派生。
    pub const MIN_M_KIB: u32 = 8 * 1024;
    pub const MAX_M_KIB: u32 = 256 * 1024;
    pub const MIN_T: u32 = 1;
    pub const MAX_T: u32 = 10;
    pub const MIN_P: u32 = 1;
    pub const MAX_P: u32 = 4;
    pub const MIN_SALT: usize = 16;
    pub const MAX_SALT: usize = 64;

    /// 按上下限检查（FFI 传进来的是 i64：负数 / 超出 u32 的一并拒绝，不做截断）。
    pub fn checked(m_kib: i64, t: i64, p: i64) -> Result<KdfParams, String> {
        let within = |v: i64, lo: u32, hi: u32| v >= i64::from(lo) && v <= i64::from(hi);
        if !within(m_kib, Self::MIN_M_KIB, Self::MAX_M_KIB) {
            return Err(format!("kdf memory {m_kib} KiB out of range"));
        }
        if !within(t, Self::MIN_T, Self::MAX_T) {
            return Err(format!("kdf iterations {t} out of range"));
        }
        if !within(p, Self::MIN_P, Self::MAX_P) {
            return Err(format!("kdf parallelism {p} out of range"));
        }
        Ok(KdfParams { m_kib: m_kib as u32, t: t as u32, p: p as u32 })
    }
}

/// 集合加密密钥。
#[derive(Clone)]
pub struct CollectionKey(pub [u8; 32]);

pub const NONCE_LEN: usize = 24;
pub const TAG_LEN: usize = 16;

impl CollectionKey {
    pub fn derive(passphrase: &[u8], salt: &[u8], params: KdfParams) -> Result<CollectionKey, String> {
        let params = KdfParams::checked(i64::from(params.m_kib), i64::from(params.t), i64::from(params.p))?;
        if !(KdfParams::MIN_SALT..=KdfParams::MAX_SALT).contains(&salt.len()) {
            return Err(format!("kdf salt of {} bytes out of range", salt.len()));
        }
        let p = Params::new(params.m_kib, params.t, params.p, Some(32)).map_err(|e| e.to_string())?;
        let mut out = [0u8; 32];
        Argon2::new(Algorithm::Argon2id, Version::V0x13, p)
            .hash_password_into(passphrase, salt, &mut out)
            .map_err(|e| e.to_string())?;
        Ok(CollectionKey(out))
    }

    /// `nonce || ciphertext+tag`；[aad] 绑定段头，换头即解密失败。
    pub fn seal(&self, plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::fill(&mut nonce).expect("system random source");
        let cipher = XChaCha20Poly1305::new((&self.0).into());
        let ct = cipher
            .encrypt(&XNonce::from(nonce), Payload { msg: plaintext, aad })
            .expect("xchacha20poly1305 encrypt");
        let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ct);
        out
    }

    pub fn open(&self, sealed: &[u8], aad: &[u8]) -> Option<Vec<u8>> {
        if sealed.len() < NONCE_LEN + TAG_LEN {
            return None;
        }
        let nonce: [u8; NONCE_LEN] = sealed[..NONCE_LEN].try_into().ok()?;
        let cipher = XChaCha20Poly1305::new((&self.0).into());
        cipher.decrypt(&XNonce::from(nonce), Payload { msg: &sealed[NONCE_LEN..], aad }).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_verify_and_reject_tampering() {
        let k = DeviceKey::generate();
        let sig = k.sign(b"segment");
        assert!(verify(&k.public(), b"segment", &sig));
        assert!(!verify(&k.public(), b"segmenT", &sig));
        let other = DeviceKey::generate();
        assert!(!verify(&other.public(), b"segment", &sig));
        assert_eq!(DeviceKey::from_seed(&k.seed()).public(), k.public());
    }

    #[test]
    fn aead_round_trip_binds_aad() {
        let key = CollectionKey::derive(b"pw", b"0123456789abcdef", KdfParams { m_kib: 8 * 1024, t: 1, p: 1 }).unwrap();
        let sealed = key.seal(b"hello", b"hdr");
        assert_eq!(key.open(&sealed, b"hdr").as_deref(), Some(&b"hello"[..]));
        assert_eq!(key.open(&sealed, b"other"), None);
        let wrong = CollectionKey::derive(b"pw2", b"0123456789abcdef", KdfParams { m_kib: 8 * 1024, t: 1, p: 1 }).unwrap();
        assert_eq!(wrong.open(&sealed, b"hdr"), None);
    }

    /// KDF 参数来自不可信的 `meta.json`：越界一律报错，不派生（也不截断成别的值）。
    #[test]
    fn kdf_params_from_meta_are_bounded() {
        let salt = b"0123456789abcdef";
        let derive = |m: i64, t: i64, p: i64| KdfParams::checked(m, t, p).and_then(|k| CollectionKey::derive(b"pw", salt, k));
        assert!(derive(8 * 1024, 1, 1).is_ok());
        for (m, t, p) in [
            (8 * 1024 - 1, 1, 1),
            (256 * 1024 + 1, 1, 1),
            (4 << 30, 1, 1),
            (-1, 1, 1),
            (1 << 32, 1, 1),
            (64 * 1024, 0, 1),
            (64 * 1024, 11, 1),
            (64 * 1024, 3, 0),
            (64 * 1024, 3, 5),
        ] {
            assert!(derive(m, t, p).is_err(), "m={m} t={t} p={p} must be rejected");
        }
        assert!(CollectionKey::derive(b"pw", b"short", KdfParams { m_kib: 8 * 1024, t: 1, p: 1 }).is_err());
        assert!(CollectionKey::derive(b"pw", &[0u8; 65], KdfParams { m_kib: 8 * 1024, t: 1, p: 1 }).is_err());
    }
}
