/// 「OCR 忽略振假名」（反馈 ZBJTgLuPIb）：逐列 CTC 识别前，把贴在正文列 / 行旁边
/// 的小号注音带从行框里裁掉。
///
/// 为什么还要这一步：[dropOcrRubyLines]（`ocr_line_layout.dart`）只能删掉被行检测器
/// **单独检出**的注音列。注音紧贴正文、行检测器把两者检成**同一条**行框时，裁出的
/// 列图里正文旁边就带着一条注音——CTC 把它当正文的一部分读，汉字被读成别的字或
/// 混进假名（用户在注音密集的《葬送のフリーレン》上用 Manga CTC 遇到的就是这个）。
///
/// 做法是在**行框内部**看墨迹：沿跨轴（竖排是 x、横排是 y）统计每一条像素线上的
/// 墨迹量，连续有墨迹的位置合成「带」。正文列是墨迹最多的那条带；位于它外侧、
/// 宽度不到正文带 [kOcrRubyBandRatio] 倍、墨迹量也明显更少的带就是注音，裁掉。
/// 只裁行框的跨轴两侧，沿阅读方向的长度不动；判不出（对比度不够 / 只有一条带 /
/// 行框太细）时原样返回，绝不比不开时更差。
///
/// 这只是不读来源自带的注音，不生成任何读音。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 注音带宽度上限：正文带宽的这么多倍。注音字号一般是正文的 0.4~0.6。
const double kOcrRubyBandRatio = 0.65;

/// 注音带墨迹量上限：正文带墨迹量的这么多倍（注音只标在部分汉字旁，又小又稀）。
const double kOcrRubyMassRatio = 0.5;

/// 墨迹 / 底色的最小亮度差；低于它说明这块没有可分辨的文字，不动。
const int _kMinContrast = 48;

/// 裁掉 [line]（页面坐标）跨轴两侧的注音带，返回裁后的行框；没有可裁的返回
/// [line] 本身。[vertical] 为真时跨轴是 x（竖排注音在列右侧，也兼顾左侧——
/// 相邻列的注音会伸进本列框的左缘），否则跨轴是 y。
OcrRect trimOcrRubyBands(
  img.Image page,
  OcrRect line, {
  required bool vertical,
}) {
  final _InkBands? ink = _inkBandsOf(page, line, vertical: vertical);
  if (ink == null) return line;
  final List<({int start, int end, int mass})> bands = ink.bands;
  final int cross = ink.cross;
  final int x0 = ink.x0;
  final int y0 = ink.y0;
  if (bands.length < 2) return line;

  int mainIndex = 0;
  for (int i = 1; i < bands.length; i++) {
    if (bands[i].mass > bands[mainIndex].mass) mainIndex = i;
  }
  final ({int start, int end, int mass}) main = bands[mainIndex];
  final int mainWidth = main.end - main.start;
  bool isRuby(({int start, int end, int mass}) band) =>
      band.end - band.start < kOcrRubyBandRatio * mainWidth &&
      band.mass < kOcrRubyMassRatio * main.mass;

  // 从两侧往里剥注音带，碰到不像注音的带（另一列正文）就停。
  int first = 0;
  while (first < mainIndex && isRuby(bands[first])) {
    first++;
  }
  int last = bands.length - 1;
  while (last > mainIndex && isRuby(bands[last])) {
    last--;
  }
  if (first == 0 && last == bands.length - 1) return line;

  // 新边界落在被剥掉那条带与保留带之间空隙的中点：留出半个空隙的白边，
  // 不贴着笔画裁。
  final int keepStart = first == 0
      ? 0
      : (bands[first - 1].end + bands[first].start) ~/ 2;
  final int keepEnd = last == bands.length - 1
      ? cross
      : (bands[last].end + bands[last + 1].start + 1) ~/ 2;
  if (keepEnd - keepStart < 1) return line;
  return vertical
      ? OcrRect(
          left: (x0 + keepStart).toDouble(),
          top: line.top,
          right: (x0 + keepEnd).toDouble(),
          bottom: line.bottom,
        )
      : OcrRect(
          left: line.left,
          top: (y0 + keepStart).toDouble(),
          right: line.right,
          bottom: (y0 + keepEnd).toDouble(),
        );
}

/// [line] 夹进页面后的跨轴墨迹带（[_inkBandsOf]）。
class _InkBands {
  const _InkBands({
    required this.x0,
    required this.y0,
    required this.cross,
    required this.bands,
  });

