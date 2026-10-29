//! 注入给前奏的原生函数（全局 `__n`，前奏执行完即从全局删除，插件只经 `fushi.*` 间接使用）。
//!
//! 加解密 / 摘要 / 编码同步在 Rust 里做（快、无宿主往返）；网络与存储只登记成宿主调用，
//! 由 [Gate::host_call] 先按清单核对。

use std::sync::Arc;

use aes::cipher::{block_padding, BlockDecryptMut, BlockEncryptMut, KeyInit, KeyIvInit};
use data_encoding::{BASE64, HEXLOWER_PERMISSIVE};
use hmac::{Hmac, Mac};
use md5::Md5;
use num_bigint::BigUint;
use rquickjs::{Ctx, Function, Object, Result, TypedArray, Value};
use sha1::Sha1;
use sha2::{Digest, Sha256};

use crate::plugin::runtime::{settle, throw, Gate, API_VERSION};

fn bytes_of(ctx: &Ctx<'_>, v: &Value<'_>) -> Result<Vec<u8>> {
    if let Some(s) = v.as_string() {
        return Ok(s.to_string()?.into_bytes());
    }
    if let Some(arr) = v.as_object().and_then(|o| o.as_typed_array::<u8>()) {
        // SAFETY: 立即拷出，期间不执行任何 JS，缓冲区不会被分离或缩小。
        return Ok(unsafe { arr.as_bytes() }.map(<[u8]>::to_vec).unwrap_or_default());
    }
    Err(throw(ctx, "期望 Uint8Array 或字符串"))
}

fn u8a<'js>(ctx: &Ctx<'js>, data: Vec<u8>) -> Result<TypedArray<'js, u8>> {
    TypedArray::new(ctx.clone(), data)
}

