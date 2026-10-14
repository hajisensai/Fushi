import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 漫画裁切框的纯几何（高级制卡 · 漫画图片分区）。
///
/// 坐标一律是**相对原页图的 0..1 归一化** [Rect]——与分镜检测、
/// `MangaCropSuggestions`、`MiningImageCrop` 同一坐标系，所以「所在分镜」可以不经
/// 换算直接当选中框，确认时也直接落进覆盖项。屏幕像素只出现在命中判定
/// （[hitTestCropHandle] / [cropRectContains]）与布局（[containRect]）里。
///
/// 抽成纯函数是为了能脱离 widget 单测：拖框、手柄、键盘微调的边界情形（翻转、
/// 越界、最小尺寸）全在这里，控件只负责把指针 / 按键翻译成这些调用。

/// 八个缩放手柄：四角 + 四边中点。
enum MangaCropHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

/// 框的最小宽 / 高（归一化）。比 `MiningImageCrop.isDegenerate` 的 1% 宽松得多：
/// 小于页面 4% 的卡图基本看不清，也让手柄不至于叠成一团点不中。
const double kMangaCropMinExtent = 0.04;

/// 键盘方向键一次挪动 / 缩放的步长（归一化）。1% 在常见页图（1000~2000px）上是
/// 10~20px，既能细调又不至于按半天。
const double kMangaCropNudgeStep = 0.01;

