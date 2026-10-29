//! srs.db 的 C ABI（Dart 绑定：packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart）。
//!
//! 约定与 lib.rs 其余部分相同：返回 i32 状态（0 成功，负数失败），失败时 `*error_out` 是新分配的
//! C 字符串（用 `ffsrs_free_string` 释放）；Rust 分配的字节用 `ffsrs_free_bytes` 释放；panic 一律
//! 接住转成 -100。
//!
//! 库句柄（[SrsCoreHandle]）**不是指针**，是句柄表里的一个编号：Dart 把句柄地址交给后台 isolate
//! （`SrsCore.fromAddress`），拥有者关库时那边可能还在调用、甚至之后才调用。每次调用先在句柄表里
//! 取出一份 `Arc<SrsCore>` 再干活，关库把它从表里摘掉：在途调用手上那份让结构体活到它跑完，之后
//! 再来的调用查不到编号、报「已关闭」，最后一份引用放掉时结构体真正释放。编号单调递增不复用，
//! 旧句柄不会误指到后来打开的库。只读会话句柄（[ReadSessionHandle]）同理，另一张表；会话随所属的库
//! 关闭而失效（连接关掉、之后报「已关闭」），表项留到 [ffsrs_store_read_end]。线程安全，可在任意
//! isolate 上用。

use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use super::{ReadSession, SrsCore, CLOSED};

pub const STORE_OK: i32 = 0;
pub const STORE_ERROR: i32 = -1;
pub const STORE_BAD_ARGUMENT: i32 = -2;
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
static HANDLES: Mutex<BTreeMap<usize, Arc<SrsCore>>> = Mutex::new(BTreeMap::new());

/// 只读会话句柄的不透明类型：值是 [SESSIONS] 里的编号，从不解引用。
pub enum ReadSessionHandle {}

/// 没结束的只读会话：编号 → 共享引用（同 [HANDLES]，只在取 / 放引用时持锁）。
static SESSIONS: Mutex<BTreeMap<usize, Arc<ReadSession>>> = Mutex::new(BTreeMap::new());

/// 下一个句柄编号（0 留给 NULL；库与会话共用，单调递增，不复用）。
static NEXT_HANDLE: AtomicUsize = AtomicUsize::new(1);

fn sessions() -> std::sync::MutexGuard<'static, BTreeMap<usize, Arc<ReadSession>>> {
    SESSIONS.lock().unwrap_or_else(|e| e.into_inner())
}

/// 跑一段带会话句柄的操作（已结束 / 从没开过 = 「已关闭」）。
fn run_session(
    session: *const ReadSessionHandle,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&ReadSession) -> Result<(), String>,
) -> i32 {
    if session.is_null() {
        set_error(error_out, "null srs handle");
        return STORE_BAD_ARGUMENT;
    }
    let found = sessions().get(&(session as usize)).cloned();
    let Some(s) = found else {
        set_error(error_out, CLOSED);
        return STORE_ERROR;
    };
    run(Arc::as_ptr(&s), error_out, body)
}

fn handles() -> std::sync::MutexGuard<'static, BTreeMap<usize, Arc<SrsCore>>> {
    // 锁里只有 BTreeMap 的增删查，不跑用户代码；就算哪次 panic 毒化了锁，表本身也完好。
    HANDLES.lock().unwrap_or_else(|e| e.into_inner())
}

fn register(core: SrsCore) -> *mut SrsCoreHandle {
    let id = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    handles().insert(id, Arc::new(core));
    id as *mut SrsCoreHandle
}

/// 取出句柄对应的库（已关闭 / 从没打开过 = None）。
fn resolve(core: *const SrsCoreHandle) -> Option<Arc<SrsCore>> {
    handles().get(&(core as usize)).cloned()
}

/// 跑一段带库句柄的操作：调用期间手上握着一份 `Arc`，关库不会把结构体从脚下释放掉。
fn run_core(
    core: *const SrsCoreHandle,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&SrsCore) -> Result<(), String>,
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

/// 跑一段带句柄（[SrsCore] / [ReadSession]）的操作，统一处理空指针、错误与 panic。
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

