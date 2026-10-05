/// 首页（仪表盘）的浮动工具栏与「继续」FAB（2026-10 统一浮动工具栏）。
///
/// 小说 / 漫画 / 视频的顶底栏统一成 M3 Expressive floating toolbar 之后，首页
/// 也换成同一套视觉：页面顶上不再是贴边的实体条，而是两枚**悬浮胶囊**——
///
///  * 起始侧 = 标题胶囊（形状图标 + 页面名）；
///  * 末尾侧 = 动作按钮组（更新中心带未读角标 · 统计中心 · 排行榜）。
///
/// 两枚胶囊都是 [FushiToolbar] 的悬浮形态（MD3 = surfaceContainer 全胶囊 +
/// elevation 3；Apple = iOS 26 悬浮液态玻璃组胶囊），与阅读器 / 视频 / 库页
/// 工具栏同一个组件、同一套尺寸。
///
/// 滚动行为（M3 Expressive「floating toolbar 随滚动退场」）：内容一离开顶部，
/// 标题胶囊收起文字只留形状图标（腾出视野）；继续向下滚，整条栏弹簧上滑退场；
/// 任意位置向上回滚，栏弹簧回落。退场中的栏 [IgnorePointer] + [ExcludeFocus]：
/// 看不见的按钮不该被点到或 Tab 到。墨水屏 / 系统「减弱动态效果」下瞬时切换。
///
/// FAB：「继续」主角卡滚出视野后，右下角出现「继续阅读 / 继续观看 / 打开」FAB
/// （首屏主角卡自己就有这颗主按钮，首屏不重复）。栏在时 FAB 展开带文字，栏退场
/// （用户在往下读内容）时收成只剩图标——M3 extended FAB 的滚动收缩约定。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiBadgeControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 栏离内容区顶边的距离。
const double kHomeToolbarTopGap = 8;

/// 悬浮胶囊高（[FushiToolbar] 悬浮形态的 MD3 默认档 64）。
const double kHomeToolbarHeight = 64;

/// 内容列表顶部要让出的高度（栏 + 上留白）；列表自己的内边距另算。
const double kHomeToolbarExtent = kHomeToolbarTopGap + kHomeToolbarHeight;

/// FAB 离内容区底边 / 末尾边的距离（M3：16）。
const double kHomeFabMargin = 16;

/// FAB 高（M3 FAB 56 档）。
const double kHomeFabHeight = 56;

/// 列表底部为 FAB 预留的高度：最后一张卡滚到底时不被 FAB 压住。
const double kHomeFabClearance = kHomeFabHeight + kHomeFabMargin;

/// 滚动距离超过它才把标题胶囊收成紧凑态。
const double _kCompactAfter = 24;

/// 同一方向累计滚过这么多才切换显隐，避免手指微抖导致栏来回闪。
const double _kRevealHysteresis = 24;

/// 首页浮动栏 / FAB 的滚动驱动状态。
///
/// 只认仪表盘主列表（`depth == 0` 的纵向滚动）——卡片里的横滑行、热力图横滚
/// 的通知深度 > 0，不参与。[handle] 恒返回 false，通知照常冒泡给外壳（Apple
/// 底栏最小化 / 大标题收起都还要读它）。
class HomeToolbarScrollState extends ChangeNotifier {
  HomeToolbarScrollState({this.fabRevealOffset = 280});

  /// 滚过这个偏移（≈「继续」主角卡底边）后 FAB 才出现。
  final double fabRevealOffset;

  bool _visible = true;
  bool _compact = false;
  bool _pastHero = false;
  double _accumulated = 0;

  /// 栏是否显示。
  bool get visible => _visible;

  /// 标题胶囊是否收成只剩图标。
  bool get compact => _compact;

  /// 主角卡是否已滚出视野（FAB 出现的条件之一）。
  bool get pastHero => _pastHero;

  bool handle(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification) return false;
    final double pixels = notification.metrics.pixels;
    final double delta = notification.scrollDelta ?? 0;
    bool visible = _visible;
    if (pixels <= kHomeToolbarExtent) {
      // 顶部一屏栏高之内恒显示：此时栏下压的是列表自己让出的空白。
      visible = true;
      _accumulated = 0;
    } else if (delta != 0) {
      // 换向就重新累计。
      if (delta.sign != _accumulated.sign) _accumulated = 0;
      _accumulated += delta;
      if (_accumulated > _kRevealHysteresis) {
        visible = false;
        _accumulated = 0;
      } else if (_accumulated < -_kRevealHysteresis) {
        visible = true;
        _accumulated = 0;
      }
    }
    _set(
      visible: visible,
      compact: pixels > _kCompactAfter,
      pastHero: pixels > fabRevealOffset,
    );
    return false;
  }

  /// 强制显示（例如焦点从别处移回列表顶）。
  void reveal() => _set(visible: true, compact: _compact, pastHero: _pastHero);

  void _set({
    required bool visible,
    required bool compact,
    required bool pastHero,
  }) {
    if (visible == _visible && compact == _compact && pastHero == _pastHero) {
      return;
    }
    _visible = visible;
    _compact = compact;
    _pastHero = pastHero;
    notifyListeners();
  }
}

