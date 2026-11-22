/// 一个段落场景的构建（folia `sonnetSceneBuilder.ts` / `sonnetTextViewBuilder.ts`）：每个镜头
/// 排好版、拆好逐字、备好 MG / 装饰与文字画笔；播放时只按时间改姿态（见 `sonnet_painter.dart`）。
/// 场景只缓存当前段 ±1，换段时构建，尺寸 / 参数变化时整体重建。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_decor.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_graphics.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_mg.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_typography.dart';

/// 生效的参数（folia `SonnetTuning` 里在 Flutter 有意义的部分）。
@immutable
class SonnetSettings {
  const SonnetSettings({
    this.cameraIntensity = 1,
    this.typographyMotion = 1,
    this.mgDensity = 1,
    this.showOnlyText = false,
    this.showGuide = true,
    this.showBackgroundMg = true,
    this.showFixedGeo = true,
    this.showGiantDecorativeText = true,
    this.showBackgroundDecor = true,
    this.enableTransitions = true,
    this.outerFrameMode = 'full',
    this.postProcessEnabled = false,
    this.postProcessGrain = 0.2,
    this.postProcessContrast = 0,
    this.postProcessRgbShift = 0,
    this.postProcessHalftone = 0,
    this.postProcessVignette = 0.85,
    this.postProcessLensDistortion = 0.3,
    this.postProcessLensDispersion = 0.6,
  });

  final double cameraIntensity;
  final double typographyMotion;
  final double mgDensity;
  final bool showOnlyText;
  final bool showGuide;
  final bool showBackgroundMg;
  final bool showFixedGeo;
  final bool showGiantDecorativeText;
  final bool showBackgroundDecor;
  final bool enableTransitions;

  /// none / frame / full。
  final String outerFrameMode;
  final bool postProcessEnabled;
  final double postProcessGrain;
  final double postProcessContrast;
  final double postProcessRgbShift;
  final double postProcessHalftone;
  final double postProcessVignette;
  final double postProcessLensDistortion;
  final double postProcessLensDispersion;

  @override
  bool operator ==(Object other) =>
      other is SonnetSettings &&
      other.cameraIntensity == cameraIntensity &&
      other.typographyMotion == typographyMotion &&
      other.mgDensity == mgDensity &&
      other.showOnlyText == showOnlyText &&
      other.showGuide == showGuide &&
      other.showBackgroundMg == showBackgroundMg &&
      other.showFixedGeo == showFixedGeo &&
      other.showGiantDecorativeText == showGiantDecorativeText &&
      other.showBackgroundDecor == showBackgroundDecor &&
      other.enableTransitions == enableTransitions &&
      other.outerFrameMode == outerFrameMode &&
      other.postProcessEnabled == postProcessEnabled &&
      other.postProcessGrain == postProcessGrain &&
      other.postProcessContrast == postProcessContrast &&
      other.postProcessRgbShift == postProcessRgbShift &&
      other.postProcessHalftone == postProcessHalftone &&
      other.postProcessVignette == postProcessVignette &&
      other.postProcessLensDistortion == postProcessLensDistortion &&
      other.postProcessLensDispersion == postProcessLensDispersion;

  @override
  int get hashCode => Object.hashAll(<Object>[
    cameraIntensity,
    typographyMotion,
    mgDensity,
    showOnlyText,
    showGuide,
    showBackgroundMg,
    showFixedGeo,
    showGiantDecorativeText,
    showBackgroundDecor,
    enableTransitions,
    outerFrameMode,
    postProcessEnabled,
    postProcessGrain,
    postProcessContrast,
    postProcessRgbShift,
    postProcessHalftone,
    postProcessVignette,
    postProcessLensDistortion,
    postProcessLensDispersion,
  ]);
}

/// folia 主题色在 Fushi 调色板上的对应：字色 = primaryColor，其余照名。
@immutable
class SonnetColors {
  const SonnetColors({
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.background,
    this.keywords = const <String, Color>{},
  });

  final Color primary;
  final Color secondary;
  final Color accent;
  final Color background;

