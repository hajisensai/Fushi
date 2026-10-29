//! 插件凭据保险库（`fushi.credentials`，契约见 docs/specs/2026-10-28-music-plugins.md §3）。
//!
//! - 每个插件一个文件 `<root>/.credentials/<插件 id>.json`：`{"<sha256(键名) 十六进制>":
//!   "<base64(nonce 12B || AES-256-GCM 密文)>"}`。键名不落盘明文。
//! - 附加认证数据 = `fushi-music-plugin-credential-v1\0<插件 id>\0<键名>`：把密文拷到别的插件或
//!   别的键名下解不开（命名空间由密码学保证，而不只是由文件名保证）。
//! - 数据密钥 32 字节随机，存 `<root>/.credentials/key`：Windows 用 DPAPI（当前用户）封装；其它平台
//!   退为明文密钥文件（Unix 上 0600）。**威胁模型**：防凭据文件 / 备份被单独拷走后直接恢复登录，
//!   不防本机同用户的恶意程序（DPAPI 本身就是用户 / 会话级边界）。
//!
//! 密钥文件丢失或无法解封（换了 Windows 账户）时，所有插件凭据作废：读返回空、写生成新密钥，
//! 插件表现为「未登录」，用户重新登录即可——不会因此报错卡住。

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use data_encoding::{BASE64, HEXLOWER};
use sha2::{Digest, Sha256};

use crate::plugin::manifest::valid_id;

const DIR: &str = ".credentials";
const KEY_FILE: &str = "key";
const AAD_DOMAIN: &str = "fushi-music-plugin-credential-v1";
pub const MAX_VALUE_BYTES: usize = 64 * 1024;
const MAX_ENTRIES: usize = 64;

fn dir(root: &Path) -> PathBuf {
    root.join(DIR)
}

fn plugin_file(root: &Path, plugin: &str) -> PathBuf {
    dir(root).join(format!("{plugin}.json"))
}

fn key_id(key: &str) -> String {
    HEXLOWER.encode(&Sha256::digest(key.as_bytes()))
}

fn aad(plugin: &str, key: &str) -> Vec<u8> {
    format!("{AAD_DOMAIN}\0{plugin}\0{key}").into_bytes()
}

/// 进程内保险库锁：宿主在后台 isolate（各自的 OS 线程）里并发调用 get / set / remove，
/// `set` 是「读条目 → 改 → 整文件写回」，首次 `set` 还要生成数据密钥并清掉旧密文。不加锁时
/// 两个并发的首次 `set` 会各自生成密钥、后者删掉前者刚写的条目，同一插件的两次 `set` 也会
/// 互相丢写。所有操作在这把锁下串行（锁里只有文件读写与 AES，持有时间很短）。
static VAULT_LOCK: Mutex<()> = Mutex::new(());

fn lock() -> MutexGuard<'static, ()> {
    // 持锁线程 panic 只会发生在 FFI 的 catch_unwind 之内；数据都在磁盘上，锁本身无状态可坏。
    VAULT_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    // 临时文件名带进程号与序号：同一目录下别的进程（多开 / 弹窗入口）写同名文件时不会共用
    // 一个 .tmp。
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("{}.{seq}.tmp", std::process::id()));
    let write = || -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        }
        fs::rename(&tmp, path)
    };
    write().map_err(|e| format!("写凭据文件失败：{e}"))
}

#[cfg(windows)]
mod protect {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    const ENTROPY: &[u8] = b"fushi-music-plugin-vault-key-v1";

    fn run(input: &[u8], seal: bool) -> Option<Vec<u8>> {
        let mut entropy = ENTROPY.to_vec();
        let mut data = input.to_vec();
        let in_blob = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_mut_ptr(),
        };
        let ent_blob = CRYPT_INTEGER_BLOB {
            cbData: entropy.len() as u32,
            pbData: entropy.as_mut_ptr(),
        };
        let mut out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        // SAFETY: 输入 blob 指向本函数持有的缓冲区；输出由系统分配，拷出后 LocalFree。
        let ok = unsafe {
            if seal {
                CryptProtectData(
                    &in_blob,
                    std::ptr::null(),
                    &ent_blob,
                    std::ptr::null(),
                    std::ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut out,
                )
            } else {
                CryptUnprotectData(
                    &in_blob,
                    std::ptr::null_mut(),
                    &ent_blob,
                    std::ptr::null(),
                    std::ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut out,
                )
            }
        };
        if ok == 0 || out.pbData.is_null() {
            return None;
        }
        // SAFETY: 系统保证 pbData 指向 cbData 字节。
        let v = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec() };
        unsafe { LocalFree(out.pbData as _) };
        Some(v)
    }

    pub fn seal(key: &[u8]) -> Option<Vec<u8>> {
        run(key, true)
    }

    pub fn unseal(blob: &[u8]) -> Option<Vec<u8>> {
        run(blob, false)
    }

    pub const SCHEME: &str = "dpapi";
}

