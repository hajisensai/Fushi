//! 格式升级后的一次性整理（srs.db v17，2026-10-30 磁盘占用）。
//!
//! v16 / v17 把冗余挪出了存储（索引、配置快照原文、投影原文），腾出来的页只进空闲链表，文件不会自己变小。升级
//! 阶梯在事务里给 `srs_meta` 记一个 [PENDING]；打开时（写连接上、读连接还没开）在这里做一次 `VACUUM`。
//!
//! - 空间：WAL 模式下 VACUUM 先把整理后的库写进临时文件，再经 WAL 写回，峰值约多占「两倍有效数据」。库所在卷的
//!   空闲空间不够 `2 × 有效数据 + 余量` 就不做，原因记进 `srs_meta` 的 [LAST]，标记留着，下次打开再试。
//! - 临时文件放在库所在目录（`temp_store_directory`）：Android 等平台没有可写的默认临时目录。整理副本落文件
//!   （不落内存）靠构建参数 `SQLITE_TEMP_STORE=1`，见 [set_temp_dir]。
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

/// 让 SQLite 的临时文件（大排序溢出、建索引、VACUUM / VACUUM INTO 的整理副本）落在 [dir]（库所在目录）。
///
/// 临时数据落文件而不是内存靠的是构建参数 `SQLITE_TEMP_STORE=1`（`native/fushi_fsrs/.cargo/config.toml`；
/// libsqlite3-sys 编 Android 默认是 3 = 永远放内存，几 GB 的库一整理 / 一做备份快照就 OOM 闪退）。落文件就得有个
/// 可写的目录：Android 进程没有默认临时目录（无 TMPDIR，`/tmp` 不存在、工作目录是 `/`），不设的话一溢出就报
/// 「unable to open database file」。
///
/// `temp_store_directory` 是进程全局的：
/// - Android：一个进程只开一份 srs.db（在 app 数据根目录，不随 Profile 删），打开时设好就一直留着（[clear_temp_dir]
///   在 Android 上不还原），之后读连接上的备份快照、同步里的大排序也都有地方溢出。
/// - 其它平台有可用的默认临时目录，只在用得着的那一段设、用完还原，不把一个可能被删掉的目录（测试的临时库）留给别的库。
pub(crate) fn set_temp_dir(c: &Connection, dir: &Path) {
    let dir_text = dir.to_string_lossy().replace('\'', "''");
    let _ = c.execute_batch(&format!("PRAGMA temp_store_directory = '{dir_text}';"));
}

/// 还原 [set_temp_dir]（回到平台默认）。Android 没有平台默认可回，不还原（见 [set_temp_dir]）。
pub(crate) fn clear_temp_dir(c: &Connection) {
    if cfg!(target_os = "android") {
        return;
    }
    let _ = c.execute_batch("PRAGMA temp_store_directory = '';");
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
    set_temp_dir(c, dir);
    let out = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;");
    clear_temp_dir(c);
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

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    /// 编进来的 SQLite 临时数据落文件（`SQLITE_TEMP_STORE=1`）。libsqlite3-sys 编 Android 默认 3 = 永远放内存，几 GB 的
    /// srs.db 一做备份快照（VACUUM INTO + VACUUM）/ 整理就把整份数据搬进内存、Scudo OOM 闪退（小米平板 5 实测）。
    /// 主机上跑这条只能证明覆盖参数被接受、结果是 1；Android 产物上的效果由下一条钉住配置、真机复测兜底。
    #[test]
    fn temp_store_compiled_to_files() {
        let c = Connection::open_in_memory().unwrap();
        let opts: Vec<String> = c
            .prepare("PRAGMA compile_options")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(opts.iter().any(|o| o == "TEMP_STORE=1"), "compile_options: {opts:?}");
    }

    /// 覆盖参数写在 crate 目录的 cargo 配置里（所有构建脚本都在本目录跑 cargo）：先 -U 掉 libsqlite3-sys 给 Android
    /// 加的 3，再定成 1。删了它 Android 包就退回全内存临时存储。
    #[test]
    fn cargo_config_overrides_android_temp_store() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/.cargo/config.toml");
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        assert!(
            text.contains("LIBSQLITE3_FLAGS = \"-USQLITE_TEMP_STORE -DSQLITE_TEMP_STORE=1\""),
            "{path} 缺 LIBSQLITE3_FLAGS 覆盖"
        );
    }
}
