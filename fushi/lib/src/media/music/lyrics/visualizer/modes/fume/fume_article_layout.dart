/// 浮名的整篇排版（folia `fumeArticleLayout.ts` + `fumeTextMeasure.ts`）：把整首歌词排成一张
/// 多栏「报纸」，挑出几句大标题（hero），按目标高度试栏数与密度，取最接近的一版。
///
/// 量字走 [FumeTextMeasurer]（真实实现用 TextPainter；单测可换假的），排版本身是纯函数。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_timeline.dart';

/// 量字接口。
abstract class FumeTextMeasurer {
  /// 单行排开时每 1px 字号的宽度（宽度随字号线性增长，folia 也按此猜测）。
  double naturalWidthPerPx(String text, FumeVariant variant);

  /// 在 [width] 内按 [fontPx] 折行：每行的字形区间 [start, end)。
  List<(int, int)> wrap(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
    double width,
  );

  /// 单行内每个字形左缘的 x（长度 = 字形数 + 1，末项为整行宽）。
  List<double> glyphOffsets(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
  );

  /// 一行文字的绘制高度（段落盒高，用来把字竖直居中到行盒中线）。
  double paintHeight(FumeVariant variant, double fontPx);
}

/// 块里折出来的一行（folia `RenderLineSlice`）。
class FumeRenderLine {
  const FumeRenderLine({
    required this.start,
    required this.end,
    required this.graphemes,
    required this.glyphOffsets,
    required this.left,
    required this.top,
    required this.width,
  });

  /// 在块的字形序列里的 [start, end)。
  final int start;
  final int end;
  final List<String> graphemes;

  /// 每个字形左缘 x（长度 = 字形数 + 1）。
  final List<double> glyphOffsets;
  final double left;
  final double top;
  final double width;

  String get text => graphemes.join();

  /// 行内第 [local] 个字形左缘（越界夹到两端）。
  double offsetAt(int local) {
    if (local <= 0) return 0;
    if (local >= graphemes.length) return glyphOffsets.last;
    return glyphOffsets[local];
  }

  double advanceAt(int local) {
    if (local < 0 || local >= graphemes.length) return 0;
    return math.max(glyphOffsets[local + 1] - glyphOffsets[local], 0);
  }
}

/// 文章里的一块 = 一句歌词（folia `FumeBlock`）。
class FumeBlock {
  FumeBlock({
    required this.id,
    required this.line,
    required this.variant,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.fontPx,
    required this.lineHeight,
    required this.paintHeight,
    required this.renderLines,
  }) : rangeIndexByOffset = _rangeIndex(line),
       cjk = fumeIsCjk(line.text);

  final int id;
  final FumeLine line;
  final FumeVariant variant;
  final double x;
  final double y;
  final double width;
  final double height;
  final double fontPx;
  final double lineHeight;
  final double paintHeight;
  final List<FumeRenderLine> renderLines;

  /// 字形 → 所属词区间下标（-1 = 不属于任何词）。
  final List<int> rangeIndexByOffset;
  final bool cjk;

  bool get hero => variant == FumeVariant.hero;
  int get lineIndex => line.index;
  int get graphemeCount => line.graphemes.length;

  /// 行盒内的基线（folia 用 middle 基线：CJK 略偏下）。
  double get baselineOffset => lineHeight * (cjk ? 0.52 : 0.5);

  static List<int> _rangeIndex(FumeLine line) {
    final List<int> out = List<int>.filled(line.graphemes.length, -1);
    for (int r = 0; r < line.ranges.length; r++) {
      final FumeWordRange range = line.ranges[r];
      for (int o = range.start; o < range.end && o < out.length; o++) {
        out[o] = r;
      }
    }
    return out;
  }
}

/// 整篇文章。
class FumeArticle {
  FumeArticle({
    required this.width,
    required this.height,
    required this.columns,
    required this.gap,
    required this.paperBounds,
    required this.blocks,
  }) : chronological = (List<FumeBlock>.of(blocks)
         ..sort((FumeBlock a, FumeBlock b) => a.lineIndex - b.lineIndex)),
       blockByLine = <int, FumeBlock>{
         for (final FumeBlock b in blocks) b.lineIndex: b,
       };