pub(crate) fn install<'js>(ctx: &Ctx<'js>, gate: Arc<Gate>) -> Result<Object<'js>> {
    let n = Object::new(ctx.clone())?;
    n.set("apiVersion", API_VERSION)?;

    {
        let gate = gate.clone();
        n.set(
            "hostCall",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, op: String, args: String| {
                gate.host_call(&op, &args)
                    .map(|id| id as f64)
                    .map_err(|e| throw(&ctx, &e))
            })?,
        )?;
    }
    {
        let gate = gate.clone();
        n.set(
            "settle",
            Function::new(ctx.clone(), move |inv: f64, ok: bool, payload: String| {
                settle(&gate, inv as u64, ok, payload);
            })?,
        )?;
    }
    {
        let gate = gate.clone();
        n.set(
            "log",
            Function::new(ctx.clone(), move |level: String, msg: String| {
                let level = match level.as_str() {
                    "debug" | "info" | "warn" | "error" => level,
                    _ => "info".to_string(),
                };
                gate.outbox.lock().unwrap().log(&level, &msg);
            })?,
        )?;
    }
    {
        let gate = gate.clone();
        n.set(
            "compile",
            Function::new(ctx.clone(), move |ctx: Ctx<'js>, path: String| -> Result<Value<'js>> {
                let Some(src) = gate.sources.get(&path) else {
                    return Ok(Value::new_undefined(ctx.clone()));
                };
                // 包成函数再求值：模块作用域隔离，`module` / `exports` / `require` 是形参。
                let wrapped = format!("(function (module, exports, require) {{\n{src}\n}})");
                ctx.eval::<Value, _>(wrapped)
            })?,
        )?;
    }

    n.set(
        "utf8Encode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, s: String| u8a(&ctx, s.into_bytes()))?,
    )?;
    n.set(
        "utf8Decode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, v: Value<'js>| -> Result<String> {
            Ok(String::from_utf8_lossy(&bytes_of(&ctx, &v)?).into_owned())
        })?,
    )?;
    n.set(
        "b64Encode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, v: Value<'js>| -> Result<String> {
            Ok(BASE64.encode(&bytes_of(&ctx, &v)?))
        })?,
    )?;
    n.set(
        "b64Decode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, s: String| {
            let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
            let data = BASE64
                .decode(cleaned.as_bytes())
                .map_err(|_| throw(&ctx, "base64 解码失败"))?;
            u8a(&ctx, data)
        })?,
    )?;
    n.set(
        "hexEncode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, v: Value<'js>| -> Result<String> {
            Ok(data_encoding::HEXLOWER.encode(&bytes_of(&ctx, &v)?))
        })?,
    )?;
    n.set(
        "hexDecode",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, s: String| {
            let data = HEXLOWER_PERMISSIVE
                .decode(s.as_bytes())
                .map_err(|_| throw(&ctx, "十六进制解码失败"))?;
            u8a(&ctx, data)
        })?,
    )?;

    n.set(
        "digest",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, alg: String, v: Value<'js>| {
            let data = bytes_of(&ctx, &v)?;
            let out = match alg.as_str() {
                "md5" => Md5::digest(&data).to_vec(),
                "sha1" => Sha1::digest(&data).to_vec(),
                "sha256" => Sha256::digest(&data).to_vec(),
                _ => return Err(throw(&ctx, "不支持的摘要算法")),
            };
            u8a(&ctx, out)
        })?,
    )?;
    n.set(
        "hmac",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, alg: String, key: Value<'js>, data: Value<'js>| {
                let key = bytes_of(&ctx, &key)?;
                let data = bytes_of(&ctx, &data)?;
                let out = match alg.as_str() {
                    "sha256" => {
                        let mut m = <Hmac<Sha256> as Mac>::new_from_slice(&key).unwrap();
                        m.update(&data);
                        m.finalize().into_bytes().to_vec()
                    }
                    "sha1" => {
                        let mut m = <Hmac<Sha1> as Mac>::new_from_slice(&key).unwrap();
                        m.update(&data);
                        m.finalize().into_bytes().to_vec()
                    }
                    "md5" => {
                        let mut m = <Hmac<Md5> as Mac>::new_from_slice(&key).unwrap();
                        m.update(&data);
                        m.finalize().into_bytes().to_vec()
                    }
                    _ => return Err(throw(&ctx, "不支持的 HMAC 算法")),
                };
                u8a(&ctx, out)
            },
        )?,
    )?;
    n.set(
        "aes",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>,
             mode: String,
             decrypt: bool,
             key: Value<'js>,
             iv: Value<'js>,
             data: Value<'js>,
             padding: String| {
                let key = bytes_of(&ctx, &key)?;
                let iv = bytes_of(&ctx, &iv)?;
                let data = bytes_of(&ctx, &data)?;
                let out = aes_op(&mode, decrypt, &key, &iv, &data, padding == "pkcs7")
                    .map_err(|e| throw(&ctx, &e))?;
                u8a(&ctx, out)
            },
        )?,
    )?;
    n.set(
        "rsaRaw",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, modulus: String, exponent: String, data: Value<'js>| {
                let data = bytes_of(&ctx, &data)?;
                let out = rsa_raw(&modulus, &exponent, &data).map_err(|e| throw(&ctx, &e))?;
                u8a(&ctx, out)
            },
        )?,
    )?;
    n.set(
        "randomBytes",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, len: i32| {
            if !(0..=4096).contains(&len) {
                return Err(throw(&ctx, "randomBytes 长度须在 0–4096"));
            }
            let mut buf = vec![0u8; len as usize];
            getrandom::getrandom(&mut buf).map_err(|_| throw(&ctx, "系统随机数不可用"))?;
            u8a(&ctx, buf)
        })?,
    )?;
    Ok(n)
}

