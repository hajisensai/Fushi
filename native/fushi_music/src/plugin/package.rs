//! 插件包 `.fushiplug`（zip）的校验、安装与加载（契约见 docs/specs/2026-10-28-music-plugins.md §2）。
//!
//! 包内必须有：
//! - `manifest.json`：清单（[Manifest]）；
//! - `files.json`：`{"files": {"<相对路径>": "<小写 sha256>"}}`，覆盖除它自己和
//!   `signature.json` 之外的**每一个**文件（多一个、少一个都拒装）；
//! - 可选 `signature.json`：`{"publicKey": base64(32 字节 Ed25519 公钥), "signature":
//!   base64(64 字节)}`，签的是 `files.json` 的原始字节。
//!
//! 安装后每次加载都按 `files.json` 重新哈希；被改过的文件让整个插件拒载。执行时只从这份已校验的
//! 内存副本取源码（不再读盘），没有「校验后被换掉」的窗口。

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use data_encoding::BASE64;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::plugin::manifest::Manifest;

pub const MAX_FILES: usize = 128;
pub const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
pub const MAX_TOTAL_BYTES: u64 = 16 * 1024 * 1024;

const FILES_JSON: &str = "files.json";
const SIGNATURE_JSON: &str = "signature.json";
const MANIFEST_JSON: &str = "manifest.json";

