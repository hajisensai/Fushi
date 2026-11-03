import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' show Intl, NumberFormat;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/misc/icon_seed_color.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 「继续」区的并列取色卡（2026-11-01 用户从设计稿 `continue_card_styles.html`
/// 选定「5 · 封面取色卡」）：几张同样大小的卡并排、不分主次，每张卡的底色取自
/// 它自己的封面（封面种子色经 [buildFushiColorScheme] 出的 secondaryContainer，
/// 明度由动态配色钉死，所以一排颜色不同但深浅一致），进度条与百分比用该书的
/// primary。
///
/// 两种排法（互斥，各用各的具名构造）：
/// - [FushiContinueCardRow.grid]：卡宽卡在库页网格列上，每张占几格，左右缘落在
///   格内封面外缘上，整排与下方网格同一组竖线（书架 / 游戏库）。
/// - [FushiContinueCardRow.fill]：旁边没有网格，一排放得下几张就几张、正好铺满
///   可见宽度；可给 [fitHeight] 按高度排多行（视频首页大卡旁）。
///
/// 放不下的往后横滑。墨水屏 / Apple 设计系统不取色，退回同一块中性卡面。
class FushiContinueCardRow extends StatelessWidget {
  /// 网格对齐：[cellWidth] 是库页网格格宽（含格内边距），[cellInset] 是格子自带
  /// 的左右内边距（封面外缘离格边的距离），[columns] 是网格列数。
  const FushiContinueCardRow.grid({
    required this.entries,
    required double cellWidth,
    required double cellInset,
    required int columns,
    this.label,
    this.bleed = 0,
    this.rowKey = const ValueKey<String>('fushi-continue-card-row'),
    super.key,
  }) : _cellWidth = cellWidth,
       _columns = columns,
       gap = cellInset * 2,
       fitHeight = null;

  /// 铺满可见宽度：卡与卡之间隔 [gap]；[fitHeight] 给定时整块就是这么高。
  const FushiContinueCardRow.fill({
    required this.entries,
    required this.gap,
    this.fitHeight,
    this.label,
    this.bleed = 0,
    this.rowKey = const ValueKey<String>('fushi-continue-card-row'),
    super.key,
  }) : _cellWidth = null,
       _columns = null;

  /// 按最近阅读排好的条目（第一张就是最近读的）。
  final List<FushiContinueEntry> entries;

  /// 网格对齐时的格宽 / 列数；null = 铺满模式。
  final double? _cellWidth;
  final int? _columns;

  /// 卡与卡之间的缝（网格模式 = 两格封面之间的缝）。
  final double gap;

  /// 行上方的小节标题（「继续阅读」）；null = 不画。
  final String? label;

  /// 本组件外层的左右页边距：横滑行把视口向两侧各外扩这么多再裁切，卡片滑到
  /// 页边才被裁掉（不会画到导航栏上），首尾卡也有地方悬停放大；内容仍从原位置
  /// 起排，与下方网格对齐。
  final double bleed;

  /// 给定时整块就是这么高：按高度能排几行就排几行（横滑网格，竖向居中）——
  /// 视频首页放在剧照大卡旁边、与大卡等高时用。null = 单行、高度按卡高。
  final double? fitHeight;
  final Key rowKey;

  /// 卡上封面高。
  static const double coverHeight = 120;

  /// [fitHeight] 撑高卡片时封面最高长到这么高。
  static const double _maxCoverHeight = 168;

  /// 封面右边信息列至少留这么宽（两行标题 + 进度条读得下）。
  static const double _minInfoWidth = 180;

  double get _widestAspect => entries.fold<double>(
    0,
    (double m, FushiContinueEntry e) =>
        m > e.coverAspectRatio ? m : e.coverAspectRatio,
  );

  /// 一张卡至少多宽：封面 + 内边距 + 信息列下限。
  double _minCardWidth(double cover, double pad) =>
      cover * _widestAspect + pad * 3 + _minInfoWidth;

