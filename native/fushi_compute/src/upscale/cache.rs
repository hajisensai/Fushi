//! 超分结果的磁盘 LRU：`<目录>/<sha256(键)>.jpg`，按字节上限淘汰最久没用的。启动时扫目录按修改时间
//! 重建顺序；命中时把文件修改时间刷成现在，所以 LRU 顺序跨进程保留。

use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use sha2::{Digest, Sha256};

pub(crate) struct DiskCache {
    dir: PathBuf,
    limit: u64,
    /// 最久没用的在前。
    entries: Vec<(String, u64)>,
    total: u64,
}

impl DiskCache {
    pub(crate) fn open(dir: &Path, limit: u64) -> std::io::Result<Self> {
        fs::create_dir_all(dir)?;
        let mut found: Vec<(SystemTime, String, u64)> = Vec::new();
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let meta = entry.metadata()?;
            if !meta.is_file() {
                continue;
            }
            if name.ends_with(".tmp") {
                let _ = fs::remove_file(entry.path());
                continue;
            }
            if !name.ends_with(".jpg") {
                continue;
            }
            found.push((
                meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                name,
                meta.len(),
            ));
        }
        found.sort();
        let mut cache = Self {
            dir: dir.to_path_buf(),
            limit,
            entries: found.into_iter().map(|(_, n, l)| (n, l)).collect(),
            total: 0,
        };
        cache.total = cache.entries.iter().map(|e| e.1).sum();
        cache.evict();
        Ok(cache)
    }

    pub(crate) fn set_limit(&mut self, limit: u64) {
        self.limit = limit;
        self.evict();
    }

    fn name_of(key: &str) -> String {
        let digest = Sha256::digest(key.as_bytes());
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        format!("{hex}.jpg")
    }

    /// 命中返回文件路径并刷新为最近使用。
    pub(crate) fn get(&mut self, key: &str) -> Option<PathBuf> {
        let name = Self::name_of(key);
        let idx = self.entries.iter().position(|e| e.0 == name)?;
        let path = self.dir.join(&name);
        if !path.is_file() {
            let (_, len) = self.entries.remove(idx);
            self.total -= len;
            return None;
        }
        let entry = self.entries.remove(idx);
        self.entries.push(entry);
        if let Ok(f) = fs::File::options().write(true).open(&path) {
            let _ = f.set_modified(SystemTime::now());
        }
        Some(path)
    }

    pub(crate) fn contains(&self, key: &str) -> bool {
        let name = Self::name_of(key);
        self.entries.iter().any(|e| e.0 == name)
    }

    /// 写入（先写临时文件再改名，读者不会看到半截文件）。
    pub(crate) fn put(&mut self, key: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
        let name = Self::name_of(key);
        let path = self.dir.join(&name);
        let tmp = self.dir.join(format!("{name}.tmp"));
        fs::write(&tmp, bytes)?;
        fs::rename(&tmp, &path)?;
        if let Some(idx) = self.entries.iter().position(|e| e.0 == name) {
            let (_, len) = self.entries.remove(idx);
            self.total -= len;
        }
        self.entries.push((name, bytes.len() as u64));
        self.total += bytes.len() as u64;
        self.evict();
        Ok(path)
    }

    fn evict(&mut self) {
        while self.total > self.limit && self.entries.len() > 1 {
            let (name, len) = self.entries.remove(0);
            let _ = fs::remove_file(self.dir.join(&name));
            self.total -= len;
        }
    }

    #[cfg(test)]
    pub(crate) fn total(&self) -> u64 {
        self.total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("fushi-upscale-cache-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn evicts_least_recently_used_and_survives_reopen() {
        let dir = temp_dir("lru");
        let mut c = DiskCache::open(&dir, 25).unwrap();
        c.put("a", &[1; 10]).unwrap();
        c.put("b", &[2; 10]).unwrap();
        assert!(c.get("a").is_some()); // a 变成最近使用
        c.put("c", &[3; 10]).unwrap(); // 超限：淘汰 b
        assert!(c.contains("a") && c.contains("c") && !c.contains("b"));
        assert_eq!(c.total(), 20);
        let bytes = fs::read(c.get("c").unwrap()).unwrap();
        assert_eq!(bytes, vec![3; 10]);
        drop(c);
        fs::write(dir.join("junk.jpg.tmp"), b"x").unwrap();
        let mut again = DiskCache::open(&dir, 25).unwrap();
        assert!(again.get("a").is_some() && again.get("c").is_some());
        assert!(!dir.join("junk.jpg.tmp").exists());
        again.set_limit(10);
        assert_eq!(again.total(), 10);
        let _ = fs::remove_dir_all(&dir);
    }
}
