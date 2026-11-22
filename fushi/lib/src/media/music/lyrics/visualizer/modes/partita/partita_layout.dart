/// 云阶（folia partita）的布局规划（纯 Dart，可单测）：
///
/// 1. 运行时词 → layout unit（可选的 CJK 语义分组 + 固定开启的标点 / 缩写粘滞，
///    folia `cjkSemanticLayout.ts`）；
/// 2. layout unit 按可用高度切成不均匀的 chunk（一 chunk = 一可见行，folia
///    `partitaLayout.ts` 的 `buildSequentialColumns`）；
/// 3. 每行的错位 / 缩放 / 旋转配置与每个词的随机小偏移（`buildPartitaWordConfigs`）；
/// 4. 按测得的词宽排出行框，并可选「防止文字重叠」（folia `partitaOverlap.ts` +
///    `glowWordOverlap.ts`，这里直接用 px 算）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

/// folia 的 `theme.animationIntensity`（这里没有 AI 主题，做成样式参数）。
enum PartitaIntensity {
  calm('calm'),
  normal('normal'),
  chaotic('chaotic');

  const PartitaIntensity(this.key);

  final String key;

  static PartitaIntensity fromKey(String key) {
    for (final PartitaIntensity v in values) {
      if (v.key == key) return v;
    }
    return normal;
  }
}

/// 参数键（落库，冻结；与 folia `PartitaTuning` 字段同名）。
abstract final class PartitaTuningKeys {
  static const String showGuideLines = 'showGuideLines';
  static const String useSemanticLayout = 'useSemanticLayout';
  static const String staggerMin = 'staggerMin';
  static const String staggerMax = 'staggerMax';
  static const String avoidOverlap = 'avoidOverlap';
  static const String intensity = 'intensity';
}

/// 规整后的参数（folia `resolvePartitaTuning`：两端夹到 0–180，小的在前）。
@immutable
class PartitaSettings {
  const PartitaSettings({
    this.showGuideLines = true,
    this.useSemanticLayout = true,
    this.staggerMin = 20,
    this.staggerMax = 100,
    this.avoidOverlap = false,
    this.intensity = PartitaIntensity.normal,
  });

  factory PartitaSettings.fromTuning(
    LyricVisualizerTuning tuning, {
    required bool motion,
  }) {
    final double a = tuning
        .number(PartitaTuningKeys.staggerMin, 20)
        .clamp(0.0, 180.0);
    final double b = tuning
        .number(PartitaTuningKeys.staggerMax, 100)
        .clamp(0.0, 180.0);
    return PartitaSettings(
      showGuideLines: tuning.flag(PartitaTuningKeys.showGuideLines, true),
      useSemanticLayout: tuning.flag(PartitaTuningKeys.useSemanticLayout, true),
      staggerMin: math.min(a, b),
      staggerMax: math.max(a, b),
      avoidOverlap: tuning.flag(PartitaTuningKeys.avoidOverlap, false),
      // 减弱动态效果：按 calm 排（不抖、不随机放大）。
      intensity: motion
          ? PartitaIntensity.fromKey(
              tuning.choice(PartitaTuningKeys.intensity, 'normal'),
            )
          : PartitaIntensity.calm,
    );
  }

  final bool showGuideLines;
  final bool useSemanticLayout;
  final double staggerMin;
  final double staggerMax;
  final bool avoidOverlap;
  final PartitaIntensity intensity;

  /// 布局缓存键里的参数部分（引导线不影响布局，但 folia 也带上了，这里照抄无害）。
  String get cacheKey =>
      '${useSemanticLayout ? 1 : 0}|$staggerMin|$staggerMax|'
      '${avoidOverlap ? 1 : 0}|${intensity.key}';
}

// ---------------------------------------------------------------------------
// layout unit
// ---------------------------------------------------------------------------

/// 一个布局规划单元：一个或几个连续的运行时词。
@immutable
class PartitaUnit {
  const PartitaUnit({
    required this.words,
    required this.text,
    this.isSemantic = false,
    this.isSticky = false,
  });

  final List<LyricVisualizerWord> words;

  /// 规划用文本（词的文本直接拼接）。
  final String text;

  /// 由 CJK 语义分组得来（多个字一组，但显示时仍逐字计时）。
  final bool isSemantic;

