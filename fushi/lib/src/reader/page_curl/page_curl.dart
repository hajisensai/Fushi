/// 阅读器「卷页」翻页（仿实体书卷页）：小说与漫画两个阅读器共用的 Flutter 层实现。
///
/// 两个阅读器的正文都在 WebView 里，CSS 做不出真正的圆柱卷曲，所以卷页画在
/// WebView **上面**的 Flutter 覆盖层：翻页那一刻截一张当前页（WebView 截图），交给
/// `shaders/page_curl.frag` 按手指位置卷起来；WebView 自己提前**瞬时**落到目标页，
/// 卷起的纸后面露出的就是活的下一页。
///
/// 一次卷页的生命周期（[PageCurlController]）：
///
/// 1. **准备**：截当前页 → 覆盖层盖住整个视口（此时看起来什么都没变）→ 宿主把正文
///    瞬时预览到相邻页（[PageCurlHost.previewNeighbour]，不记任何翻页账）→ 等一帧绘制。
///    往回翻时卷的是上一页：先截当前页当底图盖住，预览到上一页后再截一张当纸面。
/// 2. **跟手**：手指位置实时驱动卷曲（准备期间的移动只记最新位置，就绪后直接跳到手指处）。
/// 3. **松手**：拖过视口宽 [kPageTurnFollowCommitFraction] 或甩速超过
///    [kPageTurnFollowFlingVelocity] 即提交——**立刻**走宿主正常的翻页记账
///    （[PageCurlHost.commitTurn]：进度 / 统计 / 跨章判定只在这里记一次），再把剩余的
///    卷曲播完；否则回卷并撤销预览（[PageCurlHost.revertPreview]）。
///
/// **双页**（一屏左右两页，[PageCurlPaper.facing] 非 null）时像实体书一样只翻外侧那一页：
/// 纸面 = 外侧页，书脊 = 两页之间的中缝；对面那页在纸翻过来盖住它之前保持原样（取自
/// 翻页前的快照），纸背是翻过去之后落在对面的那一页（前进时预览落定后再截一张相邻
/// 跨页，往回翻时就是翻页前的底图），翻完覆盖层撤掉时与活的正文逐像素接上、不闪。
///
/// 相邻页不存在（章首 / 章末、漫画首尾）时预览返回 false：本次不卷页，交回宿主的普通
/// 翻页路径（点按 / 按键走 [PageCurlHost.fallbackTurn]，跨章照旧）。截图失败同样回落。
///
/// 手指拖动的每一次事件都绑定在 [PageCurlController.dragStart] 返回的
/// [PageCurlDrag] 句柄上，只作用于它自己发起的会话；没被卷页接住的拖动（会话忙 /
/// 宿主在飞 / 中途放弃）松手时按普通滑动交给 [PageCurlHost.swipeTurn]。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart' show Easing;

import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 阅读器为卷页提供的能力。所有方法都在 UI isolate 上调用，失败要自己吞掉并返回
/// 「做不到」，控制器据此回落。
abstract interface class PageCurlHost {
  /// 此刻能不能起一次卷页会话：正文已就绪、没有换章 / 恢复在飞。连按排队的翻页
  /// 轮到执行时上一页可能刚触发了换章——加载中的页面上截图 / 预览 / 执行 JS 都不可靠
  /// （Android 上 evaluateJavascript 可能永不返回），这时控制器直接交给
  /// [fallbackTurn]，由宿主按自己的在飞闸门排队或执行。
  bool get canCurl;

  /// 截当前视口（WebView 截图后解码）。失败返回 null。
  Future<ui.Image?> capturePage();

  /// 此刻正文显示的页面在覆盖层里的位置（屏幕坐标，逻辑像素）。只有
  /// [PageCurlPaper.rect] 是「纸」：卷起来的只有它，矩形外（漫画的黑边）不卷、直接露出
  /// 下面。null = 整个视口都是一张纸（小说单页）。往回翻时在预览到上一页之后调用，
  /// 量的是上一页。
  Future<PageCurlPaper?> paperRect();

  /// 把正文**瞬时**落到相邻页，只做预览、不记翻页账。返回 false = 那个方向没有
  /// 相邻页（章首 / 章末），本次不卷页。
  Future<bool> previewNeighbour({required bool forward});

  /// 撤销 [previewNeighbour]，正文回到原页。
  Future<void> revertPreview();

  /// 提交：走宿主正常的翻页路径记账（进度、统计、caret 重锚）。正文已经在目标页上，
  /// 宿主必须消费掉预览状态而不是再翻一页。
  Future<void> commitTurn({required bool forward});

  /// 不卷页时的普通翻页（章首 / 章末跨章、截图失败等）。宿主正在换章时须自行排队，
  /// 不能在加载中的页面上执行。
  Future<void> fallbackTurn({required bool forward});

  /// 一次手指滑动没被卷页接住（已有点按 / 按键会话、宿主在飞、卷页中途放弃、卷页此刻
  /// 不可用）且按滑动阈值要翻页时调用：走宿主与**不开卷页时同一条**滑动翻页入口（含
  /// 在飞排队 / 节流），被拒的手势与非卷页模式行为一致，不丢输入。
  Future<void> swipeTurn({required bool forward});

  /// 等正文把当前状态真正画上屏（WebView 双 rAF）。覆盖层撤掉前必须等它，否则会闪
  /// 一帧旧页。
  Future<void> waitForPaint();
}

/// 截图超过这个时长就放弃本次卷页（回落成普通翻页），不能让翻页本身卡住。
const Duration _kPageCurlCaptureBudget = Duration(milliseconds: 450);

/// 等 WebView 画完一帧的上限：窗口被遮挡 / 隐藏时 WebKit 的 rAF 会冻结（平台限制），
/// 这时不等画面直接撤覆盖层——窗口看不见，也就不会闪。
const Duration _kPageCurlPaintBudget = Duration(milliseconds: 250);

