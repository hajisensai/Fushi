import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 「继续」区的并列取色卡（2026-11-01 用户从设计稿 `continue_card_styles.html`
/// 选定「5 · 封面取色卡」）：几张同样大小的卡并排、不分主次，每张卡的底色取自
/// 它自己的封面（[ColorScheme.fromImageProvider] 出的 secondaryContainer，明度由
/// 动态配色钉死，所以一排颜色不同但深浅一致），进度条与百分比用该书的 primary。
///
/// 卡宽卡在库页网格列上：每张占 [span] 格，左右缘落在格内封面外缘上
/// （[cellInset] 是格子自带的内边距），卡与卡之间的缝 = 两格封面之间的缝，
/// 整排与下方网格同一组竖线。放不下的往后横滑。
///
/// 墨水屏 / Apple 设计系统不取色，退回同一块中性卡面。
class FushiContinueCardRow extends StatelessWidget {
  const FushiContinueCardRow({
    required this.entries,
    required this.cellWidth,
    required this.cellInset,
    required this.columns,
    this.label,
    this.bleed = 0,
    this.fitHeight,
    this.fillWidth = false,
    this.rowKey = const ValueKey<String>('fushi-continue-card-row'),
    super.key,
  });

  /// 按最近阅读排好的条目（第一张就是最近读的）。
  final List<FushiContinueEntry> entries;

  /// 库页网格的格宽（含格内边距）。
  final double cellWidth;

  /// 格子自带的左右内边距（封面外缘离格边的距离）。
  final double cellInset;

  /// 库页网格列数。
  final int columns;

  /// 行上方的小节标题（「继续阅读」）；null = 不画。
  final String? label;

  /// 本组件外层的左右页边距：横滑行把视口向两侧各外扩这么多再裁切，卡片滑到
  /// 页边才被裁掉（不会画到导航栏上），首尾卡也有地方悬停放大；内容仍从原位置
  /// 起排，与下方网格对齐。
  final double bleed;

  /// 给定时整块就是这么高：按高度能排几行就排几行（横滑网格，竖向居中）——
  /// 视频首页放在剧照大卡旁边、与大卡等高时用。null = 单行、高度按卡高。
  final double? fitHeight;

  /// true：不对齐网格列，卡宽按「一排放得下几张就几张、正好铺满可见宽度」定
  /// （视频首页：旁边没有网格，卡宽卡在列上会出现一张卡里大片空）。
  final bool fillWidth;
  final Key rowKey;

  /// 卡上封面高。
  static const double coverHeight = 120;

  /// [fitHeight] 撑高卡片时封面最高长到这么高。
  static const double _maxCoverHeight = 168;

  /// 封面右边信息列至少留这么宽（两行标题 + 进度条读得下）。
  static const double _minInfoWidth = 180;

  /// 每张卡占几格：至少两格（窄到不足四列时占满整行），封面越宽（横版剧照）
  /// 占得越多，保证信息列不被挤窄；不超过列数。
  double get _widestAspect => entries.fold<double>(
    0,
    (double m, FushiContinueEntry e) =>
        m > e.coverAspectRatio ? m : e.coverAspectRatio,
  );

  /// 一张卡至少多宽：封面 + 内边距 + 信息列下限。
  double _minCardWidth(double cover, double pad) =>
      cover * _widestAspect + pad * 3 + _minInfoWidth;

  int _span(double pad, double gap) {
    if (columns < 4) return columns.clamp(1, 2);
    final double need = _minCardWidth(coverHeight, pad);
    int span = 2;
    while (span < columns && cellWidth * span - gap < need) {
      span++;
    }
    return span;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = cellInset * 2;
    final double pad = tokens.spacing.gap * 2;
    final double baseCardHeight = coverHeight + pad * 2;
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
                ? cover + pad * 2
                : math.max(cover + pad * 2, (fit - gap * (rows - 1)) / rows);
            double hoverInset(double w) =>
                w * (kFushiHoverLiftScale - 1) / 2 + 2;
            final double cardWidth;
            if (fillWidth) {
              final double need = _minCardWidth(cover, pad);
              final double room = c.maxWidth - hoverInset(need) * 2;
              final int perRow = math.max(
                1,
                ((room + gap) / (need + gap)).floor(),
              );
              cardWidth = (room - gap * (perRow - 1)) / perRow;
            } else {
              cardWidth = cellWidth * _span(pad, gap) - gap;
            }
            // 给定高度时卡片正好铺满 [fitHeight]（与旁边大卡上下齐平），悬停
            // 放大的上下余量改成把视口向上下外扩，不占版面高度。
            final double height = fit ?? cardHeight + headroom * 2;
            final double extend = fit == null ? 0 : headroom;
            final double vertical =
                (height - rows * cardHeight - (rows - 1) * gap) / 2 + extend;
            Widget card(int i) => FushiStaggeredEntrance(
              index: i,
              child: SizedBox(
                width: cardWidth,
                height: cardHeight,
                child: _TintedContinueCard(
                  entry: entries[i],
                  padding: pad,
                  coverHeight: cover,
                ),
              ),
            );
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

/// 一张取色卡：封面 | 两行标题 + 元信息 + 进度条与百分比。
class _TintedContinueCard extends StatefulWidget {
  const _TintedContinueCard({
    required this.entry,
    required this.padding,
    required this.coverHeight,
  });

  final FushiContinueEntry entry;
  final double padding;
  final double coverHeight;

  @override
  State<_TintedContinueCard> createState() => _TintedContinueCardState();
}

class _TintedContinueCardState extends State<_TintedContinueCard> {
  ColorScheme? _scheme;
  ImageProvider? _resolvedFor;
  Brightness? _resolvedBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_TintedContinueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = widget.entry.colorSource;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _resolvedFor && brightness == _resolvedBrightness) return;
    _resolvedFor = image;
    _resolvedBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    final ColorScheme? cached = coverColorSchemeCache.peek(image, brightness);
    if (cached != null) {
      _scheme = cached;
      return;
    }
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _resolvedFor != image) return;
      if (_resolvedBrightness != brightness) return;
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool plain = eink || isGlassDesign(context);
    final ColorScheme? s = plain ? null : _scheme;
    final FushiContinueEntry entry = widget.entry;