  /// 粘过标点 / 缩写后缀（非语义的粘滞单元最终合成一个显示词）。
  final bool isSticky;

  int get startMs => words.first.startMs;
  int get endMs => words.last.endMs;

  PartitaUnit copyWith({
    List<LyricVisualizerWord>? words,
    String? text,
    bool? isSemantic,
    bool? isSticky,
  }) => PartitaUnit(
    words: words ?? this.words,
    text: text ?? this.text,
    isSemantic: isSemantic ?? this.isSemantic,
    isSticky: isSticky ?? this.isSticky,
  );
}

final RegExp _apostropheOnly = RegExp(r"^['’]\s*$");
final RegExp _contractionSuffix = RegExp(
  r'^(s|t|m|d|ll|re|ve|em)\s*$',
  caseSensitive: false,
);
final RegExp _directContraction = RegExp(
  r"^['’](s|t|m|d|ll|re|ve|em)\s*$",
  caseSensitive: false,
);
final RegExp _trailingApostrophe = RegExp(r"['’]\s*$");
final RegExp _trailingWordChar = RegExp(r'[\p{L}\p{N}]$', unicode: true);
final RegExp _inlineContraction = RegExp(
  r"[\p{L}\p{N}]+['’](s|t|m|d|ll|re|ve|em)",
  caseSensitive: false,
  unicode: true,
);
final RegExp _stickyTrailingPunct = RegExp(
  '^[,.;:!?，。！？、：；）】》」』〉〕］)}\\]"\'’”]+\$',
  unicode: true,
);

bool _canAttachToPrevious(String text) =>
    _trailingWordChar.hasMatch(text.trimRight());

/// 标点 / 缩写粘滞（folia `applyStickyPunctuationLayoutUnits`）：只改分组，不改计时。
List<PartitaUnit> applyPartitaStickyPunctuation(List<PartitaUnit> units) {
  final List<PartitaUnit> merged = <PartitaUnit>[];
  PartitaUnit attach(PartitaUnit target, PartitaUnit unit) => target.copyWith(
    words: <LyricVisualizerWord>[...target.words, ...unit.words],
    text: target.text + unit.text,
    isSticky: true,
  );

  for (int i = 0; i < units.length; i++) {
    final PartitaUnit current = units[i];
    if (merged.isEmpty) {
      merged.add(current);
      continue;
    }
    final PartitaUnit previous = merged.last;
    final PartitaUnit? next = i + 1 < units.length ? units[i + 1] : null;
    final String cur = current.text.trim();
    if (_apostropheOnly.hasMatch(cur) &&
        next != null &&
        _canAttachToPrevious(previous.text) &&
        _contractionSuffix.hasMatch(next.text.trim())) {
      merged[merged.length - 1] = attach(attach(previous, current), next);
      i++;
      continue;
    }
    if ((_directContraction.hasMatch(cur) &&
            _canAttachToPrevious(previous.text)) ||
        (_contractionSuffix.hasMatch(cur) &&
            _trailingApostrophe.hasMatch(previous.text.trimRight())) ||
        (_stickyTrailingPunct.hasMatch(cur) &&
            _canAttachToPrevious(previous.text))) {
      merged[merged.length - 1] = attach(previous, current);
      continue;
    }
    merged.add(current);
  }

  return <PartitaUnit>[
    for (final PartitaUnit u in merged)
      if (!u.isSticky &&
          ((u.words.length > 1 &&
                  _stickyTrailingPunct.hasMatch(u.words.last.text.trim())) ||
              (u.words.length > 1 &&
                  !u.isSemantic &&
                  _inlineContraction.hasMatch(u.text))))
        u.copyWith(isSticky: true)
      else
        u,
  ];
}

/// 单字的书写系统（语义分组的启发式用）。
enum _Script { han, hiragana, katakana, hangul, other }

_Script _scriptOf(String text) {
  if (text.isEmpty) return _Script.other;
  final int c = text.runes.first;
  if ((c >= 0xAC00 && c <= 0xD7AF) ||
      (c >= 0x1100 && c <= 0x11FF) ||
      (c >= 0x3130 && c <= 0x318F)) {
    return _Script.hangul;
  }
  if ((c >= 0x30A0 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF)) {
    return _Script.katakana;
  }
  if (c >= 0x3040 && c <= 0x309F) return _Script.hiragana;
  if ((c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x20000 && c <= 0x2FA1F) ||
      c == 0x3005) {
    return _Script.han;
  }
  return _Script.other;
}

