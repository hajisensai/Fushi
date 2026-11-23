/// 心象（folia cadenza）的一行准备：选字号 → 测量换行 → 切成按词、按行的片段 → 算每个
/// 片段的落点（强调词居中放大，其余绕开它、彼此不重叠地散开）。对应 folia
/// `cadenzaPreparedState.ts` / `cadenzaFragments.ts` / `cadenzaPlacements.ts`。
///
/// 纯 Dart：文字宽度经 [MindscapeMeasure] 注入（运行时是 TextPainter，单测用假尺子），
/// 整个模式最贵的一步，结果按行缓存。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_timing.dart';

/// 量一段文字在给定字号下的排版宽度（逻辑像素）。
typedef MindscapeMeasure = double Function(String text, double fontPx);

final RegExp _cjkPattern = RegExp('[一-龥぀-ヿ가-힯]');

/// 含 CJK（folia `isCJK`：任一字命中即算）。
bool mindscapeContainsCjk(String text) => _cjkPattern.hasMatch(text);

/// 不该出现在行首的标点（简单避头，pretext 也会把它们黏在前一行）。
const String _noLineStart = '、。，．,.!！?？:：;；)）」』】〉》〕］]}｝…ーっゃゅょァィゥェォッャュョぁぃぅぇぉ・';

/// 行里的一个词：在字形流里的区间 + 时间。
class MindscapeSourceWord {
  const MindscapeSourceWord({
    required this.text,
    required this.start,
    required this.end,
    required this.time,
    required this.glyphTimes,
  });

  final String text;

  /// 在 [MindscapeSourceLine.graphemes] 里的 [start, end)。
  final int start;
  final int end;
  final MindscapeWordTime time;

  /// 词内每个字形的时间（秒）。
  final List<MindscapeGlyphTime> glyphTimes;

  int get graphemeCount => math.max(end - start, 1);
}

/// 一行歌词的布局输入。
class MindscapeSourceLine {
  const MindscapeSourceLine({
    required this.lineIndex,
    required this.text,
    required this.graphemes,
    required this.words,
    required this.timing,
    required this.isInterlude,
    required this.isChorus,
  });

  /// 运行时行下标（缓存键 / 动画状态键）。
  final int lineIndex;
  final String text;
  final List<String> graphemes;
  final List<MindscapeSourceWord> words;
  final MindscapeLineTiming timing;

  /// 「......」间奏行：不选强调词，漂移更轻。
  final bool isInterlude;

  /// 副歌行（共享歌曲结构 `LyricVisualizerLine.isChorus`）：唱到时画一圈涟漪。
  final bool isChorus;
}

/// 从运行时行建布局输入。逐字歌词直接用音节拆出的字形；行级歌词由运行时按行时长均分。
MindscapeSourceLine mindscapeSourceOf(LyricVisualizerLine line) {
  List<LyricVisualizerGlyph> glyphs = line.glyphs;
  List<LyricVisualizerWord> words = line.words;
  if (glyphs.isEmpty) {
    // 没有音节信息：按整行均分出字形，再按通用规则拆词。
    final List<String> chars = line.text.characters.toList();
    final int voiced = chars.where((String c) => c.trim().isNotEmpty).length;
    final double step = voiced == 0 ? 0 : line.durationMs / voiced;
    int k = 0;
    glyphs = <LyricVisualizerGlyph>[
      for (final String c in chars)
        () {
          final bool space = c.trim().isEmpty;
          final int s = (line.startMs + step * k).round();
          final int e = space ? s : (line.startMs + step * (k + 1)).round();
          if (!space) k++;
          return LyricVisualizerGlyph(
            text: c,
            startMs: s,
            endMs: e,
            syllableIndex: 0,
            isSpace: space,
          );
        }(),
    ];
    words = buildLyricVisualizerWords(glyphs);
  }
  // 掐掉首尾空白字形（folia 的 fullText 是 trim 过的）。
  int lo = 0;
  int hi = glyphs.length;
  while (lo < hi && glyphs[lo].isSpace) {
    lo++;
  }
  while (hi > lo && glyphs[hi - 1].isSpace) {
    hi--;
  }
  final List<String> graphemes = <String>[
    for (int i = lo; i < hi; i++) glyphs[i].text,
  ];
  final List<MindscapeSourceWord> sourceWords = <MindscapeSourceWord>[];
  for (final LyricVisualizerWord w in words) {
    final int start = (w.firstGlyph - lo).clamp(0, graphemes.length);
    final int end = (w.firstGlyph + w.glyphCount - lo).clamp(
      start,
      graphemes.length,
    );
    if (end <= start) continue;
    sourceWords.add(
      MindscapeSourceWord(
        text: w.text,
        start: start,
        end: end,
        time: MindscapeWordTime(w.startMs / 1000, w.endMs / 1000),
        glyphTimes: <MindscapeGlyphTime>[
          for (int i = w.firstGlyph; i < w.firstGlyph + w.glyphCount; i++)
            MindscapeGlyphTime(
              glyphs[i].startMs / 1000,
              glyphs[i].endMs / 1000,
            ),
        ],
      ),
    );
  }
  final double lastWordEnd = sourceWords.isEmpty
      ? line.endMs / 1000
      : sourceWords.last.time.endTime;
  final String text = graphemes.join();
  return MindscapeSourceLine(
    lineIndex: line.position,
    text: text,
    graphemes: graphemes,
    words: sourceWords,
    timing: mindscapeLineTimingOf(
      line.renderHints,
      startTime: line.startMs / 1000,
      endTime: line.endMs / 1000,
      lastWordEndTime: lastWordEnd,
    ),
    isInterlude: text == '......',
    isChorus: line.isChorus,
  );
}

