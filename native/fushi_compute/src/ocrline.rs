//! 游戏 OCR 台词流的判定核心（`ffc_ocrline_*`，spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md`）。
//!
//! 连续 OCR 的**全部判定状态**都在这里：上一帧签名、稳定计数、上次送 OCR 的帧签名、空白态、上一句文本。
//! Dart 侧（`GalOcrLineSource`）只是泵：按间隔截窗 → [ffc_ocrline_feed_png] → 按 action 决定是否调 OCR →
//! [ffc_ocrline_feed_text] → 把 new / extend 送进台词流。Dart 不存任何镜像状态。
//!
//! 两步判定：
//! - 帧（`feed_png`）：解码 PNG、按客户区归一化坐标裁出台词框、降成 96×24 灰度网格签名；
//!   画面变了且稳定下来、并且与上次送 OCR 的那帧不同，才交出裁好的 RGBA 让调用方 OCR。
//!   打字机逐字出现期间帧一直在变，不会 OCR 半句；框里没字（几乎没有文字边缘）回 `cleared`。
//! - 文本（`feed_text`）：拼行规范化（CJK 之间去空白）→ 与上一句去重（编辑距离 ≤ 10%）/
//!   打字机续写（输出上一句 + 新尾巴，保证是严格前缀扩展，台词流的渐进折叠能并成一行）。

use std::sync::Mutex;

use crate::{guard, hand_over_bytes, status};

/// 帧签名网格的列数 / 行数。
const GRID_W: usize = 96;
const GRID_H: usize = 24;

/// 一个格子的亮度差超过它才算「这一格变了」（0..=255）。
const CELL_DELTA: u8 = 18;

/// 至少这么多格变了，整帧才算变了（单格变化当噪声：压缩伪影、抗锯齿抖动）。
const MIN_CHANGED_CELLS: usize = 2;

/// 相邻像素亮度差超过它算一条边（文字笔画的边缘）。
const EDGE_DELTA: i32 = 40;

/// 边缘像素少于它算「框里没字」。用绝对数而不是密度：宽台词框里的一两个字（「はい」）
/// 按面积算密度极低，按密度判会被当成空白、永远不 OCR；而真正的空框（纯色 / 渐变底）
/// 一条超过 [EDGE_DELTA] 的边都没有。
const BLANK_MAX_EDGES: usize = 24;

/// 去重 / 续写的编辑距离上限（相对长度）。
const SIMILAR_RATIO: f64 = 0.10;

/// 与台词流渐进折叠（`texthooker_line_fold.dart` 的 `kMinFoldableLength`）一致：上一句短于它时
/// 不判续写——折叠那边也不会并，判了续写只会留下两条。
const MIN_EXTEND_BASE: usize = 4;

/// [ffc_ocrline_feed_png] 的 action。
pub mod action {
    /// 没变化 / 这一帧已经 OCR 过，不用做事。
    pub const IDLE: u32 = 0;
    /// 画面在变（打字机 / 转场），等它稳定。
    pub const SETTLING: u32 = 1;
    /// 稳定的新画面：RGBA 已交出，调用方 OCR 后调 [super::ffc_ocrline_feed_text]。
    pub const OCR: u32 = 2;
    /// 框里没字了（上一句已清，下一句即使相同也算新句）。
    pub const CLEARED: u32 = 3;
}

/// [ffc_ocrline_feed_text] 的 kind。
pub mod kind {
    /// 识别结果为空（同时清掉上一句）。
    pub const EMPTY: u32 = 0;
    /// 与上一句是同一句（OCR 抖动 / 光标闪烁导致的重复识别）。
    pub const DUPLICATE: u32 = 1;
    /// 新的一句。
    pub const NEW: u32 = 2;
    /// 上一句的续写（打字机停顿时 OCR 到了半句）；输出是上一句 + 新尾巴。
    pub const EXTEND: u32 = 3;
}

type Signature = Vec<u8>;

/// 帧判定的结果（Rust 内部形态）。
#[derive(Debug, PartialEq)]
pub enum FrameAction {
    Idle,
    Settling,
    Ocr {
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    },
    Cleared,
}

/// 文本判定的结果（Rust 内部形态）。
#[derive(Debug, PartialEq, Eq)]
pub enum TextEvent {
    Empty,
    Duplicate,
    New(String),
    Extend(String),
}

