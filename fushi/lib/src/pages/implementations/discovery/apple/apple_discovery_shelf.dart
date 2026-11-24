/// Apple（Cupertino）发现页的横滑货架件（「浏览」页宽屏，设计稿方案 B 的货架式）：
///
/// - [AppleDiscoveryShelfHeader]：货架头——22pt 粗体标题（macOS 档 17 × 缩放）+
///   可选副标题 + 行尾强调色「查看全部 ›」；
/// - [AppleShelfHoverArrows]：给任意横滑条加「悬停两端出箭头」（桌面指针悬停时
///   在可再滚的一端浮出玻璃圆钮，点一下翻约 80% 视口）；不改子树结构，触屏 /
///   键盘照常横滑 / 方向键；
/// - [AppleDiscoveryLockup]：来源 lockup 卡（App Store 式：56pt 中性 glyph + 名字
///   + 副行 + 获取式按钮「浏览」/「搜索」）。
///
/// 只在 `isGlassDesign` 为真时由发现页选用；M3E 不经过这里。
library;

import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 货架头：标题（Title 2 粗体）+ 副标题 +「查看全部 ›」。
class AppleDiscoveryShelfHeader extends StatelessWidget {
  const AppleDiscoveryShelfHeader({
    required this.title,
    this.subtitle,
    this.onViewAll,
    this.viewAllKey,
    this.loading = false,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onViewAll;
  final Key? viewAllKey;

  /// 行尾小转圈（货架在加载）。
  final bool loading;

  /// 「查看全部」之外的行尾件（null = 只有查看全部）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double scale = fushiAppleMacScale(context);
    final TextStyle titleStyle = TextStyle(
      fontSize: mac ? 17 * scale : 22,
      fontWeight: FontWeight.w700,
      height: 1.2,
      color: colors.label,
    );
    final TextStyle subStyle = TextStyle(
      fontSize: mac ? 12 * scale : 13,
      height: 1.3,
      color: colors.secondaryLabel,
    );
    final VoidCallback? viewAll = onViewAll;
    final String? sub = subtitle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              if (sub != null && sub.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subStyle,
                ),
              ],
            ],
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsetsDirectional.only(start: 8, bottom: 4),
            child: SizedBox.square(
              dimension: 14,
              child: FushiCircularProgressIndicator.adaptive(strokeWidth: 2),
            ),
          ),
        ?trailing,
        if (viewAll != null)
          AppleShelfViewAllButton(key: viewAllKey, onPressed: viewAll),
      ],
    );
  }
}