/// 包内相对路径的合法性：`/` 分隔、无 `..` / `.` 段、无反斜杠 / 盘符 / 绝对路径 / 控制字符。
pub fn check_rel_path(p: &str) -> Result<(), String> {
    let bad = p.is_empty()
        || p.len() > 200
        || p.starts_with('/')
        || p.contains('\\')
        || p.contains(':')
        || p.chars().any(|c| c.is_control())
        || p.split('/').any(|seg| seg.is_empty() || seg == "." || seg == "..");
    if bad {
        Err(format!("包内路径不合法：{p:?}"))
    } else {
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FilesJson {
    files: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SignatureJson {
    public_key: String,
    signature: String,
}

/// 校验通过的包：清单 + 全部文件的内存副本。
pub struct VerifiedPackage {
    pub manifest: Manifest,
    /// 除 `files.json` / `signature.json` 外的全部文件。
    pub files: BTreeMap<String, Vec<u8>>,
    /// `files.json` 原始字节的 sha256（小写十六进制）：包的身份。用户确认安装的就是它。
    pub digest: String,
    /// 签名者公钥（base64）；未签名为 None。是否可信由宿主按自己的信任列表判断。
    pub signer: Option<String>,
    files_raw: Vec<u8>,
    signature_raw: Option<Vec<u8>>,
}

impl VerifiedPackage {
    pub fn summary_json(&self) -> serde_json::Value {
        serde_json::json!({
            "manifest": self.manifest,
            "digest": self.digest,
            "signer": self.signer,
            "files": self.files.keys().collect::<Vec<_>>(),
        })
    }
}

fn hex(bytes: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(bytes)
}

/// 从「路径 → 字节」整体校验（zip 与已安装目录共用）。
fn verify(mut all: BTreeMap<String, Vec<u8>>) -> Result<VerifiedPackage, String> {
    let files_raw = all
        .remove(FILES_JSON)
        .ok_or_else(|| "包里缺 files.json".to_string())?;
    let signature_raw = all.remove(SIGNATURE_JSON);
    let listing: FilesJson =
        serde_json::from_slice(&files_raw).map_err(|e| format!("files.json 解析失败：{e}"))?;
    if listing.files.len() != all.len() || all.keys().any(|k| !listing.files.contains_key(k)) {
        let extra: Vec<&String> = all.keys().filter(|k| !listing.files.contains_key(*k)).collect();
        let missing: Vec<&String> = listing.files.keys().filter(|k| !all.contains_key(*k)).collect();
        return Err(format!(
            "files.json 与包内文件不一致（未登记：{extra:?}；缺失：{missing:?}）"
        ));
    }
    for (path, want) in &listing.files {
        check_rel_path(path)?;
        let bytes = &all[path];
        let got = hex(&Sha256::digest(bytes));
        if !got.eq_ignore_ascii_case(want) {
            return Err(format!("{path} 的哈希不符（文件被改过）"));
        }
    }
    let signer = match &signature_raw {
        None => None,
        Some(raw) => {
            let sig: SignatureJson = serde_json::from_slice(raw)
                .map_err(|e| format!("signature.json 解析失败：{e}"))?;
            let key_bytes: [u8; 32] = BASE64
                .decode(sig.public_key.as_bytes())
                .ok()
                .and_then(|v| v.try_into().ok())
                .ok_or("signature.json 的 publicKey 不是 32 字节 base64")?;
            let sig_bytes: [u8; 64] = BASE64
                .decode(sig.signature.as_bytes())
                .ok()
                .and_then(|v| v.try_into().ok())
                .ok_or("signature.json 的 signature 不是 64 字节 base64")?;
            let key = VerifyingKey::from_bytes(&key_bytes).map_err(|e| format!("公钥无效：{e}"))?;
            key.verify(&files_raw, &Signature::from_bytes(&sig_bytes))
                .map_err(|_| "签名校验失败".to_string())?;
            Some(sig.public_key)
        }
    };
    let manifest_raw = all
        .get(MANIFEST_JSON)
        .ok_or_else(|| "包里缺 manifest.json".to_string())?;
    let manifest = Manifest::parse(manifest_raw)?;
    if !all.contains_key(&manifest.entry) {
        return Err(format!("入口 {} 不在包里", manifest.entry));
    }
    Ok(VerifiedPackage {
        manifest,
        files: all,
        digest: hex(&Sha256::digest(&files_raw)),
        signer,
        files_raw,
        signature_raw,
    })
}

/// 校验一个 zip 包（不写盘）。
pub fn inspect_zip(bytes: &[u8]) -> Result<VerifiedPackage, String> {
    if bytes.len() as u64 > MAX_TOTAL_BYTES {
        return Err("插件包超过 16 MiB".into());
    }
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|e| format!("不是有效的 zip：{e}"))?;
    if zip.len() > MAX_FILES + 2 {
        return Err("插件包文件过多".into());
    }
    let mut all = BTreeMap::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| format!("读 zip 条目失败：{e}"))?;
        if entry.is_dir() {
            continue;
        }
        if entry.is_symlink() {
            return Err("插件包不得含符号链接".into());
        }
        let name = entry.name().to_string();
        check_rel_path(&name)?;
        if entry.size() > MAX_FILE_BYTES {
            return Err(format!("{name} 超过 4 MiB"));
        }
        let mut buf = Vec::new();
        // 声明的大小不可信（压缩炸弹）：读到上限 +1 就停。
        (&mut entry)
            .take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut buf)
            .map_err(|e| format!("解压 {name} 失败：{e}"))?;
        if buf.len() as u64 > MAX_FILE_BYTES {
            return Err(format!("{name} 超过 4 MiB"));
        }
        total += buf.len() as u64;
        if total > MAX_TOTAL_BYTES {
            return Err("插件包解压后超过 16 MiB".into());
        }
        if all.insert(name.clone(), buf).is_some() {
            return Err(format!("zip 里有重复条目 {name}"));
        }
    }
    verify(all)
}