/// `callAsyncJavaScript` 的函数体：等两帧 rAF（当前状态真正画上屏）。
const String kPageCurlWaitForPaintBody =
    'await new Promise(function(resolve) {'
    ' requestAnimationFrame(function() { requestAnimationFrame(resolve); });'
    ' }); return true;';

/// 两个阅读器共用的 WebView 截图（JPEG 编码比 PNG 快得多，卷页途中看不出压缩）。
Future<ui.Image?> capturePageCurlWebView(
  InAppWebViewController? controller,
) async {
  if (controller == null) return null;
  try {
    final Uint8List? bytes = await controller
        .takeScreenshot(
          screenshotConfiguration: ScreenshotConfiguration(
            compressFormat: CompressFormat.JPEG,
            quality: 92,
          ),
        )
        .timeout(_kPageCurlCaptureBudget, onTimeout: () => null);
    return await decodePageCurlSnapshot(bytes);
  } catch (e, stack) {
    ErrorLogService.instance.log('PageCurl.capture', e, stack);
    return null;
  }
}

/// 两个阅读器共用的「等 WebView 画完一帧」。
Future<void> waitPageCurlWebViewPaint(
  InAppWebViewController? controller,
) async {
  if (controller == null) return;
  try {
    await controller
        .callAsyncJavaScript(functionBody: kPageCurlWaitForPaintBody)
        .timeout(_kPageCurlPaintBudget, onTimeout: () => null);
  } catch (e, stack) {
    ErrorLogService.instance.log('PageCurl.waitForPaint', e, stack);
  }
}

/// 截图解码成 [ui.Image]（PNG / JPEG 都行）。
Future<ui.Image?> decodePageCurlSnapshot(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (e, stack) {
    ErrorLogService.instance.log('PageCurl.decodeSnapshot', e, stack);
    return null;
  }
}

/// [PageCurlHost.paperRect] 的结果：翻动的纸面，以及双页时对面那一页。
@immutable
class PageCurlPaper {
  const PageCurlPaper(this.rect, {this.facing});

  /// 翻动的那张纸（屏幕坐标）。双页时是外侧页：从左往右读是右页、从右往左读是左页，
  /// 书脊（中缝）是它靠里的那条边。
  final Rect rect;

  /// 双页时对面那一页（屏幕坐标）：翻页过程中它不动，直到翻过来的纸盖住它。null = 单页。
  final Rect? facing;

  /// 是否双页。
  bool get spread => facing != null;

  @override
  bool operator ==(Object other) =>
      other is PageCurlPaper && other.rect == rect && other.facing == facing;

  @override
  int get hashCode => Object.hash(rect, facing);

  @override
  String toString() => 'PageCurlPaper($rect, facing: $facing)';
}

/// 双页时纸面 / 对面页的划分：[view] 在中缝 [spineX] 处一分为二，外侧那半是纸、
/// 靠里那半是对面页。[mirror] = 从右往左读（书脊在纸的右边，纸是左半）。中缝不在
/// 视口内时返回 null（按单页卷整个视口）。
PageCurlPaper? pageCurlSpreadPaper({
  required Size view,
  required double spineX,
  required bool mirror,
}) {
  if (view.isEmpty || !(spineX > 0 && spineX < view.width)) return null;
  final Rect left = Rect.fromLTRB(0, 0, spineX, view.height);
  final Rect right = Rect.fromLTRB(spineX, 0, view.width, view.height);
  return mirror
      ? PageCurlPaper(left, facing: right)
      : PageCurlPaper(right, facing: left);
}

/// 卷页的几何快照（[corner] / [point] 在纸面局部的「未镜像空间」：书脊在左，拎起的角
/// 在右）。
@immutable
class PageCurlGeometry {
  const PageCurlGeometry({
    required this.corner,
    required this.point,
    required this.mirror,
    required this.paper,
    required this.radius,
    this.facing,
  });

  /// 被拎起的角（纸面上的原位置）。
  final Offset corner;

  /// 那个角当前所在的位置。等于 [corner] = 纸面平铺；在书脊另一侧一整页宽 = 完全翻过。
  final Offset point;

  /// 从右往左读：整套几何水平镜像（在纸面矩形内镜像）。
  final bool mirror;

  /// 纸面在覆盖层里的矩形（屏幕坐标）。[corner] / [point] 是相对它的局部坐标：
  /// 原点在书脊那一侧的上角，x 朝拎起的角。
  final Rect paper;

  /// 此刻的卷曲圆柱半径（[constrainPageCurl] 按书脊约束收紧过）。
  final double radius;

  /// 双页时对面那一页（屏幕坐标，见 [PageCurlPaper.facing]）；null = 单页。
  final Rect? facing;
}

/// 纸背蒙在镜像正文上的纸色比例：纸背像苹果图书那样透出镜像的正文（用户
/// 2026-11-04），0.6 = 正文以约四成浓度透出。
const double kPageCurlBackVeil = 0.6;

/// 卷页圆柱半径：纸面短边的 12%。
double pageCurlRadiusFor(Size size) => size.shortestSide * 0.12;

/// 书脊约束：纸面不能被拉长，拎起的角离书脊（同一高度上的 x = 0）不超过一整页宽。
@visibleForTesting
Offset clampPageCurlPoint(
  Offset point, {
  required Size size,
  required double y0,
}) {
  final Offset spine = Offset(0, y0);
  final Offset v = point - spine;
  final double len = v.distance;
  if (len <= size.width || len == 0) return point;
  return spine + v * (size.width / len);
}

/// 「完全翻过」时角点的位置。
Offset pageCurlTurnedPoint(Size size, double y0) => Offset(-size.width, y0);

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

