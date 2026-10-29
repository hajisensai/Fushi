//! 在线音源插件运行时（`plugin` 特性；iOS 伞形库不开）。设计见
//! `docs/specs/2026-10-28-music-plugins.md`；Dart 侧见 `packages/fushi_music/lib/src/plugin/`。
//!
//! C ABI（粗粒度，结果是 UTF-8 JSON，经 [crate::ffm_free_bytes] 释放；step 例外，见下）：
//! - `ffm_plugin_inspect(zip)`：校验插件包，不写盘 → `{manifest, digest, signer, files}`；
//! - `ffm_plugin_install(zip, root, digest)`：再次校验、摘要必须等于用户确认过的那份，原子装进
//!   `<root>/<id>/`；
//! - `ffm_plugin_verify(dir)`：重新哈希已装目录，只回摘要（列已装插件用，不建 JS 实例）；
//! - `ffm_plugin_open(dir, budgetMs)`：重新哈希已装文件、建 QuickJS 实例、核对导出 → 句柄；
//! - `ffm_plugin_step(handle, ops, blob)`：步进驱动（见 [runtime]）。HTTP 请求 / 响应体走二进制区、
//!   不经 base64：输入 `blob` 是 ops 里 `body: {off, len}` 引用的字节；输出帧为
//!   `[u32 LE json 长度][json][二进制区]`，调用参数里的 `body: {off, len}` 指向输出二进制区；
//! - `ffm_plugin_check_urls(handle, urls, purpose)`：按插件网络授权批量核对地址；
//! - `ffm_plugin_close(handle)`；
//! - `ffm_plugin_vault(root, op)`：凭据保险库（[vault]），`op` 为
//!   `{"op":"get"|"set"|"remove"|"clear","plugin":id,"key"?,"value"?}`，返回 `{"value"?}` / `{"error"}`。
//!
//! 校验 / 加载失败不是 FFI 错误：返回 0，JSON 里带 `"error"`。负返回码只给空指针 / 非 UTF-8 /
//! panic（与本 crate 其它域一致）。

pub mod jsapi;
pub mod manifest;
pub mod package;
pub mod policy;
pub mod runtime;
pub mod vault;

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Arc, Mutex};

use serde_json::json;

use crate::{guard, hand_over_bytes, slice_arg, status};
use policy::Purpose;
use runtime::{Gate, Instance};

/// FFI 句柄：JS 实例在互斥锁里（同一句柄的 step 串行），授权核对面单独持有、只读，
/// 所以 `check_urls`（UI isolate 上的重定向核对）可以与后台线程上正在跑的 step 并发，
/// 不会对 `Instance` 产生 `&mut` 别名。
pub struct PluginHandle {
    gate: Arc<Gate>,
    inst: Mutex<Instance>,
}

unsafe fn str_arg<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    slice_arg(ptr, len).and_then(|b| std::str::from_utf8(b).ok())
}

/// step 的输出帧：`[u32 LE json 长度][json][二进制区]`。
unsafe fn out_framed(v: serde_json::Value, blob: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    let j = v.to_string().into_bytes();
    let Ok(n) = u32::try_from(j.len()) else {
        return out_framed(error_json("step 结果过大".into()), Vec::new(), out_ptr, out_len);
    };
    let mut buf = Vec::with_capacity(4 + j.len() + blob.len());
    buf.extend_from_slice(&n.to_le_bytes());
    buf.extend_from_slice(&j);
    buf.extend_from_slice(&blob);
    hand_over_bytes(buf, out_ptr, out_len);
    status::OK
}

unsafe fn out_json(v: serde_json::Value, out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    hand_over_bytes(v.to_string().into_bytes(), out_ptr, out_len);
    status::OK
}

fn error_json(e: String) -> serde_json::Value {
    json!({ "error": e })
}

#[no_mangle]
pub extern "C" fn ffm_plugin_api_version() -> i32 {
    manifest::HOST_API_VERSION as i32
}

/// # Safety
/// 指针参数按长度可读；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_inspect(
    zip_ptr: *const u8,
    zip_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(zip) = slice_arg(zip_ptr, zip_len) else {
            return status::NULL_ARGUMENT;
        };
        let v = match package::inspect_zip(zip) {
            Ok(p) => p.summary_json(),
            Err(e) => error_json(e),
        };
        out_json(v, out_ptr, out_len)
    })
}

/// # Safety
/// 同 [ffm_plugin_inspect]。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_install(
    zip_ptr: *const u8,
    zip_len: usize,
    root_ptr: *const u8,
    root_len: usize,
    digest_ptr: *const u8,
    digest_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (Some(zip), Some(root), Some(digest)) = (
            slice_arg(zip_ptr, zip_len),
            str_arg(root_ptr, root_len),
            str_arg(digest_ptr, digest_len),
        ) else {
            return status::INVALID_ARGUMENT;
        };
        let v = match package::install_zip(zip, Path::new(root), digest) {
            Ok(p) => p.summary_json(),
            Err(e) => error_json(e),
        };
        out_json(v, out_ptr, out_len)
    })
}