/// 把 [n] 个字切成每段约 [size] 个；余数并进最后一段（只剩 1 个时不单独成段）。
List<int> _splitEven(int n, int size) {
  if (n <= size) return <int>[n];
  final List<int> out = <int>[];
  int left = n;
  while (left > 0) {
    if (left <= size + 1 && left > size) {
      // 余 1 个：并进这一段。
      out.add(left);
      break;
    }
    final int take = math.min(size, left);
    out.add(take);
    left -= take;
  }
  return out;
}

/// CJK 语义分组（代替 folia 的 Intl.Segmenter / AI 分词）：只在「紧挨着、没有空白」的
/// 单字 CJK 词串里分组。韩文一串一组；片假名一串一组；汉字两两一组（余一并进前组）；
/// 紧跟汉字 / 片假名的 1–2 个平假名（送假名、助词）并进前组，其余平假名每 ≤3 字一组。
List<PartitaUnit> _semanticUnits(LyricVisualizerLine line) {
  final List<LyricVisualizerWord> words = line.words;
  final List<PartitaUnit> out = <PartitaUnit>[];
  int i = 0;
  bool adjacent(LyricVisualizerWord a, LyricVisualizerWord b) =>
      b.firstGlyph == a.firstGlyph + a.glyphCount;

  PartitaUnit unitOf(List<LyricVisualizerWord> ws) => PartitaUnit(
    words: ws,
    text: ws.map((LyricVisualizerWord w) => w.text).join(),
    isSemantic: ws.length > 1,
  );

  while (i < words.length) {
    final _Script s = _scriptOf(words[i].text);
    if (s == _Script.other || words[i].text.characters.length != 1) {
      out.add(unitOf(<LyricVisualizerWord>[words[i]]));
      i++;
      continue;
    }
    // 收一段同书写系统、紧挨着的单字词。
    int j = i + 1;
    while (j < words.length &&
        adjacent(words[j - 1], words[j]) &&
        words[j].text.characters.length == 1 &&
        _scriptOf(words[j].text) == s) {
      j++;
    }
    final List<LyricVisualizerWord> run = words.sublist(i, j);
    final bool followsAnchor =
        s == _Script.hiragana &&
        out.isNotEmpty &&
        i > 0 &&
        adjacent(words[i - 1], words[i]) &&
        <_Script>{
          _Script.han,
          _Script.katakana,
        }.contains(_scriptOf(words[i - 1].text));
    int k = 0;
    if (followsAnchor) {
      final int glue = math.min(run.length, run.length <= 2 ? 2 : 1);
      final PartitaUnit prev = out.removeLast();
      out.add(unitOf(<LyricVisualizerWord>[...prev.words, ...run.take(glue)]));
      k = glue;
    }
    final List<int> sizes = switch (s) {
      _Script.hangul || _Script.katakana => <int>[run.length - k],
      _Script.han => _splitEven(run.length, 2),
      _ => _splitEven(run.length - k, 3),
    };
    for (final int n in sizes) {
      if (n <= 0) continue;
      out.add(unitOf(run.sublist(k, k + n)));
      k += n;
    }
    i = j;
  }
  return out;
}

/// 一行 → layout unit（folia `buildPostLyricLayoutUnits(line, {semantic, sticky: true})`）。
List<PartitaUnit> buildPartitaLayoutUnits(
  LyricVisualizerLine line, {
  required bool semantic,
}) {
  if (line.words.isEmpty) return const <PartitaUnit>[];
  final List<PartitaUnit> raw = semantic
      ? _semanticUnits(line)
      : <PartitaUnit>[
          for (final LyricVisualizerWord w in line.words)
            PartitaUnit(words: <LyricVisualizerWord>[w], text: w.text),
        ];
  return applyPartitaStickyPunctuation(raw);
}

/// unit → 实际画出来的词（folia `buildDisplayWordsFromLayoutUnits`）：粘滞的非语义单元合成
/// 一个词（字形区间连续覆盖），语义单元与普通单元原样返回内部词。
List<LyricVisualizerWord> partitaDisplayWords(
  List<PartitaUnit> units,
  List<LyricVisualizerGlyph> glyphs,
) => <LyricVisualizerWord>[
  for (final PartitaUnit u in units)
    if (!u.isSticky || u.isSemantic)
      ...u.words
    else
      _mergeWords(u.words, glyphs),
];

