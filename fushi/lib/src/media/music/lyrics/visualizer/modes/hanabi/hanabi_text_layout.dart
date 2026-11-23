/// 花火的排字（移植 folia `hanabi/text/layout.ts` + `glyphs.ts` 的纯函数）：词的字号起伏、按词切行
/// （最小化最长一行的 DP）、九种摆法、整体缩放适配文字区。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

class LayoutGlyphInput {
  const LayoutGlyphInput({
    required this.char,
    required this.advance,
    required this.blank,
    required this.upright,
    required this.word,
  });
  final String char;

  /// 字宽（em）。
  final double advance;
  final bool blank;
  final bool upright;
  final int word;
}

class LayoutWordInput {
  LayoutWordInput({
    required this.text,
    required this.start,
    required this.end,
    required this.blank,
    required this.space,
    this.scale = 1,
  });
  final String text;
  final int start;
  final int end;
  final bool blank;
  final bool space;
  double scale;
}

class LayoutParams {
  const LayoutParams({
    required this.layout,
    required this.regionWidth,
    required this.regionHeight,
    required this.fontPx,
    required this.tilt,
    required this.seed,
    required this.tracking,
    required this.wordGap,
    required this.lineHeight,
    required this.minAdvance,
    required this.stairStep,
    required this.padding,
  });
  final TextLayoutKind layout;
  final double regionWidth;
  final double regionHeight;
  final double fontPx;
  final double tilt;
  final String seed;
  final double tracking;
  final double wordGap;
  final double lineHeight;
  final double minAdvance;
  final double stairStep;
  final double padding;
}

class PlacedGlyph {
  PlacedGlyph({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.advance,
    required this.angle,
    required this.rotation,
    required this.boxW,
    required this.boxH,
    required this.row,
    required this.word,
    required this.blank,
  });
  final String char;
  final double x;
  final double y;
  final double size;
  final double advance;

  /// 行进方向（弧度）。
  final double angle;

  /// 字自身的旋转。
  final double rotation;
  final double boxW;
  final double boxH;
  final int row;
  final int word;
  final bool blank;
}

class LayoutRect {
  const LayoutRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
  double get cx => x + width / 2;
  double get cy => y + height / 2;
}

class TextPlacement {
  const TextPlacement({
    required this.glyphs,
    required this.rows,
    required this.fontPx,
    required this.fit,
    required this.bounds,
    required this.vertical,
  });
  final List<PlacedGlyph> glyphs;
  final List<List<int>> rows;
  final double fontPx;
  final double fit;
  final LayoutRect bounds;
  final bool vertical;
}

final Set<String> _functionWords =
    '的了在把是我你他她它们和与也就都着过吗呢吧啊呀哦被让给从向到这那之而又很のはがをにでともへやねよかな'.split('').toSet();
const Set<String> _minorLatin = <String>{
  'a',
  'an',
  'the',
  'of',
  'to',
  'in',
  'on',
  'at',
  'me',
  'my',
  'with',
  'and',
  'or',
  'is',
  'i',
  'you',
  'it',
  'by',
  'for',
};

int _lengthOf(String text) => text.runes.length;

/// 词的字号倍率：最长的实词放大，虚词缩小，其余轻微起伏。
List<double> wordScales(
  List<LayoutWordInput> words,
  double emphasis,
  String seed,
) {
  final HanabiRng rng = hanabiRng('$seed:word-scale');
  final double e = clamp01(emphasis);
  bool minor(LayoutWordInput w) =>
      w.blank ||
      (_lengthOf(w.text) == 1 && _functionWords.contains(w.text)) ||
      _minorLatin.contains(w.text.toLowerCase());
  int key = -1;
  for (int i = 0; i < words.length; i++) {
    if (minor(words[i])) continue;
    if (key < 0 || _lengthOf(words[i].text) >= _lengthOf(words[key].text)) {
      key = i;
    }
  }
  final int solid = words.where((LayoutWordInput w) => !w.blank).length;
  return <double>[
    for (int i = 0; i < words.length; i++)
      () {
        final double jitter = rng();
        final LayoutWordInput w = words[i];
        if (w.space) return 1.0;
        if (w.blank) return 1 - 0.2 * e;
        if (solid <= 1) return 1.0;
        if (i == key) return 1 + 0.8 * e;
        if (minor(w)) return math.max(0.6, 1 - 0.32 * e);
        return 1 + (jitter - 0.5) * 0.45 * e;
      }(),
  ];
}

