/// 商籁的 PV 式排版（folia `sonnetTypographyLayout.ts` / `sonnetTypographyRoles.ts` /
/// `sonnetShotFlowLayouts.ts` / `sonnetPosterBlocksLayout.ts` / `sonnetGlyphLayout.ts`）：
/// 每段先按角色（主角 / 副主角 / 陪衬）定字号并精确量框，再按镜头模板做流式摆放，摆不下就
/// 整体缩一档重排；最后把每段拆成逐字坐标与入场向量。坐标以镜头中心为原点。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';

enum SonnetSegmentRole { hero, semiHero, support, decoration }

bool isSonnetEmphasisRole(SonnetSegmentRole r) =>
    r == SonnetSegmentRole.hero || r == SonnetSegmentRole.semiHero;

/// 角色字重：强调 900，陪衬 700，镂空巨字 300。
int sonnetRoleFontWeight(SonnetSegmentRole role) {
  if (isSonnetEmphasisRole(role)) return 900;
  return role == SonnetSegmentRole.decoration ? 300 : 700;
}

FontWeight sonnetFontWeightOf(int w) =>
    FontWeight.values[((w ~/ 100) - 1).clamp(0, FontWeight.values.length - 1)];

int sonnetVisibleLength(SonnetSegment s) =>
    s.graphemes.where((SonnetGrapheme g) => g.char.trim().isNotEmpty).length;

double scoreSonnetHeroSegment(SonnetSegment s) {
  final double lengthScore = math.min(sonnetVisibleLength(s), 8) * 14.0;
  final double durationScore = math.min(2.5, math.max(0, s.end - s.start)) * 18;
  return lengthScore + durationScore;
}

int findSonnetHeroSegmentIndex(List<SonnetSegment> segments) {
  int best = segments.indexWhere((SonnetSegment s) => s.isWordLike);
  double bestScore = double.negativeInfinity;
  for (int i = 0; i < segments.length; i++) {
    final SonnetSegment s = segments[i];
    if (!s.isWordLike || sonnetVisibleLength(s) == 0) continue;
    final double score = scoreSonnetHeroSegment(s);
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return math.max(0, best);
}

/// 副主角：与主角隔开、有分量的词，放在主角倾向的另一侧；长句再补一个。
List<int> findSonnetSemiHeroSegmentIndices(
  List<SonnetSegment> segments,
  int heroIndex,
) {
  if (heroIndex < 0 || heroIndex >= segments.length) return const <int>[];
  final SonnetSegment hero = segments[heroIndex];
  final int wordLike = segments
      .where((SonnetSegment s) => s.isWordLike && sonnetVisibleLength(s) > 0)
      .length;
  if (wordLike < 4) return const <int>[];
  final double threshold = scoreSonnetHeroSegment(hero) * 0.35;
  final List<int> candidates = <int>[
    for (int i = 0; i < segments.length; i++)
      if (i != heroIndex &&
          segments[i].isWordLike &&
          sonnetVisibleLength(segments[i]) >= 2 &&
          (i - heroIndex).abs() >= 2 &&
          scoreSonnetHeroSegment(segments[i]) >= threshold)
        i,
  ];
  if (candidates.isEmpty) return const <int>[];
  int? bestOf(List<int> list) {
    int? best;
    for (final int i in list) {
      if (best == null ||
          scoreSonnetHeroSegment(segments[i]) >
              scoreSonnetHeroSegment(segments[best])) {
        best = i;
      }
    }
    return best;
  }

  final bool leansEarly = heroIndex <= (segments.length - 1) / 2;
  final List<int> primarySide = candidates
      .where((int i) => leansEarly ? i > heroIndex : i < heroIndex)
      .toList();
  final List<int> secondarySide = candidates
      .where((int i) => leansEarly ? i < heroIndex : i > heroIndex)
      .toList();
  final List<int> picks = <int>[];
  final int? primary = bestOf(primarySide) ?? bestOf(secondarySide);
  if (primary != null) picks.add(primary);
  if (wordLike >= 9 && primary != null) {
    final int? secondary = bestOf(
      secondarySide.where((int i) => (i - primary).abs() >= 2).toList(),
    );
    if (secondary != null) picks.add(secondary);
  }
  picks.sort();
  return picks;
}

/// 文字测宽（TextPainter，跨场景共享缓存，FIFO 上限 20000）。
class SonnetTextMeasurer {
  SonnetTextMeasurer({this.fontFamily, this.fontFamilyFallback});

  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final LinkedHashMap<String, double> _cache = LinkedHashMap<String, double>();

  TextStyle styleFor(int weight, double size) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: size,
    fontWeight: sonnetFontWeightOf(weight),
    height: 1.0,
  );

  double measure(String text, int weight, double size) {
    final String key = '$weight|${size.toStringAsFixed(2)}|$text';
    final double? cached = _cache[key];
    if (cached != null) return cached;
    final TextPainter p = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: styleFor(weight, size),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double w = p.maxIntrinsicWidth;
    p.dispose();
    if (_cache.length >= 20000) _cache.remove(_cache.keys.first);
    _cache[key] = w;
    return w;
  }
}

/// 一段的最终摆放（folia `SonnetTypographyPlacement`）。
class SonnetPlacement {
  SonnetPlacement({
    required this.segmentIndex,
    required this.displayText,
    required this.isHero,
    required this.isSemiHero,
    required this.fontScale,
    required this.measuredWidth,
    required this.measuredHeight,
    required this.vertical,
    required this.rotation,
    required this.timingPhase,
    this.role,
    this.verticalDisplayText,
    this.verticalMeasuredWidth,
    this.verticalMeasuredHeight,
    this.verticalFontScale,
  });

  final int segmentIndex;
  String displayText;
  bool isHero;
  final bool isSemiHero;
  double fontScale;
  double measuredWidth;
  double measuredHeight;
  bool vertical;
  bool layoutVertical = false;
  double rotation;
  final double timingPhase;
  SonnetSegmentRole? role;
  final String? verticalDisplayText;
  final double? verticalMeasuredWidth;
  final double? verticalMeasuredHeight;
  final double? verticalFontScale;
  double x = 0;
  double y = 0;
  double enterX = 0;
  double enterY = 0;

  SonnetSegmentRole get resolvedRole =>
      role ??
      (isHero
          ? SonnetSegmentRole.hero
          : isSemiHero
          ? SonnetSegmentRole.semiHero
          : SonnetSegmentRole.support);