  /// 行框左上角的页面像素坐标（带的位置从它算起）。
  final int x0;
  final int y0;

  /// 行框的跨轴像素数（竖排是宽、横排是高）。
  final int cross;

  /// 连续有墨迹的跨轴区间 `[start, end)` 与各自的墨迹量，按位置升序。
  final List<({int start, int end, int mass})> bands;
}

/// 在 [line] 内沿跨轴（竖排是 x、横排是 y）统计墨迹，连续有墨迹的位置合成带。
/// 行框太细 / 对比度不够（没有可分辨的文字）时返回 null。
_InkBands? _inkBandsOf(img.Image page, OcrRect line, {required bool vertical}) {
  final OcrRect clamped = line.clamp(
    page.width.toDouble(),
    page.height.toDouble(),
  );
  final int x0 = clamped.left.floor();
  final int y0 = clamped.top.floor();
  final int x1 = math.min(page.width, clamped.right.ceil());
  final int y1 = math.min(page.height, clamped.bottom.ceil());
  final int w = x1 - x0;
  final int h = y1 - y0;
  final int cross = vertical ? w : h;
  final int along = vertical ? h : w;
  if (cross < 6 || along < 4) return null;

  // 亮度表与对比度。
  final List<int> lum = List<int>.filled(w * h, 0);
  int lo = 255;
  int hi = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final img.Pixel p = page.getPixel(x0 + x, y0 + y);
      final int l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(
        0,
        255,
      );
      lum[y * w + x] = l;
      if (l < lo) lo = l;
      if (l > hi) hi = l;
    }
  }
  if (hi - lo < _kMinContrast) return null;
  final int threshold = (lo + hi) ~/ 2;
  int dark = 0;
  for (final int l in lum) {
    if (l < threshold) dark++;
  }
  // 墨迹是少数的那一类：黑字白底取暗、白字黑底（反白台词）取亮。
  final bool inkIsDark = dark * 2 <= lum.length;
  bool isInk(int l) => inkIsDark ? l < threshold : l >= threshold;

  // 跨轴墨迹投影。
  final List<int> profile = List<int>.filled(cross, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (isInk(lum[y * w + x])) profile[vertical ? x : y]++;
    }
  }
  final int minInk = math.max(1, (along * 0.01).round());
  final List<({int start, int end, int mass})> bands =
      <({int start, int end, int mass})>[];
  int? start;
  int mass = 0;
  for (int c = 0; c <= cross; c++) {
    final bool inked = c < cross && profile[c] >= minInk;
    if (inked) {
      start ??= c;
      mass += profile[c];
    } else if (start != null) {
      bands.add((start: start, end: c, mass: mass));
      start = null;
      mass = 0;
    }
  }
  return _InkBands(x0: x0, y0: y0, cross: cross, bands: bands);
}

/// 同一列正文内部的空隙上限：行框跨轴宽度的这么多倍。「い」「り」「川」这类字
/// 中间有一道贯通的空白，一列全是它们时墨迹投影会断成两条带；注音与正文之间的
/// 空隙也在这个量级，所以只用于量**单独一条行框**的字宽，不用于框内裁注音。
const double kOcrGlyphInnerGapRatio = 0.2;

/// [line] 里正文的墨迹厚度（跨轴像素数）：把相隔不超过
/// [kOcrGlyphInnerGapRatio] 倍框宽的墨迹带并成一组，取墨迹量最大那组的跨度。
/// 判不出（行框太细 / 没有可分辨的文字）返回 null。
///
/// 行检测器的框厚是连通域外扩出来的，同一段正文的各列能差出三成；墨迹厚度直接
/// 量字，注音约为正文的一半。
double? ocrLineInkThickness(
  img.Image page,
  OcrRect line, {
  required bool vertical,
}) {
  final _InkBands? ink = _inkBandsOf(page, line, vertical: vertical);
  if (ink == null || ink.bands.isEmpty) return null;
  final double maxGap = kOcrGlyphInnerGapRatio * ink.cross;
  int bestMass = -1;
  int bestSpan = 0;
  int groupStart = ink.bands.first.start;
  int groupEnd = ink.bands.first.end;
  int groupMass = ink.bands.first.mass;
  void close() {
    if (groupMass > bestMass) {
      bestMass = groupMass;
      bestSpan = groupEnd - groupStart;
    }
  }

  for (int i = 1; i < ink.bands.length; i++) {
    final ({int start, int end, int mass}) band = ink.bands[i];
    if (band.start - groupEnd <= maxGap) {
      groupEnd = band.end;
      groupMass += band.mass;
    } else {
      close();
      groupStart = band.start;
      groupEnd = band.end;
      groupMass = band.mass;
    }
  }
  close();
  return bestSpan.toDouble();
}

