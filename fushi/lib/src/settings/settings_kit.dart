import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart' show CupertinoSearchTextField;
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_section_anchor.dart';

export 'package:fushi/src/utils/components/settings_section_anchor.dart'
    show SettingsSectionAnchor, SettingsSectionSpy, SettingsSectionSpyScope;

// =============================================================================
// 设置模块统一设计系统（settings kit，2026-10-05）
//
// 设置首页、schema 详情页、各手写设置页与快捷键页共用的一套「壳 + 行 + 动效」
// 积木。两套视觉语言，只按设计系统分流，不按平台：
//
// - [SettingsKitStyle.expressive]：Material 3 Expressive（Material 设计系统一律
//   如此，不再保留普通 MD3 分支）。饱和的 container 色块分区、形状对比（选中图标
//   底在方圆角与圆之间弹簧变形、页头胶囊）、Emphasized 字阶、spring 动效。
// - [SettingsKitStyle.apple]：「玻璃」设计系统（iOS / macOS 26「设置」）。系统色
//   着色的图标字形（不垫底）、液态玻璃胶囊搜索框、大标题收成行内标题。
//
// 墨水屏与系统「减弱动态效果」下所有装饰性动效归零（[fushiExpressiveMotionEnabled]
// / [fushiMotionDuration]），状态变化仍然发生、只是瞬间到位。
//
// API 一览（快捷键页等新页面直接复用）：
// - [SettingsKitStyle.of]                    当前视觉语言
// - [SettingsSpringValue]                    弹簧驱动的标量 builder
// - [SettingsShapeIcon] / [settingsIconToneFor] 分类 / 行首图标块（M3E 形变）
// - [SettingsSearchBar]                      胶囊搜索栏（↓ 进结果、回车开首条）
// - [SettingsSearchResultsView]              分组 + 高亮的搜索结果（含空状态）
// - [SettingsHighlightedText]                按查询词高亮的文本
// - [SettingsFloatingHeader]                 浮动页头：返回 + 标题胶囊 + 动作组，
//                                             随滚动收缩、当前分组名粘在标题下
// - [SettingsSectionSpy] / [SettingsSectionJumpBar] 页内分组跳转 + 滚动高亮
// - [SettingsModifiedRow]                    「改过默认值」标记 + 单项恢复默认
// - [SettingsDangerRow]                      危险操作行
// - [SettingsEmptyState] / [SettingsLoadingState] 空状态 / 加载态
// - [SettingsKitScaffold]                    以上页头 + 跳转条 + 滚动正文的整页壳
// =============================================================================

/// 设置模块的两套视觉语言。
enum SettingsKitStyle {
  /// Material 3 Expressive。
  expressive,

  /// 「玻璃」设计系统（Apple）。
  apple;

  /// 当前上下文的视觉语言：玻璃设计系统（且不是隐藏的 Cupertino renderer）→
  /// [apple]，其余一律 [expressive]。
  static SettingsKitStyle of(BuildContext context) =>
      isGlassDesign(context) && !isCupertinoPlatform(context)
      ? SettingsKitStyle.apple
      : SettingsKitStyle.expressive;
}

/// M3E 圆角分级：大容器 28 / 内卡 20 / 小件 12（Apple 走 iOS 的 12 / 10 / 8）。
class SettingsKitRadii {
  const SettingsKitRadii._();

  static double container(SettingsKitStyle style) =>
      style == SettingsKitStyle.apple ? 12 : 28;

  static double card(SettingsKitStyle style) =>
      style == SettingsKitStyle.apple ? 10 : 20;

  static double small(SettingsKitStyle style) =>
      style == SettingsKitStyle.apple ? 8 : 12;
}

// -----------------------------------------------------------------------------
// 弹簧
// -----------------------------------------------------------------------------

/// 弹簧驱动的标量：[value] 变化时从当前位置（连同当前速度）弹到新值，减弱动态
/// 效果 / 墨水屏下直接跳到新值。builder 拿到的是**可能越界**的瞬时值（弹簧的
/// overshoot 正是 M3E 的回弹手感），用作颜色插值时调用方自己 clamp。
class SettingsSpringValue extends StatefulWidget {
  const SettingsSpringValue({
    required this.value,
    required this.builder,
    super.key,
    this.spring,
    this.child,
  });

  final double value;
  final SpringDescription? spring;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;

  @override
  State<SettingsSpringValue> createState() => _SettingsSpringValueState();
}

class _SettingsSpringValueState extends State<SettingsSpringValue>
    with SingleTickerProviderStateMixin {
  // initState 里建（不懒建）：从没 build 过就被 dispose 时，懒建会在已失活的
  // element 上查 TickerMode 而抛异常（FushiPressScale 同款坑）。
  late final FushiSpring _spring;

  @override
  void initState() {
    super.initState();
    _spring = FushiSpring(
      vsync: this,
      initial: widget.value,
      spring: widget.spring ?? fushiExpressiveDefaultSpatial,
    );
  }

  @override
  void didUpdateWidget(SettingsSpringValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _spring.animateTo(
        widget.value,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spring.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? child) =>
          widget.builder(context, _spring.value, child),
    );
  }
}

