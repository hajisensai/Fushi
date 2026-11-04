//! 格式升级后的一次性整理（srs.db v17，2026-10-30 磁盘占用；BUG-4001 改成低占用、防打开即崩）。
//!
//! v16–v18 把冗余挪出了存储（索引、配置快照原文、投影原文），腾出来的页只进空闲链表，文件不会自己变小。升级
//! 阶梯在事务里给 `srs_meta` 记一个 [PENDING]；打开时（写连接上、读连接还没开）在这里整理一次。两条路：
//!
//! - **原地收缩**（库已是 `auto_vacuum = INCREMENTAL`）：`PRAGMA incremental_vacuum` 分块把尾部的页挪进空闲位置、截短
//!   文件，每块后截断 WAL。额外空间只有一块的 WAL（[CHUNK]）；每块各自提交，中途被杀也只是少收缩一些。这条 PRAGMA
//!   每挪一页返回一行，必须一直 step 到结束（[incremental_vacuum]）：只 step 一次只挪 1–2 页。
//! - **重写换文件**（老库 `auto_vacuum = NONE`）：`VACUUM INTO` 把整理后的库直接写成旁边的 `<库>.compact`（顺带改成
//!   INCREMENTAL，以后走上一条），fsync 后关掉写连接、原子重命名换上去。额外空间约「一倍有效数据」（原地 `VACUUM`
//!   要先写一份整理副本再经 WAL 写回，约两倍）。重建索引的排序溢出落临时文件（构建参数 `SQLITE_TEMP_STORE=1`，
//!   libsqlite3-sys 给 Android 默认编成 3 = 临时数据全进内存，GB 级的库一整理就 OOM；临时目录见 [use_temp_dir]）。
//!   - 写之前把 WAL 检查点截断到 0；换之前确认关掉写连接后 WAL 已被删（还在 = 还有别的连接开着这个库，它们会继续
//!     读写被换掉的旧文件），否则不换。
//!   - 换上去之前在新文件里就删掉 [PENDING] / [ATTEMPTS]、写好 [LAST]，换上去的就是整理完的库。
//!   - 任何一步崩溃都安全：重命名之前旧库没动过（WAL 已截断为空），剩下的 `<库>.compact` 下次打开删掉；重命名是原子的。
//!
//! 空闲空间不够就不做，原因记进 `srs_meta` 的 [LAST]，标记留着，下次打开再试。进程死在整理中途的：每次开始前记一次
//! [ATTEMPTS]，正常结束（成功或失败）都清掉；连着 [MAX_ATTEMPTS] 次没结束就先停手，库照常打开，不陷入打开即崩的
//! 循环。停手不丢 [PENDING]：记 [GAVE_UP] =「[COMPACT_REV]/当时的 [PENDING]」，整理代码改版（升 [COMPACT_REV]）或又有
//! 一次格式升级（[PENDING] 变了）就自动重试；同一版本同一升级不再碰。连着被杀多半是大库冷启动时被划掉 / 后台回收，
//! 不等于整理本身坏了，所以不能永久放弃。

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::Connection;
use serde_json::json;

/// 待整理标记（升级阶梯写，整理成功后删）。
pub(crate) const PENDING: &str = "compact_pending";
/// 最近一次整理的结果（JSON；排查用）。
pub(crate) const LAST: &str = "compact_last";
/// 已开始、还没正常结束的整理次数（开始前 +1，成功或失败都删）。
pub(crate) const ATTEMPTS: &str = "compact_attempts";
/// 连着这么多次进程死在整理中途就停手（见 [GAVE_UP]）。
pub(crate) const MAX_ATTEMPTS: i64 = 2;
/// 停手标记：值是「[COMPACT_REV]/<当时的 [PENDING] 值>」，与当前不同就清掉重试。
pub(crate) const GAVE_UP: &str = "compact_gave_up";
/// 整理实现的版本：改了整理代码（修了让进程死在中途的问题）就 +1，之前停手的库自动重试。
pub(crate) const COMPACT_REV: i64 = 1;
/// 空间余量。
pub(crate) const MARGIN: u64 = 64 << 20;
/// 原地收缩每块挪动的字节数（每块后截断 WAL，WAL 峰值约为这么大）。
pub(crate) const CHUNK: u64 = 32 << 20;
/// `PRAGMA auto_vacuum` 的 INCREMENTAL。
const AUTO_VACUUM_INCREMENTAL: u64 = 2;