/// 打开 / 新建 srs.db。成功写 `*core_out`；用 [ffsrs_store_close] 关闭。
#[no_mangle]
pub extern "C" fn ffsrs_store_open(
    path: *const u8,
    path_len: usize,
    core_out: *mut *mut SrsCoreHandle,
    error_out: *mut *mut c_char,
) -> i32 {
    if core_out.is_null() {
        set_error(error_out, "null core_out");
        return STORE_BAD_ARGUMENT;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<SrsCore, String> {
        SrsCore::open(Path::new(utf8(path, path_len)?))
    }));
    match outcome {
        Ok(Ok(core)) => {
            unsafe { *core_out = register(core) };
            STORE_OK
        }
        Ok(Err(e)) => {
            set_error(error_out, &e);
            STORE_ERROR
        }
        Err(_) => {
            set_error(error_out, "panic in srs store open");
            STORE_PANIC
        }
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

/// `*out` = 1 已搬迁（或确认没有可搬的），0 未搬迁。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_state(
    core: *const SrsCoreHandle,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let v = c.legacy_imported()?;
        unsafe { *out = v as i32 };
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_begin(core: *const SrsCoreHandle, error_out: *mut *mut c_char) -> i32 {
    run_core(core, error_out, |c| c.legacy_begin())
}

/// 一页旧表行（rows.rs 编码）。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_page(
    core: *const SrsCoreHandle,
    table: *const u8,
    table_len: usize,
    page: *const u8,
    page_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    run_core(core, error_out, |c| {
        let t = utf8(table, table_len)?;
        let p = bytes(page, page_len).ok_or("null page")?;
        c.legacy_page(t, p).map(|_| ())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_commit(core: *const SrsCoreHandle, error_out: *mut *mut c_char) -> i32 {
    run_core(core, error_out, |c| c.legacy_commit())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_abort(core: *const SrsCoreHandle, error_out: *mut *mut c_char) -> i32 {
    run_core(core, error_out, |c| c.legacy_abort())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_mark_none(
    core: *const SrsCoreHandle,
    error_out: *mut *mut c_char,
) -> i32 {
    run_core(core, error_out, |c| c.legacy_mark_none())
}

/// `VACUUM INTO` 一份快照；`strip_device_local != 0` 时清空设备本地表。
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

/// 只读会话（`SrsCore::read_session`）：另开一条只读连接、开读事务并定下快照。成功写 `*session_out`；
/// 用 [ffsrs_store_read_end] 结束（回滚并关闭）。会话可以在别的线程 / isolate 上用，但同一时刻只许一个调用。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_begin(
    core: *const SrsCoreHandle,
    session_out: *mut *mut ReadSessionHandle,
    error_out: *mut *mut c_char,
) -> i32 {
    if session_out.is_null() {
        set_error(error_out, "null session_out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let s = c.read_session()?;
        let id = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        sessions().insert(id, s);
        unsafe { *session_out = id as *mut ReadSessionHandle };
        Ok(())
    })
}

/// 在只读会话的读事务里跑一条只读语句。参数页 / 结果编码同 [ffsrs_store_debug_query]。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_query(
    session: *const ReadSessionHandle,
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
    run_session(session, error_out, |r| {
        let s = utf8(sql, sql_len)?;
        let values = one_row(bytes(params, params_len).ok_or("null params")?)?;
        hand_out(r.query(s, &values)?, out, out_len);
        Ok(())
    })
}

/// 结束只读会话（NULL 无操作，重复结束无操作）：从表里摘掉、等在途查询跑完后回滚并关连接；之后经这个
/// 句柄的查询报「已关闭」。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_end(session: *mut ReadSessionHandle) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let removed = sessions().remove(&(session as usize));
        if let Some(s) = removed {
            s.close();
        }
    }));
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

/// Drift 执行器：执行一条语句。`select`：0 = 写语句（写连接，返回一行 `[变更行数, last_insert_rowid]`）；
/// 1 = 写连接上的语句、返回结果行（`runCustom`：事务控制、PRAGMA）；2 = Drift 的查询（`runSelect`，
/// [SrsCore::select]：Drift 事务外的只读查询走读连接的快照）。1 / 2 返回「列名行 + 结果行」；缓冲区用
/// `ffsrs_free_bytes` 释放。
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
            0 => c.exec(s, &values, false)?,
            1 => c.exec(s, &values, true)?,
            2 => c.select(s, &values)?,
            m => return Err(format!("unknown exec mode {m}")),
        };
        hand_out(page, out, out_len);
        Ok(())
    })
}

/// Drift 批量语句。`statements` 是单列文本页（每行一条 SQL）；`applications` 是两列页：
/// `[语句下标 i64, 参数页 blob]`（参数页是一行的 rows.rs 页，可为空字节）。
#[no_mangle]
pub extern "C" fn ffsrs_store_exec_batch(
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
        let (_, app_rows) = super::rows::decode(
            bytes(applications, applications_len).ok_or("null applications")?,
        )?;
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
        c.exec_batch(&refs, &apps)
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

/// 卡片历史的当前状态（直读写连接）。`groups` 是两列页 `[历史下标 i64, 卡 ID 文本]`，共
/// `n_groups` 份历史；输出布局同 `ffsrs_history_states`，用 `ffsrs_free_bytes` 释放。
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
    use rusqlite::types::Value;
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run_core(core, error_out, |c| {
        let (_, rows) = super::rows::decode(bytes(groups, groups_len).ok_or("null groups")?)?;
        let mut lineages: Vec<Vec<String>> = vec![Vec::new(); n_groups];
        for r in rows {
            let mut it = r.into_iter();
            match (it.next(), it.next()) {
                (Some(Value::Integer(g)), Some(Value::Text(card)))
                    if g >= 0 && (g as usize) < n_groups =>
                {
                    lineages[g as usize].push(card)
                }
                _ => return Err("bad history group row".into()),
            }
        }
        hand_out(c.history_states(&lineages)?, out, out_len);
        Ok(())
    })
}