  final double width;
  final double height;
  final int columns;
  final double gap;
  final Rect paperBounds;
  final List<FumeBlock> blocks;
  final List<FumeBlock> chronological;
  final Map<int, FumeBlock> blockByLine;

  double get firstRenderableStart =>
      chronological.isEmpty ? double.infinity : chronological.first.line.start;

  double get lastChronologicalRenderEnd => chronological.isEmpty
      ? double.negativeInfinity
      : chronological.last.line.renderEnd;
}

int fumeRenderableGraphemes(FumeLine line) =>
    line.graphemes.where((String g) => g.trim().isNotEmpty).length;

/// 自然挑出的大标题：不长的副歌句（≤22 字），或短句里每第 6 句、少量随机。
FumeVariant fumeNaturalVariant(FumeLine line, int index, int total) {
  final int count = fumeRenderableGraphemes(line);
  if (count == 0) return FumeVariant.body;
  if (line.isChorus && count <= 22) return FumeVariant.hero;
  final bool shortEnough = count >= 4 && count <= 28;
  final double centered = (index - total / 2).abs() / math.max(total, 1);
  final double random = fumeSeeded('${line.text}:$index');
  return shortEnough &&
          centered < 0.72 &&
          ((index + 1) % 6 == 0 || random > 0.965)
      ? FumeVariant.hero
      : FumeVariant.body;
}

/// 一句大标题都没挑中时，强行挑一句（居中、长度合适者优先）；已有则 -1。
int fumeFallbackHeroIndex(List<FumeLine> entries) {
  if (entries.isEmpty) return -1;
  for (int i = 0; i < entries.length; i++) {
    if (fumeNaturalVariant(entries[i], i, entries.length) == FumeVariant.hero) {
      return -1;
    }
  }
  int bestIndex = -1;
  double bestScore = double.negativeInfinity;
  for (int i = 0; i < entries.length; i++) {
    final FumeLine line = entries[i];
    final int count = fumeRenderableGraphemes(line);
    if (count == 0 || count > 36) continue;
    final double centered = (i - entries.length / 2).abs() / entries.length;
    final double lengthScore = count >= 6 && count <= 22
        ? 1
        : count <= 28
        ? 0.72
        : 0.36;
    final double chorusScore = line.isChorus ? 0.28 : 0;
    final double jitter = fumeSeeded('${line.text}:$i:fallback-hero') * 0.04;
    final double score =
        (1 - centered) * 0.62 + lengthScore * 0.34 + chorusScore + jitter;
    if (score > bestScore) {
      bestScore = score;
      bestIndex = i;
    }
  }
  if (bestIndex >= 0) return bestIndex;
  int shortest = -1;
  int shortestCount = 1 << 30;
  for (int i = 0; i < entries.length; i++) {
    final int count = fumeRenderableGraphemes(entries[i]);
    if (count > 0 && count < shortestCount) {
      shortestCount = count;
      shortest = i;
    }
  }
  return shortest;
}

/// 找能单行放下的最大字号（8 次二分）；放不下就退到最小字号并折行。
(double, int) fumeChooseFontPx({
  required FumeTextMeasurer measurer,
  required FumeLine line,
  required FumeVariant variant,
  required double width,
  required double fontScale,
  required double densityScale,
  required double heroScale,
  Map<String, int>? lineCountCache,
}) {
  final bool hero = variant == FumeVariant.hero;
  final double factor = fontScale * densityScale * (hero ? heroScale : 1);
  final double perPx = measurer.naturalWidthPerPx(line.text, variant);
  double low = hero ? 18 : 10;
  double high = hero ? 58 : 30;
  double? best;
  for (int i = 0; i < 8; i++) {
    final double mid = (low + high) / 2;
    final double candidate = mid * factor;
    if (perPx * candidate <= width) {
      best = candidate;
      low = mid;
    } else {
      high = mid;
    }
  }
  if (best != null) return (best, 1);
  final double fallback = (hero ? 18 : 10) * factor;
  final String key = '${variant.index}|$fallback|$width|${line.text}';
  final int count =
      lineCountCache?[key] ??
      math.max(
        1,
        measurer.wrap(line.graphemes, variant, fallback, width).length,
      );
  lineCountCache?[key] = count;
  return (fallback, count);
}