/// 字号（folia `chooseFontPx`）：随屏宽，字多 / 词多时收小。
double mindscapeChooseFontPx(double width, int graphemeCount, int wordCount) {
  final int g = graphemeCount <= 0 ? 1 : graphemeCount;
  final int w = wordCount <= 0 ? 1 : wordCount;
  final double widthBase = mindscapeClamp(width * 0.086, 34, 94);
  final double lengthPenalty = g > 12 ? math.min((g - 12) * 1.8, 34) : 0;
  final double densityPenalty = w > 7 ? math.min((w - 7) * 1.5, 18) : 0;
  return mindscapeClamp(widthBase - lengthPenalty - densityPenalty, 28, 104);
}

/// 换行后的一行：字形区间与内容宽度（行尾空白不算）。
class MindscapeLayoutLine {
  const MindscapeLayoutLine(this.start, this.end, this.width);

  final int start;
  final int end;
  final double width;
}

class _Unit {
  _Unit(this.start, this.end, this.isSpace);

  final int start;
  final int end;
  final bool isSpace;
  double width = 0;
}

/// 测量 + 换行的结果：每个字形的前缀横坐标与各行区间。
class MindscapeTextLayout {
  const MindscapeTextLayout({required this.prefixX, required this.lines});

  /// `prefixX[i]` = 第 i 个字形左边缘距整段起点的宽度（长度 = 字形数 + 1）。
  final List<double> prefixX;
  final List<MindscapeLayoutLine> lines;

  double widthBetween(int a, int b) => b <= a ? 0 : prefixX[b] - prefixX[a];
}

bool _isSpaceGrapheme(String g) => g.trim().isEmpty;

