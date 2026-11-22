//! SRS 库的 C ABI（Dart 绑定：packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart）。
//!
//! 换代（规划 §2.2 S1）之后句柄里放的是新代库（`store/gen4/kernel.rs` [G4Core]，profile 目录里的 `srs4.db`），用
//! [ffsrs_store_open_mode] 打开；`ffsrs_store_sync2` 的命令经新代分发器（`store/gen4/dispatch.rs`）。旧的
//! `ffsrs_store_open`（按 `srs.db` 路径打开协议 3 的库）已删。协议 3 的 JSON 分发器在冻结侧 `store/legacy3/`（G7-6），
//! 不经任何 C 入口。
//!
//! 约定与 lib.rs 其余部分相同：返回 i32 状态（0 成功，负数失败），失败时 `*error_out` 是新分配的
//! C 字符串（用 `ffsrs_free_string` 释放）；Rust 分配的字节用 `ffsrs_free_bytes` 释放；panic 一律
//! 接住转成 -100。
//!
//! 库句柄（[SrsCoreHandle]）**不是指针**，是句柄表里的一个编号：Dart 把句柄地址交给后台 isolate
//! （`SrsCore.fromAddress`），拥有者关库时那边可能还在调用、甚至之后才调用。每次调用先在句柄表里
//! 取出一份 `Arc<SrsCore>` 再干活，关库把它从表里摘掉：在途调用手上那份让结构体活到它跑完，之后
//! 再来的调用查不到编号、报「已关闭」，最后一份引用放掉时结构体真正释放。编号单调递增不复用，
//! 旧句柄不会误指到后来打开的库。线程安全，可在任意 isolate 上用。

use std::collections::BTreeMap;
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use super::CLOSED;
use super::gen4::dispatch as gen4_dispatch;
use super::gen4::files::{OpenError, OpenMode};
use super::gen4::kernel::G4Core;

pub const STORE_OK: i32 = 0;
pub const STORE_ERROR: i32 = -1;
pub const STORE_BAD_ARGUMENT: i32 = -2;
/// 打开时库要升级而所在卷空间不够（[super::schema::UPGRADE_NO_SPACE]，错误文本后面是 `{"need","free","from","to"}`）：
/// 库没动，腾出空间后再打开。
///
/// **S1 之后没有返回点**：这是协议 3 `ffsrs_store_open`（已删）升级前空间检查的返回码；新代打开（[ffsrs_store_open_mode]）
/// 不做协议 3 的库升级，迁移的空间不够走全局命令 `gen4_migrate_run` 的 `{verdict: "noSpace"}`。值 -3 保留、不复用给别的
/// 状态（还认它的 Dart 不会把新状态误读成「空间不够」）；Dart 那边删掉对应分支归 G7-5，删这个常量归 G7-6。
pub const STORE_NO_SPACE: i32 = -3;
/// [ffsrs_store_open_mode]：目录里还没有新代库（有协议 3 的库要迁移 / 只剩封存的旧库 / 上次迁移失败 / 辅助进程比主进程
/// 先到）。错误文本后面是 `{"state": <migrate::GenState 的线上名>}`。库没动，迁移走全局命令 `gen4_migrate_run`。
pub const STORE_NOT_MIGRATED: i32 = -4;
/// [ffsrs_store_open_mode]：另一个进程正拿着换代锁（迁移进行中）。
pub const STORE_MIGRATING: i32 = -5;
/// [ffsrs_store_open_mode]：新代库在，旁边还有一份没封存、也不是它迁移来源的协议 3 库（`files.rs` 文件头）。那份库没动，
/// 并入还是提示由调用方定。
pub const STORE_LEGACY_UNMIGRATED: i32 = -6;
pub const STORE_PANIC: i32 = -100;

fn set_error(error_out: *mut *mut c_char, message: &str) {
    if !error_out.is_null() {
        let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
        unsafe { *error_out = text.into_raw() };
    }
}

fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

fn utf8<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    let b = bytes(ptr, len).ok_or_else(|| "null string".to_string())?;
    std::str::from_utf8(b).map_err(|e| e.to_string())
}

/// 库句柄的不透明类型：C 侧只见一个 `void*`，值是 [HANDLES] 里的编号，从不解引用。
pub enum SrsCoreHandle {}

/// 打开着的库：编号 → 共享引用。只在取 / 放引用的一瞬间持锁，命令本身不在锁里跑。
static HANDLES: Mutex<BTreeMap<usize, Arc<G4Core>>> = Mutex::new(BTreeMap::new());

/// 下一个句柄编号（0 留给 NULL；单调递增，不复用）。
static NEXT_HANDLE: AtomicUsize = AtomicUsize::new(1);

fn handles() -> std::sync::MutexGuard<'static, BTreeMap<usize, Arc<G4Core>>> {
    // 锁里只有 BTreeMap 的增删查，不跑用户代码；就算哪次 panic 毒化了锁，表本身也完好。
    HANDLES.lock().unwrap_or_else(|e| e.into_inner())
}

fn register(core: G4Core) -> *mut SrsCoreHandle {
    let id = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    handles().insert(id, Arc::new(core));
    id as *mut SrsCoreHandle
}

/// 取出句柄对应的库（已关闭 / 从没打开过 = None）。
fn resolve(core: *const SrsCoreHandle) -> Option<Arc<G4Core>> {
    handles().get(&(core as usize)).cloned()
}

/// 测试用：句柄背后的库（分发器测试查命令层的常驻状态）。
#[cfg(test)]
pub(crate) fn core_of(core: *const SrsCoreHandle) -> Option<Arc<G4Core>> {
    resolve(core)
}

/// 跑一段带库句柄的操作：调用期间手上握着一份 `Arc`，关库不会把结构体从脚下释放掉。
fn run_core(
    core: *const SrsCoreHandle,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&G4Core) -> Result<(), String>,
) -> i32 {
    if core.is_null() {
        set_error(error_out, "null srs handle");
        return STORE_BAD_ARGUMENT;
    }
    let Some(c) = resolve(core) else {
        set_error(error_out, CLOSED);
        return STORE_ERROR;
    };
    run(Arc::as_ptr(&c), error_out, body)
}

