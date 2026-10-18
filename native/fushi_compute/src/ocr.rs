//! `ffc_ocr_*`：OCR 后段（PP-OCR CTC 贪心解码、RT-DETR 输出解码 / 分组 NMS / 内外判定）与
//! 漫画分格的 NMS + 分行排序。
//!
//! 只有这一份实现（Dart 侧 `packages/fushi_compute/lib/src/ocr/`，调用方
//! `fushi_engine/lib/ocr/ppocr_line_recognizer.dart` / `text_detector.dart` /
//! `media/manga/panel_detection.dart`）。逐位复刻旧 Dart 实现：浮点求值顺序相同，
//! `max` / `min` / `clamp` / `compareTo` / `List.sort` 用 [crate::dart] 的 Dart 语义版本（并列
//! 元素的去向与 Dart 的不稳定排序一致）。`exp` 走平台 libm，与 Dart VM 的 `math.exp` 同源。
//! 回归向量见 `packages/fushi_engine/test/media/image_kernels/ocr_kernel_*.dart`。

use crate::dart::{clamp_f64, compare_f64, max_f64, min_f64, sort};
use crate::{guard, status};

unsafe fn slice<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

unsafe fn slice_mut<'a, T>(ptr: *mut T, len: usize) -> &'a mut [T] {
    if len == 0 {
        &mut []
    } else {
        std::slice::from_raw_parts_mut(ptr, len)
    }
}

// ---------------------------------------------------------------------------
// CTC 贪心解码。
// ---------------------------------------------------------------------------

/// 每个吐字 run 一条记录的 f64 个数：`[token, frameStart, frameEnd, firstConf, meanConf]`。
pub const CTC_RECORD_FIELDS: usize = 5;

/// `_ppOcrFrameConfidence`：整行像概率（每项在 [-1e-5, 1.00001] 且和与 1 差 ≤ 0.02）时取
/// argmax 概率夹进 [0, 1]，否则按 logits 求 softmax(argmax) = 1 / Σexp(x - max)。
#[inline]
fn frame_confidence(row: &[f32], best: usize) -> f64 {
    let mut sum = 0.0f64;
    let mut probability_row = true;
    for &v in row {
        let value = v as f64;
        sum += value;
        // 不能写成 `!(..).contains()`：NaN 在这里不让整行失去「概率行」资格（同 Dart）。
        #[allow(clippy::manual_range_contains)]
        if value < -1e-5 || value > 1.00001 {
            probability_row = false;
        }
    }
    if probability_row && (sum - 1.0).abs() <= 0.02 {
        return clamp_f64(row[best] as f64, 0.0, 1.0);
    }
    let row_max = row[best] as f64;
    let mut denominator = 0.0f64;
    for &v in row {
        denominator += (v as f64 - row_max).exp();
    }
    1.0 / denominator
}

/// 逐帧 argmax（并列取先出现的下标，NaN 永不胜出）。
#[inline]
fn argmax(row: &[f32]) -> usize {
    let mut best = 0usize;
    let mut best_score = row[0] as f64;
    for (v, &s) in row.iter().enumerate().skip(1) {
        let s = s as f64;
        if s > best_score {
            best_score = s;
            best = v;
        }
    }
    best
}