/// 安装：校验 zip，要求其摘要等于用户确认过的 [expected_digest]，原子替换 `<root>/<id>/`。
pub fn install_zip(
    bytes: &[u8],
    root: &Path,
    expected_digest: &str,
) -> Result<VerifiedPackage, String> {
    let pkg = inspect_zip(bytes)?;
    if !pkg.digest.eq_ignore_ascii_case(expected_digest) {
        return Err("插件包与确认安装时的不是同一份".into());
    }
    let id = &pkg.manifest.id;
    fs::create_dir_all(root).map_err(|e| format!("建插件目录失败：{e}"))?;
    let staging = root.join(format!("{id}.staging"));
    let target = root.join(id);
    let backup = root.join(format!("{id}.old"));
    let _ = fs::remove_dir_all(&staging);
    let _ = fs::remove_dir_all(&backup);
    let write = || -> std::io::Result<()> {
        for (path, data) in &pkg.files {
            let dest = staging.join(path);
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(dest, data)?;
        }
        // 两个元文件也落盘：加载时重新校验靠它们。
        fs::write(staging.join(FILES_JSON), &pkg.files_raw)?;
        if let Some(sig) = &pkg.signature_raw {
            fs::write(staging.join(SIGNATURE_JSON), sig)?;
        }
        Ok(())
    };
    if let Err(e) = write() {
        let _ = fs::remove_dir_all(&staging);
        return Err(format!("写插件文件失败：{e}"));
    }
    if target.exists() {
        fs::rename(&target, &backup).map_err(|e| format!("替换旧版本失败：{e}"))?;
    }
    if let Err(e) = fs::rename(&staging, &target) {
        let _ = fs::rename(&backup, &target);
        return Err(format!("启用新版本失败：{e}"));
    }
    let _ = fs::remove_dir_all(&backup);
    // 落盘后按加载路径再核一遍，确保装上的就是校验过的。
    load_dir(&target)
}