// -----------------------------------------------------------------------------
// 图标块
// -----------------------------------------------------------------------------

/// 图标块的色调。M3E 下映射到 primary / secondary / tertiary / error container，
/// Apple 下映射到 iOS「设置」的系统色块。
enum SettingsIconTone { blue, teal, green, orange, purple, pink, red, gray }

/// 分类的图标色调：同一导航分组同一主色系，组内再错开，首页一眼能分区。
SettingsIconTone settingsIconToneFor(SettingsDestinationId id) => switch (id) {
  SettingsDestinationId.appearance => SettingsIconTone.purple,
  SettingsDestinationId.floatingBall => SettingsIconTone.pink,
  SettingsDestinationId.reading => SettingsIconTone.blue,
  SettingsDestinationId.manga => SettingsIconTone.teal,
  SettingsDestinationId.video => SettingsIconTone.red,
  SettingsDestinationId.game => SettingsIconTone.green,
  SettingsDestinationId.mediaTracking => SettingsIconTone.orange,
  SettingsDestinationId.lookup => SettingsIconTone.orange,
  SettingsDestinationId.cardCreation => SettingsIconTone.green,
  SettingsDestinationId.downloads => SettingsIconTone.teal,
  SettingsDestinationId.services => SettingsIconTone.blue,
  SettingsDestinationId.ai => SettingsIconTone.purple,
  SettingsDestinationId.profiles => SettingsIconTone.pink,
  SettingsDestinationId.syncBackup => SettingsIconTone.blue,
  SettingsDestinationId.interconnect => SettingsIconTone.teal,
  SettingsDestinationId.storage => SettingsIconTone.gray,
  SettingsDestinationId.system ||
  SettingsDestinationId.readerQuickSettings ||
  SettingsDestinationId.videoQuickSettings ||
  SettingsDestinationId.appIcon ||
  SettingsDestinationId.shortcuts => SettingsIconTone.gray,
};

/// 导航分组的色调（分组标题的小色点、搜索结果分组头用）。
SettingsIconTone settingsIconToneForGroup(SettingsNavigationGroupId id) =>
    switch (id) {
      SettingsNavigationGroupId.interface => SettingsIconTone.purple,
      SettingsNavigationGroupId.content => SettingsIconTone.blue,
      SettingsNavigationGroupId.learning => SettingsIconTone.orange,
      SettingsNavigationGroupId.connections => SettingsIconTone.teal,
      SettingsNavigationGroupId.data => SettingsIconTone.green,
      SettingsNavigationGroupId.app => SettingsIconTone.gray,
    };

/// (容器色, 前景色)。M3E 走 ColorScheme 的三组强调 container（饱和色块），
/// Apple 走 iOS 系统色实底 + 白色字形。墨水屏下一律塌缩成描边友好的中性色。
(Color, Color) settingsToneColors(
  BuildContext context,
  SettingsIconTone tone, {
  SettingsKitStyle? style,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  if (isEinkTheme(context)) {
    return (scheme.surfaceContainerHighest, scheme.onSurface);
  }
  final SettingsKitStyle resolved = style ?? SettingsKitStyle.of(context);
  if (resolved == SettingsKitStyle.apple) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fill = switch (tone) {
      SettingsIconTone.blue => apple.accent,
      SettingsIconTone.green => apple.success,
      SettingsIconTone.orange => apple.warning,
      SettingsIconTone.red => apple.destructive,
      SettingsIconTone.gray => apple.secondaryLabel,
      // 三种 iOS 系统色在 FushiAppleColors 里没有命名槽位，按 iOS HIG 的
      // 明 / 暗两档取值（teal / purple / pink）。
      SettingsIconTone.teal =>
        dark ? const Color(0xFF40C8E0) : const Color(0xFF30B0C7),
      SettingsIconTone.purple =>
        dark ? const Color(0xFFBF5AF2) : const Color(0xFFAF52DE),
      SettingsIconTone.pink =>
        dark ? const Color(0xFFFF375F) : const Color(0xFFFF2D55),
    };
    return (fill, Colors.white);
  }
  return switch (tone) {
    SettingsIconTone.blue || SettingsIconTone.teal => (
      scheme.primaryContainer,
      scheme.onPrimaryContainer,
    ),
    SettingsIconTone.purple || SettingsIconTone.pink => (
      scheme.tertiaryContainer,
      scheme.onTertiaryContainer,
    ),
    SettingsIconTone.green || SettingsIconTone.orange => (
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
    ),
    SettingsIconTone.red => (scheme.errorContainer, scheme.onErrorContainer),
    SettingsIconTone.gray => (
      scheme.surfaceContainerHighest,
      scheme.onSurfaceVariant,
    ),
  };
}

