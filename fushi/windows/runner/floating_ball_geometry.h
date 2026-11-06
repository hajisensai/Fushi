#ifndef RUNNER_FLOATING_BALL_GEOMETRY_H_
#define RUNNER_FLOATING_BALL_GEOMETRY_H_

// 桌面应用外悬浮球的纯几何与动画曲线（不依赖 Win32，可在 _test 里直接跑）。
//
// 与应用内球 lib/src/reader/reader_floating_ball.dart 的 ReaderFloatingBallLayout、
// Android FloatingBallGeometry.java 逐项同一套公式——改一边必须改另外两边。
// 契约见 docs/specs/2026-09-30-desktop-system-floating-ball.md。
//
// 单位：调用方给的视口是**物理像素**（屏幕坐标、左上原点），|scale| = dpi / 96；
// 所有 DIP 常量在这里乘 scale 变成 px。与 Dart 一样全程用 double，不在中途取整
// （Android 取整是因为 WindowManager 只收 int）；只有真正落到 HWND 位置时才取整。

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace fushi::floating_ball {

// 与 Dart kReaderFloatingBall* 同值（DIP）。
constexpr double kBallDip = 48.0;
constexpr double kButtonDip = 40.0;
constexpr double kGapDip = 6.0;
constexpr double kMarginDip = 8.0;
// 收起时缩进停靠边外的比例（Dart tuck = ballSize * 0.34）。
constexpr double kTuckRatio = 0.34;
// 收起态不透明度（Dart kReaderFloatingBallIdleOpacity）。
constexpr double kIdleOpacity = 0.42;
// 按钮图标边长（DIP）。
constexpr double kIconDip = 22.0;
// 球窗四周给阴影留的边；比按钮间距小，免得挡到按钮（Android BALL_SHADOW_PAD_DP）。
constexpr double kBallShadowPadDip = 6.0;
// 按钮窗四周给阴影留的边（Android MENU_SHADOW_PAD_DP）。
constexpr double kMenuShadowPadDip = 4.0;

// M3E FAB menu（与 Dart reader_floating_ball.dart 同值，DIP）：
// 球收起是圆角方块（kReaderFloatingBallCollapsedRadius），展开变正圆关闭钮；
// 单列时每颗按钮朝屏幕中央一侧带标签胶囊；按钮命中区 ≥ 48。
constexpr double kBallCollapsedRadiusDip = 14.0;
constexpr double kLabelGapDip = 8.0;
constexpr double kLabelHeightDip = 32.0;
constexpr double kLabelMaxWidthDip = 200.0;
constexpr double kLabelPaddingDip = 12.0;
// M3E label large（14）；Windows 无 Medium 字重，取 SemiBold（同 Dart 字阶层）。
constexpr double kLabelFontDip = 14.0;
constexpr double kMinTouchDip = 48.0;

// 与应用内球同一组时长（_expandDuration / _collapseDuration / _snapDuration）。
constexpr int kExpandMs = 280;
constexpr int kCollapseMs = 190;
constexpr int kSnapMs = 220;

struct Rect {
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;

  double Width() const { return right - left; }
  double Height() const { return bottom - top; }
  double CenterX() const { return (left + right) / 2.0; }
};

struct Offset {
  double dx = 0;
  double dy = 0;
};

class Geometry {
 public:
  // |allow_tuck| = false：停靠边外侧紧挨着另一块显示器，球不外缩（不塞进邻屏）。
  Geometry(const Rect& viewport, bool dock_left, double vertical_fraction,
           int action_count, double scale, bool allow_tuck = true)
      : viewport_(viewport),
        dock_left_(dock_left),
        vertical_fraction_(vertical_fraction),
        action_count_(std::max(0, action_count)),
        ball_(kBallDip * scale),
        button_(kButtonDip * scale),
        gap_(kGapDip * scale),
        margin_(kMarginDip * scale),
        allow_tuck_(allow_tuck) {}

  const Rect& viewport() const { return viewport_; }
  bool dock_left() const { return dock_left_; }
  int action_count() const { return action_count_; }
  double ball() const { return ball_; }
  double button() const { return button_; }
  double gap() const { return gap_; }
  double margin() const { return margin_; }

  double Tuck() const { return allow_tuck_ ? ball_ * kTuckRatio : 0.0; }

  // 相邻两颗按钮中心的竖向间距，也是相邻两列的横向间距。
  double Pitch() const { return button_ + gap_; }

  // 每列最多几颗：视口扣掉上下 margin 与球后，球顶以上还能放几个 pitch（至少 1）。
  int PerColumn() const {
    const double available = viewport_.Height() - 2 * margin_ - ball_;
    if (std::isnan(available) || available < Pitch()) return 1;
    // 1e-9 吸收浮点误差：恰好整除时不因 45.999… 少放一颗（Dart 同写法）。
    return std::max(1, static_cast<int>(std::floor(available / Pitch() + 1e-9)));
  }

  int ColumnCount() const {
    if (action_count_ <= 0) return 0;
    const int per = PerColumn();
    return (action_count_ + per - 1) / per;
  }

  // 最高一列的颗数（= 第一列）。
  int RowCount() const { return std::min(action_count_, PerColumn()); }

  // 新列朝屏幕中央展开：左停靠往右 +1，右停靠往左 -1。
  double ColumnDirection() const { return dock_left_ ? 1.0 : -1.0; }

  // 第 |index| 颗按钮中心相对球心的偏移（展开态）：列表末颗离球最近、紧贴球顶，
  // 先自下而上填满第一列，再往中央方向换列。
  Offset ButtonOffset(int index) const {
    const int slot = action_count_ - 1 - index;
    const int per = PerColumn();
    const int column = slot / per;
    const int row = slot % per;
    const double nearest = ball_ / 2 + gap_ + button_ / 2;
    return Offset{ColumnDirection() * column * Pitch(),
                  -(nearest + row * Pitch())};
  }

  // 展开态按钮区从球心向上伸出的距离（到最高一颗的上缘）。
  double Reach() const {
    return action_count_ <= 0 ? 0.0 : ball_ / 2 + RowCount() * Pitch();
  }

  double MinTop() const { return viewport_.top + margin_; }
  double MaxTop() const {
    return std::max(MinTop(), viewport_.bottom - ball_ - margin_);
  }

  // 收起态球顶边 y（比例落在活动范围内）。
  double BallTop() const {
    const double f = std::isfinite(vertical_fraction_)
                         ? std::clamp(vertical_fraction_, 0.0, 1.0)
                         : 0.5;
    return MinTop() + (MaxTop() - MinTop()) * f;
  }

  // 展开态球顶边 y：最高一列要放得进视口，放不下把球沿边往下滑。
  double ExpandedBallTop() const {
    const double lo = viewport_.top + margin_ + Reach() - ball_ / 2;
    const double max_top = MaxTop();
    if (max_top < lo) return max_top;
    return std::clamp(BallTop(), lo, max_top);
  }

  // 收起态球左边 x：停靠边外缩 tuck。
  double CollapsedBallLeft() const {
    return dock_left_ ? viewport_.left - Tuck()
                      : viewport_.right - ball_ + Tuck();
  }

  // 展开态球左边 x：整球回到视口内、贴边留 margin。
  double ExpandedBallLeft() const {
    return dock_left_ ? viewport_.left + margin_
                      : viewport_.right - ball_ - margin_;
  }

  double BallLeftAt(double t) const {
    return CollapsedBallLeft() + (ExpandedBallLeft() - CollapsedBallLeft()) * t;
  }
  double BallTopAt(double t) const {
    return BallTop() + (ExpandedBallTop() - BallTop()) * t;
  }

  // 任意球顶 y 反算持久化比例。
  double FractionForTop(double top) const {
    const double span = MaxTop() - MinTop();
    if (span <= 0) return 0.5;
    return std::clamp((top - MinTop()) / span, 0.0, 1.0);
  }

  // 松手时按球心落在视口左右哪一半决定停靠边。
  bool DockLeftForBallLeft(double ball_left) const {
    return ball_left + ball_ / 2 < viewport_.CenterX();
  }

 private:
  Rect viewport_;
  bool dock_left_;
  double vertical_fraction_;
  int action_count_;
  double ball_;
  double button_;
  double gap_;
  double margin_;
  bool allow_tuck_;
};

// ── 动画曲线 ────────────────────────────────────────────────────────────────

// CSS / Flutter Cubic 同义的三次贝塞尔 (0,0)-(x1,y1)-(x2,y2)-(1,1)：先按 x 反解
// 参数 u（x(u) 单调，二分到 1e-12），再取 y(u)。端点精确返回 0 / 1。
inline double CubicBezier(double x1, double y1, double x2, double y2,
                          double x) {
  if (!(x > 0.0)) return 0.0;
  if (x >= 1.0) return 1.0;
  auto eval = [](double a, double b, double m) {
    const double inv = 1.0 - m;
    return 3 * a * inv * inv * m + 3 * b * inv * m * m + m * m * m;
  };
  double lo = 0.0;
  double hi = 1.0;
  for (int i = 0; i < 64; ++i) {
    const double mid = (lo + hi) / 2;
    if (eval(x1, x2, mid) < x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return eval(y1, y2, (lo + hi) / 2);
}

// Flutter Curves.easeOutBack：会冲过 1 再回落（按钮飞出时的回弹）。
inline double EaseOutBack(double x) {
  return CubicBezier(0.175, 0.885, 0.32, 1.275, x);
}

// Flutter Curves.easeOutCubic：拖动松手吸附。
inline double EaseOutCubic(double x) {
  return CubicBezier(0.215, 0.61, 0.355, 1.0, x);
}

// easeOutBack 在 [0,1] 上的峰值（≈1.1）：按钮窗包围盒要容得下回弹冲过头的那段。
inline double EaseOutBackPeak() {
  double peak = 1.0;
  for (int i = 0; i <= 1000; ++i) {
    peak = std::max(peak, EaseOutBack(i / 1000.0));
  }
  return peak;
}

struct Interval {
  double begin = 0;
  double end = 1;
};

// 按钮 i（共 n 颗）占总时长里错开的一段：离球越远起得越晚、尾部对齐
// （应用内 _buildColumnButton 同一套区间）。
inline Interval ButtonInterval(int index, int count) {
  const double step = count <= 1 ? 0.0 : 0.35 / (count - 1);
  const double begin = (count - 1 - index) * step;
  return Interval{begin, std::min(1.0, begin + 0.65)};
}

// 展开进度 |t| 下第 |index| 颗按钮的曲线值 k（可能 > 1：回弹）。
inline double ButtonProgress(double t, int index, int count) {
  const Interval iv = ButtonInterval(index, count);
  double raw;
  if (iv.end > iv.begin) {
    raw = (t - iv.begin) / (iv.end - iv.begin);
  } else {
    raw = t >= iv.end ? 1.0 : 0.0;
  }
  return EaseOutBack(std::clamp(raw, 0.0, 1.0));
}

// 按钮的缩放与不透明度（应用内同一式）。
inline double ButtonScale(double k) {
  return 0.4 + 0.6 * std::clamp(k, 0.0, 1.2);
}
inline double ButtonOpacity(double k) { return std::clamp(k, 0.0, 1.0); }

// 绘制与命中共用：40 DIP 的圆钮扩到 48 DIP，仍跟随动画的实际半径。
// 分层窗口必须同时给这块区域非零 alpha，仅扩大 ButtonAt 不会收到 OS 事件。
inline double ButtonHitRadius(double visual_radius) {
  return visual_radius * kMinTouchDip / kButtonDip;
}

// 球的不透明度：收起 0.42 → 展开 1；拖动中恒 1。
inline double BallOpacity(double t, bool dragging) {
  return dragging ? 1.0 : kIdleOpacity + (1.0 - kIdleOpacity) * t;
}

// 中途反向按剩余路程缩短（与 AnimationController 反向同感）。
inline int ProgressDurationMs(int full_ms, double from, double to) {
  return std::max(1, static_cast<int>(std::lround(full_ms * std::fabs(to - from))));
}

inline double Lerp(double a, double b, double t) { return a + (b - a) * t; }

// ── 平台无关的状态与布局（Windows / Linux runner 共用）────────────────────────

constexpr char kActionOpenApp[] = "open_app";
constexpr char kActionClose[] = "close";

// 按钮自上而下：关闭、（没被关掉的）打开 Fushi 在最上（离球最远，防误触），用户勾选的
// 动作在下、去重，末颗紧贴球顶——与应用内「列表末颗离球最近」同序。
inline std::vector<std::string> ButtonIds(
    bool show_open_app, const std::vector<std::string>& actions) {
  std::vector<std::string> ids;
  ids.emplace_back(kActionClose);
  if (show_open_app) ids.emplace_back(kActionOpenApp);
  for (const std::string& id : actions) {
    if (id != kActionClose && id != kActionOpenApp &&
        std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
    }
  }
  return ids;
}

// 展开 / 收起进度动画：线性，中途反向按剩余路程缩短。
struct ProgressAnimation {
  bool active = false;
  double from = 0;
  double to = 0;
  double start_ms = 0;
  double duration_ms = 1;

  void Start(double current, double target, int full_ms, double now_ms) {
    active = true;
    from = current;
    to = target;
    start_ms = now_ms;
    duration_ms = ProgressDurationMs(full_ms, current, target);
  }

  // 当前进度；到终点时 active 置 false 并返回 to。
  double Sample(double now_ms) {
    const double f = std::clamp((now_ms - start_ms) / duration_ms, 0.0, 1.0);
    if (f >= 1.0) {
      active = false;
      return to;
    }
    return Lerp(from, to, f);
  }
};

// 拖动松手后吸附到收起位：kSnapMs、easeOutCubic。
struct SnapAnimation {
  bool active = false;
  double from_left = 0;
  double from_top = 0;
  double to_left = 0;
  double to_top = 0;
  double start_ms = 0;

  void Start(double left, double top, double target_left, double target_top,
             double now_ms) {
    active = true;
    from_left = left;
    from_top = top;
    to_left = target_left;
    to_top = target_top;
    start_ms = now_ms;
  }

  // 写出当前球左上角；到终点时 active 置 false。
  void Sample(double now_ms, double* left, double* top) {
    const double f =
        std::clamp((now_ms - start_ms) / static_cast<double>(kSnapMs), 0.0, 1.0);
    const double e = EaseOutCubic(f);
    *left = Lerp(from_left, to_left, e);
    *top = Lerp(from_top, to_top, e);
    if (f >= 1.0) active = false;
  }
};

// 拖动中的球左上角：横向夹在左右两个收起位之间，纵向夹在活动范围里。
// |as_left| / |as_right| = 同一视口按左 / 右停靠的几何。
inline Offset ClampDrag(const Geometry& as_left, const Geometry& as_right,
                        double left, double top) {
  return Offset{std::clamp(left, as_left.CollapsedBallLeft(),
                           std::max(as_left.CollapsedBallLeft(),
                                    as_right.CollapsedBallLeft())),
                std::clamp(top, as_left.MinTop(), as_left.MaxTop())};
}

// 按钮窗：按**最终几何**一次算好的包围盒（屏幕整数像素）与窗内的展开态球心、
// 各按钮落点。包围盒容得下每颗按钮从球心飞到落点、再按 easeOutBack 冲过头的整段
// 轨迹（圆心随 k 线性，两个端点 k=0 / k=峰值 的并集就够），外加阴影边与标签胶囊。
struct MenuLayout {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  double ball_cx = 0;
  double ball_cy = 0;
  std::vector<Offset> centers;
};

// |label_widths| 与按钮一一对应（屏幕像素），空 = 不显示标签。|peak| =
// EaseOutBackPeak()（调用方缓存）。
inline MenuLayout LayoutMenu(const Geometry& g, double scale, double peak,
                             const std::vector<double>& label_widths) {
  const double ball_cx = g.ExpandedBallLeft() + g.ball() / 2;
  const double ball_cy = g.ExpandedBallTop() + g.ball() / 2;
  const double reach_radius = g.button() / 2 * ButtonScale(peak) +
                              kMenuShadowPadDip * scale + 2.0 * scale;
  double min_x = ball_cx - reach_radius;
  double max_x = ball_cx + reach_radius;
  double min_y = ball_cy - reach_radius;
  double max_y = ball_cy + reach_radius;
  // 标签胶囊贴在按钮朝屏幕中央的一侧（左停靠在右、右停靠在左），随按钮圆心走。
  const double label_near = g.button() / 2 + kLabelGapDip * scale;
  const double label_pad = kMenuShadowPadDip * scale;
  const double label_half_h = kLabelHeightDip * scale / 2 + label_pad;
  auto include_label = [&](size_t index, double cx, double cy) {
    if (index >= label_widths.size()) return;
    const double w = label_widths[index];
    const double a = g.dock_left() ? cx + label_near : cx - label_near - w;
    min_x = std::min(min_x, a - label_pad);
    max_x = std::max(max_x, a + w + label_pad);
    min_y = std::min(min_y, cy - label_half_h);
    max_y = std::max(max_y, cy + label_half_h);
  };
  std::vector<Offset> offsets;
  for (int i = 0; i < g.action_count(); ++i) {
    const Offset off = g.ButtonOffset(i);
    offsets.push_back(off);
    const double far_x = ball_cx + off.dx * peak;
    const double far_y = ball_cy + off.dy * peak;
    min_x = std::min(min_x, far_x - reach_radius);
    max_x = std::max(max_x, far_x + reach_radius);
    min_y = std::min(min_y, far_y - reach_radius);
    max_y = std::max(max_y, far_y + reach_radius);
    include_label(static_cast<size_t>(i), ball_cx, ball_cy);
    include_label(static_cast<size_t>(i), far_x, far_y);
  }
  MenuLayout layout;
  layout.x = static_cast<int>(std::floor(min_x));
  layout.y = static_cast<int>(std::floor(min_y));
  layout.width = static_cast<int>(std::ceil(max_x)) - layout.x;
  layout.height = static_cast<int>(std::ceil(max_y)) - layout.y;
  layout.ball_cx = ball_cx - layout.x;
  layout.ball_cy = ball_cy - layout.y;
  for (const Offset& off : offsets) {
    layout.centers.push_back(
        Offset{layout.ball_cx + off.dx, layout.ball_cy + off.dy});
  }
  return layout;
}

}  // namespace fushi::floating_ball

#endif  // RUNNER_FLOATING_BALL_GEOMETRY_H_
