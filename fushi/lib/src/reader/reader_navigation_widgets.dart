import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 阅读器「导航」侧板（目录 / 收藏 / 搜索）的专用视觉件。共享件（页签、进度条、
/// 引文卡、空状态）在 [reader_panel_kit.dart]。

/// 目录项的层级：`depth >= 2` 的旧口径（深度 2 起是子节）与 `parent` 链两套
/// 来源取其一——真实 EPUB 经 `flattenTtuTocEntries` 压平后 depth 恒为 0，层级
/// 只活在 `parent` 上（父项标签），所以按「最近一条标签等于 parent 的前序项」
/// 往上数。父项不在目录里（href 解析不到被跳过）时按顶层处理，不会被折叠藏掉。
///
/// 返回与 [toc] 等长的层级表（0 = 顶层）以及每项的父项下标（无则 -1）。
({List<int> levels, List<int> parents}) readerTocHierarchy(
  List<TtuTocEntry> toc,
) {
  final List<int> levels = List<int>.filled(toc.length, 0);
  final List<int> parents = List<int>.filled(toc.length, -1);
  final Map<String, int> lastByLabel = <String, int>{};
  for (int i = 0; i < toc.length; i++) {
    final TtuTocEntry e = toc[i];
    if (e.depth >= 2) {
      levels[i] = e.depth - 1;
      // 旧口径：向前找第一条更浅的项当父项。
      for (int j = i - 1; j >= 0; j--) {
        if (levels[j] < levels[i]) {
          parents[i] = j;
          break;
        }
      }
    } else if (e.parent != null && lastByLabel.containsKey(e.parent)) {
      final int p = lastByLabel[e.parent]!;
      parents[i] = p;
      levels[i] = levels[p] + 1;
    }
    lastByLabel[e.label] = i;
  }
  return (levels: levels, parents: parents);
}

/// 目录行相对阅读位置的状态。
enum ReaderTocRowState {
  /// 当前位置之前（已读）：文字淡化。
  read,

  /// 当前章：强调色块 + 形状底图标。
  current,

  /// 还没读到。
  unread,
}

/// 面板可用高度低于它时进度 hero 收成单行（底部 sheet 半屏档）。
const double kReaderNavCompactHeroBelow = 560;

/// 目录行最小高：触屏 48 / 桌面 44。
double readerTocRowMinHeight() => isDesktopPlatform ? 44 : 48;

/// 每级缩进。
const double kReaderTocIndent = 18;

/// 目录一行：层级缩进 + 引导线、当前章色块 + 形状图标、已读淡化、可折叠父项
/// 的旋转箭头。标题最多 4 行再省略（长章节名在手机上要能读全，TODO-1055）。
class ReaderTocRow extends StatelessWidget {
  const ReaderTocRow({
    required this.title,
    this.level = 0,
    this.header = false,
    this.state = ReaderTocRowState.unread,
    this.foldable = false,
    this.expanded = false,
    this.onToggleExpanded,
    this.foldKey,
    this.onTap,
    super.key,
  });

  final String title;
  final int level;
  final bool header;
  final ReaderTocRowState state;
  final bool foldable;
  final bool expanded;
  final VoidCallback? onToggleExpanded;
  final Key? foldKey;
  final VoidCallback? onTap;

  /// 章节名最多显示行数（再长才省略）。
  static const int titleMaxLines = 4;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final ColorScheme cs = theme.colorScheme;
    final bool current = state == ReaderTocRowState.current;
    final double indent = level * kReaderTocIndent;