/// 分类 / 行首图标块。
///
/// - M3E：色调 container 上的单色图标，静止是方圆角（边长 × 0.3），[selected]
///   时弹簧变形成圆并换成 primary 实底（M3E 形状库「当前项」的形状对比）。
/// - Apple：不垫底色（用户 2026-10-04），iOS 系统色着色的字形；选中（行是
///   强调色实底时）字形换成 onAccent。
class SettingsShapeIcon extends StatelessWidget {
  const SettingsShapeIcon({
    required this.icon,
    super.key,
    this.tone = SettingsIconTone.blue,
    this.selected = false,
    this.size,
  });

  final IconData icon;
  final SettingsIconTone tone;
  final bool selected;

  /// 块边长；null = M3E 40 / Apple 桌面 22、触屏 30。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final (Color container, Color onContainer) = settingsToneColors(
      context,
      tone,
      style: style,
    );
    if (style == SettingsKitStyle.apple) {
      // 玻璃：图标不垫底色块（用户 2026-10-04「图标不要填充底」），只用 iOS
      // 系统色给字形着色区分分类；占位宽度与 iOS 图标位一致，文字左缘对齐。
      final double extent =
          size ?? (FushiAppleMetrics.of(context).desktop ? 22 : 30);
      return SizedBox.square(
        dimension: extent,
        child: Center(
          child: FushiIcon(
            icon,
            size: extent * 0.78,
            color: selected ? appleColorsOf(context).onAccent : container,
          ),
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double extent = size ?? 40;
    return SettingsSpringValue(
      value: selected ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        // 圆角越过 1 的那段 overshoot 不再增大（已经是圆），改成轻微放大，
        // 让「变成圆」那一下有回弹。
        final double radius = lerpDouble(extent * 0.3, extent / 2, c)!;
        final double scale = 1 + math.max(0, t - 1) * 0.6;
        return Transform.scale(
          scale: scale,
          child: SizedBox.square(
            dimension: extent,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: Color.lerp(container, scheme.primary, c),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
              child: Center(
                child: FushiIcon(
                  icon,
                  size: extent * 0.55,
                  color: Color.lerp(onContainer, scheme.onPrimary, c),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 搜索栏
// -----------------------------------------------------------------------------

/// 设置搜索栏。
///
/// - M3E：高 56 全圆角胶囊（M3 search bar），surfaceContainerHigh 填充；获得
///   焦点时填充提亮一档并画 2px primary 描边，清除钮弹簧放大出现。
/// - Apple：液态玻璃胶囊里的 [CupertinoSearchTextField]（桌面 13 号、触屏 17 号）。
///
/// 键盘：↓ 调 [onArrowDown]（把焦点交给结果列表），回车调 [onSubmitted]
/// （约定为「打开第一条结果」）。
class SettingsSearchBar extends StatefulWidget {
  const SettingsSearchBar({
    required this.controller,
    required this.onChanged,
    super.key,
    this.focusNode,
    this.hintText,
    this.onSubmitted,
    this.onArrowDown,
    this.autofocus = false,
    this.fillColor,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onArrowDown;
  final bool autofocus;

  /// M3E 填充色覆盖（画在已有色块上时提一档用）；null = `surfaces.search`。
  final Color? fillColor;

  @override
  State<SettingsSearchBar> createState() => _SettingsSearchBarState();
}

class _SettingsSearchBarState extends State<SettingsSearchBar> {
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(SettingsSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocusNode)?.removeListener(_onFocusChanged);
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onTextChanged);
    _ownFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged('');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        widget.onArrowDown != null) {
      widget.onArrowDown!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final Widget field = SettingsKitStyle.of(context) == SettingsKitStyle.apple
        ? _buildApple(context)
        : _buildExpressive(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: field,
    );
  }

  Widget _buildApple(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = FushiAppleMetrics.of(context).desktop;
    final double radius = desktop ? 15 : 19;
    return fushiClearGlassBezel(
      context,
      radius: radius,
      child: CupertinoSearchTextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        placeholder: widget.hintText ?? t.settings_search_hint,
        backgroundColor: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        itemColor: apple.secondaryLabel,
        itemSize: desktop ? 15 : 18,
        style: TextStyle(fontSize: desktop ? 13 : 17, color: apple.label),
        placeholderStyle: TextStyle(
          fontSize: desktop ? 13 : 17,
          color: apple.secondaryLabel,
        ),
        padding: desktop
            ? const EdgeInsetsDirectional.fromSTEB(4, 6, 6, 6)
            : const EdgeInsetsDirectional.fromSTEB(5, 9, 6, 9),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        onSuffixTap: _clear,
      ),
    );
  }

  Widget _buildExpressive(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool focused = _focusNode.hasFocus;
    final bool hasText = widget.controller.text.isNotEmpty;
    const BorderRadius capsule = BorderRadius.all(Radius.circular(28));
    const InputBorder flat = OutlineInputBorder(
      borderRadius: capsule,
      borderSide: BorderSide.none,
    );
    final Color fill =
        widget.fillColor ??
        (focused ? scheme.surfaceContainerHighest : tokens.surfaces.search);
    return Material(
      type: MaterialType.transparency,
      child: FushiTextFieldControl(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hintText ?? t.settings_search_hint,
          prefixIcon: Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.rowHorizontal,
              end: tokens.spacing.gap,
            ),
            child: FushiIcon(
              FushiIcons.search,
              color: focused ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          suffixIcon: SettingsSpringValue(
            value: hasText ? 1 : 0,
            spring: fushiExpressiveFastSpatial,
            builder: (BuildContext context, double v, Widget? child) {
              if (v <= 0.01 && !hasText) return const SizedBox.shrink();
              return Transform.scale(scale: v.clamp(0.0, 1.2), child: child);
            },
            child: FushiIconButtonControl(
              icon: const FushiIcon(FushiIcons.close),
              tooltip: t.clear,
              onPressed: _clear,
            ),
          ),
          contentPadding: EdgeInsets.symmetric(
            vertical: tokens.spacing.rowVertical + 4,
          ),
          filled: !eink,
          fillColor: eink ? null : fill,
          border: eink ? const OutlineInputBorder(borderRadius: capsule) : flat,
          enabledBorder: eink ? null : flat,
          focusedBorder: eink
              ? null
              : OutlineInputBorder(
                  borderRadius: capsule,
                  borderSide: BorderSide(color: scheme.primary, width: 2),
                ),
        ),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 高亮文本 / 搜索结果
// -----------------------------------------------------------------------------

/// 按 [query]（空白分词、大小写不敏感）高亮命中片段：M3E 是 primary 前景 +
/// 加粗 + primaryContainer 底，Apple 是强调色 + semibold。
class SettingsHighlightedText extends StatelessWidget {
  const SettingsHighlightedText(
    this.text, {
    required this.query,
    super.key,
    this.style,
    this.maxLines,
  });

  final String text;
  final String query;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final List<TextRange> ranges = settingsSearchMatchRanges(text, query);
    if (ranges.isEmpty) {
      return Text(text, style: style, maxLines: maxLines);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final TextStyle highlight = apple
        ? TextStyle(
            color: appleColorsOf(context).accent,
            fontWeight: FontWeight.w600,
          )
        : TextStyle(
            color: isEinkTheme(context)
                ? scheme.onSurface
                : scheme.onPrimaryContainer,
            backgroundColor: isEinkTheme(context)
                ? null
                : scheme.primaryContainer,
            fontWeight: FontWeight.w700,
            decoration: isEinkTheme(context) ? TextDecoration.underline : null,
          );
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final TextRange range in ranges) {
      if (range.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: highlight,
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
    );
  }
}

/// 搜索结果视图：按顶层分类分组（分组头 = 分类图标块 + 分类名 + 条数），
/// 每条 = 高亮标题 + 「分区 › 子页」面包屑（命中在说明里时再带一行高亮说明），
/// 首屏错峰进场。没有结果时是 [SettingsEmptyState]。
///
/// [onOpen] 由宿主决定怎么跳（宽屏切分类、窄屏 push），视图只负责呈现。
class SettingsSearchResultsView extends StatelessWidget {
  const SettingsSearchResultsView({
    required this.results,
    required this.query,
    required this.onOpen,
    super.key,
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
  });

  final List<SettingsSearchEntry> results;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;
  final EdgeInsetsGeometry padding;

  /// true = 不自带滚动（嵌进外层滚动视图）。
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      final Widget empty = SettingsEmptyState(
        icon: FushiIcons.searchOff,
        title: t.settings_search_empty_title,
        message: t.settings_search_empty_hint,
      );
      return shrinkWrap
          ? Padding(padding: padding, child: empty)
          : Padding(
              padding: padding,
              child: Center(child: empty),
            );
    }
    final List<(SettingsDestination, List<SettingsSearchEntry>)> groups =
        <(SettingsDestination, List<SettingsSearchEntry>)>[];
    for (final SettingsSearchEntry entry in results) {
      final int index = groups.indexWhere(
        ((SettingsDestination, List<SettingsSearchEntry>) g) =>
            g.$1.id == entry.destination.id,
      );
      if (index < 0) {
        groups.add((entry.destination, <SettingsSearchEntry>[entry]));
      } else {
        groups[index].$2.add(entry);
      }
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final List<Widget> children = <Widget>[
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: tokens.spacing.rowHorizontal,
          bottom: tokens.spacing.gap,
        ),
        child: Text(
          t.settings_search_result_count(n: results.length),
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final (
            int index,
            (
              SettingsDestination destination,
              List<SettingsSearchEntry> entries,
            ),
          )
          in groups.indexed)
        FushiStaggeredEntrance(
          key: ValueKey<String>('settings-search-group.${destination.id.name}'),
          index: index,
          child: Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card),
            child: _ResultGroup(
              destination: destination,
              entries: entries,
              query: query,
              onOpen: onOpen,
            ),
          ),
        ),
    ];
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    // replayKey = 查询词：每次改词都重放一次进场，结果「刷新」有反馈。
    if (shrinkWrap) {
      return FushiEntranceScope(
        replayKey: query,
        child: Padding(padding: padding, child: column),
      );
    }
    return FushiEntranceScope(
      replayKey: query,
      child: SingleChildScrollView(padding: padding, child: column),
    );
  }
}

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({
    required this.destination,
    required this.entries,
    required this.query,
    required this.onOpen,
  });

  final SettingsDestination destination;
  final List<SettingsSearchEntry> entries;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final SettingsIconTone tone = settingsIconToneFor(destination.id);
    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.rowHorizontal - 4,
        0,
        tokens.spacing.rowHorizontal,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          SettingsShapeIcon(
            icon: destination.icon,
            tone: tone,
            size: style == SettingsKitStyle.apple ? 22 : 28,
          ),
          SizedBox(width: tokens.spacing.gap + 4),
          Expanded(
            child: Text(
              destination.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style == SettingsKitStyle.apple
                  ? FushiAppleMetrics.of(context).footnoteStyle(context)
                  : theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
            ),
          ),
          SettingsCountBadge(count: entries.length),
        ],
      ),
    );
    final double radius = SettingsKitRadii.card(style);
    final Color surface = style == SettingsKitStyle.apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        FushiCard(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          borderRadius: BorderRadius.circular(radius),
          color: surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final SettingsSearchEntry entry in entries)
                _ResultRow(entry: entry, query: query, onOpen: onOpen),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.entry,
    required this.query,
    required this.onOpen,
  });

  final SettingsSearchEntry entry;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final String breadcrumb = settingsSearchLocation(entry);
    final String? detail = entry.matchedDetail(query);
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('settings-search-result.${entry.item.id}'),
        leading: FushiIcon(entry.item.icon ?? entry.destination.icon),
        title: SettingsHighlightedText(entry.title, query: query, maxLines: 2),
        titleMaxLines: 2,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (detail != null)
              SettingsHighlightedText(detail, query: query, maxLines: 2),
            if (breadcrumb.isNotEmpty)
              Text(breadcrumb, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        subtitleMaxLines: 3,
        trailing: const FushiIcon(FushiIcons.forward),
        onTap: () => onOpen(entry),
      ),
    );
  }
}