/// 书脊约束（苹果图书的「可拖动范围」）：纸是装订在书脊上的，卷起来的圆柱和
/// 翻起的那片都不能越过书脊（x = 0 那条边）。越过了着色器就会在书脊处切出缺口、
/// 台阶和三角形的「怪折痕」，也会出现整页斜着翻飞的极限姿态。
///
/// 判据：两个书脊角 S 都必须落在卷轴的平铺一侧。按着色器的轴线公式（轴线在角点
/// 中垂线朝 [point] 一侧再偏 πr/2）展开，等价于 |P − S|² ≤ |C − S|² − π·r·|C − P|。
/// 返回满足它、离 [point] 最近的角点位置（对两个圆交替投影），以及此刻能用的半径：
///
/// - 拖动（[settling] = false）：按完整半径约束，圆柱始终整根留在书脊右侧，手指拉过
///   头时书角停在可行区域的边上，翻起的面积仍跟着手指。
/// - 落定动画（[settling] = true）：只要求折痕不越过书脊（r = 0 的约束），快贴到书脊
///   时半径随之收紧——翻到底时卷成一条细线再平铺，而不是带着整根圆柱穿过书脊。
@visibleForTesting
({Offset point, double radius}) constrainPageCurl({
  required Offset corner,
  required Offset point,
  required Size size,
  required double radius,
  required bool settling,
}) {
  final List<Offset> spine = <Offset>[Offset.zero, Offset(0, size.height)];
  Offset p = point;
  for (int i = 0; i < 6; i++) {
    final double len = (corner - p).distance;
    final double r = settling ? 0.0 : math.min(radius, len / math.pi);
    for (final Offset s in spine) {
      final double rho = math.sqrt(
        math.max(0.0, (corner - s).distanceSquared - math.pi * r * len),
      );
      final Offset v = p - s;
      final double dist = v.distance;
      if (dist > rho && dist > 0) p = s + v * (rho / dist);
    }
  }
  double len = (corner - p).distance;
  if (len < 0.5) return (point: p, radius: radius);
  final Offset n = (corner - p) / len;
  double k = double.infinity;
  for (final Offset s in spine) {
    k = math.min(k, _dot(corner - s, n));
  }
  // 投影迭代的收尾保险：沿卷曲方向截到严格可行的长度。
  final double maxLen = math.max(
    0.0,
    settling ? 2 * k : (k >= math.pi * radius ? 2 * k - math.pi * radius : k),
  );
  if (len > maxLen) {
    p = corner - n * maxLen;
    len = maxLen;
  }
  final double r = math.max(
    0.0,
    math.min(radius, math.min(len / math.pi, (2 * k - len) / math.pi)),
  );
  return (point: p, radius: r);
}

/// 纸边追上手指所用的拖动距离（占纸面宽）：从页中间按下时，纸边先在这段距离里
/// 平滑追到手指下，之后贴着手指走（苹果图书的手感：手里捏着的是纸边）。
const double kPageCurlCatchUpFraction = 0.25;

/// 角点抬到手指高度所用的拖动距离（占纸面宽）。
const double kPageCurlLiftFraction = 0.5;