LyricVisualizerWord _mergeWords(
  List<LyricVisualizerWord> ws,
  List<LyricVisualizerGlyph> glyphs,
) {
  final int first = ws.first.firstGlyph;
  final int end = ws.last.firstGlyph + ws.last.glyphCount;
  final String text = first >= 0 && end <= glyphs.length
      ? glyphs
            .sublist(first, end)
            .map((LyricVisualizerGlyph g) => g.text)
            .join()
      : ws.map((LyricVisualizerWord w) => w.text).join();
  return LyricVisualizerWord(
    text: text,
    startMs: ws.first.startMs,
    endMs: ws.last.endMs,
    firstGlyph: first,
    glyphCount: end - first,
  );
}

// ---------------------------------------------------------------------------
// chunk 切分与姿态配置
// ---------------------------------------------------------------------------

/// folia 一行占的基准高度（px）与可用高度比例。
const double partitaBaseRowHeight = 100;
const double partitaAvailableHeightRatio = 0.65;

/// 一行能用几个可见 row（folia：`floor(windowHeight * 0.65 / 100)`，至少 1）。
int partitaTargetRowCount(double windowHeight) => math.max(
  1,
  (windowHeight * partitaAvailableHeightRatio / partitaBaseRowHeight).floor(),
);

/// 把 unit 切成 [rowCount] 段不均匀的 chunk（每段至少 1 个；故意不平均，像手写乐谱）。
List<List<PartitaUnit>> splitPartitaChunks(
  List<PartitaUnit> units,
  int targetRowCount,
  double Function() random,
) {
  final int rows = math.min(units.length, math.max(1, targetRowCount));
  final List<List<PartitaUnit>> chunks = <List<PartitaUnit>>[];
  int remainingUnits = units.length;
  int remainingChunks = rows;
  int index = 0;
  for (int c = 0; c < rows; c++) {
    final bool last = c == rows - 1;
    final double avg = remainingUnits / remainingChunks;
    int len;
    if (last) {
      len = remainingUnits;
    } else {
      final int max = (avg * 1.5).ceil();
      len = math.max(1, math.min(max, (avg + (random() - 0.5) * avg).round()));
    }
    len = math.max(1, math.min(len, remainingUnits - (remainingChunks - 1)));
    chunks.add(units.sublist(index, index + len));
    index += len;
    remainingUnits -= len;
    remainingChunks--;
  }
  return chunks;
}

/// 一行 / 一个词的姿态（px、度）。
@immutable
class PartitaPose {
  const PartitaPose({
    this.x = 0,
    this.y = 0,
    this.rotate = 0,
    this.scale = 1,
    this.passedRotate = 0,
  });

  final double x;
  final double y;
  final double rotate;
  final double scale;
  final double passedRotate;
}

/// 一个可见 row 的规划结果。
@immutable
class PartitaRowPlan {
  const PartitaRowPlan({
    required this.rowIndex,
    required this.units,
    required this.chunkWords,
    required this.displayWords,
    required this.config,
    required this.marginBottom,
    required this.wordPoses,
  });

  final int rowIndex;
  final List<PartitaUnit> units;

  /// 原始计时词（行级 active 时间窗来自这里）。
  final List<LyricVisualizerWord> chunkWords;
  final List<LyricVisualizerWord> displayWords;
  final PartitaPose config;

  /// 行下外边距（px，folia 0.6rem / chaotic 0.4rem）。
  final double marginBottom;
  final List<PartitaPose> wordPoses;

  /// 偶数行引导线在左、奇数行在右（folia `guidePosition`）。
  bool get guideLeft => rowIndex.isEven;
}

/// 一句歌词的规划。
@immutable
class PartitaLinePlan {
  const PartitaLinePlan({required this.rows, required this.totalGraphemes});

  final List<PartitaRowPlan> rows;
  final int totalGraphemes;
}

double _frac(double v) => v - v.floorToDouble();