  SonnetPlacement copyAsDecoration() => SonnetPlacement(
    segmentIndex: segmentIndex,
    displayText: displayText,
    isHero: false,
    isSemiHero: isSemiHero,
    fontScale: fontScale,
    measuredWidth: measuredWidth,
    measuredHeight: measuredHeight,
    vertical: false,
    rotation: rotation,
    timingPhase: timingPhase,
    role: SonnetSegmentRole.decoration,
  )..layoutVertical = layoutVertical;
}

final RegExp _cjkRe = RegExp(r'[一-鿿぀-ヿ가-힯]');

String _verticalText(SonnetSegment s) =>
    (s.graphemes.isNotEmpty
            ? s.graphemes.map((SonnetGrapheme g) => g.char)
            : s.text.split(''))
        .join('\n');

List<String> _columnChars(SonnetSegment s) => s.graphemes.isNotEmpty
    ? <String>[for (final SonnetGrapheme g in s.graphemes) g.char]
    : s.text.split('');

/// 整段排版（folia `resolveSonnetTypographyLayout`）。
List<SonnetPlacement> resolveSonnetTypographyLayout({
  required List<List<SonnetSegment>> lines,
  required SonnetShotKind shotKind,
  required double width,
  required double height,
  required double baseFontSize,
  required SonnetTextMeasurer measurer,
}) {
  final List<SonnetSegment> segments = <SonnetSegment>[
    for (final List<SonnetSegment> l in lines) ...l,
  ];
  if (segments.isEmpty) return <SonnetPlacement>[];
  int offset = 0;
  final List<int> heroIndices = <int>[];
  final List<int> semiIndices = <int>[];
  for (final List<SonnetSegment> l in lines) {
    final int localHero = findSonnetHeroSegmentIndex(l);
    heroIndices.add(offset + localHero);
    for (final int s in findSonnetSemiHeroSegmentIndices(l, localHero)) {
      semiIndices.add(offset + s);
    }
    offset += l.length;
  }
  final int heroIndex = findSonnetHeroSegmentIndex(segments);
  final List<double> mids = <double>[
    for (final SonnetSegment s in segments) (s.start + s.end) / 2,
  ];
  final double tStart = mids.reduce(math.min);
  final double tEnd = mids.reduce(math.max);
  final double tDur = tEnd - tStart;
  final List<double> phases = <double>[
    for (int i = 0; i < segments.length; i++)
      tDur > 0.001
          ? (mids[i] - tStart) / tDur
          : i / math.max(1, segments.length - 1),
  ];

  final int variantSeed =
      segments.fold<int>(
        0,
        (int acc, SonnetSegment s) =>
            acc + (s.text.trim().isNotEmpty ? s.text.trim().length : 1),
      ) +
      segments.length;
  final int posterSeed = hashSonnetSeed(
    segments.map((SonnetSegment s) => s.text).join('␟'),
  );
  int editorialVariant = variantSeed % 5;
  final int ribbonVariant = variantSeed % 3;
  final int tableauVariant = variantSeed % 4;
  final int collageVariant = variantSeed % 3;

  int secondaryHero = -1;
  if (editorialVariant == 3 && segments.length > 2) {
    double bestScore = double.negativeInfinity;
    for (int i = 0; i < segments.length; i++) {
      final SonnetSegment s = segments[i];
      if (i == heroIndex || !s.isWordLike || sonnetVisibleLength(s) == 0) {
        continue;
      }
      final double score =
          scoreSonnetHeroSegment(s) + ((i - heroIndex).abs() > 1 ? 50 : 0);
      if (score > bestScore) {
        bestScore = score;
        secondaryHero = i;
      }
    }
    if (secondaryHero == -1) editorialVariant = 0;
  } else if (editorialVariant == 3) {
    editorialVariant = 0;
  } else if (editorialVariant == 4 && segments.length < 2) {
    editorialVariant = 2;
  }

  final double maxW = width * 0.82;
  final double maxH = height * 0.82;
  final List<SonnetPlacement> boxes = <SonnetPlacement>[];
  for (int index = 0; index < segments.length; index++) {
    final SonnetSegment segment = segments[index];
    final bool isHero =
        heroIndices.contains(index) ||
        (index == secondaryHero &&
            shotKind == SonnetShotKind.editorialColumn &&
            editorialVariant == 3);
    final bool isSemi = semiIndices.contains(index) && !isHero;
    final bool emphasized = isHero || isSemi;
    double heroScale;
    double supportScale;
    bool vertical = false;
    double rotation = 0;
    switch (shotKind) {
      case SonnetShotKind.editorialColumn:
        if (editorialVariant == 3) {
          heroScale = 3.8;
          supportScale = 1.3;
        } else if (editorialVariant == 4) {
          heroScale = 4.2;
          supportScale = 1.25;
          vertical = emphasized;
        } else {
          heroScale = editorialVariant == 2 ? 3.2 : 4.0;
          supportScale = 1.2;
          vertical = emphasized && editorialVariant != 2;
        }
      case SonnetShotKind.typeImpact:
        heroScale = 5.5;
        supportScale = 1.5;
      case SonnetShotKind.fragmentCollage:
        heroScale = 3.2;
        supportScale = 1.35;
        vertical = isSemi || index % 4 == 0;
      case SonnetShotKind.trackingRibbon:
        heroScale = 3.5;
        supportScale = 1.5;
      case SonnetShotKind.maskReveal:
        heroScale = 4.5;
        supportScale = 1.6;
        vertical = emphasized;
      case SonnetShotKind.posterBlocks:
        heroScale = 4.4;
        supportScale = 1.15;
      case SonnetShotKind.quietTableau:
        heroScale = 3.0;
        supportScale = 1.15;
        vertical = emphasized && (tableauVariant == 0 || tableauVariant == 1);
    }
    double fontScale = isHero
        ? heroScale
        : isSemi
        ? math.max(supportScale * 1.35, heroScale * 0.72)
        : supportScale;
    // 竖排构图里的非 CJK 多字母词：整块转 90°，量框也按转后的尺寸。
    final bool rotatesNonCjk =
        vertical &&
        segment.graphemes
                .where((SonnetGrapheme g) => g.char.trim().isNotEmpty)
                .length >
            1 &&
        !_cjkRe.hasMatch(segment.text);
    if (rotatesNonCjk) {
      vertical = false;
      rotation += math.pi / 2;
    }
    final String displayText = vertical ? _verticalText(segment) : segment.text;
    final SonnetSegmentRole role = isHero
        ? SonnetSegmentRole.hero
        : isSemi
        ? SonnetSegmentRole.semiHero
        : SonnetSegmentRole.support;
    final int weight = sonnetRoleFontWeight(role);
    double size = baseFontSize * fontScale;
    double advance(String ch) =>
        math.max(size * 0.2, measurer.measure(ch, weight, size));
    final double horizontalAdvance = rotatesNonCjk
        ? segment.graphemes.fold<double>(
            0,
            (double sum, SonnetGrapheme g) =>
                g.char.trim().isNotEmpty ? sum + advance(g.char) : sum,
          )
        : measurer.measure(displayText, weight, size);
    double mw = rotatesNonCjk ? size * 1.2 : horizontalAdvance;
    double mh = rotatesNonCjk ? horizontalAdvance : size * 1.2;
    if (vertical) {
      final List<String> chars = _columnChars(segment);
      final List<double> adv = <double>[
        for (final String c in chars)
          if (c.trim().isNotEmpty) advance(c),
      ];
      mw = adv.isEmpty ? size : adv.reduce(math.max);
      mh = math.max(1, chars.length) * size * 0.9;
    }
    double fit = 1;
    if (mw > maxW) fit = math.min(fit, maxW / mw);
    if (mh > maxH) fit = math.min(fit, maxH / mh);
    if (fit < 1) {
      size *= fit;
      fontScale *= fit;
      mw *= fit;
      mh *= fit;
    }
    String? pvText;
    double? pvW;
    double? pvH;
    double? pvScale;
    if (shotKind == SonnetShotKind.posterBlocks &&
        _cjkRe.hasMatch(segment.text)) {
      final List<String> chars = _columnChars(segment);
      final List<double> adv = <double>[
        for (final String c in chars)
          if (c.trim().isNotEmpty) advance(c),
      ];
      double cw = adv.isEmpty ? size : adv.reduce(math.max);
      double ch = math.max(1, chars.length) * size * 0.9;
      final double vf = math.min(1, math.min(maxW / cw, maxH / ch));
      cw *= vf;
      ch *= vf;
      pvText = _verticalText(segment);
      pvW = cw;
      pvH = ch;
      pvScale = fontScale * vf;
    }
    boxes.add(
      SonnetPlacement(
        segmentIndex: index,
        displayText: displayText,
        isHero: isHero,
        isSemiHero: isSemi,
        fontScale: fontScale,
        measuredWidth: mw,
        measuredHeight: mh,
        vertical: vertical,
        rotation: rotation,
        timingPhase: phases[index],
        verticalDisplayText: pvText,
        verticalMeasuredWidth: pvW,
        verticalMeasuredHeight: pvH,
        verticalFontScale: pvScale,
      ),
    );
  }

  final SonnetPlacement hero = boxes[heroIndex.clamp(0, boxes.length - 1)];
  if (shotKind == SonnetShotKind.posterBlocks) {
    layoutSonnetPosterBlocks(boxes, width, height, baseFontSize, posterSeed);
  } else {
    final _FlowCtx ctx = _FlowCtx(
      boxes,
      heroIndex.clamp(0, boxes.length - 1),
      width,
      height,
      baseFontSize,
    );
    switch (shotKind) {
      case SonnetShotKind.quietTableau:
        _layoutQuietTableau(ctx, tableauVariant);
      case SonnetShotKind.trackingRibbon:
        _layoutTrackingRibbon(ctx, ribbonVariant);
      case SonnetShotKind.editorialColumn:
        _layoutEditorialColumn(ctx, editorialVariant, secondaryHero);
      case SonnetShotKind.fragmentCollage:
        _layoutFragmentCollage(ctx, collageVariant);
      case SonnetShotKind.typeImpact:
      case SonnetShotKind.maskReveal:
      case SonnetShotKind.posterBlocks:
        _layoutCrossStack(ctx);
    }
  }
  hero.enterX = 0;
  hero.enterY = height * 0.15;

  // 镂空巨字：每个主角复制一份放大到背景，再挑一个句首 / 句尾词做第二个。
  final List<SonnetPlacement> decorations = <SonnetPlacement>[];
  if (shotKind != SonnetShotKind.quietTableau &&
      shotKind != SonnetShotKind.posterBlocks) {
    final List<SonnetPlacement> heroes = boxes
        .where((SonnetPlacement b) => b.isHero)
        .toList();
    for (int idx = 0; idx < heroes.length; idx++) {
      final SonnetPlacement h = heroes[idx];
      decorations.add(
        h.copyAsDecoration()
          ..fontScale = math.max(2.8, math.min(h.fontScale * 3.5, 5.5))
          ..x = h.x - width * (0.1 - idx * 0.03)
          ..y = h.y - height * (0.05 - idx * 0.02)
          ..rotation = -0.15 + (idx.isEven ? 0 : 0.05)
          ..enterX = -width * 0.05
          ..enterY = -height * 0.05,
      );
    }
    if (boxes.length > 1 && heroes.isNotEmpty) {
      final SonnetPlacement d2 = boxes.last.isHero ? boxes.first : boxes.last;
      decorations.add(
        d2.copyAsDecoration()
          ..fontScale = math.max(
            1.8,
            math.min(heroes.first.fontScale * 2.2, 3.5),
          )
          ..x = heroes.first.x + width * 0.25
          ..y = heroes.first.y + height * 0.15
          ..rotation = 0.08
          ..enterX = width * 0.05
          ..enterY = height * 0.05,
      );
    }
  }
  return <SonnetPlacement>[...decorations, ...boxes];
}

