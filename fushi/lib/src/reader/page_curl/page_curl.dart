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
/// 相邻页不存在（章首 / 章末、漫画首尾）时预览返回 false：本次不卷页，交回宿主的普通
/// 翻页路径（[PageCurlHost.fallbackTurn]，跨章照旧）。截图失败同样回落。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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

/// 卷页一次完整翻过去的时长：取速度档对应的 [FushiMotion] token 再放大一档
/// （卷页的位移是整页对角线、还要卷半圈，用平移的时长会显得「甩」过去）。
Duration pageCurlTurnDuration(PageTurnAnimationSpeed speed) =>
    speed.curlDuration;

/// 卷页的几何快照（全部在「未镜像空间」：书脊在左，拎起的角在右）。
@immutable
class PageCurlGeometry {
  const PageCurlGeometry({
    required this.corner,
    required this.point,
    required this.mirror,
  });

  /// 被拎起的角（纸面上的原位置）。
  final Offset corner;

  /// 那个角当前所在的位置。等于 [corner] = 纸面平铺；在书脊另一侧一整页宽 = 完全翻过。
  final Offset point;

  /// 从右往左读：整套几何水平镜像。
  final bool mirror;
}

/// 卷页圆柱半径：视口短边的 12%。
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

/// 落定动画期间到达的新拖动（等上一页快进完再开）。
class _QueuedDrag {
  _QueuedDrag({
    required this.start,
    required this.size,
    required this.forward,
    required this.mirror,
  });

  final Offset start;
  final Size size;
  final bool forward;
  final bool mirror;
  Offset? latest;
  ({Offset position, double velocity})? end;
  bool cancelled = false;
}

/// 一次卷页会话的可视状态，覆盖层只读它。
class PageCurlController extends ChangeNotifier {
  PageCurlController({required this.host, required this.duration});

  final PageCurlHost host;

  /// 一次完整翻页的时长（每次取用，跟随设置实时变化）。
  final Duration Function() duration;

  _CurlPhase _phase = _CurlPhase.idle;
  int _generation = 0;
  Size _size = Size.zero;
  bool _forward = true;
  bool _mirror = false;
  double _y0 = 0;
  Offset _start = Offset.zero;
  Offset _finger = Offset.zero;
  Offset _point = Offset.zero;
  ui.Image? _sheet;
  ui.Image? _base;
  bool _visible = false;

  /// 松手先于准备完成到达时暂存。
  ({Offset position, double velocity})? _pendingEnd;
  bool _pendingCancel = false;
  Ticker? _ticker;
  Completer<void>? _settled;

  /// 覆盖层是否要画（会话进行中且已有纸面）。
  bool get visible => _visible && _sheet != null;

  /// 正在卷页（含准备 / 落定动画）。宿主据此暂停自己的进度采样等。
  bool get active => _phase != _CurlPhase.idle;

  ui.Image? get sheet => _sheet;
  ui.Image? get base => _base;

  PageCurlGeometry get geometry => PageCurlGeometry(
    corner: Offset(_size.width, _y0),
    point: _point,
    mirror: _mirror,
  );

  /// 开始一次跟手卷页。[position] 为覆盖层坐标（逻辑像素），[mirror] 为从右往左读。
  /// 返回 false = 本次不卷页（不支持 / 已有会话）。
  bool dragStart({
    required Offset position,
    required Size size,
    required bool forward,
    required bool mirror,
  }) {
    if (size.isEmpty) return false;
    // 上一页还在落定：快进它，这一拖排在后面接着开（连续快速滑动不丢手势）。
    if (_phase == _CurlPhase.settling) {
      final _QueuedDrag queued = _QueuedDrag(
        start: position,
        size: size,
        forward: forward,
        mirror: mirror,
      );
      _queuedDrag = queued;
      unawaited(
        finish().then((_) {
          if (!identical(_queuedDrag, queued)) return;
          _queuedDrag = null;
          if (queued.cancelled || _phase != _CurlPhase.idle) return;
          dragStart(
            position: queued.start,
            size: queued.size,
            forward: queued.forward,
            mirror: queued.mirror,
          );
          final Offset? latest = queued.latest;
          if (latest != null) dragUpdate(latest);
          final ({Offset position, double velocity})? end = queued.end;
          if (end != null) dragEnd(end.position, end.velocity);
        }),
      );
      return true;
    }
    if (_phase != _CurlPhase.idle) return false;
    _beginSession(size: size, forward: forward, mirror: mirror);
    _dragSession = true;
    final Offset p = _unmirror(position);
    _start = p;
    _finger = p;
    _y0 = p.dy.clamp(0.0, size.height);
    _point = forward ? Offset(size.width, _y0) : pageCurlTurnedPoint(size, _y0);
    unawaited(_prepare(_generation, fromDrag: true));
    return true;
  }