const String _rotateInVertical = 'ー—―─～〜…‥－-_=~';

class _Unit {
  _Unit(this.glyphs, this.space, this.length, this.thickness);
  final List<int> glyphs;
  final bool space;
  final double length;
  final double thickness;
}

class _Work {
  _Work(this.size, this.advance);
  double x = 0;
  double y = 0;
  double size;
  double advance;
  double angle = 0;
  double rotation = 0;
  double boxW = 0;
  double boxH = 0;
  int row = 0;
}

(double, double) _rotate(double x, double y, double angle) {
  final double c = math.cos(angle);
  final double s = math.sin(angle);
  return (x * c - y * s, x * s + y * c);
}

List<(List<int>, bool)> _buildUnits(
  List<LayoutGlyphInput> glyphs,
  List<LayoutWordInput> words,
) {
  final List<(List<int>, bool)> units = <(List<int>, bool)>[];
  for (int index = 0; index < words.length; index++) {
    final LayoutWordInput word = words[index];
    if (word.end <= word.start) continue;
    if (word.blank && !word.space && units.isNotEmpty && !units.last.$2) {
      units.last.$1.add(index);
      continue;
    }
    units.add((<int>[index], word.space));
  }
  if (units.length > 1 &&
      !units.first.$2 &&
      units.first.$1.every((int i) => words[i].blank)) {
    final (List<int>, bool) first = units.removeAt(0);
    units[0] = (<int>[...first.$1, ...units[0].$1], false);
  }
  return <(List<int>, bool)>[
    for (final (List<int> ws, bool space) in units)
      (
        <int>[
          for (final int wi in ws)
            for (int g = words[wi].start; g < words[wi].end; g++)
              if (g < glyphs.length) g,
        ],
        space,
      ),
  ];
}

/// 把一串单元切成至多 k 行，最小化最长一行（DP）；breakPenalty[i] 是在 i 之前断开的代价。
List<List<int>> partitionRuns(
  List<(double, bool)> units,
  List<double> gaps,
  int k, [
  List<double>? breakPenalty,
]) {
  final int n = units.length;
  if (n == 0) return <List<int>>[];
  final int solidCount = units.where(((double, bool) u) => !u.$2).length;
  final int parts = math.max(1, math.min(k, solidCount == 0 ? 1 : solidCount));
  double spanLength(int from, int to) {
    int a = from;
    int b = to;
    while (a <= b && units[a].$2) {
      a++;
    }
    while (b >= a && units[b].$2) {
      b--;
    }
    double total = 0;
    for (int i = a; i <= b; i++) {
      total += units[i].$1 + (i > a ? gaps[i] : 0);
    }
    return total;
  }

  const double inf = double.infinity;
  final List<List<double>> best = <List<double>>[
    for (int p = 0; p <= parts; p++) List<double>.filled(n + 1, inf),
  ];
  final List<List<int>> cut = <List<int>>[
    for (int p = 0; p <= parts; p++) List<int>.filled(n + 1, 0),
  ];
  best[0][0] = 0;
  for (int p = 1; p <= parts; p++) {
    for (int j = 1; j <= n; j++) {
      for (int i = p - 1; i < j; i++) {
        if (best[p - 1][i] == inf) continue;
        bool solid = false;
        for (int u = i; u < j; u++) {
          if (!units[u].$2) solid = true;
        }
        if (!solid) continue;
        final double value = math.max(
          best[p - 1][i],
          spanLength(i, j - 1) +
              (i > 0 && breakPenalty != null ? breakPenalty[i] : 0),
        );
        if (value < best[p][j] - 1e-9) {
          best[p][j] = value;
          cut[p][j] = i;
        }
      }
    }
  }
  int p = parts;
  while (p > 1 && best[p][n] == inf) {
    p--;
  }
  final List<List<int>> runs = <List<int>>[];
  int j = n;
  for (int q = p; q >= 1; q--) {
    final int i = cut[q][j];
    runs.insert(0, <int>[for (int o = 0; o < j - i; o++) i + o]);
    j = i;
  }
  return runs;
}

