//! 格式升级后的一次性整理（srs.db v17，2026-10-30 磁盘占用；BUG-3928 改成低占用）。
//!
//! v16–v18 把冗余挪出了存储（索引、配置快照原文、投影原文），腾出来的页只进空闲链表，文件不会自己变小。升级
//! 阶梯在事务里给 `srs_meta` 记一个 [PENDING]；打开时（写连接上、读连接还没开）在这里整理一次。两条路：
//!
//! - **原地收缩**（库已是 `auto_vacuum = INCREMENTAL`）：`PRAGMA incremental_vacuum` 分块把尾部的页挪进空闲位置、截短
//!   文件，每块后截断 WAL。额外空间只有一块的 WAL（[CHUNK]）；每块各自提交，中途被杀也只是少收缩一些。
//! - **重写换文件**（老库 `auto_vacuum = NONE`）：`VACUUM INTO` 把整理后的库直接写成旁边的 `<库>.compact`（顺带改成
//!   INCREMENTAL，以后走上一条），fsync 后关掉写连接、原子重命名换上去。额外空间约「一倍有效数据」（原地 `VACUUM`
//!   要先写临时副本再经 WAL 写回，约两倍），也不建临时库：不吃内存（libsqlite3-sys 给 Android 编了
//!   `SQLITE_TEMP_STORE=3`，临时库全进内存，GB 级的库原地 VACUUM 就把进程撑到 SIGABRT）。
//!   - 写之前把 WAL 检查点截断到 0；换之前确认关掉写连接后 WAL 已被删（还在 = 还有别的连接开着这个库，它们会继续
//!     读写被换掉的旧文件），否则不换。
//!   - 换上去之前在新文件里就删掉 [PENDING] / [ATTEMPTS]、写好 [LAST]，换上去的就是整理完的库。
//!   - 任何一步崩溃都安全：重命名之前旧库没动过（WAL 已截断为空），剩下的 `<库>.compact` 下次打开删掉；重命名是原子的。
//!
//! 空闲空间不够就不做，原因记进 `srs_meta` 的 [LAST]，标记留着，下次打开再试。进程死在整理中途的：每次开始前记一次
//! [ATTEMPTS]，正常结束（成功或失败）都清掉；连着 [MAX_ATTEMPTS] 次没结束就放弃这次整理，库照常打开，不陷入打开即崩的
//! 循环。

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde_json::json;

/// 待整理标记（升级阶梯写，整理成功后删）。
pub(crate) const PENDING: &str = "compact_pending";
/// 最近一次整理的结果（JSON；排查用）。
pub(crate) const LAST: &str = "compact_last";
/// 已开始、还没正常结束的整理次数（开始前 +1，成功或失败都删）。
pub(crate) const ATTEMPTS: &str = "compact_attempts";
/// 连着这么多次进程死在整理中途就放弃。
pub(crate) const MAX_ATTEMPTS: i64 = 2;
/// 空间余量。
pub(crate) const MARGIN: u64 = 64 << 20;
/// 原地收缩每块挪动的字节数（每块后截断 WAL，WAL 峰值约为这么大）。
pub(crate) const CHUNK: u64 = 32 << 20;
/// `PRAGMA auto_vacuum` 的 INCREMENTAL。
const AUTO_VACUUM_INCREMENTAL: u64 = 2;

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

/// 让 SQLite 的临时文件（大排序溢出、建索引、VACUUM 的整理副本）落在 [dir]（库所在目录）。Android 进程没有可写的
/// 默认临时目录（无 TMPDIR，`/tmp` 不存在），不设的话大库升级一溢出到临时文件就报「unable to open database
/// file」。`temp_store_directory` 是进程全局的，所以只在用得着的那一段设、用完 [clear_temp_dir] 还原，不把一个可能
/// 随 Profile 被删掉的目录留给别的库。临时库必须能落文件：`.cargo/config.toml` 把 Android 的 `SQLITE_TEMP_STORE=3`
/// 编回 1，这里再显式 `temp_store = FILE`。
pub(crate) fn set_temp_dir(c: &Connection, dir: &Path) {
    let dir_text = dir.to_string_lossy().replace('\'', "''");
    let _ = c.execute_batch(&format!("PRAGMA temp_store_directory = '{dir_text}'; PRAGMA temp_store = FILE;"));
}

/// 这份 SQLite 是否编成「临时库只能放内存」（`SQLITE_TEMP_STORE=3`：`PRAGMA temp_store` 改不动）。
#[cfg(test)]
pub(crate) fn temp_store_forced_memory(c: &Connection) -> bool {
    let Ok(mut st) = c.prepare("PRAGMA compile_options") else {
        return false;
    };
    let Ok(rows) = st.query_map([], |r| r.get::<_, String>(0)) else {
        return false;
    };
    let forced = rows.flatten().any(|o| o == "TEMP_STORE=3");
    forced
}

