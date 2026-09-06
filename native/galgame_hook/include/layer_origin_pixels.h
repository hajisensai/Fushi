// BUG-2136 引擎层原点：**纯像素求解**。不碰 Win32，可被 native ctest 直接喂合成位图。
//
// 为什么单独一个头：抓帧（BitBlt/GDI）与像素分析原本焊死在
// `fushi/windows/runner/layer_origin_solver.cpp` 的同一个函数里，签名是
// `SolveLookupLayerOrigin(HWND game, ...)` —— 结构上不可测，而它承载的正是「免手动
// 校准」的全部算法。本仓其余六个 native gate 都遵循「纯函数 + 合成夹具」，这里补齐。
//
// 判据本身：注入侧发布**本行**在层空间的包围盒与设计分辨率，宿主量出同一行在屏幕上的
// 墨迹框，两者之差就是 origin（client = (layer + origin) * client / design）。
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace fushi_voice_hook {

struct LayerOriginPixelSolve {
  bool ok = false;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  // 失败原因：静态字符串，测试逐字比对。成功时为空串。
  const char* reason = "";
  int32_t measured_left = 0;
  int32_t measured_top = 0;
  int32_t measured_right = 0;
  int32_t measured_bottom = 0;
  // 宽度对得上的候选带数。>1 时必须走消歧，消歧不掉就整轮拒绝。
  int32_t candidate_count = 0;
};

namespace layer_origin_detail {

// 一条候选墨迹带：连续若干行里有足够多的高亮像素。
struct InkBand {
  int32_t top = 0;
  int32_t bottom = 0;
  int32_t left = 0;
  int32_t right = 0;
  int64_t weight = 0;  // 带内高亮像素总数
  int32_t runs = 0;    // 列投影上的连通墨迹段数，用来跟 glyph_count 对账
};

}  // namespace layer_origin_detail

// |bgra| 是自上而下的 32bpp 客户区像素，长度必须 >= width*height*4。
// |glyph_count| 是注入侧一并发过来的本行字形数（0 = 不可用）。
inline LayerOriginPixelSolve SolveLayerOriginFromBgra(
    const uint8_t* bgra, int32_t width, int32_t height, int32_t layer_left,
    int32_t layer_top, int32_t layer_right, int32_t layer_bottom,
    uint32_t design_w, uint32_t design_h, uint32_t glyph_count) {
  LayerOriginPixelSolve out;
  if (bgra == nullptr || width <= 0 || height <= 0) {
    out.reason = "invalid_pixels";
    return out;
  }
  if (design_w == 0u || design_h == 0u || layer_right <= layer_left ||
      layer_bottom <= layer_top) {
    out.reason = "invalid_layer_bounds";
    return out;
  }

  const double sx = static_cast<double>(width) / static_cast<double>(design_w);
  const double sy = static_cast<double>(height) / static_cast<double>(design_h);
  const double predicted_w = (layer_right - layer_left) * sx;
  const double predicted_h = (layer_bottom - layer_top) * sy;
  if (!(predicted_w >= 8.0) || !(predicted_h >= 6.0)) {
    out.reason = "predicted_line_too_small";
    return out;
  }

  // 正文是亮字压在暗背景上。阈值取「全画面亮度均值 + 3 倍标准差」并夹在 [150,245]：
  // 固定阈值会在明亮场景里把背景整片吃进来，纯 Otsu 又会被大面积高光带偏。
  const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
  double sum = 0.0;
  double sum_sq = 0.0;
  std::vector<uint8_t> luma(count, 0);
  for (size_t i = 0; i < count; ++i) {
    const uint8_t b = bgra[i * 4u + 0u];
    const uint8_t g = bgra[i * 4u + 1u];
    const uint8_t r = bgra[i * 4u + 2u];
    const int y = (r * 77 + g * 151 + b * 28) >> 8;
    luma[i] = static_cast<uint8_t>(y);
    sum += y;
    sum_sq += static_cast<double>(y) * y;
  }
  const double mean = sum / static_cast<double>(count);
  double variance = sum_sq / static_cast<double>(count) - mean * mean;
  if (variance < 0.0) variance = 0.0;
  double threshold = mean + 3.0 * std::sqrt(variance);
  if (threshold < 150.0) threshold = 150.0;
  if (threshold > 245.0) threshold = 245.0;

  // 逐行统计高亮像素；连续的高亮行合成一条候选带。
  std::vector<int32_t> row_counts(static_cast<size_t>(height), 0);
  for (int32_t y = 0; y < height; ++y) {
    int32_t hits = 0;
    const uint8_t* row = luma.data() + static_cast<size_t>(y) * width;
    for (int32_t x = 0; x < width; ++x) {
      if (row[x] > threshold) ++hits;
    }
    row_counts[static_cast<size_t>(y)] = hits;
  }

  std::vector<layer_origin_detail::InkBand> bands;
  const int32_t kMinRowHits = 4;
  int32_t run_start = -1;
  for (int32_t y = 0; y <= height; ++y) {
    const bool inside =
        y < height && row_counts[static_cast<size_t>(y)] >= kMinRowHits;
    if (inside && run_start < 0) {
      run_start = y;
    } else if (!inside && run_start >= 0) {
      layer_origin_detail::InkBand band;
      band.top = run_start;
      band.bottom = y - 1;
      run_start = -1;
      // 带高度必须和预测行高同量级，否则那是背景高光而不是一行字。
      const double band_h = band.bottom - band.top + 1;
      if (band_h >= predicted_h * 0.45 && band_h <= predicted_h * 2.2) {
        bands.push_back(band);
      }
    }
  }
  if (bands.empty()) {
    out.reason = "no_ink_band";
    return out;
  }

  std::vector<uint8_t> column_ink(static_cast<size_t>(width), 0);
  for (layer_origin_detail::InkBand& band : bands) {
    int32_t left = width;
    int32_t right = -1;
    int64_t weight = 0;
    for (size_t i = 0; i < column_ink.size(); ++i) column_ink[i] = 0;
    for (int32_t y = band.top; y <= band.bottom; ++y) {
      const uint8_t* row = luma.data() + static_cast<size_t>(y) * width;
      for (int32_t x = 0; x < width; ++x) {
        if (row[x] <= threshold) continue;
        ++weight;
        column_ink[static_cast<size_t>(x)] = 1;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
    band.left = left;
    band.right = right;
    band.weight = weight;
    // 列投影上的连通段数——同宽候选之间的消歧判据（见下）。
    int32_t runs = 0;
    bool in_run = false;
    for (int32_t x = 0; x < width; ++x) {
      const bool ink = column_ink[static_cast<size_t>(x)] != 0;
      if (ink && !in_run) ++runs;
      in_run = ink;
    }
    band.runs = runs;
  }

  // 宽度是本方法的强判据：注入侧给的是**这一行**的层空间宽度，缩放后就该等于屏幕上
  // 这一行的墨迹宽度（差的只是首尾字形边距，占比很小）。
  std::vector<const layer_origin_detail::InkBand*> matched;
  for (const layer_origin_detail::InkBand& band : bands) {
    if (band.right < band.left) continue;
    const double measured_w = band.right - band.left + 1;
    const double ratio = measured_w / predicted_w;
    if (ratio < 0.80 || ratio > 1.06) continue;
    matched.push_back(&band);
  }
  out.candidate_count = static_cast<int32_t>(matched.size());
  if (matched.empty()) {
    out.reason = "no_band_matched_predicted_width";
    return out;
  }

  const layer_origin_detail::InkBand* best = matched.front();
  if (matched.size() > 1u) {
    // **多解绝不 fail-open**。宽度比值窗 [0.80, 1.06] 有 26% 宽，而 NVL 堆叠正文
    // （历史行淡出留屏）里多行同宽是常态：静默取 weight 最大者一旦选错，叠加
    // 「一个客户区尺寸只解一次」就会**锁死整局**——错误的 origin 被 publish，之后
    // 再也不会重解。
    //
    // 唯一允许的消歧是注入侧一并发过来的 glyph_count（此前跨 IPC 传了却没人用）：
    // 拿列投影的连通墨迹段数与它对账，取唯一最接近者。并列、或拿不到 glyph_count，
    // 就整轮拒绝——什么都不发布，注入侧照旧 fail-closed 退回贴合层，那是安全态。
    if (glyph_count == 0u) {
      out.reason = "ambiguous_ink_bands";
      return out;
    }
    int32_t best_delta = -1;
    int32_t tie = 0;
    for (const layer_origin_detail::InkBand* band : matched) {
      const int32_t glyphs = static_cast<int32_t>(glyph_count);
      const int32_t delta =
          band->runs > glyphs ? band->runs - glyphs : glyphs - band->runs;
      if (best_delta < 0 || delta < best_delta) {
        best_delta = delta;
        best = band;
        tie = 1;
      } else if (delta == best_delta) {
        ++tie;
      }
    }
    if (tie != 1) {
      out.reason = "ambiguous_ink_bands";
      return out;
    }
  }

  // origin = 实测(逻辑) - 层坐标。**用中点而不是左上角**：注入侧给的是字形**格子**的
  // 边界，屏幕上量到的是**墨迹**边界，两者差着首尾字形各自的边距。拿左边缘求解会把
  // 首字的左边距整个算进原点；拿中点则首尾边距一阶抵消。
  const double measured_center_x =
      (static_cast<double>(best->left) + best->right + 1.0) * 0.5;
  const double measured_center_y =
      (static_cast<double>(best->top) + best->bottom + 1.0) * 0.5;
  const double layer_center_x =
      (static_cast<double>(layer_left) + layer_right) * 0.5;
  const double layer_center_y =
      (static_cast<double>(layer_top) + layer_bottom) * 0.5;
  const double origin_x = measured_center_x / sx - layer_center_x;
  const double origin_y = measured_center_y / sy - layer_center_y;
  if (!std::isfinite(origin_x) || !std::isfinite(origin_y) ||
      origin_x < -static_cast<double>(design_w) ||
      origin_x > static_cast<double>(design_w) ||
      origin_y < -static_cast<double>(design_h) ||
      origin_y > static_cast<double>(design_h)) {
    out.reason = "origin_out_of_range";
    return out;
  }

  out.ok = true;
  out.origin_x = static_cast<int32_t>(std::lround(origin_x));
  out.origin_y = static_cast<int32_t>(std::lround(origin_y));
  out.measured_left = best->left;
  out.measured_top = best->top;
  out.measured_right = best->right;
  out.measured_bottom = best->bottom;
  return out;
}

}  // namespace fushi_voice_hook
