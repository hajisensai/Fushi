/// PDF 文字层 → 漫画 OCR 块（`manga.json`）的纯几何部分。
///
/// PDF 转成漫画时页图是 PDFium 栅格化出来的，而带文字层的 PDF（排版生成的小说 /
/// 杂志）里每个字的位置本来就是已知的：拿它直接生成文字块，逐字命中区就是字的
/// 真实位置。OCR 只能给到行框、再按字数均分，竖排里「、」「……」「──」占的高度
/// 和普通字不同，越往列尾偏得越多。
///
/// 本文件只做与 PDFium 无关的事（app 侧 `pdf_text_layer_backfill.dart` 负责取字）：
/// - [buildPdfTextLayerBlocks]：一页的逐字坐标 → 行 → 段落块（含逐字 regions）；
/// - [preservePdfTextLayer] / [preservePdfTextLayerPage]：OCR / 别的写者覆写
///   `manga.json` 时把文字层块保留下来；
/// - [mangaVolumeOcrSettled]：「这卷还要不要自动 OCR」——文字层块不算识别结果，
///   否则混排 PDF 里的扫描页永远等不到 OCR。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 文字层提取规则的版本，写进 `manga.json` 的 `pdf_text_layer_version`。改了
/// 切行 / 分块规则需要老书重提时加一。
const int kPdfTextLayerVersion = 1;

/// 一页文字层至少有这么多个字，才算「这页的正文就是文字层」：OCR 结果在这页整页
/// 丢弃。少于这个数（扫描页上只嵌了页码 / 页眉）时只丢与文字层块重叠的 OCR 块，
/// 页面其余部分照用 OCR。
const int kPdfTextLayerCompletePageMinChars = 20;

/// OCR 块与文字层块的交叠面积占 OCR 块面积到这个比例，就认为是同一段字，丢 OCR 的。
const double _kOcrOverlapDropRatio = 0.3;

/// PDF 文字层里的一个字：文本（一个字素）+ 页图像素坐标（左上原点）。
class PdfTextLayerGlyph {
  const PdfTextLayerGlyph({required this.text, required this.rect});

  final String text;
  final MokuroRect rect;
}

/// 把 PDFium 的 `fullText` / 逐字框（已换算成页图像素）配成 [PdfTextLayerGlyph]。
///
/// PDFium 的字下标与 Dart 字符串下标未必一一对应：多数实现逐 UTF-16 单元给框，
/// 也有逐码点给的（补充平面字符会差一位）。两种都认；都对不上返回空表——这页
/// 交回 OCR，而不是拿错位的框冒充真值。空白字符与空框（PDFium 生成的换行 /
/// 空格）丢弃；组合字符（浊点、变体选择符）并进前一个字，保证每个字落在字素
/// 边界上（覆盖层的 `mangaTextRegionsMatchSentence` 只认字素边界）。
List<PdfTextLayerGlyph> pdfTextLayerGlyphs(
  String fullText,
  List<MokuroRect> rects,
) {
  final List<({String text, MokuroRect rect})> units =
      <({String text, MokuroRect rect})>[];
  if (fullText.length == rects.length) {
    int offset = 0;
    for (final String grapheme in fullText.characters) {
      MokuroRect? box;
      for (int i = offset; i < offset + grapheme.length; i++) {
        box = _union(box, rects[i]);
      }
      units.add((text: grapheme, rect: box ?? MokuroRect.zero));
      offset += grapheme.length;
    }
  } else {
    final List<int> runes = fullText.runes.toList();
    if (runes.length != rects.length) return const <PdfTextLayerGlyph>[];
    // 逐码点给框：先配码点，再按字素合并。
    final List<int> runeOffsets = <int>[];
    int offset = 0;
    for (final int rune in runes) {
      runeOffsets.add(offset);
      offset += rune > 0xFFFF ? 2 : 1;
    }
    int runeIndex = 0;
    int unitOffset = 0;
    for (final String grapheme in fullText.characters) {
      MokuroRect? box;
      final int end = unitOffset + grapheme.length;
      while (runeIndex < runes.length && runeOffsets[runeIndex] < end) {
        box = _union(box, rects[runeIndex]);
        runeIndex++;
      }
      units.add((text: grapheme, rect: box ?? MokuroRect.zero));
      unitOffset = end;
    }
  }
  return <PdfTextLayerGlyph>[
    for (final ({String text, MokuroRect rect}) unit in units)
      if (unit.text.trim().isNotEmpty && !unit.rect.isEmpty)
        PdfTextLayerGlyph(text: unit.text, rect: unit.rect),
  ];
}

