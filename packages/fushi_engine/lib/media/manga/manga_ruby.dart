/// 漫画页上**来源自带**的注音（振假名 / ruby，印在底本旁边的小字假名）：认出哪些 OCR
/// 块是注音、注在哪个块的哪几个字上，供朗读与有声剧合成时「按注音念」。
///
/// 只认页面上印着的注音，不推断读音（自动注音在黑名单里）。注音块本身不进句子文本：
/// 显示 / 复制 / 制卡用底本，合成用底本换成读音后的文本——与小说 TTS 的 ruby 同一
/// 语义（`tts_book_plan.dart`：合成用读音，显示用底本）。
///
/// 判注音：块文字全是假名，紧贴在含汉字 / 拉丁字母 / 数字的块的注音一侧（竖排在右、
/// 横排在上），比底本细得多，沿行方向与底本有足够重叠。
///
/// 注在哪几个字：OCR 只给行级几何，按行框（有 `lines_coords` 用它，没有就把块框按
/// 行数均分）把每行沿行方向均分成逐字格，取与注音块重叠过半的字；拉丁字母 / 数字
/// 按整词扩展（「CRYCHIC」上的「クライシック」比底本短，只盖住中间几个字母），首尾的
/// 假名 / 标点不算底本。定不出范围的注音照样从句子里拿掉，只是不换读音。
library;

import 'dart:math' as math;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 一条注音：块 [rubyBlock] 注在块 [baseBlock] 第 [line] 行的
/// `[start, end)`（UTF-16，相对 `lines[line]`）上，读作 [reading]。
class MangaRubyAnnotation {
  const MangaRubyAnnotation({
    required this.rubyBlock,
    required this.baseBlock,
    required this.line,
    required this.start,
    required this.end,
    required this.reading,
  });

  final int rubyBlock;
  final int baseBlock;
  final int line;
  final int start;
  final int end;
  final String reading;

  @override
  String toString() =>
      'MangaRubyAnnotation(b$rubyBlock→b$baseBlock L$line [$start,$end) "$reading")';
}

/// 一页的注音：[baseOfRuby] 是全部被判为注音的块 → 它的底本块（含定不出字范围的），
/// [annotations] 是定出了字范围的注音（同一行重叠的已合并，按行、起点排序）。
class MangaPageRuby {
  const MangaPageRuby({required this.baseOfRuby, required this.annotations});

  static const MangaPageRuby empty = MangaPageRuby(
    baseOfRuby: <int, int>{},
    annotations: <MangaRubyAnnotation>[],
  );

  final Map<int, int> baseOfRuby;
  final List<MangaRubyAnnotation> annotations;

  bool isRuby(int block) => baseOfRuby.containsKey(block);

  /// 块 [block] 的各行换成读音后的文本（[lines] 即该块的 `lines`）；没有注音原样返回。
  List<String> spokenLinesOf(int block, List<String> lines) {
    final List<MangaRubyAnnotation> mine = <MangaRubyAnnotation>[
      for (final MangaRubyAnnotation a in annotations)
        if (a.baseBlock == block) a,
    ];
    if (mine.isEmpty) return lines;
    return <String>[
      for (int i = 0; i < lines.length; i++) _replace(lines[i], i, mine),
    ];
  }

  static String _replace(
    String line,
    int index,
    List<MangaRubyAnnotation> annotations,
  ) {
    final StringBuffer out = StringBuffer();
    int cursor = 0;
    for (final MangaRubyAnnotation a in annotations) {
      if (a.line != index || a.start < cursor || a.end > line.length) continue;
      out
        ..write(line.substring(cursor, a.start))
        ..write(a.reading);
      cursor = a.end;
    }
    out.write(line.substring(cursor));
    return out.toString();
  }
}