/// 把字形流切成换行单位（空白串 / 拉丁连写词 / 单个 CJK 字），量宽，再贪心换行。
/// 超宽的单个词在字形处断开（pretext 的 breakable segment）。
MindscapeTextLayout mindscapeLayoutText(
  List<String> graphemes,
  double fontPx,
  double maxWidth,
  MindscapeMeasure measure,
) {
  final List<_Unit> units = <_Unit>[];
  int i = 0;
  while (i < graphemes.length) {
    final String g = graphemes[i];
    if (_isSpaceGrapheme(g)) {
      int j = i + 1;
      while (j < graphemes.length && _isSpaceGrapheme(graphemes[j])) {
        j++;
      }
      units.add(_Unit(i, j, true));
      i = j;
    } else if (lyricVisualizerIsCjk(g)) {
      units.add(_Unit(i, i + 1, false));
      i++;
    } else {
      int j = i + 1;
      while (j < graphemes.length &&
          !_isSpaceGrapheme(graphemes[j]) &&
          !lyricVisualizerIsCjk(graphemes[j])) {
        j++;
      }
      units.add(_Unit(i, j, false));
      i = j;
    }
  }
  // 每个字形的步进：单位整体量一次（保住字距），按字形各自宽度比例分摊。
  final List<double> advances = List<double>.filled(graphemes.length, 0);
  final Map<String, double> cache = <String, double>{};
  double m(String s) => cache[s] ??= measure(s, fontPx);
  for (final _Unit u in units) {
    final String text = graphemes.sublist(u.start, u.end).join();
    u.width = m(text);
    if (u.end - u.start == 1) {
      advances[u.start] = u.width;
      continue;
    }
    double sum = 0;
    for (int k = u.start; k < u.end; k++) {
      advances[k] = m(graphemes[k]);
      sum += advances[k];
    }
    if (sum > 0) {
      final double f = u.width / sum;
      for (int k = u.start; k < u.end; k++) {
        advances[k] *= f;
      }
    }
  }
  final List<double> prefix = List<double>.filled(graphemes.length + 1, 0);
  for (int k = 0; k < graphemes.length; k++) {
    prefix[k + 1] = prefix[k] + advances[k];
  }

  final List<MindscapeLayoutLine> lines = <MindscapeLayoutLine>[];
  int lineStart = 0;
  double cur = 0;
  double pending = 0;
  bool hasContent = false;
  void push(int end) {
    lines.add(MindscapeLayoutLine(lineStart, end, cur));
    lineStart = end;
    cur = 0;
    pending = 0;
    hasContent = false;
  }

  for (final _Unit u in units) {
    if (u.isSpace) {
      if (hasContent) pending += u.width;
      continue;
    }
    final bool glued =
        u.end - u.start == 1 && _noLineStart.contains(graphemes[u.start]);
    if (hasContent && !glued && cur + pending + u.width > maxWidth) {
      push(u.start);
    }
    if (u.width > maxWidth && u.end - u.start > 1) {
      for (int k = u.start; k < u.end; k++) {
        if (hasContent && cur + pending + advances[k] > maxWidth) push(k);
        cur += pending + advances[k];
        pending = 0;
        hasContent = true;
      }
    } else {
      cur += pending + u.width;
      pending = 0;
      hasContent = true;
    }
  }
  if (hasContent || lines.isEmpty) {
    lines.add(MindscapeLayoutLine(lineStart, graphemes.length, cur));
  } else if (lines.isNotEmpty && lineStart < graphemes.length) {
    // 只剩行尾空白：并进上一行。
    final MindscapeLayoutLine last = lines.removeLast();
    lines.add(MindscapeLayoutLine(last.start, graphemes.length, last.width));
  }
  return MindscapeTextLayout(prefixX: prefix, lines: lines);
}

/// 一个词落在某一换行行里的片段（folia `WordFragment`）。
class MindscapeFragment {
  MindscapeFragment({
    required this.wordIndex,
    required this.lineIndex,
    required this.word,
    required this.text,
    required this.startX,
    required this.endX,
    required this.fragmentStartInWord,
    required this.fragmentEndInWord,
  });

  final int wordIndex;
  final int lineIndex;
  final MindscapeSourceWord word;
  final String text;
  final double startX;
  final double endX;
  final int fragmentStartInWord;
  final int fragmentEndInWord;
  int fragmentIndexInWord = 0;
  int fragmentCountInWord = 1;

  bool get isPrimaryFragment => fragmentIndexInWord == 0;
  bool get isSplitAcrossLines => fragmentCountInWord > 1;
}

