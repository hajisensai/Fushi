/// 云阶每句的排版产物：规划（[PartitaLinePlan]）+ 测量后的行框 + 每个词 / 字的 TextPainter。
/// 按「行下标 + 区域尺寸 + 字号 + 参数」缓存（folia `getOrBuildPartitaLayout`，上限 48），
/// 换色只重排正在变色的那几个词，不逐帧重建整句。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_timing.dart';

/// 可换色的一段文字：颜色 / 阴影变了才重新排版。
class PartitaTintedText {
  PartitaTintedText(this.text, this.style, this.direction);

  final String text;
  final TextStyle style;
  final TextDirection direction;
  final TextPainter painter = TextPainter();
  int _key = 0x7FFFFFFF;

  /// 排好 [color] 的正文。
  TextPainter body(Color color) {
    final int key = color.toARGB32();
    if (key != _key) {
      _key = key;
      painter
        ..text = TextSpan(
          text: text,
          style: style.copyWith(color: color),
        )
        ..textDirection = direction
        ..layout();
    }
    return painter;
  }

  /// 排好发光层：字本身透明，只画两层 text-shadow（folia 半径 [inner] / [outer]）；
  /// [alpha] 量化到 1/32 才重排。
  TextPainter glow(Color color, double alpha, double inner, double outer) {
    final int step = (alpha.clamp(0.0, 1.0) * 32).round();
    final int key = color.toARGB32() ^ (step << 1) ^ 0x55AA0000;
    if (key != _key) {
      _key = key;
      final Color c = color.withValues(alpha: color.a * step / 32);
      painter
        ..text = TextSpan(
          text: text,
          style: style.copyWith(
            color: const Color(0x00000000),
            shadows: <Shadow>[
              Shadow(color: c, blurRadius: _cssShadowRadius(inner)),
              Shadow(color: c, blurRadius: _cssShadowRadius(outer)),
            ],
          ),
        )
        ..textDirection = direction
        ..layout();
    }
    return painter;
  }

  void dispose() => painter.dispose();
}

/// CSS text-shadow 模糊半径 r（σ = r/2）→ Flutter `Shadow.blurRadius`（σ = 0.57735·b + 0.5）。
double _cssShadowRadius(double r) => math.max(0, (r / 2 - 0.5) / 0.57735);