/// 跑一段带句柄（[G4Core]）的操作，统一处理空指针、错误与 panic。
fn run<T>(
    core: *const T,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&T) -> Result<(), String>,
) -> i32 {
    if core.is_null() {
        set_error(error_out, "null srs handle");
        return STORE_BAD_ARGUMENT;
    }
    let core = unsafe { &*core };
    match catch_unwind(AssertUnwindSafe(|| body(core))) {
        Ok(Ok(())) => STORE_OK,
        Ok(Err(e)) => {
            set_error(error_out, &e);
            STORE_ERROR
        }
        Err(_) => {
            set_error(error_out, "panic in srs store");
            STORE_PANIC
        }
    }
}

fn hand_out(buf: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = buf.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
}

/// 设进程级 SQLite 临时目录（[super::compact::use_temp_dir]）：大排序 / 整理 / 快照的溢出文件落在这里。整个进程只设
/// 一次，必须在打开任何 srs.db 之前；再传同一个目录是空操作，传别的目录报错。Android 上不设就打不开库（没有平台默认
/// 临时目录），宿主传 app 的 cache 目录。
#[no_mangle]
pub extern "C" fn ffsrs_set_temp_dir(
    path: *const u8,
    path_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        super::compact::use_temp_dir(Path::new(utf8(path, path_len)?))
    }));
    match outcome {
        Ok(Ok(())) => STORE_OK,
        Ok(Err(e)) => {
            set_error(error_out, &e);
            STORE_ERROR
        }
        Err(_) => {
            set_error(error_out, "panic in srs set temp dir");
            STORE_PANIC
        }
    }
}

/// 打开 profile 目录 [dir] 里的新代库（`store/gen4/files.rs` 的打开模式）：[mode] 0 = Primary（主进程，唯一的写者；
/// 全新安装时建空库），1 = Secondary（查词弹窗等辅助进程，只读，写命令报只读）。成功写 `*core_out`；用
/// [ffsrs_store_close] 关闭。打不开时的代际状态各有返回码：[STORE_NOT_MIGRATED]（错误文本后面带 `{"state"}`）/
/// [STORE_MIGRATING] / [STORE_LEGACY_UNMIGRATED]；别的错误 [STORE_ERROR]。不会静默打开协议 3 的 `srs.db`。
#[no_mangle]
pub extern "C" fn ffsrs_store_open_mode(
    dir: *const u8,
    dir_len: usize,
    mode: i32,
    core_out: *mut *mut SrsCoreHandle,
    error_out: *mut *mut c_char,
) -> i32 {
    if core_out.is_null() {
        set_error(error_out, "null core_out");
        return STORE_BAD_ARGUMENT;
    }
    let mode = match mode {
        0 => OpenMode::Primary,
        1 => OpenMode::Secondary,
        m => {
            set_error(error_out, &format!("unknown open mode {m}"));
            return STORE_BAD_ARGUMENT;
        }
    };
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<G4Core, (i32, String)> {
        let dir = Path::new(utf8(dir, dir_len).map_err(|e| (STORE_ERROR, e))?);
        G4Core::open(dir, mode).map_err(|e| open_error(dir, e))
    }));
    match outcome {
        Ok(Ok(core)) => {
            unsafe { *core_out = register(core) };
            STORE_OK
        }
        Ok(Err((code, e))) => {
            set_error(error_out, &e);
            code
        }
        Err(_) => {
            set_error(error_out, "panic in srs store open");
            STORE_PANIC
        }
    }
}

/// [ffsrs_store_open_mode] 打不开时的返回码与错误文本。没迁移的再按 `migrate::status` 区分「要迁移 / 只剩封存的旧库 /
/// 上次迁移失败（带原因，`migrate::Failure`）/ 还什么都没有（辅助进程先到）」：调用方据此选页面。错误文本末尾是
/// `GenState::json` 的 `{failure, state}`（键按字母序）。
fn open_error(dir: &Path, e: OpenError) -> (i32, String) {
    match e {
        OpenError::NotMigrated => {
            // 状态与上次没完成的原因一起带出去（`GenState::json`，与状态命令同一形状、同一次判定）：调用方不再另读报告。
            let payload = super::gen4::migrate::status(dir)
                .map(|s| s.json(dir))
                .unwrap_or_else(|err| serde_json::json!({ "state": format!("unknown: {err}") }));
            (STORE_NOT_MIGRATED, format!("{e} {payload}"))
        }
        OpenError::Migrating => (STORE_MIGRATING, e.to_string()),
        OpenError::LegacyNotMigrated => (STORE_LEGACY_UNMIGRATED, e.to_string()),
        OpenError::Failed(m) => (STORE_ERROR, m),
    }
}

/// 关闭（NULL 无操作，重复关闭无操作）：把句柄从句柄表里摘掉，等在途命令跑完再关两条连接；之后经这个
/// 句柄的命令一律报「已关闭」。结构体在最后一个在途调用放掉引用时释放（通常就在这里）。
#[no_mangle]
pub extern "C" fn ffsrs_store_close(core: *mut SrsCoreHandle) {
    if core.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // 先摘再关（摘的时候不等连接锁）：摘掉之后新来的调用查不到编号，close 只需等已经在途的那些。
        let removed = handles().remove(&(core as usize));
        if let Some(c) = removed {
            c.close();
        }
    }));
}

/// 新代库的整库一致快照（`G4Core::snapshot_into`，G11-4：`VACUUM INTO`，读不挡写；Secondary 报只读；
/// `strip_device_local != 0` 报错——新代的 app 备份是按集合导出的流，不是剥了本机表的快照）。
#[no_mangle]
pub extern "C" fn ffsrs_store_snapshot(
    core: *const SrsCoreHandle,
    path: *const u8,
    path_len: usize,
    strip_device_local: i32,
    error_out: *mut *mut c_char,
) -> i32 {
    run_core(core, error_out, |c| {
        c.snapshot_into(Path::new(utf8(path, path_len)?), strip_device_local != 0)
    })
}

