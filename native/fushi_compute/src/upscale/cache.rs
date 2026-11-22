//! 超分结果的磁盘 LRU：`<目录>/<sha256(键)>.jpg`，按字节上限淘汰最久没用的。启动时扫目录按修改时间
//! 重建顺序；命中时把文件修改时间刷成现在，所以 LRU 顺序跨进程保留。
//!
//! 引擎把它放在状态锁里，所以除 [DiskCache::open] 外**所有方法只动内存**：写文件经 [DiskCache::stage]
//! 拿到的 [PendingPut] 在锁外做，淘汰返回要删的路径由调用方在锁外 [remove_files]，命中后刷修改时间用
//! [refresh_file]（也在锁外）。磁盘慢时 UI isolate 的同步 FFI 不会排在磁盘 I/O 后面。

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

/// 一次待写入：目标文件与临时文件（[DiskCache::stage] 给出，[PendingPut::write] 在锁外写，
/// [DiskCache::commit] 再登记）。
pub(crate) struct PendingPut {
    name: String,
    path: PathBuf,
    tmp: PathBuf,
}

impl PendingPut {
    /// 写入（先写临时文件再改名，读者不会看到半截文件）。不碰缓存状态，调用方在锁外做。
    pub(crate) fn write(&self, bytes: &[u8]) -> std::io::Result<()> {
        fs::write(&self.tmp, bytes)?;
        fs::rename(&self.tmp, &self.path)
    }
}

/// 删掉淘汰下来的文件（调用方在锁外做；删不掉的下次 [DiskCache::open] 会重新登记再淘汰）。
pub(crate) fn remove_files(paths: &[PathBuf]) {
    for path in paths {
        let _ = fs::remove_file(path);
    }
}

/// 命中后把文件修改时间刷成现在（跨进程保留 LRU 顺序）；文件不在返回 false。在锁外调用。
pub(crate) fn refresh_file(path: &Path) -> bool {
    match fs::File::options().write(true).open(path) {
        Ok(f) => {
            let _ = f.set_modified(SystemTime::now());
            true
        }
        Err(_) => path.is_file(),
    }
}

impl DiskCache {
    /// 打开（建目录、扫已有文件、按上限淘汰）。有磁盘 I/O，调用方在锁外做。
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
        let victims = cache.evict();
        remove_files(&victims);
        Ok(cache)
    }

    /// 改上限；返回要删的文件（调用方在锁外 [remove_files]）。
    #[must_use]
    pub(crate) fn set_limit(&mut self, limit: u64) -> Vec<PathBuf> {
        self.limit = limit;
        self.evict()
    }

    fn name_of(key: &str) -> String {
        let digest = Sha256::digest(key.as_bytes());
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        format!("{hex}.jpg")
    }

    /// 命中返回文件路径并在内存里刷新为最近使用（刷文件修改时间由调用方在锁外 [refresh_file]）。
    pub(crate) fn touch(&mut self, key: &str) -> Option<PathBuf> {
        let name = Self::name_of(key);
        let idx = self.entries.iter().position(|e| e.0 == name)?;
        let entry = self.entries.remove(idx);
        self.entries.push(entry);
        Some(self.dir.join(&name))
    }

    /// 文件不在了（被外部删掉）：条目作废。
    pub(crate) fn forget(&mut self, key: &str) {
        let name = Self::name_of(key);
        if let Some(idx) = self.entries.iter().position(|e| e.0 == name) {
            let (_, len) = self.entries.remove(idx);
            self.total -= len;
        }
    }

    pub(crate) fn contains(&self, key: &str) -> bool {
        let name = Self::name_of(key);
        self.entries.iter().any(|e| e.0 == name)
    }

    /// 准备写入 `key`：只算路径，不碰磁盘。
    pub(crate) fn stage(&self, key: &str) -> PendingPut {
        let name = Self::name_of(key);
        PendingPut {
            path: self.dir.join(&name),
            tmp: self.dir.join(format!("{name}.tmp")),
            name,
        }
    }

    /// 登记一次已写完的 [PendingPut]（`len` 字节）；返回要删的淘汰文件（调用方在锁外 [remove_files]）。
    #[must_use]
    pub(crate) fn commit(&mut self, pending: PendingPut, len: u64) -> Vec<PathBuf> {
        if let Some(idx) = self.entries.iter().position(|e| e.0 == pending.name) {
            let (_, old) = self.entries.remove(idx);
            self.total -= old;
        }
        self.entries.push((pending.name, len));
        self.total += len;
        self.evict()
    }

    /// 超限时从最久没用的起摘掉条目（至少留一个），返回它们的文件路径。
    fn evict(&mut self) -> Vec<PathBuf> {
        let mut victims = Vec::new();
        while self.total > self.limit && self.entries.len() > 1 {
            let (name, len) = self.entries.remove(0);
            victims.push(self.dir.join(&name));
            self.total -= len;
        }
        victims
    }

    /// 测试用：一次写完（stage → write → commit → 删淘汰）。
    #[cfg(test)]
    pub(crate) fn put(&mut self, key: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
        let pending = self.stage(key);
        pending.write(bytes)?;
        let path = pending.path.clone();
        let victims = self.commit(pending, bytes.len() as u64);
        remove_files(&victims);
        Ok(path)
    }

    /// 测试用：命中返回路径并刷新最近使用（同引擎的 touch + refresh_file）。
    #[cfg(test)]
    pub(crate) fn get(&mut self, key: &str) -> Option<PathBuf> {
        let path = self.touch(key)?;
        if refresh_file(&path) {
            Some(path)
        } else {
            self.forget(key);
            None
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
        assert!(!c.stage("b").path.exists(), "evicted file is deleted");
        assert_eq!(c.total(), 20);
        let bytes = fs::read(c.get("c").unwrap()).unwrap();
        assert_eq!(bytes, vec![3; 10]);
        drop(c);
        fs::write(dir.join("junk.jpg.tmp"), b"x").unwrap();
        let mut again = DiskCache::open(&dir, 25).unwrap();
        assert!(again.get("a").is_some() && again.get("c").is_some());
        assert!(!dir.join("junk.jpg.tmp").exists());
        let victims = again.set_limit(10);
        assert_eq!(again.total(), 10);
        assert_eq!(victims.len(), 1);
        assert!(victims[0].exists(), "set_limit itself does no disk I/O");
        remove_files(&victims);
        assert!(!victims[0].exists());
        let _ = fs::remove_dir_all(&dir);
    }

    /// 文件被外部删掉：命中查询作废条目。
    #[test]
    fn vanished_file_is_forgotten_on_lookup() {
        let dir = temp_dir("vanish");
        let mut c = DiskCache::open(&dir, 1 << 20).unwrap();
        let path = c.put("a", &[1; 4]).unwrap();
        fs::remove_file(&path).unwrap();
        assert!(c.get("a").is_none());
        assert!(!c.contains("a"));
        assert_eq!(c.total(), 0);
        let _ = fs::remove_dir_all(&dir);
    }
}