// ---------------------------------------------------------------------------
// 流式摆放
// ---------------------------------------------------------------------------

class _FlowCtx {
  _FlowCtx(
    this.boxes,
    this.heroIndex,
    this.width,
    this.height,
    double baseFontSize,
  ) : flowGap = (baseFontSize * 0.35).clamp(16.0, 40.0),
      stackGap = math.max(24, (baseFontSize * 0.35).clamp(16.0, 40.0) * 1.35);

  final List<SonnetPlacement> boxes;
  final int heroIndex;
  final double width;
  final double height;
  final double flowGap;
  final double stackGap;

  SonnetPlacement get hero => boxes[heroIndex];
}

/// 整体缩放梯：每档所有角色一起缩，直到全部落在安全区内。
void _placeWithGlobalFit(
  _FlowCtx ctx,
  void Function(double globalScale) place,
) {
  final List<(double, double, double)> snap = <(double, double, double)>[
    for (final SonnetPlacement b in ctx.boxes)
      (b.fontScale, b.measuredWidth, b.measuredHeight),
  ];
  final double safeW = ctx.width * 0.48;
  final double safeH = ctx.height * 0.46;
  for (final double g in const <double>[1, 0.92, 0.84, 0.76, 0.68, 0.6, 0.52]) {
    for (int i = 0; i < ctx.boxes.length; i++) {
      ctx.boxes[i]
        ..fontScale = snap[i].$1 * g
        ..measuredWidth = snap[i].$2 * g
        ..measuredHeight = snap[i].$3 * g;
    }
    place(g);
    final bool fits = ctx.boxes.every(
      (SonnetPlacement b) =>
          b.x.abs() + b.measuredWidth / 2 <= safeW + 0.5 &&
          b.y.abs() + b.measuredHeight / 2 <= safeH + 0.5,
    );
    if (fits) return;
  }
}

