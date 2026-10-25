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
}

/// 集合加密密钥。
#[derive(Clone)]
pub struct CollectionKey(pub [u8; 32]);

pub const NONCE_LEN: usize = 24;
pub const TAG_LEN: usize = 16;

impl CollectionKey {
    pub fn derive(passphrase: &[u8], salt: &[u8], params: KdfParams) -> Result<CollectionKey, String> {
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
        let key = CollectionKey::derive(b"pw", b"0123456789abcdef", KdfParams { m_kib: 64, t: 1, p: 1 }).unwrap();
        let sealed = key.seal(b"hello", b"hdr");
        assert_eq!(key.open(&sealed, b"hdr").as_deref(), Some(&b"hello"[..]));
        assert_eq!(key.open(&sealed, b"other"), None);
        let wrong = CollectionKey::derive(b"pw2", b"0123456789abcdef", KdfParams { m_kib: 64, t: 1, p: 1 }).unwrap();
        assert_eq!(wrong.open(&sealed, b"hdr"), None);
    }
}