/// 小计数徽标（搜索分组条数、分类「N 项已修改」）。
class SettingsCountBadge extends StatelessWidget {
  const SettingsCountBadge({required this.count, super.key, this.label});

  final int count;

  /// 非空时显示文字而不是纯数字。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final Color fill = apple
        ? appleColorsOf(context).tertiaryFill
        : scheme.secondaryContainer;
    final Color fg = apple
        ? appleColorsOf(context).secondaryLabel
        : scheme.onSecondaryContainer;
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label ?? '$count',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: fg,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 空状态 / 加载态
// -----------------------------------------------------------------------------

/// 空状态：M3E 是 tertiaryContainer 圆形图标块 + titleMedium 粗体 + 说明 +
/// 可选按钮；Apple 是灰色大图标 + 17 号 semibold + 15 号次级说明。
class SettingsEmptyState extends StatelessWidget {
  const SettingsEmptyState({
    required this.icon,
    required this.title,
    super.key,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final Widget glyph = apple
        ? FushiIcon(icon, size: 44, color: appleColorsOf(context).tertiaryLabel)
        : SettingsShapeIcon(
            icon: icon,
            tone: SettingsIconTone.purple,
            size: 72,
            selected: false,
          );
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.page,
          vertical: tokens.spacing.section,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            glyph,
            SizedBox(height: tokens.spacing.card),
            Text(
              title,
              textAlign: TextAlign.center,
              style: apple
                  ? TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: appleColorsOf(context).label,
                    )
                  : theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
            ),
            if (message != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: apple
                    ? TextStyle(
                        fontSize: 15,
                        color: appleColorsOf(context).secondaryLabel,
                      )
                    : theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
              ),
            ],
            if (action != null) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载态：M3E 是形状变形的 loading indicator（contained），Apple 是系统转圈。
class SettingsLoadingState extends StatelessWidget {
  const SettingsLoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.section),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (apple)
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator.adaptive(),
            )
          else
            FushiExpressiveLoadingIndicator(
              contained: true,
              semanticsLabel: label,
            ),
          if (label != null) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            Text(label!, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 浮动页头
// -----------------------------------------------------------------------------

/// 浮动页头：返回钮 + 标题胶囊 + 尾部动作组，三块都是悬浮的独立形状。
///
/// - 展开态（内容在顶）：标题大号（M3E headlineSmall 粗体 / Apple 28 粗体），
///   胶囊无底色，像一条直接写在页面上的大标题。
/// - 收缩态（[scrollController] 向下滚过阈值）：标题收成 titleMedium，胶囊
///   换成 surfaceContainerHigh 实底 + 阴影（Apple 是液态玻璃）浮在内容上方，
///   动作组同样成胶囊——M3E floating toolbar 的形态。两态之间走弹簧。
/// - [subtitle]：粘性分组标题（滚动时当前所在分组名），切换时上下淡入。
///
/// 返回钮仅在 [onBack] 非空时出现；[actions] 为空时不画动作组。
class SettingsFloatingHeader extends StatefulWidget {
  const SettingsFloatingHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.onBack,
    this.actions = const <Widget>[],
    this.scrollController,
    this.leadingIcon,
    this.leadingTone = SettingsIconTone.blue,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final ScrollController? scrollController;

  /// 标题左侧的分类图标块（详情页标题带上分类形状，与导航一致）。
  final IconData? leadingIcon;
  final SettingsIconTone leadingTone;

  @override
  State<SettingsFloatingHeader> createState() => _SettingsFloatingHeaderState();
}

class _SettingsFloatingHeaderState extends State<SettingsFloatingHeader> {
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(SettingsFloatingHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScroll);
      widget.scrollController?.addListener(_onScroll);
      _onScroll();
    }
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final ScrollController? controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;
    // 只看第一个附着位置：同一 controller 偶尔被短暂挂到两个滚动视图上
    // （路由转场期间），读 offset 会断言。
    final double offset = controller.positions.first.pixels;
    final bool collapsed = offset > 12;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = style == SettingsKitStyle.apple;
    // 与共享悬浮工具栏（fushi_floating_toolbar.dart 的 FushiFloatingTopBar）
    // 同一套胶囊：同色板、同阴影 / 发丝描边；展开态胶囊淡出成纯文字标题。
    final Color pillColor = fushiFloatingToolbarPalette(context).container;
    Widget capsule({required Widget child, required double t}) {
      final double c = t.clamp(0.0, 1.0);
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: c,
                child: DecoratedBox(
                  decoration: fushiFloatingPillDecoration(
                    context,
                    color: pillColor,
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      );
    }

    final TextStyle expandedTitle = apple
        ? TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: appleColorsOf(context).label,
          )
        : (theme.textTheme.headlineSmall ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          );
    final TextStyle collapsedTitle = apple
        ? TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: appleColorsOf(context).label,
          )
        : (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          );
    final TextStyle subtitleStyle = apple
        ? TextStyle(fontSize: 12, color: appleColorsOf(context).secondaryLabel)
        : (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          );