/// 贪心 CTC：合并相邻重复、去 blank。每个吐字 run 一条记录（[CTC_RECORD_FIELDS]）：
/// - `firstConf`：run 首帧的置信度（`ctcGreedyDecodeScored` 的口径，取其最小值得行置信度）；
/// - `meanConf`：run 内逐帧置信度的均值（`recognizeLineDetailed` 的口径），`detailed == 0`
///   时不算、写 NaN（详细口径要逐帧扫整个词表，热路径不付这笔）。
///
/// `detailed != 0` 时先查整个张量都是有限值，否则返回 [status::BAD_INPUT]（Dart 侧抛
/// `StateError`，与旧 `_validatePpOcrOutput` 同文案）。`out` 容量至少
/// `frames * CTC_RECORD_FIELDS` 个 f64，`out_count` 写 run 数。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocr_ctc_greedy(
    logits: *const f32,
    len: usize,
    frames: u32,
    vocab: u32,
    detailed: i32,
    out: *mut f64,
    out_cap: usize,
    out_count: *mut usize,
) -> i32 {
    guard(|| {
        if logits.is_null() || out.is_null() || out_count.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (t, v) = (frames as usize, vocab as usize);
        if v == 0 || len != t * v {
            return status::INVALID_ARGUMENT;
        }
        if out_cap < t * CTC_RECORD_FIELDS {
            return status::BUFFER_TOO_SMALL;
        }
        let data = slice(logits, len);
        let detailed = detailed != 0;
        if detailed && data.iter().any(|x| !x.is_finite()) {
            return status::BAD_INPUT;
        }
        let out = slice_mut(out, out_cap);
        let mut count = 0usize;
        let mut previous: isize = -1;
        let mut run_start = 0usize;
        let mut first_conf = 0.0f64;
        let mut conf_sum = 0.0f64;
        let mut conf_count = 0usize;
        let mut flush = |token: isize,
                         start: usize,
                         end: usize,
                         first: f64,
                         sum: f64,
                         n: usize,
                         count: &mut usize| {
            let r = &mut out[*count * CTC_RECORD_FIELDS..(*count + 1) * CTC_RECORD_FIELDS];
            r[0] = token as f64;
            r[1] = start as f64;
            r[2] = end as f64;
            r[3] = first;
            r[4] = if detailed {
                if n == 0 {
                    0.0
                } else {
                    sum / n as f64
                }
            } else {
                f64::NAN
            };
            *count += 1;
        };
        for frame in 0..t {
            let row = &data[frame * v..(frame + 1) * v];
            let best = argmax(row) as isize;
            if best != previous {
                if previous > 0 {
                    flush(
                        previous, run_start, frame, first_conf, conf_sum, conf_count, &mut count,
                    );
                }
                if best != 0 {
                    run_start = frame;
                    conf_sum = 0.0;
                    conf_count = 0;
                    first_conf = frame_confidence(row, best as usize);
                    if detailed {
                        conf_sum += first_conf;
                        conf_count += 1;
                    }
                }
            } else if best != 0 && detailed {
                conf_sum += frame_confidence(row, best as usize);
                conf_count += 1;
            }
            previous = best;
        }
        if previous > 0 {
            flush(
                previous, run_start, t, first_conf, conf_sum, conf_count, &mut count,
            );
        }
        *out_count = count;
        status::OK
    })
}

// ---------------------------------------------------------------------------
// RT-DETR 输出解码 / 分组 NMS / 内外判定。
// ---------------------------------------------------------------------------

/// 每条检测记录的 f64 个数：`[left, top, right, bottom, score, tag]`；`tag` 在原始导出里是
/// 类别号，在图内后处理导出里是输入下标（类别由 Dart 侧按 `labels[i].round()` 取，保留
/// 旧实现对 num 标签的取整与报错语义）。
pub const DET_RECORD_FIELDS: usize = 6;

/// `LetterboxTransform` 的 8 个字段：`scaleX, scaleY, padX, padY, srcW, srcH, dstW, dstH`。
#[derive(Clone, Copy)]
struct Transform {
    scale_x: f64,
    scale_y: f64,
    pad_x: f64,
    pad_y: f64,
    src_w: f64,
    src_h: f64,
    dst_w: f64,
    dst_h: f64,
}

impl Transform {
    fn from(t: &[f64]) -> Self {
        Self {
            scale_x: t[0],
            scale_y: t[1],
            pad_x: t[2],
            pad_y: t[3],
            src_w: t[4],
            src_h: t[5],
            dst_w: t[6],
            dst_h: t[7],
        }
    }

