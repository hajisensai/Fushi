/// 阅读器面板（导航 / 有声书 / 阅读设置 / 统计）共用的视觉组件——四类侧板是
/// **一个整体**，页头、页签、进度、引文卡、空状态、当前项高亮只在这里定义一次
/// （设计约定见 scratchpad/reader-chrome-brief.md；外壳在
/// `lib/src/reader/reader_desktop_chrome.dart`）。
///
/// 两套设计系统：
///  * Material 一律 **M3 Expressive**（用户 2026-10-05：不再区分 MD3 / M3E）：
///    形状对比（大容器 28 / 内卡 20 / 小件 12）、饱和的 container 色块、
///    Emphasized 字阶（页头 titleLarge 加粗、指标用 display 级大数字）、波浪进度、
///    连接式按钮组页签、cookie 形图标底、spring 动效。
///  * Apple 保持 iOS 26 分组列表语汇：卡片圆角 14、分段控件、细线进度、
///    secondaryGroupedBackground 卡面。
///
/// 动效：列表 / 卡片错峰进场用 [readerPanelStagger]（[FushiStaggeredEntrance]），
/// 按压用 [FushiPressScale]；墨水屏 / 减弱动态效果下全部瞬时（共享判据）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// ── 形状尺度（M3E 形状对比：大容器 / 内卡 / 小件）────────────────────────────

/// 大容器（侧板外壳、sheet）圆角：M3E 28 / Apple 同 28（系统 sheet）。
const double kReaderPanelLargeRadius = 28;

/// 内卡圆角：M3E 20 / Apple 14。
double readerPanelCardRadius(BuildContext context) =>
    isGlassDesign(context) ? 14 : 20;

/// 小件（行内高亮、chip、按钮底）圆角：M3E 12 / Apple 10。
double readerPanelSmallRadius(BuildContext context) =>
    isGlassDesign(context) ? 10 : 12;

/// 侧板页头高：侧板 64、底部 sheet 56（约定「页头 56/64」）。
const double kReaderPanelHeaderHeight = 64;
const double kReaderPanelHeaderCompactHeight = 56;

/// 列表项最小高：手机 48、桌面 40（约定）。
double readerPanelRowMinHeight(BuildContext context) =>
    isDesktopPlatform ? 40 : 48;

/// 卡片 / 列表错峰进场：把第 [index] 项包进 [FushiStaggeredEntrance]。调用方
/// 在列表外包 [FushiEntranceScope]（否则窗口常开）。
Widget readerPanelStagger(int index, Widget child) =>
    FushiStaggeredEntrance(index: index, child: child);

// ── 页头 ─────────────────────────────────────────────────────────────────

/// 面板页头：`[cookie 图标底] 标题 / 副标题 … [动作] [×]`。
///
/// M3E：图标落在 primaryContainer 的 9 瓣 cookie 形底上（[ReaderCookieBorder]），
/// 标题 titleLarge w800（Emphasized）。Apple：图标是强调色字形、无底，标题
/// title2 粗体，关闭键是灰色圆底 xmark（iOS sheet 关闭键）。
///
/// [title] 变化时（侧板原地换内容）标题交叉淡入（[AnimatedSwitcher]）。
class ReaderPanelHeader extends StatelessWidget {
  const ReaderPanelHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onClose,
    this.actions = const <Widget>[],
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onClose;
  final List<Widget> actions;