    return SettingsSpringValue(
      value: _collapsed ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        final Widget titleBlock = Padding(
          padding: EdgeInsets.symmetric(
            horizontal: lerpDouble(4, tokens.spacing.rowHorizontal + 2, c)!,
            vertical: lerpDouble(2, 6, c)!,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.leadingIcon != null) ...<Widget>[
                SettingsShapeIcon(
                  icon: widget.leadingIcon!,
                  tone: widget.leadingTone,
                  size: lerpDouble(apple ? 30 : 40, apple ? 22 : 28, c),
                ),
                SizedBox(width: tokens.spacing.gap + 4),
              ],
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle.lerp(expandedTitle, collapsedTitle, c),
                    ),
                    AnimatedSwitcher(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      transitionBuilder:
                          (Widget child, Animation<double> animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SizeTransition(
                                  sizeFactor: animation,
                                  axisAlignment: -1,
                                  child: child,
                                ),
                              ),
                      child: widget.subtitle == null || widget.subtitle!.isEmpty
                          ? const SizedBox.shrink(key: ValueKey<String>(''))
                          : Text(
                              widget.subtitle!,
                              key: ValueKey<String>(widget.subtitle!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page - 4,
            tokens.spacing.gap,
            tokens.spacing.page - 4,
            tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              if (widget.onBack != null) ...<Widget>[
                capsule(
                  t: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: FushiIconButtonControl(
                      icon: const FushiIcon(FushiIcons.back),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: widget.onBack,
                    ),
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
              ],
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: capsule(t: t, child: titleBlock),
                ),
              ),
              if (widget.actions.isNotEmpty)
                capsule(
                  t: math.max(t, 0.6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: FushiButtonGroup(
                      spacing: 2,
                      children: widget.actions,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 页内分组跳转
// -----------------------------------------------------------------------------

/// 页内分组跳转条：一排胶囊（分组名），当前分组胶囊弹簧变宽 + 填色
/// （M3E secondaryContainer / Apple 强调色）。可横向滚动；键盘 Tab 可达、
/// Enter 跳转。
class SettingsSectionJumpBar extends StatelessWidget {
  const SettingsSectionJumpBar({
    required this.sections,
    required this.activeId,
    required this.onSelected,
    super.key,
    this.padding,
  });

  /// (分组 id, 分组标题)。
  final List<(String, String)> sections;
  final String? activeId;
  final ValueChanged<String> onSelected;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding:
            padding ?? EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 6),
        itemBuilder: (BuildContext context, int index) {
          final (String id, String title) = sections[index];
          return Center(
            child: _JumpChip(
              key: ValueKey<String>('settings-jump.$id'),
              label: title,
              selected: id == activeId,
              onTap: () => onSelected(id),
            ),
          );
        },
      ),
    );
  }
}

class _JumpChip extends StatelessWidget {
  const _JumpChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final bool eink = isEinkTheme(context);
    final Color idle = apple
        ? appleColorsOf(context).tertiaryFill
        : scheme.surfaceContainerHigh;
    final Color active = apple
        ? appleColorsOf(context).accent
        : scheme.secondaryContainer;
    final Color idleFg = apple
        ? appleColorsOf(context).label
        : scheme.onSurfaceVariant;
    final Color activeFg = apple
        ? appleColorsOf(context).onAccent
        : scheme.onSecondaryContainer;
    return SettingsSpringValue(
      value: selected ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        return FushiPressScale(
          child: Material(
            color: Color.lerp(idle, active, c),
            shape: StadiumBorder(
              side: eink && selected
                  ? BorderSide(color: scheme.onSurface, width: 2)
                  : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                // 选中胶囊变宽（M3E 按钮组「选中项变宽」）。
                padding: EdgeInsets.symmetric(
                  horizontal: lerpDouble(14, 20, t)!,
                  vertical: 7,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Color.lerp(idleFg, activeFg, c),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 行装饰：改过默认值 / 危险操作
// -----------------------------------------------------------------------------

/// 「改过默认值」装饰：[modified] 时行首边缘出现一枚 primary 小圆点（弹簧放大），
/// 行尾追加一个「恢复默认」图标钮（键盘 / 手柄可达）。未修改时原样返回 [child]
/// 的同一棵树（不额外包层，避免切换时 State 重建）。
class SettingsModifiedRow extends StatelessWidget {
  const SettingsModifiedRow({
    required this.modified,
    required this.onReset,
    required this.child,
    super.key,
  });

  final bool modified;
  final VoidCallback onReset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final Color dot = apple ? appleColorsOf(context).accent : scheme.primary;
    return Stack(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: child),
            AnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: modified
                  ? Padding(
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: FushiIconButtonControl(
                        key: const ValueKey<String>('settings-reset-default'),
                        icon: const FushiIcon(FushiIcons.undo),
                        tooltip: t.settings_reset_to_default,
                        onPressed: onReset,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        PositionedDirectional(
          start: 3,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Center(
              child: SettingsSpringValue(
                value: modified ? 1 : 0,
                spring: fushiExpressiveFastSpatial,
                builder: (BuildContext context, double v, Widget? _) {
                  if (v <= 0.01) return const SizedBox.shrink();
                  return Tooltip(
                    message: t.settings_modified_hint,
                    child: SizedBox.square(
                      dimension: 6 * v.clamp(0.0, 1.4),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 危险操作行：error 色调的图标块 + error 色标题（Apple：destructive 红字），
/// 按压回弹。用于清空 / 删除 / 重置这类不可撤销的动作。
class SettingsDangerRow extends StatelessWidget {
  const SettingsDangerRow({
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final Color danger = apple
        ? appleColorsOf(context).destructive
        : scheme.error;
    return FushiPressScale(
      child: FushiListItem(
        leading: icon == null
            ? null
            : SettingsShapeIcon(
                icon: icon!,
                tone: SettingsIconTone.red,
                size: apple ? null : 36,
              ),
        title: Text(
          title,
          style: TextStyle(color: danger, fontWeight: FontWeight.w600),
        ),
        titleMaxLines: 2,
        subtitle: subtitle == null ? null : Text(subtitle!),
        onTap: onTap,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 整页壳
// -----------------------------------------------------------------------------

/// 设置子页整页壳：浮动页头（返回 + 标题胶囊 + 动作组）+ 可选分组跳转条 +
/// 自持滚动的正文。正文由 [bodyBuilder] 按给定的滚动控制器与 [SettingsSectionSpy]
/// 构建（schema 详情页用 spy 给分组挂锚点；手写页可以忽略 spy）。
///
/// 页面底色走 `surfaces.page`（Apple 走 groupedBackground），整页 [Material]
/// 提供 ink 上下文。
class SettingsKitScaffold extends StatefulWidget {
  const SettingsKitScaffold({
    required this.title,
    required this.bodyBuilder,
    super.key,
    this.leadingIcon,
    this.leadingTone = SettingsIconTone.blue,
    this.actions = const <Widget>[],
    this.showBack = true,
    this.sections = const <(String, String)>[],
  });

  final String title;
  final IconData? leadingIcon;
  final SettingsIconTone leadingTone;
  final List<Widget> actions;

  /// true = 能 pop 时画返回钮（根页 / 嵌入宿主传 false）。
  final bool showBack;

  /// 旧接口保留（不再使用）：分组表现在由页内带标题的共享分组组件自动登记
  /// （见 settings_section_anchor.dart），≥ 2 个分组即画跳转条。
  final List<(String, String)> sections;

  final Widget Function(
    BuildContext context,
    ScrollController controller,
    SettingsSectionSpy spy,
  )
  bodyBuilder;

  @override
  State<SettingsKitScaffold> createState() => _SettingsKitScaffoldState();
}

class _SettingsKitScaffoldState extends State<SettingsKitScaffold> {
  final ScrollController _controller = ScrollController();
  final SettingsSectionSpy _spy = SettingsSectionSpy();

  @override
  void initState() {
    super.initState();
    _spy.attach(_controller);
    _spy.addListener(_onSpy);
    // 独立路由页登记为当前页滚动控制器：手柄 LB / RB 翻屏兜底够得到正文
    // （与 FushiPageScaffold 同一约定）。嵌在宽屏右窗格时不登记——那里由宿主页负责。
    if (widget.showBack) PageScrollRegistry.push(_controller);
  }

  @override
  void dispose() {
    if (widget.showBack) PageScrollRegistry.pop(_controller);
    _spy.removeListener(_onSpy);
    _spy.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onSpy() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color page = apple
        ? appleColorsOf(context).groupedBackground
        : tokens.surfaces.page;
    final bool canPop =
        widget.showBack && (ModalRoute.of(context)?.canPop ?? false);
    // 分组跳转条：页内只要有 ≥ 2 个带标题的分组就出现（单组页不画）。
    final List<(String, String)> sections = _spy.sections;
    final bool jump = sections.length >= 2;
    String? activeTitle;
    for (final (String id, String title) in sections) {
      if (id == _spy.activeId) activeTitle = title;
    }
    final Widget body = widget.bodyBuilder(context, _controller, _spy);
    final Widget column = SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsFloatingHeader(
            title: widget.title,
            subtitle: jump ? activeTitle : null,
            leadingIcon: widget.leadingIcon,
            leadingTone: widget.leadingTone,
            scrollController: _controller,
            onBack: canPop ? () => Navigator.of(context).maybePop() : null,
            actions: widget.actions,
          ),
          // 跳转条吸在页头下方（不随正文滚动），出现 / 消失走尺寸 + 淡入过渡。
          // 与下方第一个分组标题之间留一档 gap：此前胶囊底紧贴分组标题，两排
          // 文字读成一行。
          AnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.enter,
            alignment: Alignment.topCenter,
            child: jump
                ? Padding(
                    padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                    child: SettingsSectionJumpBar(
                      sections: sections,
                      activeId: _spy.activeId,
                      onSelected: (String id) => _spy.jumpTo(
                        id,
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.long,
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: SettingsSectionSpyScope(
              spy: _spy,
              child: PrimaryScrollController(
                controller: _controller,
                automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
                child: body,
              ),
            ),
          ),
        ],
      ),
    );
    // 独立路由页用 Scaffold（SnackBar / 键盘避让都要它）；嵌在宽屏右窗格时
    // 只铺 Material，不再套第二层 Scaffold。
    if (widget.showBack) {
      return Scaffold(backgroundColor: page, body: column);
    }
    return Material(color: page, child: column);
  }
}

/// 设置项「是否改过默认值」与恢复动作的统一判据（schema 渲染层与快捷键页共用）。
class SettingsResetSpec {
  const SettingsResetSpec({required this.modified, required this.reset});

  final bool modified;
  final Future<void> Function() reset;
}

/// 读 schema item 的 `defaultValue` 判断是否改过；没声明默认值的项返回 null
/// （不出标记，也不出恢复钮）。
SettingsResetSpec? settingsResetSpecFor(
  SettingsItem item,
  SettingsContext context,
) {
  if (item is SettingsSwitchItem) {
    final bool? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    return SettingsResetSpec(
      modified: item.value(context) != defaultValue,
      reset: () async {
        await item.onChanged(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsSliderItem) {
    final double? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    return SettingsResetSpec(
      modified: (item.value(context) - defaultValue).abs() > 1e-6,
      reset: () async {
        await item.onChanged(context, defaultValue);
        await item.onChangeEnd?.call(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsStepperItem) {
    final double? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    return SettingsResetSpec(
      modified: (item.value(context) - defaultValue).abs() > 1e-6,
      reset: () async {
        await item.onChanged(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsSegmentedItem) {
    final SettingsSegmentedItem<Object> segmented =
        item as SettingsSegmentedItem<Object>;
    final Object? defaultValue = segmented.defaultValue;
    if (defaultValue == null) return null;
    return SettingsResetSpec(
      modified: segmented.selected(context) != defaultValue,
      reset: () async {
        await segmented.dispatchChange(context, defaultValue);
        context.refresh();
      },
    );
  }
  return null;
}

/// 详情页分组跳转条的条目：只收带标题的分组，id 与渲染层锚点同一口径
/// （`section.id ?? 第一项 id`）。
List<(String, String)> settingsJumpSections(List<SettingsSection> sections) {
  return <(String, String)>[
    for (final SettingsSection section in sections)
      if ((section.title?.isNotEmpty ?? false) && section.items.isNotEmpty)
        (settingsSectionAnchorId(section), section.title!),
  ];
}

/// 分组锚点 id（[settingsJumpSections] 与渲染层共用）。
String settingsSectionAnchorId(SettingsSection section) =>
    section.id ?? section.items.first.id;

/// 旧接口保留：分组锚点现在由共享分组组件（AdaptiveSettingsSection /
/// SettingsSectionHeader）自动挂，schema 分组也走那条路，这里原样返回。
Widget settingsSectionAnchor({
  required SettingsSectionSpy? spy,
  required SettingsSection section,
  required Widget child,
}) => child;
