import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 底栏「中央展开」弹出层里的一个目的地（与底栏 `AdaptiveNavItem` 同形，
/// 这里单独声明是为了不依赖底栏的私有实现）。
@immutable
class NavLauncherEntry {
  const NavLauncherEntry({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.selected = false,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// 当前页就是这一项：画成实底指示色。
  final bool selected;
}

/// 弹出层配色：与底栏胶囊同一套（MD3 tertiaryContainer / Apple 中性灰 /
/// 墨水屏反色），由调用方按设计系统给。
@immutable
class NavLauncherStyle {
  const NavLauncherStyle({
    required this.container,
    required this.content,
    required this.indicator,
    required this.onIndicator,
    required this.scrim,
    required this.labelColor,
    required this.closeLabel,
    this.outline,
  });

  final Color container;
  final Color content;
  final Color indicator;
  final Color onIndicator;

  /// 弹出时压在页面上的遮罩色；点遮罩任意处收回。
  final Color scrim;

  /// 圆钮下方标签的字色（压在 [scrim] 上，须与遮罩成对比）。
  final Color labelColor;
  final String closeLabel;

  /// 墨水屏描边；null = 不描边（彩色主题靠阴影分层）。
  final Color? outline;
}

/// 每个圆钮的直径（与 M3 FAB 同大，命中区 ≥ 48）。
const double kNavLauncherButtonSize = 56;

/// 圆钮 + 标签的格宽：标签最多两行，按这个宽度换行。
const double _kSlotWidth = 76;

/// 第一圈半径（中央钮圆心到目的地圆心）；之后每圈再往外推 [_kRingGap]。
/// 140：一圈 5 个时相邻圆心弦长 ≈ 84（56 圆钮 + 标签不互压；108 时只有 65，
/// 实测圆钮压住邻项标签）。
const double _kFirstRingRadius = 140;
const double _kRingGap = 88;

/// 弧的圆心比「+」圆心再高这么多：弧两端的圆钮（连同下方标签）也整个
/// 浮在底栏胶囊之上，不压住左右常驻的目的地。
const double _kArcLift = 64;

/// 每圈最多放几个：越外圈弧长越长、放得越多。
const List<int> _kRingCapacity = <int>[5, 6, 7, 8];

/// 「按住『+』直接划过去」手势（像手机图案解锁）：「+」格按下即弹出扇面，
/// 手指不抬起划到某一项上（那一项放大高亮、轻震），抬手即选中；划到空处抬手
/// = 收回；没移动就抬手 = 普通点按，扇面留着。
///
/// 指针事件始终送回按下时命中的「+」格（新推的路由不会抢走进行中的指针），
/// 所以由「+」格的 Listener 把位置喂给本控制器，命中判定按与扇面布局同一份
/// 几何（[navLauncherSlotCenters]）算，不依赖扇面里控件的命中测试。
class NavLauncherDragController {
  NavLauncherDragController();

  /// 手指当前罩着的那一项（[entries] 里的序号）；null = 不在任何一项上。
  final ValueNotifier<int?> hovered = ValueNotifier<int?>(null);

  List<Offset> _centers = const <Offset>[];
  Route<int>? _route;

  /// 手指离圆心多近算罩住（圆钮半径 28 + 标签与手指遮挡的余量）。
  static const double hitRadius = 48;

  void _attach(Route<int> route, List<Offset> centers) {
    _route = route;
    _centers = centers;
  }

  /// [position] 是根 Overlay 坐标系里的手指位置。
  void move(Offset position) {
    int? best;
    double bestDistance = hitRadius;
    for (int i = 0; i < _centers.length; i++) {
      final double d = (_centers[i] - position).distance;
      if (d <= bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    if (best != hovered.value) {
      hovered.value = best;
      if (best != null) unawaited(HapticFeedback.selectionClick());
    }
  }

  /// 抬手：罩着某一项 → 选中它；否则 [moved] 为真（划过但落在空处）→ 收回；
  /// 都不是（按住不动就抬手）→ 当普通点按，扇面留着。
  void release({required bool moved}) {
    final Route<int>? route = _route;
    if (route == null || !route.isActive) return;
    final int? index = hovered.value;
    if (index != null) {
      route.navigator?.pop<int>(index);
    } else if (moved) {
      route.navigator?.pop<int>();
    }
  }

  void dispose() => hovered.dispose();
}

/// 各目的地圆钮圆心在根 Overlay 坐标系里的位置：「+」圆心 [center] 加
/// [navLauncherSlotOffset]，横向夹进 [width] 宽的屏幕（留出半个格宽 + 8 边距）。
/// 扇面布局与拖选命中共用这一份。
List<Offset> navLauncherSlotCenters({
  required Offset center,
  required int count,
  required double width,
}) {
  const double half = _kSlotWidth / 2;
  const double minX = half + 8;
  final double maxX = math.max(minX, width - half - 8);
  return <Offset>[
    for (int i = 0; i < count; i++)
      () {
        final Offset target = center + navLauncherSlotOffset(i, count);
        return Offset(target.dx.clamp(minX, maxX), target.dy);
      }(),
  ];
}

/// 打开「中央展开」弹出层：[anchor] 是底栏中央「+」格在根 Overlay 坐标系里
/// 的矩形，[entries] 从它的圆心沿上半圆弧逐个弹簧飞出（错峰），中央的「+」
/// 转 45° 变成「×」；点遮罩 / 「×」/ 返回键 / Esc 收回（逆向飞回圆心）。
/// 返回选中项在 [entries] 里的序号；收回 = null。减弱动态效果 / 墨水屏下
/// 时长归零、瞬间出现。[drag] 非空时接上「按住直接划过去」手势，
/// [overlayWidth] 是根 Overlay 的宽（命中几何要与布局一致）。
Future<int?> showNavLauncherFan({
  required BuildContext context,
  required Rect anchor,
  required List<NavLauncherEntry> entries,
  required NavLauncherStyle style,
  NavLauncherDragController? drag,
  double? overlayWidth,
}) {
  final Duration enter = fushiMotionDuration(context, FushiMotion.long);
  final Duration exit = fushiMotionDuration(context, FushiMotion.longReverse);
  final PageRouteBuilder<int> route = PageRouteBuilder<int>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: style.scrim,
    barrierLabel: style.closeLabel,
    transitionDuration: enter,
    reverseTransitionDuration: exit,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => _NavLauncherFan(
          anchor: anchor,
          entries: entries,
          style: style,
          animation: animation,
          hovered: drag?.hovered,
        ),
  );
  if (drag != null && overlayWidth != null) {
    drag._attach(
      route,
      navLauncherSlotCenters(
        center: anchor.center,
        count: entries.length,
        width: overlayWidth,
      ),
    );
  }
  return Navigator.of(context, rootNavigator: true).push<int>(route);
}

/// 第 [index] 个目的地（共 [count] 个）在弧上的圆心相对中央钮圆心的偏移。
/// 纯几何、可单测：内圈先填满再往外圈放，每圈在 160°→20° 的上半圆弧上
/// 均匀分布（只有一个时正上方），弧心比「+」高 [_kArcLift]。
@visibleForTesting
Offset navLauncherSlotOffset(int index, int count) {
  int ring = 0;
  int start = 0;
  while (true) {
    final int capacity =
        _kRingCapacity[math.min(ring, _kRingCapacity.length - 1)];
    if (index < start + capacity) {
      final int inRing = math.min(capacity, count - start);
      final int pos = index - start;
      final double radius = _kFirstRingRadius + ring * _kRingGap;
      final double degrees = inRing == 1
          ? 90
          : 160 - pos * (140 / (inRing - 1));
      final double rad = degrees * math.pi / 180;
      return Offset(
        radius * math.cos(rad),
        -(_kArcLift + radius * math.sin(rad)),
      );
    }
    start += capacity;
    ring++;
  }
}

class _NavLauncherFan extends StatelessWidget {
  const _NavLauncherFan({
    required this.anchor,
    required this.entries,
    required this.style,
    required this.animation,
    this.hovered,
  });

  final Rect anchor;
  final List<NavLauncherEntry> entries;
  final NavLauncherStyle style;
  final Animation<double> animation;

  /// 「按住划过去」时手指罩着的那一项；null = 没在拖。
  final ValueListenable<int?>? hovered;

  void _close(BuildContext context) => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final int count = entries.length;
    final int autofocusIndex = math.max(
      0,
      entries.indexWhere((NavLauncherEntry e) => e.selected),
    );
    // 错峰：每项晚 staggerStep 起飞，整体仍在路由时长内跑完。
    final int totalMs = math.max(1, FushiMotion.long.inMilliseconds);
    final double step = FushiMotion.staggerStep.inMilliseconds / totalMs;
    final double span = math.max(0.35, 1 - step * (count - 1));
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (DismissIntent intent) {
              _close(context);
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final Offset center = anchor.center;
            final List<Offset> centers = navLauncherSlotCenters(
              center: center,
              count: count,
              width: box.maxWidth,
            );
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                for (int i = 0; i < count; i++)
                  _FlyingSlot(
                    animation: CurvedAnimation(
                      parent: animation,
                      curve: Interval(
                        math.min(i * step, 1 - span),
                        math.min(i * step, 1 - span) + span,
                      ),
                    ),
                    from: center,
                    to: centers[i],
                    child: _LauncherButton(
                      entry: entries[i],
                      index: i,
                      hovered: hovered,
                      style: style,
                      autofocus: i == autofocusIndex,
                      focusId: FushiFocusId('nav-launcher-$i'),
                      onPressed: () => Navigator.of(context).pop(i),
                    ),
                  ),
                // 中央「×」盖在底栏「+」格的正上方（遮罩之上），旋转 45° 由「+」
                // 变「×」；点它收回。
                Positioned(
                  left: center.dx - kNavLauncherButtonSize / 2,
                  top: center.dy - kNavLauncherButtonSize / 2,
                  width: kNavLauncherButtonSize,
                  height: kNavLauncherButtonSize,
                  child: Semantics(
                    button: true,
                    label: style.closeLabel,
                    child: FushiPressScale(
                      child: Material(
                        color: style.indicator,
                        shape: CircleBorder(
                          side: style.outline == null
                              ? BorderSide.none
                              : BorderSide(color: style.outline!),
                        ),
                        elevation: style.outline == null ? 3 : 0,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _close(context),
                          canRequestFocus: false,
                          child: Center(
                            child: RotationTransition(
                              turns: Tween<double>(
                                begin: 0,
                                end: 0.125,
                              ).animate(fushiUnitClamped(animation)),
                              child: FushiIcon(
                                FushiIcons.add,
                                color: style.onIndicator,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 从 [from] 飞到 [to] 的一格：位置与缩放走带回弹的 spatial 弹簧
/// （[FushiMotion.release]，只用于位置 / 缩放），透明度走不过冲的 effects。
class _FlyingSlot extends StatelessWidget {
  const _FlyingSlot({
    required this.animation,
    required this.from,
    required this.to,
    required this.child,
  });

  final Animation<double> animation;
  final Offset from;
  final Offset to;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) {
        final double t = animation.value;
        final double spatial = FushiMotion.release.transform(t);
        final double fade = FushiMotion.enter.transform(t).clamp(0.0, 1.0);
        final Offset at = Offset.lerp(from, to, spatial)!;
        return Positioned(
          left: at.dx - _kSlotWidth / 2,
          top: at.dy - kNavLauncherButtonSize / 2,
          width: _kSlotWidth,
          child: IgnorePointer(
            ignoring: t < 0.5,
            child: Opacity(
              opacity: fade,
              child: Transform.scale(
                scale: 0.3 + 0.7 * spatial,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _LauncherButton extends StatelessWidget {
  const _LauncherButton({
    required this.entry,
    required this.index,
    required this.hovered,
    required this.style,
    required this.autofocus,
    required this.focusId,
    required this.onPressed,
  });

  final NavLauncherEntry entry;
  final int index;

  /// 拖选中手指罩着的项：罩着这一项时放大并画成指示色。
  final ValueListenable<int?>? hovered;
  final NavLauncherStyle style;
  final bool autofocus;
  final FushiFocusId focusId;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<int?>? source = hovered;
    if (source == null) return _build(context, false);
    return ValueListenableBuilder<int?>(
      valueListenable: source,
      builder: (BuildContext context, int? value, Widget? _) =>
          _build(context, value == index),
    );
  }

  Widget _build(BuildContext context, bool hot) {
    final bool selected = entry.selected || hot;
    final TextStyle label =
        (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: style.labelColor,
          shadows: style.outline == null
              ? const <Shadow>[Shadow(blurRadius: 4)]
              : null,
        );
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onPressed();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: focusId,
        autofocus: autofocus,
        child: Semantics(
          button: true,
          selected: selected,
          label: entry.label,
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedScale(
                scale: hot ? 1.18 : 1,
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.release,
                child: SizedBox.square(
                  dimension: kNavLauncherButtonSize,
                  child: FushiPressScale(
                    child: Material(
                      color: selected ? style.indicator : style.container,
                      shape: CircleBorder(
                        side: style.outline == null
                            ? BorderSide.none
                            : BorderSide(color: style.outline!),
                      ),
                      elevation: style.outline == null ? 3 : 0,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: onPressed,
                        canRequestFocus: false,
                        child: Center(
                          child: FushiIcon(
                            selected
                                ? (entry.selectedIcon ?? entry.icon)
                                : entry.icon,
                            color: selected ? style.onIndicator : style.content,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // 标签也是命中区（只点圆钮太苛刻）；涟漪只画在圆钮上。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onPressed,
                child: Text(
                  entry.label,
                  style: label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
