//! 网页漫画章末广告页识别（只用于网页漫画来源）。
//!
//! 盗链 / 聚合站常在一章末尾塞几张「扫码下载 App / 加群」的彩色广告图。判据刻意做得窄，
//! 宁可漏判也不误删正文：
//!
//! 1. 只看一章**最后 `tail_window` 张**；
//! 2. 前 `protected_leading_pages` 张**永远不算广告**（短章 / 单页不会被整章删光）；
//! 3. 必须是**彩色图**（漫画正文几乎都是灰度，彩页也极少印二维码）；
//! 4. 且图里能找到**二维码的三个定位图形**（1:1:3:1:1 的「回」字，三个中心呈等腰直角三角形）。
//!
//! 只判「有没有二维码」，不解码码内容。
//!
//! 对外是粗粒度批量接口：一次传入一章末尾的若干张图片字节，返回每张的结论
//! （`fwc_comic_ad_detect_batch`）；Dart 侧放后台 isolate 调一次。

mod dart_sort;
pub mod decode;
pub mod ffi;
mod qr;

pub use qr::contains_qr_finder_patterns;

/// 判定规则。字段与 C ABI 的 `FwcComicAdRules` 一一对应。
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ComicAdRules {
    /// 只判一章最后这么多张。
    pub tail_window: u32,
    /// 一章开头永不判广告的张数。
    pub protected_leading_pages: u32,
    /// 彩色像素占比超过它才算彩色图（扫描的黑白页通常远低于 5%，广告图远高于它）。
    pub colorful_threshold: f64,
    /// 判定前把长边缩到这么多像素（二维码模块在 900px 长边下仍有几个像素宽）。
    pub analysis_max_side: u32,
}

impl Default for ComicAdRules {
    fn default() -> Self {
        Self {
            tail_window: 10,
            protected_leading_pages: 3,
            colorful_threshold: 0.12,
            analysis_max_side: 900,
        }
    }
}

/// 单张图的判定结论（C ABI 的输出码）。
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ComicAdVerdict {
    /// 正文页（解码成功，不是广告）。
    Content = 0,
    /// 广告页。
    Ad = 1,
    /// 解码失败 / 太小：按正文保留（判广告只许漏判，不许误删）。
    Undecodable = 2,
}

/// 一章 `page_count` 张里要判定的页序区间 `[start, page_count)` 的起点；
/// 返回值 ≥ `page_count` 表示一张都不用判。
pub fn candidate_start(page_count: u32, rules: &ComicAdRules) -> u32 {
    if page_count <= rules.protected_leading_pages {
        return page_count;
    }
    rules
        .protected_leading_pages
        .max(page_count.saturating_sub(rules.tail_window))
}

/// 一张图的完整判定（含中间量，测试 / 回归向量用）。
#[derive(Clone, Copy, Debug)]
pub struct ComicAdAnalysis {
    pub verdict: ComicAdVerdict,
    /// 缩放后的彩色占比；解码失败 / 太小为 None。
    pub colorful: Option<f64>,
}

/// 判一张图。
pub fn analyze(bytes: &[u8], rules: &ComicAdRules) -> ComicAdAnalysis {
    let Some(decoded) = decode::decode_rgb8(bytes) else {
        return ComicAdAnalysis {
            verdict: ComicAdVerdict::Undecodable,
            colorful: None,
        };
    };
    if decoded.width < 32 || decoded.height < 32 {
        return ComicAdAnalysis {
            verdict: ComicAdVerdict::Undecodable,
            colorful: None,
        };
    }
    let image = decode::fit_within(decoded, rules.analysis_max_side as usize);
    let colorful = decode::colorful_fraction(&image);
    if colorful < rules.colorful_threshold {
        return ComicAdAnalysis {
            verdict: ComicAdVerdict::Content,
            colorful: Some(colorful),
        };
    }
    let gray = decode::luminance(&image);
    let verdict = if contains_qr_finder_patterns(&gray, image.width, image.height) {
        ComicAdVerdict::Ad
    } else {
        ComicAdVerdict::Content
    };
    ComicAdAnalysis {
        verdict,
        colorful: Some(colorful),
    }
}

/// 单张判定，panic 隔离在这一张图上：解码器（第三方 `image` crate）碰到畸形字节若 panic，
/// 这张记为 [`ComicAdVerdict::Undecodable`]（按正文保留），整批照常返回——判广告只许漏判、
/// 不许因为一张坏图让整章打不开。
fn analyze_isolated(bytes: &[u8], rules: &ComicAdRules) -> ComicAdVerdict {
    verdict_or_undecodable(|| analyze(bytes, rules).verdict)
}

fn verdict_or_undecodable(f: impl FnOnce() -> ComicAdVerdict) -> ComicAdVerdict {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(ComicAdVerdict::Undecodable)
}

/// 批量判定：`images[i]` 的结论写进返回值第 i 项。多张图用最多 4 个作用域线程并行（解码峰值
/// 内存 ≈ 4 张 RGB 图；手机上也可接受），
/// 整批只跨一次 FFI。
pub fn detect_batch(images: &[&[u8]], rules: &ComicAdRules) -> Vec<ComicAdVerdict> {
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .min(images.len())
        .clamp(1, 4);
    if workers <= 1 {
        return images.iter().map(|b| analyze_isolated(b, rules)).collect();
    }
    let mut out = vec![ComicAdVerdict::Undecodable; images.len()];
    let next = std::sync::atomic::AtomicUsize::new(0);
    let results = std::sync::Mutex::new(&mut out);
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if i >= images.len() {
                    break;
                }
                let verdict = analyze_isolated(images[i], rules);
                if let Ok(mut guard) = results.lock() {
                    guard[i] = verdict;
                }
            });
        }
    });
    out
}

#[cfg(test)]
mod tests;