class _Attempt {
  _Attempt(this.height, this.blocks);

  final double height;
  final List<FumeBlock>? blocks;
}

class _Geometry {
  _Geometry(this.viewport, this.paperWidth);

  final Size viewport;
  final double paperWidth;

  double get horizontalMargin => math.max(viewport.width * 0.86, 280);
  double get verticalMargin => math.max(viewport.height * 0.82, 220);
}

/// 排一整篇。空歌词或零尺寸返回 null。
FumeArticle? buildFumeArticle({
  required List<FumeLine> lines,
  required Size viewport,
  required FumeTextMeasurer measurer,
  required double fontScale,
  required double heroScale,
  required String seedKey,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) return null;
  final List<(FumeLine, int)> entries = <(FumeLine, int)>[
    for (final FumeLine l in lines)
      if (l.text.trim().isNotEmpty) (l, l.index),
  ];
  if (entries.isEmpty) return null;

  final double paperWidth = fumeClamp(
    math.max(viewport.width * 1.95, viewport.width + 520),
    920,
    2400,
  );
  final double viewportHeight = math.max(viewport.height, 240);
  final int maxColumns = paperWidth >= 1120
      ? 4
      : paperWidth >= 760
      ? 3
      : paperWidth >= 500
      ? 2
      : 1;
  final double targetHeight = viewportHeight * 2.45;
  final _Geometry geo = _Geometry(viewport, paperWidth);
  final Map<String, int> lineCounts = <String, int>{};

  int? bestColumns;
  double bestDensity = 1;
  double bestGap = 0;
  double bestScore = double.infinity;

  // 试几种栏数与密度，取高度最接近目标的一版（「排出来的」，而不是一套固定配方）。
  for (int columns = maxColumns; columns >= 1; columns--) {
    double low = 0.82;
    double high = 1.42;
    final double gap = fumeClamp(
      (paperWidth *
              (columns >= 4
                  ? 0.0065
                  : columns == 3
                  ? 0.0085
                  : 0.0115))
          .roundToDouble(),
      6,
      14,
    );
    for (int iteration = 0; iteration < 8; iteration++) {
      final double density = (low + high) / 2;
      final _Attempt a = _attempt(
        entries: entries,
        geo: geo,
        measurer: measurer,
        fontScale: fontScale,
        heroScale: heroScale,
        columns: columns,
        gap: gap,
        density: density,
        seedKey: '$seedKey:$columns:$paperWidth',
        render: false,
        lineCounts: lineCounts,
      );
      final double coverage = (a.height - targetHeight).abs();
      final double overflow = a.height < targetHeight
          ? 0
          : (a.height - targetHeight) * 0.14;
      final double score = coverage + overflow;
      if (score < bestScore) {
        bestScore = score;
        bestColumns = columns;
        bestDensity = density;
        bestGap = gap;
      }
      if (a.height < targetHeight) {
        low = density;
      } else {
        high = density;
      }
    }
  }
  if (bestColumns == null) return null;
  final _Attempt result = _attempt(
    entries: entries,
    geo: geo,
    measurer: measurer,
    fontScale: fontScale,
    heroScale: heroScale,
    columns: bestColumns,
    gap: bestGap,
    density: bestDensity,
    seedKey: '$seedKey:$bestColumns:$paperWidth',
    render: true,
    lineCounts: lineCounts,
  );
  final double vm = geo.verticalMargin;
  final double hm = geo.horizontalMargin;
  return FumeArticle(
    width: paperWidth + hm * 2,
    height: result.height,
    columns: bestColumns,
    gap: bestGap,
    paperBounds: Rect.fromLTRB(
      hm,
      vm,
      hm + paperWidth,
      math.max(result.height - vm, vm),
    ),
    blocks: result.blocks!,
  );
}

