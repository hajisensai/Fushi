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
//!
//! 第二期（BUG-5141）补的两件判定细节也在这里：
//! - **易变格掩码**：台词框里循环播放的小动画（「点击继续」图标、光标）若与取帧间隔错相，
//!   每帧都有几格在变，整框永远「不稳定」、整句不出。每格记一个易变分（变一次 +2、稳一帧 -1），
//!   分数够高的格子在「变没变」的判定里排除；打字机逐字出墨每格只变一次，不会被当成易变。
//!   易变格超过网格四分之一（整框在动：视频底 / 转场）时掩码作废，回到整框判定。
//! - **送 OCR 前的预处理**：估计字高，小字（低分辨率游戏）按整数倍放大到识别器舒服的字高；
//!   可选按 Otsu 阈值二值化（字与底分成黑白两色，少数派当字），给低对比 / 描边字用。

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

/// 一格「变了」时易变分加多少 / 封顶多少 / 达到多少算易变格（稳一帧减 1）。
/// 连续三帧都变（2+2+2）才算易变：打字机每格只在出墨那一帧变一次。
const VOLATILE_HIT: u8 = 2;
const VOLATILE_CAP: u8 = 8;
const VOLATILE_SCORE: u8 = 6;

/// 易变格超过这么多就不当掩码用（整框都在动，不是局部小动画）。
const VOLATILE_MAX_CELLS: usize = GRID_W * GRID_H / 4;

/// 估出的字高低于它才放大（像素）；放大目标字高；最大倍数。
const UPSCALE_BELOW_TEXT_HEIGHT: usize = 16;
const UPSCALE_TARGET_TEXT_HEIGHT: usize = 24;
const UPSCALE_MAX_FACTOR: usize = 4;

/// 放大后的最长边上限：Windows.Media.Ocr 的 `OcrEngine.MaxImageDimension`（2600），
/// 超过会被识别端再缩回去，放大就白做了。
const OCR_MAX_DIMENSION: usize = 2600;

/// 一行里水平边缘至少这么多，才算「有墨的行」（估字高用）。
const INK_ROW_MIN_EDGES: usize = 2;

/// [ffc_ocrline_configure] 的标志位。
pub mod flags {
    /// 送 OCR 前按 Otsu 阈值二值化。
    pub const BINARIZE: u32 = 1;
    /// 全部已知位。
    pub const ALL: u32 = BINARIZE;
}

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

/// 送 OCR 前的预处理选项（[ffc_ocrline_configure]）。小字放大总是开着，不是选项。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Preprocess {
    pub binarize: bool,
}

/// 连续 OCR 台词流的状态机。
#[derive(Default)]
pub struct OcrLineTracker {
    prev_sig: Option<Signature>,
    stable: u32,
    ocr_sig: Option<Signature>,
    blank: bool,
    /// 每格易变分（见模块文档）；空 = 还没比过两帧。
    volatility: Vec<u8>,
    /// 上一句（显示文本）。
    last_text: Option<String>,
    preprocess: Preprocess,
}