  /// 网格模式下每张卡占几格：至少两格（不足两列时一格），放不下最小卡宽就一直
  /// 扩，最多占满整行——封面越宽（横版剧照）占得越多，保证信息列不被挤窄。
  @visibleForTesting
  static int spanFor({
    required double cellWidth,
    required int columns,
    required double gap,
    required double minCardWidth,
  }) {
    int span = math.min(2, math.max(1, columns));
    while (span < columns && cellWidth * span - gap < minCardWidth) {
      span++;
    }
    return span;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double pad = tokens.spacing.gap * 2;
    final _CardTextStyles styles = _CardTextStyles.of(tokens, null);
    // 信息列最少要多高：两行标题 + 进度行（随系统字号放大），封面比它矮时卡片
    // 跟着长高，元信息行放不下的整行不画（[_WholeLinesColumn]）。
    final double infoMin = styles.minInfoHeight(
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );
    final double baseCardHeight = math.max(coverHeight, infoMin) + pad * 2;
    // 悬停放大的上下余量，免得抬起时被行裁掉。
    final double headroom = baseCardHeight * (kFushiHoverLiftScale - 1) / 2 + 4;
    final String? label = this.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (label != null)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Text(
              label,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double? fit = fitHeight;
            final int rows = fit == null
                ? 1
                : math.max(1, ((fit + gap) / (baseCardHeight + gap)).floor());
            // 给定高度时卡片撑高铺满（封面跟着放大，封顶 [_maxCoverHeight]），
            // 与旁边的大卡上下齐平。
            final double cover = fit == null
                ? coverHeight
                : (((fit - gap * (rows - 1)) / rows) - pad * 2).clamp(
                    coverHeight,
                    _maxCoverHeight,
                  );
            // 卡高恒铺满（封面封顶后在卡里竖向居中）。
            final double cardHeight = fit == null
                ? baseCardHeight
                : math.max(
                    math.max(cover, infoMin) + pad * 2,
                    (fit - gap * (rows - 1)) / rows,
                  );
            double hoverInset(double w) =>
                w * (kFushiHoverLiftScale - 1) / 2 + 2;
            final double cardWidth;
            final double? cellWidth = _cellWidth;
            final int? columns = _columns;
            if (cellWidth == null || columns == null) {
              final double need = _minCardWidth(cover, pad);
              final double room = c.maxWidth - hoverInset(need) * 2;
              final int perRow = math.max(
                1,
                ((room + gap) / (need + gap)).floor(),
              );
              cardWidth = (room - gap * (perRow - 1)) / perRow;
            } else {
              final int span = spanFor(
                cellWidth: cellWidth,
                columns: columns,
                gap: gap,
                minCardWidth: _minCardWidth(coverHeight, pad),
              );
              cardWidth = cellWidth * span - gap;
            }
            // 给定高度时卡片正好铺满 [fitHeight]（与旁边大卡上下齐平），悬停
            // 放大的上下余量改成把视口向上下外扩，不占版面高度。
            final double height = fit ?? cardHeight + headroom * 2;
            final double extend = fit == null ? 0 : headroom;
            final double vertical =
                (height - rows * cardHeight - (rows - 1) * gap) / 2 + extend;
            // State 跟着条目走（KeyedSubtree），不跟下标：「继续」行重排后第 0 格
            // 不会先带着上一本书的配色。
            Widget card(int i) {
              final FushiContinueEntry entry = entries[i];
              return KeyedSubtree(
                key: ValueKey<Key>(entry.key),
                child: FushiStaggeredEntrance(
                  index: i,
                  child: SizedBox(
                    width: cardWidth,
                    height: cardHeight,
                    child: _TintedContinueCard(
                      entry: entry,
                      padding: pad,
                      coverHeight: cover,
                    ),
                  ),
                ),
              );
            }

            // 首尾卡悬停放大的横向余量：外扩的 [bleed] 不够时在视口内补。
            final EdgeInsets padding = EdgeInsets.symmetric(
              horizontal: math.max(bleed, hoverInset(cardWidth)),
              vertical: math.max(0, vertical),
            );
            return SizedBox(
              key: rowKey,
              height: height,
              child: OverflowBox(
                minWidth: c.maxWidth + bleed * 2,
                maxWidth: c.maxWidth + bleed * 2,
                minHeight: height + extend * 2,
                maxHeight: height + extend * 2,
                child: SectionSwipeCascade(
                  child: HorizontalDragScrollable(
                    child: rows == 1
                        ? ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: desktopAwareScrollPhysics(),
                            padding: padding,
                            itemCount: entries.length,
                            separatorBuilder: (BuildContext _, int __) =>
                                SizedBox(width: gap),
                            itemBuilder: (BuildContext _, int i) => card(i),
                          )
                        : GridView.builder(
                            scrollDirection: Axis.horizontal,
                            physics: desktopAwareScrollPhysics(),
                            padding: padding,
                            itemCount: entries.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: rows,
                                  mainAxisSpacing: gap,
                                  crossAxisSpacing: gap,
                                  mainAxisExtent: cardWidth,
                                ),
                            itemBuilder: (BuildContext _, int i) => card(i),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 卡内三种文字样式（标题 / 元信息 / 进度百分比），量高与渲染共用一份。
class _CardTextStyles {
  const _CardTextStyles({
    required this.title,
    required this.meta,
    required this.progress,
  });

  factory _CardTextStyles.of(FushiDesignTokens tokens, Color? foreground) =>
      _CardTextStyles(
        title: tokens.type.listTitle.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: foreground,
        ),
        meta: tokens.type.metadata.copyWith(
          color: foreground?.withValues(alpha: 0.72),
        ),
        progress: tokens.type.metadata.copyWith(fontWeight: FontWeight.w700),
      );

  final TextStyle title;
  final TextStyle meta;
  final TextStyle progress;

  /// 信息列必须放下的高度：两行标题 + 进度行（按当前字号缩放实测）。
  double minInfoHeight(TextScaler scaler, TextDirection direction) {
    double measure(TextStyle style, int lines) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: List<String>.filled(lines, 'Hg').join('\n'),
          style: style,
        ),
        textScaler: scaler,
        textDirection: direction,
        maxLines: lines,
      )..layout();
      final double h = painter.height;
      painter.dispose();
      return h;
    }

    return measure(title, 2) + math.max(6, measure(progress, 1)) + 4;
  }
}

/// 一张取色卡：封面 | 两行标题 + 角标 / 元信息 + 进度条与百分比。配色经
/// [FushiCoverTint]（与音乐「最近播放」同一份缓存与取色）。
class _TintedContinueCard extends StatelessWidget {
  const _TintedContinueCard({
    required this.entry,
    required this.padding,
    required this.coverHeight,
  });

  final FushiContinueEntry entry;
  final double padding;
  final double coverHeight;

  String _percent(BuildContext context, double progress) {
    final String? label = entry.progressLabel;
    if (label != null) return label;
    final String locale = Intl.verifiedLocale(
      Localizations.maybeLocaleOf(context)?.toLanguageTag(),
      NumberFormat.localeExists,
      onFailure: (String _) => 'en',
    )!;
    return NumberFormat.percentPattern(locale).format(progress);
  }

  @override
  Widget build(BuildContext context) => FushiCoverTint(
    image: entry.colorSource,
    builder: (BuildContext context, ColorScheme? s) => _build(context, s),
  );

  Widget _build(BuildContext context, ColorScheme? s) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool plain = eink || isGlassDesign(context);

    final Color background = plain
        ? tokens.surfaces.group
        : (s?.secondaryContainer ?? fushiHeroBlockColor(cs));
    final Color foreground = s?.onSecondaryContainer ?? cs.onSurface;
    final Color accent = eink
        ? cs.onSurface
        : (s?.primary ?? tokens.surfaces.primary);
    final double? progress = entry.progress?.clamp(0.0, 1.0);
    final _CardTextStyles styles = _CardTextStyles.of(tokens, foreground);

    Widget cover = entry.frameCover
        ? ShelfCoverFrame(flat: true, child: entry.cover)
        : entry.cover;
    final ShelfCoverMaterial? material = entry.material;
    if (material != null) {
      cover = ShelfCoverMaterialScope(material: material, child: cover);
    }
    final double coverWidth = coverHeight * entry.coverAspectRatio;

    final List<String> meta = <String>[
      if (entry.subtitle case final String sub when sub.isNotEmpty) sub,
      ...entry.metaLines,
    ];
    final IconData? metaIcon = entry.metaIcon;
    final Widget? badge = entry.badge;

    Widget metaLine(int i) {
      final Widget text = Text(
        meta[i],
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: styles.meta,
      );
      if (i != 0 || metaIcon == null) return text;
      // 远端条目的云图标等：放在第一行元信息前，用强调色。
      return Row(
        children: <Widget>[
          Icon(metaIcon, size: styles.meta.fontSize, color: accent),
          const SizedBox(width: 4),
          Flexible(child: text),
        ],
      );
    }

    final Widget body = Row(
      children: <Widget>[
        SizedBox(width: coverWidth, height: coverHeight, child: cover),
        SizedBox(width: padding),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ShelfTitleOverflowTooltip(
                title: entry.title,
                style: styles.title,
                maxLines: 2,
                child: Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: styles.title,
                ),
              ),
              // 角标与元信息行：剩余高度放得下几行画几行，放不下的整行不画
              // （系统字号放大时不溢出、也不露半行）。
              Expanded(
                child: _WholeLinesColumn(
                  children: <Widget>[
                    if (badge != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: badge,
                      ),
                    for (int i = 0; i < meta.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: metaLine(i),
                      ),
                  ],
                ),
              ),
              if (progress != null)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FushiLinearProgressIndicator(
                        key: entry.progressKey,
                        value: progress,
                        minHeight: 6,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(3),
                        ),
                        color: accent,
                        backgroundColor: accent.withValues(alpha: 0.18),
                      ),
                    ),
                    SizedBox(width: tokens.spacing.gap * 1.5),
                    Text(
                      _percent(context, progress),
                      style: styles.progress.copyWith(color: accent),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );

    Widget card = FushiHoverLift(
      enabled: entry.onOpen != null,
      builder: (BuildContext context, bool _) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: background),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        builder: (BuildContext context, Color? color, Widget? child) =>
            FushiCard(
              key: entry.key,
              focusId: entry.focusId,
              color: color,
              borderRadius: plain ? null : FushiM3eShape.containerLargeRadius,
              padding: EdgeInsets.all(padding),
              onTap: entry.onOpen,
              onLongPress: entry.onLongPress,
              onSecondaryTap: entry.onLongPress,
              child: child!,
            ),
        child: body,
      ),
    );
    final String? semanticLabel = entry.semanticLabel;
    if (semanticLabel != null) {
      card = Semantics(container: true, label: semanticLabel, child: card);
    }
    return card;
  }
}