fn pragma(c: &Connection, name: &str) -> rusqlite::Result<u64> {
    c.query_row(&format!("PRAGMA {name}"), [], |r| r.get::<_, i64>(0))
        .map(|v| v.max(0) as u64)
}

fn record(c: &Connection, v: serde_json::Value) {
    eprintln!("srs.db compact: {v}");
    let _ = c.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [LAST, &v.to_string()],
    );
}

/// 进程级 SQLite 临时目录（[use_temp_dir] 设过的）。
static TEMP_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

/// 让本库编进来的 SQLite 的临时文件（大排序溢出、建索引、VACUUM / VACUUM INTO 的整理副本）落在 [dir]，整个进程只设一次。
///
/// 临时数据落文件而不是内存靠的是构建参数 `SQLITE_TEMP_STORE=1`（`native/fushi_fsrs/.cargo/config.toml`；
/// libsqlite3-sys 编 Android 默认是 3 = 永远放内存，几 GB 的库一整理 / 一做备份快照就 OOM 闪退）。落文件就得有个
/// 可写的目录：Android 进程没有默认临时目录（无 TMPDIR，`/tmp` 不存在、工作目录是 `/`），不设的话一溢出就报
/// 「unable to open database file」。
///
/// `temp_store_directory` 是进程全局的（`sqlite3_temp_directory`），别的连接正在用的时候改它不安全，也不能挂在某一份
/// 库的目录上：同一进程会开不止一份 srs.db（备份恢复先开解压到临时目录的源库，再开本机库），挂在哪份库的目录上，
/// 那个目录一删，之后所有大排序都失败。所以由宿主在打开任何库之前传一个跟进程走的稳定目录（Android 上是 app 的
/// cache 目录，`ffsrs_set_temp_dir`），这里只设一次；之后打开 / 整理 / 快照都不再碰它。再传同一个目录是空操作，
/// 传别的目录报错（全局量不能在连接用着的时候换）。其它平台有可用的默认临时目录，不设也行。
pub(crate) fn use_temp_dir(dir: &Path) -> Result<(), String> {
    let mut set = TEMP_DIR.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(cur) = set.as_ref() {
        return if cur == dir {
            Ok(())
        } else {
            Err(format!(
                "srs temp directory already set to {} (asked for {})",
                cur.display(),
                dir.display()
            ))
        };
    }
    let text = dir
        .to_str()
        .ok_or_else(|| "srs temp directory is not UTF-8".to_string())?;
    // PRAGMA 设的是全局 `sqlite3_temp_directory`，在哪条连接上执行都一样；SQLite 会检查目录存在且可写。
    let c = Connection::open_in_memory().map_err(|e| e.to_string())?;
    c.execute_batch(&format!(
        "PRAGMA temp_store_directory = '{}';",
        text.replace('\'', "''")
    ))
    .map_err(|e| format!("srs temp directory {}: {e}", dir.display()))?;
    *set = Some(dir.to_path_buf());
    Ok(())
}

/// 打开库之前确认临时数据有地方落：Android 上必须先 [use_temp_dir]（没有平台默认目录）。
pub(crate) fn require_temp_dir() -> Result<(), String> {
    if cfg!(target_os = "android") && TEMP_DIR.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
        return Err(
            "srs temp directory not set: call ffsrs_set_temp_dir before opening srs.db".into(),
        );
    }
    Ok(())
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