/// 只读调试查询（测试 / 诊断）。参数是一行 rows.rs 编码的页（列数 = 参数个数，可为空页）。
#[no_mangle]
pub extern "C" fn ffsrs_store_debug_query(
    core: *const SrsCoreHandle,
    sql: *const u8,
    sql_len: usize,
    params: *const u8,
    params_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let s = utf8(sql, sql_len)?;
        let p = bytes(params, params_len).ok_or("null params")?;
        let values = if p.is_empty() {
            Vec::new()
        } else {
            let (_, mut rows) = super::rows::decode(p)?;
            if rows.len() > 1 {
                return Err("params page must hold at most one row".into());
            }
            rows.pop().unwrap_or_default()
        };
        hand_out(c.debug_query(s, &values)?, out, out_len);
        Ok(())
    })
}

fn one_row(page: &[u8]) -> Result<Vec<rusqlite::types::Value>, String> {
    if page.is_empty() {
        return Ok(Vec::new());
    }
    let (_, mut rows) = super::rows::decode(page)?;
    if rows.len() > 1 {
        return Err("params page must hold at most one row".into());
    }
    Ok(rows.pop().unwrap_or_default())
}

/// 测试专用的原始通道（[SrsCore::exec_raw]，写连接）：`select` 4 返回一行 `[变更行数, last_insert_rowid]`，5 返回
/// 「列名行 + 结果行」；缓冲区用 `ffsrs_free_bytes` 释放。别的取值不认：0–3 是以前 Drift 执行器的语句入口，
/// 已经没有了——srs.db 的写入只有内核命令，读只有内核的读命令（`ffsrs_store_sync2`；`read` 见 store/reads.rs）。
/// 4 / 5 只有带 cargo feature `raw_sql` 的库里有，别的构建报 [crate::store::RAW_SQL_ABSENT]、不执行。
#[no_mangle]
pub extern "C" fn ffsrs_store_exec(
    core: *const SrsCoreHandle,
    sql: *const u8,
    sql_len: usize,
    params: *const u8,
    params_len: usize,
    select: i32,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let s = utf8(sql, sql_len)?;
        let values = one_row(bytes(params, params_len).ok_or("null params")?)?;
        let page = match select {
            #[cfg(any(test, feature = "raw_sql"))]
            4 => c.exec_raw(s, &values, false)?,
            #[cfg(any(test, feature = "raw_sql"))]
            5 => c.exec_raw(s, &values, true)?,
            #[cfg(not(any(test, feature = "raw_sql")))]
            4 | 5 => return Err(crate::store::RAW_SQL_ABSENT.to_string()),
            m => return Err(format!("unknown exec mode {m}")),
        };
        hand_out(page, out, out_len);
        Ok(())
    })
}

/// 测试专用的原始通道的批量版（[SrsCore::exec_batch_raw]：整批在写连接的一个 SAVEPOINT 里）。`statements` 是单列文本页（每行一条 SQL）；`applications` 是两列页：
/// `[语句下标 i64, 参数页 blob]`（参数页是一行的 rows.rs 页，可为空字节）。
///
/// 只有带 cargo feature `raw_sql` 的库里有；别的构建报 [crate::store::RAW_SQL_ABSENT]、什么都不解析、不取写锁。符号
/// 照常导出：Dart 绑定构造时 lookup 全部符号，`verify_abi.sh` 按绑定核对导出面——发布构建里不在的是能写库的代码。
#[no_mangle]
pub extern "C" fn ffsrs_store_exec_batch(
    core: *const SrsCoreHandle,
    statements: *const u8,
    statements_len: usize,
    applications: *const u8,
    applications_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    #[cfg(not(any(test, feature = "raw_sql")))]
    {
        let _ = (statements, statements_len, applications, applications_len);
        return run_core(core, error_out, |_| {
            Err(crate::store::RAW_SQL_ABSENT.to_string())
        });
    }
    #[cfg(any(test, feature = "raw_sql"))]
    exec_batch_raw_entry(
        core,
        statements,
        statements_len,
        applications,
        applications_len,
        error_out,
    )
}

#[cfg(any(test, feature = "raw_sql"))]
fn exec_batch_raw_entry(
    core: *const SrsCoreHandle,
    statements: *const u8,
    statements_len: usize,
    applications: *const u8,
    applications_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    use rusqlite::types::Value;
    run_core(core, error_out, |c| {
        let (_, stmt_rows) =
            super::rows::decode(bytes(statements, statements_len).ok_or("null statements")?)?;
        let mut sqls: Vec<String> = Vec::with_capacity(stmt_rows.len());
        for r in stmt_rows {
            match r.into_iter().next() {
                Some(Value::Text(t)) => sqls.push(t),
                _ => return Err("statement page row must be one text value".into()),
            }
        }
        let (_, app_rows) =
            super::rows::decode(bytes(applications, applications_len).ok_or("null applications")?)?;
        let mut apps: Vec<(usize, Vec<Value>)> = Vec::with_capacity(app_rows.len());
        for r in app_rows {
            let mut it = r.into_iter();
            let index = match it.next() {
                Some(Value::Integer(i)) if i >= 0 => i as usize,
                _ => return Err("application row needs a statement index".into()),
            };
            let args = match it.next() {
                Some(Value::Blob(b)) => one_row(&b)?,
                Some(Value::Null) | None => Vec::new(),
                _ => return Err("application args must be a blob".into()),
            };
            apps.push((index, args));
        }
        let refs: Vec<&str> = sqls.iter().map(String::as_str).collect();
        c.exec_batch_raw(&refs, &apps)
    })
}

/// [ffsrs_store_diag_counts] 写出的项数。
pub const DIAG_COUNT_LEN: usize = 7;