_Attempt _attempt({
  required List<(FumeLine, int)> entries,
  required _Geometry geo,
  required FumeTextMeasurer measurer,
  required double fontScale,
  required double heroScale,
  required int columns,
  required double gap,
  required double density,
  required String seedKey,
  required bool render,
  required Map<String, int> lineCounts,
}) {
  final double paperWidth = geo.paperWidth;
  final double hm = geo.horizontalMargin;
  final double vm = geo.verticalMargin;
  final double columnWidth = (paperWidth - gap * (columns - 1)) / columns;
  // 摆放顺序按种子打乱：纸面像「排版」而不是严格按时间顺序往下写。
  final List<(FumeLine, int)> ordered = List<(FumeLine, int)>.of(entries)
    ..sort(((FumeLine, int) a, (FumeLine, int) b) {
      final double sa = fumeSeeded('$seedKey:${a.$2}:${a.$1.text}');
      final double sb = fumeSeeded('$seedKey:${b.$2}:${b.$1.text}');
      return sa.compareTo(sb);
    });
  final List<FumeLine> orderedLines = <FumeLine>[
    for (final (FumeLine l, int _) in ordered) l,
  ];
  final int forcedHero = fumeFallbackHeroIndex(orderedLines);
  final List<double> columnHeights = List<double>.filled(columns, vm);
  final List<FumeBlock>? blocks = render ? <FumeBlock>[] : null;
  int bodyTie = 0;
  int heroTie = 0;

  for (int bi = 0; bi < orderedLines.length; bi++) {
    final FumeLine line = orderedLines[bi];
    final FumeVariant variant = bi == forcedHero
        ? FumeVariant.hero
        : fumeNaturalVariant(line, bi, orderedLines.length);
    final bool hero = variant == FumeVariant.hero;
    final int heroSpan = hero ? math.min(columns, columns <= 1 ? 1 : 2) : 1;
    final double heroSpanWidth = heroSpan > 1
        ? columnWidth * heroSpan + gap * (heroSpan - 1)
        : paperWidth;
    final double blockWidth = hero
        ? heroSpan == 1
              ? paperWidth
              : columns == 2
              ? columnWidth * 1.5 + gap * 0.5
              : heroSpanWidth
        : columnWidth;
    final double innerWidth = math.max(blockWidth, 120);
    final (double fontPx, int lineCount) = fumeChooseFontPx(
      measurer: measurer,
      line: line,
      variant: variant,
      width: innerWidth,
      fontScale: fontScale,
      densityScale: density,
      heroScale: heroScale,
      lineCountCache: lineCounts,
    );
    final double lineHeight = (fontPx * (hero ? 1.02 : 1.06)).roundToDouble();
    final double blockGap = hero
        ? math.max((lineHeight * 0.2).roundToDouble(), 6)
        : math.max((lineHeight * 0.08).roundToDouble(), 2);
    final double blockHeight = lineCount * lineHeight;
    double x;
    double y;

    if (hero) {
      // 大标题在多栏里找最平的一段坑位。
      if (heroSpan == 1) {
        y = columnHeights.reduce(math.max);
        x = hm;
        columnHeights[0] = y + blockHeight + blockGap;
      } else {
        double bestHeight = double.infinity;
        List<int> starts = <int>[];
        for (int s = 0; s <= columns - heroSpan; s++) {
          double covered = 0;
          for (int c = s; c < s + heroSpan; c++) {
            covered = math.max(covered, columnHeights[c]);
          }
          if (covered < bestHeight) {
            bestHeight = covered;
            starts = <int>[s];
          } else if (covered == bestHeight) {
            starts.add(s);
          }
        }
        final int target = starts.isEmpty ? 0 : starts[heroTie % starts.length];
        heroTie++;
        y = bestHeight;
        x =
            hm +
            target * (columnWidth + gap) +
            math.max((heroSpanWidth - blockWidth) * 0.5, 0);
        for (int c = target; c < target + heroSpan; c++) {
          columnHeights[c] = y + blockHeight + blockGap;
        }
      }
    } else {
      // 正文落进当前最矮的一栏。
      double minHeight = columnHeights[0];
      final List<int> candidates = <int>[0];
      for (int c = 1; c < columns; c++) {
        final double h = columnHeights[c];
        if (h < minHeight) {
          minHeight = h;
          candidates
            ..clear()
            ..add(c);
        } else if (h == minHeight) {
          candidates.add(c);
        }
      }
      final int target = candidates[bodyTie % candidates.length];
      bodyTie++;
      x = hm + target * (columnWidth + gap);
      y = columnHeights[target];
      columnHeights[target] = y + blockHeight + blockGap;
    }

    if (blocks != null) {
      final List<(int, int)> ranges = lineCount <= 1
          ? <(int, int)>[(0, line.graphemes.length)]
          : measurer.wrap(line.graphemes, variant, fontPx, innerWidth);
      final List<FumeRenderLine> renderLines = <FumeRenderLine>[];
      for (int li = 0; li < ranges.length; li++) {
        final (int s, int e) = ranges[li];
        final List<String> g = line.graphemes.sublist(s, e);
        final List<double> offsets = measurer.glyphOffsets(g, variant, fontPx);
        // 行宽不算行尾空白（pre-wrap 的悬挂空白）。
        int visibleEnd = g.length;
        while (visibleEnd > 0 && g[visibleEnd - 1].trim().isEmpty) {
          visibleEnd--;
        }
        final double width = offsets[visibleEnd];
        renderLines.add(
          FumeRenderLine(
            start: s,
            end: e,
            graphemes: g,
            glyphOffsets: offsets,
            left: hero ? math.max((blockWidth - width) * 0.08, 0) : 0,
            top: li * lineHeight,
            width: width,
          ),
        );
      }
      blocks.add(
        FumeBlock(
          id: line.index,
          line: line,
          variant: variant,
          x: x,
          y: y,
          width: blockWidth,
          height: math.max(blockHeight, renderLines.length * lineHeight),
          fontPx: fontPx,
          lineHeight: lineHeight,
          paintHeight: measurer.paintHeight(variant, fontPx),
          renderLines: renderLines,
        ),
      );
    }
  }
  final double height = columnHeights.reduce(math.max) + vm;
  return _Attempt(height, blocks);
}