/// 有效复习投影（直读写连接）。`groups` 同 [ffsrs_store_history_states]（两列页 `[组下标, 卡 ID]`），
/// 每组是一个归属组（归属卡 + 归它的前身卡）；输出是 9 列行页（见 `SrsCore::stat_projection`），
/// 用 `ffsrs_free_bytes` 释放。
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
        let lineages = decode_groups(bytes(groups, groups_len).ok_or("null groups")?, n_groups)?;
        hand_out(c.stat_projection(&lineages)?, out, out_len);
        Ok(())
    })
}

/// 两列页 `[组下标 i64, 卡 ID 文本]` → 每组的卡 ID（组内保持页里的顺序）。
fn decode_groups(page: &[u8], n_groups: usize) -> Result<Vec<Vec<String>>, String> {
    use rusqlite::types::Value;
    let (_, rows) = super::rows::decode(page)?;
    let mut groups: Vec<Vec<String>> = vec![Vec::new(); n_groups];
    for r in rows {
        let mut it = r.into_iter();
        match (it.next(), it.next()) {
            (Some(Value::Integer(g)), Some(Value::Text(card))) if g >= 0 && (g as usize) < n_groups => {
                groups[g as usize].push(card)
            }
            _ => return Err("bad history group row".into()),
        }
    }
    Ok(groups)
}

// ---------------------------------------------------------------- P6 直读命令（store/projections.rs）

