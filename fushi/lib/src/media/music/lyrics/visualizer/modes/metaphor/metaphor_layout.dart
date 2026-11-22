/// 隐喻的排版（纯函数，移植 folia `metaphor/metaphorLayout.ts`）：一句歌词按词切成 token，再按
/// 构图（方阵、阶梯、主词、竖排、散置、齐行）摆到世界坐标里。单位是 em（基础字号的一个字高是 1），
/// y 朝上。字的时间来自运行时的逐字时间线；量字宽的函数由外面给（运行时是 TextPainter，单测里是常数）。
library;

import 'dart:math' as math;

import 'dart:ui' show Color;

import 'package:characters/characters.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';

/// token 里的一个字和它的演唱时间（秒）。
class MetaphorTokenChar {
  const MetaphorTokenChar(this.char, this.t0, this.t1);

  final String char;
  final double t0;
  final double t1;
}

class MetaphorToken {
  const MetaphorToken({
    required this.text,
    required this.chars,
    required this.wordLike,
    required this.space,
  });

  final String text;
  final List<MetaphorTokenChar> chars;
  final bool wordLike;

  /// 只有空白：占宽度，不出字。
  final bool space;
}

/// 世界里的矩形（y 朝上：y0 在下）。
class MetaphorRect {
  const MetaphorRect(this.x0, this.y0, this.x1, this.y1);

  final double x0;
  final double y0;
  final double x1;
  final double y1;

  double get width => x1 - x0;
  double get height => y1 - y0;

  MetaphorRect union(MetaphorRect o) => MetaphorRect(
    math.min(x0, o.x0),
    math.min(y0, o.y0),
    math.max(x1, o.x1),
    math.max(y1, o.y1),
  );
}

/// 一个摆好的字。
class MetaphorGlyph {
  MetaphorGlyph({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.rot,
    required this.t0,
    required this.t1,
    required this.word,
    required this.accent,
    required this.seed,
    this.tint,
  });

  final String char;
  double x;
  double y;

  /// 字高（em 的倍数）。
  final double size;
  final double rot;
  final double t0;
  final double t1;

  /// 属于 words 里的第几个。
  final int word;
  final bool accent;

  /// 关键字自己的颜色（主题 wordColors）；null = 强调色（或不是关键字）。
  final Color? tint;

  /// 0..1，这个字自己的随机数（化开时散去的方向、放出的粒子用）。
  final double seed;
}

/// 一个词的包围盒和时间。
class MetaphorWord extends MetaphorRect {
  const MetaphorWord(super.x0, super.y0, super.x1, super.y1, this.t0, this.t1);

  final double t0;
  final double t1;
}

class MetaphorLayout {
  const MetaphorLayout({
    required this.composition,
    required this.glyphs,
    required this.words,
    required this.bounds,
  });

  final MetaphorComposition composition;
  final List<MetaphorGlyph> glyphs;
  final List<MetaphorWord> words;
  final MetaphorRect bounds;
}

/// 一个字的步进宽度，em 的倍数。
typedef MetaphorMeasure = double Function(String char);

/// 间奏没有字：留给融球的舞台。
const MetaphorRect metaphorEmptyStage = MetaphorRect(-4.5, -2.6, 4.5, 2.6);

const double _lineHeight = 1.14;
final RegExp _wordLike = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isSpace(String s) => s.trim().isEmpty;