    #[inline]
    fn inverse_x(&self, x: f64) -> f64 {
        (x - self.pad_x) / self.scale_x
    }

    #[inline]
    fn inverse_y(&self, y: f64) -> f64 {
        (y - self.pad_y) / self.scale_y
    }

    /// `OcrRect(...).clamp(srcW, srcH)` 后的四边，及其面积是否 > 0。
    #[inline]
    fn rect(&self, l: f64, t: f64, r: f64, b: f64) -> Option<[f64; 4]> {
        let rect = [
            clamp_f64(self.inverse_x(l), 0.0, self.src_w),
            clamp_f64(self.inverse_y(t), 0.0, self.src_h),
            clamp_f64(self.inverse_x(r), 0.0, self.src_w),
            clamp_f64(self.inverse_y(b), 0.0, self.src_h),
        ];
        if area(&rect) <= 0.0 {
            None
        } else {
            Some(rect)
        }
    }
}

/// `OcrRect.area`（宽高各取 `max(0, …)`）。
#[inline]
fn area(r: &[f64; 4]) -> f64 {
    max_f64(0.0, r[2] - r[0]) * max_f64(0.0, r[3] - r[1])
}

/// `OcrRect.iou`（[a] 是接收者）。
#[inline]
fn ocr_iou(a: &[f64; 4], b: &[f64; 4]) -> f64 {
    let ix = max_f64(0.0, min_f64(a[2], b[2]) - max_f64(a[0], b[0]));
    let iy = max_f64(0.0, min_f64(a[3], b[3]) - max_f64(a[1], b[1]));
    let inter = ix * iy;
    if inter <= 0.0 {
        return 0.0;
    }
    let union = area(a) + area(b) - inter;
    if union <= 0.0 {
        0.0
    } else {
        inter / union
    }
}

#[inline]
fn push_det(out: &mut [f64], count: &mut usize, rect: [f64; 4], score: f64, tag: f64) {
    let r = &mut out[*count * DET_RECORD_FIELDS..(*count + 1) * DET_RECORD_FIELDS];
    r[..4].copy_from_slice(&rect);
    r[4] = score;
    r[5] = tag;
    *count += 1;
}

/// `decodeRtdetrOutputs`：逐 (query, class) sigmoid 过阈值，cxcywh → xyxy、反变换回原图、
/// 夹进原图、去掉零面积。`out` 容量至少 `queries * classes * DET_RECORD_FIELDS`。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`transform` 可读 8 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_ocr_rtdetr_decode(
    logits: *const f32,
    logits_len: usize,
    boxes: *const f32,
    boxes_len: usize,
    queries: u32,
    classes: u32,
    transform: *const f64,
    score_threshold: f64,
    out: *mut f64,
    out_cap: usize,
    out_count: *mut usize,
) -> i32 {
    guard(|| {
        if logits.is_null() || boxes.is_null() || transform.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        if out_count.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (nq, nc) = (queries as usize, classes as usize);
        if logits_len != nq * nc || boxes_len != nq * 4 {
            return status::INVALID_ARGUMENT;
        }
        if out_cap < nq * nc * DET_RECORD_FIELDS {
            return status::BUFFER_TOO_SMALL;
        }
        let logits = slice(logits, logits_len);
        let boxes = slice(boxes, boxes_len);
        let tr = Transform::from(slice(transform, 8));
        let out = slice_mut(out, out_cap);
        let mut count = 0usize;
        for q in 0..nq {
            for c in 0..nc {
                let score = 1.0 / (1.0 + (-(logits[q * nc + c] as f64)).exp());
                if score < score_threshold {
                    continue;
                }
                let cx = boxes[q * 4] as f64 * tr.dst_w;
                let cy = boxes[q * 4 + 1] as f64 * tr.dst_h;
                let w = boxes[q * 4 + 2] as f64 * tr.dst_w;
                let h = boxes[q * 4 + 3] as f64 * tr.dst_h;
                if let Some(rect) = tr.rect(cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0) {
                    push_det(out, &mut count, rect, score, c as f64);
                }
            }
        }
        *out_count = count;
        status::OK
    })
}