/// 进程级内存诊断计数（不需要句柄，任意线程可调）：按序写 `out[0..min(n, DIAG_COUNT_LEN)]`，返回写了几项。
/// `[句柄表里打开着的库, 还没释放的库句柄结构（G4Core，含已关、在途调用还握着的）,
///   各库只读连接池开着的连接总数, 本库内置 SQLite 的堆用量字节, 其高水位字节,
///   打开着的库文件总字节, 它们的 `-wal` 总字节]`。
/// 用途：移动端内存耗尽闪退（BUG-4075）的取证面包屑看「退役的库还驻留没有 / 连接与 SQLite 页缓存占多少」。
#[no_mangle]
pub extern "C" fn ffsrs_store_diag_counts(out: *mut i64, n: usize) -> usize {
    if out.is_null() || n == 0 {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let (open, readers, cores) = {
            let table = handles();
            let readers: usize = table.values().map(|c| c.pooled_readers()).sum();
            let cores: Vec<Arc<G4Core>> = table.values().cloned().collect();
            (table.len(), readers, cores)
        };
        // stat 在句柄表锁外做：慢盘上也不挡别的线程取句柄。
        let (db, wal) = cores
            .iter()
            .map(|c| c.file_sizes())
            .fold((0u64, 0u64), |(d, w), (a, b)| (d + a, w + b));
        drop(cores);
        let values: [i64; DIAG_COUNT_LEN] = [
            open as i64,
            super::gen4::kernel::live_cores() as i64,
            readers as i64,
            unsafe { rusqlite::ffi::sqlite3_memory_used() },
            unsafe { rusqlite::ffi::sqlite3_memory_highwater(0) },
            db as i64,
            wal as i64,
        ];
        let k = n.min(DIAG_COUNT_LEN);
        let dst = unsafe { std::slice::from_raw_parts_mut(out, k) };
        dst.copy_from_slice(&values[..k]);
        k
    }))
    .unwrap_or(0)
}

/// `*out` = 查询道的并发上限（只读连接池的空闲连接上限，`G4Core::read_concurrency`）：Dart 侧查询道的
/// worker 数取它。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_concurrency(
    core: *const SrsCoreHandle,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        unsafe { *out = c.read_concurrency() as i32 };
        Ok(())
    })
}

/// `*out` = 1 写连接在事务里。
#[no_mangle]
pub extern "C" fn ffsrs_store_in_transaction(
    core: *const SrsCoreHandle,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let v = c.in_transaction()?;
        unsafe { *out = v as i32 };
        Ok(())
    })
}

/// 卡片历史的当前状态（新代：`gen4/dispatch.rs` `history_states`，一个读快照）。`groups` 是两列页 `[历史下标 i64,
/// 卡 ID 文本]`，共 `n_groups` 份历史，可另带一行 `[-1, profile]` 指定集合（没有就按卡认集合，`dispatch.rs`
/// `direct_col`）；输出布局同 `ffsrs_history_states`，用 `ffsrs_free_bytes` 释放。
#[no_mangle]
pub extern "C" fn ffsrs_store_history_states(
    core: *const SrsCoreHandle,
    groups: *const u8,
    groups_len: usize,
    n_groups: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let (lineages, profile) =
            lineage_page(bytes(groups, groups_len).ok_or("null groups")?, n_groups)?;
        hand_out(
            gen4_dispatch::history_states(c, profile.as_deref(), &lineages)?,
            out,
            out_len,
        );
        Ok(())
    })
}

/// 有效复习投影（新代：`gen4/dispatch.rs` `stat_projection`）。`groups` 同 [ffsrs_store_history_states]（两列页
/// `[组下标, 卡 ID]`，可带 `[-1, profile]`），每组是一个归属组（归属卡 + 归它的前身卡）；输出是 9 列行页（见
/// `SrsCore::stat_projection`），用 `ffsrs_free_bytes` 释放。
#[no_mangle]
pub extern "C" fn ffsrs_store_stat_projection(
    core: *const SrsCoreHandle,
    groups: *const u8,
    groups_len: usize,
    n_groups: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let (lineages, profile) =
            lineage_page(bytes(groups, groups_len).ok_or("null groups")?, n_groups)?;
        hand_out(
            gen4_dispatch::stat_projection(c, profile.as_deref(), &lineages)?,
            out,
            out_len,
        );
        Ok(())
    })
}

// ---------------------------------------------------------------- P6 直读命令（store/projections.rs）

/// 命令的输入页：两列 `[下标 i64, 文本]`。下标 g ≥ 0 = 第 g 份历史的血统里的一张卡；-1 = profile uid。
fn lineage_page(
    page: &[u8],
    n_groups: usize,
) -> Result<(Vec<Vec<String>>, Option<String>), String> {
    use rusqlite::types::Value;
    let (_, rows) = super::rows::decode(page)?;
    let mut lineages: Vec<Vec<String>> = vec![Vec::new(); n_groups];
    let mut profile = None;
    for r in rows {
        let mut it = r.into_iter();
        match (it.next(), it.next()) {
            (Some(Value::Integer(-1)), Some(Value::Text(p))) => profile = Some(p),
            (Some(Value::Integer(g)), Some(Value::Text(card)))
                if g >= 0 && (g as usize) < n_groups =>
            {
                lineages[g as usize].push(card)
            }
            _ => return Err("bad lineage row".into()),
        }
    }
    Ok((lineages, profile))
}

fn ints<'a>(ptr: *const i64, n: usize) -> Option<&'a [i64]> {
    if n == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(ptr, n) })
    }
}

/// 统一的命令外壳：输入页 + i64 参数，输出 Rust 分配的字节（`ffsrs_free_bytes` 释放）。
#[allow(clippy::too_many_arguments)]
fn command(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&G4Core, &[u8], &[i64]) -> Result<Vec<u8>, String>,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let page = bytes(page, page_len).ok_or("null page")?;
        let args = ints(args, n_args).ok_or("null args")?;
        hand_out(body(c, page, args)?, out, out_len);
        Ok(())
    })
}

fn arg(args: &[i64], k: usize) -> Result<i64, String> {
    args.get(k)
        .copied()
        .ok_or_else(|| format!("missing argument {k}"))
}

fn day_of(args: &[i64], k: usize) -> Result<crate::projection::Day, String> {
    Ok(crate::projection::Day {
        utc_offset_min: arg(args, k)?,
        rollover_hour: arg(args, k + 1)?,
    })
}

fn group_count(args: &[i64]) -> Result<usize, String> {
    usize::try_from(arg(args, 0)?).map_err(|_| "negative group count".to_string())
}