/// 每个显示词在 chunk 内的随机小偏移（folia `buildPartitaWordConfigs`；按首词起唱时间取种子，
/// 同一首每次一样）。
List<PartitaPose> partitaWordPoses(
  List<LyricVisualizerWord> displayWords,
  PartitaPose row,
  PartitaIntensity intensity,
) {
  if (displayWords.isEmpty) return const <PartitaPose>[];
  final double spread = switch (intensity) {
    PartitaIntensity.chaotic => 15,
    PartitaIntensity.calm => 0,
    PartitaIntensity.normal => 6,
  };
  final double rot = switch (intensity) {
    PartitaIntensity.chaotic => 8,
    PartitaIntensity.calm => 0,
    PartitaIntensity.normal => 3,
  };
  final double base = displayWords.first.startMs / 1000;
  return <PartitaPose>[
    for (int i = 0; i < displayWords.length; i++)
      () {
        final double seed = base + i * 7.13;
        double r(int o) => _frac(math.sin(seed + o) * 10000);
        return PartitaPose(
          x: (r(1) - 0.5) * spread * 2,
          y: (r(2) - 0.5) * spread * 2,
          rotate: (r(3) - 0.5) * rot * 2,
          scale: row.scale,
          passedRotate: (r(8) - 0.5) * 20,
        );
      }(),
  ];
}

int _graphemesNoSpace(String s) =>
    s.replaceAll(RegExp(r'\s+'), '').characters.length;

/// 规划一句（folia `buildSequentialColumns`）。[random] 是本句的种子随机源。
PartitaLinePlan planPartitaLine(
  LyricVisualizerLine line, {
  required double windowHeight,
  required PartitaSettings settings,
  required double Function() random,
}) {
  final PartitaIntensity intensity = settings.intensity;
  final bool calm = intensity == PartitaIntensity.calm;
  final bool chaotic = intensity == PartitaIntensity.chaotic;
  final int totalGraphemes = math.max(
    math.max(_graphemesNoSpace(line.text), line.words.length),
    1,
  );
  final List<PartitaUnit> units = buildPartitaLayoutUnits(
    line,
    semantic: settings.useSemanticLayout,
  );
  final int rowCount = math.min(
    units.length,
    partitaTargetRowCount(windowHeight),
  );
  final List<List<PartitaUnit>> chunks = splitPartitaChunks(
    units,
    rowCount,
    random,
  );

  final List<PartitaRowPlan> rows = <PartitaRowPlan>[];
  for (int r = 0; r < chunks.length; r++) {
    final List<PartitaUnit> chunkUnits = chunks[r];
    final List<LyricVisualizerWord> chunkWords = <LyricVisualizerWord>[
      for (final PartitaUnit u in chunkUnits) ...u.words,
    ];
    if (chunkWords.isEmpty) continue;
    final List<LyricVisualizerWord> display = partitaDisplayWords(
      chunkUnits,
      line.glyphs,
    );
    final int graphemes = _graphemesNoSpace(
      chunkWords.map((LyricVisualizerWord w) => w.text.trim()).join(),
    );
    final double rowBias = r - (rowCount - 1) / 2;
    final bool left = r.isEven;
    final double magnitude =
        settings.staggerMin +
        random() * math.max(settings.staggerMax - settings.staggerMin, 0);
    final double staggerScale = calm ? 1 : 0.8 + random() * 0.9;
    final PartitaPose config = PartitaPose(
      x: left ? -magnitude : magnitude,
      y: calm ? 0 : rowBias * 2.5,
      rotate: chaotic ? (left ? -3 : 3) : 0,
      scale:
          (chaotic ? 1 + math.min(graphemes * 0.01, 0.05) : 1) * staggerScale,
      passedRotate: (left ? 1 : -1) * (chaotic ? 6 : 3),
    );
    rows.add(
      PartitaRowPlan(
        rowIndex: r,
        units: chunkUnits,
        chunkWords: chunkWords,
        displayWords: display,
        config: config,
        marginBottom: chaotic ? 6.4 : 9.6,
        wordPoses: partitaWordPoses(display, config, intensity),
      ),
    );
  }
  return PartitaLinePlan(rows: rows, totalGraphemes: totalGraphemes);
}

// ---------------------------------------------------------------------------
// 几何：行框与「防止文字重叠」
// ---------------------------------------------------------------------------