// ---------------------------------------------------------------------------
// TextPainter 量字
// ---------------------------------------------------------------------------

/// 主题的字重 / 字体（folia `resolveThemeFontWeight` / `resolveThemeFontStack`）；都为 null
/// = 样式默认。
@immutable
class FumeFont {
  const FumeFont({this.weight, this.family});

  static const FumeFont standard = FumeFont();

  final FontWeight? weight;
  final String? family;

  /// 排版缓存键的一部分。
  String get key => '${weight?.value ?? ''}/${family ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is FumeFont && other.weight == weight && other.family == family;

  @override
  int get hashCode => Object.hash(weight, family);
}

/// 两种块的字重（folia hero 780 / body 640）；主题给了字重时两种都用主题的。
FontWeight fumeFontWeight(FumeVariant v, [FumeFont font = FumeFont.standard]) =>
    font.weight ?? (v == FumeVariant.hero ? FontWeight.w800 : FontWeight.w600);

TextStyle fumeTextStyle(
  FumeVariant v,
  double fontPx, [
  FumeFont font = FumeFont.standard,
]) => TextStyle(
  fontSize: fontPx,
  fontWeight: fumeFontWeight(v, font),
  fontFamily: font.family,
);

/// 真实量字：TextPainter。一次排版用一个实例（带缓存），用完 [dispose]。
class FumeTextPainterMeasurer implements FumeTextMeasurer {
  FumeTextPainterMeasurer({
    this.textScaler = TextScaler.noScaling,
    this.font = FumeFont.standard,
  });

  final TextScaler textScaler;
  final FumeFont font;
  static const double _refPx = 100;
  final Map<String, double> _natural = <String, double>{};
  final Map<String, double> _heights = <String, double>{};

  TextPainter _painter(String text, FumeVariant v, double fontPx) =>
      TextPainter(
        text: TextSpan(text: text, style: fumeTextStyle(v, fontPx, font)),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      );