/// 一句歌词 → token（folia `buildMetaphorTokens`）：按共享分词（`LyricVisualizerLine.segments`，
/// folia `segmentLyricWords`）切成词，词与词之间的空白各成一段；每个字带自己的演唱时间。
List<MetaphorToken> buildMetaphorTokens(LyricVisualizerLine line) {
  final List<MetaphorToken> tokens = <MetaphorToken>[];
  final List<LyricVisualizerGlyph> glyphs = line.glyphs;

  void push(int from, int to) {
    if (to <= from) return;
    final List<MetaphorTokenChar> chars = <MetaphorTokenChar>[
      for (final LyricVisualizerGlyph g in glyphs.sublist(from, to))
        MetaphorTokenChar(g.text, g.startMs / 1000, g.endMs / 1000),
    ];
    final String text = chars.map((MetaphorTokenChar c) => c.char).join();
    tokens.add(
      MetaphorToken(
        text: text,
        chars: chars,
        wordLike: _wordLike.hasMatch(text),
        space: _isSpace(text),
      ),
    );
  }

  /// 词外的字（空白、没归进词的符号）：空白连成一段，其余一字一个。
  void pushGap(int from, int to) {
    int i = from;
    while (i < to) {
      final int first = i;
      if (glyphs[i].isSpace) {
        while (i < to && glyphs[i].isSpace) {
          i++;
        }
      } else {
        i++;
      }
      push(first, i);
    }
  }

  int cursor = 0;
  for (final LyricVisualizerSegment seg in line.segments) {
    final int from = seg.firstGlyph.clamp(cursor, glyphs.length);
    final int to = (seg.firstGlyph + seg.glyphCount).clamp(from, glyphs.length);
    pushGap(cursor, from);
    push(from, to);
    cursor = to;
  }
  pushGap(cursor, glyphs.length);
  return tokens;
}

/// 没有时间的文字（曲名卡）→ token：全部在 [time] 这一刻就唱完。
List<MetaphorToken> buildMetaphorTextTokens(String text, double time) {
  final List<MetaphorToken> tokens = <MetaphorToken>[];
  final List<String> chars = text.characters.toList();
  int i = 0;
  while (i < chars.length) {
    final int first = i;
    if (_isSpace(chars[i])) {
      while (i < chars.length && _isSpace(chars[i])) {
        i++;
      }
    } else if (lyricVisualizerIsCjk(chars[i])) {
      i++;
    } else {
      while (i < chars.length &&
          !_isSpace(chars[i]) &&
          !lyricVisualizerIsCjk(chars[i])) {
        i++;
      }
    }
    final List<String> part = chars.sublist(first, i);
    final String t = part.join();
    tokens.add(
      MetaphorToken(
        text: t,
        chars: <MetaphorTokenChar>[
          for (final String c in part) MetaphorTokenChar(c, time, time),
        ],
        wordLike: _wordLike.hasMatch(t),
        space: _isSpace(t),
      ),
    );
  }
  return tokens;
}

class _Placed {
  const _Placed(
    this.token,
    this.index,
    this.x,
    this.y,
    this.size,
    this.rot,
    this.width,
  );

  final MetaphorToken token;
  final int index;

  /// 左缘、行中线。
  final double x;
  final double y;
  final double size;
  final double rot;
  final double width;
}

double _clamp(double v, double min, double max) =>
    math.min(max, math.max(min, v));

double _tokenAdvance(MetaphorToken token, MetaphorMeasure measure) =>
    token.chars.fold(0, (double s, MetaphorTokenChar c) => s + measure(c.char));

/// 按 token 折行：行首行尾的空白不算。
List<List<int>> _wrapRows(
  List<MetaphorToken> tokens,
  List<double> widths,
  double maxWidth,
) {
  final List<List<int>> rows = <List<int>>[];
  List<int> row = <int>[];
  double width = 0;
  for (int index = 0; index < tokens.length; index++) {
    final MetaphorToken token = tokens[index];
    if (row.isEmpty && token.space) continue;
    if (row.isNotEmpty && !token.space && width + widths[index] > maxWidth) {
      rows.add(row);
      row = <int>[];
      width = 0;
    }
    row.add(index);
    width += widths[index];
  }
  if (row.isNotEmpty) rows.add(row);
  final List<List<int>> out = <List<int>>[];
  for (final List<int> r in rows) {
    final List<int> trimmed = List<int>.of(r);
    while (trimmed.isNotEmpty && tokens[trimmed.last].space) {
      trimmed.removeLast();
    }
    if (trimmed.isNotEmpty) out.add(trimmed);
  }
  return out;
}

double _rowWidth(List<int> row, List<double> widths, List<double> sizes) =>
    row.fold(0, (double s, int i) => s + widths[i] * sizes[i]);