/// 按墨迹复核的注音字宽上限：字宽不到相邻正文字宽的这么多倍才可能是注音。
/// 注音字号一般是正文的 0.4~0.6。
const double kOcrRubyInkRatio = 0.7;

/// 按墨迹复核的注音贴靠上限：与相邻正文之间的空白不到正文字宽的这么多倍才算
/// 贴着正文。注音紧挨着它标注的字（空白约 0~0.1 个字宽）；同一气泡里字号小一号
/// 的独立正文列（括号里的补充说明、手写旁白）与旁边一列隔着正常的列距（0.25
/// 个字宽以上）。
const double kOcrRubyHugRatio = 0.25;

/// 字宽不到相邻正文的这么多倍时不看贴靠、直接算注音：独立的正文列再小也有
/// 正文的一半大（实测 0.55~0.6），小到这个程度的只有注音和框里混进来的杂点。
const double kOcrRubyTinyInkRatio = 0.45;

/// [dropOcrRubyLines] 加一步按墨迹的复核：只按行框几何判成注音的行，量它框内的
/// 字宽（[ocrLineInkThickness]）和它与相邻保留行之间的空白，**字小且贴着正文**
/// 才是注音；否则是正文，留下。
///
/// 为什么要复核：行框厚度是检测器连通域外扩出来的，多列竖排里短列、含竖排数字
/// 的列与相邻列的框厚能差出两三成，[dropOcrRubyLines] 的 `sideRatio` 口径会把
/// 贴着较厚一列的正文短列（「あ？」「でも…」「は〜〜〜」）当注音整列删掉——
/// JMangaBench_Read 前 1,480 框里，这一项占全部字错的四成。量不出字宽的行
/// （对比度不够等）维持几何判定。
List<OcrRect> dropOcrRubyLinesByInk(
  img.Image page,
  List<OcrRect> lines, {
  required bool vertical,
}) {
  final List<OcrRect> kept = dropOcrRubyLines(lines, vertical: vertical);
  if (kept.length == lines.length) return kept;
  bool isKept(OcrRect line) => kept.any((OcrRect k) => identical(k, line));
  return <OcrRect>[
    for (final OcrRect line in lines)
      if (isKept(line) || !_isInkRuby(page, line, kept, vertical: vertical))
        line,
  ];
}

