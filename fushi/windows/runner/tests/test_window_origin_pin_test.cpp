// release 也要真断言：NDEBUG 会把 assert 编成空语句。与
// window_activation_policy_test.cpp 同一写法。
#undef NDEBUG

#include "../test_window_origin_pin.h"

#include <iostream>
#include <string>

namespace {

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

constexpr POINT kOffscreen{-32000, -32000};

WINDOWPOS Move(int x, int y, UINT flags = 0) {
  WINDOWPOS pos{};
  pos.x = x;
  pos.y = y;
  pos.cx = 1440;
  pos.cy = 960;
  pos.flags = flags;
  return pos;
}

}  // namespace

int main() {
  bool passed = true;

  // --- which origin is pinned ---
  passed &= Expect(
      !ResolveTestWindowOriginPin(false, false, std::nullopt, kOffscreen),
      "a normal (non-test) launch pins nothing");
  passed &= Expect(
      !ResolveTestWindowOriginPin(false, false, POINT{10, 20}, kOffscreen),
      "FUSHI_TEST_TOPMOST without FUSHI_TEST_HIDDEN pins nothing");
  {
    const auto pin =
        ResolveTestWindowOriginPin(true, false, std::nullopt, kOffscreen);
    passed &= Expect(pin.has_value() && pin->x == -32000 && pin->y == -32000,
                     "default hidden mode pins the off-screen origin");
  }
  passed &= Expect(
      !ResolveTestWindowOriginPin(true, true, std::nullopt, kOffscreen),
      "FUSHI_TEST_ONSCREEN leaves the window movable");
  {
    const auto pin =
        ResolveTestWindowOriginPin(true, true, POINT{100, 200}, kOffscreen);
    passed &= Expect(pin.has_value() && pin->x == 100 && pin->y == 200,
                     "FUSHI_TEST_TOPMOST pins its evidence origin");
  }

  // --- the WM_WINDOWPOSCHANGING rewrite ---
  {
    // Measured: applyInitialPlacement's centring setBounds.
    WINDOWPOS pos = Move(840, 360);
    passed &= Expect(PinWindowPosOrigin(&pos, kOffscreen, false),
                     "a startup centring move is rewritten");
    passed &= Expect(pos.x == -32000 && pos.y == -32000,
                     "the rewritten move lands at the pinned origin");
    passed &= Expect(pos.cx == 1440 && pos.cy == 960,
                     "the requested size is kept");
  }
  {
    WINDOWPOS pos = Move(840, 360, SWP_NOMOVE);
    passed &= Expect(!PinWindowPosOrigin(&pos, kOffscreen, false),
                     "SWP_NOMOVE is not a move");
    passed &= Expect(pos.x == 840 && pos.y == 360,
                     "SWP_NOMOVE coordinates are left alone");
  }
  {
    WINDOWPOS pos = Move(840, 360);
    passed &= Expect(!PinWindowPosOrigin(&pos, std::nullopt, false),
                     "no pin, no rewrite");
    passed &= Expect(pos.x == 840, "unpinned moves keep their origin");
  }
  {
    WINDOWPOS pos = Move(840, 360);
    passed &= Expect(!PinWindowPosOrigin(&pos, POINT{0, 0}, true),
                     "an iconic window is left to the system");
  }
  {
    WINDOWPOS pos = Move(-32000, -32000);
    passed &= Expect(!PinWindowPosOrigin(&pos, kOffscreen, false),
                     "a move that already targets the pin reports no change");
  }
  passed &= Expect(!PinWindowPosOrigin(nullptr, kOffscreen, false),
                   "null WINDOWPOS is ignored");

  // --- FUSHI_TEST_WINDOW_RECT size pin (BUG-3888) ---
  passed &= Expect(!ResolveTestWindowSizePin(false, SIZE{2880, 1920}),
                   "the rect without FUSHI_TEST_HIDDEN pins no size");
  passed &= Expect(!ResolveTestWindowSizePin(true, std::nullopt),
                   "hidden mode without the rect pins no size");
  passed &= Expect(!ResolveTestWindowSizePin(true, SIZE{0, 1920}),
                   "an empty rect pins no size");
  {
    const auto pin = ResolveTestWindowSizePin(true, SIZE{2880, 1920});
    passed &= Expect(pin.has_value() && pin->cx == 2880 && pin->cy == 1920,
                     "hidden mode pins the rect size");
    // Shape of applyInitialPlacement's work-area-sized setBounds.
    WINDOWPOS pos = Move(840, 360);
    passed &= Expect(PinWindowPosSize(&pos, pin, false),
                     "a startup resize is rewritten");
    passed &= Expect(pos.cx == 2880 && pos.cy == 1920,
                     "the rewritten resize lands at the pinned size");
    passed &= Expect(pos.x == 840 && pos.y == 360,
                     "the size pin leaves the origin to the origin pin");
    WINDOWPOS keep = Move(840, 360, SWP_NOSIZE);
    passed &= Expect(!PinWindowPosSize(&keep, pin, false),
                     "SWP_NOSIZE is not a resize");
    WINDOWPOS iconic = Move(840, 360);
    passed &= Expect(!PinWindowPosSize(&iconic, pin, true),
                     "an iconic window is left to the system");
  }
  passed &= Expect(!PinWindowPosSize(nullptr, SIZE{1, 1}, false),
                   "null WINDOWPOS is ignored by the size pin");

  if (!passed) {
    return 1;
  }
  std::cout << "test_window_origin_pin_test: all passed\n";
  return 0;
}