  /// 底部 sheet 形态（56 高、上边距收窄）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final String? sub = subtitle?.trim();
    final TextStyle? titleStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: glass ? FontWeight.w700 : FontWeight.w800,
      color: fushiNeutralBlockForeground(context),
      height: 1.15,
    );
    final Widget titleBlock = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: Column(
        key: ValueKey<String>('reader_panel_header_$title'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            key: const ValueKey<String>('fushi_side_sheet_title'),
            style: titleStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null && sub.isNotEmpty)
            Text(
              sub,
              key: const ValueKey<String>('fushi_side_sheet_subtitle'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fushiNeutralSecondaryForeground(context),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: compact
            ? kReaderPanelHeaderCompactHeight
            : kReaderPanelHeaderHeight,
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(20, compact ? 2 : 10, 8, 6),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              ReaderPanelIconBadge(
                key: const ValueKey<String>('fushi_side_sheet_icon'),
                icon: icon!,
              ),
              const SizedBox(width: 14),
            ],
            Expanded(child: titleBlock),
            ...actions,
            if (onClose != null)
              Semantics(
                identifier: 'hibiki.reader.side_sheet.close',
                child: glass
                    ? FushiIconButtonControl.filledTonal(
                        key: const ValueKey<String>('fushi_side_sheet_close'),
                        icon: const FushiIcon(FushiIcons.close),
                        iconSize: 18,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: onClose,
                      )
                    : FushiIconButtonControl(
                        key: const ValueKey<String>('fushi_side_sheet_close'),
                        icon: const FushiIcon(FushiIcons.close),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: onClose,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 页头 / 当前项的图标底。M3E：primaryContainer 的 9 瓣 cookie（M3E 形状库
/// 「Cookie9Sided」）；Apple：强调色淡底圆角方（iOS 设置图标形）。
class ReaderPanelIconBadge extends StatelessWidget {
  const ReaderPanelIconBadge({super.key, required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (glass) {
      final FushiAppleColors apple = appleColorsOf(context);
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: apple.accent.withValues(alpha: 0.14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(size * 0.25)),
            ),
          ),
          child: Center(
            child: FushiIcon(icon, color: apple.accent, size: size * 0.55),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: scheme.primaryContainer,
          shape: const ReaderCookieBorder(),
        ),
        child: Center(
          child: FushiIcon(
            icon,
            color: scheme.onPrimaryContainer,
            size: size * 0.52,
          ),
        ),
      ),
    );
  }
}

/// M3E 形状库的「cookie」：极径 r(θ) = R·(1 − a + a·cos(nθ))，n 瓣、凹凸幅度 a。
/// 9 瓣 + 幅度 0.08 ≈ Cookie9Sided。按实际尺寸解析，可直接用作 [ShapeDecoration]。
class ReaderCookieBorder extends OutlinedBorder {
  const ReaderCookieBorder({super.side, this.petals = 9, this.depth = 0.08});

  final int petals;
  final double depth;

  Path _path(Rect rect) {
    final double radius = math.min(rect.width, rect.height) / 2;
    final Offset c = rect.center;
    const int samples = 144;
    final Path path = Path();
    for (int i = 0; i <= samples; i++) {
      final double theta = i / samples * 2 * math.pi - math.pi / 2;
      final double r = radius * (1 - depth + depth * math.cos(petals * theta));
      final Offset p = Offset(
        c.dx + r * math.cos(theta),
        c.dy + r * math.sin(theta),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  ReaderCookieBorder copyWith({BorderSide? side}) =>
      ReaderCookieBorder(side: side ?? this.side, petals: petals, depth: depth);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(_path(rect), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) =>
      ReaderCookieBorder(side: side.scale(t), petals: petals, depth: depth);
}

// ── 页签 ─────────────────────────────────────────────────────────────────

/// 页签的一项。
@immutable
class ReaderPanelTab<T> {
  const ReaderPanelTab({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final Key? key;
}

/// 面板分段页签（约定：四类侧板只用这一种）。M3E = 连接式按钮组（选中段弹成
/// 全胶囊、primary 填充）；Apple = 分段控件。撑满可用宽度。
class ReaderPanelTabs<T> extends StatelessWidget {
  const ReaderPanelTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 8),
  });

  final List<ReaderPanelTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (tabs.length < 2) return const SizedBox.shrink();
    // 标签多于 3 颗时不带图标（窄侧板放不下），只留文字。
    final bool icons = tabs.length <= 3;
    return Padding(
      padding: padding,
      child: FushiSegmentedButton<T>(
        key: const ValueKey<String>('reader_panel_tabs'),
        expandedInsets: EdgeInsets.zero,
        showSelectedIcon: false,
        segments: <ButtonSegment<T>>[
          for (final ReaderPanelTab<T> tab in tabs)
            ButtonSegment<T>(
              value: tab.value,
              icon: icons && tab.icon != null
                  ? FushiIcon(tab.icon!, size: 18)
                  : null,
              label: Text(
                tab.label,
                key: tab.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        selected: <T>{selected},
        onSelectionChanged: (Set<T> values) {
          if (values.isEmpty) return;
          final T next = values.first;
          if (next != selected) onChanged(next);
        },
      ),
    );
  }
}

// ── 进度 ─────────────────────────────────────────────────────────────────

/// 统一进度表达：M3E 波浪线性进度（全书进度 / 有声书进度）；Apple 4px 细线。
class ReaderPanelProgress extends StatelessWidget {
  const ReaderPanelProgress({
    super.key,
    required this.value,
    this.semanticsLabel,
    this.color,
  });

  /// 0..1；null = 不定态。
  final double? value;
  final String? semanticsLabel;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double? v = value?.clamp(0.0, 1.0);
    if (isGlassDesign(context) || isEinkTheme(context)) {
      final FushiAppleColors? apple = Theme.of(
        context,
      ).extension<FushiAppleColors>();
      final Color fill = color ?? apple?.accent ?? scheme.primary;
      final Color track = apple?.tertiaryFill ?? scheme.outlineVariant;
      return Semantics(
        label: semanticsLabel,
        value: v == null ? null : '${(v * 100).round()}%',
        child: SizedBox(
          height: 4,
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 4,
              color: fill,
              backgroundColor: track,
            ),
          ),
        ),
      );
    }
    return FushiWavyLinearProgress(
      value: v,
      color: color ?? scheme.primary,
      trackColor: scheme.secondaryContainer,
      semanticsLabel: semanticsLabel,
      semanticsValue: v == null ? null : '${(v * 100).round()}%',
    );
  }
}

// ── 卡片 ─────────────────────────────────────────────────────────────────

/// 卡面色调：neutral = 中性卡面；emphasis = 饱和强调色块（M3E 当前章 / 进度卡）。
enum ReaderPanelCardTone { neutral, emphasis, tertiary }

/// 面板卡片（圆角 M3E 20 / Apple 14）。emphasis 在 M3E 下铺 primaryContainer
/// 大色块（不是淡描边），Apple 下仍是分组卡面（iOS 不用彩色卡）。
class ReaderPanelCard extends StatelessWidget {
  const ReaderPanelCard({
    super.key,
    required this.child,
    this.tone = ReaderPanelCardTone.neutral,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  final Widget child;
  final ReaderPanelCardTone tone;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// 该色调下的前景色（卡内文字 / 图标取它）。
  static Color foregroundFor(BuildContext context, ReaderPanelCardTone tone) {
    if (isGlassDesign(context)) return appleColorsOf(context).label;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return switch (tone) {
      ReaderPanelCardTone.neutral => scheme.onSurface,
      ReaderPanelCardTone.emphasis => scheme.onPrimaryContainer,
      ReaderPanelCardTone.tertiary => scheme.onTertiaryContainer,
    };
  }

  static Color backgroundFor(BuildContext context, ReaderPanelCardTone tone) {
    if (isGlassDesign(context)) {
      return appleColorsOf(context).secondaryGroupedBackground;
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return switch (tone) {
      ReaderPanelCardTone.neutral => scheme.surfaceContainer,
      ReaderPanelCardTone.emphasis => scheme.primaryContainer,
      ReaderPanelCardTone.tertiary => scheme.tertiaryContainer,
    };
  }

  @override
  Widget build(BuildContext context) {
    final double radius = readerPanelCardRadius(context);
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      side: isEinkTheme(context)
          ? BorderSide(color: Theme.of(context).colorScheme.outline)
          : BorderSide.none,
    );
    final Widget card = Material(
      color: backgroundFor(context, tone),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foregroundFor(context, tone)),
            child: IconTheme.merge(
              data: IconThemeData(color: foregroundFor(context, tone)),
              child: child,
            ),
          ),
        ),
      ),
    );
    if (onTap == null) return card;
    return FushiPressScale(child: card);
  }
}

/// 引文卡（收藏 / 搜索结果 / 句子共用）：左侧细色条 + 正文 + 次要信息行 +
/// 可选尾部动作。[current] = 当前项（secondaryContainer 底 + 色条加粗）。
class ReaderQuoteCard extends StatelessWidget {
  const ReaderQuoteCard({
    super.key,
    required this.text,
    this.meta,
    this.onTap,
    this.trailing,
    this.railColor,
    this.current = false,
    this.maxLines = 4,
    this.textStyle,
  });

  final String text;
  final String? meta;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? railColor;
  final bool current;
  final int maxLines;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = theme.colorScheme;
    final double radius = glass ? 12 : 16;
    final Color bg = current
        ? (glass
              ? appleColorsOf(context).accent.withValues(alpha: 0.12)
              : scheme.secondaryContainer)
        : (glass
              ? appleColorsOf(context).secondaryGroupedBackground
              : scheme.surfaceContainer);
    final Color fg = current && !glass
        ? scheme.onSecondaryContainer
        : (glass ? appleColorsOf(context).label : scheme.onSurface);
    final Color rail =
        railColor ?? (glass ? appleColorsOf(context).accent : scheme.primary);
    final String? m = meta?.trim();
    final Widget body = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            width: current ? 6 : 4,
            decoration: ShapeDecoration(
              color: rail,
              shape: const StadiumBorder(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    text,
                    maxLines: maxLines,
                    overflow: TextOverflow.ellipsis,
                    style: (textStyle ?? theme.textTheme.bodyMedium)?.copyWith(
                      color: fg,
                      height: 1.5,
                    ),
                  ),
                  if (m != null && m.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      m,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 4),
            Center(child: trailing),
          ],
        ],
      ),
    );
    final Widget card = Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          child: body,
        ),
      ),
    );
    return Semantics(
      selected: current,
      child: onTap == null ? card : FushiPressScale(child: card),
    );
  }
}