/// 竖排子项，只画完整放得下的那些（从上往下，第一个放不下的及其后都不画、不
/// 参与命中与语义）；高度 = 画出来的那些的总高。
class _WholeLinesColumn extends MultiChildRenderObjectWidget {
  const _WholeLinesColumn({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWholeLinesColumn();
}

class _WholeLinesParentData extends ContainerBoxParentData<RenderBox> {
  bool visible = false;
}

class _RenderWholeLinesColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _WholeLinesParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _WholeLinesParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WholeLinesParentData) {
      child.parentData = _WholeLinesParentData();
    }
  }

  Size _arrange(
    BoxConstraints constraints,
    Size Function(RenderBox child, BoxConstraints c) layoutChild, {
    bool commit = false,
  }) {
    final BoxConstraints childConstraints = BoxConstraints(
      maxWidth: constraints.maxWidth,
    );
    double y = 0;
    double width = 0;
    bool full = false;
    RenderBox? child = firstChild;
    while (child != null) {
      final _WholeLinesParentData pd =
          child.parentData! as _WholeLinesParentData;
      final Size s = layoutChild(child, childConstraints);
      final bool fits = !full && y + s.height <= constraints.maxHeight + 0.01;
      if (!fits) full = true;
      if (commit) {
        pd
          ..visible = fits
          ..offset = Offset(0, y);
      }
      if (fits) {
        y += s.height;
        width = math.max(width, s.width);
      }
      child = pd.nextSibling;
    }
    return constraints.constrain(Size(width, y));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _arrange(
    constraints,
    (RenderBox child, BoxConstraints c) => child.getDryLayout(c),
  );

  @override
  void performLayout() {
    size = _arrange(constraints, (RenderBox child, BoxConstraints c) {
      child.layout(c, parentUsesSize: true);
      return child.size;
    }, commit: true);
  }

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) {
    double h = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      h += child.getMaxIntrinsicHeight(width);
      child = childAfter(child);
    }
    return h;
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    double w = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      w = math.max(w, child.getMaxIntrinsicWidth(height));
      child = childAfter(child);
    }
    return w;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    RenderBox? child = firstChild;
    while (child != null) {
      final _WholeLinesParentData pd =
          child.parentData! as _WholeLinesParentData;
      if (pd.visible) context.paintChild(child, offset + pd.offset);
      child = pd.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    RenderBox? child = lastChild;
    while (child != null) {
      final RenderBox current = child;
      final _WholeLinesParentData pd =
          current.parentData! as _WholeLinesParentData;
      if (pd.visible &&
          result.addWithPaintOffset(
            offset: pd.offset,
            position: position,
            hitTest: (BoxHitTestResult r, Offset p) =>
                current.hitTest(r, position: p),
          )) {
        return true;
      }
      child = pd.previousSibling;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    RenderBox? child = firstChild;
    while (child != null) {
      final _WholeLinesParentData pd =
          child.parentData! as _WholeLinesParentData;
      if (pd.visible) visitor(child);
      child = pd.nextSibling;
    }
  }
}