/// 认出 [blocks]（一页的 OCR 块）里的注音。
MangaPageRuby detectMangaPageRuby(List<MokuroBlock> blocks) {
  if (blocks.length < 2) return MangaPageRuby.empty;
  final Map<int, int> baseOfRuby = <int, int>{};
  final List<MangaRubyAnnotation> found = <MangaRubyAnnotation>[];
  for (int r = 0; r < blocks.length; r++) {
    final MokuroBlock ruby = blocks[r];
    final String reading = ruby.lines.join().trim();
    if (!_kanaOnly(reading)) continue;
    int? best;
    double bestGap = double.infinity;
    for (int b = 0; b < blocks.length; b++) {
      if (b == r) continue;
      final double? gap = mangaRubyGap(ruby, blocks[b]);
      if (gap != null && gap < bestGap) {
        bestGap = gap;
        best = b;
      }
    }
    if (best == null) continue;
    baseOfRuby[r] = best;
    final ({int line, int start, int end})? span = _rubySpan(
      ruby,
      blocks[best],
    );
    if (span == null) continue;
    found.add(
      MangaRubyAnnotation(
        rubyBlock: r,
        baseBlock: best,
        line: span.line,
        start: span.start,
        end: span.end,
        reading: reading,
      ),
    );
  }
  return MangaPageRuby(
    baseOfRuby: Map<int, int>.unmodifiable(baseOfRuby),
    annotations: List<MangaRubyAnnotation>.unmodifiable(_merge(found)),
  );
}

/// 同一底本行上重叠的注音合成一条（逐字分开识别的「は る / ひ / かげ」），读音按
/// 起点顺序相连。结果按底本块、行、起点排序。
List<MangaRubyAnnotation> _merge(List<MangaRubyAnnotation> found) {
  final List<MangaRubyAnnotation> sorted = List<MangaRubyAnnotation>.of(found)
    ..sort((MangaRubyAnnotation a, MangaRubyAnnotation b) {
      final int byBlock = a.baseBlock.compareTo(b.baseBlock);
      if (byBlock != 0) return byBlock;
      final int byLine = a.line.compareTo(b.line);
      if (byLine != 0) return byLine;
      final int byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.end.compareTo(b.end);
    });
  final List<MangaRubyAnnotation> out = <MangaRubyAnnotation>[];
  for (final MangaRubyAnnotation a in sorted) {
    final MangaRubyAnnotation? last = out.isEmpty ? null : out.last;
    if (last != null &&
        last.baseBlock == a.baseBlock &&
        last.line == a.line &&
        a.start < last.end) {
      out[out.length - 1] = MangaRubyAnnotation(
        rubyBlock: last.rubyBlock,
        baseBlock: last.baseBlock,
        line: last.line,
        start: last.start,
        end: math.max(last.end, a.end),
        reading: last.reading + a.reading,
      );
    } else {
      out.add(a);
    }
  }
  return out;
}

final RegExp _kanaOnlyPattern = RegExp(r'^[぀-ヿㇰ-ㇿｦ-ﾝー]+$');

bool _kanaOnly(String text) =>
    text.isNotEmpty && _kanaOnlyPattern.hasMatch(text);

final RegExp _kanjiPattern = RegExp(r'[々㐀-䶿一-鿿豈-﫿]');
final RegExp _latinOrDigitPattern = RegExp(r'[A-Za-z0-9０-９Ａ-Ｚａ-ｚ]');

/// 能被注音的字：汉字、拉丁字母、数字。
bool _annotatable(String char) =>
    _kanjiPattern.hasMatch(char) || _latinOrDigitPattern.hasMatch(char);

bool _latinOrDigit(String char) => _latinOrDigitPattern.hasMatch(char);

double _axisOverlap(MokuroRect a, MokuroRect b, {required bool vertical}) {
  if (vertical) {
    return math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  }
  return math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));
}

double _axisLength(MokuroRect rect, {required bool vertical}) =>
    vertical ? rect.height : rect.width;

double _crossThickness(MokuroRect rect, {required bool vertical}) =>
    vertical ? rect.width : rect.height;

