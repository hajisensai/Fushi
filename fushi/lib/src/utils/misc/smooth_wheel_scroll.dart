import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

/// 粗滚轮一档才需要补间；触控板 / 高精度滚轮本来就连续上报小 delta，再套一层动画
/// 只会拖尾，走原生同步路径。
///
/// 🔴 判据按**物理像素**（BUG-2867）。引擎发的是物理像素、框架 converter 再除以
/// devicePixelRatio 才交给 [PointerScrollEvent.scrollDelta]：
/// - Windows（flutter_window.cc `UpdateScrollOffsetMultiplier`）一档 =
///   `行数 × 100/3` 物理 px，系统默认 3 行即 100；
/// - Linux（fl_scrolling_manager.cc）一档 = `53 × 缩放` 物理 px。
///
/// 旧判据是逻辑 px `>= 80`：Windows 150% 缩放一档只剩 66.7、200% 只剩 50，Linux
/// 任何缩放都是 53——全被当成触控板，根部补间在高 DPI 机器上从未生效。高精度滚轮
/// 1/8 档约 12.5 物理 px，一档最少（每次 1 行）33 物理 px，阈值取两者之间。
///
/// macOS / 移动端：触控板与 Magic Mouse 走 `PointerPanZoom*`，根本不是
/// [PointerScrollEvent]；到这里的只剩物理滚轮，一律补间。
///
/// 🔴 分类只决定**要不要补间**，不决定距离（BUG-2009）：一档走多远是系统「每次
/// 滚动行数」设置说了算，app 只补插值、不打折。
bool isCoarseDesktopPointerScrollDelta(
  double delta, {
  required double devicePixelRatio,
}) =>
    !(Platform.isWindows || Platform.isLinux) ||
    delta.abs() * devicePixelRatio >= kCoarseWheelMinPhysicalDelta;

/// 粗滚轮一档的最小物理像素（见 [isCoarseDesktopPointerScrollDelta]）。
const double kCoarseWheelMinPhysicalDelta = 30;

const Duration kDesktopWheelScrollDuration = Duration(milliseconds: 140);

/// 见 [SmoothWheelScrollScope.isRewinding]。全 app 只有一个根部补间层、且拉回
/// 是同步完成的，一个全局标志足够。
bool _rewinding = false;

/// 全 app 唯一的鼠标滚轮「无极滚动」层（BUG-2834，接替 BUG-1959/1960 的
/// `FushiScrollController`）。
///
/// Flutter 的 [ScrollPositionWithSingleContext.pointerScroll] 把一档 delta 单帧
/// `forcePixels` 过去，视觉上一格一跳。旧方案靠自定义 [ScrollController] 改写
/// `pointerScroll`，但只有显式接了它的滚动区生效——全仓 ~300 个滚动视图只有 3 个
/// 接了，没写控制器的 ListView 走 [Scrollable] 内部写死的 `ScrollController()`，
/// 根本接不进去。
///
/// 这里改在**根部**一次接住所有滚动区，不挑控制器：
/// 1. 根 [Listener] 在 [PointerSignalResolver] 裁决**之前**收到滚轮事件（命中路径
///    由内向外，`GestureBinding` 排在最后），记下「本事件正在裁决」；
/// 2. 裁决时胜出的 Scrollable 同步 `pointerScroll` → 同步发出
///    [ScrollUpdateNotification]，根 [NotificationListener] 由此拿到**是哪个
///    position、从哪到哪**；
/// 3. 同一任务的 microtask 里把它拉回起点、再补间到目标（连拨从未到达的目标继续
///    累加）。整个过程在一个任务内完成，中间不出帧，不会闪跳。
///
/// 保持原生的情况：Flutter 滚完后物理接管（PageView / 转盘吸附 → 不是空闲态）；
/// 关闭动画的无障碍设置；被别的滚动区联动、不在指针下的跟随者。
class SmoothWheelScrollScope extends StatefulWidget {
  const SmoothWheelScrollScope({required this.child, super.key});

  final Widget child;

  /// 是否正处在补间的「拉回起点」那一步（同步 `jumpTo`，期间同步发出一组
  /// start / update / end 通知，update 的 delta 与用户这一档**反向**）。
  ///
  /// 按滚动**方向**做判断的监听者必须忽略这段通知：它不是用户输入，紧接着的
  /// 补间会把位置带回目标。只读位置 / 尺寸的监听者不受影响。
  static bool get isRewinding => _rewinding;

  @override
  State<SmoothWheelScrollScope> createState() => _SmoothWheelScrollScopeState();
}

class _WheelStep {
  _WheelStep(this.from, this.to);

  final double from;
  double to;
}

class _WheelEase {
  _WheelEase(this.target, this.forward);

  final double target;
  final bool forward;
}

class _SmoothWheelScrollScopeState extends State<SmoothWheelScrollScope> {
  /// 正在裁决的滚轮事件；microtask 里清空。
  PointerScrollEvent? _resolving;

  /// 本事件裁决期间被滚动的 position（指针下的那个）。
  final Map<ScrollPosition, _WheelStep> _steps = <ScrollPosition, _WheelStep>{};

  /// 飞行中的补间。完成 / 被打断后由 whenComplete 摘掉。
  final Map<ScrollPosition, _WheelEase> _eases = <ScrollPosition, _WheelEase>{};

  /// 本次手势判成粗滚轮还是细指针；null = 没有进行中的手势。按**手势**锁而不是
  /// 逐事件判：同一次拨动的尾帧可能小于阈值，逐事件判会让尾帧同步落地、掐断补间。
  bool? _gestureIsCoarse;