/// 货架头行尾的「查看全部 ›」：强调色文字，自成焦点停靠点（Enter 激活）。
class AppleShelfViewAllButton extends StatelessWidget {
  const AppleShelfViewAllButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double size = mac ? 13 * fushiAppleMacScale(context) : 15;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent _) {
            onPressed();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: FushiFocusId('apple-shelf-view-all-${identityHashCode(key)}'),
        child: Semantics(
          button: true,
          child: FushiPressScale(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onPressed,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 12,
                    top: 8,
                    bottom: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        t.manga_discovery_view_all,
                        style: TextStyle(fontSize: size, color: colors.accent),
                      ),
                      const SizedBox(width: 2),
                      FushiIcon(
                        CupertinoIcons.chevron_forward,
                        size: size * 0.85,
                        color: colors.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 给横滑条加悬停两端箭头（macOS 档 / 桌面指针）。子树里第一个横向
/// [Scrollable] 是被驱动的那条；箭头只在还能往那边滚时出现，淡入淡出时长取
/// [FushiMotion.short]。与设计系统无关的纯交互层（只在 Apple 货架里用）。
class AppleShelfHoverArrows extends StatefulWidget {
  const AppleShelfHoverArrows({required this.child, super.key});

  final Widget child;

  @override
  State<AppleShelfHoverArrows> createState() => _AppleShelfHoverArrowsState();
}

class _AppleShelfHoverArrowsState extends State<AppleShelfHoverArrows> {
  bool _hovering = false;
  ScrollMetrics? _metrics;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return false;
    final ScrollMetrics? old = _metrics;
    if (old == null ||
        old.pixels != metrics.pixels ||
        old.maxScrollExtent != metrics.maxScrollExtent) {
      setState(() => _metrics = metrics);
    }
    return false;
  }

  ScrollableState? _findScrollable() {
    ScrollableState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement &&
          element.state is ScrollableState &&
          (element.state as ScrollableState).position.axis == Axis.horizontal) {
        found = element.state as ScrollableState;
        return;
      }
      element.visitChildElements(visit);
    }

    (context as Element).visitChildElements(visit);
    return found;
  }

  void _page(int direction) {
    final ScrollableState? scrollable = _findScrollable();
    if (scrollable == null) return;
    final ScrollPosition position = scrollable.position;
    final double target =
        (position.pixels + direction * position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    if (duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      position.animateTo(
        target,
        duration: duration,
        curve: FushiMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = FushiAppleMetrics.of(context).desktop;
    final Widget body = NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (ScrollUpdateNotification n) => _onMetrics(n.metrics),
        child: widget.child,
      ),
    );
    if (!desktop) return body;
    final ScrollMetrics? m = _metrics;
    final bool canBack = m != null && m.pixels > m.minScrollExtent + 1;
    final bool canForward = m == null || m.pixels < m.maxScrollExtent - 1;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: <Widget>[
          body,
          PositionedDirectional(
            start: 4,
            top: 0,
            bottom: 0,
            child: _ShelfArrow(
              visible: _hovering && canBack,
              icon: CupertinoIcons.chevron_back,
              onTap: () => _page(-1),
            ),
          ),
          PositionedDirectional(
            end: 4,
            top: 0,
            bottom: 0,
            child: _ShelfArrow(
              visible: _hovering && canForward && (m?.maxScrollExtent ?? 1) > 0,
              icon: CupertinoIcons.chevron_forward,
              onTap: () => _page(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.visible,
    required this.icon,
    required this.onTap,
  });

  final bool visible;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final double size = 32 * fushiAppleMacScale(context);
    return Center(
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          child: ExcludeFocus(
            child: FushiPressScale(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onTap,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.secondaryGroupedBackground,
                      shape: BoxShape.circle,
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 10,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: SizedBox.square(
                      dimension: size,
                      child: Center(
                        child: FushiIcon(
                          icon,
                          size: size * 0.45,
                          color: colors.label,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// lockup 卡宽：iOS 260 / macOS 280 × 缩放。
double appleDiscoveryLockupWidth(BuildContext context) =>
    fushiAppleUsesMacMetrics(context) ? 280 * fushiAppleMacScale(context) : 260;

/// lockup 卡高（56 glyph + 上下各 12 内边距）。
double appleDiscoveryLockupHeight(BuildContext context) =>
    (56 + 24) * fushiAppleMacScale(context);

/// 来源 lockup 卡（方案 B「浏览来源」货架）：56pt 中性 glyph + 名字 + 副行 + 获取式
/// 按钮。整卡可点（同 [onTap]），获取式按钮是视觉提示、不另成焦点停靠点。
class AppleDiscoveryLockup extends StatelessWidget {
  const AppleDiscoveryLockup({
    required this.name,
    required this.actionLabel,
    required this.onTap,
    this.caption,
    this.icon,
    this.failed = false,
    this.focusId,
    super.key,
  });

  final String name;
  final String? caption;
  final ImageProvider? icon;

  /// 获取式按钮文案（「浏览」/「搜索」/「重试」）。
  final String actionLabel;
  final VoidCallback onTap;
  final bool failed;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final double scale = fushiAppleMacScale(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double glyph = 56 * scale;
    final String? sub = failed ? t.discovery_source_load_failed : caption;
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: FushiAppleGroupSurface(
          borderRadius: BorderRadius.circular((mac ? 12 : 18) * scale),
          child: FushiAppleRow(
            focusable: true,
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.all(12 * scale),
              child: Row(
                children: <Widget>[
                  AppleDiscoverySourceGlyph(
                    name: name,
                    icon: icon,
                    size: glyph,
                  ),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: (mac ? 13 : 15) * scale,
                            fontWeight: FontWeight.w600,
                            color: colors.label,
                          ),
                        ),
                        if (sub != null && sub.isNotEmpty) ...<Widget>[
                          SizedBox(height: 2 * scale),
                          Text(
                            sub,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: (mac ? 11.5 : 12.5) * scale,
                              color: failed
                                  ? colors.destructive
                                  : colors.secondaryLabel,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: 8 * scale),
                  ExcludeSemantics(
                    child: Container(
                      height: 28 * scale,
                      constraints: BoxConstraints(minWidth: 56 * scale),
                      padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        color: colors.fill,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        actionLabel,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: (mac ? 12.5 : 14) * scale,
                          fontWeight: FontWeight.w700,
                          color: colors.accent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条 lockup 货架：横滑、错峰由调用方的 [FushiEntranceScope] 决定；卡宽
/// [appleDiscoveryLockupWidth]，卡距 16（macOS）/ 12（iOS）。
class AppleDiscoveryLockupStrip extends StatelessWidget {
  const AppleDiscoveryLockupStrip({
    required this.children,
    required this.horizontalInset,
    super.key,
  });

  final List<Widget> children;
  final double horizontalInset;

  @override
  Widget build(BuildContext context) {
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double gap = mac ? 16 : 12;
    final double width = appleDiscoveryLockupWidth(context);
    return AppleShelfHoverArrows(
      child: SizedBox(
        // 悬停上浮放大留出上下余量。
        height: appleDiscoveryLockupHeight(context) + 16,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: EdgeInsets.symmetric(
            horizontal: horizontalInset,
            vertical: 8,
          ),
          itemCount: children.length,
          separatorBuilder: (BuildContext context, int index) =>
              SizedBox(width: gap),
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(width: math.max(width, 200), child: children[index]),
        ),
      ),
    );
  }
}