pub(crate) fn aes_op(
    mode: &str,
    decrypt: bool,
    key: &[u8],
    iv: &[u8],
    data: &[u8],
    pkcs7: bool,
) -> std::result::Result<Vec<u8>, String> {
    macro_rules! run {
        ($aes:ty) => {{
            match (mode, decrypt, pkcs7) {
                ("cbc", false, true) => cbc::Encryptor::<$aes>::new_from_slices(key, iv)
                    .map_err(|_| "AES-CBC 的 iv 必须 16 字节".to_string())?
                    .encrypt_padded_vec_mut::<block_padding::Pkcs7>(data),
                ("cbc", false, false) => cbc::Encryptor::<$aes>::new_from_slices(key, iv)
                    .map_err(|_| "AES-CBC 的 iv 必须 16 字节".to_string())?
                    .encrypt_padded_vec_mut::<block_padding::NoPadding>(data),
                ("cbc", true, true) => cbc::Decryptor::<$aes>::new_from_slices(key, iv)
                    .map_err(|_| "AES-CBC 的 iv 必须 16 字节".to_string())?
                    .decrypt_padded_vec_mut::<block_padding::Pkcs7>(data)
                    .map_err(|_| "AES 解密失败（填充不对）".to_string())?,
                ("cbc", true, false) => cbc::Decryptor::<$aes>::new_from_slices(key, iv)
                    .map_err(|_| "AES-CBC 的 iv 必须 16 字节".to_string())?
                    .decrypt_padded_vec_mut::<block_padding::NoPadding>(data)
                    .map_err(|_| "AES 解密失败（长度不是块的整数倍）".to_string())?,
                ("ecb", false, true) => ecb::Encryptor::<$aes>::new_from_slice(key)
                    .unwrap()
                    .encrypt_padded_vec_mut::<block_padding::Pkcs7>(data),
                ("ecb", false, false) => ecb::Encryptor::<$aes>::new_from_slice(key)
                    .unwrap()
                    .encrypt_padded_vec_mut::<block_padding::NoPadding>(data),
                ("ecb", true, true) => ecb::Decryptor::<$aes>::new_from_slice(key)
                    .unwrap()
                    .decrypt_padded_vec_mut::<block_padding::Pkcs7>(data)
                    .map_err(|_| "AES 解密失败（填充不对）".to_string())?,
                ("ecb", true, false) => ecb::Decryptor::<$aes>::new_from_slice(key)
                    .unwrap()
                    .decrypt_padded_vec_mut::<block_padding::NoPadding>(data)
                    .map_err(|_| "AES 解密失败（长度不是块的整数倍）".to_string())?,
                _ => return Err(format!("不支持的 AES 模式 {mode}")),
            }
        }};
    }
    if !pkcs7 && data.len() % 16 != 0 {
        return Err("无填充 AES 的数据长度必须是 16 的整数倍".into());
    }
    Ok(match key.len() {
        16 => run!(aes::Aes128),
        24 => run!(aes::Aes192),
        32 => run!(aes::Aes256),
        _ => return Err("AES 密钥必须是 16 / 24 / 32 字节".into()),
    })
}

/// 无填充 RSA：`data^e mod n`，结果左补零到模长。
pub(crate) fn rsa_raw(modulus_hex: &str, exponent_hex: &str, data: &[u8]) -> std::result::Result<Vec<u8>, String> {
    let n = BigUint::parse_bytes(modulus_hex.trim().as_bytes(), 16).ok_or("modulus 不是十六进制")?;
    let e = BigUint::parse_bytes(exponent_hex.trim().as_bytes(), 16).ok_or("exponent 不是十六进制")?;
    if n.bits() < 64 || n.bits() > 8192 {
        return Err("modulus 长度不合理".into());
    }
    let m = BigUint::from_bytes_be(data);
    if m >= n {
        return Err("数据不小于模数".into());
    }
    let c = m.modpow(&e, &n).to_bytes_be();
    let width = n.bits().div_ceil(8) as usize;
    let mut out = vec![0u8; width.saturating_sub(c.len())];
    out.extend_from_slice(&c);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes_cbc_known_vector() {
        // NIST SP 800-38A F.2.1 第一块。
        let key = HEXLOWER_PERMISSIVE.decode(b"2b7e151628aed2a6abf7158809cf4f3c").unwrap();
        let iv = HEXLOWER_PERMISSIVE.decode(b"000102030405060708090a0b0c0d0e0f").unwrap();
        let pt = HEXLOWER_PERMISSIVE.decode(b"6bc1bee22e409f96e93d7e117393172a").unwrap();
        let ct = aes_op("cbc", false, &key, &iv, &pt, false).unwrap();
        assert_eq!(data_encoding::HEXLOWER.encode(&ct), "7649abac8119b246cee98e9b12e9197d");
        assert_eq!(aes_op("cbc", true, &key, &iv, &ct, false).unwrap(), pt);
        let padded = aes_op("ecb", false, &key, &[], b"hello", true).unwrap();
        assert_eq!(padded.len(), 16);
        assert_eq!(aes_op("ecb", true, &key, &[], &padded, true).unwrap(), b"hello");
        assert!(aes_op("cbc", false, &key, &[1, 2], &pt, true).is_err());
    }

    #[test]
    fn rsa_raw_small() {
        // 过小的模数拒绝；正常模数下结果等于大数模幂、并左补零到模长。
        assert!(rsa_raw("ca1", "11", &[65]).is_err());
        let modulus = "c7f1d3e5b9a1f2d4c6e8a0b2d4f6a8c1e3f5a7b9d1c3e5f7a9b1d3f5e7c9a1b3";
        let out = rsa_raw(modulus, "10001", &[2]).unwrap();
        assert_eq!(out.len(), 32);
        let back = BigUint::from_bytes_be(&out);
        let expect = BigUint::from(2u32).modpow(
            &BigUint::parse_bytes(b"10001", 16).unwrap(),
            &BigUint::parse_bytes(modulus.as_bytes(), 16).unwrap(),
        );
        assert_eq!(back, expect);
    }
}