  @override
  double naturalWidthPerPx(String text, FumeVariant variant) =>
      _natural.putIfAbsent('${variant.index}|$text', () {
        final TextPainter p = _painter(text, variant, _refPx)..layout();
        final double w = p.width;
        p.dispose();
        return w / _refPx;
      });

  @override
  List<(int, int)> wrap(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
    double width,
  ) {
    if (graphemes.isEmpty) return const <(int, int)>[(0, 0)];
    final TextPainter p = _painter(graphemes.join(), variant, fontPx)
      ..layout(maxWidth: width);
    final List<LineMetrics> metrics = p.computeLineMetrics();
    final List<int> lineOf = List<int>.filled(graphemes.length, 0);
    int u16 = 0;
    int last = 0;
    for (int i = 0; i < graphemes.length; i++) {
      final int len = graphemes[i].length;
      final List<TextBox> boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: u16, extentOffset: u16 + len),
      );
      int line = last;
      if (boxes.isNotEmpty && graphemes[i].trim().isNotEmpty) {
        final double cy = (boxes.first.top + boxes.first.bottom) / 2;
        for (int m = 0; m < metrics.length; m++) {
          final LineMetrics lm = metrics[m];
          if (cy <= lm.baseline + lm.descent) {
            line = m;
            break;
          }
          line = m;
        }
      }
      // 行号只增不减（空白挂在前一行）。
      line = math.max(line, last);
      lineOf[i] = line;
      last = line;
      u16 += len;
    }
    p.dispose();
    final List<(int, int)> out = <(int, int)>[];
    int s = 0;
    for (int i = 1; i <= graphemes.length; i++) {
      if (i == graphemes.length || lineOf[i] != lineOf[s]) {
        out.add((s, i));
        s = i;
      }
    }
    return out;
  }

  @override
  List<double> glyphOffsets(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
  ) {
    final TextPainter p = _painter(graphemes.join(), variant, fontPx)..layout();
    final List<double> out = <double>[];
    int u16 = 0;
    for (final String g in graphemes) {
      out.add(p.getOffsetForCaret(TextPosition(offset: u16), Rect.zero).dx);
      u16 += g.length;
    }
    out.add(p.width);
    p.dispose();
    // 保证单调（个别字体的连字 / 组合字会让光标回退）。
    for (int i = 1; i < out.length; i++) {
      if (out[i] < out[i - 1]) out[i] = out[i - 1];
    }
    return out;
  }

  @override
  double paintHeight(FumeVariant variant, double fontPx) =>
      _heights.putIfAbsent('${variant.index}|$fontPx', () {
        final TextPainter p = _painter('Hg浮', variant, fontPx)..layout();
        final double h = p.height;
        p.dispose();
        return h;
      });
}

/// 排版缓存（folia `fumeLayoutCache`，留 4 份：换样式回来不必重排整首）。
class FumeArticleCache {
  FumeArticleCache._();

  static const int _limit = 4;
  static final Map<String, FumeArticle?> _cache = <String, FumeArticle?>{};

  static String keyOf({
    required List<FumeLine> lines,
    required Size viewport,
    required double fontScale,
    required double heroScale,
    required String seedKey,
    required double textScale,
    FumeFont font = FumeFont.standard,
  }) {
    int h = 2166136261;
    for (final FumeLine l in lines) {
      h ^= fumeHashString(
        '${l.start}:${l.end}:${l.text}:${l.ranges.length}:${l.index}:${l.isChorus ? 1 : 0}',
      );
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return <Object>[
      viewport.width.round(),
      viewport.height.round(),
      fontScale.toStringAsFixed(4),
      heroScale.toStringAsFixed(4),
      textScale.toStringAsFixed(4),
      seedKey,
      font.key,
      lines.length,
      h,
    ].join('|');
  }

  static FumeArticle? resolve(String key, FumeArticle? Function() build) {
    if (_cache.containsKey(key)) {
      final FumeArticle? hit = _cache.remove(key);
      _cache[key] = hit;
      return hit;
    }
    final FumeArticle? made = build();
    _cache[key] = made;
    while (_cache.length > _limit) {
      _cache.remove(_cache.keys.first);
    }
    return made;
  }

  @visibleForTesting
  static void clear() => _cache.clear();
}
