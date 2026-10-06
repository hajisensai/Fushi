// Render the real native menu into a memory DIB, without creating a window or
// sending input. A layered window passes alpha-zero pixels through before its
// ButtonAt handler can run, so geometry alone cannot prove a 48dp hit target.
#include <windows.h>
#include <commctrl.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <string>
#include <utility>
#include <vector>

// Keep the injection seam local to this test translation unit. The renderer
// and hit-test implementation below are the production implementation.
#define private public
#include "../floating_ball_window.h"
#undef private

namespace hit_region_test {
std::vector<uint32_t> pixels;
int width = 0;
int height = 0;
bool dpi_queried = false;
int presentations = 0;
bool presentation_contract_ok = true;

UINT MonitorDpi(HMONITOR) {
  dpi_queried = true;
  return 96;
}

BOOL WINAPI CaptureLayered(HWND hwnd, HDC, const POINT*, const SIZE* size,
                          HDC source, const POINT* origin, COLORREF,
                          const BLENDFUNCTION* blend, DWORD flags) {
  ++presentations;
  presentation_contract_ok &=
      hwnd == reinterpret_cast<HWND>(static_cast<uintptr_t>(1)) &&
      origin != nullptr && origin->x == 0 && origin->y == 0 &&
      blend != nullptr && blend->BlendOp == AC_SRC_OVER &&
      blend->BlendFlags == 0 && blend->SourceConstantAlpha == 255 &&
      blend->AlphaFormat == AC_SRC_ALPHA && flags == ULW_ALPHA;
  DIBSECTION section{};
  if (!GetObjectW(GetCurrentObject(source, OBJ_BITMAP),
                  static_cast<int>(sizeof(section)), &section) ||
      section.dsBm.bmBits == nullptr || size == nullptr) {
    return FALSE;
  }
  width = size->cx;
  height = size->cy;
  presentation_contract_ok &= section.dsBm.bmWidth == width &&
                              section.dsBm.bmHeight == height &&
                              section.dsBm.bmBitsPixel == 32 &&
                              std::abs(section.dsBmih.biHeight) == height;
  const auto* first = static_cast<const uint32_t*>(section.dsBm.bmBits);
  pixels.assign(first, first + width * height);
  return TRUE;
}

int Alpha(int x, int y) {
  if (x < 0 || y < 0 || x >= width || y >= height || pixels.empty()) return -1;
  return static_cast<int>((pixels[y * width + x] >> 24) & 255);
}

bool FullyTransparent() {
  return !pixels.empty() &&
         std::all_of(pixels.begin(), pixels.end(),
                     [](uint32_t pixel) { return (pixel >> 24) == 0; });
}

struct ScopedCom {
  const HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ~ScopedCom() {
    if (SUCCEEDED(result)) CoUninitialize();
  }
};
}  // namespace hit_region_test

// Only presentation and the unrelated Flutter monitor query are replaced.
// The target's private stub include path avoids a Flutter engine/build
// dependency. Any unexpected monitor query is still a test setup failure.
#define UpdateLayeredWindow hit_region_test::CaptureLayered
#define FlutterDesktopGetDpiForMonitor hit_region_test::MonitorDpi
#include "../floating_ball_window.cpp"
#undef FlutterDesktopGetDpiForMonitor
#undef UpdateLayeredWindow