/// 只读训练集命令的公共壳（`ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items`）：
/// 解析 `args = [n_groups, alg, utcOffsetMin, rolloverHour, 卡数字 id × n_groups]` 与 lineage 页，
/// 把 `body` 产出的训练集字节串打包返回。
#[allow(clippy::too_many_arguments)]
fn lineage_command(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
    body: impl FnOnce(
        &G4Core,
        Option<&str>,
        Vec<Vec<String>>,
        &[i64],
        crate::projection::Alg,
        crate::projection::Day,
    ) -> Result<Vec<u8>, String>,
) -> i32 {
    command(
        core,
        page,
        page_len,
        args,
        n_args,
        out,
        out_len,
        error_out,
        |c, page, args| {
            let n = group_count(args)?;
            let (lineages, profile) = lineage_page(page, n)?;
            let alg = crate::projection::Alg::from_code(arg(args, 1)?)?;
            let ids = args.get(4..4 + n).ok_or("missing card ids")?;
            body(c, profile.as_deref(), lineages, ids, alg, day_of(args, 2)?)
        },
    )
}

/// 优化器训练集（`SrsCore::optimizer_items`）。`args = [n_groups, alg, utcOffsetMin, rolloverHour, 卡数字 id × n_groups]`。
#[no_mangle]
pub extern "C" fn ffsrs_store_optimizer_items(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    lineage_command(
        core,
        page,
        page_len,
        args,
        n_args,
        out,
        out_len,
        error_out,
        |c, profile, lineages, ids, alg, day| {
            gen4_dispatch::optimizer_items(c, profile, &lineages, ids, alg, &day)
        },
    )
}

/// 复习统计页校准图的训练集与条目元数据（`SrsCore::calibration_items`）。参数同 [ffsrs_store_optimizer_items]。
#[no_mangle]
pub extern "C" fn ffsrs_store_calibration_items(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    lineage_command(
        core,
        page,
        page_len,
        args,
        n_args,
        out,
        out_len,
        error_out,
        |c, profile, lineages, ids, alg, day| {
            gen4_dispatch::calibration_items(c, profile, &lineages, ids, alg, &day)
        },
    )
}

/// RWKV 回放行。mode 0 = 逐卡（`SrsCore::rwkv_cards`）：`args = [n_groups, 0, utcOffsetMin, rolloverHour, 0,
/// 数字 id × 4·n_groups]`；mode 1 = 回放（`SrsCore::rwkv_replay`，页里要有 profile 行）：`args = [n_groups, 1,
/// utcOffsetMin, rolloverHour, since, rebaseSince|NONE, rowsFrom|NONE, 数字 id × 4·n_groups]`（NONE = i64::MIN，
/// rebaseSince 为 NONE = 全量）。
#[no_mangle]
pub extern "C" fn ffsrs_store_rwkv_rows(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    command(
        core,
        page,
        page_len,
        args,
        n_args,
        out,
        out_len,
        error_out,
        |c, page, args| {
            let n = group_count(args)?;
            let (lineages, profile) = lineage_page(page, n)?;
            let day = day_of(args, 2)?;
            let opt = |v: i64| (v != crate::history::NONE_I64).then_some(v);
            match arg(args, 1)? {
                0 => gen4_dispatch::rwkv_cards(
                    c,
                    profile.as_deref(),
                    &lineages,
                    args.get(5..5 + 4 * n).ok_or("missing rwkv ids")?,
                    &day,
                ),
                1 => gen4_dispatch::rwkv_replay(
                    c,
                    profile.as_deref().ok_or("missing profile")?,
                    &lineages,
                    args.get(7..7 + 4 * n).ok_or("missing rwkv ids")?,
                    &day,
                    arg(args, 4)?,
                    crate::store::projections::RwkvRange {
                        rebase_since: opt(arg(args, 5)?),
                        rows_from: opt(arg(args, 6)?),
                    },
                ),
                m => Err(format!("unknown rwkv mode {m}")),
            }
        },
    )
}

/// RWKV 对齐的日志指纹与尾巴（`SrsCore::rwkv_log_tail`）。页 = profile 行；
/// `args = [since, with_rows, incremental?]`（第三个省略 = 0，整表计数）。
#[no_mangle]
pub extern "C" fn ffsrs_store_rwkv_log_tail(
    core: *const SrsCoreHandle,
    page: *const u8,
    page_len: usize,
    args: *const i64,
    n_args: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    command(
        core,
        page,
        page_len,
        args,
        n_args,
        out,
        out_len,
        error_out,
        |c, page, args| {
            let (_, profile) = lineage_page(page, 0)?;
            gen4_dispatch::rwkv_log_tail(
                c,
                profile.as_deref().ok_or("missing profile")?,
                arg(args, 0)?,
                arg(args, 1)? != 0,
                args.get(2).copied().unwrap_or(0) != 0,
            )
        },
    )
}

// ---------------------------------------------------------------- 同步 v2（store/sync2）

/// 分帧字节块：`u32 n`，再 n 个 `u32 len + 字节`（小端）。空输入 = 0 块。
///
/// 这里是唯一一次复制：输入缓冲属于 Dart（调用返回就释放），收段会话要把段留到投递，所以拷成自己的；之后一路
/// 按所有权移交（`ingest_prepare` / `ingest_batch` 直接接走），不再复制（审查 S-9）。
fn frames(b: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if b.is_empty() {
        return Ok(Vec::new());
    }
    let mut at = 0usize;
    let mut take = |n: usize| -> Result<&[u8], String> {
        let end = at.checked_add(n).ok_or("frame overflow")?;
        if end > b.len() {
            return Err("truncated frames".into());
        }
        let s = &b[at..end];
        at = end;
        Ok(s)
    };
    let n = u32::from_le_bytes(take(4)?.try_into().map_err(|_| "frames")?) as usize;
    let mut out = Vec::with_capacity(n.min(1 << 16));
    for _ in 0..n {
        let len = u32::from_le_bytes(take(4)?.try_into().map_err(|_| "frames")?) as usize;
        out.push(take(len)?.to_vec());
    }
    Ok(out)
}