    final Color background = plain
        ? tokens.surfaces.group
        : (s?.secondaryContainer ?? fushiHeroBlockColor(cs));
    final Color foreground = s?.onSecondaryContainer ?? cs.onSurface;
    final Color accent = eink
        ? cs.onSurface
        : (s?.primary ?? tokens.surfaces.primary);
    final double? progress = entry.progress?.clamp(0.0, 1.0);

    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: foreground,
    );
    final TextStyle metaStyle = tokens.type.metadata.copyWith(
      color: foreground.withValues(alpha: 0.72),
    );

    Widget cover = entry.frameCover
        ? ShelfCoverFrame(flat: true, child: entry.cover)
        : entry.cover;
    final ShelfCoverMaterial? material = entry.material;
    if (material != null) {
      cover = ShelfCoverMaterialScope(material: material, child: cover);
    }
    final double coverHeight = widget.coverHeight;
    final double coverWidth = coverHeight * entry.coverAspectRatio;

    final List<String> meta = <String>[
      if (entry.subtitle case final String sub when sub.isNotEmpty) sub,
      ...entry.metaLines,
    ];

    final Widget body = Row(
      children: <Widget>[
        SizedBox(width: coverWidth, height: coverHeight, child: cover),
        SizedBox(width: widget.padding),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ShelfTitleOverflowTooltip(
                title: entry.title,
                style: titleStyle,
                maxLines: 2,
                child: Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              for (final String line in meta)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
              const Spacer(),
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
                      '${(progress * 100).round()}%',
                      style: tokens.type.metadata.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );

    return FushiHoverLift(
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
              padding: EdgeInsets.all(widget.padding),
              onTap: entry.onOpen,
              onLongPress: entry.onLongPress,
              onSecondaryTap: entry.onLongPress,
              child: child!,
            ),
        child: body,
      ),
    );
  }
}

/// 封面 → 动态配色的进程内缓存（同一张封面在书架来回切换不重复量化）。
final CoverColorSchemeCache coverColorSchemeCache = CoverColorSchemeCache();

/// 按（封面 provider，明暗）缓存 [ColorScheme.fromImageProvider] 的结果；失败记
/// null 不再重试。
class CoverColorSchemeCache {
  final Map<(ImageProvider, Brightness), ColorScheme?> _done =
      <(ImageProvider, Brightness), ColorScheme?>{};
  final Map<(ImageProvider, Brightness), Future<ColorScheme?>> _pending =
      <(ImageProvider, Brightness), Future<ColorScheme?>>{};

  /// 已算好的结果；没算过 / 算失败返回 null。
  ColorScheme? peek(ImageProvider image, Brightness brightness) =>
      _done[(image, brightness)];

  Future<ColorScheme?> resolve(ImageProvider image, Brightness brightness) {
    final (ImageProvider, Brightness) key = (image, brightness);
    if (_done.containsKey(key)) return Future<ColorScheme?>.value(_done[key]);
    return _pending[key] ??= () async {
      ColorScheme? scheme;
      try {
        scheme = await ColorScheme.fromImageProvider(
          provider: image,
          brightness: brightness,
        );
      } on Object {
        scheme = null;
      }
      _done[key] = scheme;
      _pending.remove(key);
      return scheme;
    }();
  }
}

/// 按封面取色（[coverColorSchemeCache]，与「继续」取色卡同一份）后交给
/// [builder]：没给图 / 还没算好 / 失败 / 墨水屏 / Apple 设计系统时传 null，调用方
/// 用自己的中性色。音乐「最近播放」格子等不走 [FushiContinueCardRow] 的卡用它。
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