double _crossGap(MokuroRect a, MokuroRect b, {required bool vertical}) {
  if (vertical) {
    return math.max(0, math.max(a.left, b.left) - math.min(a.right, b.right));
  }
  return math.max(0, math.max(a.top, b.top) - math.min(a.bottom, b.bottom));
}

/// [candidate] 很可能是 [base] 的注音时返回两者在交叉方向的间距，否则 null。
/// 不检查 [candidate] 是否全假名（调用方先查）。
double? mangaRubyGap(MokuroBlock candidate, MokuroBlock base) {
  if (candidate.isVertical != base.isVertical) return null;
  final String baseText = base.lines.join();
  if (!_kanjiPattern.hasMatch(baseText) &&
      !_latinOrDigitPattern.hasMatch(baseText)) {
    return null;
  }
  final bool vertical = candidate.isVertical;
  final double candidateThickness = _crossThickness(
    candidate.rectangle,
    vertical: vertical,
  );
  final double baseThickness = _crossThickness(
    base.rectangle,
    vertical: vertical,
  );
  if (candidateThickness <= 0 ||
      baseThickness <= 0 ||
      candidateThickness > baseThickness * 0.68) {
    return null;
  }
  // 竖排注音在底本右侧，横排在上方。
  final bool annotationSide = vertical
      ? candidate.rectangle.center.dx > base.rectangle.center.dx
      : candidate.rectangle.center.dy < base.rectangle.center.dy;
  if (!annotationSide) return null;
  final double candidateLength = _axisLength(
    candidate.rectangle,
    vertical: vertical,
  );
  final double baseLength = _axisLength(base.rectangle, vertical: vertical);
  final double overlap = _axisOverlap(
    candidate.rectangle,
    base.rectangle,
    vertical: vertical,
  );
  if (candidateLength <= 0 ||
      baseLength <= 0 ||
      overlap / math.min(candidateLength, baseLength) < 0.45) {
    return null;
  }
  final double gap = _crossGap(
    candidate.rectangle,
    base.rectangle,
    vertical: vertical,
  );
  final double maximumGap = math.max(6.0, base.fontSize * 0.45);
  return gap <= maximumGap ? gap : null;
}

/// 底本一行的几何：沿行方向的起止 [axisStart]..[axisEnd]，交叉方向的中心 [cross]。
typedef _LineBox = ({double axisStart, double axisEnd, double cross});

/// 底本块各行的几何。`lines_coords` 与行数一致时用它的外接框；否则把块框按行数均分
/// （竖排右起、横排上起），每行从块首起、按「最长一行占满块长」的字距排。
List<_LineBox> _lineBoxes(MokuroBlock base) {
  final bool vertical = base.isVertical;
  final MokuroRect rect = base.rectangle;
  final List<String> lines = base.lines;
  final List<List<List<double>>>? coords = base.linesCoords;
  if (coords != null && coords.length == lines.length) {
    final List<_LineBox> boxes = <_LineBox>[];
    for (final List<List<double>> polygon in coords) {
      final Iterable<List<double>> points = polygon.where(
        (List<double> p) => p.length >= 2,
      );
      if (points.isEmpty) return _evenLineBoxes(base);
      final double minX = points.map((List<double> p) => p[0]).reduce(math.min);
      final double maxX = points.map((List<double> p) => p[0]).reduce(math.max);
      final double minY = points.map((List<double> p) => p[1]).reduce(math.min);
      final double maxY = points.map((List<double> p) => p[1]).reduce(math.max);
      boxes.add(
        vertical
            ? (axisStart: minY, axisEnd: maxY, cross: (minX + maxX) / 2)
            : (axisStart: minX, axisEnd: maxX, cross: (minY + maxY) / 2),
      );
    }
    return boxes;
  }
  if (rect.isEmpty || lines.isEmpty) return const <_LineBox>[];
  return _evenLineBoxes(base);
}

