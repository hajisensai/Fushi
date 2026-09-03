#include "global_lookup_shadow.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {

constexpr wchar_t kShadowClassName[] = L"FushiLookupShadowWindow";

// 投影形状参数（CSS px，运行时按锚窗 DPI 换算成物理 px）。
// 双瓣近似 Win11 flyout 阴影：
// - ambient：贴边紧瓣，d→0 处最深，负责"落地感"并在视觉上柔化 region 锯齿边；
// - key：向下偏移的大瓣，负责"浮起感"。
constexpr double kMarginCss = 30.0;        // 投影窗四周超出锚窗的边距
constexpr double kAmbientSigmaCss = 7.0;   // ambient 高斯宽度
constexpr double kAmbientAlpha = 0.26;     // ambient 峰值不透明度
constexpr double kKeySigmaCss = 16.0;      // key 高斯宽度
constexpr double kKeyAlpha = 0.20;         // key 峰值不透明度
constexpr double kKeyOffsetYCss = 4.0;     // key 瓣向下偏移

// 圆角矩形有符号距离（外正内负）。[rect]=l,t,w,h；[r] 圆角半径。
double RoundedRectDistance(double px, double py,
                           const std::array<double, 4>& rect, double r) {
  const double cx = rect[0] + rect[2] / 2.0;
  const double cy = rect[1] + rect[3] / 2.0;
  const double bx = rect[2] / 2.0 - r;
  const double by = rect[3] / 2.0 - r;
  const double qx = std::abs(px - cx) - (bx > 0 ? bx : 0);
  const double qy = std::abs(py - cy) - (by > 0 ? by : 0);
  const double ax = qx > 0 ? qx : 0;
  const double ay = qy > 0 ? qy : 0;
  const double outside = std::sqrt(ax * ax + ay * ay);
  const double inside = std::min(std::max(qx, qy), 0.0);
  return outside + inside - r;
}

// 返回 sample_y 这一物理像素扫描线上，圆角矩形内部覆盖的 [x0, x1)。
//
// Paint 的热路径只需要在卡片外围的阴影带执行 RoundedRectDistance/exp；卡片
// 内部原本逐像素算完 d<=0 后直接 continue，既不产出任何像素，又会让大卡在
// Debug 构建里付出数百万次 sqrt。按扫描线一次求出内部连续区间后，可以整段
// 跳过；punch-out 也可复用同一区间做连续清零。像素中心约定与旧实现完全一致
// （px + 0.5 / py + 0.5），圆角外的四个角仍会进入阴影计算。
bool RoundedRectInteriorSpan(double sample_y,
                             const std::array<double, 4>& rect, double radius,
                             int limit_width, int* x0, int* x1) {
  if (x0 == nullptr || x1 == nullptr || limit_width <= 0 || rect[2] <= 0 ||
      rect[3] <= 0) {
    return false;
  }
  const double half_w = rect[2] / 2.0;
  const double half_h = rect[3] / 2.0;
  // 与 RoundedRectDistance 的旧语义同源：不能把 r 钳到半宽/半高。虽然正常
  // popup 远大于 2r，极窄的防御性输入在旧公式里会退化成以中心为基准的胶囊/
  // 圆；这里必须跳过完全相同的像素集合，不能借性能改动悄悄改变轮廓。
  const double r = std::max(radius, 0.0);
  const double cx = rect[0] + half_w;
  const double cy = rect[1] + half_h;
  const double bx = std::max(half_w - r, 0.0);
  const double by = std::max(half_h - r, 0.0);
  const double dy = std::max(std::abs(sample_y - cy) - by, 0.0);
  if (dy > r) {
    return false;
  }
  const double corner_dx =
      std::sqrt(std::max(r * r - dy * dy, 0.0));
  const double left = cx - bx - corner_dx;
  const double right = cx + bx + corner_dx;
  // 旧循环判断的是像素中心是否落在闭区间 [left, right]。
  const int first = static_cast<int>(std::ceil(left - 0.5));
  const int last_exclusive =
      static_cast<int>(std::floor(right - 0.5)) + 1;
  *x0 = std::clamp(first, 0, limit_width);
  *x1 = std::clamp(last_exclusive, 0, limit_width);
  return *x0 < *x1;
}

}  // namespace

LookupShadowWindow::~LookupShadowWindow() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  // 类注册进程级共享（瞬态查词窗 + 剪贴板面板各持一个投影窗），不在此注销，
  // 与 GlobalLookupWindow 的窗口类同一纪律：进程退出时由 OS 回收。
}