MokuroRect? _union(MokuroRect? a, MokuroRect b) {
  if (b.isEmpty) return a;
  if (a == null) return b;
  return MokuroRect.fromLTRB(
    math.min(a.left, b.left),
    math.min(a.top, b.top),
    math.max(a.right, b.right),
    math.max(a.bottom, b.bottom),
  );
}

enum _Axis { vertical, horizontal, unknown }

class _Line {
  _Line(PdfTextLayerGlyph first) : glyphs = <PdfTextLayerGlyph>[first];

  final List<PdfTextLayerGlyph> glyphs;
  _Axis axis = _Axis.unknown;

  MokuroRect get bounds {
    MokuroRect? box;
    for (final PdfTextLayerGlyph glyph in glyphs) {
      box = _union(box, glyph.rect);
    }
    return box!;
  }

  /// 行的「粗细」：竖排看列宽、横排看行高（单字行取两者较大）。字号与分块都按它比。
  double get crossExtent {
    final MokuroRect b = bounds;
    return switch (axis) {
      _Axis.vertical => b.width,
      _Axis.horizontal => b.height,
      _Axis.unknown => math.max(b.width, b.height),
    };
  }

  String get text => glyphs.map((PdfTextLayerGlyph g) => g.text).join();
}

double _overlap(double a0, double a1, double b0, double b1) =>
    math.max(0, math.min(a1, b1) - math.max(a0, b0));