    if (header) {
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: 12 + indent,
          end: 12,
          top: 16,
          bottom: 6,
        ),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: glass ? apple!.secondaryLabel : cs.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    final Color titleColor = current
        ? (glass ? apple!.label : cs.onSecondaryContainer)
        : state == ReaderTocRowState.read
        ? (glass ? apple!.secondaryLabel : cs.onSurfaceVariant)
        : (glass ? apple!.label : cs.onSurface);
    final TextStyle? titleStyle =
        (level == 0 ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
            ?.copyWith(
              color: titleColor,
              fontWeight: current
                  ? FontWeight.w700
                  : level == 0
                  ? FontWeight.w500
                  : FontWeight.w400,
              height: 1.35,
            );
    final Color guideColor = glass ? apple!.separator : cs.outlineVariant;
    final Color fill = eink
        ? Colors.transparent
        : glass
        ? apple!.accent.withValues(alpha: 0.14)
        : cs.secondaryContainer;
    final double radius = current
        ? (glass ? 10 : 20)
        : readerPanelItemRadius(context);

    final Widget body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: readerTocRowMinHeight()),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: 12 + indent,
          end: foldable ? 4 : 12,
          top: 6,
          bottom: 6,
        ),
        child: Row(
          children: <Widget>[
            if (current) ...<Widget>[
              TweenAnimationBuilder<double>(
                key: const ValueKey<String>('reader_toc_current_badge'),
                tween: Tween<double>(begin: 0.4, end: 1),
                duration: fushiMotionDuration(context, FushiMotion.long),
                curve: FushiMotion.release,
                builder: (BuildContext context, double s, Widget? child) =>
                    Transform.scale(scale: s, child: child),
                child: ReaderShapeBadge(
                  icon: glass
                      ? Icons.play_arrow_rounded
                      : Icons.auto_stories_rounded,
                  size: glass ? 26 : 32,
                  shape: ReaderBadgeShape.cookie4,
                  iconSize: glass ? 18 : 17,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: titleMaxLines,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (foldable)
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.release,
                child: FushiIconButtonControl(
                  key: foldKey,
                  iconSize: 22,
                  tooltip: expanded
                      ? MaterialLocalizations.of(context).collapsedIconTapHint
                      : MaterialLocalizations.of(context).expandedIconTapHint,
                  icon: FushiIcon(
                    Icons.expand_more_rounded,
                    color: glass ? apple!.tertiaryLabel : cs.onSurfaceVariant,
                  ),
                  onPressed: onToggleExpanded,
                ),
              ),
          ],
        ),
      ),
    );

    final bool focusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    final BorderRadius br = BorderRadius.circular(radius);
    Widget row = Material(
      type: current ? MaterialType.canvas : MaterialType.transparency,
      color: current ? fill : null,
      borderRadius: br,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: br,
        canRequestFocus: !focusRoot,
        splashFactory: glass ? NoSplash.splashFactory : null,
        highlightColor: glass ? apple!.fill : null,
        child: body,
      ),
    );
    if (current) {
      row = DecoratedBox(
        key: const ValueKey<String>('reader_toc_current_fill'),
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: br,
          border: eink ? Border.all(color: cs.outline) : null,
        ),
        child: row,
      );
    }
    if (level > 0) {
      // 缩进引导线：每级一条细竖线，画在缩进区内、文字左侧。
      row = CustomPaint(
        painter: _TocGuidePainter(
          levels: level,
          color: guideColor,
          textDirection: Directionality.of(context),
        ),
        child: row,
      );
    }
    row = Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: row);
    row = FushiPressScale(enabled: onTap != null, scale: 0.98, child: row);
    if (onTap == null || !focusRoot) return row;
    return FushiActivatableFocusTarget(
      focusIdPrefix: 'reader-toc-row',
      onTap: onTap!,
      child: row,
    );
  }
}

class _TocGuidePainter extends CustomPainter {
  _TocGuidePainter({
    required this.levels,
    required this.color,
    required this.textDirection,
  });

  final int levels;
  final Color color;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (int l = 0; l < levels; l++) {
      final double dx = 20 + l * kReaderTocIndent;
      final double x = textDirection == TextDirection.rtl
          ? size.width - dx
          : dx;
      canvas.drawLine(Offset(x, 4), Offset(x, size.height - 4), p);
    }
  }

  @override
  bool shouldRepaint(_TocGuidePainter old) =>
      old.levels != levels ||
      old.color != color ||
      old.textDirection != textDirection;
}

/// 导航页头下的阅读进度 hero：
/// - M3E：饱和 primaryContainer 大色块，Display 级全书百分比 + 波浪全书进度条，
///   左上封面缩略（有封面时）、当前章名、章 / 页 / 字读数。
/// - Apple：分组卡 + 大号圆体百分比 + 细线进度。
/// [compact] 用于矮面板（底部 sheet 半屏档）：单行「百分比 + 章名 + 进度条」，
/// 把高度让给下面的列表。
class ReaderNavProgressHero extends StatelessWidget {
  const ReaderNavProgressHero({
    required this.fraction,
    required this.chapter,
    required this.fallbackTitle,
    this.readouts = const <String>[],
    this.coverPath,
    this.caption,
    this.compact = false,
    this.footer,
    super.key,
  });

