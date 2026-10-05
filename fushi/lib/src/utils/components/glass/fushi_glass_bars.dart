import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart'
    show FushiTitleBarColorScope;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

// 顶栏族（AppBar / SliverAppBar / TabBar）的「设计系统分派」包装：构造参数与
// Material 原控件逐个同名同型，调用点只改类名。MD3 下原样构造原控件；玻璃下
// 是 Apple 26 的导航栏形态：
// - AppBar / SliverAppBar：仍是框架 AppBar（标题、bottom、系统状态栏样式、
//   返回键行为全不变），但背景透明、无阴影无底线——顶栏不是一整块玻璃，
//   玻璃只给栏上的控件：返回 / 关闭 / 抽屉键是一枚圆形玻璃钮，actions 收进
//   一枚玻璃胶囊（iOS 26 UIBarButtonItemGroup / messages 演示的 Edit 胶囊）。
//   标题桌面 20 bold 靠前、移动 17 semibold 居中（UINavigationBar 内联标题）。
// - TabBar：iOS 26 分段控件——中性填充的胶囊轨道，选中段是一枚白（深色下
//   浅灰）玻璃滑块，与 TabController 双向同步，Enter / 手柄 A 选中，方向键在
//   页签间移动焦点。

/// 圆形玻璃钮的直径（iOS 26 导航栏 bar button 实测 44）。
const double _kGlassBarControlExtent = 44;

/// 栏上玻璃控件里的图标字号（SF Symbols 在 44 圆钮 / 胶囊里实测 ≈ 19–20）。
const double _kGlassBarIconSize = 20;

/// 玻璃顶栏 leading 槽的宽：44 圆钮 + 离屏幕边 16（iOS 26 导航栏边距）。
const double _kGlassLeadingWidth = _kGlassBarControlExtent + 16;

/// 顶栏 scroll edge 带的高度（顶栏下沿往内容里延伸的那段渐隐）。
const double _kGlassTopEdgeExtent = 20;

/// SliverAppBar 在栏内下沿留出的 scroll edge 段：钉住后内容就在栏下面滚，
/// 这一段从实色渐隐成透明。
const double _kGlassSliverEdgeExtent = 16;

/// 玻璃顶栏上的一枚圆形玻璃底（返回键 / 单个导航钮）：里面的
/// [FushiIconButtonControl] 是透明玻璃按钮，焦点 / Enter / 语义都在它身上。
/// [alignment] 让 leading 槽里的圆钮贴着离屏幕边 16 的位置（槽宽
/// [_kGlassLeadingWidth]），而不是在 56 宽的槽里居中。
Widget _glassCircle(
  BuildContext context,
  Widget child, {
  AlignmentGeometry alignment = Alignment.center,
}) {
  return Align(
    alignment: alignment,
    child: SizedBox.square(
      dimension: _kGlassBarControlExtent,
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        shape: const LiquidOval(),
        child: IconTheme.merge(
          data: IconThemeData(
            size: _kGlassBarIconSize,
            color: appleColorsOf(context).label,
          ),
          child: Center(child: child),
        ),
      ),
    ),
  );
}