/// 封面 → 种子色的进程内缓存（同一张封面在书架来回切换不重复量化）。
final CoverColorSchemeCache coverColorSchemeCache = CoverColorSchemeCache();

/// 按封面 provider 缓存取到的种子色，再按明暗经 [buildFushiColorScheme] 出配色
/// （与应用主题同一套派生：无彩度种子走 monochrome，不会被染成别的色相）。
///
/// 取色走 [extractImageProviderSeedArgb]：缩图后在后台 isolate 量化，透明像素
/// 不参与，全灰阶封面得到灰种子，没有可用像素（无封面的透明占位图）记 null，
/// 卡面退回中性色——不会落到 `Score` 的谷歌蓝兜底。加载失败也记 null 不再重试。
///
/// 已算好的结果按最近使用淘汰（LRU，上限 [capacity]）：书架 / 视频库条目多、
/// 封面 provider 会被反复新建时，缓存不随浏览量无限增长。正在算的请求不计入上限
/// （同一时刻在屏的卡片数量本身有限）。
class CoverColorSchemeCache {
  CoverColorSchemeCache({this.capacity = 256, this.extractSeed})
    : assert(capacity > 0);

  /// 最多保留多少个已算好的种子色。
  final int capacity;

  /// 取种子色的实现（测试注入）；null = [extractImageProviderSeedArgb]。
  final Future<int?> Function(ImageProvider image)? extractSeed;