LRESULT CALLBACK LookupShadowWindow::WndProc(HWND hwnd, UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept {
  // 纯展示窗：WS_EX_TRANSPARENT 已保证鼠标穿透，这里不需要任何自定义行为。
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void LookupShadowWindow::EnsureWindow() {
  if (hwnd_ != nullptr && IsWindow(hwnd_)) {
    return;
  }
  hwnd_ = nullptr;
  static bool s_class_registered = false;
  if (!s_class_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = LookupShadowWindow::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = kShadowClassName;
    RegisterClassExW(&wc);
    s_class_registered = true;
  }
  // WS_EX_TRANSPARENT：命中测试永远穿透（影子环绝不吃底下应用的点击）；
  // WS_EX_NOACTIVATE + WS_DISABLED：绝不参与激活/焦点；
  // WS_EX_TOOLWINDOW：无任务栏项/Alt-Tab 项；
  // WS_EX_LAYERED：UpdateLayeredWindow 逐像素 alpha 的前提。
  // 不带 WS_EX_TOPMOST：Z 序全程由 Sync 里 insertAfter=anchor 钉在锚窗正下，
  // 锚窗在哪个 Z 带、影子就跟到哪个 Z 带（面板未 pin 时在非置顶带同样成立）。
  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      kShadowClassName, L"", WS_POPUP | WS_DISABLED, 0, 0, 1, 1, nullptr,
      nullptr, GetModuleHandle(nullptr), nullptr);
  if (hwnd_ != nullptr && block_capture_) {
    SetWindowDisplayAffinity(hwnd_, WDA_EXCLUDEFROMCAPTURE);
  }
  // 强制下次 Sync 重画（新窗口还没有内容）。
  last_w_ = 0;
  last_h_ = 0;
  last_cards_px_.clear();
}

void LookupShadowWindow::SetBlockCapture(bool block) {
  block_capture_ = block;
  if (hwnd_ != nullptr && IsWindow(hwnd_)) {
    SetWindowDisplayAffinity(hwnd_,
                             block ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
  }
}

void LookupShadowWindow::Hide() {
  if (hwnd_ != nullptr && IsWindow(hwnd_)) {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

void LookupShadowWindow::Sync(
    HWND anchor, bool show,
    const std::vector<std::array<double, 4>>& cards_css, int radius_css,
    bool defer_repaint) {
  if (anchor == nullptr || !IsWindow(anchor) || !show) {
    Hide();
    return;
  }
  RECT wr{};
  if (!GetWindowRect(anchor, &wr)) {
    Hide();
    return;
  }
  const int anchor_w = wr.right - wr.left;
  const int anchor_h = wr.bottom - wr.top;
  if (anchor_w <= 0 || anchor_h <= 0) {
    Hide();
    return;
  }
  UINT dpi = GetDpiForWindow(anchor);
  if (dpi == 0) {
    dpi = 96;
  }
  const double dpr = static_cast<double>(dpi) / 96.0;
  const int margin = static_cast<int>(std::lround(kMarginCss * dpr));
  const int radius_px = static_cast<int>(std::lround(radius_css * dpr));

  // 卡矩形 CSS px → 投影窗本地物理 px（投影窗原点 = 锚窗原点 − margin）。
  std::vector<std::array<double, 4>> cards_px;
  if (cards_css.empty()) {
    cards_px.push_back({static_cast<double>(margin),
                        static_cast<double>(margin),
                        static_cast<double>(anchor_w),
                        static_cast<double>(anchor_h)});
  } else {
    cards_px.reserve(cards_css.size());
    for (const std::array<double, 4>& r : cards_css) {
      if (r[2] <= 0 || r[3] <= 0) {
        continue;
      }
      cards_px.push_back({r[0] * dpr + margin, r[1] * dpr + margin,
                          r[2] * dpr, r[3] * dpr});
    }
    if (cards_px.empty()) {
      Hide();
      return;
    }
  }

  const int win_w = anchor_w + 2 * margin;
  const int win_h = anchor_h + 2 * margin;
  const int win_x = wr.left - margin;
  const int win_y = wr.top - margin;

  EnsureWindow();
  if (hwnd_ == nullptr) {
    return;
  }

  const bool dirty = win_w != last_w_ || win_h != last_h_ ||
                     radius_px != last_radius_px_ ||
                     cards_px != last_cards_px_;
  if (dirty) {
    if (defer_repaint) {
      // 模态 resize 循环中每帧重画会拖慢拖拽：先藏起来，
      // WM_EXITSIZEMOVE 后的下一次 Sync 再恢复。
      Hide();
      return;
    }
    if (!Paint(win_x, win_y, win_w, win_h, cards_px, radius_px, dpr)) {
      Hide();
      return;
    }
    last_w_ = win_w;
    last_h_ = win_h;
    last_radius_px_ = radius_px;
    last_cards_px_ = cards_px;
  }
  // 纯移动（内容没变）：layered 窗口内容随窗而动，SetWindowPos 免重画；
  // 同一调用顺带把 Z 序钉回锚窗正下方并确保可见。SWP_NOACTIVATE：绝不抢焦点。
  SetWindowPos(hwnd_, anchor, win_x, win_y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

bool LookupShadowWindow::Paint(
    int x, int y, int width, int height,
    const std::vector<std::array<double, 4>>& cards_px, int radius_px,
    double dpr) {
  if (width <= 0 || height <= 0) {
    return false;
  }
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC screen_dc = GetDC(nullptr);
  HBITMAP dib =
      CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib == nullptr || bits == nullptr) {
    if (dib != nullptr) {
      DeleteObject(dib);
    }
    ReleaseDC(nullptr, screen_dc);
    return false;
  }
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  HGDIOBJ old_bitmap = SelectObject(mem_dc, dib);

  const double sigma_a = kAmbientSigmaCss * dpr;
  const double sigma_k = kKeySigmaCss * dpr;
  const double key_dy = kKeyOffsetYCss * dpr;
  // 高斯尾部按 margin 截断即可；margin(30css) > 2σk(16css) 有足够余量。
  auto* pixels = static_cast<uint32_t*>(bits);
  std::fill(pixels, pixels + static_cast<size_t>(width) * height, 0u);

  for (const std::array<double, 4>& card : cards_px) {
    // 只扫本卡影响的外围阴影带（卡矩形外扩 margin），级联多卡时避免整图 ×
    // 卡数。卡内本来就不画；按扫描线跳过内部连续区间，避免大卡逐像素执行
    // RoundedRectDistance/sqrt 后才 continue。
    const int margin_px =
        static_cast<int>(std::lround(kMarginCss * dpr));
    const int x0 = std::max(0, static_cast<int>(std::floor(card[0])) - margin_px);
    const int y0 = std::max(0, static_cast<int>(std::floor(card[1])) - margin_px);
    const int x1 = std::min(
        width, static_cast<int>(std::ceil(card[0] + card[2])) + margin_px);
    const int y1 = std::min(
        height, static_cast<int>(std::ceil(card[1] + card[3])) + margin_px);
    for (int py = y0; py < y1; ++py) {
      uint32_t* row = pixels + static_cast<size_t>(py) * width;
      int inside_x0 = 0;
      int inside_x1 = 0;
      const bool has_inside = RoundedRectInteriorSpan(
          py + 0.5, card, radius_px, width, &inside_x0, &inside_x1);
      const auto paint_range = [&](int range_x0, int range_x1) {
        for (int px = range_x0; px < range_x1; ++px) {
          const double fx = px + 0.5;
          const double fy = py + 0.5;
          const double d = RoundedRectDistance(fx, fy, card, radius_px);
          const double dk =
              RoundedRectDistance(fx, fy - key_dy, card, radius_px);
          const double ambient =
              kAmbientAlpha * std::exp(-(d * d) / (sigma_a * sigma_a));
          const double key =
              dk <= 0 ? kKeyAlpha
                      : kKeyAlpha * std::exp(-(dk * dk) / (sigma_k * sigma_k));
          const double alpha = 1.0 - (1.0 - ambient) * (1.0 - key);
          const uint32_t a = static_cast<uint32_t>(std::lround(
              std::clamp(alpha, 0.0, 1.0) * 255.0));
          if (a == 0) {
            continue;
          }
          // 多卡重叠区取较深者（max）——比相加更接近真实阴影且不会过曝。
          const uint32_t existing = row[px] >> 24;
          if (a > existing) {
            // 纯黑影：预乘 ARGB = (a, 0, 0, 0)。
            row[px] = a << 24;
          }
        }
      };
      if (!has_inside) {
        paint_range(x0, x1);
        continue;
      }
      paint_range(x0, std::min(x1, inside_x0));
      paint_range(std::max(x0, inside_x1), x1);
    }
  }
  // punch-out：任何卡矩形内部一律 alpha=0。面板可开整窗 LWA_ALPHA 半透明，
  // 不打洞的话黑影会从半透明卡片底下透出来把内容压暗；级联相邻卡的影子落进
  // 另一张卡的矩形同理清掉（那块像素本来也被不透明卡片盖住，防御性一致）。
  for (const std::array<double, 4>& card : cards_px) {
    const int x0 = std::max(0, static_cast<int>(std::floor(card[0])));
    const int y0 = std::max(0, static_cast<int>(std::floor(card[1])));
    const int x1 = std::min(width, static_cast<int>(std::ceil(card[0] + card[2])));
    const int y1 = std::min(height, static_cast<int>(std::ceil(card[1] + card[3])));
    for (int py = y0; py < y1; ++py) {
      uint32_t* row = pixels + static_cast<size_t>(py) * width;
      int inside_x0 = 0;
      int inside_x1 = 0;
      if (RoundedRectInteriorSpan(py + 0.5, card, radius_px, width,
                                  &inside_x0, &inside_x1)) {
        // 连续写零仍是 O(card area) 的内存带宽，但不再为每个像素做
        // RoundedRectDistance/sqrt/branch。
        const int clear_x0 = std::max(x0, inside_x0);
        const int clear_x1 = std::min(x1, inside_x1);
        if (clear_x0 < clear_x1) {
          std::fill(row + clear_x0, row + clear_x1, 0u);
        }
      }
    }
  }

  POINT dst = {x, y};
  SIZE size = {width, height};
  POINT src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  const BOOL ok = UpdateLayeredWindow(hwnd_, screen_dc, &dst, &size, mem_dc,
                                      &src, 0, &blend, ULW_ALPHA);

  SelectObject(mem_dc, old_bitmap);
  DeleteDC(mem_dc);
  DeleteObject(dib);
  ReleaseDC(nullptr, screen_dc);
  return ok != FALSE;
}