/// 把整组 actions 收进一枚玻璃胶囊（多个图标钮 = 一枚胶囊里并排，单个 =
/// 胶囊收成圆）。子组件原样挂在 Row 里，GlobalKey / 焦点 / 菜单锚点都不变；
/// 只是高度从 AppBar 的 stretch 改成胶囊内的 44 松约束。
Widget _glassActionsCapsule(BuildContext context, List<Widget> actions) {
  // 胶囊离屏幕边与 leading 圆钮对称：移动 16（iOS 导航栏边距）、桌面 12；
  // 胶囊里的图标统一 20 号 label 色（SF Symbols 在 bar button 里的字号），
  // 钮与钮之间不再另加缝——每枚钮自带 40–44 的点按区，排在一起就是 iOS
  // UIBarButtonItemGroup 的间距。
  return Center(
    child: Padding(
      padding: EdgeInsetsDirectional.only(
        end: _isDesktopBar(context) ? 12 : 16,
      ),
      child: GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        shape: const LiquidRoundedSuperellipse(
          borderRadius: _kGlassBarControlExtent / 2,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: _kGlassBarControlExtent,
            minHeight: _kGlassBarControlExtent,
            maxHeight: _kGlassBarControlExtent,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IconTheme.merge(
              data: IconThemeData(
                size: _kGlassBarIconSize,
                color: appleColorsOf(context).label,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 桌面（Windows / macOS / Linux）用 macOS 26 的窗口标题字阶，移动用 iOS 的
/// 内联导航栏标题。
bool _isDesktopBar(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 玻璃顶栏的默认标题字阶：桌面 20 bold、移动 17 semibold（label 色）。
TextStyle _glassTitleStyle(BuildContext context) {
  final bool desktop = _isDesktopBar(context);
  return (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
    fontSize: desktop ? 20 : 17,
    fontWeight: desktop ? FontWeight.w700 : FontWeight.w600,
    color: appleColorsOf(context).label,
  );
}

/// 与框架 AppBar 同一判据推出隐含 leading（抽屉键 / 关闭键 / 返回键），
/// 但渲染成圆形玻璃钮（SF 风格图标）。推不出时返回 null（交回 AppBar，它同样
/// 推不出）。
Widget? _impliedGlassLeading(BuildContext context) {
  final ScaffoldState? scaffold = Scaffold.maybeOf(context);
  final ModalRoute<dynamic>? parentRoute = ModalRoute.of(context);
  final MaterialLocalizations l10n = MaterialLocalizations.of(context);
  final Color fg = appleColorsOf(context).label;
  if (scaffold?.hasDrawer ?? false) {
    return _glassCircle(
      context,
      alignment: AlignmentDirectional.centerEnd,
      FushiIconButtonControl(
        icon: FushiIcon(CupertinoIcons.line_horizontal_3, color: fg, size: 20),
        tooltip: l10n.openAppDrawerTooltip,
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    );
  }
  if (parentRoute?.impliesAppBarDismissal ?? false) {
    final bool useCloseButton =
        parentRoute is PageRoute<dynamic> && parentRoute.fullscreenDialog;
    return _glassCircle(
      context,
      alignment: AlignmentDirectional.centerEnd,
      FushiIconButtonControl(
        icon: FushiIcon(
          useCloseButton ? CupertinoIcons.xmark : CupertinoIcons.chevron_back,
          color: fg,
          size: useCloseButton ? 18 : 22,
        ),
        tooltip: useCloseButton
            ? l10n.closeButtonTooltip
            : l10n.backButtonTooltip,
        onPressed: () => Navigator.maybePop(context),
      ),
    );
  }
  return null;
}

Widget? _glassLeading(
  BuildContext context, {
  required Widget? leading,
  required bool automaticallyImplyLeading,
}) {
  if (leading != null) {
    // 调用方给的图标按钮 / 返回 / 关闭键同样落进圆形玻璃底；其它 leading
    // （头像、品牌位……）原样交给 AppBar。
    if (leading is FushiIconButtonControl ||
        leading is IconButton ||
        leading is BackButton ||
        leading is CloseButton) {
      return _glassCircle(
        context,
        leading,
        alignment: AlignmentDirectional.centerEnd,
      );
    }
    return leading;
  }
  if (!automaticallyImplyLeading) return null;
  return _impliedGlassLeading(context);
}

List<Widget>? _glassActions(
  BuildContext context, {
  required List<Widget>? actions,
  required bool automaticallyImplyActions,
}) {
  List<Widget>? resolved = actions;
  if ((resolved == null || resolved.isEmpty) &&
      automaticallyImplyActions &&
      (Scaffold.maybeOf(context)?.hasEndDrawer ?? false)) {
    resolved = <Widget>[
      FushiIconButtonControl(
        icon: const FushiIcon(CupertinoIcons.sidebar_right, size: 20),
        tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
        onPressed: () => Scaffold.of(context).openEndDrawer(),
      ),
    ];
  }
  if (resolved == null || resolved.isEmpty) return resolved;
  return <Widget>[_glassActionsCapsule(context, resolved)];
}

/// 返回键图标统一：MD3 一律 Material 的 `arrow_back`（框架在 iOS / macOS 上
/// 默认给 `arrow_back_ios`，与其余平台不一致）；Apple 下调用方给的
/// [BackButton] 也画成 SF 风格的 chevron（它落在圆形玻璃钮里）。
class _BackIconTheme extends StatelessWidget {
  const _BackIconTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ActionIconThemeData base =
        ActionIconTheme.of(context) ?? const ActionIconThemeData();
    return ActionIconTheme(
      data: base.copyWith(
        backButtonIconBuilder: (BuildContext context) => glass
            ? const FushiIcon(CupertinoIcons.chevron_back, size: 22)
            : const Icon(Icons.arrow_back),
      ),
      child: child,
    );
  }
}

/// Apple 26 的 scroll edge effect（顶栏版）：内容滚到顶栏下面之后，顶栏下沿
/// 往内容里延伸一段 soft 渐隐 + 渐进模糊（[FushiAppleScrollEdge]），内容是
/// 「化进」栏里而不是被一刀切掉。是否滚到栏下用与框架 AppBar 同一个判据
/// （Scaffold 的 [ScrollNotificationObserver] + [notificationPredicate]）。
/// 边缘带画在栏的盒子外面（Stack 不裁剪），Scaffold 先画 body 后画 appBar，
/// 所以它正好盖在正文顶部；不参与命中测试。[enabled] 为 false（MD3）时只是
/// 一层透传的 Stack。
///
/// MD3 下同一个滚动判据还喂桌面自绘顶栏：主题顶栏滚到内容上面后换成
/// surfaceContainer（[md3ScrolledColor]），而自绘顶栏挂在 Navigator 外只认根
/// 主题 surface——不跟着上报，两条栏之间就切出一道色带。只有贴着窗口顶、
/// 横跨整个 Navigator 宽的顶栏才上报（对话框 / 分栏里的顶栏不碰窗口顶栏）。
class _AppleBarScrollEdge extends StatefulWidget {
  const _AppleBarScrollEdge({
    required this.enabled,
    required this.notificationPredicate,
    required this.child,
    this.md3ScrolledColor,
  });

  final bool enabled;
  final ScrollNotificationPredicate notificationPredicate;
  final Widget child;

  /// MD3 顶栏滚到内容上面之后的实际底色；null = 不随滚动换色（Apple、显式
  /// 底色、透明顶栏），不向桌面顶栏上报。
  final Color? md3ScrolledColor;

  @override
  State<_AppleBarScrollEdge> createState() => _AppleBarScrollEdgeState();
}

class _AppleBarScrollEdgeState extends State<_AppleBarScrollEdge> {
  ScrollNotificationObserverState? _observer;
  bool _scrolledUnder = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handleScroll);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handleScroll);
    _observer = null;
    super.dispose();
  }

  /// 本栏是否贴着窗口顶、横跨整个根 Navigator（= 紧挨在桌面自绘顶栏下面）。
  bool _spansWindowTop() {
    final RenderObject? box = context.findRenderObject();
    final RenderObject? nav = Navigator.maybeOf(
      context,
      rootNavigator: true,
    )?.context.findRenderObject();
    if (box is! RenderBox || nav is! RenderBox) return false;
    if (!box.hasSize || !nav.hasSize || !box.attached || !nav.attached) {
      return false;
    }
    final Rect rect = MatrixUtils.transformRect(
      box.getTransformTo(nav),
      Offset.zero & box.size,
    );
    return rect.top.abs() < 1 &&
        rect.left.abs() < 1 &&
        (rect.right - nav.size.width).abs() < 1;
  }

  bool _atWindowTop = false;

  void _handleScroll(ScrollNotification notification) {
    if (!widget.enabled && widget.md3ScrolledColor == null) return;
    if (notification is! ScrollUpdateNotification ||
        !widget.notificationPredicate(notification)) {
      return;
    }
    final ScrollMetrics metrics = notification.metrics;
    final bool under = switch (metrics.axisDirection) {
      AxisDirection.up => metrics.extentAfter > 0,
      AxisDirection.down => metrics.extentBefore > 0,
      AxisDirection.left || AxisDirection.right => _scrolledUnder,
    };
    if (under != _scrolledUnder && mounted) {
      final bool atTop = !widget.enabled && under && _spansWindowTop();
      setState(() {
        _scrolledUnder = under;
        _atWindowTop = atTop;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color? scrolled = widget.md3ScrolledColor;
    // 结构恒定：两套设计系统、滚没滚动都挂着这层上报，只换 colors（null =
    // 不表态，顶栏回落根主题）。
    return FushiTitleBarColorScope(
      colors: !widget.enabled && scrolled != null && _scrolledUnder &&
              _atWindowTop
          ? (
              background: scrolled,
              foreground: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: <Widget>[
          widget.child,
          if (widget.enabled)
            Positioned(
              left: 0,
              right: 0,
              bottom: -_kGlassTopEdgeExtent,
              height: _kGlassTopEdgeExtent,
              child: FushiAppleScrollEdge(
                side: FushiScrollEdgeSide.top,
                visible: _scrolledUnder,
              ),
            ),
        ],
      ),
    );
  }
}

/// MD3 主题顶栏滚到内容上面之后的底色（[AppBarTheme.backgroundColor] 是
/// 按 scrolledUnder 解析的 [WidgetStateColor]）；调用方给了显式底色、强制透明、
/// 或主题底色不随滚动变时返回 null。
Color? _md3ScrolledAppBarColor(
  BuildContext context, {
  required Color? backgroundColor,
  required bool forceMaterialTransparency,
  required bool primary,
}) {
  if (backgroundColor != null || forceMaterialTransparency || !primary) {
    return null;
  }
  final Color? themed = AppBarTheme.of(context).backgroundColor;
  if (themed is! WidgetStateColor) return null;
  final Color scrolled = themed.resolve(<WidgetState>{
    WidgetState.scrolledUnder,
  });
  final Color idle = themed.resolve(<WidgetState>{});
  return scrolled == idle || scrolled.a < 1 ? null : scrolled;
}

/// [AppBar] 的设计系统分派版。[preferredSize] 与 AppBar 同一对象形态
/// （Scaffold 经 `AppBar.preferredHeightFor` 读主题 toolbarHeight 依赖它）。
class FushiAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FushiAppBar({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.actions,
    this.automaticallyImplyActions = true,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.shadowColor,
    this.surfaceTintColor,
    this.shape,
    this.backgroundColor,
    this.foregroundColor,
    this.iconTheme,
    this.actionsIconTheme,
    this.primary = true,
    this.centerTitle,
    this.excludeHeaderSemantics = false,
    this.titleSpacing,
    this.toolbarOpacity = 1.0,
    this.bottomOpacity = 1.0,
    this.toolbarHeight,
    this.leadingWidth,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.forceMaterialTransparency = false,
    this.useDefaultSemanticsOrder = true,
    this.clipBehavior,
    this.actionsPadding,
    this.animateColor = false,
  });

  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? title;
  final List<Widget>? actions;
  final bool automaticallyImplyActions;
  final Widget? flexibleSpace;
  final PreferredSizeWidget? bottom;
  final double? elevation;
  final double? scrolledUnderElevation;
  final ScrollNotificationPredicate notificationPredicate;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final ShapeBorder? shape;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final IconThemeData? iconTheme;
  final IconThemeData? actionsIconTheme;
  final bool primary;
  final bool? centerTitle;
  final bool excludeHeaderSemantics;
  final double? titleSpacing;
  final double toolbarOpacity;
  final double bottomOpacity;
  final double? toolbarHeight;
  final double? leadingWidth;
  final TextStyle? toolbarTextStyle;
  final TextStyle? titleTextStyle;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool forceMaterialTransparency;
  final bool useDefaultSemanticsOrder;
  final Clip? clipBehavior;
  final EdgeInsetsGeometry? actionsPadding;
  final bool animateColor;

  @override
  Size get preferredSize =>
      AppBar(toolbarHeight: toolbarHeight, bottom: bottom).preferredSize;

  /// Material（M3E）下是否画成悬浮胶囊顶栏：调用方自带 [flexibleSpace]（hero
  /// 背景图等）时保留原形态——那种栏本身就是页面的一部分，不是工具栏。
  bool get _floatingMaterial => flexibleSpace == null;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final bool floating = !glass && _floatingMaterial;
    // 结构恒定：两套设计系统都包同一层返回键图标主题 + scroll edge 观察层 +
    // 悬浮收起层，只换参数。
    return _BackIconTheme(
      child: _AppleBarScrollEdge(
        enabled: glass,
        notificationPredicate: notificationPredicate,
        md3ScrolledColor: glass || floating
            ? null
            : _md3ScrolledAppBarColor(
                context,
                backgroundColor: backgroundColor,
                forceMaterialTransparency: forceMaterialTransparency,
                primary: primary,
              ),
        child: _M3eAppBarScrollAway(
          enabled: floating,
          notificationPredicate: notificationPredicate,
          builder: (FushiScrollAwayController chrome) =>
              _buildBar(context, glass, floating ? chrome : null),
        ),
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    bool glass,
    FushiScrollAwayController? floating,
  ) {
    if (floating != null) return _buildFloating(context, floating);
    return AppBar(
      leading: glass
          ? _glassLeading(
              context,
              leading: leading,
              automaticallyImplyLeading: automaticallyImplyLeading,
            )
          : leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      title: title,
      actions: glass
          ? _glassActions(
              context,
              actions: actions,
              automaticallyImplyActions: automaticallyImplyActions,
            )
          : actions,
      automaticallyImplyActions: automaticallyImplyActions,
      flexibleSpace: flexibleSpace,
      bottom: bottom,
      elevation: glass ? 0 : elevation,
      scrolledUnderElevation: glass ? 0 : scrolledUnderElevation,
      notificationPredicate: notificationPredicate,
      shadowColor: glass ? Colors.transparent : shadowColor,
      surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
      shape: shape,
      // 透明：页面的实色分组底直接透上来，顶栏本身不是玻璃。
      backgroundColor: glass ? Colors.transparent : backgroundColor,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      actionsIconTheme: actionsIconTheme,
      primary: primary,
      centerTitle: glass
          ? (centerTitle ?? !_isDesktopBar(context))
          : centerTitle,
      excludeHeaderSemantics: excludeHeaderSemantics,
      titleSpacing: titleSpacing,
      toolbarOpacity: toolbarOpacity,
      bottomOpacity: bottomOpacity,
      toolbarHeight: toolbarHeight,
      leadingWidth: glass
          ? (leadingWidth ?? _kGlassLeadingWidth)
          : leadingWidth,
      toolbarTextStyle: toolbarTextStyle,
      titleTextStyle: glass
          ? (titleTextStyle ?? _glassTitleStyle(context))
          : titleTextStyle,
      systemOverlayStyle: systemOverlayStyle,
      forceMaterialTransparency: forceMaterialTransparency,
      useDefaultSemanticsOrder: useDefaultSemanticsOrder,
      clipBehavior: clipBehavior,
      actionsPadding: actionsPadding,
      animateColor: animateColor,
    );
  }

  /// M3E 悬浮顶栏（2026-10-05「全部用浮动工具栏统一」）：栏本身透明无阴影，
  /// 返回 / 关闭 / 抽屉键是一枚圆形悬浮胶囊，标题是一枚标题胶囊，actions
  /// 收进一枚按钮组胶囊；内容往下滚时标题与动作收起、往回滚时弹回（返回键
  /// 常驻）。子组件原样挂进胶囊，key / 焦点 / 菜单锚点不变。
  Widget _buildFloating(
    BuildContext context,
    FushiScrollAwayController chrome,
  ) {
    final Widget? resolvedLeading = leading != null
        ? fushiFloatingLeading(leading)
        : (automaticallyImplyLeading ? _impliedM3eLeading(context) : null);
    List<Widget>? resolvedActions = actions;
    if ((resolvedActions == null || resolvedActions.isEmpty) &&
        automaticallyImplyActions &&
        (Scaffold.maybeOf(context)?.hasEndDrawer ?? false)) {
      resolvedActions = <Widget>[
        IconButton(
          icon: const Icon(Icons.menu),
          tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
          onPressed: () => Scaffold.of(context).openEndDrawer(),
        ),
      ];
    }
    final List<Widget>? finalActions = resolvedActions;
    final bool desktop = _isDesktopBar(context);
    final double edge = desktop ? 12 : 16;
    return AppBar(
      leading: resolvedLeading == null
          ? null
          : Align(
              alignment: AlignmentDirectional.centerEnd,
              child: resolvedLeading,
            ),
      automaticallyImplyLeading: false,
      title: _floatingTitleCapsule(title, chrome),
      actions: finalActions == null || finalActions.isEmpty
          ? null
          : <Widget>[
              Center(
                child: Padding(
                  padding: EdgeInsetsDirectional.only(end: edge),
                  child: FushiScrollAwayChrome(
                    controller: chrome,
                    child: FushiPageChromeCapsule(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: finalActions,
                      ),
                    ),
                  ),
                ),
              ),
            ],
      automaticallyImplyActions: false,
      bottom: bottom,
      elevation: 0,
      scrolledUnderElevation: 0,
      notificationPredicate: notificationPredicate,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      // 透明：页面底色直接透上来，栏上只剩几颗悬浮胶囊。
      backgroundColor: backgroundColor ?? Colors.transparent,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      actionsIconTheme: actionsIconTheme,
      primary: primary,
      centerTitle: centerTitle ?? false,
      excludeHeaderSemantics: excludeHeaderSemantics,
      titleSpacing: titleSpacing ?? 8,
      toolbarOpacity: toolbarOpacity,
      bottomOpacity: bottomOpacity,
      toolbarHeight: toolbarHeight,
      leadingWidth: leadingWidth ?? (kFushiPageChromeExtent + edge),
      toolbarTextStyle: toolbarTextStyle,
      titleTextStyle: titleTextStyle,
      systemOverlayStyle: systemOverlayStyle,
      forceMaterialTransparency: forceMaterialTransparency,
      useDefaultSemanticsOrder: useDefaultSemanticsOrder,
      clipBehavior: clipBehavior,
      actionsPadding: actionsPadding,
      animateColor: animateColor,
    );
  }
}

/// 悬浮顶栏的标题胶囊。标题为空（null / 空串 [Text] / 零尺寸占位）时不画胶囊——
/// 否则返回键旁会留一颗空胶囊（合集详情页把标题交给 hero）。标题外层若是
/// [AnimatedOpacity] / [Opacity]（「hero 滚出视野后才淡入标题」），把透明度提到
/// 胶囊**外面**，整颗胶囊随标题一起淡入淡出，而不是只淡文字、空壳常驻。
Widget? _floatingTitleCapsule(
  Widget? title,
  FushiScrollAwayController chrome,
) {
  if (title == null || _isEmptyTitle(title)) return null;
  Widget capsule(Widget inner) => FushiScrollAwayChrome(
        controller: chrome,
        child: FushiPageChromeTitle(title: inner),
      );
  final Widget current = title;
  if (current is AnimatedOpacity && current.child != null) {
    if (_isEmptyTitle(current.child!)) return null;
    return IgnorePointer(
      ignoring: current.opacity == 0,
      child: AnimatedOpacity(
        opacity: current.opacity,
        duration: current.duration,
        curve: current.curve,
        alwaysIncludeSemantics: current.alwaysIncludeSemantics,
        child: capsule(current.child!),
      ),
    );
  }
  if (current is Opacity && current.child != null) {
    if (_isEmptyTitle(current.child!)) return null;
    return IgnorePointer(
      ignoring: current.opacity == 0,
      child: Opacity(
        opacity: current.opacity,
        alwaysIncludeSemantics: current.alwaysIncludeSemantics,
        child: capsule(current.child!),
      ),
    );
  }
  return capsule(current);
}

/// 标题 widget 是否「什么都不显示」：空串 / 纯空白的 [Text]、无子的零尺寸
/// [SizedBox]。
bool _isEmptyTitle(Widget title) {
  if (title is Text) {
    final String? data = title.data;
    if (data != null) return data.trim().isEmpty;
    final String? rich = title.textSpan?.toPlainText();
    return rich != null && rich.trim().isEmpty;
  }
  if (title is SizedBox) {
    return title.child == null &&
        (title.width == 0 || title.height == 0);
  }
  return false;
}

/// 与框架 AppBar 同一判据推出 M3E 悬浮顶栏的隐含 leading（抽屉键 / 关闭键 /
/// 返回键），装进圆形悬浮胶囊。推不出时返回 null。
Widget? _impliedM3eLeading(BuildContext context) {
  final ScaffoldState? scaffold = Scaffold.maybeOf(context);
  final ModalRoute<dynamic>? parentRoute = ModalRoute.of(context);
  if (scaffold?.hasDrawer ?? false) {
    return FushiPageChromeCircle(
      child: IconButton(
        icon: const Icon(Icons.menu),
        tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    );
  }
  if (parentRoute?.impliesAppBarDismissal ?? false) {
    final bool useCloseButton =
        parentRoute is PageRoute<dynamic> && parentRoute.fullscreenDialog;
    return FushiPageChromeCircle(
      child: useCloseButton ? const CloseButton() : const BackButton(),
    );
  }
  return null;
}

/// 悬浮顶栏的「随滚动收起」状态源：订阅 Scaffold 的
/// [ScrollNotificationObserver]（与框架 AppBar 判 scrolledUnder 同一来源），
/// 把用户滚动方向喂给 [FushiScrollAwayController]。[enabled] 为 false 时不喂
/// （Apple / 非悬浮形态），树结构不变。
class _M3eAppBarScrollAway extends StatefulWidget {
  const _M3eAppBarScrollAway({
    required this.enabled,
    required this.notificationPredicate,
    required this.builder,
  });

  final bool enabled;
  final ScrollNotificationPredicate notificationPredicate;
  final Widget Function(FushiScrollAwayController chrome) builder;

  @override
  State<_M3eAppBarScrollAway> createState() => _M3eAppBarScrollAwayState();
}

class _M3eAppBarScrollAwayState extends State<_M3eAppBarScrollAway> {
  final FushiScrollAwayController _chrome = FushiScrollAwayController();
  ScrollNotificationObserverState? _observer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handle);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handle);
  }

  void _handle(ScrollNotification notification) {
    if (!widget.enabled || !widget.notificationPredicate(notification)) return;
    _chrome.handleNotification(notification);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handle);
    _observer = null;
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_chrome);
}

/// [SliverAppBar] 的变体：普通 / medium / large（M3 可收起的大标题栏）。
enum _FushiSliverAppBarVariant { small, medium, large }

/// [SliverAppBar] 的设计系统分派版（含 `.medium` / `.large`）。
///
/// - MD3：原样构造 [SliverAppBar] / [SliverAppBar.medium] /
///   [SliverAppBar.large]（M3 的 headlineSmall / headlineMedium 大标题随滚动
///   收进 22 号的小标题）。
/// - Apple 26：有标题、调用方没自带 flexibleSpace 时是 iOS 大标题导航栏——
///   大标题（iOS 34 / 桌面 26 bold，靠前）排在工具栏下面，随滚动被工具栏
///   「吃进去」并淡出，同时居中的 17 semibold 小标题淡入；栏钉住（floating
///   栏除外）。钉住后内容在栏下面滚，栏的下沿是一段 scroll edge 渐隐。
class FushiSliverAppBar extends StatelessWidget {
  const FushiSliverAppBar({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.actions,
    this.automaticallyImplyActions = true,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.forceElevated = false,
    this.backgroundColor,
    this.foregroundColor,
    this.iconTheme,
    this.actionsIconTheme,
    this.primary = true,
    this.centerTitle,
    this.excludeHeaderSemantics = false,
    this.titleSpacing,
    this.collapsedHeight,
    this.expandedHeight,
    this.floating = false,
    this.pinned = false,
    this.snap = false,
    this.stretch = false,
    this.stretchTriggerOffset = 100.0,
    this.onStretchTrigger,
    this.shape,
    this.toolbarHeight = kToolbarHeight,
    this.leadingWidth,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.forceMaterialTransparency = false,
    this.useDefaultSemanticsOrder = true,
    this.clipBehavior,
    this.actionsPadding,
  }) : _variant = _FushiSliverAppBarVariant.small;

  /// [SliverAppBar.medium] 的分派版（默认钉住、工具栏 64）。
  const FushiSliverAppBar.medium({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.actions,
    this.automaticallyImplyActions = true,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.forceElevated = false,
    this.backgroundColor,
    this.foregroundColor,
    this.iconTheme,
    this.actionsIconTheme,
    this.primary = true,
    this.centerTitle,
    this.excludeHeaderSemantics = false,
    this.titleSpacing,
    this.collapsedHeight,
    this.expandedHeight,
    this.floating = false,
    this.pinned = true,
    this.snap = false,
    this.stretch = false,
    this.stretchTriggerOffset = 100.0,
    this.onStretchTrigger,
    this.shape,
    this.toolbarHeight = 64,
    this.leadingWidth,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.forceMaterialTransparency = false,
    this.useDefaultSemanticsOrder = true,
    this.clipBehavior,
    this.actionsPadding,
  }) : _variant = _FushiSliverAppBarVariant.medium;

  /// [SliverAppBar.large] 的分派版（默认钉住、工具栏 64）。
  const FushiSliverAppBar.large({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.actions,
    this.automaticallyImplyActions = true,
    this.flexibleSpace,
    this.bottom,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.forceElevated = false,
    this.backgroundColor,
    this.foregroundColor,
    this.iconTheme,
    this.actionsIconTheme,
    this.primary = true,
    this.centerTitle,
    this.excludeHeaderSemantics = false,
    this.titleSpacing,
    this.collapsedHeight,
    this.expandedHeight,
    this.floating = false,
    this.pinned = true,
    this.snap = false,
    this.stretch = false,
    this.stretchTriggerOffset = 100.0,
    this.onStretchTrigger,
    this.shape,
    this.toolbarHeight = 64,
    this.leadingWidth,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.forceMaterialTransparency = false,
    this.useDefaultSemanticsOrder = true,
    this.clipBehavior,
    this.actionsPadding,
  }) : _variant = _FushiSliverAppBarVariant.large;

  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? title;
  final List<Widget>? actions;
  final bool automaticallyImplyActions;
  final Widget? flexibleSpace;
  final PreferredSizeWidget? bottom;
  final double? elevation;
  final double? scrolledUnderElevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final bool forceElevated;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final IconThemeData? iconTheme;
  final IconThemeData? actionsIconTheme;
  final bool primary;
  final bool? centerTitle;
  final bool excludeHeaderSemantics;
  final double? titleSpacing;
  final double? collapsedHeight;
  final double? expandedHeight;
  final bool floating;
  final bool pinned;
  final bool snap;
  final bool stretch;
  final double stretchTriggerOffset;
  final AsyncCallback? onStretchTrigger;
  final ShapeBorder? shape;
  final double toolbarHeight;
  final double? leadingWidth;
  final TextStyle? toolbarTextStyle;
  final TextStyle? titleTextStyle;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool forceMaterialTransparency;
  final bool useDefaultSemanticsOrder;
  final Clip? clipBehavior;
  final EdgeInsetsGeometry? actionsPadding;
  final _FushiSliverAppBarVariant _variant;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) return _BackIconTheme(child: _material());
    return _BackIconTheme(child: _glass(context));
  }

  SliverAppBar _material() {
    switch (_variant) {
      case _FushiSliverAppBarVariant.small:
        return SliverAppBar(
          leading: leading,
          automaticallyImplyLeading: automaticallyImplyLeading,
          title: title,
          actions: actions,
          automaticallyImplyActions: automaticallyImplyActions,
          flexibleSpace: flexibleSpace,
          bottom: bottom,
          elevation: elevation,
          scrolledUnderElevation: scrolledUnderElevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          forceElevated: forceElevated,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          iconTheme: iconTheme,
          actionsIconTheme: actionsIconTheme,
          primary: primary,
          centerTitle: centerTitle,
          excludeHeaderSemantics: excludeHeaderSemantics,
          titleSpacing: titleSpacing,
          collapsedHeight: collapsedHeight,
          expandedHeight: expandedHeight,
          floating: floating,
          pinned: pinned,
          snap: snap,
          stretch: stretch,
          stretchTriggerOffset: stretchTriggerOffset,
          onStretchTrigger: onStretchTrigger,
          shape: shape,
          toolbarHeight: toolbarHeight,
          leadingWidth: leadingWidth,
          toolbarTextStyle: toolbarTextStyle,
          titleTextStyle: titleTextStyle,
          systemOverlayStyle: systemOverlayStyle,
          forceMaterialTransparency: forceMaterialTransparency,
          useDefaultSemanticsOrder: useDefaultSemanticsOrder,
          clipBehavior: clipBehavior,
          actionsPadding: actionsPadding,
        );
      case _FushiSliverAppBarVariant.medium:
        return SliverAppBar.medium(
          leading: leading,
          automaticallyImplyLeading: automaticallyImplyLeading,
          title: title,
          actions: actions,
          automaticallyImplyActions: automaticallyImplyActions,
          flexibleSpace: flexibleSpace,
          bottom: bottom,
          elevation: elevation,
          scrolledUnderElevation: scrolledUnderElevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          forceElevated: forceElevated,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          iconTheme: iconTheme,
          actionsIconTheme: actionsIconTheme,
          primary: primary,
          centerTitle: centerTitle,
          excludeHeaderSemantics: excludeHeaderSemantics,
          titleSpacing: titleSpacing,
          collapsedHeight: collapsedHeight,
          expandedHeight: expandedHeight,
          floating: floating,
          pinned: pinned,
          snap: snap,
          stretch: stretch,
          stretchTriggerOffset: stretchTriggerOffset,
          onStretchTrigger: onStretchTrigger,
          shape: shape,
          toolbarHeight: toolbarHeight,
          leadingWidth: leadingWidth,
          toolbarTextStyle: toolbarTextStyle,
          titleTextStyle: titleTextStyle,
          systemOverlayStyle: systemOverlayStyle,
          forceMaterialTransparency: forceMaterialTransparency,
          useDefaultSemanticsOrder: useDefaultSemanticsOrder,
          clipBehavior: clipBehavior,
          actionsPadding: actionsPadding,
        );
      case _FushiSliverAppBarVariant.large:
        return SliverAppBar.large(
          leading: leading,
          automaticallyImplyLeading: automaticallyImplyLeading,
          title: title,
          actions: actions,
          automaticallyImplyActions: automaticallyImplyActions,
          flexibleSpace: flexibleSpace,
          bottom: bottom,
          elevation: elevation,
          scrolledUnderElevation: scrolledUnderElevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          forceElevated: forceElevated,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          iconTheme: iconTheme,
          actionsIconTheme: actionsIconTheme,
          primary: primary,
          centerTitle: centerTitle,
          excludeHeaderSemantics: excludeHeaderSemantics,
          titleSpacing: titleSpacing,
          collapsedHeight: collapsedHeight,
          expandedHeight: expandedHeight,
          floating: floating,
          pinned: pinned,
          snap: snap,
          stretch: stretch,
          stretchTriggerOffset: stretchTriggerOffset,
          onStretchTrigger: onStretchTrigger,
          shape: shape,
          toolbarHeight: toolbarHeight,
          leadingWidth: leadingWidth,
          toolbarTextStyle: toolbarTextStyle,
          titleTextStyle: titleTextStyle,
          systemOverlayStyle: systemOverlayStyle,
          forceMaterialTransparency: forceMaterialTransparency,
          useDefaultSemanticsOrder: useDefaultSemanticsOrder,
          clipBehavior: clipBehavior,
          actionsPadding: actionsPadding,
        );
    }
  }

  Widget _glass(BuildContext context) {
    final bool desktop = _isDesktopBar(context);
    // 自带 flexibleSpace（封面头图之类）的调用方有自己的设计，只换控件皮肤、
    // 不接大标题与渐隐底。
    final bool ownBackdrop = flexibleSpace == null;
    final Widget? resolvedTitle = title;
    final bool largeTitle =
        ownBackdrop &&
        resolvedTitle != null &&
        (_variant != _FushiSliverAppBarVariant.small || expandedHeight == null);
    final double bottomHeight = bottom?.preferredSize.height ?? 0;
    final double band = desktop
        ? _kAppleLargeTitleBandDesktop
        : _kAppleLargeTitleBand;
    final Color pageColor = Theme.of(context).scaffoldBackgroundColor;
    return SliverAppBar(
      leading: _glassLeading(
        context,
        leading: leading,
        automaticallyImplyLeading: automaticallyImplyLeading,
      ),
      automaticallyImplyLeading: automaticallyImplyLeading,
      title: largeTitle
          ? _AppleCollapsedTitle(band: band, child: resolvedTitle)
          : resolvedTitle,
      actions: _glassActions(
        context,
        actions: actions,
        automaticallyImplyActions: automaticallyImplyActions,
      ),
      automaticallyImplyActions: automaticallyImplyActions,
      flexibleSpace: ownBackdrop
          ? _AppleSliverBackdrop(
              color: pageColor,
              largeTitle: largeTitle ? resolvedTitle : null,
              largeTitleStyle: _glassLargeTitleStyle(context),
              band: band,
              bottomHeight: bottomHeight,
              horizontalPadding: desktop ? 20 : 16,
            )
          : flexibleSpace,
      bottom: bottom,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      forceElevated: forceElevated,
      // 不是玻璃面。自绘底（[_AppleSliverBackdrop]）时栏本身透明——底与
      // 下沿渐隐由它画；调用方自带 flexibleSpace 时仍是页面实色底，钉住时
      // 滚上来的内容不会从标题底下透出来。
      backgroundColor: ownBackdrop ? Colors.transparent : pageColor,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      actionsIconTheme: actionsIconTheme,
      primary: primary,
      centerTitle: largeTitle ? true : (centerTitle ?? !desktop),
      excludeHeaderSemantics: excludeHeaderSemantics,
      titleSpacing: titleSpacing,
      collapsedHeight: collapsedHeight,
      expandedHeight: largeTitle
          ? (expandedHeight ?? toolbarHeight + band + bottomHeight)
          : expandedHeight,
      floating: floating,
      // iOS 的大标题导航栏恒钉住；floating 栏保留调用方的行为。
      pinned: largeTitle && !floating ? true : pinned,
      snap: snap,
      stretch: stretch,
      stretchTriggerOffset: stretchTriggerOffset,
      onStretchTrigger: onStretchTrigger,
      shape: shape,
      toolbarHeight: toolbarHeight,
      leadingWidth: leadingWidth ?? _kGlassLeadingWidth,
      toolbarTextStyle: toolbarTextStyle,
      titleTextStyle:
          titleTextStyle ??
          (largeTitle
              ? _glassInlineTitleStyle(context)
              : _glassTitleStyle(context)),
      systemOverlayStyle: systemOverlayStyle,
      forceMaterialTransparency: forceMaterialTransparency,
      useDefaultSemanticsOrder: useDefaultSemanticsOrder,
      clipBehavior: clipBehavior,
      actionsPadding: actionsPadding,
    );
  }
}

/// iOS 大标题行占的高度（UINavigationBar 大标题模式 96 − 内联 44 = 52）；
/// macOS 26 的窗口大标题小一号。
const double _kAppleLargeTitleBand = 52;
const double _kAppleLargeTitleBandDesktop = 44;

/// 大标题字阶：iOS 34 bold、桌面 26 bold（label 色）。
TextStyle _glassLargeTitleStyle(BuildContext context) {
  final bool desktop = _isDesktopBar(context);
  return (Theme.of(context).textTheme.headlineMedium ?? const TextStyle())
      .copyWith(
        fontSize: desktop ? 26 : 34,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: desktop ? 0 : 0.37,
        color: appleColorsOf(context).label,
      );
}

/// 大标题收起后的内联小标题：17 semibold、居中（两端一致）。
TextStyle _glassInlineTitleStyle(BuildContext context) {
  return (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
      .copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: appleColorsOf(context).label,
      );
}

/// 大标题行还露在外面的高度（0 = 完全收进工具栏）。读 SliverAppBar 提供的
/// [FlexibleSpaceBarSettings]；读不到（不在 SliverAppBar 里）当作已收起。
double _visibleLargeTitleBand(BuildContext context) {
  final FlexibleSpaceBarSettings? settings = context
      .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
  if (settings == null) return 0;
  return math.max(0, settings.currentExtent - settings.minExtent);
}

/// 工具栏里的内联小标题：大标题还露着时隐藏，大标题快收进工具栏时淡入。
/// 纯由滚动位置驱动（不是定时动画），减弱动态效果下同样跟手。
class _AppleCollapsedTitle extends StatelessWidget {
  const _AppleCollapsedTitle({required this.band, required this.child});

  final double band;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double visible = _visibleLargeTitleBand(context);
    final double opacity = (1 - visible / (band * 0.45)).clamp(0.0, 1.0);
    return ExcludeSemantics(
      excluding: opacity == 0,
      child: Opacity(opacity: opacity, child: child),
    );
  }
}