/// 连续 OCR 台词流的状态机。
#[derive(Default)]
pub struct OcrLineTracker {
    prev_sig: Option<Signature>,
    stable: u32,
    ocr_sig: Option<Signature>,
    blank: bool,
    /// 上一句（显示文本）。
    last_text: Option<String>,
}

impl OcrLineTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// 换区域 / 重新开始：忘掉全部帧状态与上一句。
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// 喂一帧已裁好的 RGBA（`width * height * 4`，行紧排）。
    pub fn feed_rgba(&mut self, rgba: &[u8], width: usize, height: usize) -> FrameAction {
        let luma = to_luma(rgba, width, height);
        if is_blank(&luma, width, height) {
            self.prev_sig = None;
            self.stable = 0;
            self.ocr_sig = None;
            if self.blank {
                return FrameAction::Idle;
            }
            self.blank = true;
            self.last_text = None;
            return FrameAction::Cleared;
        }
        self.blank = false;
        let sig = signature(&luma, width, height);
        match &self.prev_sig {
            Some(prev) if !changed(prev, &sig) => self.stable = self.stable.saturating_add(1),
            _ => self.stable = 0,
        }
        let needs_ocr = self.ocr_sig.as_ref().map_or(true, |o| changed(o, &sig));
        self.prev_sig = Some(sig.clone());
        if !needs_ocr {
            return FrameAction::Idle;
        }
        if self.stable == 0 {
            return FrameAction::Settling;
        }
        self.ocr_sig = Some(sig);
        FrameAction::Ocr {
            rgba: rgba.to_vec(),
            width: width as u32,
            height: height as u32,
        }
    }

    /// 喂一帧整窗 PNG + 客户区归一化区域 `[left, top, width, height]`。
    pub fn feed_png(&mut self, png: &[u8], region: [f32; 4]) -> Result<FrameAction, i32> {
        let img = image::load_from_memory_with_format(png, image::ImageFormat::Png)
            .map_err(|_| status::BAD_INPUT)?
            .into_rgba8();
        let (w, h) = (img.width() as usize, img.height() as usize);
        let (x0, y0, cw, ch) = crop_box(w, h, region).ok_or(status::INVALID_ARGUMENT)?;
        let src = img.as_raw();
        let mut crop = Vec::with_capacity(cw * ch * 4);
        for y in y0..y0 + ch {
            let start = (y * w + x0) * 4;
            crop.extend_from_slice(&src[start..start + cw * 4]);
        }
        Ok(self.feed_rgba(&crop, cw, ch))
    }

    /// 喂一次 OCR 结果（行间用 `\n` 分隔）。
    pub fn feed_text(&mut self, raw: &str) -> TextEvent {
        let text = normalize_lines(raw);
        let key = fold_key(&text);
        if key.is_empty() {
            self.last_text = None;
            return TextEvent::Empty;
        }
        let Some(last) = self.last_text.clone() else {
            self.last_text = Some(text.clone());
            return TextEvent::New(text);
        };
        let last_key = fold_key(&last);
        if similar(&key, &last_key) {
            return TextEvent::Duplicate;
        }
        if key.len() < last_key.len() && similar(&key, &last_key[..key.len()]) {
            // 变短且是上一句的近似前缀：画面淡出 / 遮挡，没有新信息。
            return TextEvent::Duplicate;
        }
        if last_key.len() >= MIN_EXTEND_BASE
            && key.len() > last_key.len()
            && similar(&key[..last_key.len()], &last_key)
        {
            let tail = tail_after_chars(&text, last_key.len());
            let extended = format!("{last}{tail}");
            self.last_text = Some(extended.clone());
            return TextEvent::Extend(extended);
        }
        self.last_text = Some(text.clone());
        TextEvent::New(text)
    }
}