/// [next] 能不能接在 [line] 后面（同一行 / 同一列）。返回接上后的方向，接不上 null。
///
/// 竖排：横向与上一个字重叠过较窄者的一半、在它下方、间隙不超过 1.5 个字宽；
/// 横排对称。PDF 内容流的字序就是排版顺序，所以只看「上一个字 → 这个字」。
_Axis? _continuation(_Line line, PdfTextLayerGlyph next) {
  final MokuroRect last = line.glyphs.last.rect;
  final MokuroRect r = next.rect;
  final double size = math.max(
    line.crossExtent,
    math.max(math.min(r.width, r.height), 1),
  );
  final bool vertical =
      _overlap(last.left, last.right, r.left, r.right) >=
          0.5 * math.min(last.width, r.width) &&
      r.center.dy > last.center.dy &&
      r.top - last.bottom <= 1.5 * size;
  final bool horizontal =
      _overlap(last.top, last.bottom, r.top, r.bottom) >=
          0.5 * math.min(last.height, r.height) &&
      r.center.dx > last.center.dx &&
      r.left - last.right <= 1.5 * size;
  switch (line.axis) {
    case _Axis.vertical:
      return vertical ? _Axis.vertical : null;
    case _Axis.horizontal:
      return horizontal ? _Axis.horizontal : null;
    case _Axis.unknown:
      if (vertical && horizontal) {
        return (r.center.dy - last.center.dy).abs() >=
                (r.center.dx - last.center.dx).abs()
            ? _Axis.vertical
            : _Axis.horizontal;
      }
      if (vertical) return _Axis.vertical;
      if (horizontal) return _Axis.horizontal;
      return null;
  }
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final List<double> sorted = List<double>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

/// [next] 能不能和 [previous] 并进同一个段落块：同方向、粗细相近、在阅读序上紧挨着
/// （竖排在左边一列、横排在下一行），且主轴范围有交叠。
bool _sameBlock(_Line previous, _Line next, _Axis axis) {
  if (previous.axis != axis || next.axis != axis) return false;
  final double a = previous.crossExtent;
  final double b = next.crossExtent;
  if (a <= 0 || b <= 0 || math.max(a, b) / math.min(a, b) > 1.4) return false;
  final double size = math.max(a, b);
  final MokuroRect p = previous.bounds;
  final MokuroRect n = next.bounds;
  if (axis == _Axis.vertical) {
    final double gap = p.left - n.right;
    return gap >= -0.5 * size &&
        gap <= 1.5 * size &&
        _overlap(p.top, p.bottom, n.top, n.bottom) > 0;
  }
  final double gap = n.top - p.bottom;
  return gap >= -0.5 * size &&
      gap <= 1.5 * size &&
      _overlap(p.left, p.right, n.left, n.right) > 0;
}

/// 一页的文字层字表 → 文字块。
///
/// 1. 沿内容流切行（[_continuation]）；单字行的方向取全页多数。
/// 2. 明显比正文细的行（注音假名）各自成块：覆盖层的分句逻辑会把「汉字旁的细假名
///    块」认成注音、不进例句；并进正文块就会把读音插进句子里。
/// 3. 其余行按 [_sameBlock] 合成段落块。
///
/// 每个字的命中区横向撑满整列（竖排）/ 整行高（横排），主轴上撑到与前后字的中点，
/// 字与字之间没有点不中的缝。
List<MokuroBlock> buildPdfTextLayerBlocks(List<PdfTextLayerGlyph> glyphs) {
  if (glyphs.isEmpty) return const <MokuroBlock>[];
  final List<_Line> lines = <_Line>[];
  for (final PdfTextLayerGlyph glyph in glyphs) {
    final _Line? current = lines.isEmpty ? null : lines.last;
    final _Axis? axis = current == null ? null : _continuation(current, glyph);
    if (current != null && axis != null) {
      current.axis = axis;
      current.glyphs.add(glyph);
    } else {
      lines.add(_Line(glyph));
    }
  }

  int verticalVotes = 0;
  int horizontalVotes = 0;
  for (final _Line line in lines) {
    if (line.axis == _Axis.vertical) verticalVotes += line.glyphs.length;
    if (line.axis == _Axis.horizontal) horizontalVotes += line.glyphs.length;
  }
  final _Axis dominant = verticalVotes > horizontalVotes
      ? _Axis.vertical
      : _Axis.horizontal;
  for (final _Line line in lines) {
    if (line.axis == _Axis.unknown) line.axis = dominant;
  }

  final double bodySize = _median(<double>[
    for (final _Line line in lines)
      for (int i = 0; i < line.glyphs.length; i++) line.crossExtent,
  ]);
  bool isAnnotation(_Line line) => line.crossExtent < 0.7 * bodySize;

  final List<List<_Line>> groups = <List<_Line>>[];
  List<_Line>? body;
  for (final _Line line in lines) {
    if (isAnnotation(line)) {
      groups.add(<_Line>[line]);
      continue;
    }
    if (body != null && _sameBlock(body.last, line, line.axis)) {
      body.add(line);
    } else {
      body = <_Line>[line];
      groups.add(body);
    }
  }

  return <MokuroBlock>[
    for (int i = 0; i < groups.length; i++) _blockFromLines(groups[i], i),
  ];
}

MokuroBlock _blockFromLines(List<_Line> lines, int zIndex) {
  final bool vertical = lines.first.axis == _Axis.vertical;
  final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
  final List<List<List<double>>> linesCoords = <List<List<double>>>[];
  MokuroRect? blockBox;
  int utf16 = 0;
  for (final _Line line in lines) {
    final MokuroRect lineBox = line.bounds;
    final List<PdfTextLayerGlyph> glyphs = line.glyphs;
    for (int i = 0; i < glyphs.length; i++) {
      final MokuroRect r = glyphs[i].rect;
      final MokuroRect? prev = i > 0 ? glyphs[i - 1].rect : null;
      final MokuroRect? next = i + 1 < glyphs.length
          ? glyphs[i + 1].rect
          : null;
      final MokuroRect cell = vertical
          ? MokuroRect.fromLTRB(
              lineBox.left,
              prev == null ? r.top : math.min(r.top, (prev.bottom + r.top) / 2),
              lineBox.right,
              next == null
                  ? r.bottom
                  : math.max(r.bottom, (r.bottom + next.top) / 2),
            )
          : MokuroRect.fromLTRB(
              prev == null
                  ? r.left
                  : math.min(r.left, (prev.right + r.left) / 2),
              lineBox.top,
              next == null
                  ? r.right
                  : math.max(r.right, (r.right + next.left) / 2),
              lineBox.bottom,
            );
      final int length = glyphs[i].text.length;
      regions.add(
        MangaOcrTextRegion(
          rectangle: cell,
          utf16Start: utf16,
          utf16End: utf16 + length,
        ),
      );
      utf16 += length;
      blockBox = _union(blockBox, cell);
    }
    linesCoords.add(<List<double>>[
      <double>[lineBox.left, lineBox.top],
      <double>[lineBox.right, lineBox.top],
      <double>[lineBox.right, lineBox.bottom],
      <double>[lineBox.left, lineBox.bottom],
    ]);
  }
  return MokuroBlock(
    rectangle: blockBox!,
    isVertical: vertical,
    fontSize: _median(<double>[
      for (final _Line line in lines) line.crossExtent,
    ]),
    zIndex: zIndex,
    lines: <String>[for (final _Line line in lines) line.text],
    linesCoords: linesCoords,
    regions: regions,
    pdfTextLayer: true,
  );
}

/// 一页的文字层块。
List<MokuroBlock> pdfTextLayerBlocksOf(MokuroImage page) => <MokuroBlock>[
  for (final MokuroBlock block in page.blocks)
    if (block.pdfTextLayer) block,
];

/// 这页的正文是否就是文字层（字数达到 [kPdfTextLayerCompletePageMinChars]）。
bool isPdfTextLayerCompletePage(MokuroImage page) {
  int count = 0;
  for (final MokuroBlock block in page.blocks) {
    if (!block.pdfTextLayer) continue;
    for (final String line in block.lines) {
      count += line.characters.length;
    }
  }
  return count >= kPdfTextLayerCompletePageMinChars;
}

/// 把 [layer]（文字层块）与 [page] 里的非文字层块（OCR 结果）合成一页。
///
/// 文字层优先：完整页（[isPdfTextLayerCompletePage]）丢掉全部 OCR 块；否则只丢
/// 与某个文字层块交叠的 OCR 块。[layer] 为空时原样返回 [page]。
MokuroImage composePdfTextLayerPage(MokuroImage page, List<MokuroBlock> layer) {
  if (layer.isEmpty) return page;
  final MokuroImage layerOnly = MokuroImage(
    url: page.url,
    size: page.size,
    blocks: layer,
  );
  final bool complete = isPdfTextLayerCompletePage(layerOnly);
  final List<MokuroBlock> others = <MokuroBlock>[
    if (!complete)
      for (final MokuroBlock block in page.blocks)
        if (!block.pdfTextLayer && !_overlapsAny(block.rectangle, layer)) block,
  ];
  return MokuroImage(
    url: page.url,
    size: page.size,
    blocks: <MokuroBlock>[...layer, ...others],
  );
}

bool _overlapsAny(MokuroRect rect, List<MokuroBlock> layer) {
  final double area = rect.width * rect.height;
  if (area <= 0) return false;
  for (final MokuroBlock block in layer) {
    final MokuroRect r = block.rectangle;
    final double shared =
        _overlap(rect.left, rect.right, r.left, r.right) *
        _overlap(rect.top, rect.bottom, r.top, r.bottom);
    if (shared >= _kOcrOverlapDropRatio * area) return true;
  }
  return false;
}

bool _sameSize(MokuroSize a, MokuroSize b) =>
    (a.width - b.width).abs() < 0.5 && (a.height - b.height).abs() < 0.5;

/// 新写入的 [incoming] 页（通常是 OCR 结果）合并 [current] 页上的文字层。
///
/// [incoming] 自己带文字层块就以它为准；否则沿用 [current] 的（尺寸必须一致——
/// 换了页图坐标系的旧文字层不能套到新图上）。
MokuroImage preservePdfTextLayerPage(
  MokuroImage current,
  MokuroImage incoming,
) {
  final List<MokuroBlock> own = pdfTextLayerBlocksOf(incoming);
  if (own.isNotEmpty) return composePdfTextLayerPage(incoming, own);
  if (!_sameSize(current.size, incoming.size)) return incoming;
  return composePdfTextLayerPage(incoming, pdfTextLayerBlocksOf(current));
}

/// 覆写 `manga.json` 前把磁盘上 [existing] 的文字层并进 [incoming]（按页 url 对应）。
///
/// 所有写书根 `manga.json` 的路径（整卷 OCR、向导、大模型识别）都经
/// `writeMangaJsonAtomically` 调这里，所以哪个引擎重跑都冲不掉文字层。[existing]
/// 没有文字层时原样返回 [incoming]。
MokuroPayload preservePdfTextLayer({
  required MokuroPayload incoming,
  required MokuroPayload? existing,
}) {
  final int? version =
      incoming.pdfTextLayerVersion ?? existing?.pdfTextLayerVersion;
  final Map<String, MokuroImage> previous = <String, MokuroImage>{
    if (existing != null)
      for (final MokuroImage page in existing.images)
        if (page.blocks.any((MokuroBlock b) => b.pdfTextLayer)) page.url: page,
  };
  if (version == incoming.pdfTextLayerVersion &&
      previous.isEmpty &&
      !incoming.images.any(
        (MokuroImage page) =>
            page.blocks.any((MokuroBlock b) => b.pdfTextLayer),
      )) {
    return incoming;
  }
  return MokuroPayload(
    images: <MokuroImage>[
      for (final MokuroImage page in incoming.images)
        previous[page.url] == null
            ? composePdfTextLayerPage(page, pdfTextLayerBlocksOf(page))
            : preservePdfTextLayerPage(previous[page.url]!, page),
    ],
    ocr: incoming.ocr,
    pdfTextLayerVersion: version,
  );
}

/// 把逐页的文字层字表套进 [payload]：[pages] 与 `payload.images` 按下标一一对应。
///
/// 页数对不上（PDF 与页图不是同一批）时不套任何块，只记版本——这卷交给 OCR，
/// 也不会每次开书重提。
MokuroPayload applyPdfTextLayer(
  MokuroPayload payload,
  List<List<PdfTextLayerGlyph>> pages,
) {
  final bool aligned = pages.length == payload.images.length;
  return MokuroPayload(
    images: <MokuroImage>[
      for (int i = 0; i < payload.images.length; i++)
        aligned
            ? composePdfTextLayerPage(
                payload.images[i],
                buildPdfTextLayerBlocks(pages[i]),
              )
            : payload.images[i],
    ],
    ocr: payload.ocr,
    pdfTextLayerVersion: kPdfTextLayerVersion,
  );
}

/// 这卷是否已识别过、不必再自动排整卷 OCR。
///
/// 与旧判据（有 OCR 元数据或任何文字块）的差别只在文字层块：它们不算识别结果。
/// 每页都是完整文字层的卷也算已识别（排版 PDF 根本不需要 OCR）。
bool mangaVolumeOcrSettled(MokuroPayload payload) {
  if (payload.ocr != null) return true;
  if (payload.images.any(
    (MokuroImage page) => page.blocks.any((MokuroBlock b) => !b.pdfTextLayer),
  )) {
    return true;
  }
  return payload.images.isNotEmpty &&
      payload.images.every(isPdfTextLayerCompletePage);
}
