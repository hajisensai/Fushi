import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 顶栏族（AppBar / SliverAppBar / TabBar）的「设计系统分派」包装：构造参数与
// Material 原控件逐个同名同型，调用点只改类名。MD3 下原样构造原控件；玻璃下：
// - AppBar / SliverAppBar：仍是框架 AppBar（标题、居中、bottom、系统状态栏样式、
//   返回键行为全不变），本体透明无阴影，背后垫一整块玻璃（flexibleSpace 底层）；
//   隐含的返回 / 关闭 / 抽屉键换成玻璃图标按钮，行为与框架同一判据；
// - TabBar：玻璃胶囊轨道 + 每个页签一枚玻璃按钮（选中项着色），与
//   TabController 双向同步，Enter / 手柄 A 选中，方向键在页签间移动焦点。

/// 顶栏背后的玻璃面：铺满 AppBar（含状态栏区域），调用方的 flexibleSpace
/// 叠在上面。
class _FushiGlassBarBackground extends StatelessWidget {
  const _FushiGlassBarBackground({this.tint, this.child});

  final Color? tint;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final Color? explicitTint = tint != null && tint!.a > 0 ? tint : null;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GlassContainer(
          useOwnLayer: true,
          quality: fushiGlassQuality(context, prominent: true),
          settings: explicitTint == null
              ? null
              : fushiGlassSettings(context, tint: explicitTint),
          shape: const LiquidRoundedRectangle(borderRadius: 0),
        ),
        if (child != null) child!,
      ],
    );
  }
}

