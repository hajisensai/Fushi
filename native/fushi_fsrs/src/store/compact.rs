//! 格式升级后的一次性整理（srs.db v17，2026-10-30 磁盘占用）。
//!
//! v16 / v17 把冗余挪出了存储（索引、配置快照原文、投影原文），腾出来的页只进空闲链表，文件不会自己变小。升级
//! 阶梯在事务里给 `srs_meta` 记一个 [PENDING]；打开时（写连接上、读连接还没开）在这里做一次 `VACUUM`。
//!
//! - 空间：WAL 模式下 VACUUM 先把整理后的库写进临时文件，再经 WAL 写回，峰值约多占「两倍有效数据」。库所在卷的
//!   空闲空间不够 `2 × 有效数据 + 余量` 就不做，原因记进 `srs_meta` 的 [LAST]，标记留着，下次打开再试。
//! - 临时文件放在库所在目录（`temp_store_directory`）：Android 等平台没有可写的默认临时目录。
//! - 失败（磁盘满、被别的连接占着）不影响打开：VACUUM 本身是原子的，失败时库不变；截断 WAL、记原因、下次再试。

use std::path::Path;

use rusqlite::Connection;
use serde_json::json;

/// 待整理标记（升级阶梯写，整理成功后删）。
pub(crate) const PENDING: &str = "compact_pending";
/// 最近一次整理的结果（JSON；排查用）。
pub(crate) const LAST: &str = "compact_last";
/// 空间余量。
const MARGIN: u64 = 64 << 20;

fn pragma(c: &Connection, name: &str) -> rusqlite::Result<u64> {
    c.query_row(&format!("PRAGMA {name}"), [], |r| r.get::<_, i64>(0)).map(|v| v.max(0) as u64)
}

fn record(c: &Connection, v: serde_json::Value) {
    eprintln!("srs.db compact: {v}");
    let _ = c.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [LAST, &v.to_string()],
    );
}

/// 有 [PENDING] 就整理一次。[free] 是库所在卷的空闲字节（拿不到为 None：照样试，失败按上面的路径处理）。
/// 返回是否整理了。
pub(crate) fn run(c: &Connection, dir: &Path, free: Option<u64>, now: i64) -> bool {
    let pending = c.query_row("SELECT 1 FROM srs_meta WHERE key = ?1", [PENDING], |_| Ok(())).is_ok();
    if !pending {
        return false;
    }
    let (Ok(size), Ok(pages), Ok(spare)) = (pragma(c, "page_size"), pragma(c, "page_count"), pragma(c, "freelist_count")) else {
        return false;
    };
    let before = size * pages;
    let live = size * pages.saturating_sub(spare);
    let need = live.saturating_mul(2).saturating_add(MARGIN);
    if let Some(free) = free.filter(|&f| f < need) {
        record(c, json!({"at": now, "ok": false, "reason": "disk", "need": need, "free": free, "bytes": before}));
        return false;
    }
    let dir_text = dir.to_string_lossy().replace('\'', "''");
    let _ = c.execute_batch(&format!("PRAGMA temp_store_directory = '{dir_text}';"));
    let out = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;");
    let _ = c.execute_batch("PRAGMA temp_store_directory = '';");
    // 成功时把整理后的页写回主文件、WAL 归零；失败时丢掉 VACUUM 写进 WAL 又回滚掉的那些帧占的空间。
    let _ = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    match out {
        Ok(()) => {
            let after = pragma(c, "page_count").unwrap_or(0) * size;
            let _ = c.execute("DELETE FROM srs_meta WHERE key = ?1", [PENDING]);
            record(c, json!({"at": now, "ok": true, "before": before, "after": after}));
            true
        }
        Err(e) => {
            record(c, json!({"at": now, "ok": false, "reason": e.to_string(), "bytes": before}));
            false
        }
    }
}

/// [path] 所在卷的可用空间。
pub(crate) fn free_bytes(path: &Path) -> Option<u64> {
    let dir = if path.is_dir() { path } else { path.parent()? };
    imp::free(dir)
}

#[cfg(windows)]
mod imp {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetDiskFreeSpaceExW(dir: *const u16, avail: *mut u64, total: *mut u64, free: *mut u64) -> i32;
    }

    pub(super) fn free(dir: &Path) -> Option<u64> {
        let wide: Vec<u16> = dir.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        let (mut avail, mut total, mut free) = (0u64, 0u64, 0u64);
        // SAFETY: wide 以 0 结尾；三个输出指针指向本函数里的局部变量。
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut avail, &mut total, &mut free) };
        (ok != 0).then_some(avail)
    }
}

#[cfg(unix)]
mod imp {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    pub(super) fn free(dir: &Path) -> Option<u64> {
        let c = CString::new(dir.as_os_str().as_bytes()).ok()?;
        // SAFETY: c 以 0 结尾；st 是本函数里的局部变量，statvfs 只写它。
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
        (rc == 0).then(|| (st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
    }
}

#[cfg(not(any(windows, unix)))]
mod imp {
    pub(super) fn free(_dir: &std::path::Path) -> Option<u64> {
        None
    }
}