impl OcrLineTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// 换区域 / 重新开始：忘掉全部帧状态与上一句（预处理选项保留，它是用户设置不是帧状态）。
    pub fn reset(&mut self) {
        let preprocess = self.preprocess;
        *self = Self::default();
        self.preprocess = preprocess;
    }

    /// 换预处理选项。已送 OCR 的那一帧作废：同一画面稳定时按新选项再识别一次。
    pub fn configure(&mut self, preprocess: Preprocess) {
        if self.preprocess != preprocess {
            self.preprocess = preprocess;
            self.ocr_sig = None;
        }
    }

    /// 上一次交出的 OCR 帧没能识别（识别器单次报错）：只忘掉「这一帧已 OCR 过」，
    /// 同一画面稳定时会再交出一次；上一句保留（去重照旧）。
    pub fn forget_frame(&mut self) {
        self.ocr_sig = None;
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
        if let Some(prev) = &self.prev_sig {
            update_volatility(&mut self.volatility, prev, &sig);
        }
        let mask = volatile_mask(&self.volatility);
        let mask = mask.as_deref();
        match &self.prev_sig {
            Some(prev) if !changed(prev, &sig, mask) => self.stable = self.stable.saturating_add(1),
            _ => self.stable = 0,
        }
        let needs_ocr = self.ocr_sig.as_ref().is_none_or(|o| changed(o, &sig, mask));
        self.prev_sig = Some(sig.clone());
        if !needs_ocr {
            return FrameAction::Idle;
        }
        if self.stable == 0 {
            return FrameAction::Settling;
        }
        self.ocr_sig = Some(sig);
        let (rgba, width, height) = prepare_for_ocr(rgba, &luma, width, height, self.preprocess);
        FrameAction::Ocr {
            rgba,
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

/// 两帧有没有变：亮度差超过 [CELL_DELTA] 的格子（排除 `mask` 里的易变格）不少于 [MIN_CHANGED_CELLS]。
fn changed(a: &Signature, b: &Signature, mask: Option<&[bool]>) -> bool {
    a.iter()
        .zip(b)
        .enumerate()
        .filter(|(i, (x, y))| x.abs_diff(**y) > CELL_DELTA && !mask.is_some_and(|m| m[*i]))
        .count()
        >= MIN_CHANGED_CELLS
}

/// 用相邻两帧的逐格差更新易变分：变了 +[VOLATILE_HIT]（封顶 [VOLATILE_CAP]），没变 -1。
fn update_volatility(scores: &mut Vec<u8>, prev: &Signature, cur: &Signature) {
    if scores.len() != cur.len() {
        *scores = vec![0; cur.len()];
    }
    for ((score, a), b) in scores.iter_mut().zip(prev).zip(cur) {
        *score = if a.abs_diff(*b) > CELL_DELTA {
            score.saturating_add(VOLATILE_HIT).min(VOLATILE_CAP)
        } else {
            score.saturating_sub(1)
        };
    }
}

/// 易变格掩码：没有易变格、或易变格多到说明整框在动时返回 None（按整框判定）。
fn volatile_mask(scores: &[u8]) -> Option<Vec<bool>> {
    let mask: Vec<bool> = scores.iter().map(|&s| s >= VOLATILE_SCORE).collect();
    let n = mask.iter().filter(|&&v| v).count();
    (n > 0 && n <= VOLATILE_MAX_CELLS).then_some(mask)
}

/// 估计字高：有墨的行（水平边缘 ≥ [INK_ROW_MIN_EDGES]）连成段，取段高的中位数；
/// 只有 1 行高的段当噪声。没有墨返回 0。
fn estimate_text_height(luma: &[u8], width: usize, height: usize) -> usize {
    if width < 2 || height == 0 {
        return 0;
    }
    let mut runs: Vec<usize> = Vec::new();
    let mut run = 0usize;
    for row in luma.chunks_exact(width).take(height) {
        let edges = row
            .windows(2)
            .filter(|p| (p[0] as i32 - p[1] as i32).abs() > EDGE_DELTA)
            .count();
        if edges >= INK_ROW_MIN_EDGES {
            run += 1;
        } else {
            if run >= 2 {
                runs.push(run);
            }
            run = 0;
        }
    }
    if run >= 2 {
        runs.push(run);
    }
    if runs.is_empty() {
        return 0;
    }
    runs.sort_unstable();
    runs[runs.len() / 2]
}

/// 放大倍数：字高 < [UPSCALE_BELOW_TEXT_HEIGHT] 时放到约 [UPSCALE_TARGET_TEXT_HEIGHT]，
/// 不超过 [UPSCALE_MAX_FACTOR] 倍，放大后最长边不超过 [OCR_MAX_DIMENSION]。
fn upscale_factor(text_height: usize, width: usize, height: usize) -> usize {
    if text_height == 0 || text_height >= UPSCALE_BELOW_TEXT_HEIGHT {
        return 1;
    }
    let mut factor = UPSCALE_TARGET_TEXT_HEIGHT
        .div_ceil(text_height)
        .clamp(1, UPSCALE_MAX_FACTOR);
    let longest = width.max(height).max(1);
    while factor > 1 && longest * factor > OCR_MAX_DIMENSION {
        factor -= 1;
    }
    factor
}

/// Otsu 阈值（类间方差最大）：返回 t，亮度 `> t` 的是亮类。
fn otsu_threshold(luma: &[u8]) -> u8 {
    let mut hist = [0u64; 256];
    for &v in luma {
        hist[v as usize] += 1;
    }
    let total = luma.len() as f64;
    let sum_all: f64 = hist
        .iter()
        .enumerate()
        .map(|(i, &c)| i as f64 * c as f64)
        .sum();
    let (mut w_bg, mut sum_bg) = (0f64, 0f64);
    let (mut best, mut best_var) = (0u8, -1f64);
    for (t, &count) in hist.iter().enumerate() {
        w_bg += count as f64;
        sum_bg += t as f64 * count as f64;
        if w_bg == 0.0 {
            continue;
        }
        let w_fg = total - w_bg;
        if w_fg == 0.0 {
            break;
        }
        let m_bg = sum_bg / w_bg;
        let m_fg = (sum_all - sum_bg) / w_fg;
        let var = w_bg * w_fg * (m_bg - m_fg).powi(2);
        if var > best_var {
            best_var = var;
            best = t as u8;
        }
    }
    best
}

/// 二值化成白底黑字：按 Otsu 分成亮暗两类，像素少的一类当字（深字浅底、浅字深底都成黑字）。
fn binarize_rgba(rgba: &[u8], width: usize, height: usize) -> Vec<u8> {
    let luma = to_luma(rgba, width, height);
    let t = otsu_threshold(&luma);
    let bright = luma.iter().filter(|&&v| v > t).count();
    let text_is_bright = bright * 2 < luma.len();
    let mut out = Vec::with_capacity(luma.len() * 4);
    for &v in &luma {
        let c = if (v > t) == text_is_bright {
            0u8
        } else {
            255u8
        };
        out.extend_from_slice(&[c, c, c, 255]);
    }
    out
}

/// 送 OCR 前的预处理：小字放大（总是开）→ 可选二值化。返回 `(rgba, width, height)`。
fn prepare_for_ocr(
    rgba: &[u8],
    luma: &[u8],
    width: usize,
    height: usize,
    preprocess: Preprocess,
) -> (Vec<u8>, usize, usize) {
    let factor = upscale_factor(estimate_text_height(luma, width, height), width, height);
    let (mut px, w, h) = if factor > 1 {
        let (nw, nh) = (width * factor, height * factor);
        match image::RgbaImage::from_raw(width as u32, height as u32, rgba.to_vec()) {
            Some(img) => {
                let up = image::imageops::resize(
                    &img,
                    nw as u32,
                    nh as u32,
                    image::imageops::FilterType::CatmullRom,
                );
                (up.into_raw(), nw, nh)
            }
            None => (rgba.to_vec(), width, height),
        }
    } else {
        (rgba.to_vec(), width, height)
    };
    if preprocess.binarize {
        px = binarize_rgba(&px, w, h);
    }
    (px, w, h)
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

/// 设预处理选项：`option_flags` 是 [flags] 的按位或（未知位返回 [status::INVALID_ARGUMENT]）。
/// 选项变了时已送 OCR 的那一帧作废，同一画面稳定时按新选项再识别一次。
///
/// # Safety
/// `handle` 是 [ffc_ocrline_new] 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_configure(
    handle: *mut std::ffi::c_void,
    option_flags: u32,
) -> i32 {
    guard(|| {
        if handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        if option_flags & !flags::ALL != 0 {
            return status::INVALID_ARGUMENT;
        }
        let preprocess = Preprocess {
            binarize: option_flags & flags::BINARIZE != 0,
        };
        with_tracker(handle, |t| t.configure(preprocess));
        status::OK
    })
}

/// 上一次交出的 OCR 帧识别失败：只忘掉帧标记（同一画面会再交出一次），上一句保留。
///
/// # Safety
/// `handle` 是 [ffc_ocrline_new] 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocrline_forget_frame(handle: *mut std::ffi::c_void) -> i32 {
    guard(|| {
        if handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        with_tracker(handle, OcrLineTracker::forget_frame);
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
    fn forget_frame_reoffers_same_frame_but_keeps_last_line() {
        let mut t = OcrLineTracker::new();
        t.feed_rgba(&frame(5), W, H);
        assert!(is_ocr(&t.feed_rgba(&frame(5), W, H)));
        assert_eq!(
            t.feed_text("同じ台詞です"),
            TextEvent::New("同じ台詞です".into())
        );
        assert_eq!(t.feed_rgba(&frame(5), W, H), FrameAction::Idle);
        t.forget_frame();
        assert!(is_ocr(&t.feed_rgba(&frame(5), W, H)));
        assert_eq!(t.feed_text("同じ台詞です"), TextEvent::Duplicate);
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

    /// 框右下角的「点击继续」动画：`phase` 决定画在哪一相（三相循环，每相位置 / 形状都不同）。
    fn with_wait_icon(mut px: Vec<u8>, phase: usize) -> Vec<u8> {
        let x0 = 170 + (phase % 3) * 8;
        for y in 38..48 {
            for x in x0..(x0 + 6).min(W) {
                let i = (y * W + x) * 4;
                px[i..i + 3].copy_from_slice(&[0, 0, 0]);
            }
        }
        px
    }

    #[test]
    fn looping_wait_icon_does_not_block_ocr_forever() {
        // BUG-5141 ⑥：等待动画与取帧错相循环，每帧都有几格在变；修之前永远 Settling、整句不出。
        let mut t = OcrLineTracker::new();
        let mut ocr_frames = 0;
        for i in 0..12 {
            if is_ocr(&t.feed_rgba(&with_wait_icon(frame(8), i), W, H)) {
                ocr_frames += 1;
            }
        }
        assert!(
            ocr_frames >= 1,
            "static line with a looping icon must be OCR'd"
        );
        // 动画继续转，台词没变：不再反复 OCR。
        for i in 12..24 {
            assert!(
                !is_ocr(&t.feed_rgba(&with_wait_icon(frame(8), i), W, H)),
                "frame {i} re-OCR'd although only the icon moved"
            );
        }
        // 下一句（字变了，图标照转）：仍然先等稳定再 OCR 一次。
        let mut next_ocr = 0;
        for i in 24..30 {
            if is_ocr(&t.feed_rgba(&with_wait_icon(frame(14), i), W, H)) {
                next_ocr += 1;
            }
        }
        assert_eq!(next_ocr, 1, "the next line must be OCR'd exactly once");
    }

    #[test]
    fn typewriter_cells_never_become_volatile() {
        // 打字机每格只出墨一次：逐字出现时仍然一直 Settling（不会被易变掩码当成「已稳定」OCR 半句）。
        let mut t = OcrLineTracker::new();
        for bars in 1..=20 {
            assert_eq!(
                t.feed_rgba(&frame(bars), W, H),
                FrameAction::Settling,
                "bars={bars}"
            );
        }
        assert!(is_ocr(&t.feed_rgba(&frame(20), W, H)));
    }

    #[test]
    fn whole_box_animation_disables_the_mask() {
        // 整框都在动（视频底 / 转场）：不把整框当易变掩掉，照旧不稳定、不 OCR。
        let mut t = OcrLineTracker::new();
        for i in 0..10 {
            let mut px = frame(8);
            let shade = if i % 2 == 0 { 120u8 } else { 230u8 };
            for p in px.chunks_exact_mut(4) {
                if p[0] == 255 {
                    p[..3].copy_from_slice(&[shade, shade, shade]);
                }
            }
            assert!(!is_ocr(&t.feed_rgba(&px, W, H)), "frame {i}");
        }
    }

    /// `rows` 行高的小字（黑竖条）。
    fn small_text(w: usize, h: usize, rows: usize) -> Vec<u8> {
        let mut px = vec![255u8; w * h * 4];
        let y0 = (h - rows) / 2;
        for y in y0..y0 + rows {
            for x in (4..w - 4).step_by(5) {
                for dx in 0..2 {
                    let i = (y * w + x + dx) * 4;
                    px[i..i + 3].copy_from_slice(&[0, 0, 0]);
                }
            }
        }
        px
    }

    #[test]
    fn small_text_is_upscaled_before_ocr() {
        let (w, h) = (300usize, 40usize);
        let px = small_text(w, h, 8);
        let mut t = OcrLineTracker::new();
        t.feed_rgba(&px, w, h);
        match t.feed_rgba(&px, w, h) {
            FrameAction::Ocr {
                rgba,
                width,
                height,
            } => {
                // 字高 8 → 放 3 倍到 24。
                assert_eq!((width, height), (900, 120));
                assert_eq!(rgba.len(), 900 * 120 * 4);
            }
            other => panic!("expected OCR, got {other:?}"),
        }
    }

    #[test]
    fn upscale_respects_ocr_max_dimension() {
        assert_eq!(upscale_factor(8, 300, 40), 3);
        assert_eq!(upscale_factor(4, 300, 40), 4);
        assert_eq!(upscale_factor(20, 300, 40), 1);
        assert_eq!(upscale_factor(0, 300, 40), 1);
        // 1800 宽放 3 倍超过 2600：退到 1 倍（2 倍 3600 也超）。
        assert_eq!(upscale_factor(8, 1800, 100), 1);
        assert_eq!(upscale_factor(8, 1000, 100), 2);
    }

    #[test]
    fn estimate_text_height_takes_median_ink_run() {
        let (w, h) = (100usize, 60usize);
        let mut px = vec![255u8; w * h * 4];
        for (y0, rows) in [(5usize, 10usize), (25, 12), (45, 11)] {
            for y in y0..y0 + rows {
                for x in (2..98).step_by(4) {
                    let i = (y * w + x) * 4;
                    px[i..i + 3].copy_from_slice(&[0, 0, 0]);
                }
            }
        }
        let luma = to_luma(&px, w, h);
        assert_eq!(estimate_text_height(&luma, w, h), 11);
        assert_eq!(estimate_text_height(&to_luma(&frame(0), W, H), W, H), 0);
    }

    #[test]
    fn binarize_makes_dark_text_on_white_for_both_polarities() {
        // 浅灰底上的深灰字，与深底上的浅字：都应变成白底黑字。
        let (w, h) = (40usize, 10usize);
        for (bg, fg) in [(180u8, 90u8), (30u8, 220u8)] {
            let mut px = Vec::with_capacity(w * h * 4);
            for y in 0..h {
                for x in 0..w {
                    let c = if (3..7).contains(&y) && x % 5 == 0 {
                        fg
                    } else {
                        bg
                    };
                    px.extend_from_slice(&[c, c, c, 255]);
                }
            }
            let out = binarize_rgba(&px, w, h);
            let text = (4 * w + 5) * 4;
            let ground = 4; // (x=1, y=0)
            assert_eq!(&out[text..text + 4], &[0, 0, 0, 255], "bg={bg} fg={fg}");
            assert_eq!(
                &out[ground..ground + 4],
                &[255, 255, 255, 255],
                "bg={bg} fg={fg}"
            );
        }
    }

    #[test]
    fn configure_binarize_reoffers_the_same_frame() {
        let mut t = OcrLineTracker::new();
        let mut px = frame(5);
        // 灰底：二值化后底变纯白，可以和原图区分。
        for p in px.chunks_exact_mut(4) {
            if p[0] == 255 {
                p[..3].copy_from_slice(&[200, 200, 200]);
            }
        }
        t.feed_rgba(&px, W, H);
        assert!(is_ocr(&t.feed_rgba(&px, W, H)));
        assert_eq!(t.feed_rgba(&px, W, H), FrameAction::Idle);
        t.configure(Preprocess { binarize: true });
        match t.feed_rgba(&px, W, H) {
            FrameAction::Ocr { rgba, .. } => assert_eq!(&rgba[..4], &[255, 255, 255, 255]),
            other => panic!("expected re-OCR after configure, got {other:?}"),
        }
        // 同样的选项再设一次：不作废。
        t.configure(Preprocess { binarize: true });
        assert_eq!(t.feed_rgba(&px, W, H), FrameAction::Idle);
        // reset 保留选项。
        t.reset();
        t.feed_rgba(&px, W, H);
        match t.feed_rgba(&px, W, H) {
            FrameAction::Ocr { rgba, .. } => assert_eq!(&rgba[..4], &[255, 255, 255, 255]),
            other => panic!("expected OCR, got {other:?}"),
        }
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
            assert_eq!(ffc_ocrline_configure(h, flags::BINARIZE), status::OK);
            assert_eq!(ffc_ocrline_configure(h, 0), status::OK);
            assert_eq!(ffc_ocrline_configure(h, 0x80), status::INVALID_ARGUMENT);
            assert_eq!(
                ffc_ocrline_configure(std::ptr::null_mut(), 0),
                status::NULL_ARGUMENT
            );
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