/// 从已安装目录加载并重新校验（只读 files.json 登记的文件 + 两个元文件）。
pub fn load_dir(dir: &Path) -> Result<VerifiedPackage, String> {
    let read = |p: PathBuf| -> Result<Vec<u8>, String> {
        let meta =
            fs::symlink_metadata(&p).map_err(|e| format!("读 {} 失败：{e}", p.display()))?;
        if !meta.is_file() {
            return Err(format!("{} 不是普通文件", p.display()));
        }
        if meta.len() > MAX_FILE_BYTES {
            return Err(format!("{} 超过 4 MiB", p.display()));
        }
        fs::read(&p).map_err(|e| format!("读 {} 失败：{e}", p.display()))
    };
    let files_raw = read(dir.join(FILES_JSON))?;
    let listing: FilesJson =
        serde_json::from_slice(&files_raw).map_err(|e| format!("files.json 解析失败：{e}"))?;
    if listing.files.len() > MAX_FILES {
        return Err("插件文件过多".into());
    }
    let mut all = BTreeMap::new();
    all.insert(FILES_JSON.to_string(), files_raw);
    let sig = dir.join(SIGNATURE_JSON);
    if sig.exists() {
        all.insert(SIGNATURE_JSON.to_string(), read(sig)?);
    }
    for path in listing.files.keys() {
        check_rel_path(path)?;
        all.insert(path.clone(), read(dir.join(path))?);
    }
    verify(all)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use std::io::Write;

    pub(crate) fn manifest_with(caps: &[&str], perms: &[&str], domains: &[&str]) -> String {
        let mut m = serde_json::json!({
            "schema": 1, "id": "moe.test", "name": "Test", "version": "0.1.0", "api": 1,
            "entry": "main.js", "capabilities": caps, "permissions": perms,
            "network": {"domains": domains, "methods": ["GET", "POST"]}
        });
        if caps.contains(&"search") {
            m["searchTypes"] = serde_json::json!(["song"]);
        }
        m.to_string()
    }

    pub(crate) enum Sign<'a> {
        None,
        Good(&'a SigningKey),
        Wrong(&'a SigningKey),
    }

    pub(crate) fn build_zip(files: &[(&str, &[u8])], sign: Sign, tamper: Option<&str>) -> Vec<u8> {
        let mut listing = serde_json::Map::new();
        for (p, d) in files {
            listing.insert(p.to_string(), hex(&Sha256::digest(d)).into());
        }
        let files_json = serde_json::json!({ "files": listing }).to_string();
        let mut buf = std::io::Cursor::new(Vec::new());
        {
            let mut z = zip::ZipWriter::new(&mut buf);
            let o = zip::write::SimpleFileOptions::default();
            for (p, d) in files {
                z.start_file(*p, o).unwrap();
                if tamper == Some(*p) {
                    z.write_all(b"tampered").unwrap();
                } else {
                    z.write_all(d).unwrap();
                }
            }
            z.start_file(FILES_JSON, o).unwrap();
            z.write_all(files_json.as_bytes()).unwrap();
            let signed = match sign {
                Sign::None => None,
                Sign::Good(k) => Some((k, k.sign(files_json.as_bytes()))),
                Sign::Wrong(k) => Some((k, k.sign(b"something else"))),
            };
            if let Some((k, sig)) = signed {
                let sj = serde_json::json!({
                    "publicKey": BASE64.encode(k.verifying_key().as_bytes()),
                    "signature": BASE64.encode(&sig.to_bytes()),
                });
                z.start_file(SIGNATURE_JSON, o).unwrap();
                z.write_all(sj.to_string().as_bytes()).unwrap();
            }
            z.finish().unwrap();
        }
        buf.into_inner()
    }

    #[test]
    fn inspect_install_load_roundtrip() {
        let m = manifest_with(&["lyrics"], &[], &[]);
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let zip = build_zip(
            &[("manifest.json", m.as_bytes()), ("main.js", b"module.exports={}")],
            Sign::Good(&key),
            None,
        );
        let pkg = inspect_zip(&zip).unwrap();
        assert_eq!(pkg.manifest.id, "moe.test");
        assert!(pkg.signer.is_some());
        let dir = std::env::temp_dir().join(format!("fmp-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        assert!(install_zip(&zip, &dir, "deadbeef").is_err());
        let installed = install_zip(&zip, &dir, &pkg.digest).unwrap();
        assert_eq!(installed.digest, pkg.digest);
        assert_eq!(installed.signer, pkg.signer);
        // 重装（升级）同一 id 覆盖成功。
        install_zip(&zip, &dir, &pkg.digest).unwrap();
        // 篡改已安装文件 → 拒载；多塞一个文件不影响（只读登记过的）。
        fs::write(dir.join("moe.test").join("extra.js"), b"x").unwrap();
        assert!(load_dir(&dir.join("moe.test")).is_ok());
        fs::write(dir.join("moe.test").join("main.js"), b"evil()").unwrap();
        assert!(load_dir(&dir.join("moe.test")).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_tampered_unlisted_and_bad_paths() {
        let m = manifest_with(&["lyrics"], &[], &[]);
        let zip = build_zip(
            &[("manifest.json", m.as_bytes()), ("main.js", b"x")],
            Sign::None,
            Some("main.js"),
        );
        assert!(inspect_zip(&zip).err().unwrap().contains("哈希"));
        for bad in ["../x.js", "a\\b.js", "/abs.js", "a/./b.js", "c:x.js", ""] {
            assert!(check_rel_path(bad).is_err(), "{bad}");
        }
        assert!(check_rel_path("lib/util.js").is_ok());
    }

    #[test]
    fn rejects_bad_signature() {
        let m = manifest_with(&["lyrics"], &[], &[]);
        let key = SigningKey::from_bytes(&[1u8; 32]);
        let zip = build_zip(
            &[("manifest.json", m.as_bytes()), ("main.js", b"x")],
            Sign::Wrong(&key),
            None,
        );
        assert_eq!(inspect_zip(&zip).err().unwrap(), "签名校验失败");
        let mut zip = build_zip(&[("manifest.json", m.as_bytes()), ("main.js", b"x")], Sign::None, None);
        zip.truncate(zip.len() / 2);
        assert!(inspect_zip(&zip).is_err());
    }
}
