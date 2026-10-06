// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"。与 window_activation_policy_test.cpp 同一写法。
#undef NDEBUG

#include "../main_surface_composition.h"

#include <iostream>
#include <string>

namespace {

using fushi::MainFrameMargins;
using fushi::MainSurfaceSeeThrough;
using fushi::MainSurfaceState;

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

bool SameMargins(const MARGINS& a, int left, int right, int top, int bottom) {
  return a.cxLeftWidth == left && a.cxRightWidth == right &&
         a.cyTopHeight == top && a.cyBottomHeight == bottom;
}

}  // namespace

int main() {
  bool ok = true;

  const MainSurfaceState plain{false, false};
  const MainSurfaceState mica{true, false};
  const MainSurfaceState passthrough{false, true};
  const MainSurfaceState mica_and_passthrough{true, true};

  // Plain window keeps window_manager's hidden-title-bar shadow (1 px top).
  ok &= Expect(SameMargins(MainFrameMargins(plain), 0, 0, 1, 0),
               "plain window keeps the 1 px top shadow margin");
  ok &= Expect(!MainSurfaceSeeThrough(plain),
               "plain window paints the theme backdrop");

  // Mica: whole client area is glass.
  ok &= Expect(SameMargins(MainFrameMargins(mica), -1, -1, -1, -1),
               "Mica extends the frame over the whole client area");
  ok &= Expect(MainSurfaceSeeThrough(mica), "Mica surface is see-through");

  // BUG-2964: the HDR passthrough must not extend the frame into the client
  // area at all — measured, the 1 px top shadow margin draws an opaque
  // DWMWA_CAPTION_COLOR line over client row 0 of the video.
  ok &= Expect(SameMargins(MainFrameMargins(passthrough), 0, 0, 0, 0),
               "passthrough keeps the frame out of the client area");
  ok &= Expect(MainSurfaceSeeThrough(passthrough),
               "passthrough surface is see-through (black GDI fill)");

  // Passthrough wins over Mica: Mica's glass would fill the video hole.
  ok &= Expect(SameMargins(MainFrameMargins(mica_and_passthrough), 0, 0, 0, 0),
               "passthrough overrides Mica's glass margins");
  ok &= Expect(MainSurfaceSeeThrough(mica_and_passthrough),
               "Mica + passthrough surface is see-through");

  // The DWM shadow under client row 0 is only removed while the frame is
  // off-screen: passthrough AND runner fullscreen. Windowed keeps the frame.
  const MainSurfaceState passthrough_fullscreen{false, true, true};
  const MainSurfaceState plain_fullscreen{false, false, true};
  ok &= Expect(fushi::MainSurfaceNcRenderingDisabled(passthrough_fullscreen),
               "passthrough fullscreen drops DWM non-client rendering");
  ok &= Expect(!fushi::MainSurfaceNcRenderingDisabled(passthrough),
               "windowed passthrough keeps the DWM frame");
  ok &= Expect(!fushi::MainSurfaceNcRenderingDisabled(plain_fullscreen),
               "SDR fullscreen keeps the DWM frame");
  ok &= Expect(!fushi::MainSurfaceNcRenderingDisabled(plain),
               "plain window keeps the DWM frame");
  ok &= Expect(SameMargins(MainFrameMargins(passthrough_fullscreen), 0, 0, 0, 0),
               "passthrough fullscreen keeps the frame out of the client area");

  if (!ok) {
    return 1;
  }
  std::cout << "main_surface_composition_test: all passed\n";
  return 0;
}