/// 归一化区域 → 像素裁框 `(x, y, w, h)`；区域与图没有交集返回 None。
fn crop_box(w: usize, h: usize, region: [f32; 4]) -> Option<(usize, usize, usize, usize)> {
    if w == 0 || h == 0 || region.iter().any(|v| !v.is_finite()) {
        return None;
    }
    let clamp = |v: f32| v.clamp(0.0, 1.0) as f64;
    let left = clamp(region[0]);
    let top = clamp(region[1]);
    let right = clamp(region[0] + region[2]);
    let bottom = clamp(region[1] + region[3]);
    let x0 = (left * w as f64).floor() as usize;
    let y0 = (top * h as f64).floor() as usize;
    let x1 = ((right * w as f64).ceil() as usize).min(w);
    let y1 = ((bottom * h as f64).ceil() as usize).min(h);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some((x0, y0, x1 - x0, y1 - y0))
}

/// RGBA → 亮度（BT.601 整数近似）。
fn to_luma(rgba: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(width * height);
    for px in rgba.chunks_exact(4).take(width * height) {
        let y = (299 * px[0] as u32 + 587 * px[1] as u32 + 114 * px[2] as u32) / 1000;
        out.push(y as u8);
    }
    out
}

/// 水平边缘像素太少 = 框里没字。
fn is_blank(luma: &[u8], width: usize, height: usize) -> bool {
    if width < 2 || height == 0 {
        return true;
    }
    let mut edges = 0usize;
    for row in luma.chunks_exact(width) {
        for pair in row.windows(2) {
            if (pair[0] as i32 - pair[1] as i32).abs() > EDGE_DELTA {
                edges += 1;
            }
        }
    }
    edges < BLANK_MAX_EDGES
}

/// 面积平均降到 [GRID_W]×[GRID_H] 的灰度网格。
fn signature(luma: &[u8], width: usize, height: usize) -> Signature {
    let mut sig = vec![0u8; GRID_W * GRID_H];
    for gy in 0..GRID_H {
        let y0 = gy * height / GRID_H;
        let y1 = ((gy + 1) * height / GRID_H).max(y0 + 1).min(height);
        for gx in 0..GRID_W {
            let x0 = gx * width / GRID_W;
            let x1 = ((gx + 1) * width / GRID_W).max(x0 + 1).min(width);
            let mut sum = 0u64;
            let mut n = 0u64;
            for y in y0..y1 {
                let row = &luma[y * width..y * width + width];
                for &v in &row[x0.min(width)..x1] {
                    sum += v as u64;
                    n += 1;
                }
            }
            sig[gy * GRID_W + gx] = if n == 0 { 0 } else { (sum / n) as u8 };
        }
    }
    sig
}

fn changed(a: &Signature, b: &Signature) -> bool {
    a.iter()
        .zip(b)
        .filter(|(x, y)| x.abs_diff(**y) > CELL_DELTA)
        .count()
        >= MIN_CHANGED_CELLS
}

/// 假名 / 汉字 / CJK 标点 / 全角字符：这些字之间的空白是 OCR 插进来的，不是原文的。
fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3000..=0x303F   // CJK 标点
        | 0x3040..=0x30FF // 平假名 / 片假名
        | 0x31F0..=0x31FF // 片假名音标扩展
        | 0x3400..=0x4DBF // 扩展 A
        | 0x4E00..=0x9FFF // 统一汉字
        | 0xF900..=0xFAFF // 兼容汉字
        | 0xFF00..=0xFFEF // 全角 / 半角形式
        | 0x20000..=0x2FFFF)
}

/// 拼行规范化：逐行 trim；CJK 与 CJK 之间（行内或跨行）的空白去掉，其余空白折成一个空格。
pub fn normalize_lines(raw: &str) -> String {
    let mut out = String::new();
    let mut pending_space = false;
    for c in raw.chars() {
        if c.is_whitespace() {
            if !out.is_empty() {
                pending_space = true;
            }
            continue;
        }
        if pending_space {
            let prev_cjk = out.chars().next_back().is_some_and(is_cjk);
            if !(prev_cjk && is_cjk(c)) {
                out.push(' ');
            }
            pending_space = false;
        }
        out.push(c);
    }
    out
}

/// 去重键：去掉全部空白后的字符序列。
fn fold_key(text: &str) -> Vec<char> {
    text.chars().filter(|c| !c.is_whitespace()).collect()
}