/// Apple 大标题 SliverAppBar 的底：页面实色 + 下沿 scroll edge 段（钉住后
/// 内容在栏下面滚时，这一段从实色渐隐成透明并叠渐进模糊），以及工具栏下面
/// 那行靠前的大标题——它随栏收起被工具栏「吃进去」（裁剪）并淡出。
class _AppleSliverBackdrop extends StatelessWidget {
  const _AppleSliverBackdrop({
    required this.color,
    required this.largeTitle,
    required this.largeTitleStyle,
    required this.band,
    required this.bottomHeight,
    required this.horizontalPadding,
  });

  final Color color;
  final Widget? largeTitle;
  final TextStyle largeTitleStyle;
  final double band;
  final double bottomHeight;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final FlexibleSpaceBarSettings? settings = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    final bool under = settings?.isScrolledUnder ?? false;
    final double visible = _visibleLargeTitleBand(context);
    final double titleOpacity = ((visible - band * 0.35) / (band * 0.5)).clamp(
      0.0,
      1.0,
    );
    final Widget? title = largeTitle;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Column(
          children: <Widget>[
            Expanded(child: ColoredBox(color: color)),
            SizedBox(
              height: _kGlassSliverEdgeExtent,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  AnimatedOpacity(
                    opacity: under ? 0 : 1,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.standard,
                    child: ColoredBox(color: color),
                  ),
                  FushiAppleScrollEdge(
                    side: FushiScrollEdgeSide.top,
                    visible: under,
                    color: color,
                    maxSigma: 6,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (title != null && settings != null)
          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            top: settings.minExtent - bottomHeight,
            bottom: bottomHeight,
            child: ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.bottomStart,
                minHeight: 0,
                maxHeight: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ExcludeSemantics(
                    excluding: titleOpacity == 0,
                    child: Opacity(
                      opacity: titleOpacity,
                      child: DefaultTextStyle(
                        style: largeTitleStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: Semantics(header: true, child: title),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 页头（[FushiPageHeader.route]）的返回键：Apple 是 44 的圆形玻璃钮
/// （SF chevron，与玻璃顶栏的隐含返回键同一形态），MD3 是 `arrow_back`
/// 图标按钮（48 命中盒，与脚手架默认返回键同口径）。[onPressed] 为 null 时
/// `Navigator.maybePop`；那种情况下当前路由不能返回就不出现。
class FushiRouteBackButton extends StatelessWidget {
  const FushiRouteBackButton({this.onPressed, super.key});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? explicit = onPressed;
    if (explicit == null) {
      final NavigatorState? navigator = Navigator.maybeOf(context);
      if (navigator == null || !navigator.canPop()) {
        return const SizedBox.shrink();
      }
    }
    final VoidCallback handler =
        explicit ?? () => Navigator.of(context).maybePop();
    final String tooltip = MaterialLocalizations.of(context).backButtonTooltip;
    if (isGlassDesign(context)) {
      return _glassCircle(
        context,
        FushiIconButtonControl(
          icon: FushiIcon(
            CupertinoIcons.chevron_back,
            color: appleColorsOf(context).label,
            size: 22,
          ),
          tooltip: tooltip,
          onPressed: handler,
        ),
      );
    }
    // M3E：返回键是一枚悬浮圆胶囊（2026-10-05 页头统一为浮动工具栏）。
    return FushiPageChromeCircle(
      child: FushiIconButtonControl(
        icon: const Icon(Icons.arrow_back),
        tooltip: tooltip,
        onPressed: handler,
      ),
    );
  }
}

/// 首页外壳给当前 tab 子树下发的「外壳已经显示的页面名」。
///
/// 外壳顶部的 [FushiShellLargeTitleBar] 已经画了这个名字；tab 内自己的
/// [FushiPageHeader] 若是同名纯文字标题（如查词页的「查词」）就不再重复画。
/// 值按 tab 固定（外壳在每个 tab 的内容外各包一层），不随设计系统 / 滚动变。
class FushiShellTitleScope extends InheritedWidget {
  const FushiShellTitleScope({
    required this.title,
    required super.child,
    this.actionsSlot,
    super.key,
  });

  /// 外壳为这个 tab 显示的页面名；null = 外壳不显示大标题（首页 / 设置等）。
  final String? title;

  /// 外壳大标题条右侧的动作槽（见 [FushiShellActionsSlot]）；null = 外壳不收
  /// 页头动作，页头照旧把动作画在自己那一行。
  final FushiShellActionsSlot? actionsSlot;

  /// 最近的外壳页面名；不在首页外壳里（推出来的路由、组件测试）为 null。
  static String? maybeTitleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiShellTitleScope>()?.title;

  /// 最近外壳的动作槽；外壳这一 tab 不显示大标题时也返回 null（没有地方放）。
  static FushiShellActionsSlot? maybeActionsSlotOf(BuildContext context) {
    final FushiShellTitleScope? scope = context
        .dependOnInheritedWidgetOfExactType<FushiShellTitleScope>();
    if (scope == null || scope.title == null) return null;
    return scope.actionsSlot;
  }

  @override
  bool updateShouldNotify(FushiShellTitleScope oldWidget) =>
      oldWidget.title != title || oldWidget.actionsSlot != actionsSlot;
}

/// 首页外壳大标题条右侧的「页头动作」槽（2026-10-04「顶部标签栏做成全宽」）。
///
/// 库页的页头原本把分区页签和动作（搜索 / 合集 / 刷新…）挤在同一行，页签只
/// 分到左边一截。iOS 26 / macOS 26 的做法是动作进大标题行右侧的工具栏胶囊、
/// MD3 是 top app bar 的 actions 位——两者都是「标题行右侧」。外壳的大标题条
/// 正好就是那一行，所以页头在外壳里时把动作**登记**到这里，自己那一行只剩
/// 页签、整行铺满。
///
/// 同一外壳下常驻着多份页头（保活的 tab / 分区、IndexedStack 里的子区），
/// 每份登记时带上自己此刻是否可见（TickerMode + [Visibility]），槽显示**最后
/// 登记的可见**那份。登记发生在页头 build 期，通知延到帧末（build 期不能让
/// 树上更早的条重建）。
class FushiShellActionsSlot extends ChangeNotifier {
  final Map<Object, ({bool visible, Widget actions})> _claims =
      <Object, ({bool visible, Widget actions})>{};
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 当前应显示的动作；没有可见的登记时为 null。
  Widget? get actions {
    Widget? result;
    for (final ({bool visible, Widget actions}) claim in _claims.values) {
      if (claim.visible) result = claim.actions;
    }
    return result;
  }

  /// [owner]（通常是页头的 State）登记 / 更新自己的动作。
  void claim(Object owner, {required bool visible, required Widget actions}) {
    _claims[owner] = (visible: visible, actions: actions);
    _scheduleNotify();
  }

  /// [owner] 撤回登记（页头卸载、或不再需要外壳代放动作）。
  void release(Object owner) {
    if (_claims.remove(owner) != null) _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _claims.clear();
    super.dispose();
  }
}

/// 首页外壳（库页 / 浏览 / 查词）的页面大标题条：在库页自己的分区页签行
/// 之上，随内容滚离顶部收起（[collapsed] 由外壳的 [FushiLargeTitleCollapse]
/// 给出）。
///
/// - Apple：iOS 34 / 桌面 26 bold 的大标题靠前，收起时被条的下沿「吃进去」
///   并淡出，同时条顶部淡入居中的 17 semibold 小标题（与
///   [FushiSliverAppBar.large] 的玻璃版同一字阶）；条本身无底色。
/// - MD3：large top app bar 语义——headlineMedium（28）靠前，收起成
///   titleLarge（22）靠前小标题，底色从透明过渡到 surfaceContainer，无阴影线。
///
/// 结构恒定：[title] 为 null（外壳这一 tab 不显示大标题）时只是高度 0，
/// 两套设计系统、展开 / 收起都是同一棵树，切换不重挂外壳下面的子树。
/// 墨水屏与「减弱动态效果」下 [fushiMotionDuration] 归零，直接切换。
class FushiShellLargeTitleBar extends StatelessWidget {
  const FushiShellLargeTitleBar({
    required this.title,
    required this.collapsed,
    this.actions,
    super.key,
  });

  final String? title;
  final bool collapsed;

  /// 可见页头登记的动作（[FushiShellActionsSlot]）：画在标题行右侧——Apple 是
  /// 一枚工具栏玻璃胶囊，MD3 是 top app bar 的 actions 位。null = 外壳不收动作。
  final FushiShellActionsSlot? actions;

  @override
  Widget build(BuildContext context) {
    final FushiShellActionsSlot? slot = actions;
    if (slot == null) return _buildBar(context, null);
    return ListenableBuilder(
      listenable: slot,
      builder: (BuildContext context, Widget? _) =>
          _buildBar(context, slot.actions),
    );
  }

  Widget _buildBar(BuildContext context, Widget? trailing) {
    final bool apple = isGlassDesign(context);
    final bool desktop = _isDesktopBar(context);
    final ThemeData theme = Theme.of(context);
    final String text = title ?? '';
    final bool hasTitle = text.isNotEmpty;
    final double horizontal = FushiDesignTokens.of(context).spacing.page;
    // 展开 / 收起高度。Apple：iOS 大标题行 52、内联栏 44；桌面大标题小一号，
    // 收起后贴着窗口控制条只留一条 32 的内联标题行。MD3：标题行 + large app
    // bar 的下边距（移动 64 / 桌面 56），收起成紧凑的 titleLarge 行。
    final double expandedHeight = apple
        ? (desktop ? 46 : 52)
        : (desktop ? 56 : 64);
    // 标题行右侧挂着动作时，收起后也要容得下一排 44 的按钮（桌面 Apple 的
    // 32 内联行放不下）。
    // MD3（M3E 悬浮页头）：收起后标题是一枚 48 高的悬浮标题胶囊，行高至少
    // 容得下胶囊 + 上下 2。
    final double collapsedHeight = math.max(
      apple ? (desktop ? 32 : 44) : 52,
      trailing == null ? 0.0 : (apple ? 44.0 : 52.0),
    );
    final TextStyle largeStyle = apple
        ? _glassLargeTitleStyle(context)
        // M3E Emphasized 字阶：展开态大标题加粗。
        : (theme.textTheme.headlineMedium ?? const TextStyle()).copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          );
    final TextStyle smallStyle = apple
        ? _glassInlineTitleStyle(context)
        : FushiPageChromeTitle.titleStyleOf(context);
    // 收起时不再给标题条单独铺 surfaceContainer：分区页签行、搜索行仍是页面
    // 底色，只有标题条变灰会在页头中间切出一道色带（用户 2026-10-04「往下拖这块
    // 会泛灰」）。两套设计系统都保持透明，收起靠字号 / 高度变化表达。
    const Color scrolledColor = Colors.transparent;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: collapsed ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double t, Widget? _) {
        final double height = hasTitle
            ? lerpDouble(expandedHeight, collapsedHeight, t)!
            : 0;
        // 大标题先走：收起前半程就淡完；小标题后半程才出现，两者不叠字。
        // 看不见的那一份文字置空（不删组件，树结构不变）：静止时页面上只有一个
        // 页面名文本，按文字找组件的测试 / 无障碍不会数到两份。
        final double largeOpacity = (1 - t * 2).clamp(0.0, 1.0);
        final double smallOpacity = ((t - 0.5) * 2).clamp(0.0, 1.0);
        return SizedBox(
          height: height,
          child: ClipRect(
            child: ColoredBox(
              color: scrolledColor.withValues(alpha: scrolledColor.a * t),
              // 标题区与右侧动作是同一行：两份标题叠在 Expanded 里，动作是行尾
              // 的非弹性子项。无动作时尾项是零宽占位，结构不变。
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) => Row(
                    children: <Widget>[
                      Expanded(
                        child: _titleStack(
                          apple: apple,
                          text: text,
                          hasTitle: hasTitle,
                          largeStyle: largeStyle,
                          smallStyle: smallStyle,
                          largeOpacity: largeOpacity,
                          smallOpacity: smallOpacity,
                          collapsedHeight: collapsedHeight,
                        ),
                      ),
                      _trailing(
                        context,
                        trailing: trailing,
                        rowWidth: box.maxWidth,
                        title: hasTitle ? text : '',
                        largeStyle: largeStyle,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 行尾动作：限宽 = 行宽 − 给标题留的宽（大标题实际字宽，至多行宽 45%）−
  /// 间距；动作自己在这个宽度内决定是否收进 ⋯。
  Widget _trailing(
    BuildContext context, {
    required Widget? trailing,
    required double rowWidth,
    required String title,
    required TextStyle largeStyle,
  }) {
    if (trailing == null || !rowWidth.isFinite) return const SizedBox.shrink();
    final TextPainter painter = TextPainter(
      text: TextSpan(text: title, style: largeStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final double titleWidth = painter.width;
    painter.dispose();
    const double gap = 12;
    final double maxWidth = math.max(
      0.0,
      rowWidth - math.min(titleWidth, rowWidth * 0.45) - gap,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: gap),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: trailing,
      ),
    );
  }

  /// MD3：收起态小标题装进悬浮标题胶囊；Apple 原样。
  Widget _maybeTitleCapsule({required bool apple, required Widget child}) {
    if (apple) return child;
    return FushiPageChromeTitle(title: child);
  }

  Widget _titleStack({
    required bool apple,
    required String text,
    required bool hasTitle,
    required TextStyle largeStyle,
    required TextStyle smallStyle,
    required double largeOpacity,
    required double smallOpacity,
    required double collapsedHeight,
  }) {
    const double horizontal = 0;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 大标题贴条的下沿：条变矮时它随下沿上移、顶部被裁掉。
        Positioned(
          left: horizontal,
          right: horizontal,
          bottom: apple ? 4 : 8,
          child: ExcludeSemantics(
            excluding: !hasTitle || largeOpacity == 0,
            child: Opacity(
              opacity: largeOpacity,
              child: Semantics(
                header: true,
                child: Text(
                  largeOpacity > 0 ? text : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: largeStyle,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: horizontal,
          right: horizontal,
          top: 0,
          height: collapsedHeight,
          child: ExcludeSemantics(
            excluding: !hasTitle || smallOpacity == 0,
            child: Opacity(
              opacity: smallOpacity,
              child: Align(
                // Apple 的内联标题居中；MD3 收起后的小标题靠前，收进一枚
                // 悬浮标题胶囊（M3E 浮动工具栏：大标题随滚动「缩」成胶囊）。
                alignment: apple
                    ? Alignment.center
                    : AlignmentDirectional.centerStart,
                child: Transform.scale(
                  scale: apple ? 1 : 0.92 + 0.08 * smallOpacity,
                  alignment: AlignmentDirectional.centerStart,
                  child: _maybeTitleCapsule(
                    apple: apple,
                    child: Semantics(
                      header: true,
                      child: Text(
                        smallOpacity > 0 ? text : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: smallStyle,
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
  }
}

/// Apple 文字页签在 label 内边距之内、文字两侧各再留的内衬（悬停 / 焦点圆角
/// 底的呼吸位）。量页签宽度的调用方（`LibrarySectionTabs` 的铺满判据）必须把它
/// 算进去，否则判「放得下」的一档实际会把文字挤到渐隐截断。
const double kFushiAppleTabContentInset = 6.0;

/// M3E 分段胶囊页签每侧吃掉的水平宽：轨道离边 12 + 轨道内 TabBar 内边距 4。
/// 量页签宽度的调用方（`LibrarySectionTabs` 的铺满判据）必须扣掉两侧这一截。
const double kFushiM3eTabTrackInset = 16.0;

/// 轨道贴齐页边（`trackInset: 0`）时每侧只剩轨道内 TabBar 内边距这一截。
const double kFushiM3eFlushTabTrackInset = 4.0;

/// [TabBar] 的设计系统分派版（含 `.secondary`）。实现 [PreferredSizeWidget]
/// 供 `AppBar.bottom` 使用，[preferredSize] 与同参 TabBar 一致（两套设计系统
/// 下高度相同，切换不跳布局）。
class FushiTabBar extends StatelessWidget implements PreferredSizeWidget {
  const FushiTabBar({
    super.key,
    required this.tabs,
    this.controller,
    this.scrollController,
    this.isScrollable = false,
    this.padding,
    this.indicatorColor,
    this.automaticIndicatorColorAdjustment = true,
    this.indicatorWeight = 2.0,
    this.indicatorPadding = EdgeInsets.zero,
    this.indicator,
    this.indicatorSize,
    this.dividerColor,
    this.dividerHeight,
    this.labelColor,
    this.labelStyle,
    this.labelPadding,
    this.unselectedLabelColor,
    this.unselectedLabelStyle,
    this.dragStartBehavior = DragStartBehavior.start,
    this.overlayColor,
    this.mouseCursor,
    this.enableFeedback,
    this.onTap,
    this.onHover,
    this.onFocusChange,
    this.physics,
    this.splashFactory,
    this.splashBorderRadius,
    this.tabAlignment,
    this.textScaler,
    this.indicatorAnimation,
    this.track = true,
    this.trackInset,
  }) : _secondary = false;

  const FushiTabBar.secondary({
    super.key,
    required this.tabs,
    this.controller,
    this.scrollController,
    this.isScrollable = false,
    this.padding,
    this.indicatorColor,
    this.automaticIndicatorColorAdjustment = true,
    this.indicatorWeight = 2.0,
    this.indicatorPadding = EdgeInsets.zero,
    this.indicator,
    this.indicatorSize,
    this.dividerColor,
    this.dividerHeight,
    this.labelColor,
    this.labelStyle,
    this.labelPadding,
    this.unselectedLabelColor,
    this.unselectedLabelStyle,
    this.dragStartBehavior = DragStartBehavior.start,
    this.overlayColor,
    this.mouseCursor,
    this.enableFeedback,
    this.onTap,
    this.onHover,
    this.onFocusChange,
    this.physics,
    this.splashFactory,
    this.splashBorderRadius,
    this.tabAlignment,
    this.textScaler,
    this.indicatorAnimation,
    this.track = true,
    this.trackInset,
  }) : _secondary = true;

  final List<Widget> tabs;
  final TabController? controller;
  final TabBarScrollController? scrollController;
  final bool isScrollable;
  final EdgeInsetsGeometry? padding;
  final Color? indicatorColor;
  final bool automaticIndicatorColorAdjustment;
  final double indicatorWeight;
  final EdgeInsetsGeometry indicatorPadding;
  final Decoration? indicator;
  final TabBarIndicatorSize? indicatorSize;
  final Color? dividerColor;
  final double? dividerHeight;
  final Color? labelColor;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final Color? unselectedLabelColor;
  final TextStyle? unselectedLabelStyle;
  final DragStartBehavior dragStartBehavior;
  final WidgetStateProperty<Color?>? overlayColor;
  final MouseCursor? mouseCursor;
  final bool? enableFeedback;
  final ValueChanged<int>? onTap;
  final TabValueChanged<bool>? onHover;
  final TabValueChanged<bool>? onFocusChange;
  final ScrollPhysics? physics;
  final InteractiveInkFeatureFactory? splashFactory;
  final BorderRadius? splashBorderRadius;
  final TabAlignment? tabAlignment;
  final TextScaler? textScaler;
  final TabIndicatorAnimation? indicatorAnimation;

  /// Material（M3E）下是否自带那条分段胶囊轨道。已经装在别的悬浮胶囊里的页签
  /// （库页浮动工具栏的页签胶囊，`LibrarySectionTabs(floating: true)`）传
  /// false：只画胶囊里的 TabBar 本体，不再叠第二层轨道——胶囊套胶囊会出两圈
  /// 圆角与底色，内层还会被外层裁掉两端。Apple 设计系统下忽略。
  final bool track;

  /// Material（M3E）分段胶囊轨道离左右边缘的距离；null = 默认 12（轨道在
  /// 一块没有页边的全宽区域里时留的呼吸位）。调用方已经按页边内缩（页签与
  /// 页面大标题 / 内容共用同一条页边）时传 0，轨道左缘才与标题左缘对齐——
  /// 否则轨道比标题多缩进 12（2026-10-06 用户截图「浏览顶部左边没对齐」）。
  final double? trackInset;
  final bool _secondary;

  /// MD3（2026-10 页签统一，Material 3 Expressive）：调用方没显式给的值按
  /// 主题补默认——主页签选中 primary + titleSmall w600、未选中
  /// onSurfaceVariant w500，指示条 3px 圆头 primary、宽度跟文字
  /// （[TabBarIndicatorSize.label]，框架 M3 默认就是这一形态并随切换滑动），
  /// 整排分隔线压成极淡的 outlineVariant；次级页签全宽 2px 下划线（框架
  /// 默认）+ onSurface 文字。状态层圆角。墨水屏分隔线保持实描边，选中 /
  /// 未选中靠字重与指示条区分。[theme] 为 null 时（[preferredSize]）只要几何，
  /// 不碰颜色。
  TabBar _material([ThemeData? theme, bool segmented = false]) {
    final ColorScheme? cs = theme?.colorScheme;
    if (segmented && cs != null) return _segmentedMaterial(theme!, cs);
    final TextStyle? titleSmall = theme?.textTheme.titleSmall;
    final bool eink = theme?.extension<FushiEinkTheme>()?.einkMode ?? false;
    final Color? labelColor =
        this.labelColor ?? (_secondary ? cs?.onSurface : cs?.primary);
    final Color? unselectedLabelColor =
        this.unselectedLabelColor ?? cs?.onSurfaceVariant;
    final TextStyle? labelStyle =
        this.labelStyle ?? titleSmall?.copyWith(fontWeight: FontWeight.w600);
    final TextStyle? unselectedLabelStyle =
        this.unselectedLabelStyle ??
        (this.labelStyle == null
            ? titleSmall?.copyWith(fontWeight: FontWeight.w500)
            : null);
    final Color? dividerColor =
        this.dividerColor ??
        (cs == null || eink
            ? null
            : cs.outlineVariant.withValues(alpha: cs.outlineVariant.a * 0.5));
    final BorderRadius? splashBorderRadius =
        this.splashBorderRadius ??
        (theme == null ? null : BorderRadius.circular(10));
    // 主页签指示条（2026-10-04 默认页签重做，MD3 Expressive）：3dp 全圆头胶囊，
    // 宽度跟文字、两端各让 2dp——框架 M3 默认只圆上两角、底边是直角压在分隔线
    // 上，读起来像一截被切掉的色块。调用方给了 [indicator] 原样用；给了
    // [indicatorColor] 只换颜色。几何（[preferredSize]）不读它，高度不变。
    final Decoration? indicator =
        this.indicator ??
        (_secondary || cs == null
            ? null
            : UnderlineTabIndicator(
                borderSide: BorderSide(
                  width: 3,
                  color: indicatorColor ?? cs.primary,
                ),
                borderRadius: const BorderRadius.all(Radius.circular(3)),
                insets: const EdgeInsets.symmetric(horizontal: 2),
              ));
    if (_secondary) {
      return TabBar.secondary(
        tabs: tabs,
        controller: controller,
        scrollController: scrollController,
        isScrollable: isScrollable,
        padding: padding,
        indicatorColor: indicatorColor,
        automaticIndicatorColorAdjustment: automaticIndicatorColorAdjustment,
        indicatorWeight: indicatorWeight,
        indicatorPadding: indicatorPadding,
        indicator: indicator,
        indicatorSize: indicatorSize,
        dividerColor: dividerColor,
        dividerHeight: dividerHeight,
        labelColor: labelColor,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        unselectedLabelColor: unselectedLabelColor,
        unselectedLabelStyle: unselectedLabelStyle,
        dragStartBehavior: dragStartBehavior,
        overlayColor: overlayColor,
        mouseCursor: mouseCursor,
        enableFeedback: enableFeedback,
        onTap: onTap,
        onHover: onHover,
        onFocusChange: onFocusChange,
        physics: physics,
        splashFactory: splashFactory,
        splashBorderRadius: splashBorderRadius,
        tabAlignment: tabAlignment,
        textScaler: textScaler,
        indicatorAnimation: indicatorAnimation,
      );
    }
    return TabBar(
      tabs: tabs,
      controller: controller,
      scrollController: scrollController,
      isScrollable: isScrollable,
      padding: padding,
      indicatorColor: indicatorColor,
      automaticIndicatorColorAdjustment: automaticIndicatorColorAdjustment,
      indicatorWeight: indicatorWeight,
      indicatorPadding: indicatorPadding,
      indicator: indicator,
      indicatorSize: indicatorSize,
      dividerColor: dividerColor,
      dividerHeight: dividerHeight,
      labelColor: labelColor,
      labelStyle: labelStyle,
      labelPadding: labelPadding,
      unselectedLabelColor: unselectedLabelColor,
      unselectedLabelStyle: unselectedLabelStyle,
      dragStartBehavior: dragStartBehavior,
      overlayColor: overlayColor,
      mouseCursor: mouseCursor,
      enableFeedback: enableFeedback,
      onTap: onTap,
      onHover: onHover,
      onFocusChange: onFocusChange,
      physics: physics,
      splashFactory: splashFactory,
      splashBorderRadius: splashBorderRadius,
      tabAlignment: tabAlignment,
      textScaler: textScaler,
      indicatorAnimation: indicatorAnimation,
    );
  }

  /// M3E 分段胶囊里的 TabBar（2026-10-05「全部用浮动工具栏统一」）：选中段是
  /// 一枚 secondaryContainer 全胶囊滑块（随 TabController 动画弹性滑动，
  /// [TabIndicatorAnimation.elastic] = M3E 指示器的伸缩形变），无下划线、无
  /// 分隔线。调用方显式给的颜色 / 字阶 / 指示器照用。
  TabBar _segmentedMaterial(ThemeData theme, ColorScheme cs) {
    final TextStyle? titleSmall = theme.textTheme.titleSmall;
    final bool eink = theme.extension<FushiEinkTheme>()?.einkMode ?? false;
    final Decoration indicator =
        this.indicator ??
        ShapeDecoration(
          color: indicatorColor ?? cs.secondaryContainer,
          shape: StadiumBorder(
            side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
          ),
        );
    final TextStyle? labelStyle =
        this.labelStyle ?? titleSmall?.copyWith(fontWeight: FontWeight.w700);
    final TextStyle? unselectedLabelStyle =
        this.unselectedLabelStyle ??
        (this.labelStyle == null
            ? titleSmall?.copyWith(fontWeight: FontWeight.w500)
            : null);
    final bool motion = !eink;
    final TabBar Function({
      required List<Widget> tabs,
    }) build = _secondary
        ? ({required List<Widget> tabs}) => TabBar.secondary(
            tabs: tabs,
            controller: controller,
            scrollController: scrollController,
            isScrollable: isScrollable,
            padding: padding ?? const EdgeInsets.all(4),
            automaticIndicatorColorAdjustment:
                automaticIndicatorColorAdjustment,
            indicatorWeight: indicatorWeight,
            indicatorPadding: indicatorPadding,
            indicator: indicator,
            indicatorSize: indicatorSize ?? TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            dividerHeight: 0,
            labelColor: labelColor ?? cs.onSecondaryContainer,
            labelStyle: labelStyle,
            labelPadding: labelPadding,
            unselectedLabelColor: unselectedLabelColor ?? cs.onSurfaceVariant,
            unselectedLabelStyle: unselectedLabelStyle,
            dragStartBehavior: dragStartBehavior,
            overlayColor: overlayColor,
            mouseCursor: mouseCursor,
            enableFeedback: enableFeedback,
            onTap: onTap,
            onHover: onHover,
            onFocusChange: onFocusChange,
            physics: physics,
            splashFactory: splashFactory,
            splashBorderRadius:
                splashBorderRadius ?? BorderRadius.circular(999),
            tabAlignment: tabAlignment,
            textScaler: textScaler,
            indicatorAnimation: indicatorAnimation ??
                (motion
                    ? TabIndicatorAnimation.elastic
                    : TabIndicatorAnimation.linear),
          )
        : ({required List<Widget> tabs}) => TabBar(
            tabs: tabs,
            controller: controller,
            scrollController: scrollController,
            isScrollable: isScrollable,
            padding: padding ?? const EdgeInsets.all(4),
            automaticIndicatorColorAdjustment:
                automaticIndicatorColorAdjustment,
            indicatorWeight: indicatorWeight,
            indicatorPadding: indicatorPadding,
            indicator: indicator,
            indicatorSize: indicatorSize ?? TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            dividerHeight: 0,
            labelColor: labelColor ?? cs.onSecondaryContainer,
            labelStyle: labelStyle,
            labelPadding: labelPadding,
            unselectedLabelColor: unselectedLabelColor ?? cs.onSurfaceVariant,
            unselectedLabelStyle: unselectedLabelStyle,
            dragStartBehavior: dragStartBehavior,
            overlayColor: overlayColor,
            mouseCursor: mouseCursor,
            enableFeedback: enableFeedback,
            onTap: onTap,
            onHover: onHover,
            onFocusChange: onFocusChange,
            physics: physics,
            splashFactory: splashFactory,
            splashBorderRadius:
                splashBorderRadius ?? BorderRadius.circular(999),
            tabAlignment: tabAlignment,
            textScaler: textScaler,
            indicatorAnimation: indicatorAnimation ??
                (motion
                    ? TabIndicatorAnimation.elastic
                    : TabIndicatorAnimation.linear),
          );
    return build(tabs: tabs);
  }

  @override
  Size get preferredSize => _material().preferredSize;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      if (track) return _FushiM3eSegmentedTabs(bar: this);
      return Material(
        type: MaterialType.transparency,
        child: _material(Theme.of(context), true),
      );
    }
    return _FushiGlassTabBar(bar: this);
  }
}

/// M3E 分段胶囊页签：一条悬浮页头同色（standard 面）的全胶囊轨道，里面是
/// [FushiTabBar._segmentedMaterial]（框架 TabBar：焦点、Enter / 方向键、
/// TabController 双向同步、横滑跟手都是框架原生行为）。总高与
/// [FushiTabBar.preferredSize] 相同（放在 `AppBar.bottom` 里不跳布局），轨道
/// 上下各让 3、左右离边 12，看起来浮在页面上。
class _FushiM3eSegmentedTabs extends StatelessWidget {
  const _FushiM3eSegmentedTabs({required this.bar});

  final FushiTabBar bar;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = theme.extension<FushiEinkTheme>()?.einkMode ?? false;
    return SizedBox(
      height: bar.preferredSize.height,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: bar.trackInset ?? kFushiM3eTabTrackInset - 4,
          vertical: 3,
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: fushiPageChromeColor(context),
            shape: StadiumBorder(
              side: eink
                  ? BorderSide(color: cs.outline)
                  : BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.4),
                    ),
            ),
          ),
          child: ClipPath(
            clipper: const ShapeBorderClipper(shape: StadiumBorder()),
            child: Material(
              type: MaterialType.transparency,
              child: bar._material(theme, true),
            ),
          ),
        ),
      ),
    );
  }
}

class _FushiGlassTabBar extends StatefulWidget {
  const _FushiGlassTabBar({required this.bar});

  final FushiTabBar bar;

  @override
  State<_FushiGlassTabBar> createState() => _FushiGlassTabBarState();
}

class _FushiGlassTabBarState extends State<_FushiGlassTabBar> {
  TabController? _controller;
  int _shown = 0;
  List<GlobalKey> _segmentKeys = <GlobalKey>[];

  /// 各页签的文字（内容）区：指示条按它量宽度，铺满（fill）档的页签再宽，
  /// 短条也只跟文字一样长（iOS 文字页签的下划线跟字走）。
  List<GlobalKey> _contentKeys = <GlobalKey>[];
  final GlobalKey _rowKey = GlobalKey();

  FushiTabBar get _bar => widget.bar;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateController();
  }

  @override
  void didUpdateWidget(_FushiGlassTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bar.controller != _bar.controller) _updateController();
  }

  void _updateController() {
    final TabController? next =
        _bar.controller ?? DefaultTabController.maybeOf(context);
    if (next == null) {
      throw FlutterError(
        'No TabController for FushiTabBar.\n'
        'Provide a controller or put a DefaultTabController above it.',
      );
    }
    if (identical(next, _controller)) return;
    _detach();
    _controller = next;
    next.animation?.addListener(_onAnimation);
    next.addListener(_onIndex);
    _shown = next.index;
  }

  void _detach() {
    _controller?.animation?.removeListener(_onAnimation);
    _controller?.removeListener(_onIndex);
  }

  int get _selected {
    final TabController c = _controller!;
    if (c.indexIsChanging) return c.index;
    final double value = c.animation?.value ?? c.index.toDouble();
    return value.round().clamp(0, c.length - 1);
  }

  void _onAnimation() {
    if (_selected != _shown && mounted) setState(() => _shown = _selected);
  }

  void _onIndex() {
    if (!mounted) return;
    setState(() => _shown = _selected);
    _scrollSelectedIntoView();
  }

  void _scrollSelectedIntoView() {
    if (!_bar.isScrollable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final int index = _controller!.index;
      if (index >= _segmentKeys.length) return;
      final BuildContext? target = _segmentKeys[index].currentContext;
      if (target == null) return;
      // 焦点驱动滚动的唯一实现者（守卫 focus_architecture_static_test）。
      FushiFocusScroll.ensureVisible(
        target,
        duration: einkSafeDuration(context, const Duration(milliseconds: 200)),
      );
    });
  }

  void _select(int index) {
    _controller!.animateTo(index);
    _bar.onTap?.call(index);
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  static String _semanticLabelOf(Widget tab) {
    if (tab is Tab) {
      if (tab.text != null) return tab.text!;
      final Widget? child = tab.child;
      if (child is Text) return child.data ?? '';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final List<Widget> tabs = _bar.tabs;
    if (_segmentKeys.length != tabs.length) {
      _segmentKeys = <GlobalKey>[
        for (int i = 0; i < tabs.length; i++) GlobalKey(),
      ];
      _contentKeys = <GlobalKey>[
        for (int i = 0; i < tabs.length; i++) GlobalKey(),
      ];
    }
    const double outerVertical = 0;
    final double height = _bar.preferredSize.height;
    final int selected = _shown.clamp(0, tabs.length - 1);
    // 选中下划线：调用方的 indicatorColor 优先，否则强调色（默认单色主题即
    // 黑 / 白）。圆角短条，宽度跟随文字。
    final Color indicator = _bar.indicatorColor ?? apple.accent;

    Widget segment(int i) {
      final bool isSelected = i == selected;
      // Apple 式文字页签（用户 2026-10-04：顶部不用分段控件、继续用标签页）：
      // 选中 = 强调色 semibold + 文字下方圆角强调色短条；未选中 =
      // secondaryLabel。没有 MD3 水波纹、没有整条分隔线。主题里的 MD3
      // TabBarTheme 颜色不读，调用方显式给的颜色照用。
      final Color fg = isSelected
          ? (_bar.labelColor ?? apple.accent)
          : (_bar.unselectedLabelColor ?? apple.secondaryLabel);
      final TextStyle base =
          (isSelected
              ? _bar.labelStyle
              : (_bar.unselectedLabelStyle ?? _bar.labelStyle)) ??
          theme.textTheme.titleSmall ??
          const TextStyle();
      // 下限 12：库页分区页签在窄屏逐级收紧时会显式下发 13 / 12 号字。
      final double fontSize = (base.fontSize ?? 14).clamp(12.0, 15.0);
      Widget content = DefaultTextStyle(
        style: base.copyWith(
          color: fg,
          fontSize: fontSize,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: IconTheme.merge(
          data: IconThemeData(color: fg, size: 20),
          child: tabs[i],
        ),
      );
      if (_bar.textScaler != null) {
        content = MediaQuery.withNoTextScaling(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: _bar.textScaler),
            child: content,
          ),
        );
      }
      Widget button = _FushiAppleTab(
        key: _segmentKeys[i],
        contentKey: _contentKeys[i],
        selected: isSelected,
        indicator: indicator,
        height: height,
        padding:
            _bar.labelPadding ?? const EdgeInsets.symmetric(horizontal: 12),
        semanticLabel: _semanticLabelOf(tabs[i]),
        onTap: () => _select(i),
        child: content,
      );
      button = Semantics(selected: isSelected, child: button);
      final TabValueChanged<bool>? onHover = _bar.onHover;
      if (onHover != null) {
        button = MouseRegion(
          onEnter: (_) => onHover(true, i),
          onExit: (_) => onHover(false, i),
          child: button,
        );
      }
      final TabValueChanged<bool>? onFocusChange = _bar.onFocusChange;
      if (onFocusChange != null) {
        button = Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (bool focused) => onFocusChange(focused, i),
          child: button,
        );
      }
      return button;
    }

    // 整排共用一条下划线，随 TabController.animation 在相邻两页签之间插值滑动
    // （点选时动画过去，横滑翻页时实时跟手）。在绘制阶段量各页签的位置，
    // 布局已完成，不必等下一帧。
    Widget slidingIndicator(Widget tabsRow) => CustomPaint(
      key: _rowKey,
      foregroundPainter: _FushiTabIndicatorPainter(
        animation:
            _controller!.animation ??
            AlwaysStoppedAnimation<double>(_controller!.index.toDouble()),
        controller: _controller!,
        tabKeys: _contentKeys,
        rowKey: _rowKey,
        color: indicator,
        // 量的是文字区，两端各多出 2px，短条比字略宽一点、不显得局促。
        inset: -2,
      ),
      child: tabsRow,
    );

    final TabAlignment alignment =
        _bar.tabAlignment ??
        TabBarTheme.of(context).tabAlignment ??
        (_bar.isScrollable ? TabAlignment.start : TabAlignment.fill);
    Widget row;
    if (_bar.isScrollable) {
      // 桌面端默认 dragDevices 不含鼠标：可滚动的标签行鼠标也要拖得动。
      row = HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _bar.scrollController,
          physics: _bar.physics,
          dragStartBehavior: _bar.dragStartBehavior,
          child: slidingIndicator(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < tabs.length; i++) segment(i),
              ],
            ),
          ),
        ),
      );
    } else if (alignment == TabAlignment.center) {
      row = slidingIndicator(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[for (int i = 0; i < tabs.length; i++) segment(i)],
        ),
      );
    } else {
      row = slidingIndicator(
        Row(
          children: <Widget>[
            for (int i = 0; i < tabs.length; i++) Expanded(child: segment(i)),
          ],
        ),
      );
    }
    final Widget track = Material(type: MaterialType.transparency, child: row);
    final bool hugs = _bar.isScrollable || alignment == TabAlignment.center;
    final AlignmentGeometry hugAlignment = alignment == TabAlignment.center
        ? Alignment.center
        : AlignmentDirectional.centerStart;
    return FocusTraversalGroup(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: (_bar.padding ?? const EdgeInsets.symmetric(horizontal: 8))
              .resolve(Directionality.of(context))
              .copyWith(top: outerVertical, bottom: outerVertical),
          child: hugs ? Align(alignment: hugAlignment, child: track) : track,
        ),
      ),
    );
  }
}

/// 玻璃设计系统的单个文字页签：文字 + 选中时下方 3px 圆角强调色短条，悬停
/// 一层极淡填充；可 Tab 聚焦、Enter 触发（ActivateIntent）。
class _FushiAppleTab extends StatefulWidget {
  const _FushiAppleTab({
    super.key,
    required this.contentKey,
    required this.selected,
    required this.indicator,
    required this.height,
    required this.padding,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
  });

  /// 挂在文字区上，供滑动指示条量宽度。
  final GlobalKey contentKey;
  final bool selected;
  final Color indicator;
  final double height;
  final EdgeInsetsGeometry padding;
  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_FushiAppleTab> createState() => _FushiAppleTabState();
}

class _FushiAppleTabState extends State<_FushiAppleTab> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel.isEmpty ? null : widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
        onShowFocusHighlight: (bool v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent _) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            height: widget.height,
            child: Padding(
              padding: widget.padding,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Positioned.fill(
                    top: 6,
                    bottom: 6,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: _hovered || _focused
                            ? apple.tertiaryFill
                            : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: _focused
                              ? BorderSide(color: widget.indicator, width: 1.5)
                              : BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kFushiAppleTabContentInset,
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: KeyedSubtree(
                        key: widget.contentKey,
                        child: widget.child,
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

/// [_FushiGlassTabBarState] 的滑动下划线：读 TabController 动画值，在第
/// floor / ceil 两个页签的文字区之间线性插值位置与宽度。
class _FushiTabIndicatorPainter extends CustomPainter {
  _FushiTabIndicatorPainter({
    required Animation<double> animation,
    required this.controller,
    required this.tabKeys,
    required this.rowKey,
    required this.color,
    required this.inset,
  }) : _animation = animation,
       super(repaint: animation);

  final Animation<double> _animation;
  final TabController controller;
  final List<GlobalKey> tabKeys;
  final GlobalKey rowKey;
  final Color color;
  final double inset;

  Rect? _tabRect(int index) {
    if (index < 0 || index >= tabKeys.length) return null;
    final RenderObject? tab = tabKeys[index].currentContext?.findRenderObject();
    final RenderObject? row = rowKey.currentContext?.findRenderObject();
    if (tab is! RenderBox || row is! RenderBox || !tab.hasSize) return null;
    final Offset origin = tab.localToGlobal(Offset.zero, ancestor: row);
    return origin & tab.size;
  }

  /// 液态拉伸（iOS 26 液态指示器）：两条边按不同缓动插值——前进方向上的
  /// 前沿先走（ease-out）、后沿后到（ease-in），中途短条被拉长、把 A 与 B
  /// 连成一条，再向 B 收拢。曲线只是 t 的函数、t 直接取自
  /// TabController.animation：点选时随动画、横滑翻页时跟手；往回拖时 t 反向
  /// 走，同一对曲线自然让左沿成为前沿。减弱动态效果下框架把动画时长归零，
  /// 指示条直接落到目标，不出现拉伸。
  static double _leadEdge(double t) => 1 - (1 - t) * (1 - t);
  static double _trailEdge(double t) => t * t;

  @override
  void paint(Canvas canvas, Size size) {
    if (tabKeys.isEmpty) return;
    final double value = _animation.value.clamp(0.0, tabKeys.length - 1.0);
    final int from = value.floor();
    final int to = value.ceil();
    final Rect? a = _tabRect(from);
    final Rect? b = _tabRect(to);
    if (a == null || b == null) return;
    final double t = value - from;
    // 从 floor 页签走向 ceil 页签时，屏幕上向右走（LTR）的话右沿是前沿；
    // RTL 下 ceil 在左边，左沿成为前沿。
    final bool towardRight = b.left >= a.left;
    final double leftT = towardRight ? _trailEdge(t) : _leadEdge(t);
    final double rightT = towardRight ? _leadEdge(t) : _trailEdge(t);
    final double left = lerpDouble(a.left, b.left, leftT)! + inset;
    final double right = lerpDouble(a.right, b.right, rightT)! - inset;
    if (right <= left) return;
    final Rect bar = Rect.fromLTRB(
      left,
      size.height - 5,
      right,
      size.height - 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar, const Radius.circular(1.5)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_FushiTabIndicatorPainter old) =>
      old.color != color ||
      old.inset != inset ||
      old.controller != controller ||
      old.tabKeys != tabKeys;
}
