/// 树状组件的动效件：子节点展开 / 收起（[FushiTreeReveal]）与展开箭头（[FushiTreeChevron]）。
///
/// 展开 = spatial 弹簧（高度 / 位移 / 缩放，可过冲；Material 取
/// [FushiSprings.treeExpand]，ζ 0.7 的俏皮回弹，Apple 取方案里的 spatialDefault），
/// 透明度另走 effects 弹簧（临界阻尼，不过冲）；收起把 ζ 钉成 1，高度不会负过冲。
/// 连点打断时从当前位置与当前速度继续。墨水屏 / 减弱动态效果下 token 已降级，
/// 直接落到终值。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 树展开 / 收起用到的三根弹簧（随设计系统与降级开关解析）。
@immutable
class FushiTreeSprings {
  const FushiTreeSprings({
    required this.expand,
    required this.collapse,
    required this.effects,
    required this.chevron,
  });

  /// 展开弹簧：Material 为 ζ 0.7，Apple 为 spatialDefault。
  final FushiSpringSpec expand;

  /// 收起弹簧：同刚度、ζ 钉 1。
  final FushiSpringSpec collapse;

  /// 透明度。
  final FushiSpringSpec effects;

  /// 箭头旋转。
  final FushiSpringSpec chevron;

  static FushiTreeSprings of(BuildContext context) {
    final FushiMotionScheme m = FushiMotionScheme.of(context);
    final FushiSpringSpec base = isGlassDesign(context)
        ? m.spatialDefault
        : (m.enabled
              ? FushiSprings.treeExpand
              : FushiSprings.treeExpand.reduced);
    return FushiTreeSprings(
      expand: base,
      collapse: FushiSpringSpec(
        dampingRatio: 1,
        stiffness: base.stiffness,
        enabled: base.enabled,
      ),
      effects: m.effectsDefault,
      chevron: m.spatialFast,
    );
  }
}

/// 子节点随父节点收起 / 展开：高度 + 位移 / 缩放弹簧，透明度走 effects 弹簧；
/// 收起后不进焦点遍历、不吃点击、不读屏。
class FushiTreeReveal extends StatefulWidget {
  const FushiTreeReveal({
    super.key,
    required this.visible,
    required this.child,
    this.enterOffset = 10,
  });

  final bool visible;
  final Widget child;

  /// 进场时从上方滑入的位移（dp），同时从 `1 - offset/120` 缩放到 1。
  final double enterOffset;

  /// 展开起始速度（全程 / 秒）：越大越「蹦」出来。
  static const double expandVelocity = 6;

  @override
  State<FushiTreeReveal> createState() => _FushiTreeRevealState();
}

class _FushiTreeRevealState extends State<FushiTreeReveal>
    with TickerProviderStateMixin {
  // unbounded：ζ < 1 的展开会越过 1。
  late final AnimationController _size = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final AnimationController _fade = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(FushiTreeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    final FushiTreeSprings s = FushiTreeSprings.of(context);
    if (widget.visible) {
      unawaited(
        _size.fushiSpringTo(
          1,
          s.expand,
          velocity: FushiTreeReveal.expandVelocity,
        ),
      );
      unawaited(_fade.fushiSpringTo(1, s.effects));
    } else {
      unawaited(_size.fushiSpringTo(0, s.collapse));
      unawaited(_fade.fushiSpringTo(0, s.effects));
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hidden = !widget.visible;
    return ExcludeFocus(
      excluding: hidden,
      child: IgnorePointer(
        ignoring: hidden,
        child: ExcludeSemantics(
          excluding: hidden,
          child: AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[_size, _fade]),
            builder: (BuildContext context, Widget? child) {
              final double v = _size.value;
              final double factor = math.max(0, v);
              if (factor == 0 && hidden) return const SizedBox.shrink();
              final double enter = (1 - v).clamp(-0.5, 1.0);
              return ClipRect(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  heightFactor: factor,
                  child: Opacity(
                    opacity: _fade.value.clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, -enter * widget.enterOffset),
                      child: Transform.scale(
                        scale: 1 - enter * widget.enterOffset / 120,
                        alignment: Alignment.topCenter,
                        child: child,
                      ),
                    ),
                  ),
                ),
              );
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 展开箭头：展开时转 90°（指向下），走 spatial 弹簧（回弹时会略过 90°）。
class FushiTreeChevron extends StatefulWidget {
  const FushiTreeChevron({
    super.key,
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  State<FushiTreeChevron> createState() => _FushiTreeChevronState();
}

class _FushiTreeChevronState extends State<FushiTreeChevron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController.unbounded(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didUpdateWidget(FushiTreeChevron oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    unawaited(
      _turn.fushiSpringTo(
        widget.expanded ? 1 : 0,
        FushiTreeSprings.of(context).chevron,
      ),
    );
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _turn,
    builder: (BuildContext context, Widget? child) =>
        Transform.rotate(angle: _turn.value * math.pi / 2, child: child),
    child: widget.child,
  );
}