/// 几何上像注音的 [candidate] 按墨迹看是不是注音：比最近的保留行 [kept] 字小
/// （[kOcrRubyInkRatio]）且贴着它（[kOcrRubyHugRatio]）。量不出时按注音处理
/// （维持几何判定）。
bool _isInkRuby(
  img.Image page,
  OcrRect candidate,
  List<OcrRect> kept, {
  required bool vertical,
}) {
  double crossStart(OcrRect r) => vertical ? r.left : r.top;
  double crossEnd(OcrRect r) => vertical ? r.right : r.bottom;
  double alongStart(OcrRect r) => vertical ? r.top : r.left;
  double alongEnd(OcrRect r) => vertical ? r.bottom : r.right;
  // 候选框与旁边保留行的框有交叠时，交叠那一段里是邻行的字：注音框常常压着它
  // 标注的那一列的边，连着邻行的墨迹一起量会把注音量成正文字宽（全注音的少年
  // 漫画里 23px 的注音框量出 23px「字宽」）。只在候选框自己独占的那一段里量；
  // 交叠过半的（候选整个落在一条压住两列的厚框里）框本身不可信，不裁。
  double lo = crossStart(candidate);
  double hi = crossEnd(candidate);
  final double thickness = hi - lo;
  for (final OcrRect line in kept) {
    if (math.min(alongEnd(line), alongEnd(candidate)) <=
        math.max(alongStart(line), alongStart(candidate))) {
      continue;
    }
    final double overlap =
        math.min(crossEnd(line), crossEnd(candidate)) -
        math.max(crossStart(line), crossStart(candidate));
    if (overlap <= 0 || overlap * 2 >= thickness) continue;
    if (crossStart(line) + crossEnd(line) <
        crossStart(candidate) + crossEnd(candidate)) {
      lo = math.max(lo, crossEnd(line));
    } else {
      hi = math.min(hi, crossStart(line));
    }
  }
  // 两边的保留行把它挤得不剩什么：夹在两列之间的只能是注音。
  if (hi - lo < 1) return true;
  final OcrRect own0 = vertical
      ? OcrRect(
          left: lo,
          top: candidate.top,
          right: hi,
          bottom: candidate.bottom,
        )
      : OcrRect(
          left: candidate.left,
          top: lo,
          right: candidate.right,
          bottom: hi,
        );
  final double? own = ocrLineInkThickness(page, own0, vertical: vertical);
  if (own == null) return true;
  // 最近的保留行：沿阅读方向有重叠的里面，跨轴距离最小的那条。
  OcrRect? base;
  double bestDistance = double.infinity;
  for (final OcrRect line in kept) {
    final double along =
        math.min(alongEnd(line), alongEnd(candidate)) -
        math.max(alongStart(line), alongStart(candidate));
    if (along <= 0) continue;
    final double distance = math.max(
      0,
      math.max(crossStart(line), crossStart(candidate)) -
          math.min(crossEnd(line), crossEnd(candidate)),
    );
    final double centers =
        ((crossStart(line) + crossEnd(line)) -
                (crossStart(candidate) + crossEnd(candidate)))
            .abs();
    final double score = distance * 1e6 + centers;
    if (score < bestDistance) {
      bestDistance = score;
      base = line;
    }
  }
  if (base == null) {
    // 旁边没有正文行：只剩「比块内正文细得多」这一条几何判据，按字宽对比。
    final List<double> body = <double>[
      for (final OcrRect line in kept)
        ?ocrLineInkThickness(page, line, vertical: vertical),
    ]..sort();
    if (body.isEmpty) return true;
    return own < kOcrRubyInkRatio * body[body.length ~/ 2];
  }
  final double? em = ocrLineInkThickness(page, base, vertical: vertical);
  if (em == null) return true;
  if (own >= kOcrRubyInkRatio * em) return false;
  if (own < kOcrRubyTinyInkRatio * em) return true;
  final double? gap = _inkGapBetween(page, candidate, base, vertical: vertical);
  if (gap == null) return true;
  return gap < kOcrRubyHugRatio * em;
}

/// [candidate] 与 [base] 两条行之间的空白（跨轴像素数）：在两者跨轴范围的并集、
/// 沿阅读方向的交集里做墨迹投影，取各自中心所在墨迹带之间最宽的一道空隙；
/// 两者的墨迹连成一条带时为 0。量不出返回 null。
double? _inkGapBetween(
  img.Image page,
  OcrRect candidate,
  OcrRect base, {
  required bool vertical,
}) {
  final OcrRect region = vertical
      ? OcrRect(
          left: math.min(candidate.left, base.left),
          top: math.max(candidate.top, base.top),
          right: math.max(candidate.right, base.right),
          bottom: math.min(candidate.bottom, base.bottom),
        )
      : OcrRect(
          left: math.max(candidate.left, base.left),
          top: math.min(candidate.top, base.top),
          right: math.min(candidate.right, base.right),
          bottom: math.max(candidate.bottom, base.bottom),
        );
  final _InkBands? ink = _inkBandsOf(page, region, vertical: vertical);
  if (ink == null || ink.bands.isEmpty) return null;
  final int origin = vertical ? ink.x0 : ink.y0;
  int nearest(OcrRect line) {
    final double center =
        (vertical ? line.left + line.right : line.top + line.bottom) / 2 -
        origin;
    int best = 0;
    double bestDistance = double.infinity;
    for (int i = 0; i < ink.bands.length; i++) {
      final ({int start, int end, int mass}) band = ink.bands[i];
      final double distance = center < band.start
          ? band.start - center
          : center > band.end
          ? center - band.end
          : 0;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  final int a = nearest(candidate);
  final int b = nearest(base);
  int widest = 0;
  for (int i = math.min(a, b); i < math.max(a, b); i++) {
    widest = math.max(widest, ink.bands[i + 1].start - ink.bands[i].end);
  }
  return widest.toDouble();
}