/// 排一句的输入。
class MetaphorLayoutInput {
  const MetaphorLayoutInput({
    required this.tokens,
    required this.composition,
    required this.measure,
    required this.rng,
    this.isAccent,
    this.tints,
  });

  final List<MetaphorToken> tokens;
  final MetaphorComposition composition;
  final MetaphorMeasure measure;
  final MetaphorRng rng;

  /// 这个词要不要用强调色。
  final bool Function(String text)? isAccent;

  /// 每个 token 的关键字颜色（folia `tints`）；有颜色的 token 也算强调。
  final List<Color?>? tints;
}

List<_Placed> _placeRows(
  List<List<int>> rows,
  MetaphorLayoutInput input,
  List<double> widths,
  List<double> sizes,
  double Function(double width, int rowIndex) rowLeft,
  double Function(int index) tokenRot,
) {
  final List<_Placed> placed = <_Placed>[];
  double top = 0;
  for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final List<int> row = rows[rowIndex];
    final double height =
        row.map((int i) => sizes[i]).reduce(math.max) * _lineHeight;
    double x = rowLeft(_rowWidth(row, widths, sizes), rowIndex);
    for (final int index in row) {
      final double width = widths[index] * sizes[index];
      placed.add(
        _Placed(
          input.tokens[index],
          index,
          x,
          top - height / 2,
          sizes[index],
          tokenRot(index),
          width,
        ),
      );
      x += width;
    }
    top -= height;
  }
  return placed;
}

double _flat(int _) => 0;

List<_Placed> _placeBlock(
  MetaphorLayoutInput input,
  List<double> widths,
  double total,
) {
  final List<double> sizes = List<double>.filled(widths.length, 1);
  final List<List<int>> rows = _wrapRows(
    input.tokens,
    widths,
    _clamp(math.sqrt(total * 2.2), 3.5, 11),
  );
  return _placeRows(
    rows,
    input,
    widths,
    sizes,
    (double w, int _) => -w / 2,
    _flat,
  );
}

List<_Placed> _placeStair(
  MetaphorLayoutInput input,
  List<double> widths,
  double total,
) {
  final List<double> sizes = List<double>.filled(widths.length, 1);
  final List<List<int>> rows = _wrapRows(
    input.tokens,
    widths,
    _clamp(math.sqrt(total * 1.4), 3, 8),
  );
  final double step = 0.7 + input.rng() * 0.6;
  return _placeRows(
    rows,
    input,
    widths,
    sizes,
    (double _, int rowIndex) => rowIndex * step,
    _flat,
  );
}

List<_Placed> _placeHero(
  MetaphorLayoutInput input,
  List<double> widths,
  double total,
) {
  final List<MetaphorToken> tokens = input.tokens;
  int hero = -1;
  for (int index = 0; index < tokens.length; index++) {
    if (tokens[index].wordLike && (hero < 0 || widths[index] >= widths[hero])) {
      hero = index;
    }
  }
  if (hero < 0) return _placeBlock(input, widths, total);
  final double heroSize = _clamp(7 / math.max(widths[hero], 0.5), 1.6, 3);
  final double heroWidth = widths[hero] * heroSize;
  final List<double> sizes = <double>[
    for (int i = 0; i < widths.length; i++) i == hero ? heroSize : 1,
  ];
  final double sideWidth = math.max(heroWidth, 4.5);
  final List<List<int>> before = _wrapRows(
    tokens.sublist(0, hero),
    widths.sublist(0, hero),
    sideWidth,
  );
  final List<List<int>> after = _wrapRows(
    tokens.sublist(hero + 1),
    widths.sublist(hero + 1),
    sideWidth,
  ).map((List<int> r) => r.map((int i) => i + hero + 1).toList()).toList();
  final List<List<int>> rows = <List<int>>[
    ...before,
    <int>[hero],
    ...after,
  ];
  // 前面的行贴主词左缘，后面的行贴主词右缘
  return _placeRows(
    rows,
    input,
    widths,
    sizes,
    (double w, int rowIndex) => rowIndex <= before.length ? 0 : heroWidth - w,
    _flat,
  );
}