/// 按换行行切片段（folia `buildLineFragments`）：被折行切开的词拆成几片，各记序号。
List<List<MindscapeFragment>> mindscapeBuildFragments(
  MindscapeSourceLine source,
  MindscapeTextLayout layout,
) {
  final List<List<MindscapeFragment>> out = <List<MindscapeFragment>>[];
  final Map<int, int> countByWord = <int, int>{};
  for (int li = 0; li < layout.lines.length; li++) {
    final MindscapeLayoutLine line = layout.lines[li];
    final List<MindscapeFragment> frags = <MindscapeFragment>[];
    for (int wi = 0; wi < source.words.length; wi++) {
      final MindscapeSourceWord w = source.words[wi];
      if (w.end <= line.start || w.start >= line.end) continue;
      final int fs = math.max(w.start, line.start);
      final int fe = math.min(w.end, line.end);
      frags.add(
        MindscapeFragment(
          wordIndex: wi,
          lineIndex: li,
          word: w,
          text: source.graphemes.sublist(fs, fe).join(),
          startX: layout.widthBetween(line.start, fs),
          endX: layout.widthBetween(line.start, fe),
          fragmentStartInWord: fs - w.start,
          fragmentEndInWord: fe - w.start,
        ),
      );
      countByWord[wi] = (countByWord[wi] ?? 0) + 1;
    }
    out.add(frags);
  }
  final Map<int, int> seen = <int, int>{};
  for (final List<MindscapeFragment> frags in out) {
    for (final MindscapeFragment f in frags) {
      f.fragmentCountInWord = countByWord[f.wordIndex] ?? 1;
      f.fragmentIndexInWord = seen[f.wordIndex] ?? 0;
      seen[f.wordIndex] = f.fragmentIndexInWord + 1;
    }
  }
  return out;
}

/// 强调词（folia `buildEmphasisMap`）：完整、非空的主片段里，CJK 词或较长的拉丁词、越靠中间
/// 越优先，只选一个当「主角」，权重 1.46×（分高再加成）。
Map<int, double> mindscapeEmphasisMap(
  List<List<MindscapeFragment>> lines,
  bool isInterlude,
) {
  final Map<int, double> map = <int, double>{};
  if (isInterlude) return map;
  final List<MindscapeFragment> primary = <MindscapeFragment>[
    for (final List<MindscapeFragment> l in lines)
      for (final MindscapeFragment f in l)
        if (f.isPrimaryFragment) f,
  ];
  MindscapeFragment? hero;
  double heroScore = double.negativeInfinity;
  for (final MindscapeFragment f in primary) {
    if (f.isSplitAcrossLines || f.text.trim().isEmpty) continue;
    final int count = math.max(
      math.max(f.word.graphemeCount, f.word.text.characters.length),
      1,
    );
    final double semantic = mindscapeContainsCjk(f.word.text)
        ? 0.18
        : math.min(count * 0.08, 0.36);
    final double centerBias =
        1 -
        (f.wordIndex - (primary.length - 1) / 2).abs() /
            math.max(primary.length, 1);
    final double score = semantic + centerBias * 0.18;
    // 同分取先出现的（folia 的稳定排序）。
    if (score > heroScore) {
      hero = f;
      heroScore = score;
    }
  }
  if (hero != null) {
    final double boost = 1 + mindscapeClamp(heroScore - 0.48, 0, 0.52);
    map[hero.wordIndex] = 1.46 * boost;
  }
  return map;
}

/// 一个片段在屏幕上的落点（相对焦点，folia `WordPlacement`）。`y` 是基线。
class MindscapePlacement {
  const MindscapePlacement({
    required this.wordIndex,
    required this.word,
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    required this.passedRotate,
    required this.passedDriftX,
    required this.passedDriftY,
    required this.fragmentStartInWord,
    required this.wordGraphemeCount,
    required this.emphasis,
    required this.isInterlude,
  });

  final int wordIndex;
  final MindscapeSourceWord word;
  final String text;
  final double x;
  final double y;
  final double width;
  final double height;
  final double scale;

  /// 唱过后转到的角度（度）。
  final double passedRotate;
  final double passedDriftX;
  final double passedDriftY;
  final int fragmentStartInWord;
  final int wordGraphemeCount;
  final double emphasis;
  final bool isInterlude;
}

class _Rect {
  const _Rect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;
}

class _Plan {
  _Plan({
    required this.fragment,
    required this.lineIndex,
    required this.fragmentIndex,
    required this.order,
    required this.baseX,
    required this.baseY,
    required this.emphasis,
    required this.width,
    required this.height,
    required this.scale,
    required this.collisionWidth,
    required this.collisionHeight,
    required this.padding,
  });

  final MindscapeFragment fragment;
  final int lineIndex;
  final int fragmentIndex;
  final int order;
  final double baseX;
  final double baseY;
  final double emphasis;
  final double width;
  final double height;
  final double scale;
  final double collisionWidth;
  final double collisionHeight;
  final double padding;
}