/// 命令的输入页：两列 `[下标 i64, 文本]`。下标 g ≥ 0 = 第 g 份历史的血统里的一张卡；-1 = profile uid。
fn lineage_page(page: &[u8], n_groups: usize) -> Result<(Vec<Vec<String>>, Option<String>), String> {
    use rusqlite::types::Value;
    let (_, rows) = super::rows::decode(page)?;
    let mut lineages: Vec<Vec<String>> = vec![Vec::new(); n_groups];
    let mut profile = None;
    for r in rows {
        let mut it = r.into_iter();
        match (it.next(), it.next()) {
            (Some(Value::Integer(-1)), Some(Value::Text(p))) => profile = Some(p),
            (Some(Value::Integer(g)), Some(Value::Text(card))) if g >= 0 && (g as usize) < n_groups => {
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
    body: impl FnOnce(&SrsCore, &[u8], &[i64]) -> Result<Vec<u8>, String>,
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
    args.get(k).copied().ok_or_else(|| format!("missing argument {k}"))
}

fn day_of(args: &[i64], k: usize) -> Result<crate::projection::Day, String> {
    Ok(crate::projection::Day { utc_offset_min: arg(args, k)?, rollover_hour: arg(args, k + 1)? })
}

fn group_count(args: &[i64]) -> Result<usize, String> {
    usize::try_from(arg(args, 0)?).map_err(|_| "negative group count".to_string())
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
    command(core, page, page_len, args, n_args, out, out_len, error_out, |c, page, args| {
        let n = group_count(args)?;
        let (lineages, _) = lineage_page(page, n)?;
        let alg = crate::projection::Alg::from_code(arg(args, 1)?)?;
        let ids = args.get(4..4 + n).ok_or("missing card ids")?;
        c.optimizer_items(&lineages, ids, alg, &day_of(args, 2)?)
    })
}

/// RWKV 回放行。`args = [n_groups, mode, utcOffsetMin, rolloverHour, since, 数字 id × 4·n_groups]`；
/// mode 0 = 逐卡（`SrsCore::rwkv_cards`），1 = 全量回放（`SrsCore::rwkv_replay`，页里要有 profile 行）。
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
    command(core, page, page_len, args, n_args, out, out_len, error_out, |c, page, args| {
        let n = group_count(args)?;
        let (lineages, profile) = lineage_page(page, n)?;
        let ids = args.get(5..5 + 4 * n).ok_or("missing rwkv ids")?;
        let day = day_of(args, 2)?;
        match arg(args, 1)? {
            0 => c.rwkv_cards(&lineages, ids, &day),
            1 => c.rwkv_replay(profile.as_deref().ok_or("missing profile")?, &lineages, ids, &day, arg(args, 4)?),
            m => Err(format!("unknown rwkv mode {m}")),
        }
    })
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
    command(core, page, page_len, args, n_args, out, out_len, error_out, |c, page, args| {
        let (_, profile) = lineage_page(page, 0)?;
        c.rwkv_log_tail(
            profile.as_deref().ok_or("missing profile")?,
            arg(args, 0)?,
            arg(args, 1)? != 0,
            args.get(2).copied().unwrap_or(0) != 0,
        )
    })
}

// ---------------------------------------------------------------- 同步 v2（store/sync2）

/// 分帧字节块：`u32 n`，再 n 个 `u32 len + 字节`（小端）。空输入 = 0 块。
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

fn key32(v: &serde_json::Value) -> Result<Option<[u8; 32]>, String> {
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

fn sync2_dispatch(c: &SrsCore, req: &serde_json::Value, blobs: &[Vec<u8>], files: &mut Vec<(String, Vec<u8>)>) -> Result<serde_json::Value, String> {
    use serde_json::{json, Value};
    let s = |k: &str| req.get(k).and_then(Value::as_str).ok_or_else(|| format!("sync2: missing {k}"));
    let i = |k: &str| req.get(k).and_then(Value::as_i64).ok_or_else(|| format!("sync2: missing {k}"));
    // 不针对单个 profile 的命令（store/profile_data.rs 找无主数据；WAL 并回）。
    match s("op")? {
        "profile_uids" => return c.profile_uids(),
        "orphan_sweep_done" => return c.orphan_sweep_done(i("now")?),
        // 不占写连接的 WAL 并回（store/mod.rs）：大批写入收尾用。
        "wal_checkpoint" => return c.wal_checkpoint(),
        // 有写入在等写锁：正在投的收段那一片尽快收（只置一个标志，等锁的一侧直接同步调）。
        "ingest_yield" => {
            c.sync2_ingest_yield();
            return Ok(json!({}));
        }
        _ => {}
    }
    let profile = s("profile")?;
    let op = s("op")?;
    // 改投影的命令：同一次调用里接着刷新本机缓存行（store/caches.rs），Dart 只收写过哪些笔记 / 卡。缓存配置
    // （内置笔记类型的代码默认值、默认牌组）只有 Dart 知道，随命令带来；缺了是调用方的 bug，不跳过刷新。
    if PROJECTING_OPS.contains(&op) || op == "refresh_caches" || op == "rebuild_caches" {
        let cfg = crate::store::caches::CacheConfig::parse(req.get("caches").ok_or("sync2: missing caches")?)?;
        let mut v = match op {
            "refresh_caches" => json!({}),
            "rebuild_caches" => {
                let w = c.writer()?;
                let written = crate::store::sync2::in_savepoint(&w, |conn| crate::store::caches::rebuild(conn, profile, &cfg))?;
                return Ok(json!({"cache": written.to_json()}));
            }
            _ => sync2_command(c, op, profile, req, blobs, files)?,
        };
        let mut dirty = crate::store::caches::Dirty::of_projection(&v);
        if op == "refresh_caches" {
            let ids = |k: &str, into: &mut std::collections::BTreeSet<String>| {
                for x in req.get(k).and_then(Value::as_array).into_iter().flatten() {
                    if let Some(id) = x.as_str() {
                        into.insert(id.to_owned());
                    }
                }
            };
            ids("notes", &mut dirty.notes);
            ids("cards", &mut dirty.cards);
            ids("noteTypes", &mut dirty.note_types);
            dirty.all_notes = req["allNotes"] == Value::Bool(true);
            dirty.all_stats = req["allStats"] == Value::Bool(true);
        }
        let w = c.writer()?;
        let written = crate::store::sync2::in_savepoint(&w, |conn| crate::store::caches::refresh(conn, profile, &cfg, dirty))?;
        // 本机作答：落库、刷新缓存之后接着在同一条写连接上排队（下一张 + 牌组计数，store/study.rs），复习页一次
        // 评分一次命令。看得见这笔还没提交的写入。
        let study = match req.get("study").filter(|s| s.is_object()) {
            Some(s) => Some(crate::store::study::study(&w, &c.study_hub, true, profile, s)?),
            None => None,
        };
        if let Some(m) = v.as_object_mut() {
            m.insert("cache".to_owned(), written.to_json());
            if let Some(s) = study {
                m.insert("study".to_owned(), s);
            }
        }
        return Ok(v);
    }
    sync2_command(c, op, profile, req, blobs, files)
}

/// 改投影的 v2 命令（结果带 `marks`）：分发器在同一次调用里刷新缓存行。
const PROJECTING_OPS: [&str; 10] = ["apply", "ingest", "ingest_batch", "ingest_commit", "ingest_finish", "import", "resolve", "purge", "checkpoint", "restore"];

fn sync2_command(
    c: &SrsCore,
    op: &str,
    profile: &str,
    req: &serde_json::Value,
    blobs: &[Vec<u8>],
    files: &mut Vec<(String, Vec<u8>)>,
) -> Result<serde_json::Value, String> {
    use serde_json::{json, Value};
    let s = |k: &str| req.get(k).and_then(Value::as_str).ok_or_else(|| format!("sync2: missing {k}"));
    let i = |k: &str| req.get(k).and_then(Value::as_i64).ok_or_else(|| format!("sync2: missing {k}"));
    let parse = |t: String| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string());
    Ok(match op {
        "identity" => c.sync2_identity(profile, i("now")?)?,
        "apply" => {
            let input = std::str::from_utf8(blobs.first().ok_or("apply: missing input")?).map_err(|e| e.to_string())?;
            parse(c.sync2_apply_local(profile, i("now")?, input)?)?
        }
        "migrate" => c.sync2_migrate(profile, i("now")?, req.get("limit").and_then(Value::as_u64))?,
        "replay_all" => json!(c.sync2_replay_all(profile)?),
        // 排队：牌组计数 + 出卡（store/study.rs），只读快照。
        "study" => c.study(profile, req)?,
        // 卡片浏览的常驻会话（store/browse.rs）：查询（筛选 + 排序）、取行、取行 id、批量目标、关闭。
        "browse_query" | "browse_rows" | "browse_ids" | "browse_targets" | "browse_close" => c.browse(op, profile, req, files)?,
        // 一组卡各自的血统（自己 + 全部前身，store/caches.rs `lineage_ids`）：卡片历史用。看得见本机写事务里未提交的行。
        "lineages" => {
            let cards: Vec<String> = req.get("cards").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
            json!(c.read_visible(|conn| crate::store::caches::lineage_ids(conn, &cards))?)
        }
        "preview" => c.sync2_preview(profile, s("card")?, req.get("note").and_then(Value::as_str), i("now")?, i("utcOff")?, i("rollover")?)?,
        // 分批发件：一批上传完用 outbox_ack 交回 segments 推进水位，more 为真再取下一批（store/sync2/transport.rs）。
        "outbox" => {
            let max_bytes = req.get("maxBytes").and_then(Value::as_u64).unwrap_or(crate::store::sync2::transport::OUTBOX_BATCH_BYTES);
            let max_segments =
                req.get("maxSegments").and_then(Value::as_u64).map_or(crate::store::sync2::transport::OUTBOX_BATCH_SEGMENTS, |n| n as usize);
            let batch = c.sync2_outbox(profile, s("location")?, key32(&req["key"])?, max_bytes.max(1), max_segments.max(1))?;
            *files = batch.files;
            json!({"upto": batch.upto, "more": batch.more, "segments": batch.segments})
        }
        "outbox_ack" => {
            let segments: Vec<(u64, u64)> = req
                .get("segments")
                .and_then(Value::as_array)
                .ok_or("sync2: missing segments")?
                .iter()
                .map(|p| match p.as_array().map(|x| (x.first().and_then(Value::as_u64), x.get(1).and_then(Value::as_u64))) {
                    Some((Some(a), Some(b))) => Ok((a, b)),
                    _ => Err("sync2: bad segment pair".to_string()),
                })
                .collect::<Result<_, _>>()?;
            let (accepted, uploaded) = c.sync2_outbox_ack(profile, s("location")?, &segments)?;
            json!({"accepted": accepted, "uploaded": uploaded})
        }
        // `skipUnchangedMs`：内容与上次写出的相同且未到期时不写（见 `sync2_head_if_changed`），回 `unchanged` + 上次的路径。
        "head" => {
            let skip = req.get("skipUnchangedMs").and_then(Value::as_i64);
            match c.sync2_head_if_changed(profile, s("location")?, i("upto")? as u64, i("now")?, skip)? {
                crate::store::sync2::transport::HeadWrite::Written { path, bytes, gen, obsolete } => {
                    files.push((path, bytes));
                    json!({"gen": gen, "delete": obsolete})
                }
                crate::store::sync2::transport::HeadWrite::Unchanged { path } => {
                    json!({"unchanged": true, "path": path})
                }
            }
        }
        "plan" => c.sync2_plan(profile, blobs)?,
        "ingest" => parse(c.sync2_ingest(profile, blobs, key32(&req["key"])?, i("now")?)?)?,
        "ingest_begin" => c.sync2_ingest_begin(profile)?,
        "ingest_batch" => parse(c.sync2_ingest_batch(profile, blobs, key32(&req["key"])?, i("now")?)?)?,
        // 拆开的一批：prepare 在写锁外解码验签（Dart 侧也不进写锁），commit 在写锁里投递。
        "ingest_prepare" => c.sync2_ingest_prepare(profile, blobs, key32(&req["key"])?)?,
        // 一次投一片（默认按时间切、有写入排队就让出；测试用 `sliceOps` 按条数切、`sliceMs` 改时间上限）；结果
        // `more` 为真 Dart 放开写锁再调。
        "ingest_commit" => {
            use crate::store::sync2::transport::CommitBudget;
            let budget = match (req.get("sliceOps").and_then(Value::as_u64), req.get("sliceMs").and_then(Value::as_u64)) {
                (Some(n), _) => CommitBudget::ops(n as usize),
                (None, Some(ms)) => CommitBudget::slice_within(c.ingest_yield_flag(), std::time::Duration::from_millis(ms)),
                (None, None) => CommitBudget::slice(c.ingest_yield_flag()),
            };
            parse(c.sync2_ingest_commit(profile, i("now")?, budget)?)?
        }
        "ingest_finish" => parse(c.sync2_ingest_finish(profile, i("now")?)?)?,
        "rotate" => c.sync2_rotate(profile, i("now")?)?,
        "export" => {
            files.push(("export.fushisrs".to_owned(), c.sync2_export(profile)?));
            json!({})
        }
        "import" => parse(c.sync2_import(profile, blobs.first().ok_or("import: missing file")?, i("now")?)?)?,
        // 加密位置上的媒体（设计 §9：网盘只见密文和文件大小）：XChaCha20-Poly1305，AAD 绑定文件名，
        // 换名 / 换内容即解密失败。段的加解密在 outbox / ingest 里，这里只给媒体用。
        "seal" | "open" => {
            let key = crate::sync2::keys::CollectionKey(key32(&req["key"])?.ok_or("seal/open: missing key")?);
            let aad = format!("fushi-srs-media:{}", s("name")?);
            let input = blobs.first().ok_or("seal/open: missing input")?;
            if op == "seal" {
                files.push(("sealed".to_owned(), key.seal(input, aad.as_bytes())));
            } else {
                files.push(("plain".to_owned(), key.open(input, aad.as_bytes()).ok_or("media decrypt failed")?));
            }
            json!({})
        }
        "digest" => match req.get("minIntervalMs").and_then(Value::as_i64) {
            Some(ms) => c.sync2_digest_due(profile, i("now")?, Some(ms))?,
            None => c.sync2_digest(profile)?,
        },
        "status" => c.sync2_status(profile)?,
        // 位置媒体目录的已知内容 / 记下事实（store/sync2/media.rs）：媒体对账读日志投影，不列目录。
        "media_known" => c.sync2_media_known(profile, s("location")?)?,
        "media_record" => {
            let names = |k: &str| -> Vec<String> {
                req.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect()).unwrap_or_default()
            };
            c.sync2_media_record(profile, s("location")?, &names("present"), &names("absent"), req["seeded"] == Value::Bool(true), i("now")?)?
        }
        // 删 profile 的级联清理（store/profile_data.rs）：确认框的规模、一个事务里删光本机数据。
        "profile_footprint" => c.profile_footprint(profile)?,
        "profile_purge" => c.profile_purge(profile)?,
        "conflicts" => c.sync2_conflicts(profile)?,
        "resolve" => c.sync2_resolve(profile, s("conflict")?, req["delete"] == Value::Bool(true), i("now")?)?,
        "purge" => c.sync2_purge(profile, s("kind")?, s("entity")?, i("now")?)?,
        "checkpoint" => c.sync2_checkpoint(profile, s("name")?, s("reason")?, i("now")?)?,
        "checkpoints" => c.sync2_checkpoints(profile)?,
        "history" => c.sync2_history(profile, s("kind")?, s("entity")?)?,
        "plan_restore" | "restore" => {
            // 恢复到还原点（`checkpoint: {device, seq}`，按它的因果截断）或某个时刻（`at`）。
            let to = match req.get("checkpoint") {
                Some(cp) if cp.is_object() => crate::store::sync2::timeline::RestoreTarget::Checkpoint(crate::sync2::vv::OpId {
                    device: crate::sync2::id::Id::parse(cp["device"].as_str().ok_or("checkpoint.device")?).ok_or("bad checkpoint device")?,
                    seq: cp["seq"].as_u64().ok_or("checkpoint.seq")?,
                }),
                _ => crate::store::sync2::timeline::RestoreTarget::At(i("at")?),
            };
            let retract = req["retract"] == Value::Bool(true);
            if op == "plan_restore" {
                c.sync2_plan_restore(profile, &to, retract, i("now")?)?
            } else {
                c.sync2_restore(profile, &to, retract, i("now")?)?
            }
        }
        "derive_key" => {
            let salt_hex = s("salt")?;
            let salt: Vec<u8> = (0..salt_hex.len() / 2)
                .map(|k| u8::from_str_radix(&salt_hex[2 * k..2 * k + 2], 16))
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?;
            let params = crate::sync2::keys::KdfParams::checked(i("m")?, i("t")?, i("p")?)?;
            let k = crate::sync2::keys::CollectionKey::derive(s("passphrase")?.as_bytes(), &salt, params)?;
            json!({"key": k.0.iter().map(|b| format!("{b:02x}")).collect::<String>()})
        }
        other => return Err(format!("unknown sync2 op {other}")),
    })
}

/// 同步 v2 的唯一入口（粗粒度命令，设计 §11；命令表见 `sync2_dispatch`）。请求是 JSON
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
        let req: serde_json::Value =
            serde_json::from_str(utf8(request, request_len)?).map_err(|e| format!("bad sync2 request: {e}"))?;
        let blobs = frames(bytes(blobs, blobs_len).ok_or("null blobs")?)?;
        let mut files = Vec::new();
        let result = sync2_dispatch(c, &req, &blobs, &mut files)?;
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
        dir.join("srs.db")
    }

    fn open(p: &Path) -> *mut SrsCoreHandle {
        let path = p.to_str().unwrap().as_bytes();
        let mut core: *mut SrsCoreHandle = null_mut();
        let mut err: *mut c_char = null_mut();
        assert_eq!(ffsrs_store_open(path.as_ptr(), path.len(), &mut core, &mut err), STORE_OK);
        assert!(!core.is_null());
        core
    }

    /// 取走错误文本（并释放）。
    fn take(err: *mut c_char) -> String {
        assert!(!err.is_null(), "no error message");
        unsafe { CString::from_raw(err) }.into_string().unwrap()
    }

    /// 结构体还活着（只看引用计数，不碰内容）。
    fn alive(weak: &Weak<SrsCore>) -> bool {
        weak.strong_count() > 0
    }

    /// 关库后经旧句柄的每个入口都报「已关闭」（不 UAF、不按路径把库重新打开）；重复关闭无操作；
    /// 关库后结构体随即释放（回归：#2540 的修法让每开一次库泄漏一个结构体）。
    #[test]
    fn closed_handle_rejects_every_entry_point_and_frees_the_core() {
        let p = temp("closed");
        let h = open(&p);
        let weak = Arc::downgrade(&resolve(h).unwrap());
        ffsrs_store_close(h);
        assert!(!alive(&weak), "closing the last reference must free the core");
        ffsrs_store_close(h);
        // 关库后 srs.db 可删（覆盖恢复）；之后任何入口都不许把它重新建出来。
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();

        let h = h as *const SrsCoreHandle;
        let mut out: *mut u8 = null_mut();
        let mut out_len: usize = 0;
        let mut flag: i32 = 0;
        let mut session: *mut ReadSessionHandle = null_mut();
        let (o, ol, f, s) = (
            &mut out as *mut *mut u8,
            &mut out_len as *mut usize,
            &mut flag as *mut i32,
            &mut session as *mut *mut ReadSessionHandle,
        );
        let sql: &[u8] = b"SELECT 1";
        let snap: &[u8] = b"snap.db";
        let req: &[u8] = br#"{"op":"status","profile":"p"}"#;
        let args = [0i64; 4];
        let a = args.as_ptr();
        type Call<'a> = (&'static str, Box<dyn Fn(*mut *mut c_char) -> i32 + 'a>);
        let calls: Vec<Call<'_>> = vec![
            ("legacy_state", Box::new(|e| ffsrs_store_legacy_state(h, f, e))),
            ("legacy_begin", Box::new(|e| ffsrs_store_legacy_begin(h, e))),
            ("legacy_page", Box::new(|e| ffsrs_store_legacy_page(h, sql.as_ptr(), 1, null(), 0, e))),
            ("legacy_commit", Box::new(|e| ffsrs_store_legacy_commit(h, e))),
            ("legacy_abort", Box::new(|e| ffsrs_store_legacy_abort(h, e))),
            ("legacy_mark_none", Box::new(|e| ffsrs_store_legacy_mark_none(h, e))),
            ("snapshot", Box::new(|e| ffsrs_store_snapshot(h, snap.as_ptr(), snap.len(), 0, e))),
            ("debug_query", Box::new(|e| ffsrs_store_debug_query(h, sql.as_ptr(), sql.len(), null(), 0, o, ol, e))),
            ("read_begin", Box::new(|e| ffsrs_store_read_begin(h, s, e))),
            ("exec", Box::new(|e| ffsrs_store_exec(h, sql.as_ptr(), sql.len(), null(), 0, 1, o, ol, e))),
            ("exec_batch", Box::new(|e| ffsrs_store_exec_batch(h, null(), 0, null(), 0, e))),
            ("in_transaction", Box::new(|e| ffsrs_store_in_transaction(h, f, e))),
            ("history_states", Box::new(|e| ffsrs_store_history_states(h, null(), 0, 0, o, ol, e))),
            ("stat_projection", Box::new(|e| ffsrs_store_stat_projection(h, null(), 0, 0, o, ol, e))),
            ("optimizer_items", Box::new(|e| ffsrs_store_optimizer_items(h, null(), 0, a, 4, o, ol, e))),
            ("rwkv_rows", Box::new(|e| ffsrs_store_rwkv_rows(h, null(), 0, a, 4, o, ol, e))),
            ("rwkv_log_tail", Box::new(|e| ffsrs_store_rwkv_log_tail(h, null(), 0, a, 4, o, ol, e))),
            ("sync2", Box::new(|e| ffsrs_store_sync2(h, req.as_ptr(), req.len(), null(), 0, o, ol, e))),
        ];
        assert_eq!(calls.len(), 18);
        for (name, call) in &calls {
            let mut err: *mut c_char = null_mut();
            assert_eq!(call(&mut err), STORE_ERROR, "{name}");
            assert_eq!(take(err), CLOSED, "{name}");
        }
        drop(calls);
        assert!(out.is_null() && session.is_null());
        assert!(!p.exists(), "a call on a closed store reopened srs.db by path");
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
        assert_eq!(ffsrs_store_in_transaction(h, &mut flag, &mut err), STORE_ERROR);
        assert_eq!(take(err), CLOSED);
        closed.wait();
        let (rc, msg) = worker.join().unwrap();
        assert_eq!((rc, msg.as_str()), (STORE_ERROR, CLOSED));
        assert!(!alive(&weak), "the core must be freed once the last in-flight call returns");
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
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
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
    }

    /// 经 C ABI：开会话 → 关库 → 会话查询报已关闭，库文件可改名 / 删除；read_end 之后同样报已关闭，
    /// 重复 read_end 无操作。
    #[test]
    fn closing_the_store_invalidates_its_read_sessions() {
        let p = temp("sessions");
        let h = open(&p);
        let mut session: *mut ReadSessionHandle = null_mut();
        let mut err: *mut c_char = null_mut();
        assert_eq!(ffsrs_store_read_begin(h, &mut session, &mut err), STORE_OK);
        assert!(!session.is_null());
        let sql: &[u8] = b"SELECT COUNT(*) FROM sqlite_master";
        let query = |s: *const ReadSessionHandle| -> (i32, Option<String>) {
            let mut out: *mut u8 = null_mut();
            let mut out_len = 0usize;
            let mut err: *mut c_char = null_mut();
            let rc = ffsrs_store_read_query(s, sql.as_ptr(), sql.len(), null(), 0, &mut out, &mut out_len, &mut err);
            if rc == STORE_OK {
                crate::ffsrs_free_bytes(out, out_len);
                (rc, None)
            } else {
                (rc, Some(take(err)))
            }
        };
        assert_eq!(query(session), (STORE_OK, None));

        ffsrs_store_close(h);
        assert_eq!(query(session), (STORE_ERROR, Some(CLOSED.to_string())));
        // 会话还没 read_end，但它的连接已经关了：库文件能改名、能删（Windows 下有打开的句柄就不行）。
        let moved = p.with_file_name("srs.moved.db");
        std::fs::rename(&p, &moved).unwrap();
        std::fs::remove_file(&moved).unwrap();

        ffsrs_store_read_end(session);
        assert_eq!(query(session), (STORE_ERROR, Some(CLOSED.to_string())));
        ffsrs_store_read_end(session);
        assert!(sessions().get(&(session as usize)).is_none());
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
    }

    /// 会话查询在途时关库：close 等那次查询跑完（不 UAF、不在查询中途关连接），之后的查询报已关闭。
    #[test]
    fn close_waits_for_an_in_flight_read_session_query() {
        let p = temp("session_inflight");
        let h = open(&p);
        let mut session: *mut ReadSessionHandle = null_mut();
        let mut err: *mut c_char = null_mut();
        assert_eq!(ffsrs_store_read_begin(h, &mut session, &mut err), STORE_OK);
        let entered = Arc::new(Barrier::new(2));
        let worker = {
            let entered = Arc::clone(&entered);
            let id = session as usize;
            std::thread::spawn(move || {
                let mut err: *mut c_char = null_mut();
                let rc = run_session(id as *const ReadSessionHandle, &mut err, |s| {
                    let guard = s.conn.lock().unwrap();
                    entered.wait();
                    std::thread::sleep(std::time::Duration::from_millis(300));
                    guard
                        .as_ref()
                        .ok_or_else(|| "closed under the query".to_string())?
                        .query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
                        .map(|_| ())
                        .map_err(|e| e.to_string())
                });
                (rc, if err.is_null() { None } else { Some(take(err)) })
            })
        };
        entered.wait();
        let t0 = std::time::Instant::now();
        ffsrs_store_close(h);
        assert!(t0.elapsed() >= std::time::Duration::from_millis(200), "close did not wait for the session query");
        assert_eq!(worker.join().unwrap(), (STORE_OK, None));
        std::fs::remove_file(&p).unwrap();
        ffsrs_store_read_end(session);
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
    }
}