  final double? fraction;
  final String? chapter;

  /// 没有章名时的标题（「阅读进度」）。
  final String fallbackTitle;

  /// 「全书」之类的百分比说明。
  final String? caption;
  final List<String> readouts;
  final String? coverPath;
  final bool compact;

  /// 额外的一行（有声书音频进度）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final ColorScheme cs = theme.colorScheme;
    final Color bg = glass
        ? apple!.secondaryGroupedBackground
        : eink
        ? cs.surface
        : cs.primaryContainer;
    final Color fg = glass ? apple!.label : cs.onPrimaryContainer;
    final Color fgSoft = glass
        ? apple!.secondaryLabel
        : cs.onPrimaryContainer.withValues(alpha: 0.78);
    final String title = chapter == null || chapter!.isEmpty
        ? fallbackTitle
        : chapter!;
    final double? f = fraction?.clamp(0.0, 1.0);
    final String? pct = f == null ? null : (f * 100).toStringAsFixed(1);
    const List<FontFeature> tabular = <FontFeature>[
      FontFeature.tabularFigures(),
    ];

    Widget percent(TextStyle? big, TextStyle? small) => pct == null
        ? const SizedBox.shrink()
        : Text.rich(
            key: const ValueKey<String>('reader_nav_progress_percent'),
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: pct),
                TextSpan(
                  text: '%',
                  style: small?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                    height: 1.0,
                  ),
                ),
              ],
            ),
            style: big?.copyWith(
              color: glass ? apple!.label : cs.onPrimaryContainer,
              fontWeight: glass ? FontWeight.w700 : FontWeight.w800,
              height: 1.0,
              letterSpacing: glass ? 0 : -1,
              fontFeatures: tabular,
            ),
          );

    final Widget? bar = f == null
        ? null
        : ReaderPanelProgress(
            key: const ValueKey<String>('reader_nav_progress_bar'),
            value: f,
            color: glass ? apple!.accent : (eink ? cs.onSurface : cs.primary),
            trackColor: glass
                ? apple!.fill
                : eink
                ? cs.outlineVariant
                : cs.onPrimaryContainer.withValues(alpha: 0.16),
          );

    final Widget chapterText = Text(
      title,
      maxLines: compact ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style:
          (compact ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)
              ?.copyWith(color: fg, fontWeight: FontWeight.w700, height: 1.3),
    );

    final Widget content;
    if (compact) {
      content = Row(
        children: <Widget>[
          if (pct != null) ...<Widget>[
            percent(
              glass
                  ? theme.textTheme.headlineSmall
                  : theme.textTheme.headlineMedium,
              glass ? theme.textTheme.titleSmall : theme.textTheme.titleMedium,
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                chapterText,
                if (bar != null) ...<Widget>[const SizedBox(height: 8), bar],
              ],
            ),
          ),
        ],
      );
    } else {
      final String? cover = coverPath;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (cover != null) ...<Widget>[
                _HeroCover(path: cover),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    chapterText,
                    if (readouts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final String r in readouts)
                            _ReadoutChip(label: r, glass: glass),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (pct != null) ...<Widget>[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                percent(
                  glass
                      ? theme.textTheme.headlineLarge
                      : theme.textTheme.displaySmall,
                  glass
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge,
                ),
                if (caption != null) ...<Widget>[
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      caption!,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: fgSoft,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (bar != null) ...<Widget>[const SizedBox(height: 10), bar],
        ],
      );
    }

    return DecoratedBox(
      key: const ValueKey<String>('reader_nav_progress_card'),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(glass ? 14 : (compact ? 20 : 28)),
        border: eink ? Border.all(color: cs.outline) : null,
      ),
      child: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(16, 12, 16, 12)
            : const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              content,
              if (footer != null && !compact) footer!,
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadoutChip extends StatelessWidget {
  const _ReadoutChip({required this.label, required this.glass});

  final String label;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: glass
          ? appleColorsOf(context).secondaryLabel
          : cs.onPrimaryContainer,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    if (glass) return Text(label, style: style);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.onPrimaryContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(label, style: style),
      ),
    );
  }
}

class _HeroCover extends StatelessWidget {
  const _HeroCover({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 52,
          height: 74,
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: 156,
            errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                ColoredBox(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                ),
          ),
        ),
      ),
    );
  }
}