/// 片段 → 落点（folia `buildWordPlacements`）：主角放在焦点正中，其他片段从排版位置出发，
/// 先被推离主角，再沿同心椭圆找第一个不与已放片段重叠的位置（找不到取重叠最少的）。
/// 唱过后的漂移方向 = 从焦点向外，幅度与转角由行种子确定。
List<MindscapePlacement> mindscapeBuildPlacements({
  required List<List<MindscapeFragment>> lineFragments,
  required List<MindscapeLayoutLine> layoutLines,
  required double fontPx,
  required double lineHeight,
  required double maxWidth,
  required LyricVisualizerIntensity intensity,
  required double seed,
  required bool isInterlude,
}) {
  final double totalHeight = math.max(lineFragments.length, 1) * lineHeight;
  final double baseMargin = intensity == LyricVisualizerIntensity.calm ? 4 : 6;
  final double baseScale = switch (intensity) {
    LyricVisualizerIntensity.chaotic => 1.02,
    LyricVisualizerIntensity.calm => 1,
    LyricVisualizerIntensity.normal => 1.01,
  };
  final Map<int, double> emphasisMap = mindscapeEmphasisMap(
    lineFragments,
    isInterlude,
  );
  int? heroWordIndex;
  double heroEmphasis = double.negativeInfinity;
  emphasisMap.forEach((int k, double v) {
    if (v > heroEmphasis) {
      heroEmphasis = v;
      heroWordIndex = k;
    }
  });

  final List<_Plan> plans = <_Plan>[];
  for (int li = 0; li < lineFragments.length; li++) {
    final double lineLeft = -layoutLines[li].width / 2;
    final double baselineY = -totalHeight / 2 + fontPx + li * lineHeight;
    final List<MindscapeFragment> frags = lineFragments[li];
    for (int fi = 0; fi < frags.length; fi++) {
      final MindscapeFragment f = frags[fi];
      final double emphasis = emphasisMap[f.wordIndex] ?? 1;
      final double width = math.max(f.endX - f.startX, fontPx * 0.18);
      final double scale = emphasis > 1 ? baseScale * emphasis : baseScale;
      final double height = fontPx * scale * 0.95;
      plans.add(
        _Plan(
          fragment: f,
          lineIndex: li,
          fragmentIndex: fi,
          order: plans.length,
          baseX: lineLeft + f.startX,
          baseY: baselineY,
          emphasis: emphasis,
          width: width,
          height: height,
          scale: scale,
          collisionWidth: width * scale * (emphasis > 1 ? 1.48 : 1.26),
          collisionHeight: height * (emphasis > 1 ? 1.36 : 1.24),
          padding: baseMargin + (emphasis > 1 ? 10 : 2),
        ),
      );
    }
  }
  plans.sort((_Plan a, _Plan b) {
    final double d = b.emphasis - a.emphasis;
    if (d.abs() > 0.001) return d > 0 ? 1 : -1;
    if (a.lineIndex != b.lineIndex) return a.lineIndex - b.lineIndex;
    final int x = a.fragment.startX.compareTo(b.fragment.startX);
    return x != 0 ? x : a.order - b.order;
  });

  _Plan? heroPlan;
  if (heroWordIndex != null) {
    for (final _Plan p in plans) {
      if (p.fragment.wordIndex == heroWordIndex) {
        heroPlan = p;
        break;
      }
    }
  }
  final double? heroCenterX = heroPlan == null
      ? null
      : heroPlan.width * heroPlan.scale / 2;
  final double heroCenterY = heroPlan == null ? 0 : -heroPlan.height * 0.46;
  final double heroWidth = heroPlan == null
      ? 0
      : heroPlan.width * heroPlan.scale;

  final List<_Rect> occupied = <_Rect>[];
  ({bool intersects, double area}) collide(
    double l,
    double t,
    double r,
    double b,
  ) {
    bool hit = false;
    double area = 0;
    for (final _Rect o in occupied) {
      final double w = math.min(r, o.right) - math.max(l, o.left);
      if (w <= 0) continue;
      final double h = math.min(b, o.bottom) - math.max(t, o.top);
      if (h <= 0) continue;
      hit = true;
      area += w * h;
    }
    return (intersects: hit, area: area);
  }

  void occupy(double x, double y, double w, double h, double pad) {
    occupied.add(_Rect(x - pad, y - h - pad, x + w + pad, y + pad));
  }

  final List<MindscapePlacement> out = <MindscapePlacement>[];
  for (final _Plan plan in plans) {
    final MindscapeFragment f = plan.fragment;
    final double wordSeed =
        seed + f.wordIndex * 17 + plan.lineIndex * 31 + plan.fragmentIndex * 13;
    double random(double offset) {
      final double x = math.sin(wordSeed + offset) * 10000;
      return x - x.floorToDouble();
    }

    final double passedRotate =
        (random(3) - 0.5) *
        (intensity == LyricVisualizerIntensity.chaotic ? 20 : 12);
    final double step = math.max(10, (fontPx * 0.14).roundToDouble());
    final double maxRadius = plan.emphasis > 1
        ? math.max(20, lineHeight * 0.5)
        : math.max(math.max(lineHeight * 2.2, plan.collisionWidth * 0.75), 56);
    double preferredX = plan.emphasis > 1 ? -plan.width / 2 : plan.baseX;
    double preferredY = plan.emphasis > 1 ? 0 : plan.baseY;

    if (!isInterlude && plan.emphasis <= 1 && heroCenterX != null) {
      final double cx = preferredX + plan.width / 2;
      final double cy = preferredY - plan.height * 0.46;
      double dx = cx - heroCenterX;
      double dy = cy - heroCenterY;
      final double distance = math.sqrt(dx * dx + dy * dy);
      if (distance < 1) {
        dx = preferredX >= 0 ? 1 : -1;
        dy = plan.lineIndex.isEven ? -0.65 : 0.65;
      }
      final double minSeparation =
          heroWidth * 0.34 + plan.width * 0.52 + plan.padding * 2;
      if (distance < minSeparation) {
        final double n = math.max(math.sqrt(dx * dx + dy * dy), 1);
        final double push = minSeparation - distance;
        preferredX += dx / n * push;
        preferredY += dy / n * push * 0.92;
      }
    }

    final double hMin = -maxWidth / 2 - 72;
    final double hMax = maxWidth / 2 + 72;
    final double vMin = -math.max(totalHeight * 0.9, lineHeight * 1.6);
    final double vMax = math.max(totalHeight * 0.9, lineHeight * 1.45);
    double chosenX = preferredX;
    double chosenY = preferredY;
    bool found = false;
    double bestX = preferredX;
    double bestY = preferredY;
    double bestScore = double.infinity;
    final double baseAngle = heroCenterX != null && plan.emphasis <= 1
        ? math.atan2(preferredY, preferredX + plan.width / 2)
        : 0;

    for (double radius = 0; radius <= maxRadius && !found; radius += step) {
      final int samples = radius == 0
          ? 1
          : plan.emphasis > 1
          ? 8
          : math.max(
              12,
              ((math.pi * 2 * radius) / math.max(step * 1.1, 10)).round(),
            );
      for (int s = 0; s < samples; s++) {
        double dx = 0;
        double dy = 0;
        if (radius > 0) {
          final double angle = baseAngle + s / samples * math.pi * 2;
          dx = math.cos(angle) * radius;
          dy = math.sin(angle) * radius * (plan.emphasis > 1 ? 0.8 : 0.92);
        }
        final double left = preferredX + dx - plan.padding;
        final double top =
            preferredY + dy - plan.collisionHeight - plan.padding;
        final double right = left + plan.collisionWidth + plan.padding * 2;
        final double bottom = top + plan.collisionHeight + plan.padding * 2;
        if (left < hMin || right > hMax || top < vMin || bottom > vMax) {
          continue;
        }
        final ({bool intersects, double area}) c = collide(
          left,
          top,
          right,
          bottom,
        );
        final double score = c.area * 2.2 + math.sqrt(dx * dx + dy * dy);
        if (score < bestScore) {
          bestScore = score;
          bestX = preferredX + dx;
          bestY = preferredY + dy;
        }
        if (!c.intersects) {
          chosenX = preferredX + dx;
          chosenY = preferredY + dy;
          occupy(
            chosenX,
            chosenY,
            plan.collisionWidth,
            plan.collisionHeight,
            plan.padding,
          );
          found = true;
          break;
        }
      }
    }
    if (!found) {
      chosenX = bestX;
      chosenY = bestY;
      occupy(
        chosenX,
        chosenY,
        plan.collisionWidth,
        plan.collisionHeight,
        plan.padding,
      );
    }

    final double ox = chosenX + plan.width / 2;
    final double oy = chosenY - plan.height * 0.46;
    final double olen = math.max(math.sqrt(ox * ox + oy * oy), 1);
    final double drift = isInterlude
        ? 3 + random(6) * 3
        : plan.emphasis > 1
        ? 4 + random(6) * 4
        : intensity == LyricVisualizerIntensity.chaotic
        ? 8 + random(6) * 9
        : 5 + random(6) * 6;

    out.add(
      MindscapePlacement(
        wordIndex: f.wordIndex,
        word: f.word,
        text: f.text,
        x: chosenX,
        y: chosenY,
        width: plan.width,
        height: plan.height,
        scale: plan.scale,
        passedRotate: passedRotate,
        passedDriftX: ox / olen * drift + (random(7) - 0.5) * 2.4,
        passedDriftY: oy / olen * drift * 0.72 + (random(8) - 0.5) * 2,
        fragmentStartInWord: f.fragmentStartInWord,
        wordGraphemeCount: f.word.graphemeCount,
        emphasis: plan.emphasis,
        isInterlude: isInterlude,
      ),
    );
  }
  return out;
}

