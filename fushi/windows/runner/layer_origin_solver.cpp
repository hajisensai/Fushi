#include "layer_origin_solver.h"

#include <vector>

// 像素判据的**唯一真相源**：纯函数 + native ctest 合成夹具
// （`fushi_layer_origin_pixels_test`）。本文件只负责抓帧这一段 Win32。
#include "../../../native/galgame_hook/include/layer_origin_pixels.h"

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
    // **不能带 CAPTUREBLT**：它的作用就是「把叠在上面的分层窗口一并拍进来」，而
    // 我们自己那张 HWND_TOPMOST 的查词卡正好就贴在词的上方。BUG-2098 ① 又把求解门
    // 从「游戏在前台」放宽成「本进程为本游戏开的查词卡在前台也算」——两处改动叠在
    // 一起，就是拿自家 UI 的墨迹去解游戏的层原点。这里要的是游戏自己的像素。
    if (BitBlt(memory, 0, 0, width, height, screen, origin.x, origin.y,
               SRCCOPY)) {
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

LayerOriginSolveResult SolveLookupLayerOrigin(
    HWND game, int32_t layer_left, int32_t layer_top, int32_t layer_right,
    int32_t layer_bottom, uint32_t design_w, uint32_t design_h,
    uint32_t glyph_count) {
  LayerOriginSolveResult out;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> pixels;
  if (!CaptureClientBgra(game, &width, &height, &pixels)) {
    out.reason = "client_capture_failed";
    return out;
  }
  const fushi_voice_hook::LayerOriginPixelSolve solved =
      fushi_voice_hook::SolveLayerOriginFromBgra(
          pixels.data(), width, height, layer_left, layer_top, layer_right,
          layer_bottom, design_w, design_h, glyph_count);
  out.ok = solved.ok;
  out.origin_x = solved.origin_x;
  out.origin_y = solved.origin_y;
  out.reason = solved.reason;
  out.measured_left = solved.measured_left;
  out.measured_top = solved.measured_top;
  out.measured_right = solved.measured_right;
  out.measured_bottom = solved.measured_bottom;
  out.candidate_count = solved.candidate_count;
  return out;
}

}  // namespace fushi
