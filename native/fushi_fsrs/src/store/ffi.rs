//! srs.db 的 C ABI（Dart 绑定：packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart）。
//!
//! 约定与 lib.rs 其余部分相同：返回 i32 状态（0 成功，负数失败），失败时 `*error_out` 是新分配的
//! C 字符串（用 `ffsrs_free_string` 释放）；Rust 分配的字节用 `ffsrs_free_bytes` 释放；panic 一律
//! 接住转成 -100。句柄是 `SrsCore` 的裸指针，线程安全，可在任意 isolate 上用。

use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use super::{ReadSession, SrsCore};

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
    core_out: *mut *mut SrsCore,
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
            unsafe { *core_out = Box::into_raw(Box::new(core)) };
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

/// 关闭（NULL 无操作，重复关闭无操作）：等在途命令跑完再关两条连接，之后经这个句柄的命令一律报
/// 「已关闭」。
///
/// 句柄指向的结构体**不释放**：Dart 侧把句柄地址交给后台 isolate（`SrsCore.fromAddress`），
/// 拥有者关闭时那边可能还在调用、甚至之后才调用；释放掉就是 use-after-free（2026-10-25 CI 实测：
/// 测试 tearDown 关库时 `Isolate.run` 里的 sync2 还在跑，析构 serde_json 时 `free(): invalid
/// pointer`）。留下的只有两把空锁加一个路径，每次打开一份，进程里打开 srs.db 的次数是个位数。
#[no_mangle]
pub extern "C" fn ffsrs_store_close(core: *mut SrsCore) {
    if !core.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe { (*core).close() }));
    }
}

/// `*out` = 1 已搬迁（或确认没有可搬的），0 未搬迁。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_state(
    core: *const SrsCore,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run(core, error_out, |c| {
        let v = c.legacy_imported()?;
        unsafe { *out = v as i32 };
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_begin(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_begin())
}

/// 一页旧表行（rows.rs 编码）。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_page(
    core: *const SrsCore,
    table: *const u8,
    table_len: usize,
    page: *const u8,
    page_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| {
        let t = utf8(table, table_len)?;
        let p = bytes(page, page_len).ok_or("null page")?;
        c.legacy_page(t, p).map(|_| ())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_commit(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_commit())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_abort(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_abort())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_mark_none(
    core: *const SrsCore,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| c.legacy_mark_none())
}

/// `VACUUM INTO` 一份快照；`strip_device_local != 0` 时清空设备本地表。
#[no_mangle]
pub extern "C" fn ffsrs_store_snapshot(
    core: *const SrsCore,
    path: *const u8,
    path_len: usize,
    strip_device_local: i32,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| {
        c.snapshot_into(Path::new(utf8(path, path_len)?), strip_device_local != 0)
    })
}

/// 只读调试查询（测试 / 诊断）。参数是一行 rows.rs 编码的页（列数 = 参数个数，可为空页）。
#[no_mangle]
pub extern "C" fn ffsrs_store_debug_query(
    core: *const SrsCore,
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
    run(core, error_out, |c| {
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
    core: *const SrsCore,
    session_out: *mut *mut ReadSession,
    error_out: *mut *mut c_char,
) -> i32 {
    if session_out.is_null() {
        set_error(error_out, "null session_out");
        return STORE_BAD_ARGUMENT;
    }
    run(core, error_out, |c| {
        let s = c.read_session()?;
        unsafe { *session_out = Box::into_raw(Box::new(s)) };
        Ok(())
    })
}

/// 在只读会话的读事务里跑一条只读语句。参数页 / 结果编码同 [ffsrs_store_debug_query]。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_query(
    session: *const ReadSession,
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
    run(session, error_out, |r| {
        let s = utf8(sql, sql_len)?;
        let values = one_row(bytes(params, params_len).ok_or("null params")?)?;
        hand_out(r.query(s, &values)?, out, out_len);
        Ok(())
    })
}

/// 结束只读会话（NULL 无操作）。之后句柄不可再用。
#[no_mangle]
pub extern "C" fn ffsrs_store_read_end(session: *mut ReadSession) {
    if !session.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe { drop(Box::from_raw(session)) }));
    }
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

/// Drift 执行器：写连接上执行一条语句。`select != 0` 返回「列名行 + 结果行」，否则返回
/// 一行 `[变更行数, last_insert_rowid]`；缓冲区用 `ffsrs_free_bytes` 释放。
#[no_mangle]
pub extern "C" fn ffsrs_store_exec(
    core: *const SrsCore,
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
    run(core, error_out, |c| {
        let s = utf8(sql, sql_len)?;
        let values = one_row(bytes(params, params_len).ok_or("null params")?)?;
        hand_out(c.exec(s, &values, select != 0)?, out, out_len);
        Ok(())
    })
}

/// Drift 批量语句。`statements` 是单列文本页（每行一条 SQL）；`applications` 是两列页：
/// `[语句下标 i64, 参数页 blob]`（参数页是一行的 rows.rs 页，可为空字节）。
#[no_mangle]
pub extern "C" fn ffsrs_store_exec_batch(
    core: *const SrsCore,
    statements: *const u8,
    statements_len: usize,
    applications: *const u8,
    applications_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    use rusqlite::types::Value;
    run(core, error_out, |c| {
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
    core: *const SrsCore,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run(core, error_out, |c| {
        let v = c.in_transaction()?;
        unsafe { *out = v as i32 };
        Ok(())
    })
}

/// 卡片历史的当前状态（直读写连接）。`groups` 是两列页 `[历史下标 i64, 卡 ID 文本]`，共
/// `n_groups` 份历史；输出布局同 `ffsrs_history_states`，用 `ffsrs_free_bytes` 释放。
#[no_mangle]
pub extern "C" fn ffsrs_store_history_states(
    core: *const SrsCore,
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
    run(core, error_out, |c| {
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
    core: *const SrsCore,
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
    run(core, error_out, |c| {
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
    core: *const SrsCore,
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
    run(core, error_out, |c| {
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
    core: *const SrsCore,
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
    core: *const SrsCore,
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
    core: *const SrsCore,
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
    let parse = |t: String| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string());
    let profile = s("profile")?;
    Ok(match s("op")? {
        "identity" => c.sync2_identity(profile, i("now")?)?,
        "apply" => {
            let input = std::str::from_utf8(blobs.first().ok_or("apply: missing input")?).map_err(|e| e.to_string())?;
            parse(c.sync2_apply_local(profile, i("now")?, input)?)?
        }
        "migrate" => c.sync2_migrate(profile, i("now")?, req.get("limit").and_then(Value::as_u64))?,
        "replay_all" => json!(c.sync2_replay_all(profile)?),
        "preview" => c.sync2_preview(profile, s("card")?, req.get("note").and_then(Value::as_str), i("now")?, i("utcOff")?, i("rollover")?)?,
        "outbox" => {
            let (segs, upto) = c.sync2_outbox(profile, s("location")?, key32(&req["key"])?)?;
            *files = segs;
            json!({"upto": upto})
        }
        "head" => {
            let (path, bytes, gen, obsolete) = c.sync2_head(profile, s("location")?, i("upto")? as u64, i("now")?)?;
            files.push((path, bytes));
            json!({"gen": gen, "delete": obsolete})
        }
        "plan" => c.sync2_plan(profile, blobs)?,
        "ingest" => parse(c.sync2_ingest(profile, blobs, key32(&req["key"])?, i("now")?)?)?,
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
            if s("op")? == "seal" {
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
            if s("op")? == "plan_restore" {
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
    core: *const SrsCore,
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
    run(core, error_out, |c| {
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