final RegExp _kanaStart = RegExp('^[぀-ゟ゠-ヿー、。，．！？]');
final RegExp _singleKana = RegExp('^[぀-ゟ゠-ヿー]\$');

/// 排一行：glyph 的位置、字号、方向，整体适配到 regionWidth × regionHeight 并居中（left / right 贴边）。
TextPlacement layoutText(
  List<LayoutGlyphInput> inputs,
  List<LayoutWordInput> words,
  LayoutParams params,
) {
  final TextLayoutKind layout = params.layout;
  final double w0 = params.regionWidth;
  final double h0 = params.regionHeight;
  final double fontPx = params.fontPx;
  final HanabiRng rng = hanabiRng('${params.seed}:layout');
  final bool vertical =
      layout == TextLayoutKind.vertical ||
      layout == TextLayoutKind.verticalSplit;
  final int count = inputs.length;
  final List<double> sizes = <double>[
    for (final LayoutGlyphInput g in inputs)
      fontPx * (g.word < words.length ? words[g.word].scale : 1),
  ];
  final List<bool> turned = <bool>[
    for (final LayoutGlyphInput g in inputs)
      vertical && (!g.upright || _rotateInVertical.contains(g.char)),
  ];
  final List<double> along = <double>[
    for (int i = 0; i < count; i++)
      inputs[i].blank
          ? inputs[i].advance * sizes[i]
          : vertical && !turned[i]
          ? sizes[i] * (1 + params.tracking * 0.6)
          : (math.max(inputs[i].advance, vertical ? 0 : params.minAdvance) +
                    params.tracking) *
                sizes[i],
  ];
  final List<_Work> work = <_Work>[
    for (int i = 0; i < count; i++) _Work(sizes[i], along[i]),
  ];
  final List<_Unit> units = <_Unit>[
    for (final (List<int> gs, bool space) in _buildUnits(inputs, words))
      _Unit(gs, space, gs.fold(0.0, (double s, int i) => s + along[i]), () {
        final double t = gs.fold(
          0.0,
          (double m, int i) => inputs[i].blank ? m : math.max(m, sizes[i]),
        );
        return t == 0 ? fontPx : t;
      }()),
  ];
  final List<double> gaps = <double>[
    for (int i = 0; i < units.length; i++)
      i > 0 && !units[i].space && !units[i - 1].space
          ? params.wordGap * fontPx
          : 0,
  ];
  final List<double> penalties = <double>[
    for (final _Unit u in units)
      _kanaStart.hasMatch(u.glyphs.isEmpty ? '' : inputs[u.glyphs.first].char)
          ? fontPx * 1.2
          : 0,
  ];
  final List<List<int>> rows = <List<int>>[];

  double runThickness(List<int> run) {
    final double t = run.fold(
      0.0,
      (double m, int u) => math.max(m, units[u].space ? 0 : units[u].thickness),
    );
    return t == 0 ? fontPx : t;
  }

  double runLength(List<int> run) {
    int a = 0;
    int b = run.length - 1;
    while (a <= b && units[run[a]].space) {
      a++;
    }
    while (b >= a && units[run[b]].space) {
      b--;
    }
    double total = 0;
    for (int k = a; k <= b; k++) {
      total += units[run[k]].length + (k > a ? gaps[run[k]] : 0);
    }
    return total;
  }

  void flow(
    List<int> run,
    int rowIndex,
    void Function(int glyph, double s, double n) place,
  ) {
    int a = 0;
    int b = run.length - 1;
    while (a <= b && units[run[a]].space) {
      a++;
    }
    while (b >= a && units[run[b]].space) {
      b--;
    }
    final double thick = runThickness(run);
    double s = 0;
    final List<int> members = <int>[];
    for (int k = 0; k < run.length; k++) {
      final _Unit unit = units[run[k]];
      final bool outside = k < a || k > b;
      if (k > a && k <= b) s += gaps[run[k]];
      int wordStart = -1;
      int stepIndex = 0;
      for (final int glyph in unit.glyphs) {
        final double size = sizes[glyph];
        final double advance = outside ? 0 : along[glyph];
        final int word = inputs[glyph].word;
        if (word != wordStart) {
          wordStart = word;
          stepIndex = 0;
        }
        final double settle = vertical ? 0 : (thick - size) * 0.42;
        final double stair = inputs[glyph].blank
            ? 0
            : -params.stairStep * size * (stepIndex % 3);
        if (!inputs[glyph].blank) stepIndex++;
        work[glyph].row = rowIndex;
        work[glyph].advance = advance;
        place(glyph, s + advance / 2, settle + stair);
        s += advance;
        members.add(glyph);
      }
    }
    while (rows.length <= rowIndex) {
      rows.add(<int>[]);
    }
    rows[rowIndex] = members;
  }

  List<(double, bool)> unitShapes() => <(double, bool)>[
    for (final _Unit u in units) (u.length, u.space),
  ];

  List<List<int>> chooseRuns(
    int kMin,
    int kMax,
    double main,
    double cross,
    double pitch,
  ) {
    List<List<int>> bestRuns = <List<int>>[];
    double bestFit = -1;
    for (int k = kMin; k <= kMax; k++) {
      final List<List<int>> runs = partitionRuns(
        unitShapes(),
        gaps,
        k,
        penalties,
      );
      if (runs.length < math.min(k, kMin)) continue;
      final double longest = math.max(
        1,
        runs.map(runLength).fold(0.0, math.max),
      );
      final double across = runs.fold(
        0.0,
        (double s, List<int> r) => s + runThickness(r) * pitch,
      );
      final double fit = math.min(
        1,
        math.min(main / longest, cross / math.max(across, 1e-6)),
      );
      if (fit > bestFit * 1.08 || bestRuns.isEmpty) {
        bestFit = fit;
        bestRuns = runs;
      }
      if (fit >= 1) break;
    }
    return bestRuns;
  }

  final int solidUnits = units.where((_Unit u) => !u.space).length;

  List<List<int>> chunkUnits() {
    final List<List<int>> chunks = <List<int>>[];
    for (int index = 0; index < units.length; index++) {
      final _Unit unit = units[index];
      if (unit.space) continue;
      final String text = unit.glyphs.map((int g) => inputs[g].char).join();
      final bool kana = unit.glyphs.length == 1 && _singleKana.hasMatch(text);
      final int lastLength = chunks.isEmpty
          ? 0
          : chunks.last.fold(0, (int s, int u) => s + units[u].glyphs.length);
      if (chunks.isNotEmpty && kana && lastLength < 5) {
        chunks.last.add(index);
      } else {
        chunks.add(<int>[index]);
      }
    }
    return chunks;
  }

  switch (layout) {
    case TextLayoutKind.center:
    case TextLayoutKind.left:
    case TextLayoutKind.right:
    case TextLayoutKind.stagger:
    case TextLayoutKind.diagonal:
      int kMin = 1;
      int kMax = layout == TextLayoutKind.diagonal ? 2 : 3;
      if (layout == TextLayoutKind.stagger) {
        kMin = math.min(solidUnits, solidUnits >= 5 ? 3 : 2);
        kMax = math.min(solidUnits, 3);
        kMin = math.max(1, kMin);
        kMax = math.max(kMin, kMax);
      }
      final double slope = layout == TextLayoutKind.diagonal
          ? -math.min(0.42, math.max(0.2, math.atan2(h0 * 0.7, w0)))
          : 0;
      final List<List<int>> runs = chooseRuns(
        kMin,
        kMax,
        layout == TextLayoutKind.diagonal ? w0 * 0.95 : w0,
        h0,
        params.lineHeight,
      );
      final double pitchFactor = layout == TextLayoutKind.stagger
          ? params.lineHeight * 0.94
          : params.lineHeight;
      double cursorY = 0;
      final List<double> lengths = runs.map(runLength).toList();
      final double longest = math.max(1, lengths.fold(0.0, math.max));
      final double staggerAmp = fontPx * (0.9 + rng() * 0.6);
      for (int rowIndex = 0; rowIndex < runs.length; rowIndex++) {
        final List<int> run = runs[rowIndex];
        final double thick = runThickness(run);
        if (rowIndex > 0) cursorY += thick * pitchFactor * 0.5;
        final double l = lengths[rowIndex];
        double x0;
        if (layout == TextLayoutKind.left) {
          x0 = 0;
        } else if (layout == TextLayoutKind.right) {
          x0 = -l;
        } else if (layout == TextLayoutKind.stagger) {
          final double room = math.max(0, (longest - l) / 2);
          final int side = rowIndex.isEven ? -1 : 1;
          x0 =
              -l / 2 +
              side *
                  math.max(staggerAmp, room * 0.9) *
                  (runs.length == 1 ? 0 : 1);
        } else {
          x0 = -l / 2;
        }
        final double rowY = cursorY;
        flow(run, rowIndex, (int glyph, double s, double n) {
          final _Work w = work[glyph];
          if (layout == TextLayoutKind.diagonal) {
            final double x = x0 + s;
            w.x = x;
            w.y = rowY + n + (x - (x0 + l / 2)) * math.tan(slope);
            w.advance /= math.cos(slope);
            w.angle = slope;
            w.rotation = slope * 0.3;
          } else {
            w.x = x0 + s;
            w.y = rowY + n;
          }
        });
        cursorY += thick * pitchFactor * 0.5;
      }
    case TextLayoutKind.arc:
      final List<List<int>> runs = chooseRuns(
        1,
        2,
        w0 * 0.95,
        h0,
        params.lineHeight,
      );
      final List<double> lengths = runs.map(runLength).toList();
      final double longest = math.max(1, lengths.fold(0.0, math.max));
      final double radius0 = math.max(longest / 1.3, w0 * 0.62);
      double depth = 0;
      for (int rowIndex = 0; rowIndex < runs.length; rowIndex++) {
        final List<int> run = runs[rowIndex];
        final double thick = runThickness(run);
        if (rowIndex > 0) depth += thick * params.lineHeight * 0.5;
        final double r0 = math.max(radius0 - depth, longest / 2.6);
        final double l = lengths[rowIndex];
        final double centerY = radius0;
        flow(run, rowIndex, (int glyph, double s, double n) {
          final double a = (s - l / 2) / r0;
          final double r = r0 - n;
          final _Work w = work[glyph];
          w.x = r * math.sin(a);
          w.y = centerY - r * math.cos(a);
          w.angle = a;
          w.rotation = a;
        });
        depth += thick * params.lineHeight * 0.5;
      }
    case TextLayoutKind.vertical:
      final List<List<int>> runs = chooseRuns(1, 4, h0, w0, params.lineHeight);
      double cursorX = 0;
      for (int col = 0; col < runs.length; col++) {
        final List<int> run = runs[col];
        final double thick = runThickness(run);
        if (col > 0) cursorX -= thick * params.lineHeight * 0.5;
        final double colX = cursorX;
        flow(run, col, (int glyph, double s, double n) {
          final _Work w = work[glyph];
          w.x = colX - n;
          w.y = s;
          w.angle = math.pi / 2;
          w.rotation = turned[glyph] ? math.pi / 2 : 0;
        });
        cursorX -= thick * params.lineHeight * 0.5;
      }
    case TextLayoutKind.verticalSplit:
      final List<List<int>> chunks = chunkUnits();
      final List<double> lengths = chunks.map(runLength).toList();
      double estimate(int groups) {
        final int per = (chunks.length / groups).ceil();
        double m = 1;
        for (int g = 0; g < groups; g++) {
          double sum = 0;
          for (
            int i = g * per;
            i < math.min(lengths.length, (g + 1) * per);
            i++
          ) {
            sum += lengths[i] * 0.6;
          }
          m = math.max(m, sum);
        }
        return m;
      }

      int groups = 1;
      while (groups < 3 &&
          estimate(groups) > h0 &&
          chunks.length > groups * 2) {
        groups++;
      }
      final int per = chunks.isEmpty ? 1 : (chunks.length / groups).ceil();
      double cursorX = 0;
      int runIndex = 0;
      for (int g = 0; g < groups; g++) {
        final int from = math.min(chunks.length, g * per);
        final int to = math.min(chunks.length, (g + 1) * per);
        final List<List<int>> members = chunks.sublist(from, to);
        final List<double> memberLengths = lengths.sublist(from, to);
        if (members.isEmpty) continue;
        final double thick = members.map(runThickness).reduce(math.max);
        final double pitch = thick * params.lineHeight;
        if (g > 0) cursorX -= pitch * 1.1;
        final List<double> tops = <double>[];
        final List<double> ends = <double>[];
        for (int k = 0; k < members.length; k++) {
          final double side = k.isEven ? 0.5 : -0.5;
          double top = 0;
          if (k >= 1) {
            top = math.max(top, tops[k - 1] + memberLengths[k - 1] * 0.5);
          }
          if (k >= 2) top = math.max(top, ends[k - 2] + fontPx * 0.2);
          tops.add(top);
          ends.add(top + memberLengths[k]);
          final double colX =
              cursorX +
              side * pitch * (members.length > 1 ? 1 : 0) -
              pitch * 0.5;
          flow(members[k], runIndex, (int glyph, double s, double n) {
            final _Work w = work[glyph];
            w.x = colX - n;
            w.y = top + s;
            w.angle = math.pi / 2;
            w.rotation = turned[glyph] ? math.pi / 2 : 0;
          });
          runIndex++;
        }
        cursorX -= pitch;
      }
    case TextLayoutKind.scatter:
      final List<List<int>> chunks = chunkUnits();
      final double pad = params.padding * fontPx;
      final List<double> extra = <double>[
        for (int i = 0; i < chunks.length; i++) 0.8 + rng() * 0.5,
      ];
      final List<double> rotations = <double>[
        for (int i = 0; i < chunks.length; i++) (rng() - 0.5) * 0.16,
      ];
      final List<double> gapsAfter = <double>[
        for (int i = 0; i < chunks.length; i++) fontPx * (0.35 + rng() * 0.8),
      ];
      final List<double> jitterRand = <double>[
        for (int i = 0; i < chunks.length; i++) rng() * 2 - 1,
      ];
      final List<(double, double)> dims = <(double, double)>[
        for (int k = 0; k < chunks.length; k++)
          () {
            final double w = runLength(chunks[k]) * extra[k] + pad * 2;
            final double h =
                runThickness(chunks[k]) *
                    extra[k] *
                    (1.12 + params.stairStep * 4) +
                pad * 2;
            final double c = math.cos(rotations[k]).abs();
            final double s = math.sin(rotations[k]).abs();
            return (w * c + h * s, w * s + h * c);
          }(),
      ];
      final int n = chunks.length;
      List<List<int>> bestRows = <List<int>>[];
      double bestScore = double.negativeInfinity;
      double rowWidth(List<int> row) {
        double sum = 0;
        for (int i = 0; i < row.length; i++) {
          sum += dims[row[i]].$1 + (i > 0 ? gapsAfter[row[i] - 1] : 0);
        }
        return sum;
      }

      for (int r = 1; r <= math.min(4, n); r++) {
        final List<List<int>> rowsOf = partitionRuns(
          <(double, bool)>[
            for (final (double, double) d in dims) (d.$1, false),
          ],
          <double>[
            for (int k = 0; k < dims.length; k++) k > 0 ? gapsAfter[k - 1] : 0,
          ],
          r,
        );
        final List<double> widths = rowsOf.map(rowWidth).toList();
        final double heights = rowsOf.fold(
          0.0,
          (double s, List<int> row) =>
              s + row.map((int k) => dims[k].$2).reduce(math.max) * 1.5,
        );
        final double fit = math.min(
          1,
          math.min(w0 / widths.reduce(math.max), h0 / heights),
        );
        final double score =
            fit +
            (n >= 3 && rowsOf.length >= 2 ? 0.08 : 0) +
            (rowsOf.length == math.min(3, n) ? 0.04 : 0);
        if (score > bestScore) {
          bestScore = score;
          bestRows = rowsOf;
        }
      }
      final List<double> rowHeights = <double>[
        for (final List<int> row in bestRows)
          row.map((int k) => dims[k].$2).reduce(math.max),
      ];
      final List<double> widths = bestRows.map(rowWidth).toList();
      final double widest = math.max(1, widths.fold(0.0, math.max));
      double cursorY = 0;
      for (int r = 0; r < bestRows.length; r++) {
        final List<int> row = bestRows[r];
        final double rowH = rowHeights[r];
        final double jitter = rowH * 0.22;
        if (r > 0) {
          cursorY +=
              rowHeights[r - 1] / 2 +
              rowH / 2 +
              (rowHeights[r - 1] * 0.22 + jitter) +
              fontPx * 0.1;
        }
        final double slack = math.max(0, widest - widths[r]);
        double cursorX =
            -widths[r] / 2 +
            (rng() - 0.5) *
                (slack + fontPx * 1.2) *
                (bestRows.length > 1 ? 1 : 0);
        for (int i = 0; i < row.length; i++) {
          final int k = row[i];
          if (i > 0) cursorX += gapsAfter[k - 1];
          final (double aabbW, double aabbH) = dims[k];
          final double cx = cursorX + aabbW / 2;
          final double cy =
              cursorY + jitterRand[k] * (jitter + (rowH - aabbH) * 0.5);
          cursorX += aabbW;
          final List<int> chunk = chunks[k];
          final double l = runLength(chunk) * extra[k];
          final double angle = rotations[k];
          flow(chunk, k, (int glyph, double s, double nOffset) {
            final _Work w = work[glyph];
            final (double lx, double ly) = _rotate(
              s * extra[k] - l / 2,
              nOffset * extra[k],
              angle,
            );
            w.x = cx + lx;
            w.y = cy + ly;
            w.angle = angle;
            w.rotation = angle;
            w.size = sizes[glyph] * extra[k];
            w.advance *= extra[k];
          });
        }
      }
  }
  if (layout == TextLayoutKind.scatter ||
      layout == TextLayoutKind.verticalSplit) {
    for (final _Unit unit in units) {
      if (!unit.space) continue;
      for (final int glyph in unit.glyphs) {
        final _Work prev = work[math.max(0, glyph - 1)];
        final _Work w = work[glyph];
        w.x = prev.x;
        w.y = prev.y;
        w.angle = prev.angle;
        w.rotation = prev.rotation;
        w.advance = 0;
        w.row = prev.row;
      }
    }
  }
  for (int i = 0; i < count; i++) {
    final _Work w = work[i];
    final bool verticalUpright = vertical && !turned[i];
    w.boxW = verticalUpright ? w.size * 1.12 : math.max(w.advance, 0.01);
    w.boxH = verticalUpright ? math.max(w.advance, 0.01) : w.size * 1.12;
    if (layout == TextLayoutKind.diagonal) {
      w.boxW = math.max(w.advance * math.cos(w.angle), 0.01);
    }
  }
  if (params.tilt != 0) {
    for (final _Work w in work) {
      final (double x, double y) = _rotate(w.x, w.y, params.tilt);
      w.x = x;
      w.y = y;
      w.angle += params.tilt;
      w.rotation += params.tilt;
    }
  }
  (double, double, double, double) measure() {
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < count; i++) {
      if (inputs[i].blank) continue;
      final _Work w = work[i];
      final double pad = params.padding * w.size;
      final double hw = w.boxW / 2 + pad;
      final double hh = w.boxH / 2 + pad;
      final double c = math.cos(w.rotation).abs();
      final double s = math.sin(w.rotation).abs();
      final double ex = hw * c + hh * s;
      final double ey = hw * s + hh * c;
      minX = math.min(minX, w.x - ex);
      maxX = math.max(maxX, w.x + ex);
      minY = math.min(minY, w.y - ey);
      maxY = math.max(maxY, w.y + ey);
    }
    if (!minX.isFinite) return (0, 0, 0, 0);
    return (minX, minY, maxX, maxY);
  }

  var (double minX, double minY, double maxX, double maxY) = measure();
  final double fit = math.min(
    1,
    math.min(
      w0 / math.max(1e-6, maxX - minX),
      h0 / math.max(1e-6, maxY - minY),
    ),
  );
  if (fit < 1) {
    for (final _Work w in work) {
      w.x *= fit;
      w.y *= fit;
      w.size *= fit;
      w.advance *= fit;
      w.boxW *= fit;
      w.boxH *= fit;
    }
    (minX, minY, maxX, maxY) = measure();
  }
  final double shiftX = layout == TextLayoutKind.left
      ? -w0 / 2 - minX
      : layout == TextLayoutKind.right
      ? w0 / 2 - maxX
      : -(minX + maxX) / 2;
  final double shiftY = -(minY + maxY) / 2;
  return TextPlacement(
    glyphs: <PlacedGlyph>[
      for (int i = 0; i < count; i++)
        PlacedGlyph(
          char: inputs[i].char,
          x: work[i].x + shiftX,
          y: work[i].y + shiftY,
          size: work[i].size,
          advance: work[i].advance,
          angle: work[i].angle,
          rotation: work[i].rotation,
          boxW: work[i].boxW,
          boxH: work[i].boxH,
          row: work[i].row,
          word: inputs[i].word,
          blank: inputs[i].blank,
        ),
    ],
    rows: <List<int>>[
      for (final List<int> run in rows)
        if (run.isNotEmpty)
          <int>[
            for (final int i in run)
              if (i < count) i,
          ],
    ],
    fontPx: fontPx * fit,
    fit: fit,
    bounds: LayoutRect(minX + shiftX, minY + shiftY, maxX - minX, maxY - minY),
    vertical: vertical,
  );
}

// ─── 字形（glyphs.ts）─────────────────────────────────────────────────

final RegExp _upright = RegExp(
  '[ᄀ-ᇿ⺀-⿿　-〿぀-ヿ㄀-ㇿ㈀-鿿가-힯豈-﫿︰-﹏＀-￯]|[\u{20000}-\u{3134f}]',
  unicode: true,
);

/// 竖排时正立的字（CJK、全角）。
bool isUprightGlyph(String char) => _upright.hasMatch(char);

bool hasCjkText(String text) => _upright.hasMatch(text);

const String _scrambleKana =
    'アイウエオカキクケコサシスセソタチツテトナニヌネハヒフヘホマミムメモヤユヨラリルレロワヲン＃％＆＊？！◆※';
const String _scrambleLatin = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%&*?!<>/+=';

/// 乱码入场用的字池。
List<String> pickScrambleChars(String text, int count, HanabiRng random) {
  final List<String> pool = (hasCjkText(text) ? _scrambleKana : _scrambleLatin)
      .split('');
  final List<String> picked = <String>[];
  while (picked.length < count && pool.isNotEmpty) {
    picked.add(pool.removeAt((random() * pool.length).floor()));
  }
  return picked;
}