/// 与框架 AppBar 同一判据推出隐含 leading（抽屉键 / 关闭键 / 返回键），
/// 但渲染成玻璃图标按钮。推不出时返回 null（交回 AppBar，它同样推不出）。
Widget? _impliedGlassLeading(BuildContext context) {
  final ScaffoldState? scaffold = Scaffold.maybeOf(context);
  final ModalRoute<dynamic>? parentRoute = ModalRoute.of(context);
  final MaterialLocalizations l10n = MaterialLocalizations.of(context);
  if (scaffold?.hasDrawer ?? false) {
    return Center(
      child: FushiIconButtonControl(
        icon: const DrawerButtonIcon(),
        tooltip: l10n.openAppDrawerTooltip,
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    );
  }
  if (parentRoute?.impliesAppBarDismissal ?? false) {
    final bool useCloseButton =
        parentRoute is PageRoute<dynamic> && parentRoute.fullscreenDialog;
    return Center(
      child: FushiIconButtonControl(
        icon: useCloseButton ? const CloseButtonIcon() : const BackButtonIcon(),
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
    // 框架只给 IconButton 包 Center；玻璃图标按钮同样要居中，否则会被
    // leading 槽的紧约束拉成 56×56。
    return leading is FushiIconButtonControl ? Center(child: leading) : leading;
  }
  if (!automaticallyImplyLeading) return null;
  return _impliedGlassLeading(context);
}

List<Widget>? _glassActions(
  BuildContext context, {
  required List<Widget>? actions,
  required bool automaticallyImplyActions,
}) {
  if (actions != null && actions.isNotEmpty) return actions;
  if (!automaticallyImplyActions) return actions;
  if (Scaffold.maybeOf(context)?.hasEndDrawer ?? false) {
    return <Widget>[
      FushiIconButtonControl(
        icon: const EndDrawerButtonIcon(),
        tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
        onPressed: () => Scaffold.of(context).openEndDrawer(),
      ),
    ];
  }
  return actions;
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

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
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
      flexibleSpace: glass
          ? _FushiGlassBarBackground(
              tint: backgroundColor,
              child: flexibleSpace,
            )
          : flexibleSpace,
      bottom: bottom,
      elevation: glass ? 0 : elevation,
      scrolledUnderElevation: glass ? 0 : scrolledUnderElevation,
      notificationPredicate: notificationPredicate,
      shadowColor: glass ? Colors.transparent : shadowColor,
      surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
      shape: shape,
      backgroundColor: glass ? Colors.transparent : backgroundColor,
      foregroundColor: foregroundColor,
      iconTheme: iconTheme,
      actionsIconTheme: actionsIconTheme,
      primary: primary,
      centerTitle: centerTitle,
      excludeHeaderSemantics: excludeHeaderSemantics,
      titleSpacing: titleSpacing,
      toolbarOpacity: toolbarOpacity,
      bottomOpacity: bottomOpacity,
      toolbarHeight: toolbarHeight,
      leadingWidth: leadingWidth,
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

/// [SliverAppBar] 的设计系统分派版。
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

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    return SliverAppBar(
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
      flexibleSpace: glass
          ? _FushiGlassBarBackground(
              tint: backgroundColor,
              child: flexibleSpace,
            )
          : flexibleSpace,
      bottom: bottom,
      elevation: glass ? 0 : elevation,
      scrolledUnderElevation: glass ? 0 : scrolledUnderElevation,
      shadowColor: glass ? Colors.transparent : shadowColor,
      surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
      forceElevated: forceElevated,
      backgroundColor: glass ? Colors.transparent : backgroundColor,
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
  final bool _secondary;

  TabBar _material() {
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

  @override
  Size get preferredSize => _material().preferredSize;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) return _material();
    return _FushiGlassTabBar(bar: this);
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
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
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
    final ColorScheme cs = theme.colorScheme;
    final TabBarThemeData tabTheme = TabBarTheme.of(context);
    final List<Widget> tabs = _bar.tabs;
    if (_segmentKeys.length != tabs.length) {
      _segmentKeys = <GlobalKey>[
        for (int i = 0; i < tabs.length; i++) GlobalKey(),
      ];
    }
    const double outerVertical = 4;
    const double trackPadding = 3;
    final double height = _bar.preferredSize.height;
    final double segmentHeight = height - 2 * outerVertical - 2 * trackPadding;
    final int selected = _shown.clamp(0, tabs.length - 1);

    Widget segment(int i) {
      final bool isSelected = i == selected;
      final Color fg = isSelected
          ? (_bar.labelColor ?? tabTheme.labelColor ?? cs.onSecondaryContainer)
          : (_bar.unselectedLabelColor ??
                tabTheme.unselectedLabelColor ??
                cs.onSurfaceVariant);
      final TextStyle base =
          (isSelected
              ? (_bar.labelStyle ?? tabTheme.labelStyle)
              : (_bar.unselectedLabelStyle ??
                    tabTheme.unselectedLabelStyle ??
                    _bar.labelStyle ??
                    tabTheme.labelStyle)) ??
          theme.textTheme.titleSmall ??
          const TextStyle();
      Widget content = DefaultTextStyle(
        style: base.copyWith(color: fg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: IconTheme.merge(
          data: IconThemeData(color: fg, size: 20),
          child: SizedBox(
            height: segmentHeight,
            child: Padding(
              padding:
                  _bar.labelPadding ??
                  tabTheme.labelPadding ??
                  const EdgeInsets.symmetric(horizontal: 14),
              child: Center(widthFactor: 1, child: tabs[i]),
            ),
          ),
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
      Widget button = GlassButton.custom(
        key: _segmentKeys[i],
        onTap: () => _select(i),
        style: isSelected
            ? GlassButtonStyle.filled
            : GlassButtonStyle.transparent,
        settings: isSelected
            ? fushiGlassSettings(
                context,
                tint:
                    _bar.indicatorColor ??
                    tabTheme.indicatorColor ??
                    cs.secondaryContainer,
              )
            : null,
        quality: fushiGlassQuality(context),
        shape: LiquidRoundedSuperellipse(borderRadius: segmentHeight / 2),
        stretch: 0.2,
        label: _semanticLabelOf(tabs[i]),
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

    final TabAlignment alignment =
        _bar.tabAlignment ??
        tabTheme.tabAlignment ??
        (_bar.isScrollable ? TabAlignment.start : TabAlignment.fill);
    Widget row;
    if (_bar.isScrollable) {
      row = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _bar.scrollController,
        physics: _bar.physics,
        dragStartBehavior: _bar.dragStartBehavior,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[for (int i = 0; i < tabs.length; i++) segment(i)],
        ),
      );
    } else if (alignment == TabAlignment.center) {
      row = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[for (int i = 0; i < tabs.length; i++) segment(i)],
      );
    } else {
      row = Row(
        children: <Widget>[
          for (int i = 0; i < tabs.length; i++) Expanded(child: segment(i)),
        ],
      );
    }
    final Widget track = GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      shape: LiquidRoundedSuperellipse(
        borderRadius: segmentHeight / 2 + trackPadding,
      ),
      padding: const EdgeInsets.all(trackPadding),
      child: Material(type: MaterialType.transparency, child: row),
    );
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