  /// 上一次滚轮事件的时刻；静默超过 [_kWheelGestureIdle] 视为新手势重新分类。
  /// 取调度器帧时间戳：widget 测试里 `pump(d)` 会推进它。
  Duration? _lastWheelStamp;

  static const Duration _kWheelGestureIdle = Duration(milliseconds: 200);

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollInertiaCancelEvent) {
      _onInertiaCancel();
      return;
    }
    if (event is! PointerScrollEvent) return;
    if (event.kind != PointerDeviceKind.mouse) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return;
    if (!_classifyCoarse(event)) return;
    _resolving = event;
    _steps.clear();
    scheduleMicrotask(() => _flush(event));
  }

  bool _classifyCoarse(PointerScrollEvent event) {
    final Duration now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final Duration? last = _lastWheelStamp;
    if (last == null || now - last > _kWheelGestureIdle) {
      _gestureIsCoarse = null;
    }
    _lastWheelStamp = now;
    final Offset d = event.scrollDelta;
    final double magnitude = d.dx.abs() > d.dy.abs() ? d.dx : d.dy;
    return _gestureIsCoarse ??= isCoarseDesktopPointerScrollDelta(
      magnitude,
      devicePixelRatio: View.maybeOf(context)?.devicePixelRatio ?? 1.0,
    );
  }

  /// 惯性取消（[PointerScrollInertiaCancelEvent]）：Scrollable 已在本监听之前调了
  /// `pointerScroll(0)`，把飞行中的补间掐在半路。要停的是动画，不是用户已经拨出去
  /// 的距离——直接落到既定目标，并清掉手势分类。
  void _onInertiaCancel() {
    _gestureIsCoarse = null;
    _lastWheelStamp = null;
    for (final MapEntry<ScrollPosition, _WheelEase> e
        in _eases.entries.toList()) {
      final ScrollPosition p = e.key;
      // 仍在补间的（不在本次取消的命中路径上）不动。
      if (p.isScrollingNotifier.value) continue;
      _eases.remove(p);
      if (p.hasPixels && p.pixels != e.value.target) p.jumpTo(e.value.target);
    }
  }

  bool _onScrollUpdate(ScrollUpdateNotification n) {
    final PointerScrollEvent? event = _resolving;
    if (event == null || n.dragDetails != null) return false;
    final BuildContext? origin = n.context;
    if (origin == null) return false;
    final ScrollableState? scrollable = Scrollable.maybeOf(origin);
    if (scrollable == null || !_isUnderPointer(scrollable, event)) return false;
    final ScrollPosition p = scrollable.position;
    final double delta = n.scrollDelta ?? 0;
    final _WheelStep? step = _steps[p];
    if (step == null) {
      _steps[p] = _WheelStep(p.pixels - delta, p.pixels);
    } else {
      step.to = p.pixels;
    }
    return false;
  }

  /// 只认指针下的滚动区：监听器里同步联动的跟随者（字幕面板跟随视频进度等）
  /// 也会在裁决期间发 update，它们不是被滚轮滚的那个。
  bool _isUnderPointer(ScrollableState scrollable, PointerScrollEvent event) {
    final RenderObject? box = scrollable.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(event.position));
  }

  void _flush(PointerScrollEvent event) {
    if (!identical(_resolving, event)) return;
    _resolving = null;
    final List<MapEntry<ScrollPosition, _WheelStep>> steps = _steps.entries
        .toList();
    _steps.clear();
    for (final MapEntry<ScrollPosition, _WheelStep> s in steps) {
      _ease(s.key, s.value);
    }
  }

  void _ease(ScrollPosition p, _WheelStep step) {
    final double delta = step.to - step.from;
    if (delta == 0 || !p.hasContentDimensions) return;
    // 物理已经接管（PageView / 转盘的吸附模拟）：pointerScroll 收尾的
    // goBallistic 没回到空闲，保持原生。
    if (p.isScrollingNotifier.value) return;
    final bool forward = delta > 0;
    final _WheelEase? running = _eases[p];
    // 连拨同向：从尚未到达的目标继续累加，否则快速连拨会不断吃掉前一段。
    // 反拨：从当前视觉位置起步，一反拨就立即响应。
    final double base = running != null && running.forward == forward
        ? running.target
        : step.from;
    // Flutter 已按边界钳过：落在边上就是边，不再往回算。
    final bool atEdge =
        step.to == p.minScrollExtent || step.to == p.maxScrollExtent;
    final double target = atEdge
        ? step.to
        : (base + delta).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    // 拉回起点只是补间的内部步骤：发出的那条反向 ScrollUpdate 不是用户在往回
    // 滚。按滚动方向收放 chrome 的监听者（浮动工具栏 / 大标题）据
    // [SmoothWheelScrollScope.isRewinding] 忽略它，否则每拨一档都会「收起 →
    // 弹回 → 收起」（BUG-2975 的闪烁 / 回弹）。
    _rewinding = true;
    try {
      p.jumpTo(step.from);
    } finally {
      _rewinding = false;
    }
    if (target == step.from) {
      _eases.remove(p);
      return;
    }
    final _WheelEase ease = _WheelEase(target, forward);
    _eases[p] = ease;
    unawaited(
      p
          .animateTo(
            target,
            duration: kDesktopWheelScrollDuration,
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (identical(_eases[p], ease)) _eases.remove(p);
          }),
    );
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _onPointerSignal,
    child: NotificationListener<ScrollUpdateNotification>(
      onNotification: _onScrollUpdate,
      child: widget.child,
    ),
  );
}