fn similar(a: &[char], b: &[char]) -> bool {
    let longest = a.len().max(b.len());
    if longest == 0 {
        return true;
    }
    (levenshtein(a, b) as f64) <= SIMILAR_RATIO * longest as f64
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = usize::from(ca != cb);
            cur[j + 1] = (prev[j] + cost).min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// [text] 里跳过前 [n] 个非空白字符之后的剩余部分（续写的新尾巴）。
fn tail_after_chars(text: &str, n: usize) -> &str {
    let mut seen = 0usize;
    for (i, c) in text.char_indices() {
        if seen == n {
            return &text[i..];
        }
        if !c.is_whitespace() {
            seen += 1;
        }
    }
    ""
}

// ---------------------------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------------------------

/// 跨 isolate 用同一个 tracker（帧判定在后台 isolate、文本判定在 UI isolate，由泵串行调用）：
/// 外面再包一层锁，调用方即使并发也不会数据竞争。
type Handle = Mutex<OcrLineTracker>;

unsafe fn with_tracker<R>(
    handle: *mut std::ffi::c_void,
    f: impl FnOnce(&mut OcrLineTracker) -> R,
) -> R {
    let lock = &*(handle as *const Handle);
    let mut tracker = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    f(&mut tracker)
}

/// 新建 tracker，写 `*out_handle`（用 [ffc_ocrline_free] 释放）。
///
/// # Safety
/// `out_handle` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_new(out_handle: *mut *mut std::ffi::c_void) -> i32 {
    guard(|| {
        if out_handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        let boxed: Box<Handle> = Box::new(Mutex::new(OcrLineTracker::new()));
        *out_handle = Box::into_raw(boxed) as *mut std::ffi::c_void;
        status::OK
    })
}

/// 释放 tracker（空指针无操作）。签名是 `void(void*)`，可直接挂 `NativeFinalizer`。
///
/// # Safety
/// `handle` 是 [ffc_ocrline_new] 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_free(handle: *mut std::ffi::c_void) {
    if !handle.is_null() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            drop(Box::from_raw(handle as *mut Handle));
        }));
    }
}

/// 忘掉全部帧状态与上一句（换区域时）。
///
/// # Safety
/// `handle` 是 [ffc_ocrline_new] 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_reset(handle: *mut std::ffi::c_void) -> i32 {
    guard(|| {
        if handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        with_tracker(handle, OcrLineTracker::reset);
        status::OK
    })
}

/// 喂一帧整窗 PNG。`region` = 4 个 f32：客户区归一化 `[left, top, width, height]`。
/// `out_meta = [action, width, height]`；action 为 [action::OCR] 时裁好的 RGBA
/// （`width * height * 4`）经 `out_ptr` / `out_len` 交出（用 `ffc_free_bytes` 释放），否则二者写 null / 0。
/// PNG 坏返回 [status::BAD_INPUT]；区域与图没有交集返回 [status::INVALID_ARGUMENT]。
///
/// # Safety
/// `handle` 有效；`png` 按 `len` 可读；`region` 可读 4 个 f32；`out_ptr` / `out_len` 可写；
/// `out_meta` 可写 3 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_feed_png(
    handle: *mut std::ffi::c_void,
    png: *const u8,
    len: usize,
    region: *const f32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_meta: *mut u32,
) -> i32 {
    guard(|| {
        if handle.is_null()
            || png.is_null()
            || region.is_null()
            || out_ptr.is_null()
            || out_len.is_null()
            || out_meta.is_null()
        {
            return status::NULL_ARGUMENT;
        }
        let bytes = std::slice::from_raw_parts(png, len);
        let r = std::slice::from_raw_parts(region, 4);
        let result = with_tracker(handle, |t| t.feed_png(bytes, [r[0], r[1], r[2], r[3]]));
        *out_ptr = std::ptr::null_mut();
        *out_len = 0;
        let meta = std::slice::from_raw_parts_mut(out_meta, 3);
        match result {
            Err(code) => code,
            Ok(FrameAction::Ocr {
                rgba,
                width,
                height,
            }) => {
                meta.copy_from_slice(&[action::OCR, width, height]);
                hand_over_bytes(rgba, out_ptr, out_len);
                status::OK
            }
            Ok(other) => {
                let a = match other {
                    FrameAction::Idle => action::IDLE,
                    FrameAction::Settling => action::SETTLING,
                    FrameAction::Cleared => action::CLEARED,
                    FrameAction::Ocr { .. } => unreachable!(),
                };
                meta.copy_from_slice(&[a, 0, 0]);
                status::OK
            }
        }
    })
}