/// 发光层里的一个字（逐字扫光用）。
class PartitaGlowGlyph {
  PartitaGlowGlyph({
    required this.dx,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  /// 在词框里的横向偏移。
  final double dx;
  final int startMs;
  final int endMs;
  final PartitaTintedText text;
}

/// 一个显示词的绘制素材。
class PartitaWordPaint {
  PartitaWordPaint({
    required this.word,
    required this.pose,
    required this.box,
    required this.body,
    required this.glyphs,
    required this.times,
    required this.durationMs,
  });

  final LyricVisualizerWord word;
  final PartitaPose pose;

  /// 相对行框左上。
  final Rect box;
  final PartitaTintedText body;

  /// 多字词逐字发光；单字词只有一个（整词持续发光）。
  final List<PartitaGlowGlyph> glyphs;
  final PartitaStateTimes times;
  final int durationMs;

  void dispose() {
    body.dispose();
    for (final PartitaGlowGlyph g in glyphs) {
      g.text.dispose();
    }
  }
}

/// 一行（chunk）的绘制素材。
class PartitaRowPaint {
  PartitaRowPaint({
    required this.plan,
    required this.box,
    required this.words,
    required this.times,
  });

  final PartitaRowPlan plan;

  /// 在整句块坐标里。
  final Rect box;
  final List<PartitaWordPaint> words;
  final PartitaStateTimes times;
}

/// 一句的绘制素材。
class PartitaLinePaint {
  PartitaLinePaint({
    required this.line,
    required this.profile,
    required this.rows,
    required this.blockSize,
    required this.fontSize,
    required this.fitScale,
  });

  final LyricVisualizerLine line;
  final LyricVisualizerRenderHints profile;
  final List<PartitaRowPaint> rows;
  final Size blockSize;
  final double fontSize;
  final double fitScale;

  void dispose() {
    for (final PartitaRowPaint r in rows) {
      for (final PartitaWordPaint w in r.words) {
        w.dispose();
      }
    }
  }
}

/// 排版缓存（State 持有，卸载时 [dispose]）。
class PartitaLineCache {
  static const int _limit = 48;

  final LinkedHashMap<String, PartitaLinePaint> _map =
      LinkedHashMap<String, PartitaLinePaint>();
  Object? _owner;

  /// 换了时间轴 / 区域尺寸 / 样式就清空（旧条目永远不会再命中）。
  void bindTo(Object owner) {
    if (identical(owner, _owner)) return;
    _owner = owner;
    clear();
  }

  int get length => _map.length;

  PartitaLinePaint lineFor({
    required LyricVisualizerLine line,
    required Size area,
    required double fontScale,
    required PartitaSettings settings,
    required TextStyle style,
    required int seed,
  }) {
    final String key =
        '${line.index}|${area.width.round()}x${(area.height / 24).round()}|'
        '$fontScale|${settings.cacheKey}|${style.hashCode}';
    final PartitaLinePaint? hit = _map.remove(key);
    if (hit != null) {
      _map[key] = hit;
      return hit;
    }
    final PartitaLinePaint built = buildPartitaLinePaint(
      line: line,
      area: area,
      fontScale: fontScale,
      settings: settings,
      style: style,
      seed: seed,
    );
    _map[key] = built;
    while (_map.length > _limit) {
      final String oldest = _map.keys.first;
      _map.remove(oldest)!.dispose();
    }
    return built;
  }

  void clear() {
    for (final PartitaLinePaint p in _map.values) {
      p.dispose();
    }
    _map.clear();
  }

  void dispose() => clear();
}

/// 规划 + 测量 + 排行框 + 建 TextPainter。
PartitaLinePaint buildPartitaLinePaint({
  required LyricVisualizerLine line,
  required Size area,
  required double fontScale,
  required PartitaSettings settings,
  required TextStyle style,
  required int seed,
}) {
  final LyricVisualizerRandom rng = LyricVisualizerRandom(
    seed ^ (line.index * 0x9E3779B1),
  );
  final PartitaLinePlan plan = planPartitaLine(
    line,
    windowHeight: area.height,
    settings: settings,
    random: rng.next,
  );
  final LyricVisualizerRenderHints profile = line.renderHints;
  final double fontSize = partitaFontSize(
    width: area.width,
    totalGraphemes: plan.totalGraphemes,
    fontScale: fontScale,
  );
  final TextStyle wordStyle = style.copyWith(
    fontSize: fontSize,
    fontWeight: style.fontWeight ?? FontWeight.w700,
    height: partitaLineHeight,
    leadingDistribution: TextLeadingDistribution.even,
  );

  // 先建正文 painter 并测宽。
  final List<List<PartitaTintedText>> bodies = <List<PartitaTintedText>>[];
  final List<List<double>> widths = <List<double>>[];
  for (final PartitaRowPlan row in plan.rows) {
    final TextDirection dir =
        partitaIsRtl(
          row.displayWords.map((LyricVisualizerWord w) => w.text).join(' '),
        )
        ? TextDirection.rtl
        : TextDirection.ltr;
    final List<PartitaTintedText> b = <PartitaTintedText>[
      for (final LyricVisualizerWord w in row.displayWords)
        PartitaTintedText(w.text, wordStyle, dir),
    ];
    bodies.add(b);
    widths.add(<double>[
      for (final PartitaTintedText t in b)
        t.body(const Color(0xFFFFFFFF)).width,
    ]);
  }
  final PartitaBlockGeometry geo = layoutPartitaBlock(
    rows: plan.rows,
    widths: widths,
    fontSize: fontSize,
    avoidOverlap: settings.avoidOverlap,
  );
  final double fit = partitaFitScale(block: geo, rows: plan.rows, area: area);

  final List<PartitaRowPaint> rows = <PartitaRowPaint>[];
  for (int r = 0; r < plan.rows.length; r++) {
    final PartitaRowPlan rp = plan.rows[r];
    final List<PartitaWordPaint> words = <PartitaWordPaint>[];
    for (int i = 0; i < rp.displayWords.length; i++) {
      final LyricVisualizerWord w = rp.displayWords[i];
      final PartitaTintedText body = bodies[r][i];
      words.add(
        PartitaWordPaint(
          word: w,
          pose: rp.wordPoses[i],
          box: geo.rows[r].wordBoxes[i],
          body: body,
          glyphs: _glowGlyphs(line, w, body, wordStyle),
          times: PartitaStateTimes.of(
            startMs: w.startMs,
            activeEndMs: profile.wordActiveEndMs(w.startMs, w.endMs),
            lineStartMs: line.startMs,
            profile: profile,
          ),
          durationMs: profile.wordDisplayDurationMs(w.startMs, w.endMs),
        ),
      );
    }
    final LyricVisualizerWord last = rp.chunkWords.last;
    rows.add(
      PartitaRowPaint(
        plan: rp,
        box: geo.rows[r].box,
        words: words,
        times: PartitaStateTimes.of(
          startMs: rp.chunkWords.first.startMs,
          activeEndMs: profile.wordActiveEndMs(last.startMs, last.endMs),
          lineStartMs: line.startMs,
          profile: profile,
        ),
      ),
    );
  }
  return PartitaLinePaint(
    line: line,
    profile: profile,
    rows: rows,
    blockSize: geo.size,
    fontSize: fontSize,
    fitScale: fit,
  );
}

/// 发光层的字：多字词逐字（各字自己的起止，取自运行时字形），单字词一个。
List<PartitaGlowGlyph> _glowGlyphs(
  LyricVisualizerLine line,
  LyricVisualizerWord w,
  PartitaTintedText body,
  TextStyle style,
) {
  final int end = w.firstGlyph + w.glyphCount;
  final bool hasGlyphs =
      w.firstGlyph >= 0 && end <= line.glyphs.length && w.glyphCount > 1;
  if (!hasGlyphs) {
    return <PartitaGlowGlyph>[
      PartitaGlowGlyph(
        dx: 0,
        startMs: w.startMs,
        endMs: w.endMs,
        text: PartitaTintedText(w.text, style, body.direction),
      ),
    ];
  }
  final TextPainter measured = body.painter;
  final List<PartitaGlowGlyph> out = <PartitaGlowGlyph>[];
  int offset = 0;
  for (int gi = w.firstGlyph; gi < end; gi++) {
    final LyricVisualizerGlyph g = line.glyphs[gi];
    final int len = g.text.length;
    if (!g.isSpace) {
      final List<TextBox> boxes = measured.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + len),
      );
      final double dx = boxes.isEmpty ? 0 : boxes.first.left;
      out.add(
        PartitaGlowGlyph(
          dx: dx,
          startMs: g.startMs,
          endMs: g.endMs,
          text: PartitaTintedText(g.text, style, body.direction),
        ),
      );
    }
    offset += len;
  }
  return out;
}