List<_Placed> _placeScatter(
  MetaphorLayoutInput input,
  List<double> widths,
  double total,
) {
  final List<double> sizes = <double>[
    for (final MetaphorToken t in input.tokens)
      t.wordLike ? 0.8 + input.rng() * 0.8 : 1,
  ];
  final List<double> scaled = <double>[
    for (int i = 0; i < widths.length; i++) widths[i] * sizes[i],
  ];
  final List<List<int>> rows = _wrapRows(
    input.tokens,
    scaled,
    _clamp(math.sqrt(total * 2), 3.5, 9),
  );
  final List<double> rots = <double>[
    for (final MetaphorToken t in input.tokens)
      t.space ? 0 : (input.rng() - 0.5) * 0.18,
  ];
  final List<double> shifts = <double>[
    for (int i = 0; i < rows.length; i++) (input.rng() - 0.5) * 2.2,
  ];
  return _placeRows(
    rows,
    input,
    widths,
    sizes,
    (double w, int rowIndex) => -w / 2 + shifts[rowIndex],
    (int index) => rots[index],
  );
}

const double _justifyMax = 2.6;

List<_Placed> _placeJustify(
  MetaphorLayoutInput input,
  List<double> widths,
  double total,
) {
  final List<List<int>> rows = _wrapRows(
    input.tokens,
    widths,
    _clamp(math.sqrt(total * 1.5), 3, 8),
  );
  final List<double> unit = List<double>.filled(widths.length, 1);
  final List<double> rowWidths = <double>[
    for (final List<int> r in rows) _rowWidth(r, widths, unit),
  ];
  final double target = rowWidths.isEmpty ? 0 : rowWidths.reduce(math.max);
  final List<double> sizes = List<double>.of(unit);
  for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final double size = _clamp(
      target / math.max(0.5, rowWidths[rowIndex]),
      1,
      _justifyMax,
    );
    for (final int index in rows[rowIndex]) {
      sizes[index] = size;
    }
  }
  // 放大封顶的行不够宽：一行靠左、一行靠右
  return _placeRows(
    rows,
    input,
    widths,
    sizes,
    (double w, int rowIndex) => rowIndex.isEven ? -target / 2 : target / 2 - w,
    _flat,
  );
}

const int _columnMax = 6;
const double _columnPitch = 1.08;
const double _columnGap = 1.3;

class _Slot {
  const _Slot(this.c, this.x, this.y, this.size, this.rot, this.half);

  final MetaphorTokenChar c;
  final double x;
  final double y;
  final double size;
  final double rot;
  final double half;
}