void _layoutQuietTableau(_FlowCtx ctx, int variant) {
  final List<SonnetPlacement> boxes = ctx.boxes;
  final SonnetPlacement hero = ctx.hero;
  final bool card = variant == 2 || variant == 3;
  for (final SonnetPlacement b in boxes) {
    b.layoutVertical = !card;
  }
  final double safeH = ctx.height * 0.46;
  _placeWithGlobalFit(ctx, (_) {
    hero.x = 0;
    hero.y = card ? 0 : -ctx.height * 0.1;
    final double stagger = variant == 3 ? 70 : 0;
    final double columnStep =
        boxes.map((SonnetPlacement b) => b.measuredWidth).reduce(math.max) +
        ctx.stackGap +
        stagger;
    double xFor(SonnetPlacement b, int i) {
      if (variant == 1) {
        return hero.x - hero.measuredWidth / 2 + b.measuredWidth / 2;
      }
      if (variant == 3) return hero.x + (i.isEven ? 1 : -1) * 35;
      return hero.x;
    }

    void enter(SonnetPlacement b, bool before) {
      if (variant == 1) {
        b.enterX = before ? 20 : -20;
        b.enterY = 0;
      } else if (variant == 3) {
        b.enterX = b.x > hero.x ? 30 : -30;
        b.enterY = 0;
      } else {
        b.enterX = 0;
        b.enterY = before ? 20 : -20;
      }
    }

    int column = 0;
    double y = hero.y - hero.measuredHeight / 2 - ctx.stackGap;
    for (int i = ctx.heroIndex - 1; i >= 0; i--) {
      final SonnetPlacement b = boxes[i];
      if (y - b.measuredHeight < -safeH) {
        column++;
        y = safeH;
      }
      b.x = xFor(b, i) + column * columnStep;
      b.y = y - b.measuredHeight / 2;
      y -= b.measuredHeight + ctx.stackGap;
      enter(b, true);
    }
    column = 0;
    y = hero.y + hero.measuredHeight / 2 + ctx.stackGap;
    for (int i = ctx.heroIndex + 1; i < boxes.length; i++) {
      final SonnetPlacement b = boxes[i];
      if (y + b.measuredHeight > safeH) {
        column++;
        y = -safeH;
      }
      b.x = xFor(b, i) - column * columnStep;
      b.y = y + b.measuredHeight / 2;
      y += b.measuredHeight + ctx.stackGap;
      enter(b, false);
    }
  });
}

void _layoutTrackingRibbon(_FlowCtx ctx, int variant) {
  final List<SonnetPlacement> boxes = ctx.boxes;
  final SonnetPlacement hero = ctx.hero;
  for (final SonnetPlacement b in boxes) {
    b.layoutVertical = false;
  }
  _placeWithGlobalFit(ctx, (_) {
    hero.x = 0;
    hero.y = 0;
    double alignY(SonnetPlacement b, int i) => variant == 1
        ? hero.y + hero.measuredHeight / 2 - b.measuredHeight / 2
        : variant == 2
        ? hero.y - hero.measuredHeight / 2 + b.measuredHeight / 2
        : hero.y + (i.isEven ? 10 : -10);
    final double enter = variant == 2 ? 20 : 30;
    double x = hero.x - hero.measuredWidth / 2 - ctx.flowGap;
    for (int i = ctx.heroIndex - 1; i >= 0; i--) {
      final SonnetPlacement b = boxes[i];
      b.x = x - b.measuredWidth / 2;
      b.y = alignY(b, i);
      x -= b.measuredWidth + ctx.flowGap;
      b.enterX = enter;
      b.enterY = 0;
    }
    x = hero.x + hero.measuredWidth / 2 + ctx.flowGap;
    for (int i = ctx.heroIndex + 1; i < boxes.length; i++) {
      final SonnetPlacement b = boxes[i];
      b.x = x + b.measuredWidth / 2;
      b.y = alignY(b, i);
      x += b.measuredWidth + ctx.flowGap;
      b.enterX = -enter;
      b.enterY = 0;
    }
  });
}