  /// 主题关键词着色（folia `theme.wordColors`），键已小写。
  final Map<String, Color> keywords;

  /// 片段整词命中关键词时的颜色（folia：`word.toLowerCase() === segment.text.toLowerCase()`）。
  Color? keywordColorOf(String text) =>
      keywords.isEmpty ? null : keywords[text.toLowerCase()];

  @override
  bool operator ==(Object other) =>
      other is SonnetColors &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.accent == accent &&
      mapEquals(other.keywords, keywords) &&
      other.background == background;

  @override
  int get hashCode => Object.hash(
    primary,
    secondary,
    accent,
    background,
    Object.hashAllUnordered(keywords.keys),
  );
}

/// 发光强度：颜色最亮通道 110→160 之间平滑升到 1（暗色不发光，folia `resolveGlowColorStrength`）。
double sonnetGlowStrength(Color c) {
  final double v = math.max(c.r, math.max(c.g, c.b)) * 255;
  final double p = ((v - 110) / 50).clamp(0.0, 1.0);
  return p * p * (3 - 2 * p);
}

class SonnetGhost {
  const SonnetGhost(this.dx, this.dy, this.alphaBase);

  final double dx;
  final double dy;
  final double alphaBase;
}

/// 一个字（或一块字后几何 / 五线谱）。
class SonnetGlyphView {
  SonnetGlyphView({
    required this.baseX,
    required this.baseY,
    required this.enterX,
    required this.enterY,
    required this.entryRotation,
    required this.finalRotation,
    required this.start,
    required this.settle,
    required this.zDepth,
    this.core,
    this.cyan,
    this.red,
    this.caOffset = 0,
    this.ghost,
    this.ghosts = const <SonnetGhost>[],
    this.ghostDuration = 0,
    this.bgShape,
    this.staff,
  });

  final double baseX;
  final double baseY;
  final double enterX;
  final double enterY;
  final double entryRotation;
  final double finalRotation;
  final double start;
  final double settle;
  final double zDepth;
  final TextPainter? core;
  final TextPainter? cyan;
  final TextPainter? red;
  final double caOffset;
  final TextPainter? ghost;
  final List<SonnetGhost> ghosts;
  final double ghostDuration;
  final SonnetTextFixedGeo? bgShape;
  final SonnetStaff? staff;

  bool get isBackgroundShape => bgShape != null;
  bool get isTextGlyph => core != null;
}

class SonnetSegmentView {
  SonnetSegmentView({
    required this.role,
    required this.glyphs,
    required this.trackingGlyphs,
    this.guide,
    this.frameDecor,
  });

  final SonnetSegmentRole role;
  final List<SonnetGlyphView> glyphs;
  final List<SonnetGlyphView> trackingGlyphs;
  final SonnetGuide? guide;
  final SonnetFrameDecor? frameDecor;
}

class SonnetShotView {
  SonnetShotView({
    required this.shot,
    required this.segments,
    required this.baseX,
    required this.baseY,
    required this.basePivotX,
    required this.basePivotY,
    required this.bg,
    required this.particles,
    this.geo,
    this.fixedGeo,
  });

  final SonnetShot shot;
  final List<SonnetSegmentView> segments;
  final double baseX;
  final double baseY;
  final double basePivotX;
  final double basePivotY;
  final SonnetAnimatedGraphics bg;
  final SonnetAnimatedGraphics? geo;
  final SonnetFixedGeo? fixedGeo;
  final List<SonnetParticle> particles;

  /// 图标随「歌词节拍」放大的平滑值（folia 按音频能量做的同一套 EMA）。
  double smoothedIconAudio = 0;

  // 镜头跟踪的段与焦点时间窗，第一帧算好后复用。
  List<SonnetSegmentView>? trackSegments;
  double revealDone = 0;
  List<(double, double)> focusRanges = const <(double, double)>[];

  void dispose() {
    bg.dispose();
    geo?.dispose();
    fixedGeo?.dispose();
  }
}

class SonnetBgLine {
  const SonnetBgLine(
    this.x,
    this.y,
    this.length,
    this.color,
    this.width,
    this.alpha,
  );