  void dragUpdate(Offset position) {
    final _QueuedDrag? queued = _queuedDrag;
    if (queued != null) {
      queued.latest = position;
      return;
    }
    if (_phase != _CurlPhase.preparing && _phase != _CurlPhase.dragging) {
      return;
    }
    _finger = _unmirror(position);
    if (_phase == _CurlPhase.dragging) _followFinger();
  }

  /// 松手。[velocityX] 为屏幕坐标下的横向末段速度（px/ms）。
  void dragEnd(Offset position, double velocityX) {
    final _QueuedDrag? queued = _queuedDrag;
    if (queued != null) {
      queued.end = (position: position, velocity: velocityX);
      return;
    }
    if (_phase == _CurlPhase.preparing) {
      _finger = _unmirror(position);
      _pendingEnd = (position: position, velocity: velocityX);
      return;
    }
    if (_phase == _CurlPhase.idle) {
      _takeAbortedDragEnd(position, velocityX);
      return;
    }
    if (_phase != _CurlPhase.dragging) return;
    _finger = _unmirror(position);
    _followFinger();
    _release(velocityX);
  }

  /// 手势被系统 / 选词夺走：回卷。
  void dragCancel() {
    _abortedDrag = false;
    _queuedDrag?.cancelled = true;
    if (_phase == _CurlPhase.preparing) {
      _pendingCancel = true;
      return;
    }
    if (_phase != _CurlPhase.dragging) return;
    unawaited(_settle(commit: false));
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

  /// 当前会话由手指拖动发起（而非点按 / 按键）。
  bool _dragSession = false;

  Future<void> _turnNow({
    required Size size,
    required bool forward,
    required bool mirror,
  }) async {
    // 手指正按着卷页：这次点按 / 按键让位给手势。
    if (_dragSession &&
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
    _dragSession = false;
    _y0 = size.height * 0.88;
    _start = Offset(size.width, _y0);
    _finger = _start;
    _point = forward ? Offset(size.width, _y0) : pageCurlTurnedPoint(size, _y0);
    _pendingEnd = (position: Offset.zero, velocity: double.infinity);
    final Completer<void> committed = Completer<void>();
    _turnCommitted = committed;
    unawaited(_prepare(_generation, fromDrag: false));
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
    _size = size;
    _forward = forward;
    _mirror = mirror;
    _pendingEnd = null;
    _pendingCancel = false;
    _jumpToEnd = false;
    _settled = Completer<void>();
  }

  Offset _unmirror(Offset p) => _mirror ? Offset(_size.width - p.dx, p.dy) : p;

  /// 沿翻页方向拖过的距离（未镜像空间里前进 = 往左拖）。
  double get _progressPx =>
      _forward ? _start.dx - _finger.dx : _finger.dx - _start.dx;

  void _followFinger() {
    final Offset delta = _finger - _start;
    final Offset raw = _forward
        ? Offset(_size.width, _y0) + delta
        : pageCurlTurnedPoint(_size, _y0) + Offset(delta.dx * 2, delta.dy);
    // 往反方向拖：纸面留在起点（前进）/ 完全翻过（后退），不倒卷。
    final Offset bounded = _forward
        ? Offset(math.min(raw.dx, _size.width), raw.dy)
        : Offset(math.max(raw.dx, -_size.width), raw.dy);
    _point = clampPageCurlPoint(bounded, size: _size, y0: _y0);
    notifyListeners();
  }

  Future<void> _prepare(int generation, {required bool fromDrag}) async {
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
      }
      if (stale()) return;
      _phase = _CurlPhase.dragging;
      if (_pendingCancel) {
        await _settle(commit: false);
        return;
      }
      _followFinger();
      final ({Offset position, double velocity})? end = _pendingEnd;
      if (end != null) {
        _pendingEnd = null;
        if (fromDrag) {
          _release(end.velocity);
        } else {
          await _settle(commit: true);
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PageCurl.prepare', e, stack);
      if (!stale()) await _abort(generation);
    }
  }

  /// 本次不卷页：清掉覆盖层；拖动中途放弃的由松手再决定要不要普通翻页。
  Future<void> _abort(int generation) async {
    if (generation != _generation) return;
    final bool forward = _forward;
    final ({Offset position, double velocity})? end = _pendingEnd;
    final bool wasTap = end != null && end.velocity == double.infinity;
    final bool commit =
        wasTap ||
        (end != null &&
            !_pendingCancel &&
            pageCurlShouldCommit(
              progressPx: _progressPx,
              velocity: _directional(end.velocity),
              width: _size.width,
            ));
    if (end == null && !_pendingCancel) {
      // 手指还按着：等松手再判（dragEnd 在 aborted 态直接走普通翻页）。
      _phase = _CurlPhase.idle;
      _abortedDrag = true;
      _clearImages();
      _complete();
      return;
    }
    _phase = _CurlPhase.idle;
    _clearImages();
    _complete();
    if (commit) await host.fallbackTurn(forward: forward);
    _completeTurn();
  }

  bool _abortedDrag = false;
  _QueuedDrag? _queuedDrag;

  /// 拖动中途放弃了卷页（截图失败 / 没有相邻页）后的松手：按普通滑动判提交并走
  /// 普通翻页。返回是否消费了这次松手。
  bool _takeAbortedDragEnd(Offset position, double velocityX) {
    if (!_abortedDrag) return false;
    _abortedDrag = false;
    _finger = _unmirror(position);
    if (pageCurlShouldCommit(
      progressPx: _progressPx,
      velocity: _directional(velocityX),
      width: _size.width,
    )) {
      unawaited(host.fallbackTurn(forward: _forward));
    }
    return true;
  }

  /// 屏幕坐标速度 → 沿翻页方向的速度。
  double _directional(double velocityX) {
    final double v = _mirror ? -velocityX : velocityX;
    return _forward ? -v : v;
  }

  void _release(double velocityX) {
    final bool commit = pageCurlShouldCommit(
      progressPx: _progressPx,
      velocity: _directional(velocityX),
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
    // 点按 / 按键：从静止起步，两头缓；松手接力：手指已带着速度，直接减速收尾。
    final double eased =
        (_settleFromRest ? Curves.easeInOutCubic : Curves.easeOutCubic)
            .transform(t);
    final Offset p = Offset.lerp(_settleFrom, _settleTo, eased)!;
    // 翻过去的途中略微抬高，卷出弧线而不是平推。
    final double lift = math.sin(eased * math.pi) * _size.height * 0.04;
    _point = clampPageCurlPoint(
      Offset(p.dx, p.dy - lift),
      size: _size,
      y0: _y0,
    );
    notifyListeners();
    if (t >= 1.0) {
      _ticker?.stop();
      _point = _settleTo;
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
        _clearImages();
        _complete();
      }
    }
  }

  void _clearImages() {
    final ui.Image? sheet = _sheet;
    final ui.Image? base = _base;
    _sheet = null;
    _base = null;
    _visible = false;
    if (!identical(sheet, base)) sheet?.dispose();
    base?.dispose();
    notifyListeners();
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
    final ui.Image? sheet = _sheet;
    final ui.Image? base = _base;
    _sheet = null;
    _base = null;
    if (!identical(sheet, base)) sheet?.dispose();
    base?.dispose();
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
    required this.geometry,
    required this.paperColor,
  });

  final ui.FragmentShader shader;
  final ui.Image sheet;
  final ui.Image? base;
  final PageCurlGeometry geometry;
  final Color paperColor;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, geometry.corner.dx)
      ..setFloat(3, geometry.corner.dy)
      ..setFloat(4, geometry.point.dx)
      ..setFloat(5, geometry.point.dy)
      ..setFloat(6, pageCurlRadiusFor(size))
      ..setFloat(7, geometry.mirror ? 1 : 0)
      ..setFloat(8, base != null ? 1 : 0)
      ..setFloat(9, paperColor.r)
      ..setFloat(10, paperColor.g)
      ..setFloat(11, paperColor.b)
      // 背面透出正文的程度（实体纸背只隐约透字）。
      ..setFloat(12, 0.07)
      ..setImageSampler(0, sheet)
      ..setImageSampler(1, base ?? sheet);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PageCurlPainter old) => true;
}
