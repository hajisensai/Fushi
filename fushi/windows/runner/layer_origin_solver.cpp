#include "layer_origin_solver.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace fushi {
namespace {

// 一条候选墨迹带：连续若干行里有足够多的高亮像素。
struct InkBand {
  int top = 0;
  int bottom = 0;
  int left = 0;
  int right = 0;
  int64_t weight = 0;  // 带内高亮像素总数，用来在同宽候选里挑最实的那条
};

// 抓 |game| 客户区一帧到 BGRA。返回 false = 抓不到（窗口没了 / DC 失败 / 尺寸非法）。
bool CaptureClientBgra(HWND game, int* out_width, int* out_height,
                       std::vector<uint8_t>* out_pixels) {
  if (game == nullptr || !IsWindow(game) || out_width == nullptr ||
      out_height == nullptr || out_pixels == nullptr) {
    return false;
  }
  RECT client{};
  if (!GetClientRect(game, &client)) return false;
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
    return false;
  }
  POINT origin{0, 0};
  if (!ClientToScreen(game, &origin)) return false;

  HDC screen = GetDC(nullptr);
  if (screen == nullptr) return false;
  HDC memory = CreateCompatibleDC(screen);
  if (memory == nullptr) {
    ReleaseDC(nullptr, screen);
    return false;
  }
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  // 负高度 = 自上而下，行序与我们的索引一致。
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(memory, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (bitmap != nullptr && bits != nullptr) {
    HGDIOBJ previous = SelectObject(memory, bitmap);
    if (BitBlt(memory, 0, 0, width, height, screen, origin.x, origin.y,
               SRCCOPY | CAPTUREBLT)) {
      out_pixels->assign(static_cast<const uint8_t*>(bits),
                         static_cast<const uint8_t*>(bits) +
                             static_cast<size_t>(width) * height * 4u);
      *out_width = width;
      *out_height = height;
      ok = true;
    }
    SelectObject(memory, previous);
  }
  if (bitmap != nullptr) DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  return ok;
}

}  // namespace

LayerOriginSolveResult SolveLookupLayerOrigin(HWND game, int32_t layer_left,
                                              int32_t layer_top,
                                              int32_t layer_right,
                                              int32_t layer_bottom,
                                              uint32_t design_w,
                                              uint32_t design_h) {
  LayerOriginSolveResult out;
  if (design_w == 0u || design_h == 0u || layer_right <= layer_left ||
      layer_bottom <= layer_top) {
    out.reason = "invalid_layer_bounds";
    return out;
  }
  int width = 0, height = 0;
  std::vector<uint8_t> pixels;
  if (!CaptureClientBgra(game, &width, &height, &pixels)) {
    out.reason = "client_capture_failed";
    return out;
  }

  const double sx =
      static_cast<double>(width) / static_cast<double>(design_w);
  const double sy =
      static_cast<double>(height) / static_cast<double>(design_h);
  const double predicted_w = (layer_right - layer_left) * sx;
  const double predicted_h = (layer_bottom - layer_top) * sy;
  if (!(predicted_w >= 8.0) || !(predicted_h >= 6.0)) {
    out.reason = "predicted_line_too_small";
    return out;
  }

  // 正文是亮字压在暗背景上。阈值取「全画面亮度均值 + 3 倍标准差」并夹在 [150,245]：
  // 固定阈值会在明亮场景里把背景整片吃进来，纯 Otsu 又会被大面积高光带偏。
  const size_t count = static_cast<size_t>(width) * height;
  double sum = 0.0, sum_sq = 0.0;
  std::vector<uint8_t> luma(count, 0);
  for (size_t i = 0; i < count; ++i) {
    const uint8_t b = pixels[i * 4u + 0u];
    const uint8_t g = pixels[i * 4u + 1u];
    const uint8_t r = pixels[i * 4u + 2u];
    const int y = (r * 77 + g * 151 + b * 28) >> 8;
    luma[i] = static_cast<uint8_t>(y);
    sum += y;
    sum_sq += static_cast<double>(y) * y;
  }
  const double mean = sum / static_cast<double>(count);
  const double variance =
      std::max(0.0, sum_sq / static_cast<double>(count) - mean * mean);
  const double threshold =
      std::min(245.0, std::max(150.0, mean + 3.0 * std::sqrt(variance)));

  // 逐行统计高亮像素；连续的高亮行合成一条候选带。
  std::vector<int> row_counts(static_cast<size_t>(height), 0);
  for (int y = 0; y < height; ++y) {
    int hits = 0;
    const uint8_t* row = luma.data() + static_cast<size_t>(y) * width;
    for (int x = 0; x < width; ++x) {
      if (row[x] > threshold) ++hits;
    }
    row_counts[static_cast<size_t>(y)] = hits;
  }

  std::vector<InkBand> bands;
  const int kMinRowHits = 4;
  int run_start = -1;
  for (int y = 0; y <= height; ++y) {
    const bool inside =
        y < height && row_counts[static_cast<size_t>(y)] >= kMinRowHits;
    if (inside && run_start < 0) {
      run_start = y;
    } else if (!inside && run_start >= 0) {
      InkBand band;
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

  for (InkBand& band : bands) {
    int left = width, right = -1;
    int64_t weight = 0;
    for (int y = band.top; y <= band.bottom; ++y) {
      const uint8_t* row = luma.data() + static_cast<size_t>(y) * width;
      for (int x = 0; x < width; ++x) {
        if (row[x] <= threshold) continue;
        ++weight;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
    band.left = left;
    band.right = right;
    band.weight = weight;
  }

  // 在宽度对得上的候选里挑墨迹最实的那条。宽度是本方法唯一的强判据：注入侧给的是
  // **这一行**的层空间宽度，缩放后就该等于屏幕上这一行的墨迹宽度（差的只是首尾字形的
  // 边距，占比很小）。
  const InkBand* best = nullptr;
  for (const InkBand& band : bands) {
    if (band.right < band.left) continue;
    const double measured_w = band.right - band.left + 1;
    const double ratio = measured_w / predicted_w;
    if (ratio < 0.80 || ratio > 1.06) continue;
    if (best == nullptr || band.weight > best->weight) best = &band;
  }
  if (best == nullptr) {
    out.reason = "no_band_matched_predicted_width";
    return out;
  }

  // origin = 实测(逻辑) - 层坐标。两轴各自求解；用 sx/sy 反缩放回设计空间。
  const double origin_x = static_cast<double>(best->left) / sx - layer_left;
  const double origin_y = static_cast<double>(best->top) / sy - layer_top;
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

}  // namespace fushi