/// `decodeProcessedRtdetrOutputs`：图内已做完 sigmoid / top-k / xyxy 的导出。记录的 `tag`
/// 是输入下标。`out` 容量至少 `n * DET_RECORD_FIELDS`。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`transform` 可读 8 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_ocr_rtdetr_decode_processed(
    scores: *const f32,
    n: usize,
    boxes: *const f32,
    boxes_len: usize,
    transform: *const f64,
    score_threshold: f64,
    out: *mut f64,
    out_cap: usize,
    out_count: *mut usize,
) -> i32 {
    guard(|| {
        if scores.is_null() || boxes.is_null() || transform.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        if out_count.is_null() {
            return status::NULL_ARGUMENT;
        }
        if boxes_len != n * 4 {
            return status::INVALID_ARGUMENT;
        }
        if out_cap < n * DET_RECORD_FIELDS {
            return status::BUFFER_TOO_SMALL;
        }
        let scores = slice(scores, n);
        let boxes = slice(boxes, boxes_len);
        let tr = Transform::from(slice(transform, 8));
        let out = slice_mut(out, out_cap);
        let mut count = 0usize;
        for (i, &score) in scores.iter().enumerate() {
            let score = score as f64;
            if score < score_threshold {
                continue;
            }
            let o = i * 4;
            if let Some(rect) = tr.rect(
                boxes[o] as f64,
                boxes[o + 1] as f64,
                boxes[o + 2] as f64,
                boxes[o + 3] as f64,
            ) {
                push_det(out, &mut count, rect, score, i as f64);
            }
        }
        *out_count = count;
        status::OK
    })
}

/// `nmsGroupOf`：气泡（0 类）一组，文字（其余）一组。
#[inline]
fn nms_group(class_id: i64) -> i32 {
    if class_id == 0 {
        0
    } else {
        1
    }
}

/// `applyClassAwareNms`：按分数降序（Dart `List.sort`，并列去向同 Dart），同组 IoU ≥
/// [iou_threshold] 的低分框剔除。[dets] 每条 [DET_RECORD_FIELDS] 个 f64（`tag` = 类别号）；
/// `out_kept` 按保留顺序写输入下标，`out_count` 写保留数。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`out_kept` 可写 `count` 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocr_class_aware_nms(
    dets: *const f64,
    count: usize,
    iou_threshold: f64,
    out_kept: *mut u32,
    out_count: *mut usize,
) -> i32 {
    guard(|| {
        if (count > 0 && (dets.is_null() || out_kept.is_null())) || out_count.is_null() {
            return status::NULL_ARGUMENT;
        }
        let dets = slice(dets, count * DET_RECORD_FIELDS);
        let rect = |i: u32| -> [f64; 4] {
            let o = i as usize * DET_RECORD_FIELDS;
            [dets[o], dets[o + 1], dets[o + 2], dets[o + 3]]
        };
        let score = |i: u32| dets[i as usize * DET_RECORD_FIELDS + 4];
        let class = |i: u32| dets[i as usize * DET_RECORD_FIELDS + 5] as i64;
        let mut order: Vec<u32> = (0..count as u32).collect();
        sort(&mut order, &mut |a, b| compare_f64(score(b), score(a)));
        let kept_out = slice_mut(out_kept, count);
        let mut kept = 0usize;
        for &candidate in &order {
            let cr = rect(candidate);
            let group = nms_group(class(candidate));
            let suppressed = kept_out[..kept].iter().any(|&k| {
                nms_group(class(k)) == group && ocr_iou(&rect(k), &cr) >= iou_threshold
            });
            if !suppressed {
                kept_out[kept] = candidate;
                kept += 1;
            }
        }
        *out_count = kept;
        status::OK
    })
}