int main() {
  const hit_region_test::ScopedCom com;
  if (FAILED(com.result)) {
    std::cerr << "test setup failed: CoInitializeEx=" << com.result << '\n';
    return 2;
  }
  int cases = 0;
  int failures = 0;
  const std::vector<std::pair<int, int>> axes = {
      {1, 0}, {-1, 0}, {0, 1}, {0, -1}};
  for (const double scale : {1.0, 1.5, 2.0}) {
    for (const bool eink : {false, true}) {
      FloatingBallWindow window;
      // Sentinel only satisfies RenderLayered's non-null precondition; the
      // presentation function is intercepted. Clear it before destruction.
      window.menu_hwnd_ = reinterpret_cast<HWND>(static_cast<uintptr_t>(1));
      window.menu_scale_ = scale;
      window.progress_ = 1;
      window.menu_ids_ = {"test"};
      const double center = 40 * scale;
      window.menu_centers_ = {{center, center}};
      window.menu_ball_cx_ = center;
      window.menu_ball_cy_ = center;
      window.menu_size_ = {static_cast<LONG>(80 * scale),
                           static_cast<LONG>(80 * scale)};
      window.config_.outline = eink ? 0xFF000000 : 0;
      window.config_.button_container = 0xFFFFFFFF;
      window.config_.on_button_container = 0xFF000000;
      hit_region_test::pixels.clear();
      const int before = hit_region_test::presentations;
      window.RenderMenu();
      const int center_x = static_cast<int>(center);
      const int center_y = static_cast<int>(center);
      const int edge_x = static_cast<int>(center + 23 * scale);
      const int center_hit = window.ButtonAt(center, center);
      const int edge_hit = window.ButtonAt(center + 23 * scale, center);
      const int center_alpha = hit_region_test::Alpha(center_x, center_y);
      const int edge_alpha = hit_region_test::Alpha(edge_x, center_y);
      bool edge_ok = true;
      bool outside_ok = true;
      for (const auto& direction : axes) {
        const double ex = center + direction.first * 23 * scale;
        const double ey = center + direction.second * 23 * scale;
        const double ox = center + direction.first * 25 * scale;
        const double oy = center + direction.second * 25 * scale;
        edge_ok &= window.ButtonAt(ex, ey) == 0 &&
                   hit_region_test::Alpha(static_cast<int>(ex),
                                           static_cast<int>(ey)) == 1;
        outside_ok &= window.ButtonAt(ox, oy) == -1 &&
                      hit_region_test::Alpha(static_cast<int>(ox),
                                              static_cast<int>(oy)) == 0;
      }
      outside_ok &= window.ButtonAt(0, 0) == -1 &&
                    hit_region_test::Alpha(0, 0) == 0;
      double cx, cy, radius, opacity;
      const bool visual_ok =
          window.ButtonCircle(0, &cx, &cy, &radius, &opacity) &&
          std::fabs(radius - 20 * scale) < 0.001 && center_alpha == 255;

      // Very early entry must not paint the invisible input pad ahead of the
      // hit-test's opacity threshold, even though the small face is fading in.
      window.progress_ = 0.001;
      window.RenderMenu();
      bool entry_ok = window.ButtonCircle(0, &cx, &cy, &radius, &opacity) &&
                      opacity > 0 && opacity < 0.05;
      for (const auto& direction : axes) {
        const int x = static_cast<int>(
            std::lround(cx + direction.first * radius * 1.15));
        const int y = static_cast<int>(
            std::lround(cy + direction.second * radius * 1.15));
        entry_ok &= window.ButtonAt(x, y) == -1 &&
                    hit_region_test::Alpha(x, y) == 0;
      }
      const double entry_opacity = opacity;

      // Re-rendering the same surface after collapse or an empty menu must
      // clear all stale input alpha, not just stop returning a button index.
      window.progress_ = 0;
      window.RenderMenu();
      const bool collapsed_ok = hit_region_test::FullyTransparent() &&
                                window.ButtonAt(center, center) == -1;
      window.progress_ = 1;
      window.menu_ids_.clear();
      window.menu_centers_.clear();
      window.RenderMenu();
      const bool empty_ok = hit_region_test::FullyTransparent() &&
                            window.ButtonAt(center, center) == -1;
      window.menu_hwnd_ = nullptr;
      ++cases;
      const bool setup_ok = center_hit == 0 && center_alpha > 0 &&
                            !hit_region_test::dpi_queried &&
                            hit_region_test::presentation_contract_ok &&
                            hit_region_test::presentations == before + 4;
      std::cout << "case=" << cases << " scale=" << scale
                << " eink=" << eink << " centerHit=" << center_hit
                << " centerAlpha=" << center_alpha
                << " edgeOffsetDip=23 edgeHit=" << edge_hit
                << " edgeAlpha=" << edge_alpha
                << " control=" << (setup_ok ? "PASS" : "FAIL")
                << " visual40=" << (visual_ok ? "PASS" : "FAIL")
                << " target48=" << (edge_ok ? "PASS" : "FAIL")
                << " outside25=" << (outside_ok ? "PASS" : "FAIL")
                << " entryOpacity=" << entry_opacity
                << " entry=" << (entry_ok ? "PASS" : "FAIL")
                << " collapsed=" << (collapsed_ok ? "PASS" : "FAIL")
                << " empty=" << (empty_ok ? "PASS" : "FAIL") << '\n';
      if (!setup_ok) {
        std::cerr << "Test setup failed; no valid renderer evidence.\n";
        return 2;
      }
      if (!visual_ok || !edge_ok || !outside_ok || !entry_ok || !collapsed_ok ||
          !empty_ok) {
        ++failures;
      }
    }
  }
  std::cout << "cases=" << cases << " failed=" << failures
            << " nativeWindowsCreated=0 inputEventsSent=0\n";
  return failures == 0 ? 0 : 1;
}