double _clampUnit(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 把 [rect] 夹进单位方框，并保证宽高都不小于 [minExtent]。
///
/// 不足最小尺寸时**以中心扩张**再整体平移回方框内——而不是只把右/下边往外推：
/// 用户点一下（零尺寸拖动）时，框应该出现在手指周围，而不是偏到右下。
Rect clampCropRect(Rect rect, {double minExtent = kMangaCropMinExtent}) {
  final double minE = minExtent.clamp(0.0, 1.0);
  double l = math.min(rect.left, rect.right);
  double r = math.max(rect.left, rect.right);
  double t = math.min(rect.top, rect.bottom);
  double b = math.max(rect.top, rect.bottom);
  // 先把超出方框的部分裁掉（框比页面还大时只剩整页）。
  l = _clampUnit(l);
  r = _clampUnit(r);
  t = _clampUnit(t);
  b = _clampUnit(b);
  (double, double) grow(double lo, double hi) {
    if (hi - lo >= minE) return (lo, hi);
    final double c = (lo + hi) / 2;
    double nlo = c - minE / 2;
    double nhi = c + minE / 2;
    // 扩张后越界：整体平移回来（尺寸保持 minE）。
    if (nlo < 0) {
      nhi -= nlo;
      nlo = 0;
    }
    if (nhi > 1) {
      nlo -= nhi - 1;
      nhi = 1;
    }
    return (_clampUnit(nlo), _clampUnit(nhi));
  }

  (l, r) = grow(l, r);
  (t, b) = grow(t, b);
  return Rect.fromLTRB(l, t, r, b);
}

/// 框外按下后拖出一个新框（Win+Shift+S 式）。拖动方向任意：起点与当前点决定对角，
/// 往左上拖也能得到正向矩形。起止点可能拖出页面外（指针离开图片区域），先夹进方框。
Rect cropRectFromDrag(
  Offset start,
  Offset end, {
  double minExtent = kMangaCropMinExtent,
}) {
  final Rect raw = Rect.fromPoints(
    Offset(_clampUnit(start.dx), _clampUnit(start.dy)),
    Offset(_clampUnit(end.dx), _clampUnit(end.dy)),
  );
  return clampCropRect(raw, minExtent: minExtent);
}

/// 平移整框，尺寸不变；撞到页面边缘就停在边上（不压缩框）。
Rect moveCropRect(Rect rect, Offset delta) {
  final double w = rect.width.clamp(0.0, 1.0);
  final double h = rect.height.clamp(0.0, 1.0);
  final double l = (rect.left + delta.dx).clamp(0.0, 1.0 - w);
  final double t = (rect.top + delta.dy).clamp(0.0, 1.0 - h);
  return Rect.fromLTWH(l, t, w, h);
}

/// 拖动 [handle] 缩放：只动该手柄对应的边，对边固定。
///
/// 不允许翻转越过对边：翻转后手柄语义跟着颠倒（拖着「右」却在改左边），用户会
/// 失去对框的掌控；于是被拖的边最多到「对边 ± minExtent」为止。
Rect resizeCropRect(
  Rect rect,
  MangaCropHandle handle,
  Offset delta, {
  double minExtent = kMangaCropMinExtent,
}) {
  double l = rect.left;
  double t = rect.top;
  double r = rect.right;
  double b = rect.bottom;
  final bool moveLeft =
      handle == MangaCropHandle.topLeft ||
      handle == MangaCropHandle.left ||
      handle == MangaCropHandle.bottomLeft;
  final bool moveRight =
      handle == MangaCropHandle.topRight ||
      handle == MangaCropHandle.right ||
      handle == MangaCropHandle.bottomRight;
  final bool moveTop =
      handle == MangaCropHandle.topLeft ||
      handle == MangaCropHandle.top ||
      handle == MangaCropHandle.topRight;
  final bool moveBottom =
      handle == MangaCropHandle.bottomLeft ||
      handle == MangaCropHandle.bottom ||
      handle == MangaCropHandle.bottomRight;
  if (moveLeft) l = (l + delta.dx).clamp(0.0, math.max(0.0, r - minExtent));
  if (moveRight) r = (r + delta.dx).clamp(math.min(1.0, l + minExtent), 1.0);
  if (moveTop) t = (t + delta.dy).clamp(0.0, math.max(0.0, b - minExtent));
  if (moveBottom) b = (b + delta.dy).clamp(math.min(1.0, t + minExtent), 1.0);
  return Rect.fromLTRB(l, t, r, b);
}

/// 手柄在像素框上的中心点。
Offset cropHandleCenter(Rect rectPx, MangaCropHandle handle) {
  switch (handle) {
    case MangaCropHandle.topLeft:
      return rectPx.topLeft;
    case MangaCropHandle.top:
      return rectPx.topCenter;
    case MangaCropHandle.topRight:
      return rectPx.topRight;
    case MangaCropHandle.right:
      return rectPx.centerRight;
    case MangaCropHandle.bottomRight:
      return rectPx.bottomRight;
    case MangaCropHandle.bottom:
      return rectPx.bottomCenter;
    case MangaCropHandle.bottomLeft:
      return rectPx.bottomLeft;
    case MangaCropHandle.left:
      return rectPx.centerLeft;
  }
}

/// 指针落在哪个手柄上（[rectPx] 是屏幕像素里的选中框，[slop] 是命中半径）。
///
/// 角优先于边中点：小框上角与边中点的命中圈互相重叠，用户拖角通常是想同时改两条边，
/// 判成边中点会只动一条边。同类里取最近的那个。
MangaCropHandle? hitTestCropHandle(
  Rect rectPx,
  Offset point, {
  required double slop,
}) {
  MangaCropHandle? best(List<MangaCropHandle> candidates) {
    MangaCropHandle? hit;
    double bestD = double.infinity;
    for (final MangaCropHandle h in candidates) {
      final double d = (cropHandleCenter(rectPx, h) - point).distance;
      if (d <= slop && d < bestD) {
        bestD = d;
        hit = h;
      }
    }
    return hit;
  }

  return best(const <MangaCropHandle>[
        MangaCropHandle.topLeft,
        MangaCropHandle.topRight,
        MangaCropHandle.bottomRight,
        MangaCropHandle.bottomLeft,
      ]) ??
      best(const <MangaCropHandle>[
        MangaCropHandle.top,
        MangaCropHandle.right,
        MangaCropHandle.bottom,
        MangaCropHandle.left,
      ]);
}

/// 指针是否在框内（含边）：框内按下 = 平移，框外按下 = 画新框。
bool cropRectContains(Rect rectPx, Offset point) =>
    point.dx >= rectPx.left &&
    point.dx <= rectPx.right &&
    point.dy >= rectPx.top &&
    point.dy <= rectPx.bottom;

bool _sameRect(Rect a, Rect b) =>
    (a.left - b.left).abs() < 1e-6 &&
    (a.top - b.top).abs() < 1e-6 &&
    (a.right - b.right).abs() < 1e-6 &&
    (a.bottom - b.bottom).abs() < 1e-6;

/// Tab / Shift+Tab 在分镜间循环：返回要切到的分镜下标。
///
/// 越过末尾 / 开头返回 null——不绕回，让 Tab 交还给焦点遍历走到下一个控件，否则
/// 键盘用户会被困在裁切区里出不去。当前框不是任何分镜（整页 / 自定义）时，前进从
/// 第一个开始、后退从最后一个开始。
int? cyclePanelIndex(
  List<Rect> panels,
  Rect? current, {
  bool backward = false,
}) {
  if (panels.isEmpty) return null;
  int at = -1;
  if (current != null) {
    for (int i = 0; i < panels.length; i++) {
      if (_sameRect(panels[i], current)) {
        at = i;
        break;
      }
    }
  }
  if (at < 0) return backward ? panels.length - 1 : 0;
  final int next = backward ? at - 1 : at + 1;
  if (next < 0 || next >= panels.length) return null;
  return next;
}

/// 按原页像素算裁出来的图有多大（给「输出 W×H」文案）。至少 1，避免显示 0×0。
({int width, int height}) cropOutputPixels(Rect rect, Size pageSize) => (
  width: math.max(1, (rect.width * pageSize.width).round()),
  height: math.max(1, (rect.height * pageSize.height).round()),
);

/// [content] 按 contain 等比放进 [box] 后，在 [box] 内的像素矩形（居中）。
/// 任一尺寸为 0 时返回零矩形（还没量到布局 / 页图尺寸未知）。
Rect containRect(Size content, Size box) {
  if (content.width <= 0 ||
      content.height <= 0 ||
      box.width <= 0 ||
      box.height <= 0) {
    return Rect.zero;
  }
  final double scale = math.min(
    box.width / content.width,
    box.height / content.height,
  );
  final double w = content.width * scale;
  final double h = content.height * scale;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}