/// `buildPageDetections` 的内外判定：对 [targets] 的每个框，中心是否落在 [bubbles] 任一框内
/// （闭区间）。两组都是每条 4 个 f64（ltrb）；`out_inside` 写 0 / 1。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocr_inside_bubbles(
    bubbles: *const f64,
    bubble_count: usize,
    targets: *const f64,
    target_count: usize,
    out_inside: *mut u8,
) -> i32 {
    guard(|| {
        if (bubble_count > 0 && bubbles.is_null())
            || (target_count > 0 && (targets.is_null() || out_inside.is_null()))
        {
            return status::NULL_ARGUMENT;
        }
        let bubbles = slice(bubbles, bubble_count * 4);
        let targets = slice(targets, target_count * 4);
        let out = slice_mut(out_inside, target_count);
        for i in 0..target_count {
            let t = &targets[i * 4..i * 4 + 4];
            let (x, y) = ((t[0] + t[2]) / 2.0, (t[1] + t[3]) / 2.0);
            out[i] = bubbles
                .chunks_exact(4)
                .any(|b| x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3]) as u8;
        }
        status::OK
    })
}

// ---------------------------------------------------------------------------
// 分格：NMS + 分行排序（`orderPanelRects`）。
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
struct Panel {
    l: f64,
    t: f64,
    r: f64,
    b: f64,
    score: f64,
    index: u32,
}

impl Panel {
    #[inline]
    fn width(&self) -> f64 {
        max_f64(0.0, self.r - self.l)
    }
    #[inline]
    fn height(&self) -> f64 {
        max_f64(0.0, self.b - self.t)
    }
    #[inline]
    fn area(&self) -> f64 {
        self.width() * self.height()
    }
    #[inline]
    fn center_x(&self) -> f64 {
        (self.l + self.r) / 2.0
    }
    #[inline]
    fn center_y(&self) -> f64 {
        (self.t + self.b) / 2.0
    }
    /// `PanelRect.iou`（没有 `inter <= 0` 的提前返回）。
    #[inline]
    fn iou(&self, o: &Panel) -> f64 {
        let ow = max_f64(0.0, min_f64(self.r, o.r) - max_f64(self.l, o.l));
        let oh = max_f64(0.0, min_f64(self.b, o.b) - max_f64(self.t, o.t));
        let inter = ow * oh;
        let union = self.area() + o.area() - inter;
        if union <= 0.0 {
            0.0
        } else {
            inter / union
        }
    }
}

fn order_panels(rects: &[f64], iou_threshold: f64, rtl: bool) -> Vec<u32> {
    let mut candidates: Vec<Panel> = rects
        .chunks_exact(5)
        .enumerate()
        .map(|(i, r)| Panel {
            l: clamp_f64(r[0], 0.0, 1.0),
            t: clamp_f64(r[1], 0.0, 1.0),
            r: clamp_f64(r[2], 0.0, 1.0),
            b: clamp_f64(r[3], 0.0, 1.0),
            score: r[4],
            index: i as u32,
        })
        .filter(|p| p.area() > 0.0)
        .collect();
    sort(&mut candidates, &mut |a, b| compare_f64(b.score, a.score));
    let mut kept: Vec<Panel> = Vec::new();
    for c in candidates {
        if kept.iter().any(|e| e.iou(&c) >= iou_threshold) {
            continue;
        }
        kept.push(c);
    }
    sort(&mut kept, &mut |a, b| compare_f64(a.center_y(), b.center_y()));
    let mut rows: Vec<Vec<Panel>> = Vec::new();
    for panel in kept {
        let mut target: Option<usize> = None;
        for (ri, row) in rows.iter().enumerate() {
            let mut sum = row[0].center_y();
            for item in &row[1..] {
                sum += item.center_y();
            }
            let row_y = sum / row.len() as f64;
            let mut tallest = row[0].height();
            for item in &row[1..] {
                tallest = max_f64(tallest, item.height());
            }
            let tolerance = max_f64(0.035, max_f64(panel.height(), tallest) * 0.5);
            if (row_y - panel.center_y()).abs() <= tolerance {
                target = Some(ri);
                break;
            }
        }
        match target {
            Some(ri) => rows[ri].push(panel),
            None => rows.push(vec![panel]),
        }
    }
    let centers: Vec<f64> = rows
        .iter()
        .map(|row| {
            let mut sum = row[0].center_y();
            for item in &row[1..] {
                sum += item.center_y();
            }
            sum / row.len() as f64
        })
        .collect();
    let mut row_order: Vec<usize> = (0..rows.len()).collect();
    sort(&mut row_order, &mut |a, b| compare_f64(centers[a], centers[b]));
    let mut out = Vec::new();
    for ri in row_order {
        let row = &mut rows[ri];
        sort(row, &mut |a, b| {
            if rtl {
                compare_f64(b.center_x(), a.center_x())
            } else {
                compare_f64(a.center_x(), b.center_x())
            }
        });
        out.extend(row.iter().map(|p| p.index));
    }
    out
}