/// # Safety
/// 同 [ffm_plugin_inspect]。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_verify(
    dir_ptr: *const u8,
    dir_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(dir) = str_arg(dir_ptr, dir_len) else {
            return status::INVALID_ARGUMENT;
        };
        let v = match package::load_dir(Path::new(dir)) {
            Ok(p) => p.summary_json(),
            Err(e) => error_json(e),
        };
        out_json(v, out_ptr, out_len)
    })
}

/// # Safety
/// 同 [ffm_plugin_inspect]；`out_handle` 可写，成功时写入句柄（用 [ffm_plugin_close] 释放）。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_open(
    dir_ptr: *const u8,
    dir_len: usize,
    budget_ms: u32,
    out_handle: *mut *mut PluginHandle,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() || out_handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out_handle = std::ptr::null_mut();
        let Some(dir) = str_arg(dir_ptr, dir_len) else {
            return status::INVALID_ARGUMENT;
        };
        let v = match package::load_dir(Path::new(dir)).and_then(|pkg| {
            let summary = pkg.summary_json();
            Instance::open(pkg, budget_ms as u64).map(|i| (i, summary))
        }) {
            Ok((inst, summary)) => {
                let gate = inst.gate();
                *out_handle = Box::into_raw(Box::new(PluginHandle {
                    gate,
                    inst: Mutex::new(inst),
                }));
                summary
            }
            Err(e) => error_json(e),
        };
        out_json(v, out_ptr, out_len)
    })
}

/// # Safety
/// `handle` 来自 [ffm_plugin_open] 且未关闭。同一句柄的 step 由句柄内的锁串行化。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_step(
    handle: *mut PluginHandle,
    ops_ptr: *const u8,
    ops_len: usize,
    blob_ptr: *const u8,
    blob_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if handle.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(ops) = slice_arg(ops_ptr, ops_len) else {
            return status::NULL_ARGUMENT;
        };
        let blob: &[u8] = if blob_len == 0 {
            &[]
        } else {
            match slice_arg(blob_ptr, blob_len) {
                Some(b) => b,
                None => return status::NULL_ARGUMENT,
            }
        };
        // 锁中毒（上一次 step panic）时实例状态不可信：按 fatal 交回，宿主作废并重建。
        let handle: &PluginHandle = &*handle;
        let (v, out_blob) = match handle.inst.lock() {
            Ok(mut inst) => inst.step(ops, blob),
            Err(_) => (json!({ "fatal": "插件运行时内部错误（上次执行崩溃）" }), Vec::new()),
        };
        out_framed(v, out_blob, out_ptr, out_len)
    })
}

/// 批量核对地址：`urls` 是 JSON 字符串数组，返回同序数组，每项为规范化 URL 或 `null`（不在授权内）。
/// `purpose`：0 = 插件请求（含重定向下一跳），1 = 交给宿主播放 / 显示的媒体地址。
///
/// # Safety
/// `handle` 来自 [ffm_plugin_open] 且未关闭；可与同句柄的 step 并发（只读授权核对面）。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_check_urls(
    handle: *mut PluginHandle,
    urls_ptr: *const u8,
    urls_len: usize,
    purpose: i32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if handle.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(raw) = slice_arg(urls_ptr, urls_len) else {
            return status::NULL_ARGUMENT;
        };
        let Ok(urls) = serde_json::from_slice::<Vec<String>>(raw) else {
            return status::BAD_INPUT;
        };
        let purpose = if purpose == 1 {
            Purpose::Media
        } else {
            Purpose::Request
        };
        let handle: &PluginHandle = &*handle;
        let out: Vec<serde_json::Value> = urls
            .iter()
            .map(|u| match handle.gate.policy.check_url(u, purpose) {
                Ok(v) => json!(v),
                Err(_) => serde_json::Value::Null,
            })
            .collect();
        out_json(json!({ "urls": out }), out_ptr, out_len)
    })
}

/// # Safety
/// 指针参数按长度可读；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_vault(
    root_ptr: *const u8,
    root_len: usize,
    op_ptr: *const u8,
    op_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (Some(root), Some(op)) = (str_arg(root_ptr, root_len), slice_arg(op_ptr, op_len))
        else {
            return status::INVALID_ARGUMENT;
        };
        let Ok(op) = serde_json::from_slice::<serde_json::Value>(op) else {
            return status::BAD_INPUT;
        };
        let s = |k: &str| op.get(k).and_then(serde_json::Value::as_str).unwrap_or("");
        let root = Path::new(root);
        let r = match s("op") {
            "get" => vault::get(root, s("plugin"), s("key")).map(|v| json!({ "value": v })),
            "set" => vault::set(root, s("plugin"), s("key"), s("value")).map(|_| json!({})),
            "remove" => vault::remove(root, s("plugin"), s("key")).map(|_| json!({})),
            "clear" => vault::clear(root, s("plugin")).map(|_| json!({})),
            other => Err(format!("未知保险库操作 {other}")),
        };
        out_json(r.unwrap_or_else(error_json), out_ptr, out_len)
    })
}

/// # Safety
/// `handle` 来自 [ffm_plugin_open]，关闭后不得再用。
#[no_mangle]
pub unsafe extern "C" fn ffm_plugin_close(handle: *mut PluginHandle) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(handle))));
    }
}

#[cfg(test)]
mod tests;