/// 喂一次 OCR 结果（UTF-8，行间 `\n`）。`*out_kind` 写 [kind] 之一；NEW / EXTEND 时这一句的显示文本
/// （UTF-8）经 `out_ptr` / `out_len` 交出（用 `ffc_free_bytes` 释放），否则二者写 null / 0。
/// 不是合法 UTF-8 返回 [status::BAD_INPUT]。
///
/// # Safety
/// `handle` 有效；`text` 按 `len` 可读（`len == 0` 时可为空指针）；输出指针可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_feed_text(
    handle: *mut std::ffi::c_void,
    text: *const u8,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_kind: *mut u32,
) -> i32 {
    guard(|| {
        if handle.is_null() || out_ptr.is_null() || out_len.is_null() || out_kind.is_null() {
            return status::NULL_ARGUMENT;
        }
        if text.is_null() && len != 0 {
            return status::NULL_ARGUMENT;
        }
        let bytes = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(text, len)
        };
        let Ok(raw) = std::str::from_utf8(bytes) else {
            return status::BAD_INPUT;
        };
        let event = with_tracker(handle, |t| t.feed_text(raw));
        *out_ptr = std::ptr::null_mut();
        *out_len = 0;
        let (k, line) = match event {
            TextEvent::Empty => (kind::EMPTY, None),
            TextEvent::Duplicate => (kind::DUPLICATE, None),
            TextEvent::New(s) => (kind::NEW, Some(s)),
            TextEvent::Extend(s) => (kind::EXTEND, Some(s)),
        };
        *out_kind = k;
        if let Some(s) = line {
            hand_over_bytes(s.into_bytes(), out_ptr, out_len);
        }
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 200;
    const H: usize = 50;

    /// 白底；`bars` 个黑色竖条（模拟字），从左往右排。
    fn frame(bars: usize) -> Vec<u8> {
        let mut px = vec![255u8; W * H * 4];
        for b in 0..bars {
            let x0 = 4 + b * 8;
            for y in 15..35 {
                for x in x0..(x0 + 4).min(W) {
                    let i = (y * W + x) * 4;
                    px[i..i + 3].copy_from_slice(&[0, 0, 0]);
                }
            }
        }
        px
    }

    fn with_cursor(mut px: Vec<u8>) -> Vec<u8> {
        for y in 40..48 {
            for x in 185..195 {
                let i = (y * W + x) * 4;
                px[i..i + 3].copy_from_slice(&[0, 0, 0]);
            }
        }
        px
    }

    fn is_ocr(a: &FrameAction) -> bool {
        matches!(a, FrameAction::Ocr { .. })
    }

    #[test]
    fn new_frame_waits_until_stable_then_ocr_once() {
        let mut t = OcrLineTracker::new();
        assert_eq!(t.feed_rgba(&frame(5), W, H), FrameAction::Settling);
        let a = t.feed_rgba(&frame(5), W, H);
        assert!(is_ocr(&a), "stable new frame must request OCR: {a:?}");
        // 同一画面不再重复 OCR。
        assert_eq!(t.feed_rgba(&frame(5), W, H), FrameAction::Idle);
        assert_eq!(t.feed_rgba(&frame(5), W, H), FrameAction::Idle);
    }

    #[test]
    fn typewriter_frames_do_not_ocr_half_lines() {
        let mut t = OcrLineTracker::new();
        for bars in 1..=10 {
            let a = t.feed_rgba(&frame(bars), W, H);
            assert_eq!(a, FrameAction::Settling, "bars={bars}");
        }
        assert!(is_ocr(&t.feed_rgba(&frame(10), W, H)));
    }

    #[test]
    fn ocr_rgba_is_the_cropped_frame() {
        let mut t = OcrLineTracker::new();
        let px = frame(3);
        t.feed_rgba(&px, W, H);
        match t.feed_rgba(&px, W, H) {
            FrameAction::Ocr {
                rgba,
                width,
                height,
            } => {
                assert_eq!((width, height), (W as u32, H as u32));
                assert_eq!(rgba, px);
            }
            other => panic!("expected OCR, got {other:?}"),
        }
    }

    #[test]
    fn blank_region_reports_cleared_once_and_forgets_last_line() {
        let mut t = OcrLineTracker::new();
        t.feed_rgba(&frame(4), W, H);
        t.feed_rgba(&frame(4), W, H);
        assert_eq!(
            t.feed_text("こんにちは"),
            TextEvent::New("こんにちは".into())
        );
        assert_eq!(t.feed_rgba(&frame(0), W, H), FrameAction::Cleared);
        assert_eq!(t.feed_rgba(&frame(0), W, H), FrameAction::Idle);
        // 空白之后同一句再出现：新的一句，且同一画面要重新 OCR。
        assert_eq!(t.feed_rgba(&frame(4), W, H), FrameAction::Settling);
        assert!(is_ocr(&t.feed_rgba(&frame(4), W, H)));
        assert_eq!(
            t.feed_text("こんにちは"),
            TextEvent::New("こんにちは".into())
        );
    }

    #[test]
    fn blinking_cursor_reocr_is_absorbed_by_text_dedup() {
        let mut t = OcrLineTracker::new();
        let on = with_cursor(frame(6));
        let off = frame(6);
        t.feed_rgba(&off, W, H);
        assert!(is_ocr(&t.feed_rgba(&off, W, H)));
        assert_eq!(
            t.feed_text("同じ台詞です"),
            TextEvent::New("同じ台詞です".into())
        );
        assert_eq!(t.feed_rgba(&on, W, H), FrameAction::Settling);
        assert!(is_ocr(&t.feed_rgba(&on, W, H)));
        assert_eq!(t.feed_text("同じ台詞です"), TextEvent::Duplicate);
    }

    #[test]
    fn feed_png_crops_normalized_region() {
        let mut full = vec![255u8; 400 * 200 * 4];
        // 只在下半部分画字。
        for y in 150..170 {
            for x in (20..200).step_by(8) {
                for dx in 0..4 {
                    let i = (y * 400 + x + dx) * 4;
                    full[i..i + 3].copy_from_slice(&[0, 0, 0]);
                }
            }
        }
        let img = image::RgbaImage::from_raw(400, 200, full).unwrap();
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let mut t = OcrLineTracker::new();
        // 上半部分没字：cleared。
        assert_eq!(
            t.feed_png(&png, [0.0, 0.0, 1.0, 0.5]).unwrap(),
            FrameAction::Cleared
        );
        t.reset();
        t.feed_png(&png, [0.0, 0.5, 1.0, 0.5]).unwrap();
        match t.feed_png(&png, [0.0, 0.5, 1.0, 0.5]).unwrap() {
            FrameAction::Ocr { width, height, .. } => assert_eq!((width, height), (400, 100)),
            other => panic!("expected OCR, got {other:?}"),
        }
        assert_eq!(
            t.feed_png(&png, [2.0, 2.0, 1.0, 1.0]),
            Err(status::INVALID_ARGUMENT)
        );
        assert_eq!(
            t.feed_png(b"not png", [0.0, 0.0, 1.0, 1.0]),
            Err(status::BAD_INPUT)
        );
    }

    #[test]
    fn short_line_in_wide_box_is_not_blank() {
        // 1920×300 的宽台词框里只有一个小字块（「はい」量级）：按面积密度会被判成空白。
        let (w, h) = (1920usize, 300usize);
        let mut px = vec![255u8; w * h * 4];
        for y in 120..150 {
            for x in (100..140).step_by(6) {
                for dx in 0..2 {
                    let i = (y * w + x + dx) * 4;
                    px[i..i + 3].copy_from_slice(&[0, 0, 0]);
                }
            }
        }
        let mut t = OcrLineTracker::new();
        assert_eq!(t.feed_rgba(&px, w, h), FrameAction::Settling);
        assert!(is_ocr(&t.feed_rgba(&px, w, h)));
    }

    #[test]
    fn normalize_removes_spaces_between_cjk_only() {
        assert_eq!(normalize_lines("こ ん に ち は"), "こんにちは");
        assert_eq!(normalize_lines("  今日は\n いい天気 \n"), "今日はいい天気");
        assert_eq!(normalize_lines("Hello\n  world"), "Hello world");
        assert_eq!(normalize_lines("ゲーム OK です"), "ゲーム OK です");
        assert_eq!(normalize_lines("「は い」"), "「はい」");
    }

    #[test]
    fn text_dedup_tolerates_ocr_jitter() {
        let mut t = OcrLineTracker::new();
        let line = "今日はとてもいい天気ですね、散歩に行きましょう";
        assert_eq!(t.feed_text(line), TextEvent::New(line.into()));
        // 一个字认错：同一句。
        assert_eq!(
            t.feed_text("今日はとてもいい天気ですね、散歩に行さましょう"),
            TextEvent::Duplicate
        );
        // 短句必须完全一致才算重复。
        let mut s = OcrLineTracker::new();
        assert_eq!(s.feed_text("はい"), TextEvent::New("はい".into()));
        assert_eq!(s.feed_text("いい"), TextEvent::New("いい".into()));
    }

    #[test]
    fn typewriter_pause_extends_previous_line_with_strict_prefix() {
        let mut t = OcrLineTracker::new();
        let base = "今日はとてもいい天気ですね";
        assert_eq!(t.feed_text(base), TextEvent::New(base.into()));
        // 前缀里有一个字认得不一样，输出仍以上一句为前缀（台词流的渐进折叠要严格前缀）。
        let full = "今日はとてもいい天気ですね、散歩に行きましょう";
        assert_eq!(
            t.feed_text("今日はとてもいい天気でずね、散歩に行きましょう"),
            TextEvent::Extend(full.into())
        );
        // 再识别到同一整句：重复。
        assert_eq!(t.feed_text(full), TextEvent::Duplicate);
        // 变短（淡出）：没有新信息。
        assert_eq!(
            t.feed_text("今日はとてもいい天気ですね、散歩"),
            TextEvent::Duplicate
        );
    }

    #[test]
    fn short_base_is_new_not_extend() {
        let mut t = OcrLineTracker::new();
        t.feed_text("はい");
        assert_eq!(
            t.feed_text("はい、そうです"),
            TextEvent::New("はい、そうです".into())
        );
    }

    #[test]
    fn empty_text_clears_last_line() {
        let mut t = OcrLineTracker::new();
        t.feed_text("もう一度");
        assert_eq!(t.feed_text("  \n "), TextEvent::Empty);
        assert_eq!(t.feed_text("もう一度"), TextEvent::New("もう一度".into()));
    }

    #[test]
    fn ffi_roundtrip() {
        unsafe {
            let mut h = std::ptr::null_mut();
            assert_eq!(ffc_ocrline_new(&mut h), status::OK);
            let s = "ゲ ー ム";
            let mut ptr = std::ptr::null_mut();
            let mut len = 0usize;
            let mut k = 99u32;
            assert_eq!(
                ffc_ocrline_feed_text(h, s.as_ptr(), s.len(), &mut ptr, &mut len, &mut k),
                status::OK
            );
            assert_eq!(k, kind::NEW);
            assert_eq!(
                std::str::from_utf8(std::slice::from_raw_parts(ptr, len)).unwrap(),
                "ゲーム"
            );
            crate::ffc_free_bytes(ptr, len);
            assert_eq!(
                ffc_ocrline_feed_text(h, s.as_ptr(), s.len(), &mut ptr, &mut len, &mut k),
                status::OK
            );
            assert_eq!((k, ptr.is_null(), len), (kind::DUPLICATE, true, 0));
            let bad = [0xffu8, 0xfe];
            assert_eq!(
                ffc_ocrline_feed_text(h, bad.as_ptr(), 2, &mut ptr, &mut len, &mut k),
                status::BAD_INPUT
            );
            assert_eq!(ffc_ocrline_reset(h), status::OK);
            let mut meta = [9u32; 3];
            let region = [0.0f32, 0.0, 1.0, 1.0];
            assert_eq!(
                ffc_ocrline_feed_png(
                    h,
                    b"x".as_ptr(),
                    1,
                    region.as_ptr(),
                    &mut ptr,
                    &mut len,
                    meta.as_mut_ptr()
                ),
                status::BAD_INPUT
            );
            ffc_ocrline_free(h);
            ffc_ocrline_free(std::ptr::null_mut());
        }
    }
}
