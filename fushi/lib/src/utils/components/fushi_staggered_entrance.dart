import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 一屏内容的「进场窗口」：窗口内首次挂载的 [FushiStaggeredEntrance] 错峰淡入
/// 上移，窗口关闭后挂载的项（滚动带出来的、懒加载补进来的）**瞬间出现**。
///
/// 只在首屏做进场是刻意的：滚动途中每张新卡都淡入一次会让快速滑动看起来「拖影」，
/// 而且与 [FushiHoverLift] 的滚动压制（BUG-2124）同理——用户的注意力在指针 / 手指
/// 底下，不在新露出的边缘。
///
/// 窗口从 scope 首次挂载开始计时；[replayKey] 变化（例如切换书架分组、切换排序）
/// 时重开窗口，让新的一屏也有一次进场。
class FushiEntranceScope extends StatefulWidget {
  const FushiEntranceScope({
    required this.child,
    super.key,
    this.replayKey,
    this.enabled = true,
    this.window = const Duration(milliseconds: 600),
  });

  final Widget child;

  /// 是否开放本 scope 的进场窗口。拖拽反馈等已可见内容的副本应直接显示。
  final bool enabled;

  /// 变化时重开进场窗口。
  final Object? replayKey;

  /// 进场窗口长度。
  final Duration window;

  @override
  State<FushiEntranceScope> createState() => _FushiEntranceScopeState();
}

class _FushiEntranceScopeState extends State<FushiEntranceScope> {
  late Duration _openedAt = _now();
  int _generation = 0;

  static Duration _now() =>
      SchedulerBinding.instance.currentSystemFrameTimeStamp;

  @override
  void didUpdateWidget(covariant FushiEntranceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replayKey != widget.replayKey ||
        oldWidget.enabled != widget.enabled) {
      _openedAt = _now();
      _generation++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _FushiEntranceWindow(
      openedAt: _openedAt,
      window: widget.window,
      generation: _generation,
      enabled: widget.enabled,
      child: widget.child,
    );
  }
}

class _FushiEntranceWindow extends InheritedWidget {
  const _FushiEntranceWindow({
    required this.openedAt,
    required this.window,
    required this.generation,
    required this.enabled,
    required super.child,
  });

  final Duration openedAt;
  final Duration window;
  final int generation;
  final bool enabled;

  bool get isOpen =>
      enabled &&
      SchedulerBinding.instance.currentSystemFrameTimeStamp - openedAt <=
          window;

  @override
  bool updateShouldNotify(_FushiEntranceWindow oldWidget) =>
      generation != oldWidget.generation;
}

/// 列表 / 网格项的错峰进场：淡入 + 自下而上 [FushiMotion.enterOffset] 的位移。
///
/// 第 [index] 项延后 `index × staggerStep` 起播，超过 [FushiMotion.staggerMaxItems]
/// 的项与最后一档同时起播。没有祖先 [FushiEntranceScope] 时视作窗口常开（单独
/// 使用也能工作）。进场只播一次；同一 element 后续 rebuild 不会重播，scope 的
/// [FushiEntranceScope.replayKey] 变化时才重播。
///
/// 动画只改 opacity 与 transform，不改布局——网格的 `mainAxisExtent` / 文字块
/// 预留高度（BUG-1184）全程不变。
class FushiStaggeredEntrance extends StatefulWidget {
  const FushiStaggeredEntrance({
    required this.index,
    required this.child,
    super.key,
  });

  final int index;
  final Widget child;

  @override
  State<FushiStaggeredEntrance> createState() => _FushiStaggeredEntranceState();
}

class _FushiStaggeredEntranceState extends State<FushiStaggeredEntrance>
    with SingleTickerProviderStateMixin {
  // 错峰延迟折进 controller 本身（总时长 = 延迟 + 进场，曲线前段走 Interval 的
  // 平台期），不挂 `Future.delayed`：计时器在 element 卸载后仍会悬着，测试里
  // 会报 pending timer，真机上也多一次无谓唤醒。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  );
  // 淡入走 effects（不过冲，透明度不能越过 1）、上移走 spatial（M3E 弹簧
  // 形状，落点带极轻回弹）；两条共用一个控制器与同一段错峰延迟。
  Animation<double> _fade = const AlwaysStoppedAnimation<double>(1);
  Animation<double> _rise = const AlwaysStoppedAnimation<double>(1);
  int? _playedGeneration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final _FushiEntranceWindow? scope = context
        .dependOnInheritedWidgetOfExactType<_FushiEntranceWindow>();
    final int generation = scope?.generation ?? 0;
    if (_playedGeneration == generation) return;
    _playedGeneration = generation;
    final bool open = scope?.isOpen ?? true;
    if (!open || !fushiMotionEnabled(context)) {
      _controller.value = 1;
      return;
    }
    final int slot = widget.index.clamp(0, FushiMotion.staggerMaxItems);
    final Duration delay = FushiMotion.staggerStep * slot;
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    final Duration total = delay + spring.duration;
    final double start = delay.inMicroseconds / total.inMicroseconds;
    _controller.duration = total;
    _fade = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, 1, curve: FushiSpringCurve.effects),
    );
    _rise = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, 1, curve: spring.curve),
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 结构恒定（Opacity → Transform → child）：进场结束后若改为直接返回 child，
    // 子树会被重新挂载、丢掉内部状态（封面图解码、焦点）。opacity 为 1 时
    // RenderOpacity 不建合成层，常驻无开销。
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        return Opacity(
          opacity: _fade.value,
          child: Transform.translate(
            offset: Offset(0, (1 - _rise.value) * FushiMotion.enterOffset),
            child: child,
          ),
        );
      },
    );
  }
}

/// `itemBuilder` 适配器：把网格 / 列表的每一项包进 [FushiStaggeredEntrance]。
///
/// 各库页 / 浏览页的 `GridView.builder` / `SliverGrid.builder` 一处套用即可接入
/// 错峰进场；调用方仍须在网格外包一层 [FushiEntranceScope]，否则窗口常开、懒加载
/// 滚出的每一格都会淡入（拖影）。
NullableIndexedWidgetBuilder fushiStaggeredItemBuilder(
  NullableIndexedWidgetBuilder builder,
) {
  return (BuildContext context, int index) {
    final Widget? child = builder(context, index);
    if (child == null) return null;
    return FushiStaggeredEntrance(index: index, child: child);
  };
}