/// `orderPanelRects`：输入每条 5 个 f64（`left, top, right, bottom, score`，未夹取），夹进
/// [0, 1]、去零面积、按分数贪心 NMS、按中心 y 分行、行内按阅读方向排序。`out_order` 按输出
/// 顺序写输入下标（Dart 侧取 `input[i].clamp()`），`out_count` 写个数。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`out_order` 可写 `count` 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_ocr_order_panels(
    rects: *const f64,
    count: usize,
    iou_threshold: f64,
    rtl: i32,
    out_order: *mut u32,
    out_count: *mut usize,
) -> i32 {
    guard(|| {
        if (count > 0 && (rects.is_null() || out_order.is_null())) || out_count.is_null() {
            return status::NULL_ARGUMENT;
        }
        let order = order_panels(slice(rects, count * 5), iou_threshold, rtl != 0);
        slice_mut(out_order, count)[..order.len()].copy_from_slice(&order);
        *out_count = order.len();
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctc_merges_repeats_and_drops_blank() {
        // 帧 argmax：1 1 0 1 2 2 → runs (1,0..2) (1,3..4) (2,4..6)。
        let ids = [1usize, 1, 0, 1, 2, 2];
        let v = 3usize;
        let mut logits = vec![0f32; ids.len() * v];
        for (t, &id) in ids.iter().enumerate() {
            logits[t * v + id] = 1.0;
        }
        let mut out = vec![0f64; ids.len() * CTC_RECORD_FIELDS];
        let mut n = 0usize;
        let code = unsafe {
            ffc_ocr_ctc_greedy(
                logits.as_ptr(),
                logits.len(),
                ids.len() as u32,
                v as u32,
                1,
                out.as_mut_ptr(),
                out.len(),
                &mut n,
            )
        };
        assert_eq!(code, status::OK);
        assert_eq!(n, 3);
        let runs: Vec<(f64, f64, f64)> = (0..n)
            .map(|i| (out[i * 5], out[i * 5 + 1], out[i * 5 + 2]))
            .collect();
        assert_eq!(runs, vec![(1.0, 0.0, 2.0), (1.0, 3.0, 4.0), (2.0, 4.0, 6.0)]);
        // 概率行（one-hot）：置信度 1。
        assert_eq!(out[3], 1.0);
        assert_eq!(out[4], 1.0);
    }

    #[test]
    fn panels_split_into_rows_in_reading_order() {
        let rects = [
            0.0, 0.0, 0.4, 0.3, 0.9, // 上左
            0.6, 0.0, 1.0, 0.3, 0.8, // 上右
            0.0, 0.5, 1.0, 0.9, 0.7, // 下
        ];
        assert_eq!(order_panels(&rects, 0.5, true), vec![1, 0, 2]);
        assert_eq!(order_panels(&rects, 0.5, false), vec![0, 1, 2]);
    }
}