/// 词距（folia 0.8rem）、行内边距（0.2rem 0.5rem）、行高（GlowWord 的 1.22）。
const double partitaWordGap = 12.8;
const double partitaRowPadX = 8;
const double partitaRowPadY = 3.2;
const double partitaLineHeight = 1.22;

/// active 词放大倍数（folia `GLOW_WORD_ACTIVE_SCALE`）。
const double partitaActiveScale = 1.4;

/// 主字号（folia `clamp(2.5rem, 5.5vw, 4.5rem)` × 长句密度 × 字号倍数）。
double partitaFontSize({
  required double width,
  required int totalGraphemes,
  required double fontScale,
}) {
  final double density = totalGraphemes > 40 ? 0.8 : 1;
  return (width * 0.055).clamp(40.0, 72.0) * density * fontScale;
}

/// 画出来的词超出其排版框多少（folia `getGlowWordReach`，px）：active 放大与 passed 慢转里取最大。
({double halfWidth, double halfHeight}) partitaWordReach(
  double width,
  double fontSize,
  PartitaPose pose,
) {
  ({double halfWidth, double halfHeight}) at(double scale, double deg) {
    final double rad = deg * math.pi / 180;
    final double c = math.cos(rad).abs();
    final double s = math.sin(rad).abs();
    return (
      halfWidth: scale * (width * c + fontSize * s) / 2,
      halfHeight: scale * (fontSize * c + width * s) / 2,
    );
  }

  final ({double halfWidth, double halfHeight}) active = at(
    pose.scale * partitaActiveScale,
    pose.rotate,
  );
  double hw = active.halfWidth;
  double hh = active.halfHeight;
  for (int step = 0; step <= 8; step++) {
    final ({double halfWidth, double halfHeight}) p = at(
      pose.scale,
      pose.rotate + pose.passedRotate * step / 8,
    );
    hw = math.max(hw, p.halfWidth);
    hh = math.max(hh, p.halfHeight);
  }
  return (halfWidth: hw, halfHeight: hh);
}

/// 一行排好的几何。
@immutable
class PartitaRowGeometry {
  const PartitaRowGeometry({
    required this.box,
    required this.wordBoxes,
    required this.rtl,
  });

  /// 行框（含内边距），在整句块坐标里（块左上为原点）。
  final Rect box;

  /// 各显示词的框，相对行框左上。
  final List<Rect> wordBoxes;
  final bool rtl;
}

/// 整句块的几何。
@immutable
class PartitaBlockGeometry {
  const PartitaBlockGeometry({required this.rows, required this.size});

  final List<PartitaRowGeometry> rows;
  final Size size;

  /// 含错位后的最大半宽（相对块中线），给缩放适配用。
  double get reachHalfWidth {
    double r = size.width / 2;
    for (final PartitaRowGeometry g in rows) {
      r = math.max(r, g.box.width / 2);
    }
    return r;
  }
}

final RegExp _rtlChars = RegExp(r'[֐-ࣿיִ-﷿ﹰ-﻿]');

/// 粗判 RTL（阿拉伯文 / 希伯来文 / 维吾尔文…），folia `resolveLyricTextDirection`。
bool partitaIsRtl(String text) => _rtlChars.hasMatch(text);