void _layoutEditorialColumn(_FlowCtx ctx, int variant, int secondaryHero) {
  final List<SonnetPlacement> boxes = ctx.boxes;
  final SonnetPlacement hero = ctx.hero;
  final int heroIndex = ctx.heroIndex;
  final double w = ctx.width;
  final double h = ctx.height;
  final double flowGap = ctx.flowGap;
  final double stackGap = ctx.stackGap;
  if (variant == 0) {
    for (final SonnetPlacement b in boxes) {
      b.layoutVertical = true;
    }
    // 竖排传统：主角柱右侧放之前的词，左侧放之后的词。
    _placeWithGlobalFit(ctx, (_) {
      hero.x = -w * 0.15;
      hero.y = 0;
      double y = hero.y - hero.measuredHeight / 2 + stackGap * 0.5;
      for (int i = 0; i < heroIndex; i++) {
        final SonnetPlacement b = boxes[i];
        b.x = hero.x + hero.measuredWidth / 2 + flowGap + b.measuredWidth / 2;
        b.y = y + b.measuredHeight / 2;
        y += b.measuredHeight + stackGap;
        b.enterX = -20;
        b.enterY = 0;
      }
      y = hero.y - hero.measuredHeight / 2 + stackGap * 0.5;
      for (int i = heroIndex + 1; i < boxes.length; i++) {
        final SonnetPlacement b = boxes[i];
        b.x = hero.x - hero.measuredWidth / 2 - flowGap - b.measuredWidth / 2;
        b.y = y + b.measuredHeight / 2;
        y += b.measuredHeight + stackGap;
        b.enterX = 20;
        b.enterY = 0;
      }
    });
  } else if (variant == 1) {
    for (final SonnetPlacement b in boxes) {
      b.layoutVertical = true;
    }
    _placeWithGlobalFit(ctx, (_) {
      final double rightEdge = w * 0.28;
      final double safeH = h * 0.46;
      final double railStep =
          boxes.map((SonnetPlacement b) => b.measuredWidth).reduce(math.max) +
          stackGap;
      final double sumH = boxes.fold<double>(
        0,
        (double s, SonnetPlacement b) => s + b.measuredHeight,
      );
      final double totalHeight = sumH + stackGap * (boxes.length - 1);
      final bool single =
          sumH * 0.52 + stackGap * (boxes.length - 1) <= safeH * 2;
      if (single) {
        double y = -totalHeight / 2;
        for (final SonnetPlacement b in boxes) {
          b.x = rightEdge - b.measuredWidth / 2;
          b.y = y + b.measuredHeight / 2;
          y += b.measuredHeight + stackGap;
          b.enterX = 20;
          b.enterY = 0;
        }
        return;
      }
      int rail = 0;
      double y = -safeH;
      for (final SonnetPlacement b in boxes) {
        if (y + b.measuredHeight > safeH) {
          rail++;
          y = -safeH;
        }
        b.x = (rightEdge - rail * railStep) - b.measuredWidth / 2;
        b.y = y + b.measuredHeight / 2;
        y += b.measuredHeight + stackGap;
        b.enterX = 20;
        b.enterY = 0;
      }
    });
  } else if (variant == 2) {
    for (final SonnetPlacement b in boxes) {
      b.layoutVertical = false;
    }
    _placeWithGlobalFit(ctx, (_) {
      hero.x = 0;
      hero.y = -h * 0.25;
      final List<SonnetPlacement> before = boxes.sublist(0, heroIndex);
      final List<SonnetPlacement> after = boxes.sublist(heroIndex + 1);
      if (before.isNotEmpty) {
        final double kh = before
            .map((SonnetPlacement b) => b.measuredHeight)
            .reduce(math.max);
        final double kw =
            before.fold<double>(
              0,
              (double s, SonnetPlacement b) => s + b.measuredWidth,
            ) +
            flowGap * (before.length - 1);
        final double ky = hero.y - hero.measuredHeight / 2 - stackGap - kh / 2;
        double x = hero.x - kw / 2;
        for (final SonnetPlacement b in before) {
          b.x = x + b.measuredWidth / 2;
          b.y = ky;
          x += b.measuredWidth + flowGap;
          b.enterX = 0;
          b.enterY = -20;
        }
      }
      final double leftAnchor = hero.x - hero.measuredWidth * 0.25 - flowGap;
      final double rightAnchor = hero.x + hero.measuredWidth * 0.25 + flowGap;
      double y = hero.y + hero.measuredHeight / 2 + stackGap;
      for (int pair = 0; pair < after.length; pair += 2) {
        final SonnetPlacement left = after[pair];
        final SonnetPlacement? right = pair + 1 < after.length
            ? after[pair + 1]
            : null;
        final double rowH = math.max(
          left.measuredHeight,
          right?.measuredHeight ?? 0,
        );
        left.x = leftAnchor - left.measuredWidth / 2;
        left.y = y + left.measuredHeight / 2;
        left.enterX = -20;
        left.enterY = 0;
        if (right != null) {
          right.x = rightAnchor + right.measuredWidth / 2;
          right.y = y + right.measuredHeight / 2;
          right.enterX = 20;
          right.enterY = 0;
        }
        y += rowH + stackGap;
      }
    });
  } else if (variant == 3) {
    for (final SonnetPlacement b in boxes) {
      b.layoutVertical = false;
    }
    _placeWithGlobalFit(ctx, (_) {
      hero.x = 0;
      hero.y = 0;
      final int firstHero = math.min(heroIndex, secondaryHero);
      final List<SonnetPlacement> l1 = boxes.sublist(0, firstHero + 1);
      final List<SonnetPlacement> l2 = boxes.sublist(firstHero + 1);
      final double h1 = l1
          .map((SonnetPlacement b) => b.measuredHeight)
          .reduce(math.max);
      final double h2 = l2.isEmpty
          ? 0
          : l2.map((SonnetPlacement b) => b.measuredHeight).reduce(math.max);
      final double total = h1 + stackGap + h2;
      final double y1 = hero.y - total / 2 + h1 / 2;
      final double y2 = y1 + h1 / 2 + stackGap + h2 / 2;
      double layLine(List<SonnetPlacement> line, double ly, double ex) {
        final double lw =
            line.fold<double>(
              0,
              (double s, SonnetPlacement b) => s + b.measuredWidth,
            ) +
            flowGap * (line.length - 1);
        double x = -lw / 2;
        for (final SonnetPlacement b in line) {
          b.x = x + b.measuredWidth / 2;
          b.y = ly;
          x += b.measuredWidth + flowGap;
          b.enterX = ex;
          b.enterY = 0;
        }
        return lw;
      }

      final double w1 = layLine(l1, y1, 30);
      final double w2 = layLine(l2, y2, -30);
      final double off = math.max(w1, w2) * 0.12;
      for (final SonnetPlacement b in l1) {
        b.x -= off;
      }
      for (final SonnetPlacement b in l2) {
        b.x += off;
      }
    });
  } else {
    for (int i = 0; i < boxes.length; i++) {
      boxes[i].layoutVertical = i == heroIndex;
    }
    // 徽标：主角柱浮在一侧，之前的词整行排在上面，之后的词绕柱排，再在柱下整行续排。
    _placeWithGlobalFit(ctx, (_) {
      final bool heroOnRight = heroIndex == boxes.length - 1;
      final double blockLeft = -w * 0.40;
      final double blockRight = w * 0.40;
      double y = -h * 0.34;
      void flowWords(
        List<int> indices,
        (double, double) Function(double rowTop) region,
      ) {
        (double, double) r = region(y);
        double x = r.$1;
        double rowH = 0;
        for (final int index in indices) {
          final SonnetPlacement b = boxes[index];
          if (x > r.$1 && x + b.measuredWidth > r.$2) {
            y += rowH + stackGap;
            r = region(y);
            x = r.$1;
            rowH = 0;
          }
          b.x = x + b.measuredWidth / 2;
          b.y = y + b.measuredHeight / 2;
          b.enterX = heroOnRight ? -25 : 25;
          b.enterY = 0;
          x += b.measuredWidth + flowGap;
          rowH = math.max(rowH, b.measuredHeight);
        }
        if (indices.isNotEmpty) y += rowH;
      }

      flowWords(<int>[
        for (int i = 0; i < heroIndex; i++) i,
      ], (_) => (blockLeft, blockRight));
      y += stackGap;
      final double pillarLeft = heroOnRight
          ? blockRight - hero.measuredWidth
          : blockLeft;
      hero.x = pillarLeft + hero.measuredWidth / 2;
      hero.y = y + hero.measuredHeight / 2;
      final double pillarBottom = y + hero.measuredHeight + stackGap;
      final double besideLeft = heroOnRight
          ? blockLeft
          : pillarLeft + hero.measuredWidth + flowGap;
      final double besideRight = heroOnRight
          ? pillarLeft - flowGap
          : blockRight;
      flowWords(
        <int>[for (int i = heroIndex + 1; i < boxes.length; i++) i],
        (double top) => top < pillarBottom - 0.5
            ? (besideLeft, besideRight)
            : (blockLeft, blockRight),
      );
    });
  }
}