  // Dart 默认 Map 是 LinkedHashMap：按插入顺序迭代，命中时删了重插即「最近使用」。
  final Map<ImageProvider, int?> _done = <ImageProvider, int?>{};
  final Map<ImageProvider, Future<int?>> _pending =
      <ImageProvider, Future<int?>>{};

  /// 当前缓存的已算好条目数（测试用）。
  @visibleForTesting
  int get length => _done.length;

  static ColorScheme? _schemeOf(int? seed, Brightness brightness) =>
      seed == null
      ? null
      : buildFushiColorScheme(seedColor: Color(seed), brightness: brightness);

  /// 已算好的配色；没算过 / 没有可用像素 / 算失败返回 null。
  ColorScheme? peek(ImageProvider image, Brightness brightness) {
    if (!_done.containsKey(image)) return null;
    return _schemeOf(_touch(image), brightness);
  }

  Future<ColorScheme?> resolve(
    ImageProvider image,
    Brightness brightness,
  ) async {
    if (_done.containsKey(image)) return _schemeOf(_touch(image), brightness);
    final int? seed = await (_pending[image] ??= _compute(image));
    return _schemeOf(seed, brightness);
  }

  Future<int?> _compute(ImageProvider image) async {
    int? seed;
    try {
      seed = await (extractSeed ?? extractImageProviderSeedArgb)(image);
    } on Object {
      seed = null;
    }
    _store(image, seed);
    _pending.remove(image);
    return seed;
  }

  /// 直接写入一条种子色（测试用；正常路径经 [resolve]）。
  @visibleForTesting
  void debugStoreSeed(ImageProvider image, int? seed) => _store(image, seed);

  int? _touch(ImageProvider key) {
    final int? seed = _done.remove(key);
    _done[key] = seed;
    return seed;
  }

  void _store(ImageProvider key, int? seed) {
    _done.remove(key);
    _done[key] = seed;
    while (_done.length > capacity) {
      _done.remove(_done.keys.first);
    }
  }
}

/// 按封面取色（[coverColorSchemeCache]，与「继续」取色卡同一份）后交给
/// [builder]：没给图 / 还没算好 / 无可用像素 / 失败 / 墨水屏 / Apple 设计系统时
/// 传 null，调用方用自己的中性色。「继续」取色卡与音乐「最近播放」格子都用它。
class FushiCoverTint extends StatefulWidget {
  const FushiCoverTint({required this.image, required this.builder, super.key});

  final ImageProvider? image;
  final Widget Function(BuildContext context, ColorScheme? scheme) builder;

  @override
  State<FushiCoverTint> createState() => _FushiCoverTintState();
}

class _FushiCoverTintState extends State<FushiCoverTint> {
  ColorScheme? _scheme;
  ImageProvider? _resolvedFor;
  Brightness? _resolvedBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(FushiCoverTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = widget.image;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _resolvedFor && brightness == _resolvedBrightness) return;
    _resolvedFor = image;
    _resolvedBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    // 换了封面：先清成缓存里的（没有就 null = 中性色），不留上一张的配色。
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _resolvedFor != image) return;
      if (_resolvedBrightness != brightness) return;
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool plain = isEinkTheme(context) || isGlassDesign(context);
    return widget.builder(context, plain ? null : _scheme);
  }
}