/// 更新中心未读总数（工具栏角标用），订阅 [UpdateFeedService.watchChanged]。
///
/// 与 `UpdatesDashboardBanner` 同一信号流（不是裸 drift watch，见 BUG-834）。
class HomeUpdateCount extends ValueNotifier<int> {
  HomeUpdateCount(this._service) : super(0) {
    _changes = _service.watchChanged().listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  final UpdateFeedService _service;
  StreamSubscription<void>? _changes;
  bool _disposed = false;

  Future<void> reload() async {
    final int total = (await _service.unseenCounts()).values.fold<int>(
      0,
      (int a, int b) => a + b,
    );
    if (_disposed) return;
    value = total;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    super.dispose();
  }
}

/// 工具栏上的一颗动作。
@immutable
class HomeToolbarAction {
  const HomeToolbarAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badgeCount,
  });

  final Key key;
  final IconData icon;

  /// tooltip 与语义标签。
  final String label;
  final VoidCallback onPressed;

  /// 非 null 时在图标右上角画未读数（0 不画）。
  final ValueListenable<int>? badgeCount;
}

/// 首页浮动工具栏：标题胶囊 + 动作按钮组，两枚都是 [FushiToolbar] 悬浮胶囊。
class HomeFloatingToolbar extends StatefulWidget {
  const HomeFloatingToolbar({
    super.key,
    required this.title,
    required this.icon,
    required this.actions,
    required this.visible,
    required this.compact,
  });

  final String title;

  /// 标题胶囊前的形状图标。
  final IconData icon;
  final List<HomeToolbarAction> actions;

  /// 栏是否在场（false = 弹簧上滑退场）。
  final bool visible;

  /// 标题胶囊是否收成只剩形状图标。
  final bool compact;

  @override
  State<HomeFloatingToolbar> createState() => _HomeFloatingToolbarState();
}