  final double x;
  final double y;
  final double length;
  final Color color;
  final double width;
  final double alpha;
}

class SonnetSceneView {
  SonnetSceneView({
    required this.paragraph,
    required this.shots,
    required this.bgLines,
    required this.drawBackdrop,
    required this.painters,
    this.metaTitle,
    this.metaDescription,
  });

  final SonnetParagraph paragraph;
  final List<SonnetShotView> shots;
  final List<SonnetBgLine> bgLines;
  final bool drawBackdrop;
  final List<TextPainter> painters;

  /// 「外层边框：完全显示」时左下竖排的曲名与右上的艺人 / 专辑（folia 是 AI 主题名与描述）。
  final TextPainter? metaTitle;
  final TextPainter? metaDescription;

  void dispose() {
    for (final SonnetShotView s in shots) {
      s.dispose();
    }
    for (final TextPainter p in painters) {
      p.dispose();
    }
  }
}

/// 构建所需的全部输入。
class SonnetSceneInputs {
  const SonnetSceneInputs({
    required this.program,
    required this.size,
    required this.settings,
    required this.colors,
    required this.measurer,
    required this.fontScale,
    required this.motion,
    this.title,
    this.artist,
    this.album,
  });

  final SonnetProgram program;
  final Size size;
  final SonnetSettings settings;
  final SonnetColors colors;
  final SonnetTextMeasurer measurer;
  final double fontScale;
  final bool motion;
  final String? title;
  final String? artist;
  final String? album;
}