double _smoothstep(double edge0, double edge1, double x) {
  if (edge1 <= edge0) return x < edge0 ? 0 : 1;
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 按下点离被拎起的角多近（0 = 按在边缘中段，1 = 按在角附近）。决定角点抬向手指
/// 的程度：按在角附近拖出斜折痕（掀书角），按在中段保持竖直折痕。
@visibleForTesting
double pageCurlCornerWeight({
  required Size size,
  required double startY,
  required double cornerY,
}) {
  final double fromCorner =
      (startY - cornerY).abs() / math.max(1.0, size.height);
  return 1 - _smoothstep(0.2, 0.45, fromCorner);
}

/// 拖动按下时拎哪个角（纸面局部 y）：上半页拎上角，下半页拎下角（苹果图书）。
@visibleForTesting
double pageCurlCornerYFor(Size size, double startY) =>
    startY < size.height / 2 ? 0 : size.height;

/// 拖动跟手时角点的位置（纸面局部、未镜像空间，未做书脊约束）。
///
/// - 横向：前进时纸边从「按下点到纸边的距离」开始，在 [kPageCurlCatchUpFraction]
///   的拖动距离内平滑追到手指下，之后纸边就在手指下；后退时上一页的边以两倍速
///   从书脊另一侧拉回来（手指从左缘拖到右缘刚好铺平）。
/// - 纵向：手指的上下位移原样带给角点；另外按在角附近时，角点随拖动逐渐抬到手指
///   高度（[kPageCurlLiftFraction]），卷出斜的折痕，而不是整条竖线平推。
@visibleForTesting
Offset pageCurlFollowPoint({
  required Size size,
  required Offset start,
  required Offset finger,
  required double cornerY,
  required bool forward,
}) {
  final double w = size.width;
  final double weight = pageCurlCornerWeight(
    size: size,
    startY: start.dy,
    cornerY: cornerY,
  );
  final double progress = forward ? start.dx - finger.dx : finger.dx - start.dx;
  final double lift =
      (start.dy - cornerY) *
      weight *
      _smoothstep(0, kPageCurlLiftFraction * w, progress);
  final double y = cornerY + (finger.dy - start.dy) + lift;
  if (forward) {
    final double gap = math.max(0.0, w - start.dx);
    final double catchUp = _smoothstep(
      0,
      kPageCurlCatchUpFraction * w,
      progress,
    );
    final double x = finger.dx + gap * (1 - catchUp);
    // 往反方向拖：纸面留在起点，不倒卷。
    return Offset(math.min(x, w), y);
  }
  final double x = -w + 2 * (finger.dx - start.dx);
  return Offset(math.max(x, -w), y);
}

/// 由松手时的位移 / 速度判断是否提交（与平移 / 覆盖的拖动跟手同一阈值）。
///
/// [progressPx] = 沿翻页方向已经拖过的距离（向反方向拖为负），[velocity] = 沿翻页
/// 方向的末段速度（px/ms，反向为负）。
bool pageCurlShouldCommit({
  required double progressPx,
  required double velocity,
  required double width,
}) {
  if (progressPx <= 0) return false;
  if (velocity < -kPageTurnFollowFlingVelocity) return false;
  return progressPx > kPageTurnFollowCommitFraction * width ||
      velocity > kPageTurnFollowFlingVelocity;
}

enum _CurlPhase { idle, preparing, dragging, settling }

/// 一次手指拖动在控制器里的角色。
enum _DragRole {
  /// 上一页还在落定：等它快进完再开会话。
  queued,

  /// 正在驱动（或准备驱动）本次卷页会话。
  session,

  /// 没被卷页接住（会话忙 / 宿主在飞 / 中途放弃 / 卷页此刻不可用）：松手按普通滑动
  /// 判提交，交给 [PageCurlHost.swipeTurn]。
  swipe,

  /// 已经处理完（松手 / 取消已消费）。
  done,
}

/// 一次手指拖动的句柄（[PageCurlController.dragStart] 返回）。
///
/// 宿主把本次手势后续的 move / end / cancel 一律交回**这个句柄**：控制器只让它影响
/// 它自己发起的会话——同时在准备的点按 / 按键会话、或下一次拖动的会话，都不会被
/// 一条迟到 / 交错的事件改写。没被卷页接住的拖动不会作废，松手时按普通滑动翻页。
class PageCurlDrag {
  PageCurlDrag._({
    required PageCurlController owner,
    required this.start,
    required this.size,
    required this.forward,
    required this.mirror,
    required bool allowCurl,
  }) : _owner = owner,
       _allowCurl = allowCurl,
       latest = start;

  final PageCurlController _owner;

  /// 按下点（覆盖层坐标，屏幕方向）。
  final Offset start;
  final Size size;
  final bool forward;
  final bool mirror;
  final bool _allowCurl;
  _DragRole _role = _DragRole.swipe;

  /// 最近一次手指位置（覆盖层坐标）。
  Offset latest;
  ({Offset position, double velocity})? _end;
  bool _cancelled = false;

  /// 本次手势已松手或被取消。
  bool get finished => _end != null || _cancelled;

  /// 本次手势正由（或排队等着由）卷页跟手；false = 按普通滑动处理。
  bool get curling => _role == _DragRole.queued || _role == _DragRole.session;

  void update(Offset position) => _owner._dragUpdate(this, position);

  /// 松手。[velocityX] 为屏幕坐标下的横向末段速度（px/ms）。
  void end(Offset position, double velocityX) =>
      _owner._dragEnd(this, position, velocityX);

  /// 手势被系统 / 选词夺走：回卷，不翻页。
  void cancel() => _owner._dragCancel(this);

  Offset _unmirror(Offset p) => mirror ? Offset(size.width - p.dx, p.dy) : p;

  /// 普通滑动口径：沿翻页方向拖过的距离与末段速度是否够翻页。
  bool _swipeCommits(Offset position, double velocityX) {
    final Offset s = _unmirror(start);
    final Offset p = _unmirror(position);
    final double progress = forward ? s.dx - p.dx : p.dx - s.dx;
    final double v = mirror ? -velocityX : velocityX;
    return pageCurlShouldCommit(
      progressPx: progress,
      velocity: forward ? -v : v,
      width: size.width,
    );
  }
}

/// 一次卷页会话的可视状态，覆盖层只读它。
class PageCurlController extends ChangeNotifier {
  PageCurlController({required this.host, required this.duration});

  final PageCurlHost host;

  /// 一次完整翻页的时长（每次取用，跟随设置实时变化）。
  final Duration Function() duration;

  _CurlPhase _phase = _CurlPhase.idle;
  int _generation = 0;

  /// 覆盖层（视口）尺寸。
  Size _view = Size.zero;

  /// 纸面在覆盖层里的矩形（屏幕坐标）。会话开始时是整个视口，准备阶段由
  /// [PageCurlHost.paperRect] 收窄到真正的页面（漫画留黑边时只卷页图本身）。
  Rect _paper = Rect.zero;

  /// 双页时对面那一页（[PageCurlPaper.facing]）；单页为 null。
  Rect? _facing;
  bool _forward = true;
  bool _mirror = false;

  /// 以下几何量都在「纸面局部、未镜像」空间：原点是纸面左上角（镜像时是右上角），
  /// 书脊在 x = 0，拎起的角在 x = 纸面宽。
  double _y0 = 0;

  /// 按下点 / 手指当前位置（屏幕坐标）。纸面矩形在准备阶段才确定，所以存屏幕坐标、
  /// 用时再换算。
  Offset _startScreen = Offset.zero;
  Offset _fingerScreen = Offset.zero;
  Offset _point = Offset.zero;

  Size get _size => _paper.size;
  Offset get _start => _toPaper(_startScreen);
  Offset get _finger => _toPaper(_fingerScreen);
  ui.Image? _sheet;
  ui.Image? _base;

  /// 双页的纸背：纸翻过去后落在对面的那一页。前进时是预览落定后另截的相邻跨页；
  /// 往回翻时与 [_base]（翻页前的当前跨页）是同一张图。单页为 null（纸背透出镜像
  /// 正文）。
  ui.Image? _back;
  bool _visible = false;

  /// 当前会话由哪一次手指拖动发起；null = 点按 / 按键会话（或空闲）。拖动事件只在
  /// 句柄与它相同时才作用于会话。
  PageCurlDrag? _sessionDrag;
  Ticker? _ticker;
  Completer<void>? _settled;

  /// 覆盖层是否要画（会话进行中且已有纸面）。
  bool get visible => _visible && _sheet != null;

  /// 正在卷页（含准备 / 落定动画）。宿主据此暂停自己的进度采样等。
  bool get active => _phase != _CurlPhase.idle;

  ui.Image? get sheet => _sheet;
  ui.Image? get base => _base;

  /// 双页的纸背（见 [_back]）；单页或还没截到时为 null。
  ui.Image? get back => _facing == null ? null : _back;

  PageCurlGeometry get geometry => PageCurlGeometry(
    corner: Offset(_size.width, _y0),
    point: _point,
    mirror: _mirror,
    paper: _paper,
    radius: _radius,
    facing: _facing,
  );

  /// 当前圆柱半径（书脊约束收紧过）。
  double _radius = 0;

  /// 把 [raw] 按书脊约束落成角点位置与半径。
  void _placePoint(Offset raw, {required bool settling}) {
    final ({Offset point, double radius}) c = constrainPageCurl(
      corner: Offset(_size.width, _y0),
      point: clampPageCurlPoint(raw, size: _size, y0: _y0),
      size: _size,
      radius: pageCurlRadiusFor(_size),
      settling: settling,
    );
    _point = c.point;
    _radius = c.radius;
  }

  /// 开始一次手指拖动。[position] 为按下点（覆盖层坐标，逻辑像素），[mirror] 为从右
  /// 往左读，[allowCurl] = 宿主此刻是否用卷页（false 时整次手势按普通滑动处理）。
  ///
  /// 总是返回一个句柄，本次手势后续事件都交给它：能卷就开会话（上一页还在落定时排在
  /// 它后面），卷不了（已有点按 / 按键会话在准备或落定、宿主在飞、卷页关闭）就按普通
  /// 滑动处理——不会悄悄作废，也不会改写别的会话。
  PageCurlDrag dragStart({
    required Offset position,
    required Size size,
    required bool forward,
    required bool mirror,
    bool allowCurl = true,
  }) {
    final PageCurlDrag drag = PageCurlDrag._(
      owner: this,
      start: position,
      size: size,
      forward: forward,
      mirror: mirror,
      allowCurl: allowCurl && !size.isEmpty,
    );
    if (!drag._allowCurl) return drag;
    // 上一页还在落定：快进它，这一拖排在后面接着开（连续快速滑动不丢手势）。
    if (_phase == _CurlPhase.settling) {
      drag._role = _DragRole.queued;
      unawaited(finish().then((_) => _promoteQueuedDrag(drag)));
      return drag;
    }
    if (_phase == _CurlPhase.idle && host.canCurl) _startDragSession(drag);
    return drag;
  }

  /// 落定快进完：排队的拖动开会话；那时已有别的会话 / 宿主在飞就转普通滑动。
  void _promoteQueuedDrag(PageCurlDrag drag) {
    if (drag._role != _DragRole.queued) return;
    if (drag._cancelled) {
      drag._role = _DragRole.done;
      return;
    }
    if (_phase == _CurlPhase.idle && host.canCurl) {
      _startDragSession(drag);
      return;
    }
    drag._role = _DragRole.swipe;
    final ({Offset position, double velocity})? end = drag._end;
    if (end != null) _swipeEnd(drag, end.position, end.velocity);
  }

  void _startDragSession(PageCurlDrag drag) {
    _beginSession(size: drag.size, forward: drag.forward, mirror: drag.mirror);
    _sessionDrag = drag;
    drag._role = _DragRole.session;
    _startScreen = drag.start;
    _fingerScreen = drag._end?.position ?? drag.latest;
    _anchorToPaper();
    unawaited(_prepare(_generation));
  }

  bool _owns(PageCurlDrag drag) =>
      identical(_sessionDrag, drag) && drag._role == _DragRole.session;

  void _dragUpdate(PageCurlDrag drag, Offset position) {
    if (drag.finished) return;
    drag.latest = position;
    if (!_owns(drag)) return;
    if (_phase != _CurlPhase.preparing && _phase != _CurlPhase.dragging) {
      return;
    }
    _fingerScreen = position;
    if (_phase == _CurlPhase.dragging) _followFinger();
  }

  void _dragEnd(PageCurlDrag drag, Offset position, double velocityX) {
    if (drag.finished) return;
    drag.latest = position;
    drag._end = (position: position, velocity: velocityX);
    switch (drag._role) {
      case _DragRole.queued:
      case _DragRole.done:
        // 排队的由 [_promoteQueuedDrag] 接着处理。
        return;
      case _DragRole.swipe:
        _swipeEnd(drag, position, velocityX);
        return;
      case _DragRole.session:
        if (!_owns(drag)) return;
        _fingerScreen = position;
        // 准备中：[_prepare] 就绪后读 drag._end 接着松手。
        if (_phase != _CurlPhase.dragging) return;
        drag._role = _DragRole.done;
        _followFinger();
        _release(velocityX);
    }
  }

  void _dragCancel(PageCurlDrag drag) {
    if (drag.finished) return;
    drag._cancelled = true;
    switch (drag._role) {
      case _DragRole.queued:
        return;
      case _DragRole.swipe:
      case _DragRole.done:
        drag._role = _DragRole.done;
        return;
      case _DragRole.session:
        if (!_owns(drag)) return;
        // 准备中：[_prepare] 就绪后读 drag._cancelled 回卷。
        if (_phase != _CurlPhase.dragging) return;
        drag._role = _DragRole.done;
        unawaited(_settle(commit: false));
    }
  }

  /// 没被卷页接住的拖动松手：按普通滑动判，够了就走宿主的滑动翻页入口。
  void _swipeEnd(PageCurlDrag drag, Offset position, double velocityX) {
    drag._role = _DragRole.done;
    if (!drag._swipeCommits(position, velocityX)) return;
    unawaited(
      host.swipeTurn(forward: drag.forward).catchError((
        Object e,
        StackTrace stack,
      ) {
        ErrorLogService.instance.log('PageCurl.swipeTurn', e, stack);
      }),
    );
  }

  /// 点按 / 按键翻页：完整播一次卷页，在这一页记账（提交或回落）后完成。
  ///
  /// 连按串行排队：每一次都排在上一次记账之后执行（上一页还在播的落定动画被快进），
  /// 一次都不丢——上一次还在截图 / 预览（准备阶段）时到达的按键也只是排队。
  Future<void> turn({
    required Size size,
    required bool forward,
    required bool mirror,
  }) {
    final Future<void> run = _turnTail.then(
      (_) => _turnNow(size: size, forward: forward, mirror: mirror),
    );
    _turnTail = run.catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log('PageCurl.turn', e, stack);
    });
    return run;
  }

  Future<void> _turnTail = Future<void>.value();

  Future<void> _turnNow({
    required Size size,
    required bool forward,
    required bool mirror,
  }) async {
    // 手指正按着卷页：这次点按 / 按键让位给手势。
    if (_sessionDrag != null &&
        (_phase == _CurlPhase.preparing || _phase == _CurlPhase.dragging)) {
      return;
    }
    await finish();
    // 快进收尾期间手指又按下开始了新的拖动：同样让位。
    if (_phase != _CurlPhase.idle) return;
    if (size.isEmpty || !host.canCurl) {
      await host.fallbackTurn(forward: forward);
      return;
    }
    _completeTurn();
    _beginSession(size: size, forward: forward, mirror: mirror);
    // 点按 / 按键没有手指：起止点重合，卷曲完全由落定动画驱动。
    _startScreen = Offset(size.width, size.height);
    _fingerScreen = _startScreen;
    _anchorToPaper();
    final Completer<void> committed = Completer<void>();
    _turnCommitted = committed;
    unawaited(_prepare(_generation));
    // 只等到记账完成（或回落完成），卷页动画自己播完，连按时由 [finish] 快进。
    await committed.future;
  }

  Completer<void>? _turnCommitted;

  void _completeTurn() {
    final Completer<void>? c = _turnCommitted;
    _turnCommitted = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 立刻结束在播的落定动画（连按 / 新手势按下）。准备中的会话不受影响。
  Future<void> finish() async {
    final Completer<void>? settled = _settled;
    if (_phase == _CurlPhase.settling) {
      _jumpToEnd = true;
      final Ticker? ticker = _ticker;
      if (ticker != null && ticker.isActive) {
        ticker.stop();
        _settleStep(Duration.zero, forceEnd: true);
      }
    }
    if (settled != null) await settled.future;
  }

  void _beginSession({
    required Size size,
    required bool forward,
    required bool mirror,
  }) {
    _completeTurn();
    _generation++;
    _phase = _CurlPhase.preparing;
    _sessionDrag = null;
    _view = size;
    _paper = Offset.zero & size;
    _facing = null;
    _forward = forward;
    _mirror = mirror;
    _jumpToEnd = false;
    _settled = Completer<void>();
  }

  /// 屏幕坐标 → 纸面局部、未镜像坐标。
  Offset _toPaper(Offset p) {
    final double x = p.dx - _paper.left;
    return Offset(_mirror ? _paper.width - x : x, p.dy - _paper.top);
  }

  /// 按当前纸面矩形定卷曲的起点：拖动拎离按下点近的那个真角（上半页上角、下半页
  /// 下角），点按 / 按键拎下角；角点回到「平铺」（前进）或「完全翻过」（后退）。
  void _anchorToPaper() {
    _y0 = _sessionDrag == null
        ? _size.height
        : pageCurlCornerYFor(_size, _start.dy);
    _point = _forward
        ? Offset(_size.width, _y0)
        : pageCurlTurnedPoint(_size, _y0);
    // 平铺时半径无所谓（着色器直接画平面）；完全翻过时卷轴贴在书脊上，半径为 0。
    _radius = _forward ? pageCurlRadiusFor(_size) : 0;
  }

  /// 收窄纸面到宿主报告的页面矩形（与视口取交集；拿不到 / 太小就保持整个视口），
  /// 双页时记下对面那一页。
  Future<void> _resolvePaper() async {
    PageCurlPaper? reported;
    try {
      reported = await host.paperRect();
    } catch (e, stack) {
      ErrorLogService.instance.log('PageCurl.paperRect', e, stack);
    }
    final Rect view = Offset.zero & _view;
    bool usable(Rect r) => r.width >= 8 && r.height >= 8;
    final Rect? rect = reported?.rect.intersect(view);
    if (rect == null || !usable(rect)) {
      _paper = view;
      _facing = null;
    } else {
      _paper = rect;
      final Rect? facing = reported?.facing?.intersect(view);
      _facing = facing != null && usable(facing) ? facing : null;
    }
    _anchorToPaper();
  }

  /// 沿翻页方向拖过的距离（未镜像空间里前进 = 往左拖）。
  double get _progressPx =>
      _forward ? _start.dx - _finger.dx : _finger.dx - _start.dx;

  void _followFinger() {
    final Offset raw = pageCurlFollowPoint(
      size: _size,
      start: _start,
      finger: _finger,
      cornerY: _y0,
      forward: _forward,
    );
    // 往回翻是从「整页已翻过」拉回来：按落定口径让半径从书脊处由 0 长起来，
    // 不然一按下书脊上就凭空冒出一整根圆柱。
    _placePoint(raw, settling: !_forward);
    notifyListeners();
  }

  Future<void> _prepare(int generation) async {
    bool stale() => generation != _generation;
    try {
      if (_forward) {
        final ui.Image? sheet = await host.capturePage();
        if (stale()) {
          sheet?.dispose();
          return;
        }
        if (sheet == null) {
          await _abort(generation);
          return;
        }
        await _resolvePaper();
        if (stale()) {
          sheet.dispose();
          return;
        }
        _sheet = sheet;
        _visible = true;
        notifyListeners();
        await SchedulerBinding.instance.endOfFrame;
        if (stale()) return;
        if (!await host.previewNeighbour(forward: true)) {
          await _abort(generation);
          return;
        }
        if (stale()) return;
        await host.waitForPaint();
        if (stale()) return;
        if (_facing != null) {
          // 双页：纸背 = 翻过去后落在对面的那一页，取自已落定的相邻跨页。截不到就
          // 按单页画法卷（对面页露出活的正文），不中断这次翻页。
          final ui.Image? back = await host.capturePage();
          if (stale()) {
            back?.dispose();
            return;
          }
          _back = back;
        }
      } else {
        final ui.Image? base = await host.capturePage();
        if (stale()) {
          base?.dispose();
          return;
        }
        if (base == null) {
          await _abort(generation);
          return;
        }
        _base = base;
        // 底图先当纸面画出来（纸面完全翻过 = 只剩底图），盖住预览时的跳页。
        _sheet = base;
        _visible = true;
        notifyListeners();
        await SchedulerBinding.instance.endOfFrame;
        if (stale()) return;
        if (!await host.previewNeighbour(forward: false)) {
          await _abort(generation);
          return;
        }
        if (stale()) return;
        await host.waitForPaint();
        if (stale()) return;
        // 卷的是上一页：纸面矩形按上一页量。
        await _resolvePaper();
        if (stale()) return;
        final ui.Image? sheet = await host.capturePage();
        if (stale()) {
          sheet?.dispose();
          return;
        }
        if (sheet == null) {
          await host.revertPreview();
          await _abort(generation);
          return;
        }
        _sheet = sheet;
        // 双页往回翻：纸背是翻页前的当前跨页（翻回来的纸原先就盖在它对面）。
        if (_facing != null) _back = base;
      }
      if (stale()) return;
      _phase = _CurlPhase.dragging;
      final PageCurlDrag? drag = _sessionDrag;
      if (drag == null) {
        // 点按 / 按键：直接完整翻过去。
        _followFinger();
        await _settle(commit: true);
        return;
      }
      if (drag._cancelled) {
        drag._role = _DragRole.done;
        await _settle(commit: false);
        return;
      }
      _followFinger();
      final ({Offset position, double velocity})? end = drag._end;
      if (end != null) {
        // 准备期间就松手了：按松手点接着判。
        drag._role = _DragRole.done;
        _release(end.velocity);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PageCurl.prepare', e, stack);
      if (!stale()) await _abort(generation);
    }
  }

  /// 本次不卷页（截图失败 / 没有相邻页）：清掉覆盖层。点按 / 按键交给宿主的普通翻页；
  /// 拖动转为普通滑动，由它自己的松手（已松手的立刻）判要不要翻。
  Future<void> _abort(int generation) async {
    if (generation != _generation) return;
    final bool forward = _forward;
    final PageCurlDrag? drag = _sessionDrag;
    _sessionDrag = null;
    _phase = _CurlPhase.idle;
    _clearImages();
    _complete();
    if (drag == null) {
      try {
        await host.fallbackTurn(forward: forward);
      } finally {
        _completeTurn();
      }
      return;
    }
    if (drag._cancelled) {
      drag._role = _DragRole.done;
      return;
    }
    drag._role = _DragRole.swipe;
    final ({Offset position, double velocity})? end = drag._end;
    if (end != null) _swipeEnd(drag, end.position, end.velocity);
  }

  void _release(double velocityX) {
    final double v = _mirror ? -velocityX : velocityX;
    final bool commit = pageCurlShouldCommit(
      progressPx: _progressPx,
      velocity: _forward ? -v : v,
      width: _size.width,
    );
    unawaited(_settle(commit: commit));
  }

  bool _settleCommit = false;
  bool _settleFromRest = false;
  Offset _settleFrom = Offset.zero;
  Offset _settleTo = Offset.zero;
  Duration _settleDuration = Duration.zero;
  bool _jumpToEnd = false;

  Future<void> _settle({required bool commit}) async {
    final int generation = _generation;
    _phase = _CurlPhase.settling;
    _settleCommit = commit;
    final bool landsTurned = commit == _forward;
    _settleFrom = _point;
    _settleFromRest =
        _settleFrom == Offset(_size.width, _y0) ||
        _settleFrom == pageCurlTurnedPoint(_size, _y0);
    _settleTo = landsTurned
        ? pageCurlTurnedPoint(_size, _y0)
        : Offset(_size.width, _y0);
    final double span = 2 * _size.width;
    final double remaining = (_settleTo - _settleFrom).distance;
    final int full = duration().inMilliseconds;
    _settleDuration = Duration(
      milliseconds: math.max(
        60,
        (full * math.min(1.0, remaining / math.max(1.0, span))).round(),
      ),
    );
    // 提交即记账：进度 / 统计 / 跨章判定与普通翻页同一条路径，不等动画播完。
    if (commit) {
      try {
        await host.commitTurn(forward: _forward);
      } catch (e, stack) {
        ErrorLogService.instance.log('PageCurl.commitTurn', e, stack);
      }
      _completeTurn();
      if (generation != _generation) return;
    } else {
      _completeTurn();
    }
    if (_jumpToEnd) {
      _point = _settleTo;
      _radius = 0;
      await _finishSettle(generation);
      return;
    }
    _ticker?.dispose();
    _ticker = Ticker(_onSettleTick, debugLabel: 'PageCurlController.settle');
    _ticker!.start();
  }

  void _onSettleTick(Duration elapsed) => _settleStep(elapsed, forceEnd: false);

  void _settleStep(Duration elapsed, {required bool forceEnd}) {
    if (_phase != _CurlPhase.settling) return;
    final double t = forceEnd || _settleDuration == Duration.zero
        ? 1.0
        : (elapsed.inMicroseconds / _settleDuration.inMicroseconds).clamp(
            0.0,
            1.0,
          );
    // M3 缓动 token（三次贝塞尔，不过冲——落点越界会把卷页顶点推出页外、抬升弧
    // 变负）。点按 / 按键从静止起步：standard 两头缓。松手接力时手指已带着速度：
    // standardDecelerate 起点速度最大、直接减速收尾。不用弹簧 token：静止起步的
    // 临界阻尼弹簧起点速度为 0，接力时页面会先顿住再加速。
    final double eased =
        (_settleFromRest ? Easing.standard : Easing.standardDecelerate)
            .transform(t);
    final Offset p = Offset.lerp(_settleFrom, _settleTo, eased)!;
    // 翻过去的途中把角往页心抬，卷出弧线而不是平推。点按 / 按键从静止起翻：角从
    // 下角掀起、中途明显上弧再落平（苹果图书点按翻页）；松手接力时手指已带出了
    // 折痕的斜度，只补一点弧线。
    final double towardCenter = _y0 > _size.height / 2 ? -1.0 : 1.0;
    final double liftAmount = _settleFromRest ? 0.14 : 0.04;
    final double lift =
        math.sin(eased * math.pi) * _size.height * liftAmount * towardCenter;
    _placePoint(Offset(p.dx, p.dy + lift), settling: true);
    notifyListeners();
    if (t >= 1.0) {
      _ticker?.stop();
      _point = _settleTo;
      _radius = 0;
      unawaited(_finishSettle(_generation));
    }
  }

  bool _finishing = false;

  Future<void> _finishSettle(int generation) async {
    if (_finishing || generation != _generation) return;
    _finishing = true;
    try {
      if (!_settleCommit) {
        await host.revertPreview();
        await host.waitForPaint();
      } else if (_forward) {
        // 纸面已完全翻走，下面就是活的目标页，直接撤。
      } else {
        // 纸面已平铺盖满，正文早就在上一页上：等它画好再撤。
        await host.waitForPaint();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PageCurl.finishSettle', e, stack);
    } finally {
      _finishing = false;
      if (generation == _generation) {
        _phase = _CurlPhase.idle;
        _sessionDrag = null;
        _clearImages();
        _complete();
      }
    }
  }

  void _clearImages() {
    _disposeImages();
    _visible = false;
    notifyListeners();
  }

  /// 释放快照：[_sheet] / [_base] / [_back] 可能指向同一张图，每张只释放一次。
  void _disposeImages() {
    final Set<ui.Image> images = <ui.Image>{?_sheet, ?_base, ?_back};
    _sheet = null;
    _base = null;
    _back = null;
    for (final ui.Image image in images) {
      image.dispose();
    }
  }

  void _complete() {
    final Completer<void>? settled = _settled;
    _settled = null;
    if (settled != null && !settled.isCompleted) settled.complete();
  }

  @override
  void dispose() {
    _generation++;
    _completeTurn();
    _ticker?.dispose();
    _ticker = null;
    _disposeImages();
    _complete();
    super.dispose();
  }
}

Future<ui.FragmentProgram?>? _programLoad;

/// 预加载卷页着色器（阅读器打开时调一次，首次翻页不卡编译）。
Future<ui.FragmentProgram?> loadPageCurlProgram() {
  return _programLoad ??= ui.FragmentProgram.fromAsset('shaders/page_curl.frag')
      .then<ui.FragmentProgram?>(
        (ui.FragmentProgram p) => p,
        onError: (Object e, StackTrace s) {
          ErrorLogService.instance.log('PageCurl.loadProgram', e, s);
          _programLoad = null;
          return null;
        },
      );
}

/// 叠在 WebView 上的卷页覆盖层。不吃指针（手势由 WebView 里的 JS 转发给控制器）。
class PageCurlOverlay extends StatefulWidget {
  const PageCurlOverlay({
    super.key,
    required this.controller,
    required this.paperColor,
  });

  final PageCurlController controller;

  /// 纸张底色（阅读器背景），纸背面用它。
  final Color paperColor;

  @override
  State<PageCurlOverlay> createState() => _PageCurlOverlayState();
}

class _PageCurlOverlayState extends State<PageCurlOverlay> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    unawaited(
      loadPageCurlProgram().then((ui.FragmentProgram? program) {
        if (!mounted || program == null) return;
        setState(() => _shader = program.fragmentShader());
      }),
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (BuildContext context, Widget? child) {
          final ui.FragmentShader? shader = _shader;
          final ui.Image? sheet = widget.controller.sheet;
          if (!widget.controller.visible || shader == null || sheet == null) {
            return const SizedBox.expand();
          }
          return CustomPaint(
            key: const ValueKey<String>('fushi_page_curl_overlay'),
            size: Size.infinite,
            painter: _PageCurlPainter(
              shader: shader,
              sheet: sheet,
              base: widget.controller.base,
              back: widget.controller.back,
              geometry: widget.controller.geometry,
              paperColor: widget.paperColor,
            ),
          );
        },
      ),
    );
  }
}