/// 整库重写以外的临时库放哪：Android 进程没有可写的默认临时目录，放内存（与改编译选项前一致）；别的平台用默认
/// （文件，系统临时目录）。
#[cfg(target_os = "android")]
pub(crate) const ORDINARY_TEMP_STORE: &str = "PRAGMA temp_store = MEMORY;";
#[cfg(not(target_os = "android"))]
pub(crate) const ORDINARY_TEMP_STORE: &str = "PRAGMA temp_store = DEFAULT;";

/// 还原 [set_temp_dir]（回到平台默认）。
pub(crate) fn clear_temp_dir(c: &Connection) {
    let _ = c.execute_batch("PRAGMA temp_store_directory = '';");
    let _ = c.execute_batch(ORDINARY_TEMP_STORE);
}

/// [path] 加后缀（`srs.db` → `srs.db-wal`）。
fn suffixed(path: &Path, suffix: &str) -> PathBuf {
    let mut s: OsString = path.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

/// 重写换文件时的新库：库旁边的 `<库>.compact`。
pub(crate) fn staged_path(path: &Path) -> PathBuf {
    suffixed(path, ".compact")
}

/// 删掉 [staged]（及其回滚日志）；不存在不算错。
fn remove_staged(staged: &Path) {
    for p in [staged.to_path_buf(), suffixed(staged, "-journal")] {
        let _ = std::fs::remove_file(p);
    }
}

/// 有 [PENDING] 就整理一次（见模块文档）。[c] 是 [path] 的写连接、此时没有别的连接；重写换文件时会关掉它、换完用
/// [reopen] 重新打开，所以拿走它、还回一个（可能是新的）写连接。[free] 是库所在卷的空闲字节（拿不到为 None：照样试，
/// 失败按上面的路径处理）。整理本身的失败只记进 [LAST]；只有换完文件后重新打开失败才返回错误。
pub(crate) fn run(
    c: Connection,
    path: &Path,
    free: Option<u64>,
    now: i64,
    reopen: &dyn Fn() -> Result<Connection, String>,
) -> Result<Connection, String> {
    let staged = staged_path(path);
    // 上次死在重命名之前留下的半成品。
    remove_staged(&staged);
    let pending = c.query_row("SELECT 1 FROM srs_meta WHERE key = ?1", [PENDING], |_| Ok(())).is_ok();
    if !pending {
        return Ok(c);
    }
    let (Ok(size), Ok(pages), Ok(spare), Ok(auto)) =
        (pragma(&c, "page_size"), pragma(&c, "page_count"), pragma(&c, "freelist_count"), pragma(&c, "auto_vacuum"))
    else {
        return Ok(c);
    };
    let before = size * pages;
    let live = size * pages.saturating_sub(spare);
    let in_place = auto == AUTO_VACUUM_INCREMENTAL;
    let need = if in_place { CHUNK } else { live }.saturating_add(MARGIN);
    if let Some(free) = free.filter(|&f| f < need) {
        record(&c, json!({"at": now, "ok": false, "reason": "disk", "need": need, "free": free, "bytes": before}));
        return Ok(c);
    }
    let attempts: i64 = c
        .query_row("SELECT CAST(value AS INTEGER) FROM srs_meta WHERE key = ?1", [ATTEMPTS], |r| r.get(0))
        .unwrap_or(0);
    if attempts >= MAX_ATTEMPTS {
        let _ = c.execute("DELETE FROM srs_meta WHERE key IN (?1, ?2)", [PENDING, ATTEMPTS]);
        record(&c, json!({"at": now, "ok": false, "reason": "interrupted", "attempts": attempts, "bytes": before}));
        return Ok(c);
    }
    // 自动提交：进程死在整理里时这一笔已经落盘（WAL）。
    let marked = c.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![ATTEMPTS, (attempts + 1).to_string()],
    );
    if let Err(e) = marked {
        record(&c, json!({"at": now, "ok": false, "reason": e.to_string(), "bytes": before}));
        return Ok(c);
    }
    if in_place {
        shrink_in_place(&c, size, before, now);
        return Ok(c);
    }
    let rewritten = rewrite_into(&c, &staged, size, before, now);
    // 换文件前旧库上不能有打开的句柄。
    drop(c);
    let out = rewritten.and_then(|()| swap_in(path, &staged));
    if out.is_err() {
        remove_staged(&staged);
    }
    let c = reopen()?;
    if let Err(e) = out {
        let _ = c.execute("DELETE FROM srs_meta WHERE key = ?1", [ATTEMPTS]);
        record(&c, json!({"at": now, "ok": false, "reason": e, "bytes": before}));
    }
    Ok(c)
}