/// 排一句：每个字的位置、每个词的包围盒和整句的包围盒，整句的中心在原点。
MetaphorLayout buildMetaphorLayout(MetaphorLayoutInput input) {
  final List<MetaphorToken> tokens = input.tokens;
  final List<double> widths = <double>[
    for (final MetaphorToken t in tokens) _tokenAdvance(t, input.measure),
  ];
  final double total = widths.fold(0, (double s, double w) => s + w);
  final List<MetaphorGlyph> glyphs = <MetaphorGlyph>[];
  final List<MetaphorWord> words = <MetaphorWord>[];
  final List<Color?> tints = <Color?>[
    for (int i = 0; i < tokens.length; i++)
      tokens[i].space || input.tints == null || i >= input.tints!.length
          ? null
          : input.tints![i],
  ];
  final List<bool> accents = <bool>[
    for (int i = 0; i < tokens.length; i++)
      !tokens[i].space &&
          (tints[i] != null ||
              (input.isAccent?.call(tokens[i].text.trim()) ?? false)),
  ];

  void pushWord(List<_Slot> slots, bool accent, [Color? tint]) {
    if (slots.isEmpty) return;
    final int word = words.length;
    double x0 = double.infinity;
    double y0 = double.infinity;
    double x1 = double.negativeInfinity;
    double y1 = double.negativeInfinity;
    double t0 = double.infinity;
    double t1 = double.negativeInfinity;
    for (final _Slot s in slots) {
      x0 = math.min(x0, s.x - s.half);
      x1 = math.max(x1, s.x + s.half);
      y0 = math.min(y0, s.y - s.size * 0.55);
      y1 = math.max(y1, s.y + s.size * 0.55);
      t0 = math.min(t0, s.c.t0);
      t1 = math.max(t1, s.c.t1);
      glyphs.add(
        MetaphorGlyph(
          char: s.c.char,
          x: s.x,
          y: s.y,
          size: s.size,
          rot: s.rot,
          t0: s.c.t0,
          t1: s.c.t1,
          word: word,
          accent: accent,
          tint: tint,
          seed: input.rng(),
        ),
      );
    }
    words.add(MetaphorWord(x0, y0, x1, y1, t0, t1));
  }

  if (input.composition == MetaphorComposition.column) {
    final List<(MetaphorTokenChar, int)> cells = <(MetaphorTokenChar, int)>[
      for (int i = 0; i < tokens.length; i++)
        if (!tokens[i].space)
          for (final MetaphorTokenChar c in tokens[i].chars) (c, i),
    ];
    final int columns = math.max(1, (cells.length / _columnMax).ceil());
    final int perColumn = math.max(1, (cells.length / columns).ceil());
    final Map<int, List<_Slot>> byToken = <int, List<_Slot>>{};
    for (int order = 0; order < cells.length; order++) {
      final (MetaphorTokenChar item, int index) = cells[order];
      final int column = order ~/ perColumn;
      final _Slot slot = _Slot(
        item,
        -column * _columnGap,
        -(order % perColumn) * _columnPitch - column * 0.5,
        1,
        0,
        0.5,
      );
      (byToken[index] ??= <_Slot>[]).add(slot);
    }
    byToken.forEach((int index, List<_Slot> slots) {
      pushWord(slots, accents[index], tints[index]);
    });
  } else {
    final List<_Placed> placed = switch (input.composition) {
      MetaphorComposition.block => _placeBlock(input, widths, total),
      MetaphorComposition.stair => _placeStair(input, widths, total),
      MetaphorComposition.hero => _placeHero(input, widths, total),
      MetaphorComposition.scatter => _placeScatter(input, widths, total),
      MetaphorComposition.justify => _placeJustify(input, widths, total),
      MetaphorComposition.column => const <_Placed>[],
    };
    for (final _Placed p in placed) {
      if (p.token.space) continue;
      final double centerX = p.x + p.width / 2;
      final double cos = math.cos(p.rot);
      final double sin = math.sin(p.rot);
      double pen = p.x;
      final List<_Slot> slots = <_Slot>[];
      for (final MetaphorTokenChar item in p.token.chars) {
        final double advance = input.measure(item.char) * p.size;
        final double dx = pen + advance / 2 - centerX;
        pen += advance;
        slots.add(
          _Slot(
            item,
            centerX + dx * cos,
            p.y + dx * sin,
            p.size,
            p.rot,
            advance / 2,
          ),
        );
      }
      pushWord(slots, accents[p.index], tints[p.index]);
    }
  }

  if (words.isEmpty) {
    return MetaphorLayout(
      composition: input.composition,
      glyphs: glyphs,
      words: words,
      bounds: const MetaphorRect(-1, -0.5, 1, 0.5),
    );
  }
  MetaphorRect bounds = words.first;
  for (final MetaphorWord w in words) {
    bounds = bounds.union(w);
  }
  final double cx = (bounds.x0 + bounds.x1) / 2;
  final double cy = (bounds.y0 + bounds.y1) / 2;
  for (final MetaphorGlyph g in glyphs) {
    g.x -= cx;
    g.y -= cy;
  }
  return MetaphorLayout(
    composition: input.composition,
    glyphs: glyphs,
    words: <MetaphorWord>[
      for (final MetaphorWord w in words)
        MetaphorWord(w.x0 - cx, w.y0 - cy, w.x1 - cx, w.y1 - cy, w.t0, w.t1),
    ],
    bounds: MetaphorRect(
      bounds.x0 - cx,
      bounds.y0 - cy,
      bounds.x1 - cx,
      bounds.y1 - cy,
    ),
  );
}