void _layoutFragmentCollage(_FlowCtx ctx, int variant) {
  final List<SonnetPlacement> boxes = ctx.boxes;
  final SonnetPlacement hero = ctx.hero;
  // 转过 90° 的非 CJK 块在拼贴里放平：先换回横向尺寸再进缩放梯。
  for (int i = 0; i < boxes.length; i++) {
    if (i == ctx.heroIndex) continue;
    final SonnetPlacement b = boxes[i];
    if ((b.rotation / (math.pi / 2)).round().abs() % 2 == 1) {
      final double w = b.measuredHeight;
      b.measuredHeight = b.measuredWidth;
      b.measuredWidth = w;
    }
    b.rotation = 0;
  }
  double separation(Rect a, Rect b) => math.max(
    math.max(a.left - b.right, b.left - a.right),
    math.max(a.top - b.bottom, b.top - a.bottom),
  );
  _placeWithGlobalFit(ctx, (double g) {
    hero.x = 0;
    hero.y = 0;
    final double baseRadius =
        math.sqrt(
              hero.measuredWidth * hero.measuredWidth +
                  hero.measuredHeight * hero.measuredHeight,
            ) /
            2 +
        ctx.stackGap;
    final int count = math.max(1, boxes.length - 1);
    const double squash = 0.65;
    final List<Rect> placed = <Rect>[
      Rect.fromCenter(
        center: Offset(hero.x, hero.y),
        width: hero.measuredWidth,
        height: hero.measuredHeight,
      ),
    ];
    double angle = math.pi / 4;
    int support = 0;
    for (int i = 0; i < boxes.length; i++) {
      if (i == ctx.heroIndex) continue;
      final SonnetPlacement b = boxes[i];
      double radius = baseRadius;
      if (variant == 1) {
        radius += (35 + (support / count) * 150) * g;
      } else if (variant == 2) {
        radius += (support.isOdd ? 140 : 50) * g;
      } else {
        radius += (45 + (support * 23) % 90) * g;
      }
      support++;
      double candidate = angle;
      Rect rect = Rect.zero;
      double resolved = radius;
      bool clear = false;
      for (int ring = 0; ring < 14 && !clear; ring++) {
        for (int attempt = 0; attempt < 400; attempt++) {
          rect = Rect.fromCenter(
            center: Offset(
              math.cos(candidate) * resolved,
              math.sin(candidate) * resolved * squash,
            ),
            width: b.measuredWidth,
            height: b.measuredHeight,
          );
          if (placed.every((Rect p) => separation(p, rect) >= ctx.flowGap)) {
            clear = true;
            break;
          }
          candidate += 0.07;
        }
        if (!clear) resolved += (36 + ring * 12) * g;
      }
      angle = candidate + 0.02;
      placed.add(rect);
      b.x = hero.x + math.cos(candidate) * resolved;
      b.y = hero.y + math.sin(candidate) * resolved * squash;
      b.layoutVertical = math.cos(candidate).abs() >= math.sin(candidate).abs();
      b.enterX = math.cos(candidate) * -60;
      b.enterY = math.sin(candidate) * -60;
    }
  });
}

void _layoutCrossStack(_FlowCtx ctx) {
  final List<SonnetPlacement> boxes = ctx.boxes;
  final SonnetPlacement hero = ctx.hero;
  final int heroIndex = ctx.heroIndex;
  final int topCount = heroIndex ~/ 2;
  final int afterCount = boxes.length - 1 - heroIndex;
  final int rightCount = (afterCount / 2).ceil();
  double fillColumn(List<SonnetPlacement> column) {
    if (column.isEmpty) return 0;
    final double available = math.max(
      0,
      ctx.height * 0.46 - hero.measuredHeight / 2 - ctx.stackGap,
    );
    if (available <= 0) return 0;
    final double gaps = ctx.stackGap * (column.length - 1);
    final double content = column.fold<double>(
      0,
      (double s, SonnetPlacement b) => s + b.measuredHeight,
    );
    final double target = available * 0.72;
    if (content + gaps < target) {
      final double boost = math.min(
        2.2,
        (target - gaps) / math.max(1, content),
      );
      for (final SonnetPlacement b in column) {
        final double capped = math.min(
          boost,
          (hero.fontScale * 0.6) / b.fontScale,
        );
        if (capped > 1.05) {
          b.fontScale *= capped;
          b.measuredWidth *= capped;
          b.measuredHeight *= capped;
        }
      }
    }
    if (column.length < 2) return 0;
    final double grown = column.fold<double>(
      0,
      (double s, SonnetPlacement b) => s + b.measuredHeight,
    );
    final double pitch = (available * 0.95 - grown) / (column.length - 1);
    return math.max(0, math.min(ctx.stackGap * 2, pitch - ctx.stackGap));
  }

  _placeWithGlobalFit(ctx, (_) {
    hero.x = 0;
    hero.y = 0;
    final double topStretch = fillColumn(boxes.sublist(0, topCount));
    final double bottomStretch = fillColumn(
      boxes.sublist(math.min(boxes.length, heroIndex + rightCount + 1)),
    );
    double x = hero.x - hero.measuredWidth / 2 - ctx.stackGap;
    for (int i = heroIndex - 1; i >= topCount; i--) {
      final SonnetPlacement b = boxes[i];
      b.layoutVertical = false;
      b.x = x - b.measuredWidth / 2;
      b.y = hero.y + (i.isEven ? 10 : -10);
      x -= b.measuredWidth + ctx.flowGap;
      b.enterX = -30;
      b.enterY = 0;
    }
    double y = hero.y - hero.measuredHeight / 2 - ctx.stackGap;
    for (int i = topCount - 1; i >= 0; i--) {
      final SonnetPlacement b = boxes[i];
      b.layoutVertical = true;
      b.x = hero.x + (i.isEven ? 15 : -15);
      b.y = y - b.measuredHeight / 2;
      y -= b.measuredHeight + ctx.stackGap + topStretch;
      b.enterX = 0;
      b.enterY = -30;
    }
    x = hero.x + hero.measuredWidth / 2 + ctx.stackGap;
    for (
      int i = heroIndex + 1;
      i <= heroIndex + rightCount && i < boxes.length;
      i++
    ) {
      final SonnetPlacement b = boxes[i];
      b.layoutVertical = false;
      b.x = x + b.measuredWidth / 2;
      b.y = hero.y + (i.isEven ? 10 : -10);
      x += b.measuredWidth + ctx.flowGap;
      b.enterX = 30;
      b.enterY = 0;
    }
    y = hero.y + hero.measuredHeight / 2 + ctx.stackGap;
    for (int i = heroIndex + rightCount + 1; i < boxes.length; i++) {
      final SonnetPlacement b = boxes[i];
      b.layoutVertical = true;
      b.x = hero.x + (i.isEven ? 15 : -15);
      b.y = y + b.measuredHeight / 2;
      y += b.measuredHeight + ctx.stackGap + bottomStretch;
      b.enterX = 0;
      b.enterY = 30;
    }
  });
}