/// `PRAGMA incremental_vacuum`（[pages] 为 None 时收空整条空闲链表），一直 step 到结束。
///
/// 这条 PRAGMA 每挪一页就返回一行（VDBE 的 ResultRow），只 step 一次（rusqlite `execute_batch` 的做法）只挪 1–2 页。
pub(crate) fn incremental_vacuum(c: &Connection, pages: Option<u64>) -> rusqlite::Result<()> {
    let sql = match pages {
        Some(n) => format!("PRAGMA incremental_vacuum({n})"),
        None => "PRAGMA incremental_vacuum".to_string(),
    };
    let mut st = c.prepare(&sql)?;
    let mut rows = st.query([])?;
    while rows.next()?.is_some() {}
    Ok(())
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
    let meta = |key: &str| -> Option<String> {
        c.query_row(
            "SELECT CAST(value AS TEXT) FROM srs_meta WHERE key = ?1",
            [key],
            |r| r.get(0),
        )
        .ok()
    };
    let Some(pending) = meta(PENDING) else {
        return Ok(c);
    };
    let gave_up_at = format!("{COMPACT_REV}/{pending}");
    match meta(GAVE_UP) {
        // 同一版本、同一次升级已经停过手：不再碰。
        Some(g) if g == gave_up_at => return Ok(c),
        // 整理改了版 / 又升级过：重新来过。
        Some(_) => {
            let _ = c.execute(
                "DELETE FROM srs_meta WHERE key IN (?1, ?2)",
                [GAVE_UP, ATTEMPTS],
            );
        }
        None => {}
    }
    let (Ok(size), Ok(pages), Ok(spare), Ok(auto)) = (
        pragma(&c, "page_size"),
        pragma(&c, "page_count"),
        pragma(&c, "freelist_count"),
        pragma(&c, "auto_vacuum"),
    ) else {
        return Ok(c);
    };
    let before = size * pages;
    let live = size * pages.saturating_sub(spare);
    let in_place = auto == AUTO_VACUUM_INCREMENTAL;
    let need = if in_place { CHUNK } else { live }.saturating_add(MARGIN);
    if let Some(free) = free.filter(|&f| f < need) {
        record(
            &c,
            json!({"at": now, "ok": false, "reason": "disk", "need": need, "free": free, "bytes": before}),
        );
        return Ok(c);
    }
    let attempts: i64 = c
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM srs_meta WHERE key = ?1",
            [ATTEMPTS],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if attempts >= MAX_ATTEMPTS {
        // 标记留着，记下在哪个版本 / 哪次升级停的手（见模块文档）。
        let _ = c.execute_batch("BEGIN");
        let _ = c.execute("DELETE FROM srs_meta WHERE key = ?1", [ATTEMPTS]);
        let _ = c.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [GAVE_UP, &gave_up_at],
        );
        record(
            &c,
            json!({"at": now, "ok": false, "reason": "interrupted", "attempts": attempts, "rev": COMPACT_REV, "bytes": before}),
        );
        let _ = c.execute_batch("COMMIT");
        return Ok(c);
    }
    // 自动提交：进程死在整理里时这一笔已经落盘（WAL）。
    let marked = c.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![ATTEMPTS, (attempts + 1).to_string()],
    );
    if let Err(e) = marked {
        record(
            &c,
            json!({"at": now, "ok": false, "reason": e.to_string(), "bytes": before}),
        );
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
        record(
            &c,
            json!({"at": now, "ok": false, "reason": e, "bytes": before}),
        );
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
        // 每块自动提交；随后把 WAL 截回 0，WAL 峰值不超过一块。
        if let Err(e) = incremental_vacuum(c, Some(chunk))
            .and_then(|()| c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())))
        {
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
            let _ = c.execute(
                "DELETE FROM srs_meta WHERE key IN (?1, ?2)",
                [PENDING, GAVE_UP],
            );
            record(
                c,
                json!({"at": now, "ok": true, "mode": "in_place", "before": before, "after": after}),
            );
        }
        Err(e) => record(
            c,
            json!({"at": now, "ok": false, "mode": "in_place", "reason": e, "bytes": before}),
        ),
    }
}