/// 排行框。[widths] 是每行各显示词测得的宽（px）。列居中，行逐个向下、行内水平居中。
PartitaBlockGeometry layoutPartitaBlock({
  required List<PartitaRowPlan> rows,
  required List<List<double>> widths,
  required double fontSize,
  required bool avoidOverlap,
}) {
  final double wordH = fontSize * partitaLineHeight;
  final double rowH = wordH + partitaRowPadY * 2;
  final double breath = 0.05 * fontSize;

  // 每行：词间距、上下伸出量。
  final List<List<double>> gaps = <List<double>>[];
  final List<({double top, double bottom})> reach =
      <({double top, double bottom})>[];
  final List<bool> rtl = <bool>[];
  for (int r = 0; r < rows.length; r++) {
    final PartitaRowPlan row = rows[r];
    final List<double> w = widths[r];
    final bool isRtl = partitaIsRtl(
      row.displayWords.map((LyricVisualizerWord x) => x.text).join(' '),
    );
    rtl.add(isRtl);
    final List<double> g = <double>[];
    double top = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    double rowWidth = 0;
    for (int i = 0; i < w.length; i++) {
      final PartitaPose pose = row.wordPoses[i];
      final ({double halfWidth, double halfHeight}) re = partitaWordReach(
        w[i],
        fontSize,
        pose,
      );
      if (!avoidOverlap || i == w.length - 1) {
        g.add(partitaWordGap);
      } else {
        final PartitaPose next = row.wordPoses[i + 1];
        final ({double halfWidth, double halfHeight}) rn = partitaWordReach(
          w[i + 1],
          fontSize,
          next,
        );
        final double toward = isRtl ? next.x - pose.x : pose.x - next.x;
        final double pair =
            (re.halfWidth - w[i] / 2) + (rn.halfWidth - w[i + 1] / 2) + toward;
        g.add(math.max(partitaWordGap, pair + breath));
      }
      final double over = re.halfHeight - wordH / 2;
      top = math.max(top, over - pose.y);
      bottom = math.max(bottom, over + pose.y);
      rowWidth += math.max(w[i], 2 * re.halfWidth) + partitaWordGap;
    }
    final double turn =
        rowWidth / 2 * math.sin(row.config.rotate * math.pi / 180).abs();
    gaps.add(g);
    reach.add((
      top: (top.isFinite ? top : 0) + turn,
      bottom: (bottom.isFinite ? bottom : 0) + turn,
    ));
  }

  // 纵向：第一行上边距、各行下边距。
  final List<double> marginBottom = <double>[];
  double marginTop = 0;
  for (int r = 0; r < rows.length; r++) {
    double mb = rows[r].marginBottom;
    if (avoidOverlap) {
      if (r == 0) {
        marginTop = math.max(0, reach[r].top - partitaRowPadY);
      }
      final double need = r + 1 < rows.length
          ? reach[r].bottom + reach[r + 1].top + breath - 2 * partitaRowPadY
          : reach[r].bottom - partitaRowPadY;
      mb = math.max(mb, need);
    }
    marginBottom.add(mb);
  }

  // 行宽与块宽。
  final List<double> rowWidths = <double>[
    for (int r = 0; r < rows.length; r++)
      partitaRowPadX * 2 +
          List<double>.generate(
            widths[r].length,
            (int i) => widths[r][i] + gaps[r][i],
          ).fold<double>(0, (double a, double b) => a + b),
  ];
  // 列的 px-3（12px）。
  final double blockW =
      rowWidths.fold<double>(0, (double a, double b) => math.max(a, b)) + 24;
  double y = marginTop;
  final List<PartitaRowGeometry> out = <PartitaRowGeometry>[];
  for (int r = 0; r < rows.length; r++) {
    final double rw = rowWidths[r];
    final Rect box = Rect.fromLTWH((blockW - rw) / 2, y, rw, rowH);
    final List<Rect> wordBoxes = <Rect>[];
    if (rtl[r]) {
      double x = rw - partitaRowPadX;
      for (int i = 0; i < widths[r].length; i++) {
        x -= widths[r][i];
        wordBoxes.add(Rect.fromLTWH(x, partitaRowPadY, widths[r][i], wordH));
        x -= gaps[r][i];
      }
    } else {
      double x = partitaRowPadX;
      for (int i = 0; i < widths[r].length; i++) {
        wordBoxes.add(Rect.fromLTWH(x, partitaRowPadY, widths[r][i], wordH));
        x += widths[r][i] + gaps[r][i];
      }
    }
    out.add(PartitaRowGeometry(box: box, wordBoxes: wordBoxes, rtl: rtl[r]));
    y += rowH + marginBottom[r];
  }
  return PartitaBlockGeometry(rows: out, size: Size(blockW, y));
}

/// 整句缩放适配：块（含行错位）放进歌词区（宽 − 2×32、高 70% − 2×32）；只缩不放。
double partitaFitScale({
  required PartitaBlockGeometry block,
  required List<PartitaRowPlan> rows,
  required Size area,
}) {
  final double availW = math.max(1, area.width - 64);
  final double availH = math.max(1, area.height * 0.7 - 64);
  double half = block.size.width / 2;
  for (int r = 0; r < rows.length; r++) {
    half = math.max(half, block.rows[r].box.width / 2 + rows[r].config.x.abs());
  }
  final double s = math.min(
    1,
    math.min(availW / (half * 2), availH / math.max(1, block.size.height)),
  );
  return s.clamp(0.3, 1.0);
}