List<_LineBox> _evenLineBoxes(MokuroBlock base) {
  final bool vertical = base.isVertical;
  final MokuroRect rect = base.rectangle;
  final List<String> lines = base.lines;
  final int n = lines.length;
  final int longest = lines.map((String l) => l.runes.length).fold(0, math.max);
  if (n == 0 || longest == 0) return const <_LineBox>[];
  final double thickness = _crossThickness(rect, vertical: vertical) / n;
  final double pitch = _axisLength(rect, vertical: vertical) / longest;
  final double axisOrigin = vertical ? rect.top : rect.left;
  return <_LineBox>[
    for (int i = 0; i < n; i++)
      (
        axisStart: axisOrigin,
        axisEnd: axisOrigin + pitch * lines[i].runes.length,
        cross: vertical
            ? rect.right - thickness * (i + 0.5)
            : rect.top + thickness * (i + 0.5),
      ),
  ];
}

/// 注音块 [ruby] 注在 [base] 的哪一行、哪几个字（UTF-16 区间）；定不出返回 null。
({int line, int start, int end})? _rubySpan(
  MokuroBlock ruby,
  MokuroBlock base,
) {
  final bool vertical = base.isVertical;
  final MokuroRect r = ruby.rectangle;
  final double rubyStart = vertical ? r.top : r.left;
  final double rubyEnd = vertical ? r.bottom : r.right;
  final double rubyCross = vertical ? r.center.dx : r.center.dy;
  final List<_LineBox> boxes = _lineBoxes(base);

  // 注音一侧最近的那一行（竖排：注音左边 x 最大的；横排：注音下边 y 最小的）。
  int? lineIndex;
  for (int i = 0; i < boxes.length; i++) {
    final _LineBox box = boxes[i];
    final double overlap =
        math.min(box.axisEnd, rubyEnd) - math.max(box.axisStart, rubyStart);
    if (overlap <= 0) continue;
    final bool onBaseSide = vertical
        ? box.cross < rubyCross
        : box.cross > rubyCross;
    if (!onBaseSide) continue;
    if (lineIndex == null ||
        (vertical
            ? box.cross > boxes[lineIndex].cross
            : box.cross < boxes[lineIndex].cross)) {
      lineIndex = i;
    }
  }
  if (lineIndex == null) return null;

  final String text = base.lines[lineIndex];
  final List<({int start, int end, String char})> chars =
      <({int start, int end, String char})>[];
  int offset = 0;
  for (final int rune in text.runes) {
    final String char = String.fromCharCode(rune);
    chars.add((start: offset, end: offset + char.length, char: char));
    offset += char.length;
  }
  if (chars.isEmpty) return null;
  final _LineBox box = boxes[lineIndex];
  final double pitch = (box.axisEnd - box.axisStart) / chars.length;
  if (pitch <= 0) return null;

  int first = -1;
  int last = -1;
  for (int k = 0; k < chars.length; k++) {
    final double s = box.axisStart + pitch * k;
    final double overlap =
        math.min(s + pitch, rubyEnd) - math.max(s, rubyStart);
    if (overlap >= pitch * 0.5) {
      if (first < 0) first = k;
      last = k;
    }
  }
  if (first < 0) return null;
  // 首尾不能被注音的字（假名、标点）不算底本。
  while (first <= last && !_annotatable(chars[first].char)) {
    first++;
  }
  while (last >= first && !_annotatable(chars[last].char)) {
    last--;
  }
  if (first > last) return null;
  // 拉丁字母 / 数字按整词：注音不会只注半个单词。
  if (_latinOrDigit(chars[first].char)) {
    while (first > 0 && _latinOrDigit(chars[first - 1].char)) {
      first--;
    }
  }
  if (_latinOrDigit(chars[last].char)) {
    while (last < chars.length - 1 && _latinOrDigit(chars[last + 1].char)) {
      last++;
    }
  }
  return (line: lineIndex, start: chars[first].start, end: chars[last].end);
}
