//! 章末广告页识别的 C ABI（`fwc_comic_ad_*`）。

use std::panic::{catch_unwind, AssertUnwindSafe};

use super::{candidate_start, detect_batch, ComicAdRules, ComicAdVerdict};
use crate::ffi_util::{panic_message, set_last_error};

/// 内置默认规则（最后 10 张、前 3 张不判、彩色占比 0.12、长边缩到 900）。
#[no_mangle]
pub extern "C" fn fwc_comic_ad_default_rules() -> ComicAdRules {
    ComicAdRules::default()
}

/// 一章 `page_count` 张里要判定的页序区间 `[start, page_count)` 的起点（≥ page_count = 不用判）。
/// `rules` 为 NULL 时用默认规则。
///
/// # Safety
/// `rules` 为 NULL 或指向有效的 `FwcComicAdRules`。
#[no_mangle]
pub unsafe extern "C" fn fwc_comic_ad_candidate_start(
    page_count: u32,
    rules: *const ComicAdRules,
) -> u32 {
    let rules = rules.as_ref().copied().unwrap_or_default();
    candidate_start(page_count, &rules)
}

/// 批量判定 `count` 张图：`images[i]` / `lens[i]` 是第 i 张的编码字节，结论码（0 正文 /
/// 1 广告 / 2 解码失败）写进 `out[i]`。返回 0 成功；参数非法 / 内部 panic 返回 -1
/// （原因见 `fwc_last_error`），此时 `out` 全部写成 2（按正文保留）。
///
/// 慢调用（解码 + 扫描，几十毫秒级）：Dart 侧放后台 isolate，**不要**用 leaf 调用。
///
/// # Safety
/// `images` / `lens` 指向 `count` 个元素，`images[i]` 指向 `lens[i]` 个可读字节；
/// `out` 指向 `count` 个可写字节；`rules` 为 NULL 或有效。
#[no_mangle]
pub unsafe extern "C" fn fwc_comic_ad_detect_batch(
    rules: *const ComicAdRules,
    images: *const *const u8,
    lens: *const usize,
    count: usize,
    out: *mut u8,
) -> i32 {
    if count == 0 {
        return 0;
    }
    if images.is_null() || lens.is_null() || out.is_null() {
        set_last_error("fwc_comic_ad_detect_batch: NULL argument".into());
        return -1;
    }
    let out = std::slice::from_raw_parts_mut(out, count);
    out.fill(ComicAdVerdict::Undecodable as u8);
    let rules = rules.as_ref().copied().unwrap_or_default();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let ptrs = std::slice::from_raw_parts(images, count);
        let lens = std::slice::from_raw_parts(lens, count);
        let slices: Vec<&[u8]> = ptrs
            .iter()
            .zip(lens)
            .map(|(&p, &len)| {
                if p.is_null() || len == 0 {
                    &[][..]
                } else {
                    std::slice::from_raw_parts(p, len)
                }
            })
            .collect();
        detect_batch(&slices, &rules)
    }));
    match result {
        Ok(verdicts) => {
            for (slot, v) in out.iter_mut().zip(verdicts) {
                *slot = v as u8;
            }
            0
        }
        Err(p) => {
            set_last_error(panic_message(p));
            -1
        }
    }
}