/// 原地收缩：分块 `incremental_vacuum`，每块后截断 WAL，直到空闲链表清空。
fn shrink_in_place(c: &Connection, size: u64, before: u64, now: i64) {
    let chunk = (CHUNK / size.max(1)).max(1);
    let mut out: Result<(), String> = Ok(());
    loop {
        let spare = pragma(c, "freelist_count").unwrap_or(0);
        if spare == 0 {
            break;
        }
        if let Err(e) = c.execute_batch(&format!("PRAGMA incremental_vacuum({chunk}); PRAGMA wal_checkpoint(TRUNCATE);")) {
            out = Err(e.to_string());
            break;
        }
        if pragma(c, "freelist_count").unwrap_or(0) >= spare {
            out = Err("incremental_vacuum made no progress".into());
            break;
        }
    }
    let _ = c.execute("DELETE FROM srs_meta WHERE key = ?1", [ATTEMPTS]);
    match out {
        Ok(()) => {
            let after = pragma(c, "page_count").unwrap_or(0) * size;
            let _ = c.execute("DELETE FROM srs_meta WHERE key = ?1", [PENDING]);
            record(c, json!({"at": now, "ok": true, "mode": "in_place", "before": before, "after": after}));
        }
        Err(e) => record(c, json!({"at": now, "ok": false, "mode": "in_place", "reason": e, "bytes": before})),
    }
}

/// 把整理后的库写成 [staged]（auto_vacuum 改成 INCREMENTAL），在里面清掉标记、记好结果，fsync。
fn rewrite_into(c: &Connection, staged: &Path, size: u64, before: u64, now: i64) -> Result<(), String> {
    let staged_text = staged.to_str().ok_or_else(|| "srs.db path is not UTF-8".to_string())?;
    // WAL 截断到 0：之后旧库的主文件本身就是完整的库，换文件之前任何一步崩溃都不丢东西。有别的连接正读着就截不动，
    // 不整理（没在读的别的连接由 [swap_in] 按关闭后 WAL 是否还在查出来）。
    let (busy, frames, done): (i64, i64, i64) = c
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(|e| e.to_string())?;
    if busy != 0 || done != frames {
        return Err(format!("busy: wal_checkpoint busy={busy} frames={frames} checkpointed={done}"));
    }
    c.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;").map_err(|e| e.to_string())?;
    c.execute("VACUUM INTO ?1", [staged_text]).map_err(|e| e.to_string())?;
    {
        let s = Connection::open(staged).map_err(|e| e.to_string())?;
        let after = pragma(&s, "page_count").map_err(|e| e.to_string())? * size;
        s.execute("DELETE FROM srs_meta WHERE key IN (?1, ?2)", [PENDING, ATTEMPTS]).map_err(|e| e.to_string())?;
        record(&s, json!({"at": now, "ok": true, "mode": "rewrite", "before": before, "after": after}));
    }
    // Windows 的 FlushFileBuffers 要写权限：只读句柄上 sync_all 报「拒绝访问」。
    std::fs::OpenOptions::new()
        .write(true)
        .open(staged)
        .and_then(|f| f.sync_all())
        .map_err(|e| format!("sync {}: {e}", staged.display()))
}

/// 关掉旧库的连接之后，把 [staged] 原子换成 [path]。最后一个连接关闭时 SQLite 检查点并删掉 WAL / 共享内存索引；WAL
/// 还在就是还有别的连接开着这个库（它们会继续读写被换掉的旧文件），不换。残留的 `-shm` 删掉，免得配给新库。
fn swap_in(path: &Path, staged: &Path) -> Result<(), String> {
    let wal = suffixed(path, "-wal");
    if wal.exists() {
        return Err(format!("busy: {} still exists after closing (another connection has srs.db open)", wal.display()));
    }
    let shm = suffixed(path, "-shm");
    match std::fs::remove_file(&shm) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(format!("remove {}: {e}", shm.display())),
        _ => {}
    }
    std::fs::rename(staged, path).map_err(|e| format!("rename {}: {e}", staged.display()))?;
    sync_dir(path);
    Ok(())
}

/// 把重命名落盘（POSIX 上目录项要 fsync 目录；Windows 的 MoveFileEx 不需要）。
fn sync_dir(path: &Path) {
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        let _ = std::fs::File::open(dir).and_then(|d| d.sync_all());
    }
    #[cfg(not(unix))]
    let _ = path;
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