/// 构建第 [index] 段的场景。
SonnetSceneView buildSonnetScene(SonnetSceneInputs inputs, int index) {
  final SonnetParagraph paragraph = inputs.program.paragraphs[index];
  final double width = math.max(inputs.size.width, 320);
  final double height = math.max(inputs.size.height, 240);
  final SonnetSettings s = inputs.settings;
  final SonnetColors colors = inputs.colors;
  final bool onlyText = s.showOnlyText;
  final bool showBackgroundMg = !onlyText && s.showBackgroundMg;
  final bool showFixedGeo = !onlyText && s.showFixedGeo;
  final int sceneSeed = hashSonnetSeed(
    '${inputs.program.seed}:${paragraph.id}',
  );
  final bool glowEnabled = inputs.motion;
  final Map<String, TextPainter> cache = <String, TextPainter>{};
  final List<TextPainter> owned = <TextPainter>[];

  TextPainter painterFor(String text, TextStyle style, String key) =>
      cache.putIfAbsent(key, () {
        final TextPainter p = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        owned.add(p);
        return p;
      });

  final List<SonnetBgLine> bgLines = <SonnetBgLine>[];
  if (showBackgroundMg) {
    final int density = (4 + s.mgDensity * 5).round();
    for (int i = 0; i < density; i++) {
      bgLines.add(
        SonnetBgLine(
          ((sceneSeed + i * 97) % 997) / 997 * width,
          ((sceneSeed + i * 193) % 991) / 991 * height,
          32.0 + (sceneSeed + i * 43) % 180,
          i.isOdd ? colors.secondary : colors.accent,
          i % 3 == 0 ? 2 : 1,
          0.12 + (i % 4) * 0.04,
        ),
      );
    }
  }
  TextPainter? metaTitle;
  TextPainter? metaDescription;
  if (!onlyText && s.outerFrameMode == 'full') {
    final String title = (inputs.title ?? '').trim();
    if (title.isNotEmpty) {
      metaTitle = painterFor(
        '[ TRACK ] ${title.toUpperCase()}',
        inputs.measurer
            .styleFor(700, 14)
            .copyWith(
              color: colors.primary.withValues(alpha: 0.2),
              letterSpacing: 4,
            ),
        'meta-title',
      );
    }
    final String desc = <String>[
      (inputs.artist ?? '').trim(),
      (inputs.album ?? '').trim(),
    ].where((String x) => x.isNotEmpty).join(' — ');
    if (desc.isNotEmpty) {
      final TextPainter p = TextPainter(
        text: TextSpan(
          text: desc,
          style: inputs.measurer
              .styleFor(400, 12)
              .copyWith(
                color: colors.secondary.withValues(alpha: 0.3),
                height: 1.3,
              ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: width * 0.3);
      owned.add(p);
      metaDescription = p;
    }
  }

  final List<SonnetShotView> shots = <SonnetShotView>[];
  for (int shotIndex = 0; shotIndex < paragraph.shots.length; shotIndex++) {
    final SonnetShot shot = paragraph.shots[shotIndex];
    final List<List<SonnetSegment>> lineSegments = <List<SonnetSegment>>[
      for (final int li in shot.lineIndices)
        for (final SonnetCompiledLine l in paragraph.lines)
          if (l.sourceIndex == li)
            l.segments
                .where((SonnetSegment x) => x.text.trim().isNotEmpty)
                .toList(),
    ].where((List<SonnetSegment> x) => x.isNotEmpty).toList();
    final List<SonnetSegment> segments = <SonnetSegment>[
      for (final List<SonnetSegment> l in lineSegments) ...l,
    ];
    final int wordCount = math.max(
      1,
      segments.where((SonnetSegment x) => x.isWordLike).length,
    );
    final double heroScale = shot.kind == SonnetShotKind.typeImpact
        ? 1.55
        : shot.kind == SonnetShotKind.quietTableau
        ? 0.82
        : 1;
    final double fontSize =
        (width / math.max(7, wordCount * 2.15) * heroScale * inputs.fontScale)
            .clamp(24.0, 112.0);
    final List<SonnetPlacement> placements = resolveSonnetTypographyLayout(
      lines: lineSegments,
      shotKind: shot.kind,
      width: width,
      height: height,
      baseFontSize: fontSize,
      measurer: inputs.measurer,
    );
    final int shotSeed = sceneSeed + shotIndex * 97;
    final double radius = math.min(width, height);

    // MG：HUD 边框 + 模板背景（bg），几何主图与固定几何只给 type-impact / fragment-collage。
    final SonnetAnimatedGraphics bg = SonnetAnimatedGraphics(shotSeed);
    drawSonnetBackgroundHud(
      bg,
      resolveSonnetBackgroundMgVariant(shotSeed),
      width,
      height,
      shotSeed,
      colors.primary,
      colors.secondary,
    );
    SonnetAnimatedGraphics? geo;
    SonnetFixedGeo? fixedGeo;
    if (shot.kind == SonnetShotKind.typeImpact ||
        shot.kind == SonnetShotKind.fragmentCollage) {
      final int variant =
          resolveSonnetGeoVariant(shotSeed) % sonnetPortedGeoVariantCount;
      geo = SonnetAnimatedGraphics(shotSeed ^ 0x6e0);
      drawSonnetGeoVariant(
        geo,
        variant,
        radius,
        width,
        height,
        shotSeed,
        colors.primary,
        colors.secondary,
      );
      geo.rotation = resolveSonnetGeoRotation(variant, shotSeed);
      fixedGeo = buildSonnetFixedGeo(
        resolveSonnetFixedGeoVariant(shotSeed),
        radius,
        shotSeed,
        colors.primary,
        colors.secondary,
      );
    }
    drawSonnetShotKindBackground(
      bg,
      shot.kind,
      width,
      height,
      shotSeed,
      colors.primary,
    );
    final List<SonnetParticle> particles = buildSonnetParticles(
      shot.kind,
      width,
      height,
      shotSeed,
      colors.primary,
      colors.secondary,
      colors.accent,
    );

    final List<SonnetSegmentView> views = <SonnetSegmentView>[];
    bool staffAdded = false;
    for (final SonnetPlacement placement in placements) {
      if (placement.resolvedRole == SonnetSegmentRole.decoration &&
          (onlyText || !s.showGiantDecorativeText)) {
        continue;
      }
      final SonnetSegment segment = segments[placement.segmentIndex];
      if (segment.text == '♪') {
        if (staffAdded) continue;
        staffAdded = true;
      }
      views.add(
        _buildSegmentView(
          segment: segment,
          original: placement,
          baseFontSize: fontSize,
          shot: shot,
          width: width,
          colors: colors,
          measurer: inputs.measurer,
          glowEnabled: glowEnabled,
          showFixedGeo: showFixedGeo,
          painterFor: painterFor,
        ),
      );
    }

    // poster-blocks 从中心起，其余从主角词起。
    SonnetPlacement? hero;
    for (final SonnetPlacement p in placements) {
      if (p.resolvedRole == SonnetSegmentRole.hero) {
        hero = p;
        break;
      }
    }
    double focusX = 0;
    double focusY = 0;
    if (shot.kind != SonnetShotKind.posterBlocks) {
      if (hero != null) {
        focusX = hero.x;
        focusY = hero.y;
      } else if (placements.isNotEmpty) {
        Rect b = Rect.fromCenter(
          center: Offset(placements.first.x, placements.first.y),
          width: 0,
          height: 0,
        );
        for (final SonnetPlacement p in placements) {
          b = b.expandToInclude(
            Rect.fromCenter(
              center: Offset(p.x, p.y),
              width: p.measuredWidth,
              height: p.measuredHeight,
            ),
          );
        }
        focusX = b.center.dx;
        focusY = b.center.dy;
      }
    }
    final bool poster = shot.kind == SonnetShotKind.posterBlocks;
    shots.add(
      SonnetShotView(
        shot: shot,
        segments: views,
        baseX: width * (poster ? 0.5 : 0.5 + shot.camera.x),
        baseY:
            height *
            (poster
                ? 0.5
                : 0.48 + shot.camera.y + (shotIndex.isOdd ? 0.025 : -0.025)),
        basePivotX: focusX,
        basePivotY: focusY,
        bg: bg,
        geo: geo,
        fixedGeo: fixedGeo,
        particles: particles,
      ),
    );
  }
  return SonnetSceneView(
    paragraph: paragraph,
    shots: shots,
    bgLines: bgLines,
    drawBackdrop: showBackgroundMg,
    painters: owned,
    metaTitle: metaTitle,
    metaDescription: metaDescription,
  );
}

Color _tint(Color c, double r, double g, double b, double alpha) =>
    Color.from(alpha: alpha, red: c.r * r, green: c.g * g, blue: c.b * b);

SonnetSegmentView _buildSegmentView({
  required SonnetSegment segment,
  required SonnetPlacement original,
  required double baseFontSize,
  required SonnetShot shot,
  required double width,
  required SonnetColors colors,
  required SonnetTextMeasurer measurer,
  required bool glowEnabled,
  required bool showFixedGeo,
  required TextPainter Function(String text, TextStyle style, String key)
  painterFor,
}) {
  final SonnetSegmentRole role = original.resolvedRole;
  final double fontSize = baseFontSize * original.fontScale;
  final int normalSeed = hashSonnetSeed(
    '${segment.text}:${segment.startOffset}:${segment.endOffset}:${original.segmentIndex}:normal-offset',
  );
  // 陪衬词沿排版法线随机错开，打破死板的对齐。
  double px = original.x;
  double py = original.y;
  if (role == SonnetSegmentRole.support) {
    final double distance =
        ((normalSeed / 0xFFFFFFFF).clamp(0.0, 1.0) * 2 - 1) * fontSize * 0.3;
    final double normal =
        original.rotation + (original.layoutVertical ? 0 : math.pi / 2);
    px += math.cos(normal) * distance;
    py += math.sin(normal) * distance;
  }
  final SonnetPlacement placement =
      SonnetPlacement(
          segmentIndex: original.segmentIndex,
          displayText: original.displayText,
          isHero: original.isHero,
          isSemiHero: original.isSemiHero,
          fontScale: original.fontScale,
          measuredWidth: original.measuredWidth,
          measuredHeight: original.measuredHeight,
          vertical: original.vertical,
          rotation: original.rotation,
          timingPhase: original.timingPhase,
          role: original.role,
        )
        ..layoutVertical = original.layoutVertical
        ..x = px
        ..y = py
        ..enterX = original.enterX
        ..enterY = original.enterY;

  final bool emphasis = isSonnetEmphasisRole(role);
  final bool isDecoration = role == SonnetSegmentRole.decoration;
  final Color body = colors.primary;
  // 发光 / 描边用关键词色，否则强调词用字色、陪衬词用强调色。
  final Color glowColor =
      colors.keywordColorOf(segment.text) ??
      (emphasis ? colors.primary : colors.accent);
  final int weight = sonnetRoleFontWeight(role);
  final SonnetRng depthRng = SonnetRng(normalSeed ^ 0x5a17);
  final double zDepth = isDecoration
      ? (depthRng.next() > 0.5
            ? 0.5 + depthRng.next() * 0.8
            : -0.5 - depthRng.next() * 0.8)
      : 0;
  final bool hasGlow = glowEnabled && !isDecoration;
  final double glowBlur = math.max(12, fontSize * 0.18);
  final double glowStrength = hasGlow ? sonnetGlowStrength(glowColor) : 0;
  final TextStyle base = measurer.styleFor(weight, fontSize);
  final double strokeW = math.max(1, math.min(8, fontSize * 0.006));
  final TextStyle coreStyle = isDecoration
      ? base.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeW
            ..color = glowColor.withValues(alpha: 0.2),
        )
      : base.copyWith(
          color: body,
          shadows: glowStrength > 0
              ? <Shadow>[
                  Shadow(
                    color: glowColor.withValues(alpha: 0.8 * glowStrength),
                    blurRadius: glowBlur,
                  ),
                ]
              : null,
        );
  final String styleKey =
      '$weight|${fontSize.toStringAsFixed(2)}|${isDecoration ? 'd' : 'b'}|${glowStrength.toStringAsFixed(2)}|${glowColor.toARGB32()}';
  final bool isSemi = role == SonnetSegmentRole.semiHero;
  final TextStyle? ghostStyle = isSemi
      ? base.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeW
            ..color = glowColor,
        )
      : null;
  final Offset screenNormal = placement.layoutVertical
      ? const Offset(1, 0)
      : const Offset(0, 1);
  final double cn = math.cos(-placement.rotation);
  final double sn = math.sin(-placement.rotation);
  final Offset ghostNormal = Offset(
    screenNormal.dx * cn - screenNormal.dy * sn,
    screenNormal.dx * sn + screenNormal.dy * cn,
  );
  final double ghostSpread = fontSize * 0.85;
  final double ghostDuration = math.min(
    0.7,
    math.max(0.4, (shot.end - shot.start) * 0.12 + 0.1),
  );

  if (segment.text == '♪') {
    final SonnetGlyphView staff = SonnetGlyphView(
      baseX: placement.x,
      baseY: placement.y,
      enterX: placement.enterX,
      enterY: placement.enterY,
      entryRotation: 0,
      finalRotation: placement.rotation,
      start: shot.start,
      settle: shot.start + 0.5,
      zDepth: 0,
      staff: SonnetStaff(
        baseFontSize: baseFontSize,
        width: width,
        shotStart: shot.start,
        primary: colors.primary,
        accent: colors.accent,
      ),
    );
    return SonnetSegmentView(
      role: role,
      glyphs: <SonnetGlyphView>[staff],
      trackingGlyphs: <SonnetGlyphView>[staff],
      guide: isDecoration
          ? null
          : SonnetGuide(
              segment: segment,
              placement: placement,
              color: emphasis ? colors.accent : colors.secondary,
              fontSize: fontSize,
              textStart: shot.start,
              seed: normalSeed ^ 0x9e37,
            ),
    );
  }

  final List<SonnetGlyphPlacement> layout = buildSonnetGlyphLayout(
    segment,
    placement,
    fontSize,
    (String ch) => measurer.measure(ch, weight, fontSize),
    shot.start,
    shot.end,
  );
  final double caOffset = fontSize * (emphasis ? 0.025 : 0.010);
  final double caAlpha = emphasis ? 0.8 : 0.5;
  final List<SonnetGlyphView> glyphs = <SonnetGlyphView>[
    for (final SonnetGlyphPlacement g in layout)
      SonnetGlyphView(
        baseX: g.baseX,
        baseY: g.baseY,
        enterX: g.enterX,
        enterY: g.enterY,
        entryRotation: g.entryRotation,
        finalRotation: placement.rotation,
        start: g.start,
        settle: g.settle,
        zDepth: zDepth,
        core: painterFor(g.char, coreStyle, '${g.char}|$styleKey'),
        cyan: isDecoration
            ? null
            : painterFor(
                g.char,
                base.copyWith(color: _tint(body, 0, 1, 1, caAlpha)),
                '${g.char}|$styleKey|cyan',
              ),
        red: isDecoration
            ? null
            : painterFor(
                g.char,
                base.copyWith(color: _tint(body, 1, 0, 0x44 / 255, caAlpha)),
                '${g.char}|$styleKey|red',
              ),
        caOffset: isDecoration ? 0 : caOffset,
        ghost: ghostStyle == null
            ? null
            : painterFor(g.char, ghostStyle, '${g.char}|$styleKey|ghost'),
        ghosts: ghostStyle == null
            ? const <SonnetGhost>[]
            : <SonnetGhost>[
                for (int layer = 1; layer <= 2; layer++)
                  SonnetGhost(
                    ghostNormal.dx *
                        (normalSeed.isEven ? 1 : -1) *
                        (layer == 1 ? 1 : 1.7) *
                        ghostSpread,
                    ghostNormal.dy *
                        (normalSeed.isEven ? 1 : -1) *
                        (layer == 1 ? 1 : 1.7) *
                        ghostSpread,
                    layer == 1 ? 0.3 : 0.16,
                  ),
              ],
        ghostDuration: ghostDuration,
      ),
  ];

  // 字后的固定几何：较少出现，且不与开口画框叠在同一段。
  final int textSeed =
      segment.text.codeUnits.fold<int>(0, (int a, int b) => a + b) +
      placement.segmentIndex * 13;
  final bool chorusEffect = textSeed % 100 < 35;
  final int threshold = chorusEffect ? 26 : 15;
  final bool hasFrameDecor = SonnetFrameDecor.specOf(segment).$1;
  if (showFixedGeo &&
      textSeed % 100 < threshold &&
      !isDecoration &&
      segment.isWordLike &&
      !hasFrameDecor &&
      glyphs.isNotEmpty) {
    glyphs.insert(
      0,
      SonnetGlyphView(
        baseX: placement.x,
        baseY: placement.y,
        enterX: placement.enterX,
        enterY: placement.enterY,
        entryRotation: 0,
        finalRotation: placement.rotation,
        start: glyphs.first.start,
        settle: glyphs.first.settle,
        zDepth: -0.5 - (textSeed % 5) * 0.1,
        bgShape: SonnetTextFixedGeo(
          seed: textSeed,
          isChorusEffect: chorusEffect,
          fontSize: fontSize,
          layoutWidth: width,
          primary: colors.primary,
          secondary: colors.secondary,
          accent: colors.accent,
        ),
      ),
    );
  }
  final double firstText = glyphs
      .firstWhere(
        (SonnetGlyphView g) => g.isTextGlyph,
        orElse: () => glyphs.first,
      )
      .start;
  return SonnetSegmentView(
    role: role,
    glyphs: glyphs,
    trackingGlyphs: glyphs
        .where((SonnetGlyphView g) => !g.isBackgroundShape)
        .toList(),
    guide: isDecoration
        ? null
        : SonnetGuide(
            segment: segment,
            placement: placement,
            color: emphasis ? colors.accent : colors.secondary,
            fontSize: fontSize,
            textStart: glyphs.isEmpty ? shot.start : glyphs.first.start,
            seed: normalSeed ^ 0x9e37,
          ),
    frameDecor: SonnetFrameDecor.build(
      segment: segment,
      placement: placement,
      primary: colors.primary,
      fontSize: fontSize,
      shotStart: shot.start,
      shotEnd: shot.end,
      firstGlyphStart: glyphs.isEmpty ? segment.start : firstText,
    ),
  );
}
