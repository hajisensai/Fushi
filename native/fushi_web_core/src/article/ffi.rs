//! 正文提取与连载会话的 C ABI（`fwc_article_*` / `fwc_novel_session_*`）。
//!
//! 大块数据走字节：整页 HTML 是 `(ptr, len)` 原始字节（编码在 Rust 里嗅探），提取结果是帧
//! `[u32 LE 头长度][JSON 头][正文 XHTML UTF-8]`（见 `encode_framed`），正文不进 JSON。
//! 提取是毫秒级的慢调用（整页 DOM 解析）：Dart 侧放后台 isolate，不用 leaf 调用。

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

use serde::Serialize;

use super::session::{IngestOutcome, NovelSession};
use super::{encode_framed, extract, work_key_for_url, Article};
use crate::ffi_util::{
    bytes_in, clear_last_error, hand_out, panic_message, set_last_error, str_in,
};

/// 不透明句柄：Dart 侧可能从不同 isolate（不同 OS 线程）调用，内部加锁。
pub struct FwcNovelSession {
    inner: Mutex<NovelSession>,
}

fn guarded<F>(name: &str, out_len: *mut usize, f: F) -> *mut u8
where
    F: FnOnce() -> Result<Vec<u8>, String>,
{
    clear_last_error();
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(bytes)) => unsafe { hand_out(bytes, out_len) },
        Ok(Err(e)) => {
            set_last_error(format!("{name}: {e}"));
            unsafe { hand_out(Vec::new(), out_len) }
        }
        Err(p) => {
            set_last_error(format!("{name}: {}", panic_message(p)));
            unsafe { hand_out(Vec::new(), out_len) }
        }
    }
}

/// 无状态提取一页（预览 / 测量用）。返回帧；失败返回 NULL（原因见 `fwc_last_error`）。
///
/// # Safety
/// `html` 指向 `html_len` 个可读字节；`url` 指向 `url_len` 个 UTF-8 字节；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_article_extract(
    html: *const u8,
    html_len: usize,
    url: *const u8,
    url_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    guarded("fwc_article_extract", out_len, || {
        let html = bytes_in(html, html_len);
        let url = str_in(url, url_len).ok_or("url is not UTF-8")?;
        let article = extract(html, url)?;
        encode_framed(&article, &article.xhtml)
    })
}

/// 只从章节 URL 推作品身份键（UTF-8）。URL 不合法返回 NULL。快调用。
///
/// # Safety
/// `url` 指向 `url_len` 个 UTF-8 字节；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_article_work_key(
    url: *const u8,
    url_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    guarded("fwc_article_work_key", out_len, || {
        let url = str_in(url, url_len).ok_or("url is not UTF-8")?;
        work_key_for_url(url)
            .map(String::into_bytes)
            .ok_or_else(|| "not an http(s) url".to_owned())
    })
}

/// 开一个连载会话。`snapshot` 为空（NULL / 0）= 新会话；否则是之前
/// `fwc_novel_session_snapshot` 给出的 JSON。快照坏了返回 NULL（原因见 `fwc_last_error`）。
///
/// # Safety
/// `snapshot` 为 NULL 或指向 `snapshot_len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn fwc_novel_session_open(
    snapshot: *const u8,
    snapshot_len: usize,
) -> *mut FwcNovelSession {
    clear_last_error();
    let bytes = bytes_in(snapshot, snapshot_len);
    match catch_unwind(AssertUnwindSafe(|| NovelSession::restore(bytes))) {
        Ok(Ok(session)) => Box::into_raw(Box::new(FwcNovelSession {
            inner: Mutex::new(session),
        })),
        Ok(Err(e)) => {
            set_last_error(format!("fwc_novel_session_open: {e}"));
            std::ptr::null_mut()
        }
        Err(p) => {
            set_last_error(format!("fwc_novel_session_open: {}", panic_message(p)));
            std::ptr::null_mut()
        }
    }
}

/// 关闭会话。NULL 为 no-op。
///
/// # Safety
/// `session` 为 NULL 或 `fwc_novel_session_open` 返回、尚未关闭的句柄。
#[no_mangle]
pub unsafe extern "C" fn fwc_novel_session_close(session: *mut FwcNovelSession) {
    if !session.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(session))));
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct IngestHeader<'a> {
    article: &'a Article,
    ingest: IngestOutcome,
}

/// 喂一页：提取 + 并进会话。返回帧，头是 `{"article":{…},"ingest":{"status","index",
/// "chapterCount","tailNext"}}`，正文 XHTML 跟在后面（`empty` / `otherWork` 时也给出提取
/// 结果，便于 Dart 提示）。失败返回 NULL。
///
/// # Safety
/// `session` 有效；`html` / `url` 同 `fwc_article_extract`；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_novel_session_ingest(
    session: *mut FwcNovelSession,
    html: *const u8,
    html_len: usize,
    url: *const u8,
    url_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    guarded("fwc_novel_session_ingest", out_len, || {
        let session = session.as_ref().ok_or("NULL session")?;
        let html = bytes_in(html, html_len);
        let url = str_in(url, url_len).ok_or("url is not UTF-8")?;
        let article = extract(html, url)?;
        let outcome = {
            let mut guard = session.inner.lock().map_err(|_| "session poisoned")?;
            guard.ingest(&article)
        };
        encode_framed(
            &IngestHeader {
                article: &article,
                ingest: outcome,
            },
            &article.xhtml,
        )
    })
}

/// 会话快照 JSON（可原样持久化，`fwc_novel_session_open` 恢复）。
///
/// # Safety
/// `session` 有效；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_novel_session_snapshot(
    session: *mut FwcNovelSession,
    out_len: *mut usize,
) -> *mut u8 {
    guarded("fwc_novel_session_snapshot", out_len, || {
        let session = session.as_ref().ok_or("NULL session")?;
        let guard = session.inner.lock().map_err(|_| "session poisoned")?;
        guard.snapshot_json()
    })
}