#[cfg(not(windows))]
mod protect {
    pub fn seal(key: &[u8]) -> Option<Vec<u8>> {
        Some(key.to_vec())
    }

    pub fn unseal(blob: &[u8]) -> Option<Vec<u8>> {
        Some(blob.to_vec())
    }

    pub const SCHEME: &str = "file";
}

/// 读数据密钥；没有 / 解不开时 [create] = true 就生成新的（旧凭据随之作废），否则返回 None。
fn data_key(root: &Path, create: bool) -> Result<Option<[u8; 32]>, String> {
    let path = dir(root).join(KEY_FILE);
    if let Ok(raw) = fs::read(&path) {
        if let Some(rest) = raw.strip_prefix(format!("{}:", protect::SCHEME).as_bytes()) {
            if let Some(key) = protect::unseal(rest).and_then(|k| <[u8; 32]>::try_from(k).ok()) {
                return Ok(Some(key));
            }
        }
    }
    if !create {
        return Ok(None);
    }
    fs::create_dir_all(dir(root)).map_err(|e| format!("建凭据目录失败：{e}"))?;
    let mut key = [0u8; 32];
    getrandom::getrandom(&mut key).map_err(|_| "系统随机数不可用".to_string())?;
    let sealed = protect::seal(&key).ok_or("系统拒绝保护凭据密钥")?;
    let mut out = format!("{}:", protect::SCHEME).into_bytes();
    out.extend_from_slice(&sealed);
    write_atomic(&path, &out)?;
    // 新密钥下旧密文全都解不开：清掉，免得留着永远读不出的残渣。
    if let Ok(entries) = fs::read_dir(dir(root)) {
        for e in entries.flatten() {
            if e.path().extension().is_some_and(|x| x == "json") {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    Ok(Some(key))
}

fn read_entries(root: &Path, plugin: &str) -> BTreeMap<String, String> {
    fs::read(plugin_file(root, plugin))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn check_args(plugin: &str, key: &str) -> Result<(), String> {
    if !valid_id(plugin) {
        return Err("插件 id 不合法".into());
    }
    if key.is_empty() || key.len() > 256 {
        return Err("凭据键名为空或过长".into());
    }
    Ok(())
}

pub fn get(root: &Path, plugin: &str, key: &str) -> Result<Option<String>, String> {
    check_args(plugin, key)?;
    let _guard = lock();
    let Some(dk) = data_key(root, false)? else {
        return Ok(None);
    };
    let Some(blob) = read_entries(root, plugin).remove(&key_id(key)) else {
        return Ok(None);
    };
    let Ok(raw) = BASE64.decode(blob.as_bytes()) else {
        return Ok(None);
    };
    if raw.len() < 12 + 16 {
        return Ok(None);
    }
    let cipher = Aes256Gcm::new_from_slice(&dk).unwrap();
    let aad = aad(plugin, key);
    // 认证失败（被篡改 / 拷错命名空间）按「没有」处理：插件表现为未登录。
    Ok(cipher
        .decrypt(
            Nonce::from_slice(&raw[..12]),
            Payload {
                msg: &raw[12..],
                aad: &aad,
            },
        )
        .ok()
        .and_then(|p| String::from_utf8(p).ok()))
}

pub fn set(root: &Path, plugin: &str, key: &str, value: &str) -> Result<(), String> {
    check_args(plugin, key)?;
    let _guard = lock();
    if value.len() > MAX_VALUE_BYTES {
        return Err("凭据超过 64 KiB".into());
    }
    let dk = data_key(root, true)?.expect("create = true");
    let mut entries = read_entries(root, plugin);
    let id = key_id(key);
    if !entries.contains_key(&id) && entries.len() >= MAX_ENTRIES {
        return Err("凭据条目过多".into());
    }
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce).map_err(|_| "系统随机数不可用".to_string())?;
    let cipher = Aes256Gcm::new_from_slice(&dk).unwrap();
    let aad = aad(plugin, key);
    let ct = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: value.as_bytes(),
                aad: &aad,
            },
        )
        .map_err(|_| "加密失败".to_string())?;
    let mut blob = nonce.to_vec();
    blob.extend_from_slice(&ct);
    entries.insert(id, BASE64.encode(&blob));
    write_atomic(
        &plugin_file(root, plugin),
        serde_json::to_string(&entries).unwrap().as_bytes(),
    )
}

pub fn remove(root: &Path, plugin: &str, key: &str) -> Result<(), String> {
    check_args(plugin, key)?;
    let _guard = lock();
    let mut entries = read_entries(root, plugin);
    if entries.remove(&key_id(key)).is_none() {
        return Ok(());
    }
    write_atomic(
        &plugin_file(root, plugin),
        serde_json::to_string(&entries).unwrap().as_bytes(),
    )
}

/// 删掉某插件的全部凭据（卸载 / 退出登录兜底）。
pub fn clear(root: &Path, plugin: &str) -> Result<(), String> {
    if !valid_id(plugin) {
        return Err("插件 id 不合法".into());
    }
    let _guard = lock();
    match fs::remove_file(plugin_file(root, plugin)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("删除凭据失败：{e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_namespacing_and_tamper() {
        let root = std::env::temp_dir().join(format!("fmp-vault-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        assert_eq!(get(&root, "moe.a", "cookie").unwrap(), None);
        set(&root, "moe.a", "cookie", "MUSIC_U=secret").unwrap();
        set(&root, "moe.b", "cookie", "other").unwrap();
        assert_eq!(
            get(&root, "moe.a", "cookie").unwrap().as_deref(),
            Some("MUSIC_U=secret")
        );
        assert_eq!(
            get(&root, "moe.b", "cookie").unwrap().as_deref(),
            Some("other")
        );
        // 落盘不含明文与键名。
        let raw = fs::read_to_string(plugin_file(&root, "moe.a")).unwrap();
        assert!(!raw.contains("secret") && !raw.contains("cookie"));
        let key_raw = fs::read(dir(&root).join(KEY_FILE)).unwrap();
        assert!(key_raw.starts_with(format!("{}:", protect::SCHEME).as_bytes()));
        // 把 a 的密文拷到 b 名下：认证失败 → 当没有。
        fs::copy(plugin_file(&root, "moe.a"), plugin_file(&root, "moe.b")).unwrap();
        assert_eq!(get(&root, "moe.b", "cookie").unwrap(), None);
        remove(&root, "moe.a", "cookie").unwrap();
        assert_eq!(get(&root, "moe.a", "cookie").unwrap(), None);
        set(&root, "moe.a", "k", "v").unwrap();
        clear(&root, "moe.a").unwrap();
        assert_eq!(get(&root, "moe.a", "k").unwrap(), None);
        // 密钥坏了：读当没有，写生成新密钥并清掉旧密文。
        set(&root, "moe.a", "k", "v").unwrap();
        fs::write(dir(&root).join(KEY_FILE), b"garbage").unwrap();
        assert_eq!(get(&root, "moe.a", "k").unwrap(), None);
        set(&root, "moe.c", "k", "v2").unwrap();
        assert_eq!(get(&root, "moe.c", "k").unwrap().as_deref(), Some("v2"));
        assert!(!plugin_file(&root, "moe.a").exists());
        assert!(get(&root, "Bad Id", "k").is_err());
        let _ = fs::remove_dir_all(&root);
    }

    /// 并发首次 set（还没有数据密钥）与同一插件的并发 set：每一条都要留下、读得回来，
    /// 不留 .tmp 残渣。
    #[test]
    fn concurrent_sets_do_not_lose_entries_or_keys() {
        let root = std::env::temp_dir().join(format!("fmp-vault-conc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let threads: Vec<_> = (0..16)
            .map(|i| {
                let root = root.clone();
                std::thread::spawn(move || {
                    let plugin = if i % 2 == 0 { "moe.a" } else { "moe.b" };
                    set(&root, plugin, &format!("k{i}"), &format!("v{i}")).unwrap();
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        for i in 0..16 {
            let plugin = if i % 2 == 0 { "moe.a" } else { "moe.b" };
            assert_eq!(
                get(&root, plugin, &format!("k{i}")).unwrap().as_deref(),
                Some(format!("v{i}").as_str()),
                "k{i}"
            );
        }
        let leftovers: Vec<_> = fs::read_dir(dir(&root))
            .unwrap()
            .flatten()
            .filter(|e| e.path().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