class _PageCurlPainter extends CustomPainter {
  _PageCurlPainter({
    required this.shader,
    required this.sheet,
    required this.base,
    required this.back,
    required this.geometry,
    required this.paperColor,
  });

  final ui.FragmentShader shader;
  final ui.Image sheet;
  final ui.Image? base;

  /// 双页的纸背（[PageCurlController.back]）；null = 单页（纸背透出镜像正文）。
  final ui.Image? back;
  final PageCurlGeometry geometry;
  final Color paperColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect paper = geometry.paper;
    // 双页：对面页矩形 + 纸背快照都在时才按双页画（缺一个就退回单页画法）。
    final Rect? facing = back == null ? null : geometry.facing;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, paper.left)
      ..setFloat(3, paper.top)
      ..setFloat(4, paper.width)
      ..setFloat(5, paper.height)
      ..setFloat(6, geometry.corner.dx)
      ..setFloat(7, geometry.corner.dy)
      ..setFloat(8, geometry.point.dx)
      ..setFloat(9, geometry.point.dy)
      ..setFloat(10, geometry.radius)
      ..setFloat(11, geometry.mirror ? 1 : 0)
      ..setFloat(12, base != null ? 1 : 0)
      ..setFloat(13, paperColor.r)
      ..setFloat(14, paperColor.g)
      ..setFloat(15, paperColor.b)
      // 纸背：镜像正文上蒙的纸色比例。
      ..setFloat(16, kPageCurlBackVeil)
      ..setFloat(17, facing != null ? 1 : 0)
      ..setFloat(18, facing?.left ?? 0)
      ..setFloat(19, facing?.top ?? 0)
      ..setFloat(20, facing?.right ?? 0)
      ..setFloat(21, facing?.bottom ?? 0)
      ..setImageSampler(0, sheet)
      ..setImageSampler(1, base ?? sheet)
      ..setImageSampler(2, back ?? sheet);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PageCurlPainter old) => true;
}