// ---------------------------------------------------------------------------
// 海报分区（poster-blocks）
// ---------------------------------------------------------------------------

class _PosterPlacement {
  _PosterPlacement(
    this.box,
    this.u,
    this.v,
    this.uSize,
    this.vSize,
    this.scale,
    this.vertical,
  );

  final SonnetPlacement box;
  double u;
  double v;
  double uSize;
  double vSize;
  double scale;
  final bool vertical;
}

class _Chip {
  _Chip(this.box, this.useVertical, this.baseScale, this.uSize, this.vSize);

  final SonnetPlacement box;
  final bool useVertical;
  final double baseScale;
  final double uSize;
  final double vSize;
  double shrink = 1;
}

/// 强调词各占一块固定分区，陪衬词在分区之间按阅读顺序流式填满；竖排变体从右往左排列。
void layoutSonnetPosterBlocks(
  List<SonnetPlacement> boxes,
  double width,
  double height,
  double baseFontSize,
  int seed,
) {
  if (boxes.isEmpty) return;
  final double gap = (baseFontSize * 0.35).clamp(16.0, 40.0);
  final double chipGap = gap;
  final double lineGap = gap * 1.15;
  final Rect canvas = Rect.fromLTWH(
    -width * 0.42,
    -height * 0.40,
    width * 0.84,
    height * 0.80,
  );
  final bool horizontal = seed % 2 == 0;
  final double spaceU = horizontal ? canvas.width : canvas.height;
  final double spaceV = horizontal ? canvas.height : canvas.width;

  (List<_PosterPlacement>, double) attempt(double globalScale) {
    // 分区与陪衬组。
    final List<(SonnetPlacement?, List<SonnetPlacement>?)> items =
        <(SonnetPlacement?, List<SonnetPlacement>?)>[];
    List<SonnetPlacement> group = <SonnetPlacement>[];
    for (final SonnetPlacement b in boxes) {
      if (b.isHero || b.isSemiHero) {
        if (group.isNotEmpty) items.add((null, group));
        group = <SonnetPlacement>[];
        items.add((b, null));
      } else {
        group.add(b);
      }
    }
    if (group.isNotEmpty) items.add((null, group));
    final List<_PosterPlacement> placements = <_PosterPlacement>[];
    final List<(double, double)> floats = <(double, double)>[];
    double vCursor = 0;
    bool endSide = ((seed >> 1) & 1) == 1;
    (bool, double, double, double) measure(SonnetPlacement b) {
      final bool useV =
          !horizontal &&
          b.verticalMeasuredWidth != null &&
          b.verticalMeasuredHeight != null &&
          b.verticalFontScale != null;
      final double baseScale = useV ? b.verticalFontScale! : b.fontScale;
      final double w =
          (useV ? b.verticalMeasuredWidth! : b.measuredWidth) * globalScale;
      final double h =
          (useV ? b.verticalMeasuredHeight! : b.measuredHeight) * globalScale;
      return (useV, baseScale, w, h);
    }

    (double, double) flowSize(double w, double h) =>
        horizontal ? (w, h) : (h, w);
    void prune() => floats.removeWhere(((double, double) f) => f.$2 <= vCursor);

    for (int itemIndex = 0; itemIndex < items.length; itemIndex++) {
      final (SonnetPlacement? zone, List<SonnetPlacement>? grp) =
          items[itemIndex];
      prune();
      if (grp != null) {
        final double reserved = floats.fold<double>(
          0,
          (double s, (double, double) f) => s + f.$1,
        );
        final double capacity = math.max(chipGap * 2, spaceU - reserved);
        final double uStart = reserved;
        final List<_Chip> chips = <_Chip>[
          for (final SonnetPlacement b in grp)
            () {
              final (bool useV, double bs, double w, double h) = measure(b);
              final (double us, double vs) = flowSize(w, h);
              return _Chip(b, useV, bs, us, vs);
            }(),
        ];
        List<_Chip> line = <_Chip>[];
        double used = 0;
        void flush() {
          if (line.isEmpty) return;
          final double lineV = line
              .map((_Chip c) => c.vSize * c.shrink)
              .reduce(math.max);
          final double leftover = capacity - used;
          final double spread = line.length > 1 && leftover > 0
              ? math.min(leftover / (line.length - 1), chipGap * 2.5)
              : 0;
          double u = uStart;
          for (final _Chip c in line) {
            placements.add(
              _PosterPlacement(
                c.box,
                u,
                vCursor,
                c.uSize * c.shrink,
                c.vSize * c.shrink,
                c.baseScale * globalScale * c.shrink,
                c.useVertical,
              ),
            );
            u += c.uSize * c.shrink + chipGap + spread;
          }
          vCursor += lineV + lineGap;
          prune();
          line = <_Chip>[];
          used = 0;
        }

        for (final _Chip c in chips) {
          final double needed =
              used + (line.isNotEmpty ? chipGap : 0) + c.uSize;
          if (needed > capacity && line.isNotEmpty) flush();
          if (c.uSize > capacity) {
            c.shrink = math.max(0.5, capacity / c.uSize);
            used = 0;
            line.add(c);
            flush();
            continue;
          }
          used += (line.isNotEmpty ? chipGap : 0) + c.uSize;
          line.add(c);
        }
        flush();
        continue;
      }
      final SonnetPlacement z = zone!;
      for (final (double, double) f in floats) {
        vCursor = math.max(vCursor, f.$2);
      }
      vCursor = math.max(vCursor, 0);
      floats.clear();
      final (bool useV, double bs, double w, double h) = measure(z);
      final (double fu, double fv) = flowSize(w, h);
      final bool followed =
          itemIndex + 1 < items.length && items[itemIndex + 1].$2 != null;
      final double shrink = math.min(
        1,
        math.min((spaceU * (followed ? 0.62 : 0.9)) / fu, (spaceV * 0.66) / fv),
      );
      final double uSize = fu * shrink;
      final double vSize = fv * shrink;
      final double u = items.length == 1
          ? (spaceU - uSize) / 2
          : followed
          ? 0
          : endSide
          ? spaceU - uSize
          : 0;
      placements.add(
        _PosterPlacement(
          z,
          u,
          vCursor,
          uSize,
          vSize,
          bs * globalScale * shrink,
          useV,
        ),
      );
      if (followed) {
        floats.add((uSize + chipGap, vCursor + vSize + lineGap));
      } else {
        vCursor += vSize + lineGap;
        endSide = !endSide;
      }
    }
    final double vTotal = placements.fold<double>(
      0,
      (double m, _PosterPlacement p) => math.max(m, p.v + p.vSize),
    );
    return (placements, vTotal);
  }

  (List<_PosterPlacement>, double) result = attempt(1);
  for (final double g in const <double>[0.92, 0.84, 0.76, 0.68, 0.6, 0.52]) {
    if (result.$2 <= spaceV + 0.5) break;
    result = attempt(g);
  }
  if (result.$2 > spaceV) {
    final double fit = spaceV / result.$2;
    for (final _PosterPlacement p in result.$1) {
      p
        ..u *= fit
        ..v *= fit
        ..uSize *= fit
        ..vSize *= fit
        ..scale *= fit;
    }
    result = (result.$1, spaceV);
  }
  final double vShift = math.max(0, (spaceV - result.$2) / 2);
  for (final _PosterPlacement p in result.$1) {
    final double v = p.v + vShift;
    final Rect screen = horizontal
        ? Rect.fromLTWH(canvas.left + p.u, canvas.top + v, p.uSize, p.vSize)
        : Rect.fromLTWH(
            canvas.left + canvas.width - v - p.vSize,
            canvas.top + p.u,
            p.vSize,
            p.uSize,
          );
    final SonnetPlacement b = p.box
      ..fontScale = p.scale
      ..measuredWidth = screen.width
      ..measuredHeight = screen.height
      ..x = screen.center.dx
      ..y = screen.center.dy
      ..rotation = 0
      ..vertical = p.vertical
      ..layoutVertical = !horizontal;
    if (p.vertical && b.verticalDisplayText != null) {
      b.displayText = b.verticalDisplayText!;
    }
    if (horizontal) {
      b.enterX =
          (screen.center.dx < 0 ? -1 : 1) * math.min(28, baseFontSize * 0.45);
      b.enterY = math.min(18, baseFontSize * 0.25);
    } else {
      b.enterX = math.min(18, baseFontSize * 0.25);
      b.enterY =
          (screen.center.dy < 0 ? -1 : 1) * math.min(28, baseFontSize * 0.45);
    }
  }
}