/// 列表行（章节 / 句子 / 资源）：最小高 48 / 40，当前项 = secondaryContainer
/// 胶囊底 + 前置图标（约定「当前项高亮统一」）。
class ReaderPanelListItem extends StatelessWidget {
  const ReaderPanelListItem({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leadingIcon,
    this.currentIcon = FushiIcons.play,
    this.current = false,
    this.onTap,
    this.titleMaxLines = 2,
    this.indent = 0,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? leadingIcon;

  /// 当前项的前置图标（非当前项不画，标题对齐留同宽空位时用 [leadingIcon]）。
  final IconData currentIcon;
  final bool current;
  final VoidCallback? onTap;
  final int titleMaxLines;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color currentBg = glass
        ? appleColorsOf(context).accent.withValues(alpha: 0.14)
        : scheme.secondaryContainer;
    final Color fg = current
        ? (glass ? appleColorsOf(context).accent : scheme.onSecondaryContainer)
        : (glass ? appleColorsOf(context).label : scheme.onSurface);
    final Color secondary = current
        ? fg.withValues(alpha: 0.78)
        : fushiNeutralSecondaryForeground(context);
    final IconData? icon = current ? currentIcon : leadingIcon;
    final String? sub = subtitle?.trim();
    // 当前项高亮底色补间过渡（当前章 / 当前句切换时不是硬切）；减弱动态与墨水屏
    // 下时长归零。
    return Semantics(
      selected: current,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          end: current ? currentBg : currentBg.withValues(alpha: 0),
        ),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        builder: (BuildContext context, Color? bg, Widget? child) => Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(readerPanelSmallRadius(context) + 4),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: readerPanelRowMinHeight(context),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(12 + indent, 8, 12, 8),
                child: Row(
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      FushiIcon(icon, size: 20, color: fg),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: titleMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: fg,
                              fontWeight: current
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                          if (sub != null && sub.isNotEmpty)
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: secondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...<Widget>[
                      const SizedBox(width: 8),
                      DefaultTextStyle.merge(
                        style: TextStyle(color: secondary),
                        child: trailing!,
                      ),
                    ],
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

// ── 指标 / 空状态 / 分组标题 ─────────────────────────────────────────────

/// Display 级大数字指标（百分比 / 时间）：M3E displaySmall w700 + 小号单位；
/// Apple largeTitle 粗体（同字阶族）。
class ReaderStatNumber extends StatelessWidget {
  const ReaderStatNumber({
    super.key,
    required this.value,
    this.unit,
    this.label,
    this.color,
    this.large = true,
  });

  final String value;
  final String? unit;
  final String? label;
  final Color? color;

  /// false = headlineMedium（并排的次要指标）。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg =
        color ??
        DefaultTextStyle.of(context).style.color ??
        theme.colorScheme.onSurface;
    final TextStyle? numStyle =
        (large ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)
            ?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
              height: 1.0,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(text: value, style: numStyle),
              if (unit != null && unit!.isNotEmpty)
                TextSpan(
                  text: ' ${unit!}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          maxLines: 1,
        ),
        if (label != null && label!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            label!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: fg.withValues(alpha: 0.75),
            ),
          ),
        ],
      ],
    );
  }
}

/// 空状态（图标 + 一句话 + 可选按钮）。
class ReaderPanelEmpty extends StatelessWidget {
  const ReaderPanelEmpty({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ReaderPanelIconBadge(icon: icon, size: 56),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: fushiNeutralSecondaryForeground(context),
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 16),
            FushiFilledButton.tonal(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// 面板内分组小标题（M3E：primary labelLarge w700；Apple：13 号 secondaryLabel
/// 大写感灰字——取 labelMedium）。
class ReaderPanelSectionLabel extends StatelessWidget {
  const ReaderPanelSectionLabel(
    this.label, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
    this.trailing,
  });

  final String label;
  final EdgeInsets padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final TextStyle? style = glass
        ? theme.textTheme.labelMedium?.copyWith(
            color: appleColorsOf(context).secondaryLabel,
            fontWeight: FontWeight.w600,
          )
        : theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          );
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