/// 一行准备好的全部布局（folia `PreparedState`）。
class MindscapePrepared {
  const MindscapePrepared({
    required this.source,
    required this.fontPx,
    required this.lineHeight,
    required this.maxWidth,
    required this.layout,
    required this.placements,
  });

  final MindscapeSourceLine source;
  final double fontPx;
  final double lineHeight;
  final double maxWidth;
  final MindscapeTextLayout layout;
  final List<MindscapePlacement> placements;
}

/// 整行准备（folia `buildPreparedState`）。[fontScale] = 样式参数 × 全局歌词字号。
MindscapePrepared? mindscapePrepare(
  MindscapeSourceLine source, {
  required double viewportWidth,
  required double viewportHeight,
  required double fontScale,
  required double widthRatio,
  required LyricVisualizerIntensity intensity,
  required MindscapeMeasure measure,
}) {
  if (viewportWidth <= 0 || viewportHeight <= 0 || source.graphemes.isEmpty) {
    return null;
  }
  final double fontPx = mindscapeClamp(
    mindscapeChooseFontPx(
          viewportWidth,
          source.graphemes.length,
          source.words.length,
        ) *
        fontScale,
    24,
    132,
  );
  final double lineHeight =
      (fontPx * (mindscapeContainsCjk(source.text) ? 1.22 : 1.1))
          .roundToDouble();
  final double available = math.max(viewportWidth - 48, 120);
  final double minWidth = math.min(220, available);
  final int n = source.graphemes.length;
  final double compression = n > 12
      ? mindscapeClamp(0.92 - (n - 12) * 0.018, 0.62, 0.92)
      : 0.92;
  final double maxWidth = mindscapeClamp(
    math.min(viewportWidth * widthRatio * compression, 820),
    minWidth,
    available,
  );
  final MindscapeTextLayout layout = mindscapeLayoutText(
    source.graphemes,
    fontPx,
    maxWidth,
    measure,
  );
  final List<List<MindscapeFragment>> fragments = mindscapeBuildFragments(
    source,
    layout,
  );
  final List<MindscapePlacement> placements = mindscapeBuildPlacements(
    lineFragments: fragments,
    layoutLines: layout.lines,
    fontPx: fontPx,
    lineHeight: lineHeight,
    maxWidth: maxWidth,
    intensity: intensity,
    seed: source.timing.startTime * 1000,
    isInterlude: source.isInterlude,
  );
  return MindscapePrepared(
    source: source,
    fontPx: fontPx,
    lineHeight: lineHeight,
    maxWidth: maxWidth,
    layout: layout,
    placements: placements,
  );
}
