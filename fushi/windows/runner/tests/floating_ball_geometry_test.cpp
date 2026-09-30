// release 也要真断言：NDEBUG 会把 assert 编成空语句，测试就会空跑照样"通过"。
#undef NDEBUG

#include "../floating_ball_geometry.h"

#include <cassert>
#include <cmath>

namespace {

bool Near(double a, double b, double eps = 1e-9) {
  return std::fabs(a - b) < eps;
}

}  // namespace

int main() {
  using namespace fushi::floating_ball;

  // 竖屏：视口 (0,40)-(400,700)，右停靠，比例 0.5，3 颗按钮，scale 1。
  // 数值与 Dart ReaderFloatingBallLayout / Android FloatingBallGeometry 同式手算。
  {
    const Geometry g(Rect{0, 40, 400, 700}, false, 0.5, 3, 1.0);
    assert(Near(g.Tuck(), 16.32));
    assert(Near(g.Pitch(), 46));
    // (660 - 16 - 48) / 46 = 12.95…
    assert(g.PerColumn() == 12);
    assert(g.ColumnCount() == 1);
    assert(g.RowCount() == 3);
    assert(Near(g.MinTop(), 48));
    assert(Near(g.MaxTop(), 644));
    assert(Near(g.BallTop(), 346));
    assert(Near(g.Reach(), 24 + 3 * 46));
    assert(Near(g.ExpandedBallTop(), 346));
    assert(Near(g.CollapsedBallLeft(), 400 - 48 + 16.32));
    assert(Near(g.ExpandedBallLeft(), 344));
    // 末颗紧贴球顶：球心上方 24 + 6 + 20 = 50；首颗最远。
    assert(Near(g.ButtonOffset(2).dx, 0) && Near(g.ButtonOffset(2).dy, -50));
    assert(Near(g.ButtonOffset(1).dy, -96));
    assert(Near(g.ButtonOffset(0).dy, -142));
    assert(Near(g.FractionForTop(346), 0.5));
    assert(Near(g.FractionForTop(-1000), 0.0));
    assert(Near(g.FractionForTop(10000), 1.0));
    assert(!g.DockLeftForBallLeft(200));  // 球心 224 > 200
    assert(g.DockLeftForBallLeft(170));   // 球心 194 < 200
    // 邻屏：不外缩。
    const Geometry no_tuck(Rect{0, 40, 400, 700}, false, 0.5, 3, 1.0, false);
    assert(Near(no_tuck.CollapsedBallLeft(), 352));
  }

  // 横屏矮视口 800x280，6 颗：每列 4 颗，第二列朝屏幕中央（右停靠往左）。
  {
    const Geometry g(Rect{0, 0, 800, 280}, false, 0.5, 6, 1.0);
    // (280 - 16 - 48) / 46 = 4.69…
    assert(g.PerColumn() == 4);
    assert(g.ColumnCount() == 2);
    assert(g.RowCount() == 4);
    assert(Near(g.ButtonOffset(5).dx, 0) && Near(g.ButtonOffset(5).dy, -50));
    assert(Near(g.ButtonOffset(2).dx, 0) && Near(g.ButtonOffset(2).dy, -188));
    assert(Near(g.ButtonOffset(1).dx, -46) && Near(g.ButtonOffset(1).dy, -50));
    assert(Near(g.ButtonOffset(0).dx, -46) && Near(g.ButtonOffset(0).dy, -96));
    // 放不下时球沿边下滑：lo = 8 + 208 - 24 = 192；maxTop = 224；ballTop = 116。
    assert(Near(g.BallTop(), 116));
    assert(Near(g.ExpandedBallTop(), 192));
    const Geometry left(Rect{0, 0, 800, 280}, true, 0.5, 6, 1.0);
    assert(Near(left.ButtonOffset(0).dx, 46));
    assert(Near(left.CollapsedBallLeft(), -16.32));
    assert(Near(left.ExpandedBallLeft(), 8));
  }

  // DPI 150%：所有 DIP 常量等比放大。
  {
    const Geometry g(Rect{100, 0, 1100, 900}, true, 0.0, 1, 1.5);
    assert(Near(g.ball(), 72));
    assert(Near(g.MinTop(), 12));
    assert(Near(g.BallTop(), 12));
    assert(Near(g.ButtonOffset(0).dy, -(36 + 9 + 30)));
    assert(Near(g.CollapsedBallLeft(), 100 - 72 * 0.34));
  }

  // 极端矮视口：perColumn 退化成 1，球钉在视口底部。
  {
    const Geometry g(Rect{0, 0, 300, 100}, true, 0.5, 3, 1.0);
    assert(g.PerColumn() == 1);
    assert(Near(g.MaxTop(), 44));
    assert(Near(g.ExpandedBallTop(), 44));
    const Geometry nan(Rect{0, 0, 300, 700}, true, std::nan(""), 0, 1.0);
    assert(Near(nan.BallTop(), 8 + (644 - 8) * 0.5));
    assert(Near(nan.Reach(), 0));
    assert(nan.ColumnCount() == 0);
  }

  // 曲线端点与形状。
  assert(Near(EaseOutBack(0), 0) && Near(EaseOutBack(1), 1));
  assert(Near(EaseOutCubic(0), 0) && Near(EaseOutCubic(1), 1));
  assert(Near(EaseOutCubic(-1), 0) && Near(EaseOutCubic(2), 1));
  // easeOutCubic 近似 1-(1-x)^3（贝塞尔拟合，误差 < 1%）。
  assert(Near(EaseOutCubic(0.5), 1 - 0.125, 0.01));
  // easeOutBack 冲过 1 再回落。
  const double peak = EaseOutBackPeak();
  assert(peak > 1.05 && peak < 1.15);
  assert(EaseOutBack(0.8) > 1.0);
  // 单调区段：前半程递增。
  assert(EaseOutBack(0.2) < EaseOutBack(0.4));

  // 错峰：n 颗时首颗（离球最远）起得最晚，末颗从 0 开始；尾部对齐到 1。
  {
    const Interval first = ButtonInterval(0, 5);
    const Interval last = ButtonInterval(4, 5);
    assert(Near(first.begin, 0.35) && Near(first.end, 1.0));
    assert(Near(last.begin, 0.0) && Near(last.end, 0.65));
    assert(Near(ButtonInterval(2, 5).begin, 0.175));
    const Interval single = ButtonInterval(0, 1);
    assert(Near(single.begin, 0) && Near(single.end, 0.65));
    assert(Near(ButtonProgress(0.0, 0, 5), 0));
    assert(Near(ButtonProgress(0.3, 0, 5), 0));  // 还没起
    assert(ButtonProgress(0.3, 4, 5) > 0);
    assert(Near(ButtonProgress(1.0, 0, 5), 1));
    assert(Near(ButtonProgress(0.65, 4, 5), 1));
  }

  assert(Near(ButtonScale(0), 0.4) && Near(ButtonScale(1), 1.0));
  assert(Near(ButtonScale(2), 0.4 + 0.72));
  assert(Near(ButtonOpacity(1.1), 1.0));
  assert(Near(BallOpacity(0, false), kIdleOpacity));
  assert(Near(BallOpacity(0, true), 1.0));
  assert(Near(BallOpacity(1, false), 1.0));
  assert(ProgressDurationMs(kExpandMs, 0, 1) == 280);
  assert(ProgressDurationMs(kCollapseMs, 0.5, 0) == 95);
  assert(ProgressDurationMs(kExpandMs, 1, 1) == 1);
  return 0;
}