/// 把整理后的库写成 [staged]（auto_vacuum 改成 INCREMENTAL），在里面清掉标记、记好结果，fsync。
fn rewrite_into(
    c: &Connection,
    staged: &Path,
    size: u64,
    before: u64,
    now: i64,
) -> Result<(), String> {
    let staged_text = staged
        .to_str()
        .ok_or_else(|| "srs.db path is not UTF-8".to_string())?;
    // WAL 截断到 0：之后旧库的主文件本身就是完整的库，换文件之前任何一步崩溃都不丢东西。有别的连接正读着就截不动，
    // 不整理（没在读的别的连接由 [swap_in] 按关闭后 WAL 是否还在查出来）。
    let (busy, frames, done): (i64, i64, i64) = c
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .map_err(|e| e.to_string())?;
    if busy != 0 || done != frames {
        return Err(format!(
            "busy: wal_checkpoint busy={busy} frames={frames} checkpointed={done}"
        ));
    }
    c.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;")
        .map_err(|e| e.to_string())?;
    c.execute("VACUUM INTO ?1", [staged_text])
        .map_err(|e| e.to_string())?;
    {
        let s = Connection::open(staged).map_err(|e| e.to_string())?;
        let after = pragma(&s, "page_count").map_err(|e| e.to_string())? * size;
        s.execute(
            "DELETE FROM srs_meta WHERE key IN (?1, ?2, ?3)",
            [PENDING, ATTEMPTS, GAVE_UP],
        )
        .map_err(|e| e.to_string())?;
        record(
            &s,
            json!({"at": now, "ok": true, "mode": "rewrite", "before": before, "after": after}),
        );
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
        return Err(format!(
            "busy: {} still exists after closing (another connection has srs.db open)",
            wal.display()
        ));
    }
    let shm = suffixed(path, "-shm");
    match std::fs::remove_file(&shm) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!("remove {}: {e}", shm.display()));
        }
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
        fn GetDiskFreeSpaceExW(
            dir: *const u16,
            avail: *mut u64,
            total: *mut u64,
            free: *mut u64,
        ) -> i32;
    }

    pub(super) fn free(dir: &Path) -> Option<u64> {
        let wide: Vec<u16> = dir
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
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

    fn temp_db(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ffsrs-compact-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("t.db")
    }

    /// 真实平台实现（statvfs / GetDiskFreeSpaceExW）取得到库所在卷的可用空间。
    #[test]
    fn free_bytes_reads_the_real_volume() {
        let p = temp_db("free");
        Connection::open(&p)
            .unwrap()
            .execute_batch("CREATE TABLE t (x)")
            .unwrap();
        assert!(super::free_bytes(&p).is_some_and(|f| f > 0));
        assert!(super::free_bytes(p.parent().unwrap()).is_some_and(|f| f > 0));
    }

    /// `incremental_vacuum` 一次调用就挪满请求的页数（step 到结束），不是 1–2 页；不带页数时收空整条空闲链表。
    #[test]
    fn incremental_vacuum_runs_to_completion() {
        let p = temp_db("ivac");
        let c = Connection::open(&p).unwrap();
        c.execute_batch(
            "PRAGMA auto_vacuum = INCREMENTAL; PRAGMA journal_mode = WAL; CREATE TABLE junk (x); \
             WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) INSERT INTO junk SELECT randomblob(4000) FROM n; \
             DROP TABLE junk;",
        )
        .unwrap();
        let free = |c: &Connection| super::pragma(c, "freelist_count").unwrap();
        let spare = free(&c);
        assert!(spare > 300, "{spare}");
        // 对照：只 step 一次（rusqlite execute_batch）几乎不动。
        c.execute_batch("PRAGMA incremental_vacuum(200);").unwrap();
        let after_batch = free(&c);
        assert!(
            spare - after_batch < 10,
            "execute_batch steps once: {spare} -> {after_batch}"
        );
        super::incremental_vacuum(&c, Some(200)).unwrap();
        assert_eq!(free(&c), after_batch - 200);
        super::incremental_vacuum(&c, None).unwrap();
        assert_eq!(free(&c), 0);
    }

    /// 进程级临时目录只设一次：同一个目录再设是空操作，换目录报错（全局量不能在连接用着时换）。设的是一个常驻目录
    /// （系统临时目录），不影响同一测试进程里别的测试。
    #[test]
    fn temp_dir_is_set_once_per_process() {
        let dir = std::env::temp_dir();
        super::use_temp_dir(&dir).unwrap();
        super::use_temp_dir(&dir).unwrap();
        assert!(super::use_temp_dir(&dir.join("elsewhere")).is_err());
        super::require_temp_dir().unwrap();
    }

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
        assert!(
            opts.iter().any(|o| o == "TEMP_STORE=1"),
            "compile_options: {opts:?}"
        );
    }

    /// 覆盖参数写在 crate 目录的 cargo 配置里（所有构建脚本都在本目录跑 cargo）：先 -U 掉 libsqlite3-sys 给 Android
    /// 加的 3，再定成 1。删了它 Android 包就退回全内存临时存储。
    #[test]
    fn cargo_config_overrides_android_temp_store() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/.cargo/config.toml");
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        assert!(
            text.contains("LIBSQLITE3_FLAGS = { value = \"-USQLITE_TEMP_STORE -DSQLITE_TEMP_STORE=1\", force = true }"),
            "{path} 缺 LIBSQLITE3_FLAGS 覆盖"
        );
    }
}