class _HomeFloatingToolbarState extends State<HomeFloatingToolbar>
    with TickerProviderStateMixin {
  // 显隐：M3 Expressive default spatial 弹簧（与按钮组选中形变同一根），
  // 回落时带一点过冲，读作「弹回来」。
  late final FushiSpring _reveal = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void didUpdateWidget(HomeFloatingToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _reveal.animateTo(
        widget.visible ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget bar = Padding(
      padding: const EdgeInsetsDirectional.only(top: kHomeToolbarTopGap),
      child: SizedBox(
        height: kHomeToolbarHeight,
        child: Row(
          children: <Widget>[
            Flexible(
              child: _HomeTitleCapsule(
                title: widget.title,
                icon: widget.icon,
                compact: widget.compact,
              ),
            ),
            const Spacer(),
            if (widget.actions.isNotEmpty)
              FushiHeaderLabelScope(
                expandLabels: false,
                child: FushiToolbar(
                  floating: true,
                  children: <Widget>[
                    for (final HomeToolbarAction action in widget.actions)
                      _HomeToolbarButton(action: action),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _reveal.animation,
      child: bar,
      builder: (BuildContext context, Widget? child) {
        final double t = _reveal.value;
        final bool hidden = !widget.visible;
        return IgnorePointer(
          ignoring: hidden,
          child: ExcludeFocus(
            excluding: hidden,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.translate(
                // 整栏上滑出顶边（再多走 16，连同投影一起出去）。
                offset: Offset(0, -(1 - t) * (kHomeToolbarExtent + 16)),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 标题胶囊：M3E 形状图标（饱和 primaryContainer 的圆角方块）+ 页面名；紧凑态
/// 文字弹簧收起，只剩图标。
class _HomeTitleCapsule extends StatelessWidget {
  const _HomeTitleCapsule({
    required this.title,
    required this.icon,
    required this.compact,
  });

  final String title;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final bool motion = fushiExpressiveMotionEnabled(context);
    final Widget badge = apple
        ? FushiIcon(icon, size: 20, color: cs.primary)
        : DecoratedBox(
            decoration: ShapeDecoration(
              color: cs.primaryContainer,
              // M3E 形状对比：胶囊里放一块 12 圆角方块，不再是又一个圆。
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
            child: SizedBox.square(
              dimension: 40,
              child: Icon(icon, size: 22, color: cs.onPrimaryContainer),
            ),
          );
    final TextStyle? style =
        (apple ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)
            ?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurface);
    return FushiToolbar(
      floating: true,
      children: <Widget>[
        Semantics(
          header: true,
          label: title,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: EdgeInsetsDirectional.only(start: apple ? 8 : 0),
                child: badge,
              ),
              AnimatedSize(
                duration: motion ? FushiMotion.medium : Duration.zero,
                curve: FushiMotion.release,
                alignment: AlignmentDirectional.centerStart,
                child: compact
                    ? const SizedBox(width: 0, height: 0)
                    : Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 12,
                          end: 12,
                        ),
                        child: Text(
                          title,
                          key: const ValueKey<String>('home-toolbar-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HomeToolbarButton extends StatelessWidget {
  const _HomeToolbarButton({required this.action});

  final HomeToolbarAction action;

  @override
  Widget build(BuildContext context) {
    final Widget button = FushiIconButton(
      key: action.key,
      icon: action.icon,
      tooltip: action.label,
      onTap: action.onPressed,
    );
    final ValueListenable<int>? count = action.badgeCount;
    if (count == null) return button;
    return ValueListenableBuilder<int>(
      valueListenable: count,
      child: button,
      builder: (BuildContext context, int n, Widget? child) =>
          FushiBadgeControl(
            isLabelVisible: n > 0,
            label: Text(n > 99 ? '99+' : '$n'),
            offset: const Offset(-4, 4),
            child: child!,
          ),
    );
  }
}

/// 「继续」FAB：主角卡滚出视野后出现（弹簧缩放 + 淡入），[extended] 时带文字。
///
/// MD3 = M3 Expressive FAB：饱和 primaryContainer、圆角 16（FAB 56 档）、
/// elevation 3（悬停 4），文字展开 / 收起走弹簧；Apple = iOS 26 有色
/// （`.glassProminent`）液态玻璃胶囊。
class HomeResumeFab extends StatefulWidget {
  const HomeResumeFab({
    super.key,
    required this.visible,
    required this.extended,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool visible;
  final bool extended;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<HomeResumeFab> createState() => _HomeResumeFabState();
}

class _HomeResumeFabState extends State<HomeResumeFab>
    with TickerProviderStateMixin {
  late final FushiSpring _reveal = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void didUpdateWidget(HomeResumeFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _reveal.animateTo(
        widget.visible ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget fab = isGlassDesign(context)
        ? _buildApple(context)
        : _buildMaterial(context);
    return AnimatedBuilder(
      animation: _reveal.animation,
      child: fab,
      builder: (BuildContext context, Widget? child) {
        final double t = _reveal.value;
        if (!widget.visible && t <= 0.001) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeFocus(
            excluding: !widget.visible,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.6 + 0.4 * t,
                alignment: AlignmentDirectional.bottomEnd.resolve(
                  Directionality.of(context),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _label(BuildContext context, Color color) {
    final bool motion = fushiExpressiveMotionEnabled(context);
    return AnimatedSize(
      duration: motion ? FushiMotion.medium : Duration.zero,
      curve: FushiMotion.release,
      alignment: AlignmentDirectional.centerStart,
      child: widget.extended
          ? Padding(
              padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
              child: Text(
                widget.label,
                key: const ValueKey<String>('home-resume-fab-label'),
                maxLines: 1,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : const SizedBox(width: 0, height: 0),
    );
  }

  Widget _buildMaterial(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget fab = Material(
      color: eink ? cs.surface : cs.primaryContainer,
      elevation: eink ? 0 : 3,
      shadowColor: cs.shadow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onPressed,
        child: Semantics(
          button: true,
          label: widget.label,
          excludeSemantics: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kHomeFabHeight,
              minWidth: kHomeFabHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(widget.icon, size: 24, color: cs.onPrimaryContainer),
                  _label(context, cs.onPrimaryContainer),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // 结构恒定（展开 / 收起不增删包装层，否则 InkWell 重挂会丢焦点）：
    // tooltip 恒在，收成图标时它是唯一的文字说明。
    return Tooltip(message: widget.label, child: fab);
  }

  Widget _buildApple(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: fushiGlassSettings(context, tint: cs.primary),
        shape: const LiquidRoundedSuperellipse(borderRadius: 999),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onPressed,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50, minWidth: 50),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(widget.icon, size: 22, color: cs.onPrimary),
                    _label(context, cs.onPrimary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