// ---------------------------------------------------------------------------
// 逐字
// ---------------------------------------------------------------------------

class SonnetGlyphPlacement {
  const SonnetGlyphPlacement({
    required this.char,
    required this.baseX,
    required this.baseY,
    required this.enterX,
    required this.enterY,
    required this.entryRotation,
    required this.start,
    required this.settle,
  });

  final String char;
  final double baseX;
  final double baseY;
  final double enterX;
  final double enterY;
  final double entryRotation;
  final double start;
  final double settle;
}

/// 一段拆成逐字坐标：沿排版方向居中排开，再绕段的旋转转到镜头坐标；奇偶字错开入场。
List<SonnetGlyphPlacement> buildSonnetGlyphLayout(
  SonnetSegment segment,
  SonnetPlacement placement,
  double fontSize,
  double Function(String char) measureGlyph,
  double shotStart,
  double shotEnd,
) {
  final List<SonnetGrapheme> graphemes = segment.graphemes.isNotEmpty
      ? segment.graphemes
      : <SonnetGrapheme>[
          for (int i = 0; i < segment.text.length; i++)
            SonnetGrapheme(
              segment.text[i],
              segment.start +
                  (segment.end - segment.start) *
                      i /
                      math.max(1, segment.text.length),
              segment.start +
                  (segment.end - segment.start) *
                      (i + 1) /
                      math.max(1, segment.text.length),
            ),
        ];
  final List<double> advances = <double>[
    for (final SonnetGrapheme g in graphemes)
      placement.vertical
          ? fontSize * 0.9
          : math.max(fontSize * 0.2, measureGlyph(g.char)),
  ];
  final double total = advances.fold<double>(0, (double a, double b) => a + b);
  final double motion = resolveSonnetGlyphMotionDuration(shotStart, shotEnd);
  final double cosine = math.cos(placement.rotation);
  final double sine = math.sin(placement.rotation);
  double cursor = -total / 2;
  final bool emphasis = isSonnetEmphasisRole(placement.resolvedRole);
  return <SonnetGlyphPlacement>[
    for (int i = 0; i < graphemes.length; i++)
      () {
        final double adv = advances[i];
        final double lx = placement.vertical ? 0 : cursor + adv / 2;
        final double ly = placement.vertical ? cursor + adv / 2 : 0;
        cursor += adv;
        final double stagger = i.isEven ? -1 : 1;
        final double start = graphemes[i].start;
        return SonnetGlyphPlacement(
          char: graphemes[i].char,
          baseX: placement.x + lx * cosine - ly * sine,
          baseY: placement.y + lx * sine + ly * cosine,
          enterX:
              placement.enterX +
              (placement.vertical ? stagger * fontSize * 0.28 : 0),
          enterY:
              placement.enterY +
              (placement.vertical ? 0 : stagger * fontSize * 0.24),
          entryRotation: stagger * (emphasis ? 0.055 : 0.035),
          start: start,
          settle: math.max(start, start + motion),
        );
      }(),
  ];
}