fn push_frame(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

pub(crate) fn key32(v: &serde_json::Value) -> Result<Option<[u8; 32]>, String> {
    match v.as_str() {
        None => Ok(None),
        Some(h) if h.len() == 64 => {
            let mut k = [0u8; 32];
            for (i, x) in k.iter_mut().enumerate() {
                *x = u8::from_str_radix(&h[2 * i..2 * i + 2], 16).map_err(|e| e.to_string())?;
            }
            Ok(Some(k))
        }
        Some(_) => Err("bad collection key".into()),
    }
}

/// 纯加解密命令（`seal` / `open` / `seal_file` / `open_file` / `derive_key`）：不碰库、与库代无关，协议 3 与
/// 新代的分发器共用这一份（交接说明对照表 7.4「S1 原样接」）。
pub(crate) fn crypto_command(
    op: &str,
    req: &serde_json::Value,
    blobs: &[Vec<u8>],
    files: &mut Vec<(String, Vec<u8>)>,
) -> Result<serde_json::Value, String> {
    use serde_json::{Value, json};
    let s = |k: &str| {
        req.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    let i = |k: &str| {
        req.get(k)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    Ok(match op {
        // 加密位置上的媒体（设计 §9：网盘只见密文和文件大小）：XChaCha20-Poly1305，AAD 绑定文件名，
        // 换名 / 换内容即解密失败。段的加解密在 outbox / ingest 里，这里只给媒体用。
        "seal" | "open" => {
            let key = crate::sync2::keys::CollectionKey(
                key32(&req["key"])?.ok_or("seal/open: missing key")?,
            );
            let aad = format!("fushi-srs-media:{}", s("name")?);
            let input = blobs.first().ok_or("seal/open: missing input")?;
            // 分块流式格式（sync2/media_seal.rs，审查 S-9）。
            if op == "seal" {
                files.push((
                    "sealed".to_owned(),
                    crate::sync2::media_seal::seal_bytes(&key, input, aad.as_bytes())?,
                ));
            } else {
                files.push((
                    "plain".to_owned(),
                    crate::sync2::media_seal::open_bytes(&key, input, aad.as_bytes())?,
                ));
            }
            json!({})
        }
        // 文件到文件的流式封 / 解（大媒体不整份进内存；审查 S-9）：返回明文的字节数与 sha256（内容寻址核对用，
        // 不必再读一遍文件）。目标先写同目录临时文件再改名；解不开不留目标。解不开（不是本机读写出错）不算命令失败：
        // 回 `{"failure": "unauthenticated" | "corrupt"}`（media_seal.rs [OpenError]），媒体对账据此决定记不记可疑。
        "seal_file" | "open_file" => {
            use crate::sync2::media_seal::OpenError;
            let key = crate::sync2::keys::CollectionKey(
                key32(&req["key"])?.ok_or("seal/open: missing key")?,
            );
            let aad = format!("fushi-srs-media:{}", s("name")?);
            let (src, dst) = (
                std::path::Path::new(s("src")?),
                std::path::Path::new(s("dst")?),
            );
            let done = if op == "seal_file" {
                crate::sync2::media_seal::seal_file(&key, src, dst, aad.as_bytes())?
            } else {
                match crate::sync2::media_seal::open_file(&key, src, dst, aad.as_bytes()) {
                    Ok(done) => done,
                    Err(OpenError::Unauthenticated) => {
                        return Ok(json!({"failure": "unauthenticated"}));
                    }
                    Err(OpenError::Corrupt) => return Ok(json!({"failure": "corrupt"})),
                    Err(e @ OpenError::Io(_)) => return Err(e.into()),
                }
            };
            let sha: String = done.sha256.iter().map(|b| format!("{b:02x}")).collect();
            json!({"sha256": sha, "bytes": done.plain_len})
        }
        "derive_key" => {
            let salt_hex = s("salt")?;
            let salt: Vec<u8> = (0..salt_hex.len() / 2)
                .map(|k| u8::from_str_radix(&salt_hex[2 * k..2 * k + 2], 16))
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?;
            let params = crate::sync2::keys::KdfParams::checked(i("m")?, i("t")?, i("p")?)?;
            let k = crate::sync2::keys::CollectionKey::derive(
                s("passphrase")?.as_bytes(),
                &salt,
                params,
            )?;
            json!({"key": k.0.iter().map(|b| format!("{b:02x}")).collect::<String>()})
        }
        other => return Err(format!("not a crypto op {other}")),
    })
}

/// 同步 v2 的唯一入口（粗粒度命令，设计 §11；命令表见新代分发器 `store/gen4/dispatch.rs`）。请求是 JSON
/// `{"op": ..., "profile": ..., ...}`；[blobs] 是分帧字节块（段 / head 文件，或 `apply` 的事件数组 JSON）。
/// 输出 = `u32 json_len + JSON`，再接 `u32 n` 与 n 组分帧的 `(相对路径, 字节)`（发件 / 写 head 才有）。
#[no_mangle]
pub extern "C" fn ffsrs_store_sync2(
    core: *const SrsCoreHandle,
    request: *const u8,
    request_len: usize,
    blobs: *const u8,
    blobs_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let req: serde_json::Value = serde_json::from_str(utf8(request, request_len)?)
            .map_err(|e| format!("bad sync2 request: {e}"))?;
        let mut blobs = frames(bytes(blobs, blobs_len).ok_or("null blobs")?)?;
        let mut files = Vec::new();
        let result = super::gen4::dispatch::dispatch(c, &req, &mut blobs, &mut files)?;
        let text = serde_json::to_vec(&result).map_err(|e| e.to_string())?;
        let mut buf = Vec::with_capacity(text.len() + 8);
        buf.extend_from_slice(&(text.len() as u32).to_le_bytes());
        buf.extend_from_slice(&text);
        buf.extend_from_slice(&(files.len() as u32).to_le_bytes());
        for (p, b) in &files {
            push_frame(&mut buf, p.as_bytes());
            push_frame(&mut buf, b);
        }
        hand_out(buf, out, out_len);
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::legacy3::tests::dispatched_ops;
    use std::ffi::CString;
    use std::path::PathBuf;
    use std::ptr::{null, null_mut};
    use std::sync::{Barrier, Weak};

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ffsrs_store_ffi_{}_{}_{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn open(p: &Path) -> *mut SrsCoreHandle {
        let path = p.to_str().unwrap().as_bytes();
        let mut core: *mut SrsCoreHandle = null_mut();
        let mut err: *mut c_char = null_mut();
        assert_eq!(
            ffsrs_store_open_mode(path.as_ptr(), path.len(), 0, &mut core, &mut err),
            STORE_OK
        );
        assert!(!core.is_null());
        core
    }

    /// 取走错误文本（并释放）。
    fn take(err: *mut c_char) -> String {
        assert!(!err.is_null(), "no error message");
        unsafe { CString::from_raw(err) }.into_string().unwrap()
    }

    /// 结构体还活着（只看引用计数，不碰内容）。
    fn alive(weak: &Weak<G4Core>) -> bool {
        weak.strong_count() > 0
    }

    /// 内存诊断计数：空 / 零长度不写；按 n 截断、不越界；开着库时句柄、存活库、连接池与 SQLite 堆都有数，
    /// 高水位不低于当前用量。别的测试并行开关库，只断言下界。
    #[test]
    fn diag_counts_report_open_cores_and_respect_the_buffer_length() {
        assert_eq!(ffsrs_store_diag_counts(null_mut(), DIAG_COUNT_LEN), 0);
        let mut one = [-7i64; 1];
        assert_eq!(ffsrs_store_diag_counts(one.as_mut_ptr(), 0), 0);
        assert_eq!(one, [-7]);

        let p = temp("diag");
        let h = open(&p);
        let mut out = [-7i64; DIAG_COUNT_LEN + 2];
        assert_eq!(
            ffsrs_store_diag_counts(out.as_mut_ptr(), out.len()),
            DIAG_COUNT_LEN
        );
        assert_eq!(
            &out[DIAG_COUNT_LEN..],
            &[-7, -7],
            "must not write past the counts"
        );
        assert!(out[0] >= 1, "open handles {out:?}");
        assert!(out[1] >= 1, "live cores {out:?}");
        assert!(out[2] >= 1, "pooled readers {out:?}");
        assert!(out[3] > 0, "sqlite memory used {out:?}");
        assert!(out[4] >= out[3], "highwater below current use {out:?}");
        assert!(out[5] > 0, "open db bytes {out:?}");
        assert!(out[6] >= 0, "wal bytes {out:?}");

        let mut two = [-7i64; 3];
        assert_eq!(ffsrs_store_diag_counts(two.as_mut_ptr(), 2), 2);
        assert_eq!(two[2], -7);

        // 关掉之后在途调用还握着的那份照样算存活：退役的库驻留就是要看的东西。
        let held = resolve(h).unwrap();
        ffsrs_store_close(h);
        assert!(crate::store::gen4::kernel::live_cores() >= 1);
        drop(held);
        std::fs::remove_dir_all(&p).unwrap();
    }

    /// 关库后经旧句柄的每个入口都报「已关闭」（不 UAF、不按路径把库重新打开）；重复关闭无操作；
    /// 关库后结构体随即释放（回归：#2540 的修法让每开一次库泄漏一个结构体）。
    #[test]
    fn closed_handle_rejects_every_entry_point_and_frees_the_core() {
        let p = temp("closed");
        let h = open(&p);
        let weak = Arc::downgrade(&resolve(h).unwrap());
        ffsrs_store_close(h);
        assert!(
            !alive(&weak),
            "closing the last reference must free the core"
        );
        ffsrs_store_close(h);
        // 关库后 srs.db 可删（覆盖恢复）；之后任何入口都不许把它重新建出来。
        std::fs::remove_dir_all(&p).unwrap();

        let h = h as *const SrsCoreHandle;
        let mut out: *mut u8 = null_mut();
        let mut out_len: usize = 0;
        let mut flag: i32 = 0;
        let (o, ol, f) = (
            &mut out as *mut *mut u8,
            &mut out_len as *mut usize,
            &mut flag as *mut i32,
        );
        let sql: &[u8] = b"SELECT 1";
        let snap: &[u8] = b"snap.db";
        let req: &[u8] = br#"{"op":"status","profile":"p"}"#;
        let args = [0i64; 4];
        let a = args.as_ptr();
        type Call<'a> = (&'static str, Box<dyn Fn(*mut *mut c_char) -> i32 + 'a>);
        let calls: Vec<Call<'_>> = vec![
            (
                "snapshot",
                Box::new(|e| ffsrs_store_snapshot(h, snap.as_ptr(), snap.len(), 0, e)),
            ),
            (
                "debug_query",
                Box::new(|e| {
                    ffsrs_store_debug_query(h, sql.as_ptr(), sql.len(), null(), 0, o, ol, e)
                }),
            ),
            (
                "exec",
                Box::new(|e| ffsrs_store_exec(h, sql.as_ptr(), sql.len(), null(), 0, 1, o, ol, e)),
            ),
            (
                "exec_batch",
                Box::new(|e| ffsrs_store_exec_batch(h, null(), 0, null(), 0, e)),
            ),
            (
                "in_transaction",
                Box::new(|e| ffsrs_store_in_transaction(h, f, e)),
            ),
            (
                "history_states",
                Box::new(|e| ffsrs_store_history_states(h, null(), 0, 0, o, ol, e)),
            ),
            (
                "stat_projection",
                Box::new(|e| ffsrs_store_stat_projection(h, null(), 0, 0, o, ol, e)),
            ),
            (
                "optimizer_items",
                Box::new(|e| ffsrs_store_optimizer_items(h, null(), 0, a, 4, o, ol, e)),
            ),
            (
                "rwkv_rows",
                Box::new(|e| ffsrs_store_rwkv_rows(h, null(), 0, a, 4, o, ol, e)),
            ),
            (
                "rwkv_log_tail",
                Box::new(|e| ffsrs_store_rwkv_log_tail(h, null(), 0, a, 4, o, ol, e)),
            ),
            (
                "sync2",
                Box::new(|e| ffsrs_store_sync2(h, req.as_ptr(), req.len(), null(), 0, o, ol, e)),
            ),
        ];
        assert_eq!(calls.len(), 11);
        for (name, call) in &calls {
            let mut err: *mut c_char = null_mut();
            assert_eq!(call(&mut err), STORE_ERROR, "{name}");
            assert_eq!(take(err), CLOSED, "{name}");
        }
        drop(calls);
        assert!(out.is_null());
        assert!(
            !p.exists(),
            "a call on a closed store reopened srs.db by path"
        );
    }

    /// 在途命令期间关库：close 立即把句柄摘掉，在途调用手上那份引用让结构体活到它返回（不 UAF），
    /// 它返回后结构体才释放（不泄漏）；在途调用之后再碰连接得到「已关闭」，别的调用也一律「已关闭」。
    #[test]
    fn close_during_an_in_flight_command_neither_frees_under_it_nor_leaks() {
        let p = temp("inflight");
        let h = open(&p);
        let weak = Arc::downgrade(&resolve(h).unwrap());
        let entered = Arc::new(Barrier::new(2));
        let closed = Arc::new(Barrier::new(2));
        let worker = {
            let (entered, closed) = (Arc::clone(&entered), Arc::clone(&closed));
            let id = h as usize;
            std::thread::spawn(move || {
                let mut err: *mut c_char = null_mut();
                let rc = run_core(id as *const SrsCoreHandle, &mut err, |c| {
                    c.debug_query("SELECT 1", &[])?;
                    entered.wait();
                    closed.wait();
                    // 拥有者已经关库：结构体还在（这里拿它的锁不是 UAF），连接已经没了。
                    c.debug_query("SELECT 1", &[]).map(|_| ())
                });
                (rc, take(err))
            })
        };
        entered.wait();
        ffsrs_store_close(h);
        assert!(alive(&weak), "the in-flight call must keep the core alive");
        let mut err: *mut c_char = null_mut();
        let mut flag = 0;
        assert_eq!(
            ffsrs_store_in_transaction(h, &mut flag, &mut err),
            STORE_ERROR
        );
        assert_eq!(take(err), CLOSED);
        closed.wait();
        let (rc, msg) = worker.join().unwrap();
        assert_eq!((rc, msg.as_str()), (STORE_ERROR, CLOSED));
        assert!(
            !alive(&weak),
            "the core must be freed once the last in-flight call returns"
        );
        std::fs::remove_dir_all(&p).unwrap();
    }

    /// 压力：多线程不停跑命令时关库，每个调用不是成功就是「已关闭」，最后结构体释放。
    #[test]
    fn concurrent_commands_racing_close_only_see_ok_or_closed() {
        let p = temp("race");
        let h = open(&p);
        let weak = Arc::downgrade(&resolve(h).unwrap());
        let start = Arc::new(Barrier::new(5));
        let workers: Vec<_> = (0..4)
            .map(|_| {
                let start = Arc::clone(&start);
                let id = h as usize;
                std::thread::spawn(move || {
                    start.wait();
                    let h = id as *const SrsCoreHandle;
                    let sql: &[u8] = b"SELECT COUNT(*) FROM sqlite_master";
                    let mut ok = 0usize;
                    loop {
                        let mut out: *mut u8 = null_mut();
                        let mut out_len = 0usize;
                        let mut err: *mut c_char = null_mut();
                        let rc = ffsrs_store_debug_query(
                            h,
                            sql.as_ptr(),
                            sql.len(),
                            null(),
                            0,
                            &mut out,
                            &mut out_len,
                            &mut err,
                        );
                        if rc == STORE_OK {
                            crate::ffsrs_free_bytes(out, out_len);
                            ok += 1;
                            continue;
                        }
                        let msg = take(err);
                        assert_eq!((rc, msg.as_str()), (STORE_ERROR, CLOSED));
                        return ok;
                    }
                })
            })
            .collect();
        start.wait();
        std::thread::sleep(std::time::Duration::from_millis(50));
        ffsrs_store_close(h);
        let done: usize = workers.into_iter().map(|w| w.join().unwrap()).sum();
        assert!(done > 0);
        assert!(!alive(&weak));
        std::fs::remove_dir_all(&p).unwrap();
    }

    /// 换代（S1）：协议 3 分发器里的每一条命令在新代分发器里都有去向（接线 / 归某模块接线 / 已删，
    /// `gen4/dispatch.rs` `wiring`），不会落进「unknown op」；标成接线的在新代分发器里真有臂（经 C ABI 发出去，错误
    /// 不是 `NO_ARM`）；未接线 / 已删的报各自的明确错误。新增协议 3 命令或改了去向而没登记就红。
    #[test]
    fn every_protocol_3_command_has_a_gen4_wiring() {
        use crate::store::gen4::dispatch::{NO_ARM, Wiring, wiring};
        use crate::store::gen4::kernel::{REMOVED, UNWIRED};
        let ops = dispatched_ops();
        assert!(ops.len() > 60, "parsed too few commands: {ops:?}");
        let p = temp("wiring");
        let h = open(&p);
        let (mut wired, mut unwired, mut gone) = (0, 0, 0);
        for op in &ops {
            let w = wiring(op)
                .unwrap_or_else(|| panic!("protocol 3 command `{op}` has no gen4 wiring"));
            let req =
                serde_json::json!({"op": op, "profile": "0193a1b2-0000-7000-8000-00000000beef"})
                    .to_string();
            let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
            let rc = ffsrs_store_sync2(
                h,
                req.as_ptr(),
                req.len(),
                null(),
                0,
                &mut out,
                &mut out_len,
                &mut err,
            );
            let msg = if rc == STORE_OK {
                crate::ffsrs_free_bytes(out, out_len);
                String::new()
            } else {
                take(err)
            };
            assert_ne!(rc, STORE_PANIC, "{op}: {msg}");
            match w {
                Wiring::Wired => {
                    wired += 1;
                    assert!(!msg.starts_with(NO_ARM), "{op}: {msg}");
                    assert!(
                        !msg.starts_with(UNWIRED) && !msg.starts_with(REMOVED),
                        "{op}: {msg}"
                    );
                }
                Wiring::Unwired(owner) => {
                    unwired += 1;
                    assert_eq!(rc, STORE_ERROR, "{op}");
                    assert!(
                        msg.starts_with(UNWIRED) && msg.contains(owner),
                        "{op}: {msg}"
                    );
                }
                Wiring::Removed(_) => {
                    gone += 1;
                    assert_eq!(rc, STORE_ERROR, "{op}");
                    assert!(msg.starts_with(REMOVED), "{op}: {msg}");
                }
            }
        }
        assert!(
            // W3 合流后各模块都已接线，不再有未接线命令。
            wired > 40 && unwired == 0 && gone > 8,
            "{wired} / {unwired} / {gone}"
        );
        ffsrs_store_close(h);
        std::fs::remove_dir_all(&p).unwrap();
    }
}
