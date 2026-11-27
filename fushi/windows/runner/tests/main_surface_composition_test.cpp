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
  const MainSurfaceState mica_opaque_content{true, true};
  const MainSurfaceState plain_opaque_content{false, true};

  // Plain window keeps window_manager's hidden-title-bar shadow (1 px top).
  ok &= Expect(SameMargins(MainFrameMargins(plain), 0, 0, 1, 0),
               "plain window keeps the 1 px top shadow margin");
  ok &= Expect(!MainSurfaceSeeThrough(plain),
               "plain window paints the theme backdrop");

  // Mica: whole client area is glass.
  ok &= Expect(SameMargins(MainFrameMargins(mica), -1, -1, -1, -1),
               "Mica extends the frame over the whole client area");
  ok &= Expect(MainSurfaceSeeThrough(mica), "Mica surface is see-through");

  // BUG-5591: opaque content (video page) composes the surface opaque even
  // with Mica requested, so fullscreen jumps keep the snapshot under the view.
  ok &= Expect(!MainSurfaceSeeThrough(mica_opaque_content),
               "Mica under opaque content is not see-through");
  ok &= Expect(SameMargins(MainFrameMargins(mica_opaque_content), 0, 0, 1, 0),
               "Mica under opaque content uses the plain margins");
  ok &= Expect(!MainSurfaceSeeThrough(plain_opaque_content) &&
                   SameMargins(MainFrameMargins(plain_opaque_content), 0, 0,
                               1, 0),
               "opaque content does not change a plain window");

  if (!ok) {
    return 1;
  }
  std::cout << "main_surface_composition_test: all passed\n";
  return 0;
}
