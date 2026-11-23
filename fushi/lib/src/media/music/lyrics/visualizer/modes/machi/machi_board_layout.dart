/// 歌词屏字面的排版与逐字点亮（folia `engine/boardLayout.ts`）：把一行歌词按字面宽高排成
/// 1–3 行（取字最大的那种，行数多了略扣分），记下每个字的 [x0, x1] 和唱起、唱完时间；
/// 每帧按时间求每一行亮到哪个 x。字的时间来自运行时的字形时间线，不靠字符串搜索猜。
/// 测量函数由调用方给（TextPainter 或测试里的假测量）。纯 Dart。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 按参考字号量一段字的宽度（像素）。
typedef MachiMeasure = double Function(String text);

class MachiBoardGlyph {
  const MachiBoardGlyph({
    required this.text,
    required this.x0,
    required this.x1,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final double x0;
  final double x1;

  /// 唱起、唱完（毫秒；曲名卡的字是负无穷，一直全亮）。
  final double startMs;
  final double endMs;
}

class MachiBoardRow {
  const MachiBoardRow({
    required this.glyphs,
    required this.text,
    required this.fontPx,
    required this.centerY,
    required this.top,
    required this.bottom,
    required this.left,
    required this.width,
  });

  final List<MachiBoardGlyph> glyphs;

  /// 这一行的字（行尾空格去掉）。
  final String text;
  final double fontPx;
  final double centerY;
  final double top;
  final double bottom;
  final double left;
  final double width;
}

class MachiBoardLayout {
  const MachiBoardLayout({
    required this.fontPx,
    required this.rows,
    required this.width,
    required this.height,
  });

  final double fontPx;
  final List<MachiBoardRow> rows;
  final double width;
  final double height;
}

/// 字面：宽高（像素）、左右留白占宽度的比例、测量用的参考字号。
class MachiBoardBox {
  const MachiBoardBox({
    required this.width,
    required this.height,
    this.paddingX = 0.05,
    this.referencePx = 100,
  });

  final double width;
  final double height;
  final double paddingX;
  final double referencePx;
}

const int _maxRows = 3;

/// 单行时字高占字面高的上限。
const double _singleRowFill = 0.56;
const double machiBoardLineGap = 1.22;

/// 行数多了略扣分：同样大的字，少一行更好读。
const List<double> _rowPenalty = <double>[1, 0.94, 0.84];

final RegExp _sticky = RegExp(r'^[，。、！？；：,.!?;:」』）)\]】〉》…~～ー]+$');

class _Token {
  _Token();

  final List<LyricVisualizerGlyph> glyphs = <LyricVisualizerGlyph>[];

  String get text => glyphs.map((LyricVisualizerGlyph g) => g.text).join();
}

/// 断行单位：中日韩字一个字一个单位，拉丁词连同后面的空格一个单位，行首禁则标点并到前面。
List<List<LyricVisualizerGlyph>> machiBoardTokens(
  List<LyricVisualizerGlyph> glyphs,
) {
  final List<_Token> tokens = <_Token>[];
  _Token? current;
  for (final LyricVisualizerGlyph g in glyphs) {
    if (_sticky.hasMatch(g.text) && tokens.isNotEmpty && current == null) {
      tokens.last.glyphs.add(g);
      continue;
    }
    if (lyricVisualizerIsCjk(g.text) && !_sticky.hasMatch(g.text)) {
      if (current != null) tokens.add(current);
      current = null;
      tokens.add(_Token()..glyphs.add(g));
      continue;
    }
    current ??= _Token();
    current.glyphs.add(g);
    if (g.isSpace) {
      tokens.add(current);
      current = null;
    }
  }
  if (current != null) tokens.add(current);
  return <List<LyricVisualizerGlyph>>[
    for (final _Token t in tokens)
      if (t.glyphs.isNotEmpty) t.glyphs,
  ];
}

String _joined(List<List<LyricVisualizerGlyph>> tokens) => tokens
    .map(
      (List<LyricVisualizerGlyph> t) =>
          t.map((LyricVisualizerGlyph g) => g.text).join(),
    )
    .join();

double _rowWidth(List<List<LyricVisualizerGlyph>> tokens, MachiMeasure m) =>
    m(_joined(tokens).trimRight());

/// 把单位分成 [rows] 行，尽量等宽（贪心：每行装到接近总宽 / 行数）。
List<List<List<LyricVisualizerGlyph>>> _splitRows(
  List<List<LyricVisualizerGlyph>> tokens,
  int rows,
  MachiMeasure m,
) {
  if (rows <= 1 || tokens.length <= 1) {
    return <List<List<LyricVisualizerGlyph>>>[tokens];
  }
  final double target = _rowWidth(tokens, m) / rows;
  final List<List<List<LyricVisualizerGlyph>>> result =
      <List<List<LyricVisualizerGlyph>>>[];
  List<List<LyricVisualizerGlyph>> current = <List<LyricVisualizerGlyph>>[];
  for (int index = 0; index < tokens.length; index++) {
    final List<LyricVisualizerGlyph> token = tokens[index];
    final int remainingRows = rows - result.length;
    final int remainingTokens = tokens.length - index;
    final List<List<LyricVisualizerGlyph>> next = <List<LyricVisualizerGlyph>>[
      ...current,
      token,
    ];
    if (current.isNotEmpty &&
        remainingRows > 1 &&
        _rowWidth(next, m) > target * 1.04 &&
        remainingTokens >= remainingRows - 1) {
      final double without = _rowWidth(current, m);
      final double withIt = _rowWidth(next, m);
      if ((withIt - target).abs() < (without - target).abs() &&
          remainingTokens > remainingRows - 1) {
        result.add(next);
        current = <List<LyricVisualizerGlyph>>[];
        continue;
      }
      result.add(current);
      current = <List<LyricVisualizerGlyph>>[token];
      continue;
    }
    current = next;
  }
  if (current.isNotEmpty) result.add(current);
  return result;
}

/// 一行歌词在字面上的排版：1–3 行里挑字最大的（行数多扣分）。
MachiBoardLayout layoutMachiBoardLine(
  List<LyricVisualizerGlyph> glyphs,
  MachiBoardBox box,
  MachiMeasure measure,
) {
  final List<List<LyricVisualizerGlyph>> tokens = machiBoardTokens(glyphs);
  final double usable = box.width * (1 - box.paddingX * 2);
  List<List<List<LyricVisualizerGlyph>>>? bestRows;
  double bestFont = 0;
  double bestScore = -1;
  for (int rows = 1; rows <= _maxRows; rows++) {
    if (rows > tokens.length) break;
    final List<List<List<LyricVisualizerGlyph>>> split = _splitRows(
      tokens,
      rows,
      measure,
    );
    double widest = 1;
    for (final List<List<LyricVisualizerGlyph>> r in split) {
      widest = math.max(widest, _rowWidth(r, measure));
    }
    final double byWidth = usable / widest * box.referencePx;
    final double byHeight = rows == 1
        ? box.height * _singleRowFill
        : box.height * 0.86 / (split.length * machiBoardLineGap);
    final double font = math.min(byWidth, byHeight);
    final double score = font * _rowPenalty[split.length - 1];
    if (score > bestScore) {
      bestScore = score;
      bestRows = split;
      bestFont = font;
    }
  }
  if (bestRows == null) {
    return MachiBoardLayout(
      fontPx: box.height * 0.4,
      rows: const <MachiBoardRow>[],
      width: box.width,
      height: box.height,
    );
  }
  return _placeRows(bestRows, bestFont, box, measure);
}

MachiBoardLayout _placeRows(
  List<List<List<LyricVisualizerGlyph>>> rows,
  double fontPx,
  MachiBoardBox box,
  MachiMeasure measure,
) {
  final double scale = fontPx / box.referencePx;
  final double lineHeight = fontPx * machiBoardLineGap;
  final double blockHeight = lineHeight * rows.length;
  final double firstCenter = box.height / 2 - blockHeight / 2 + lineHeight / 2;
  final List<MachiBoardRow> placed = <MachiBoardRow>[];
  for (int r = 0; r < rows.length; r++) {
    final List<LyricVisualizerGlyph> glyphs = <LyricVisualizerGlyph>[
      for (final List<LyricVisualizerGlyph> t in rows[r]) ...t,
    ];
    final String text = glyphs.map((LyricVisualizerGlyph g) => g.text).join();
    final double width = measure(text.trimRight()) * scale;
    final double left = (box.width - width) / 2;
    final StringBuffer prefix = StringBuffer();
    final List<MachiBoardGlyph> out = <MachiBoardGlyph>[];
    double x0 = left;
    for (final LyricVisualizerGlyph g in glyphs) {
      prefix.write(g.text);
      final double x1 = left + measure(prefix.toString()) * scale;
      out.add(
        MachiBoardGlyph(
          text: g.text,
          x0: x0,
          x1: x1,
          startMs: g.startMs.toDouble(),
          endMs: g.endMs.toDouble(),
        ),
      );
      x0 = x1;
    }
    final double centerY = firstCenter + r * lineHeight;
    placed.add(
      MachiBoardRow(
        glyphs: out,
        text: text.trimRight(),
        fontPx: fontPx,
        centerY: centerY,
        top: centerY - lineHeight / 2,
        bottom: centerY + lineHeight / 2,
        left: left,
        width: width,
      ),
    );
  }
  return MachiBoardLayout(
    fontPx: fontPx,
    rows: placed,
    width: box.width,
    height: box.height,
  );
}

/// 曲名卡（间奏、开唱前、长空隙）：主标题一行（放不下缩字），副标题小一号。
MachiBoardLayout layoutMachiBoardCard(
  String title,
  String subtitle,
  MachiBoardBox box,
  MachiMeasure measure,
) {
  final double usable = box.width * (1 - box.paddingX * 2);
  final double titleFont = math.min(
    box.height * (subtitle.isNotEmpty ? 0.4 : 0.5),
    usable / math.max(1, measure(title)) * box.referencePx,
  );
  final double subtitleFont = subtitle.isNotEmpty
      ? math.min(
          titleFont * 0.52,
          usable / math.max(1, measure(subtitle)) * box.referencePx,
        )
      : 0;
  final List<MachiBoardRow> rows = <MachiBoardRow>[];
  final double total =
      titleFont * 1.15 + (subtitle.isNotEmpty ? subtitleFont * 1.4 : 0);
  double y = box.height / 2 - total / 2;
  void row(String text, double fontPx) {
    final double scale = fontPx / box.referencePx;
    final double width = measure(text) * scale;
    final double left = (box.width - width) / 2;
    final double height = fontPx * (rows.isEmpty ? 1.15 : 1.4);
    rows.add(
      MachiBoardRow(
        glyphs: <MachiBoardGlyph>[
          MachiBoardGlyph(
            text: text,
            x0: left,
            x1: left + width,
            startMs: double.negativeInfinity,
            endMs: double.negativeInfinity,
          ),
        ],
        text: text,
        fontPx: fontPx,
        centerY: y + height / 2,
        top: y,
        bottom: y + height,
        left: left,
        width: width,
      ),
    );
    y += height;
  }

  row(title, titleFont);
  if (subtitle.isNotEmpty) row(subtitle, subtitleFont);
  return MachiBoardLayout(
    fontPx: titleFont,
    rows: rows,
    width: box.width,
    height: box.height,
  );
}

/// 时刻 [timeMs] 每一行亮到的 x。字在 [start, end] 里从左往右扫亮，唱完的字全亮；
/// 遇到还没开始的字就停。结果对时间单调不减。
List<double> resolveMachiBoardReveal(MachiBoardLayout layout, double timeMs) =>
    <double>[
      for (final MachiBoardRow row in layout.rows) _rowReveal(row, timeMs),
    ];

double _rowReveal(MachiBoardRow row, double time) {
  double lit = row.glyphs.isEmpty ? 0 : row.glyphs.first.x0;
  for (final MachiBoardGlyph g in row.glyphs) {
    if (time >= g.endMs) {
      lit = g.x1;
      continue;
    }
    if (time > g.startMs) {
      final double span = math.max(1e-3, g.endMs - g.startMs);
      lit = g.x0 + (g.x1 - g.x0) * math.min(1, (time - g.startMs) / span);
    }
    break;
  }
  return lit;
}
