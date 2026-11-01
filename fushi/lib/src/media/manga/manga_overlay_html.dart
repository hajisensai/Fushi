import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 把一页所有 mokuro block 渲染成绝对定位的透明 `<p class="ocr-box">` 层。
///
/// 关键不变式（依据 reader_selection_scripts.dart）：
/// - 每个 block 一个 `<p>`（findParagraph 认 p → 扫描 TreeWalker 根落框内，天然不跨框）。
/// - OCR 文本按字符区域拆成连续 span，DOM 顺序保持句子顺序且不插入 `\n`
///   （`\n` 是 scanDelimiter，会截断扫描）。
/// - 坐标取百分比（box / page.size），自适应缩放。
/// - 字号用容器查询单位 `cqi`（fontSize / img_width * 100），相对 `.manga-page`
///   容器的 inline-size（宽度）等比缩放，让透明文字铺满本页框、命中区域与可视框
///   一致。绝不用 `font-size:%`：% 相对父字号≈1.6px 会让透明文字塌缩到框角，导致
///   点击全部 miss（ERRATA H5）。spread 双页各自相对本页宽度，故用容器查询单位而
///   非 vh/vw（vh/vw 跨页共用视口会算错另一半页）。
///   用 `inline-size` 容器而非 `size`：`container-type:size` 建立两轴 size
///   containment，会让 img 驱动的页高塌成 0（容器尺寸不受后代影响）；
///   `inline-size` 只约束宽度轴，页高仍由 `<img height:auto>` 正常撑开。
/// - 竖排框 writing-mode:vertical-rl；文字 color:transparent；margin/padding 清零；
///   pointer-events:auto（仅底图 <img> 为 none）。
String mangaOcrBoxesHtml(MokuroImage page) {
  final double pageWidth = page.size.width <= 0 ? 1 : page.size.width;
  final double pageHeight = page.size.height <= 0 ? 1 : page.size.height;
  final List<({int group, String sentence})> sentenceAssignments =
      _mangaBlockSentenceAssignments(page);
  final StringBuffer buffer = StringBuffer();
  for (int blockIndex = 0; blockIndex < page.blocks.length; blockIndex++) {
    final MokuroBlock block = page.blocks[blockIndex];
    final MokuroRect r = block.rectangle;
    final double leftPct = (r.left / pageWidth) * 100;
    final double topPct = (r.top / pageHeight) * 100;
    final double widthPct = (r.width / pageWidth) * 100;
    final double heightPct = (r.height / pageHeight) * 100;
    // ERRATA H5：字号按页宽折算为容器查询 inline-size 单位（cqi），随 .manga-page
    // 容器宽度等比缩放，让透明文字铺满 OCR 框、命中区域与可视框一致。用 cqi 而非
    // cqh，因容器是 inline-size 类型（size 类型会塌缩 img 驱动的页高，见上方文档）。
    // ERRATA M1：mokuro 偶尔给 font_size==0（缺字段容错回退）→ font-size:0cqi 会把
    // 透明文字塌成 0 高、整框命中区域塌缩到原点，点框全 miss。给一个非零下限
    // （3cqi≈正常正文字号档），保证框始终可命中。
    final double rawCqi = (block.fontSize / pageWidth) * 100;
    final double fontCqi = rawCqi > 0 ? rawCqi : 3.0;
    final String writingMode = block.isVertical
        ? 'writing-mode:vertical-rl;'
        : '';
    final String orientation = block.isVertical ? 'vertical' : 'horizontal';
    final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
    final bool hasRegions = regions.isNotEmpty;
    final String inner = hasRegions
        ? _mangaCharacterRegionsHtml(block: block, regions: regions)
        : block.lines.map(_escapeHtml).join('<br>');
    buffer.write(
      '<p class="ocr-box" '
      'data-ocr-orientation="$orientation" '
      'data-manga-sentence="'
      '${_escapeAttr(sentenceAssignments[blockIndex].sentence)}" '
      'data-manga-sentence-group="'
      '${sentenceAssignments[blockIndex].group}" '
      'style="'
      'position:absolute;'
      'left:${_pct(leftPct)};'
      'top:${_pct(topPct)};'
      'width:${_pct(widthPct)};'
      'height:${_pct(heightPct)};'
      'font-size:${_num(fontCqi)}cqi;'
      '$writingMode'
      'color:transparent;'
      'margin:0;'
      'padding:0;'
      'pointer-events:${hasRegions ? 'none' : 'auto'};'
      '">$inner</p>',
    );
  }
  return buffer.toString();
}

/// Resolve the complete sentence represented by every OCR block on a page.
///
/// Google Lens often emits one paragraph per *vertical column*, not per speech
/// bubble. For example, the real One Piece page behind BUG-1333 produced four
/// neighbouring blocks `だいじょうぶ` (ruby), `大丈夫`, `だよな`, `?`.
/// Rendering each paragraph as an isolated `<p>` made mining capture only the
/// clicked column. This routine joins only geometrically adjacent columns/rows
/// until a strong sentence terminator, and maps the resulting sentence back to
/// every participating block. Existing single-block mokuro/local OCR remains
/// unchanged.
///
/// A narrow kana-only run immediately on the annotation side of a kanji run is
/// treated as furigana: it participates in the group (so clicking it still gets
/// the complete base sentence) but is omitted from the mined sentence itself.
@visibleForTesting
List<String> mangaBlockSentenceTexts(MokuroImage page) {
  return _mangaBlockSentenceAssignments(page)
      .map((({int group, String sentence}) assignment) => assignment.sentence)
      .toList(growable: false);
}

/// 句子分组 [group]（即 overlay 写进 `data-manga-sentence-group` 的那个组号）里全部
/// OCR 块的下标。组号与 [mangaOcrBoxesHtml] 同一次分组算出，所以 JS 回传的组号能
/// 原样映射回块。
List<int> mangaSentenceGroupBlockIndices(MokuroImage page, int group) {
  final List<({int group, String sentence})> assignments =
      _mangaBlockSentenceAssignments(page);
  return <int>[
    for (int i = 0; i < assignments.length; i++)
      if (assignments[i].group == group) i,
  ];
}

/// 这句话（句子分组 [group]）的 OCR 文本块并集，按 `page.size` 归一化到 0..1。
///
/// 制卡裁切要的是**相对原页图**的坐标；JS 回传的选区矩形是 WebView 视口 CSS 像素，
/// 宽页旋转 / 拆页 / 裁边都会让它和原页对不上，所以真值只能在 Dart 侧从 OCR 块算。
/// 组号不存在 / 页尺寸非法时返回 null。
Rect? mangaSentenceGroupNormalizedRect(MokuroImage page, int group) {
  final double pageWidth = page.size.width;
  final double pageHeight = page.size.height;
  if (pageWidth <= 0 || pageHeight <= 0) return null;
  final List<int> indices = mangaSentenceGroupBlockIndices(page, group);
  if (indices.isEmpty) return null;
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final int index in indices) {
    final MokuroRect r = page.blocks[index].rectangle;
    left = math.min(left, r.left);
    top = math.min(top, r.top);
    right = math.max(right, r.right);
    bottom = math.max(bottom, r.bottom);
  }
  double unit(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  final Rect rect = Rect.fromLTRB(
    unit(left / pageWidth),
    unit(top / pageHeight),
    unit(right / pageWidth),
    unit(bottom / pageHeight),
  );
  return rect.width > 0 && rect.height > 0 ? rect : null;
}

List<({int group, String sentence})> _mangaBlockSentenceAssignments(
  MokuroImage page,
) {
  final List<MokuroBlock> blocks = page.blocks;
  if (blocks.isEmpty) {
    return const <({int group, String sentence})>[];
  }

  final List<int> parents = List<int>.generate(blocks.length, (int i) => i);
  int rootOf(int value) {
    int root = value;
    while (parents[root] != root) {
      root = parents[root];
    }
    while (parents[value] != value) {
      final int next = parents[value];
      parents[value] = root;
      value = next;
    }
    return root;
  }

  void join(int a, int b) {
    final int rootA = rootOf(a);
    final int rootB = rootOf(b);
    if (rootA != rootB) {
      parents[rootB] = rootA;
    }
  }

  final Set<int> rubyBlocks = <int>{};
  for (
    int candidateIndex = 0;
    candidateIndex < blocks.length;
    candidateIndex++
  ) {
    final MokuroBlock candidate = blocks[candidateIndex];
    if (!_mangaKanaOnly(_mangaBlockText(candidate))) {
      continue;
    }
    int? closestBase;
    double closestGap = double.infinity;
    for (int baseIndex = 0; baseIndex < blocks.length; baseIndex++) {
      if (baseIndex == candidateIndex) {
        continue;
      }
      final MokuroBlock base = blocks[baseIndex];
      final double? gap = _mangaRubyGap(candidate, base);
      if (gap != null && gap < closestGap) {
        closestGap = gap;
        closestBase = baseIndex;
      }
    }
    if (closestBase != null) {
      rubyBlocks.add(candidateIndex);
      join(candidateIndex, closestBase);
    }
  }

  for (int i = 0; i < blocks.length; i++) {
    if (rubyBlocks.contains(i)) {
      continue;
    }
    for (int j = i + 1; j < blocks.length; j++) {
      if (rubyBlocks.contains(j) ||
          !_mangaBlocksAreAdjacent(blocks[i], blocks[j])) {
        continue;
      }
      final int order = _compareMangaBlockReadingOrder(blocks[i], blocks[j]);
      final MokuroBlock earlier = order <= 0 ? blocks[i] : blocks[j];
      if (_mangaEndsSentence(_mangaBlockText(earlier))) {
        continue;
      }
      join(i, j);
    }
  }

  final Map<int, List<int>> groups = <int, List<int>>{};
  for (int i = 0; i < blocks.length; i++) {
    groups.putIfAbsent(rootOf(i), () => <int>[]).add(i);
  }
  final List<({int group, String sentence})?> result =
      List<({int group, String sentence})?>.filled(blocks.length, null);
  int groupIndex = 0;
  for (final List<int> indices in groups.values) {
    indices.sort(
      (int a, int b) => _compareMangaBlockReadingOrder(blocks[a], blocks[b]),
    );
    final String sentence = indices
        .where((int index) => !rubyBlocks.contains(index))
        .map((int index) => _mangaBlockText(blocks[index]))
        .join();
    final String fallback = sentence.isNotEmpty
        ? sentence
        : indices.map((int index) => _mangaBlockText(blocks[index])).join();
    for (final int index in indices) {
      result[index] = (group: groupIndex, sentence: fallback);
    }
    groupIndex++;
  }
  return result.cast<({int group, String sentence})>();
}

String _mangaBlockText(MokuroBlock block) => block.lines.join();

bool _mangaKanaOnly(String text) =>
    text.isNotEmpty &&
    RegExp(r'^[\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9dー]+$').hasMatch(text);

bool _mangaContainsKanji(String text) =>
    RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]').hasMatch(text);

double _mangaAxisOverlap(MokuroRect a, MokuroRect b, {required bool vertical}) {
  if (vertical) {
    return math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  }
  return math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));
}

double _mangaAxisLength(MokuroRect rect, {required bool vertical}) =>
    vertical ? rect.height : rect.width;

double _mangaCrossThickness(MokuroRect rect, {required bool vertical}) =>
    vertical ? rect.width : rect.height;

double _mangaCrossGap(MokuroRect a, MokuroRect b, {required bool vertical}) {
  if (vertical) {
    return math.max(0, math.max(a.left, b.left) - math.min(a.right, b.right));
  }
  return math.max(0, math.max(a.top, b.top) - math.min(a.bottom, b.bottom));
}

/// Return the cross-axis gap when [candidate] is very likely ruby for [base].
double? _mangaRubyGap(MokuroBlock candidate, MokuroBlock base) {
  if (candidate.isVertical != base.isVertical ||
      !_mangaContainsKanji(_mangaBlockText(base))) {
    return null;
  }
  final bool vertical = candidate.isVertical;
  final double candidateThickness = _mangaCrossThickness(
    candidate.rectangle,
    vertical: vertical,
  );
  final double baseThickness = _mangaCrossThickness(
    base.rectangle,
    vertical: vertical,
  );
  if (candidateThickness <= 0 ||
      baseThickness <= 0 ||
      candidateThickness > baseThickness * 0.68) {
    return null;
  }
  // Japanese ruby sits to the right of vertical-rl base text and above
  // horizontal base text.
  final bool annotationSide = vertical
      ? candidate.rectangle.center.dx > base.rectangle.center.dx
      : candidate.rectangle.center.dy < base.rectangle.center.dy;
  if (!annotationSide) {
    return null;
  }
  final double candidateLength = _mangaAxisLength(
    candidate.rectangle,
    vertical: vertical,
  );
  final double baseLength = _mangaAxisLength(
    base.rectangle,
    vertical: vertical,
  );
  final double overlap = _mangaAxisOverlap(
    candidate.rectangle,
    base.rectangle,
    vertical: vertical,
  );
  if (candidateLength <= 0 ||
      baseLength <= 0 ||
      overlap / math.min(candidateLength, baseLength) < 0.45) {
    return null;
  }
  final double gap = _mangaCrossGap(
    candidate.rectangle,
    base.rectangle,
    vertical: vertical,
  );
  final double maximumGap = math.max(6.0, base.fontSize * 0.45);
  return gap <= maximumGap ? gap : null;
}

bool _mangaBlocksAreAdjacent(MokuroBlock a, MokuroBlock b) {
  if (a.isVertical != b.isVertical) {
    return false;
  }
  final bool vertical = a.isVertical;
  final double aLength = _mangaAxisLength(a.rectangle, vertical: vertical);
  final double bLength = _mangaAxisLength(b.rectangle, vertical: vertical);
  if (aLength <= 0 || bLength <= 0) {
    return false;
  }
  final double overlap = _mangaAxisOverlap(
    a.rectangle,
    b.rectangle,
    vertical: vertical,
  );
  if (overlap / math.min(aLength, bLength) < 0.30) {
    return false;
  }
  final double gap = _mangaCrossGap(
    a.rectangle,
    b.rectangle,
    vertical: vertical,
  );
  final double maximumGap = math.max(
    8.0,
    math.max(a.fontSize, b.fontSize) * 0.90,
  );
  return gap <= maximumGap;
}

int _compareMangaBlockReadingOrder(MokuroBlock a, MokuroBlock b) {
  if (a.isVertical && b.isVertical) {
    final double crossDelta = b.rectangle.center.dx - a.rectangle.center.dx;
    if (crossDelta.abs() > 1) {
      return crossDelta.sign.toInt();
    }
    return a.rectangle.top.compareTo(b.rectangle.top);
  }
  final double crossDelta = a.rectangle.center.dy - b.rectangle.center.dy;
  if (crossDelta.abs() > 1) {
    return crossDelta.sign.toInt();
  }
  return a.rectangle.left.compareTo(b.rectangle.left);
}

bool _mangaEndsSentence(String text) =>
    RegExp(r'[。！？.!?‼⁉][」』）)\]】〉》〕｝}］”’]*$').hasMatch(text);

/// Returns character-level hit regions for every OCR producer.
///
/// Lens already supplies line-derived regions. Local ONNX and legacy mokuro
/// blocks do not, so they are subdivided here using `lines_coords` when
/// available and the block rectangle otherwise. This mirrors Niratan's native
/// reader: hit testing is based on explicit character geometry instead of
/// asking browser typography to approximate where transparent text landed.
///
/// Supplied regions are used only when they match the block text as a whole:
/// every region lies on grapheme boundaries inside the sentence and every
/// visible grapheme is covered ([mangaTextRegionsMatchSentence]). Otherwise —
/// for example a manga.json whose text was rewritten while the regions still
/// carry the old offsets — the whole block falls back to line geometry.
/// Dropping the mismatched regions one by one would leave characters with no
/// hit target (or, when all of them miss, a block that cannot be clicked).
List<MangaOcrTextRegion> mangaEffectiveTextRegions(MokuroBlock block) {
  final List<MangaOcrTextRegion>? supplied = block.regions;
  if (supplied != null &&
      supplied.isNotEmpty &&
      mangaTextRegionsMatchSentence(supplied, block.lines.join())) {
    return supplied;
  }
  return _mangaGeometryTextRegions(block);
}

/// Whether [regions] can stand for [sentence] character by character.
///
/// Each region must be a non-empty UTF-16 range on grapheme boundaries inside
/// the sentence, and together they must cover every non-whitespace grapheme.
/// A single miss makes the whole set unusable: the caller then re-derives
/// regions from line geometry instead of keeping a partial set.
bool mangaTextRegionsMatchSentence(
  List<MangaOcrTextRegion> regions,
  String sentence,
) {
  final Set<int> boundaries = <int>{0};
  final List<({int start, int end})> visible = <({int start, int end})>[];
  int offset = 0;
  for (final String grapheme in sentence.characters) {
    final int end = offset + grapheme.length;
    if (grapheme.trim().isNotEmpty) visible.add((start: offset, end: end));
    boundaries.add(end);
    offset = end;
  }
  final List<bool> covered = List<bool>.filled(sentence.length, false);
  for (final MangaOcrTextRegion region in regions) {
    final int start = region.utf16Start;
    final int end = region.utf16End;
    if (start < 0 || end <= start || end > sentence.length) return false;
    if (!boundaries.contains(start) || !boundaries.contains(end)) return false;
    covered.fillRange(start, end, true);
  }
  return visible.every((({int start, int end}) g) => covered[g.start]);
}

/// Character regions derived from `lines_coords` (or the block rectangle).
List<MangaOcrTextRegion> _mangaGeometryTextRegions(MokuroBlock block) {
  if (block.lines.isEmpty || block.rectangle.isEmpty) {
    return const <MangaOcrTextRegion>[];
  }
  final List<MokuroOrientedRect> lineRects = _mangaLineRects(block);
  final List<MangaOcrTextRegion> result = <MangaOcrTextRegion>[];
  int utf16Base = 0;
  for (int lineIndex = 0; lineIndex < block.lines.length; lineIndex++) {
    final String line = block.lines[lineIndex];
    final List<({String text, int start, int end})> characters =
        <({String text, int start, int end})>[];
    int offset = utf16Base;
    for (final String character in line.characters) {
      final int end = offset + character.length;
      if (character.trim().isNotEmpty) {
        characters.add((text: character, start: offset, end: end));
      }
      offset = end;
    }
    if (characters.isNotEmpty) {
      final MokuroOrientedRect line = lineRects[lineIndex];
      final MokuroRect lineRect = line.unrotated;
      for (int index = 0; index < characters.length; index++) {
        // 先在摆正的行里均分字格，再把字格中心转回行的倾角：斜行上的字格
        // 沿着斜线排，而不是在外接框里横平竖直地铺。
        final MokuroRect upright = block.isVertical
            ? MokuroRect.fromLTWH(
                lineRect.left,
                lineRect.top + index * lineRect.height / characters.length,
                lineRect.width,
                lineRect.height / characters.length,
              )
            : MokuroRect.fromLTWH(
                lineRect.left + index * lineRect.width / characters.length,
                lineRect.top,
                lineRect.width / characters.length,
                lineRect.height,
              );
        final MokuroRect characterRect;
        if (line.rotation == 0) {
          characterRect = upright;
        } else {
          final MokuroPoint center = line.toPage(
            upright.center.dx - line.center.dx,
            upright.center.dy - line.center.dy,
          );
          characterRect = MokuroRect.fromLTWH(
            center.dx - upright.width / 2,
            center.dy - upright.height / 2,
            upright.width,
            upright.height,
          );
        }
        result.add(
          MangaOcrTextRegion(
            rectangle: characterRect,
            utf16Start: characters[index].start,
            utf16End: characters[index].end,
            rotation: line.rotation,
          ),
        );
      }
    }
    utf16Base += line.length;
  }
  return result;
}

/// 每行的几何：`lines_coords` 齐全时逐行取，四点矩形保留旋转
/// （[mokuroOrientedRectFromQuad]），其它多边形取外接框；否则按块均分。
List<MokuroOrientedRect> _mangaLineRects(MokuroBlock block) {
  final List<List<List<double>>>? coordinates = block.linesCoords;
  if (coordinates != null && coordinates.length == block.lines.length) {
    final List<MokuroOrientedRect> parsed = <MokuroOrientedRect>[];
    for (final List<List<double>> polygon in coordinates) {
      if (polygon.isEmpty ||
          polygon.any((List<double> point) => point.length < 2)) {
        parsed.clear();
        break;
      }
      double left = double.infinity;
      double top = double.infinity;
      double right = double.negativeInfinity;
      double bottom = double.negativeInfinity;
      for (final List<double> point in polygon) {
        left = math.min(left, point[0]);
        top = math.min(top, point[1]);
        right = math.max(right, point[0]);
        bottom = math.max(bottom, point[1]);
      }
      if (right <= left || bottom <= top) {
        parsed.clear();
        break;
      }
      final MokuroOrientedRect? oriented = mokuroOrientedRectFromQuad(polygon);
      parsed.add(
        oriented != null && oriented.rotation != 0
            ? oriented
            : _uprightLine(MokuroRect.fromLTRB(left, top, right, bottom)),
      );
    }
    if (parsed.length == block.lines.length) {
      return parsed;
    }
  }

  final MokuroRect rect = block.rectangle;
  final int count = block.lines.length;
  if (block.isVertical) {
    final double width = rect.width / count;
    return <MokuroOrientedRect>[
      for (int index = 0; index < count; index++)
        _uprightLine(
          MokuroRect.fromLTWH(
            rect.right - (index + 1) * width,
            rect.top,
            width,
            rect.height,
          ),
        ),
    ];
  }
  final double height = rect.height / count;
  return <MokuroOrientedRect>[
    for (int index = 0; index < count; index++)
      _uprightLine(
        MokuroRect.fromLTWH(
          rect.left,
          rect.top + index * height,
          rect.width,
          height,
        ),
      ),
  ];
}

MokuroOrientedRect _uprightLine(MokuroRect rect) => MokuroOrientedRect(
  center: rect.center,
  width: rect.width,
  height: rect.height,
);

String _mangaCharacterRegionsHtml({
  required MokuroBlock block,
  required List<MangaOcrTextRegion> regions,
}) {
  final String sentence = block.lines.join();
  final MokuroRect parent = block.rectangle;
  final double parentWidth = parent.width <= 0 ? 1 : parent.width;
  final double parentHeight = parent.height <= 0 ? 1 : parent.height;
  final StringBuffer buffer = StringBuffer();
  // [regions] comes from [mangaEffectiveTextRegions]: every range is already
  // known to lie inside the sentence, so nothing is filtered here.
  for (final MangaOcrTextRegion region in regions) {
    final MokuroRect r = region.rectangle;
    final double leftPct = ((r.left - parent.left) / parentWidth) * 100;
    final double topPct = ((r.top - parent.top) / parentHeight) * 100;
    final double widthPct = (r.width / parentWidth) * 100;
    final double heightPct = (r.height / parentHeight) * 100;
    final String text = sentence.substring(region.utf16Start, region.utf16End);
    // 斜行字格绕自身中心旋转（transform-origin 默认即中心）；elementsFromPoint
    // 按变换后的形状命中，所以点击判定跟着字格一起转。
    final String rotate = region.rotation == 0
        ? ''
        : 'transform:rotate(${_num(region.rotation * 180 / math.pi)}deg);';
    buffer.write(
      '<span class="ocr-char" '
      'data-utf16-start="${region.utf16Start}" '
      'data-ocr-orientation="${block.isVertical ? 'vertical' : 'horizontal'}" '
      'style="left:${_pct(leftPct)};'
      'top:${_pct(topPct)};'
      'width:${_pct(widthPct)};'
      'height:${_pct(heightPct)};'
      '$rotate">'
      '${_escapeHtml(text)}</span>',
    );
  }
  return buffer.toString();
}

/// 一整页：底图 `<img pointer-events:none>` + 上层 OCR 框。
///
/// `.manga-page` 声明 `container-type:inline-size`，为框字号的 `cqi` 单位提供参照
/// 宽度（ERRATA H5）；每页独立成容器，spread 双页各自相对本页宽。用 inline-size 而
/// 非 size：size containment 会让 img 驱动的页尺寸塌成 0、所有百分比框塌到原点重叠
/// 串字；inline-size 只约束宽度轴。
///
/// 尺寸策略：spread 模式下每页同时受槽宽与视口高度约束。页宽为
/// `min(slotVw, 100*w/h vh)`，页高为 `min(100vh, slotVw*h/w)`，因此无论窗口横竖比
/// 如何，100% 缩放时整页始终完整可见；双页各自最多 50vw，单页最多 100vw。
/// 页外再由 `.manga-spread` 提供固定 100vw×100vh 的居中槽，既避免裁切，也保持
/// translateX 每次恰好移动一个视口。webtoon 仍是宽驱动（每页宽=100vw）。
/// [spreadIndex] 标注本页所属的跨页号（写入 `data-spread`）。[pagesInSpread] 标注本页
/// 所在跨页的页数（1=单页 / 2=双页），决定 spread 槽宽；写入 `data-spread-pages` 仅供
/// 调试/测试，槽宽本身由内联 `width` 落实，不依赖 CSS 类选择。
///
/// [pageIndex] 是本页在整卷里的 0-based 页码（写入 `data-page`），连同页图原始
/// 像素尺寸（`data-pw` / `data-ph`）供补扫模式把视口矩形换算回**页图像素坐标**：
/// div 的 aspect-ratio 与页图一致 + `object-fit:contain`，图恒铺满 div（无信箱
/// 留白），故 div getBoundingClientRect 与页图像素是纯线性映射。
String mangaPageDivHtml(
  MokuroImage page,
  String imgSrc, {
  int spreadIndex = 0,
  int pagesInSpread = 1,
  int pageIndex = 0,
  bool isWebtoon = false,
  bool eager = false,
  bool ocrLoaded = true,
  MangaScaleType scaleType = MangaScaleType.fitScreen,
  bool cropBorders = false,
  bool splitWidePages = false,
  bool rotateWidePages = false,
  double spreadGutterPx = 0,
}) {
  // div 内联声明：
  // - position:relative —— OCR 框绝对定位的包含块。
  // - container-type:inline-size —— cqi 参照宽（自包含，不依赖外部 style 块）。
  // spread：内联 width/height 同时受槽宽与 100vh 约束；
  //   inline-size containment 不阻止显式 width（width 是 used value，非内容撑开），
  //   故 OCR 框 cqi 参照有效、底图按 object-fit:contain 等比内含进槽。
  // webtoon：宽由 style 块的 .manga-page{width:100vw} 给定（外部），这里只给
  //   aspect-ratio 让高从 definite 宽推出，不再内联 width（避免与 style 块冲突）。
  final double w = page.size.width <= 0 ? 1 : page.size.width;
  final double h = page.size.height <= 0 ? 1 : page.size.height;
  // spread 页槽：双页每页最多 50vw、单页最多 100vw；再按图片宽高比限制
  // 最大 100vh。把乘法在 Dart 侧预先折成 vh/vw 数值，避免依赖 CSS Values 4
  // 的单位乘法语法（旧 WebView 不完整支持）。
  final int slots = pagesInSpread <= 1 ? 1 : pagesInSpread;
  final double slotVw = 100.0 / slots;
  // 折叠屏书本姿态的铰链缝（见 mangaWindowDocument 的 spreadGutterPx）：双页时每页
  // 槽宽让出半条缝，两页之间留出整条缝，铰链下不放页面像素。
  final double gutter = slots == 2 && spreadGutterPx > 0 ? spreadGutterPx : 0;
  final String slotWidth = gutter > 0
      ? 'calc(${_num(slotVw)}vw - ${_num(gutter / 2)}px)'
      : '${_num(slotVw)}vw';
  final String slotHeightFromWidth = gutter > 0
      ? 'calc((${_num(slotVw)}vw - ${_num(gutter / 2)}px) * ${_num(h / w)})'
      : '${_num(slotVw * h / w)}vw';
  final String sizingCss = isWebtoon
      ? ''
      : switch (scaleType) {
          MangaScaleType.fitWidth =>
            'width:$slotWidth;height:auto;max-height:100vh;',
          MangaScaleType.fitHeight =>
            'width:auto;height:100vh;max-width:$slotWidth;',
          MangaScaleType.original => 'width:${_num(w)}px;height:${_num(h)}px;',
          MangaScaleType.stretch => 'width:$slotWidth;height:100vh;',
          MangaScaleType.fitScreen || MangaScaleType.smart =>
            'width:min($slotWidth,${_num(100 * w / h)}vh);'
                'height:min(100vh,$slotHeightFromWidth);',
        };
  final String loading = eager && !isWebtoon ? 'eager' : 'lazy';
  final String fetchPriority = eager && !isWebtoon ? 'high' : 'auto';
  return '<div class="manga-page" data-spread="$spreadIndex" '
      'data-spread-pages="$pagesInSpread" '
      'data-page="$pageIndex" data-pw="${_num(w)}" data-ph="${_num(h)}" '
      'data-ocr-loaded="${ocrLoaded ? '1' : '0'}" '
      'data-crop-borders="${cropBorders ? '1' : '0'}" '
      'data-split-wide="${splitWidePages ? '1' : '0'}" '
      'data-rotate-wide="${rotateWidePages ? '1' : '0'}" '
      'style="position:relative;container-type:inline-size;'
      '$sizingCss'
      'aspect-ratio:${_num(w)}/${_num(h)};">'
      '<div class="manga-source" style="position:absolute;inset:0;container-type:inline-size;">'
      '<img src="${_escapeAttr(imgSrc)}" loading="$loading" '
      'fetchpriority="$fetchPriority" decoding="async" '
      'style="pointer-events:none;object-fit:${scaleType == MangaScaleType.stretch ? 'fill' : 'contain'};">'
      '${mangaOcrBoxesHtml(page)}'
      '</div>'
      '</div>';
}

/// 自包含窗口文档：spread → flex-row（RTL 经 direction:rtl 排序）+ 视口裁剪 +
/// translateX 只显示当前跨页；webtoon → 竖向堆叠 + 滚动。内联选词 JS + 一个
/// 手势机（swipe→翻页 / scroll→滚动报告 / tap→选词或放大）。
///
/// OCR 框有两条明确的查词入口（单击 / Shift 悬停），都走同一个字级选词函数
/// `_selectOcrChar()`：命中层先定位到字符节点，再调
/// `fushiSelection.selectFromPosition(node, 0, 40, x, y, fromHover)`（fromHover 随 payload 回传，宿主据此区分悬停与点击）。第三个参数是
/// maxLength，漏传 → 扫描循环 gate `< undefined` 恒假 → text 恒空 →
/// onTextSelected 永不触发（查词哑火）。Task 19 的内联选区 JS 只注入
/// ReaderSelectionScripts 的定义。手势机与选词 pointerup 共存；裸图单击保持 no-op。
///
/// ERRATA C1（翻页导航）：spread 模式把 strip 包进 `#manga-viewport`
/// (`overflow:hidden`)，每跨页单元宽恒 100vw（双页 50vw×2 / 单页 100vw），靠
/// translateX 平移使**只显示当前跨页**（RTL 取镜像）；翻页/恢复定位都改 translateX，
/// 不重 loadData。
///
/// webtoon（HIGH-2 修复，re-review）：调用方把**全部页**一次性渲染进单文档（不做
/// 窗口化/不滑窗 loadData——窗口化只是 spread 的优化），靠文档竖滚翻页；`onMangaScroll`
/// 只更新进度，绝不在滚动中 loadData 重建（否则在手指下抹掉重建抖动/抢滚）。恢复用
/// 页内 fraction（`__mangaScrollToSpread`）一次定位即可。
///
/// [currentSpread] 是恢复/翻页时要对齐到视口的跨页号；[restoreFraction] 是 webtoon
/// 恢复时的**页内**归一化偏移（0..1，spread 忽略）。[pagesPerSpread] 与 [pages] 等长，
/// 给每页标注其所在跨页的页数（spread 槽宽 50vw/100vw 用）。手势经 `onMangaTurn`(+1/-1)、
/// `onMangaScroll`({fraction, topPage}) 回 Dart 推进 `_currentSpread`/`_currentPage`。
String mangaWindowDocument(
  List<MokuroImage> pages,
  List<String> imgSrcs, {
  required MangaReadingMode mode,
  required String spreadDirection,
  required String inlineSelectionJs,
  List<int>? pageSpreadIndices,
  List<int>? pagesPerSpread,
  List<int>? pageNumbers,
  int currentSpread = 0,
  double restoreFraction = 0,
  int zoomPercent = 100,
  int? restZoomPercent,
  int documentGeneration = 0,
  Set<int>? ocrPageIndices,
  int zoomMinPercent = kMangaZoomMinPercent,
  int zoomMaxPercent = kMangaZoomMaxPercent,
  int zoomSensitivity = kMangaZoomSensitivityDefault,
  MangaPageAnimation pageAnimation = MangaPageAnimation.slide,
  PageTurnAnimationSpeed pageAnimationSpeed = PageTurnAnimationSpeed.normal,
  bool followDrag = kMangaPageTurnFollowDragDefault,
  bool tapZonePaging = true,
  MangaTapZoneLayout tapZoneLayout = MangaTapZoneLayout.leftRight,
  String backgroundCss = '#000',
  bool showOcrBoxes = false,
  MangaScaleType scaleType = MangaScaleType.fitScreen,
  int longStripSidePadding = 0,
  bool disableZoomOut = false,
  bool animateDoubleTap = true,
  bool invertHorizontal = false,
  bool invertVertical = false,
  bool invertBoth = false,
  bool cropBorders = false,
  bool splitWidePages = false,
  bool rotateWidePages = false,
  bool autoZoomWidePages = false,
  bool panWidePages = true,
  int doubleTapAnimationMs = 300,
  String zoomStartPosition = 'automatic',
  MangaReaderPreferences? readerPreferences,
  String? readingModeLabel,
  // 悬停查词按住的键在 MouseEvent 上的字段名（HoverLookupModifier.jsEventFlag）。
  String hoverKey = 'shiftKey',
  // 折叠屏书本姿态：双页之间留出的铰链缝（逻辑像素，见 fushiHingeGutterPx）。0 = 无缝。
  double spreadGutterPx = 0,
}) {
  final MangaReaderPreferences preferences =
      readerPreferences ?? const MangaReaderPreferences();
  if (readerPreferences != null) {
    scaleType = preferences.scaleType;
    longStripSidePadding = preferences.longStripSidePadding;
    disableZoomOut = preferences.disableZoomOut;
    animateDoubleTap = preferences.animateDoubleTap;
    invertHorizontal = preferences.invertHorizontal;
    invertVertical = preferences.invertVertical;
    invertBoth = preferences.invertBoth;
    cropBorders = preferences.cropBorders;
    splitWidePages = preferences.splitWidePages;
    rotateWidePages = preferences.rotateWidePages;
    autoZoomWidePages = preferences.autoZoomWide;
    panWidePages = preferences.panWide;
    zoomStartPosition = preferences.zoomStartPosition;
    showOcrBoxes = preferences.showOcrBoxes;
    // 翻页动画只认 `manga_page_animation`（调用方传入的 [pageAnimation]）；
    // animateTransitions 是它的旧投影，不再参与判定。墨水屏强制无动画。
    if (preferences.einkMode) pageAnimation = MangaPageAnimation.none;
  }
  if (preferences.einkMode) backgroundCss = '#fff';
  // Vertical paging shares the scroll bridge with long-strip mode, but each
  // page snaps to a viewport. Keeping this distinction here lets old callers
  // that only know spread/webtoon continue to work.
  final bool isVerticalPaged = mode == MangaReadingMode.pagedVertical;
  final bool isWebtoon = mode.isWebtoon || isVerticalPaged;
  // 长条漫的页间距只由阅读模式决定：「条漫」无缝拼接、「带间距长条漫」留间距
  // （与 Mihon 两种长条模式同义）。此前两种模式都只看 showPageGaps，而它默认开，
  // 于是「条漫」每页之间都露出一条背景色横带——切片发布的韩漫满屏黑线。
  // showPageGaps 只管纵向分页（翻页步进之间的空隙，见 _layoutSource）。
  final bool hasGaps = mode.isWebtoon
      ? mode.hasGaps
      : readerPreferences != null && preferences.showPageGaps;
  // spread 容器本身始终按 LTR 的几何顺序排列，保证 offsetLeft 是稳定的
  // 0/100vw/200vw；RTL 只施加到每个 spread 内部，让双页视觉页序反转。
  // 若把 direction:rtl 放在根 strip 上，Chromium 会把 wrapper 的 RTL 起点偏移
  // 混进 offsetLeft，translate 后整组图片向左错位、无法水平居中。
  final bool rtl = !isWebtoon && spreadDirection == 'rtl';
  final String pageDirectionCss = rtl ? 'direction:rtl;' : 'direction:ltr;';

  final StringBuffer pagesHtml = StringBuffer();
  final Map<int, StringBuffer> spreadPages = <int, StringBuffer>{};
  // spread 模式下落点跨页在 strip 里的槽位（DOM 顺序，RTL 已倒序）。
  int initialStripSlot = 0;
  final int count = pages.length < imgSrcs.length
      ? pages.length
      : imgSrcs.length;
  for (int i = 0; i < count; i++) {
    final int spreadIndex =
        (pageSpreadIndices != null && i < pageSpreadIndices.length)
        ? pageSpreadIndices[i]
        : 0;
    // 本页所在跨页的页数（CRITICAL-1：决定 spread 槽宽 50vw/100vw）。缺省/webtoon
    // 视为单页。
    final int slotPages =
        (!isWebtoon && pagesPerSpread != null && i < pagesPerSpread.length)
        ? pagesPerSpread[i]
        : 1;
    // 真实页码（窗口化文档里数组序 != 整卷页码）；缺省退回数组序（webtoon 全量
    // 渲染时两者一致）。
    final int pageNumber = (pageNumbers != null && i < pageNumbers.length)
        ? pageNumbers[i]
        : i;
    final bool includeOcr =
        ocrPageIndices == null || ocrPageIndices.contains(pageNumber);
    final MokuroImage renderedPage = includeOcr
        ? pages[i]
        : MokuroImage(
            url: pages[i].url,
            size: pages[i].size,
            blocks: const <MokuroBlock>[],
          );
    final String pageHtml = mangaPageDivHtml(
      renderedPage,
      imgSrcs[i],
      spreadIndex: spreadIndex,
      pagesInSpread: slotPages,
      pageIndex: pageNumber,
      isWebtoon: isWebtoon,
      scaleType: scaleType,
      cropBorders: cropBorders,
      splitWidePages: splitWidePages,
      rotateWidePages: rotateWidePages,
      spreadGutterPx: spreadGutterPx,
      // 当前 spread 与前后相邻 spread 立即解码；窗口里更远的页继续 lazy，
      // 兼顾无白屏翻页与超清页图内存。
      eager: !isWebtoon && (spreadIndex - currentSpread).abs() <= 1,
      ocrLoaded: includeOcr,
    );
    if (isWebtoon) {
      pagesHtml.write(pageHtml);
    } else {
      spreadPages.putIfAbsent(spreadIndex, StringBuffer.new).write(pageHtml);
    }
  }
  if (!isWebtoon) {
    // strip 的**几何顺序**必须跟着阅读方向走，否则翻页动画方向是反的。
    //
    // 根 strip 恒 `direction:ltr`（见上方注释）：把 `direction:rtl` 放上去会让
    // Chromium 把 RTL 起点偏移混进 offsetLeft，translate 后整组图片错位。所以
    // RTL 不能靠 CSS 反排——改成按**倒序写入 DOM**：spread N 的 offsetLeft 变成
    // (n-1-N)×100vw，仍是稳定的 100vw 整数倍（`__mangaApplyTranslate` 的
    // `-offsetLeft` 口径不变），但「下一跨页」落到左边，于是前进时画面向右滑、
    // 新页从左边进——与 tap zone（IS_RTL 镜像）和方向键（resolveMangaArrowPageTurn）
    // 早已按 RTL 镜像过的输入语义对上。此前只镜像输入不镜像几何，RTL（默认值）下
    // 「按前进键 → 画面往后退的方向滑」。
    //
    // `__mangaApplyTranslate` 用 `data-spread` 属性选择器定位目标，与 DOM 顺序
    // 无关，故无需改动；窗口化文档只渲染连续的一段 spread，倒序后仍连续。
    List<int> spreadOrder = spreadPages.keys.toList()..sort();
    if (rtl) {
      spreadOrder = spreadOrder.reversed.toList();
    }
    initialStripSlot = math.max(0, spreadOrder.indexOf(currentSpread));
    for (final int spreadIndex in spreadOrder) {
      pagesHtml.write(
        '<div class="manga-spread" '
        'data-spread="$spreadIndex">${spreadPages[spreadIndex]}</div>',
      );
    }
  }

  // 容器尺寸策略（CRITICAL-1 修复，re-review）：给 .manga-page 一个 definite 轴
  // （视口单位），另一轴由内联 aspect-ratio 推出（见 mangaPageDivHtml），使两轴都
  // definite → inline-size containment 下 cqi 参照有效、OCR 框百分比不塌缩。
  // - spread（flex-row）：每个 `.manga-spread` 固定 100vw×100vh；页本身同时受
  //   槽宽（单页 100vw / 双页 50vw）与高度 100vh 限制，故 100% 下不裁切。
  //   translateX 以 spread 容器为锚，每次仍恰好移动一个视口。
  // - webtoon（column）：每页宽=100vw，高由 aspect-ratio 推出，文档竖滚。
  // 用视口单位而非 height:100% 链：WebView initialData 文档 html/body 高度链常解析
  // 为 0。
  final String rootSizing = isWebtoon
      ? '#manga-root{display:flex;flex-direction:column;direction:ltr;'
            'width:100vw;align-items:center;}'
            '.manga-page{width:${100 - longStripSidePadding.clamp(0, 24) * 2}vw;'
            'box-sizing:border-box;${hasGaps ? 'margin-bottom:12px;' : ''}'
            '${isVerticalPaged ? 'scroll-snap-align:start;' : ''}}'
            '${isVerticalPaged ? '#manga-root{scroll-snap-type:y mandatory;}' : ''}'
      : '#manga-viewport{overflow:hidden;width:100vw;height:100vh;'
            'position:relative;}'
            '#manga-root{display:flex;flex-direction:row;direction:ltr;'
            'height:100vh;align-items:center;}'
            '.manga-spread{display:flex;flex:0 0 100vw;'
            'width:100vw;height:100vh;align-items:center;'
            'justify-content:center;$pageDirectionCss'
            '${spreadGutterPx > 0 ? 'column-gap:${_num(spreadGutterPx)}px;' : ''}}'
            // 「覆盖」翻页的克隆层：与 strip 同在 #manga-canvas 下（缩放 / 平移一致），
            // 不吃指针，带一圈投影压在下面那一屏上。
            '.manga-cover-layer{position:absolute;left:0;top:0;width:100vw;'
            'height:100vh;pointer-events:none;z-index:2;'
            'box-shadow:0 0 28px rgba(0,0,0,.45);}';
  // #manga-root 的过渡声明单独一张样式表：设置 / 系统「减弱动态效果」变化时
  // JS（__mangaSetPageAnimation）只换这张表的内容，不重建文档。
  final String animCss = isWebtoon
      ? ''
      : '<style id="manga-anim-css">#manga-root{'
            '${_rootTransitionCss(pageAnimation, pageAnimationSpeed)}}</style>';

  // spread 时 strip 包进 overflow:hidden 视口；webtoon 时 root 直接在 body。
  final String content = isWebtoon
      ? '<div id="manga-root">${pagesHtml.toString()}</div>'
      : '<div id="manga-viewport">'
            // 首帧就停在落点跨页（BUG-3222）：脚本的 _reanchor 要等 load / 双 rAF
            // 才跑，在那之前 strip 是 transform:none——屏上是窗口里 DOM 最左的那个
            // 跨页（LTR 的首页）。每个跨页恰好 100vw，所以落点能直接写成 vw。
            '<div id="manga-root" style="transform:translateX(-${initialStripSlot * 100}vw)">'
            '${pagesHtml.toString()}</div>'
            '</div>';
  final String body = '<div id="manga-canvas">$content</div>';

  return '<!DOCTYPE html>'
      '<html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1,'
      'maximum-scale=1,user-scalable=no">'
      '<style>'
      // BUG-051：禁用原生文字选区 + 图片拖拽。桌面 WebView 上鼠标拖动会触发浏览器
      // 原生 image drag-and-drop / 文字选区，拖出一个半透明残影（用户称「秃瓢」）并
      // 抢走指针，让 swipe→onMangaTurn 哑火。查词走坐标式 DOM 读取（fushiSelection
      // 用 elementFromPoint + TreeWalker + createRange，不依赖 window.getSelection），
      // 故禁 user-select 不影响查词，反而让鼠标拖动变成干净的 swipe。
      // BUG-1701：touch-action 必须在**手势开始前**就是 none。浏览器在第一个
      // touchstart 那一刻就按当时的 touch-action 锁定原生手势；之后 pointermove 里的
      // preventDefault 按 Pointer Events 规范并不阻止滚动。默认值 auto 下，webtoon 的
      // 双指捏合会与原生二指 pan 同时进行（缩放和上下滚动一起发生），滚动一旦接管还会
      // 让浏览器取消指针序列、把捏合状态清掉——这就是「放大缩小跟上下滑动混了」。改由
      // JS 独占后，webtoon 的竖向滚动由下面的单指拖动 + 惯性自己实现。
      'html,body{margin:0;padding:0;background:$backgroundCss;height:100%;'
      'touch-action:none;'
      '-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;}'
      '$rootSizing'
      // BUG-1759：#manga-canvas / #manga-root **不得**在样式表里常驻
      // will-change:transform——Chromium 会把带该提示的层的栅格化尺度钉成只升不降，
      // 缩到 <100% 时合成器拿旧尺度纹理做无 mipmap 缩小，网点/线稿全是锯齿，放大
      // 跨过旧尺度才重栅格（用户实测「90% 糊、150% 才恢复」）。合成层提升改由 JS 的
      // _hintWillChange 在手势/动画期间临时挂、静止后摘除。
      '#manga-canvas{transform-origin:0 0;}'
      '.manga-page{position:relative;flex:0 0 auto;'
      'container-type:inline-size;overflow:hidden;}'
      '.manga-page img{display:block;width:100%;height:100%;'
      'object-fit:contain;-webkit-user-drag:none;user-drag:none;}'
      // 全为恒等值时写 none：哪怕 invert(0)…saturate(1) 也会让每张页图走一次滤镜
      // 离屏渲染，长条漫的超高页图（数万像素高）会把滤镜面撑过纹理上限画成空白，
      // 滚动时逐帧重做滤镜也是卡顿的大头。
      '.manga-source img{filter:${mangaImageFilterIsIdentity(preferences) ? 'none' : mangaImageFilterCss(preferences)};}'
      // 取页失败的页：中央一个重试符号（点它 / 翻到它会重新请求，见 _retryPageImage）。
      '.manga-page[data-load-failed="1"] .manga-source::before{content:"\\21BB";'
      'position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);'
      'font:600 56px/1 sans-serif;color:#8888;pointer-events:none;}'
      '.manga-source::after{content:"";position:absolute;inset:0;pointer-events:none;'
      'background:${_escapeAttr(preferences.colorFilterColor)};'
      'opacity:${preferences.customColorFilter ? preferences.colorFilterOpacity.clamp(0, 100) / 100 : 0};}'
      '#manga-flash{position:fixed;inset:0;background:#fff;pointer-events:none;z-index:999;opacity:0;}'
      '#manga-mode-hint{position:fixed;left:16px;top:16px;padding:8px 12px;'
      'border-radius:8px;background:#fff;color:#111;z-index:8;pointer-events:none;font:14px sans-serif;}'
      '#manga-navigation-hint{position:fixed;inset:0;pointer-events:none;z-index:7;}'
      '#manga-navigation-hint span{position:absolute;box-sizing:border-box;border:1px solid #4673aa;'
      'background:rgba(80,140,220,.15);display:flex;align-items:center;justify-content:center;'
      'color:#4673aa;font:32px sans-serif;}'
      '.ocr-box{margin:0;padding:0;pointer-events:auto;}'
      // BUG-2481「显示识别范围」：body 挂 ocr-boxes-visible 时把每个 OCR 块的框
      // 画出来（外描边 + 淡底），字符级命中区用虚线，一眼能看出识别漏了哪块、
      // 框歪到哪。只改样式不改几何，命中判定与平时逐字节一致。
      '.ocr-boxes-visible .ocr-box{outline:2px solid rgba(255,64,64,.9);'
      'background:rgba(255,64,64,.12);}'
      '.ocr-boxes-visible .ocr-char{outline:1px dashed rgba(64,160,255,.7);}'
      // Character geometry is entirely explicit. Keep the common hit-layer
      // declarations in one rule instead of repeating them for every OCR
      // character: dense magazine pages can contain several thousand regions.
      '.ocr-char{position:absolute;display:block;overflow:hidden;'
      'color:transparent;pointer-events:auto;line-height:1;'
      'writing-mode:horizontal-tb;}'
      // BUG-2554：被查词高亮。命中层文字本身透明（画的是底下的页图），查词后
      // Dart 经 fushiSelection.highlightSelection 把命中的字符 Range 放进 CSS
      // Highlight `fushi-selection`；没有这条规则浏览器什么都不画，用户看不出
      // 自己查的是哪个字。半透明是为了不盖住页图上的原字。
      '::highlight(fushi-selection){background-color:rgba(255,196,0,0.45);}'
      // 没有 CSS Highlight API 的内核（Android System WebView < 105、
      // iOS/macOS WebKit < 17.2）走 highlightSelection 的降级分支：把命中字符
      // 包进 .fushi-dict-highlight span。缺这条规则时那一侧照样什么都不画。
      '.fushi-dict-highlight{background-color:rgba(255,196,0,0.45);}'
      '</style>$animCss</head>'
      '<body${showOcrBoxes ? ' class="ocr-boxes-visible"' : ''}>'
      '$body'
      '<div id="manga-flash"></div>'
      '${preferences.showReadingMode && readingModeLabel != null ? '<div id="manga-mode-hint">${_escapeHtml(readingModeLabel)}</div>' : ''}'
      '<script>$inlineSelectionJs</script>'
      '<script>'
      'window.__mangaDocumentGeneration=$documentGeneration;'
      '${_mangaGestureJs(isWebtoon: isWebtoon, rtl: rtl, currentSpread: currentSpread, restoreFraction: restoreFraction, zoomPercent: zoomPercent, restZoomPercent: restZoomPercent ?? zoomPercent, zoomMinPercent: zoomMinPercent, zoomMaxPercent: zoomMaxPercent, zoomSensitivity: zoomSensitivity, pageAnimation: pageAnimation, pageAnimationSpeed: pageAnimationSpeed, followDrag: followDrag, tapZonePaging: tapZonePaging, tapZoneLayout: tapZoneLayout, disableZoomOut: disableZoomOut, animateDoubleTap: animateDoubleTap, invertHorizontal: invertHorizontal, invertVertical: invertVertical, invertBoth: invertBoth, doubleTapAnimationMs: doubleTapAnimationMs, splitWidePages: splitWidePages, rotateWidePages: rotateWidePages, autoZoomWidePages: autoZoomWidePages, panWidePages: panWidePages, zoomStartPosition: zoomStartPosition, preferences: preferences, hoverKey: hoverKey, cropBorders: cropBorders, scaleType: scaleType, longStripSidePadding: longStripSidePadding, isVerticalPaged: isVerticalPaged)}'
      '</script>'
      '</body></html>';
}

/// Whether [mangaImageFilterCss] would leave every pixel unchanged.
bool mangaImageFilterIsIdentity(MangaReaderPreferences preferences) =>
    !preferences.invertColors &&
    !preferences.grayscale &&
    !preferences.einkMode &&
    preferences.brightness.clamp(-100, 100) == 0 &&
    preferences.contrast.clamp(0, 200) == 100 &&
    preferences.saturation.clamp(0, 200) == 100;

/// CSS filters affect the bitmap only; OCR hit boxes retain their source geometry.
String mangaImageFilterCss(MangaReaderPreferences preferences) =>
    'invert(${preferences.invertColors ? 1 : 0}) '
    'grayscale(${preferences.grayscale || preferences.einkMode ? 1 : 0}) '
    'brightness(${(100 + preferences.brightness.clamp(-100, 100)) / 100}) '
    'contrast(${preferences.contrast.clamp(0, 200) / 100}) '
    'saturate(${preferences.saturation.clamp(0, 200) / 100})';

/// 内联手势机 + 翻页/滚动几何。一个 pointerdown/pointerup 对（消歧 tap vs swipe）+
/// webtoon 滚动监听 + spread 鼠标滚轮翻页（BUG-051）。tap 命中 `.ocr-box` → 选词
/// （单击查词路径）；Shift 悬停是第二条显式查词路径。tap 命中裸图或未完成 OCR 的
/// 区域时保持在阅读器内，不打开独立大图。
/// swipe（仅 spread）→ `onMangaTurn`。spread 鼠标 `wheel`：ZOOM<=1 → `onMangaTurn`
/// （桌面 swipe 等价物，overflow:hidden 视口下滚轮本是死操作；带 110ms 锁合并连发）；
/// ZOOM>1 → 页内平移优先，贴边后继续滚才翻页（BUG-1760）。webtoon 滚动
/// 节流 → `onMangaScroll`。viewport resize → `_reanchor` 把语义位置重投影成新视口
/// 的 px（BUG-1758）。`dragstart` 全程 preventDefault + CSS user-select/user-drag
/// 禁用，消除桌面拖动时的原生图片/选区残影（「秃瓢」）。手势阈值镜像 reader
/// （absDx>absDy 判 swipe，小位移判 tap）。spread translateX 在 [_mangaApplyTranslate]
/// 按 data-spread 测量。
/// 翻页动画统一缓动（CSS 过渡与 JS 逐帧滚动动画同一条曲线）。
const String kMangaPageTurnEasing = 'cubic-bezier(.2,.7,.2,1)';

/// `#manga-root` 的过渡声明，由翻页动画效果与速度决定（JS 侧 `_rootTransitionDecl`
/// 是它的运行时镜像，设置变化时换掉 `#manga-anim-css` 的内容）。
///
/// `slide` = transform 过渡；`none` = 不声明过渡（瞬时翻页）；`fade` = 只过渡
/// opacity（淡出、瞬时位移、淡入各占半程，见 `_fadeTurn`）；`cover` = strip 本身瞬时
/// 定位，动的是克隆出来的覆盖层（见 `_coverTurn`），root 不声明过渡。
String _rootTransitionCss(
  MangaPageAnimation animation, [
  PageTurnAnimationSpeed speed = PageTurnAnimationSpeed.normal,
]) {
  switch (animation) {
    case PageTurnAnimation.none:
    case PageTurnAnimation.cover:
      return '';
    case PageTurnAnimation.slide:
      return 'transition:transform ${speed.durationMs}ms $kMangaPageTurnEasing;';
    case PageTurnAnimation.fade:
      return 'transition:opacity ${(speed.durationMs / 2).round()}ms '
          '$kMangaPageTurnEasing;';
  }
}

String _mangaGestureJs({
  String hoverKey = 'shiftKey',
  required bool isWebtoon,
  required bool rtl,
  required int currentSpread,
  required double restoreFraction,
  required int zoomPercent,
  required int restZoomPercent,
  required int zoomMinPercent,
  required int zoomMaxPercent,
  required int zoomSensitivity,
  required MangaPageAnimation pageAnimation,
  PageTurnAnimationSpeed pageAnimationSpeed = PageTurnAnimationSpeed.normal,
  bool followDrag = kMangaPageTurnFollowDragDefault,
  required bool tapZonePaging,
  required MangaTapZoneLayout tapZoneLayout,
  bool disableZoomOut = false,
  bool animateDoubleTap = true,
  bool invertHorizontal = false,
  bool invertVertical = false,
  bool invertBoth = false,
  int doubleTapAnimationMs = 300,
  bool splitWidePages = false,
  bool rotateWidePages = false,
  bool autoZoomWidePages = false,
  bool panWidePages = true,
  String zoomStartPosition = 'automatic',
  MangaReaderPreferences preferences = const MangaReaderPreferences(),
  bool cropBorders = false,
  MangaScaleType scaleType = MangaScaleType.fitScreen,
  int longStripSidePadding = 0,
  bool isVerticalPaged = false,
}) {
  // 点击翻页热区表 → JS 字面量 `[l,t,w,h,forward]` 的逗号串（外层中括号在模板里
  // 补）。几何与阅读方向镜像都在 Dart 侧算完（[mangaTapZones] 有单测），注入的脚本
  // 只负责遍历命中。webtoon 的 rtl 恒 false（长条漫没有开本方向），热区的
  // prev/next 在 JS 里换成滚动方向。
  final String tapZonesJs = <String>[
    for (final MangaTapZone z in mangaTapZones(
      tapZoneLayout,
      rtl: rtl,
      invertHorizontal: invertHorizontal,
      invertVertical: invertVertical,
      invertBoth: invertBoth,
    ))
      '[${_num(z.left)},${_num(z.top)},${_num(z.width)},${_num(z.height)},'
          '${z.forward}]',
  ].join(',');
  // RTL：strip 视觉镜像，但 DOM offsetLeft 仍是几何坐标；translateX 统一把目标跨页
  // 首页 offsetLeft 平移到视口左边缘（width=100vw 的视口里目标跨页正好填满）。
  return '''
(function(){
  function _bridge(){ return window.flutter_inappwebview; }
  // ── canvas zoom/pan ──
  var ZOOM_MIN = ${disableZoomOut ? 1.0 : zoomMinPercent / 100.0};
  var ZOOM_MAX = ${zoomMaxPercent / 100.0};
  // 反馈 EjyFnomM6w（墨水屏放大看句子后常缩过头 / 误翻页）的三项设置：
  // ZOOM_OUT_LIMIT  'fit_height' = 最多缩到整页高度撑满视口（见 _zoomFloor）；
  // QUICK_ZOOM_GESTURE 'double_tap' / 'two_finger_tap' = 一下缩回 QUICK_ZOOM_TARGET
  //   （'fit_height' / 'fit_width'，见 _quickZoom）；'off' = 双击照旧 100% ↔ 2×。
  var ZOOM_OUT_LIMIT = '${preferences.zoomOutLimit}';
  var QUICK_ZOOM_GESTURE = '${preferences.quickZoomGesture}';
  var QUICK_ZOOM_TARGET = '${preferences.quickZoomTarget}';
  // 灵敏度倍率（设置项，100% = 基准）。
  var ZOOM_SENS = ${zoomSensitivity / 100.0};
  var ZOOM = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, ${zoomPercent / 100.0}));
  // 静止倍率（BUG-3634）：阅读器**自己**把页面放到的倍率——设置里的默认缩放、
  // 宽页切半 / 宽页自动放大的适配、分镜聚焦。用户捏合 / 双击 / Ctrl+滚轮 /
  // 右键菜单 ± 放大不改它。超出它就是「用户放大在看细节」，此时点左右热区
  // 不翻页（见 _onTap）。默认值必须来自偏好而不是 ZOOM：跨窗口重建文档时
  // ZOOM 带的是会话倍率，用它当基准会让放大态在重建后又能点翻页。
  var ZOOM_REST_DEFAULT = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, ${restZoomPercent / 100.0}));
  var ZOOM_REST = ZOOM_REST_DEFAULT;
  function _userZoomedIn(){
    return ZOOM > Math.max(1, ZOOM_REST) + 0.01;
  }
  var SPLIT_WIDE = $splitWidePages;
  var ROTATE_WIDE = $rotateWidePages;
  var AUTO_ZOOM_WIDE = $autoZoomWidePages;
  var PAN_WIDE = $panWidePages;
  var PAGE_HALF = 0;
  var SPLIT_ACTIVE = false;
  // 纵向位置的唯一拥有者（BUG-1701）：webtoon 是竖滚文档，纵向归 window.scrollY，
  // PAN_Y 恒 0；spread 是 100vh 定高、overflow:hidden 的视口，不滚动，纵向归 PAN_Y。
  // 此前两模式共用 PAN_Y 公式，于是 webtoon 每次缩放都额外把整条长图平移
  // innerHeight*(1-ZOOM)/2 —— 画面自己上下跳一截。IS_WEBTOON 必须在这里就绪：
  // 下面的 _recenterPan / _applyCanvas 在文档解析期就会跑。
  var IS_WEBTOON = $isWebtoon;
  // 纵向分页（pagedVertical）走 webtoon 的滚动桥，但相邻翻页要平滑滚动。
  var IS_VERTICAL_PAGED = $isVerticalPaged;
  var PAN_X = 0;
  var PAN_Y = 0;
  // One source transform owns image and OCR geometry. Crop bounds stay in
  // original pixels, so selection, background OCR and captures share a frame.
  function _layoutSource(page){
    var pw = Number(page.dataset.pw), ph = Number(page.dataset.ph);
    var crop = page.__crop || {x:0,y:0,width:pw,height:ph};
    var rotated = ROTATE_WIDE && crop.width > crop.height * 1.15;
    page.__rotated = rotated;
    var vw = rotated ? crop.height : crop.width;
    var vh = rotated ? crop.width : crop.height;
    var slots = Number(page.dataset.spreadPages) || 1;
    var maxW = window.innerWidth / slots;
    var maxH = window.innerHeight;
    var sx = maxW / vw, sy = maxH / vh;
    var fit = Math.min(sx, sy);
    if (IS_WEBTOON) fit = window.innerWidth * ${1 - longStripSidePadding.clamp(0, 24) * 2 / 100} / vw;
    else if ('${scaleType.key}' === 'fit_width') fit = sx;
    else if ('${scaleType.key}' === 'fit_height') fit = sy;
    else if ('${scaleType.key}' === 'original') fit = 1;
    var scaleX = fit, scaleY = fit;
    if (!IS_WEBTOON && '${scaleType.key}' === 'stretch') { scaleX = sx; scaleY = sy; }
    // 长条漫页缝：页高按宽度比例算出来是小数像素，页与页的交界落在物理像素中间，
    // 两张图的边缘各被抗锯齿掉半个像素，底色从缝里透出来——就是那条横贯的黑线。
    // 页高对齐到物理像素，并让无间距的后一页向上压住前一页一个物理像素：滚动偏移
    // 是小数时交界仍会落在像素中间，有这一像素的重叠，底色就永远透不出来。
    if (IS_WEBTOON && !IS_VERTICAL_PAGED && !rotated) {
      var dpr = window.devicePixelRatio || 1;
      scaleY = Math.max(1, Math.round(vh * scaleY * dpr)) / dpr / vh;
      var prevPage = page.previousElementSibling;
      var gapped = prevPage &&
          parseFloat(getComputedStyle(prevPage).marginBottom) > 0;
      page.style.marginTop = prevPage && !gapped ? (-1 / dpr) + 'px' : '';
    }
    page.style.width = (vw * scaleX) + 'px';
    page.style.height = (vh * scaleY) + 'px';
    // A short vertical page keeps its true hit-test frame. Empty space between
    // pages supplies the viewport-sized paging step without stretching OCR.
    if($isVerticalPaged) page.style.marginBottom=Math.max(${preferences.showPageGaps ? 12 : 0},maxH-vh*scaleY)+'px';
    page.style.maxWidth = 'none'; page.style.maxHeight = 'none';
    var source = page.querySelector('.manga-source');
    if (!source) return;
    source.style.inset = 'auto'; source.style.left = '0'; source.style.top = '0';
    // Source layout stays proportional to original pixels; cqi text sizing and
    // normalized OCR boxes use this container rather than the cropped frame.
    source.style.width = pw + 'px'; source.style.height = ph + 'px';
    source.style.transformOrigin = '0 0';
    source.style.transform = rotated
      ? 'matrix(0,'+scaleY+','+(-scaleX)+',0,'+
          ((crop.y+crop.height)*scaleX)+','+(-crop.x*scaleY)+')'
      : 'matrix('+scaleX+',0,0,'+scaleY+','+(-crop.x*scaleX)+','+(-crop.y*scaleY)+')';
  }
  function _inspectSource(page){
    var img = page.querySelector('img');
    if (!img || !img.complete || !img.naturalWidth) return;
    if ($cropBorders || ${preferences.automaticBackground && !preferences.einkMode}) {
      try {
        var canvas = document.createElement('canvas');
        var ratio = Math.min(1, 512 / Math.max(img.naturalWidth,img.naturalHeight));
        canvas.width = Math.max(1,Math.round(img.naturalWidth*ratio));
        canvas.height = Math.max(1,Math.round(img.naturalHeight*ratio));
        var ctx = canvas.getContext('2d', {willReadFrequently:true});
        ctx.drawImage(img,0,0,canvas.width,canvas.height);
        var pixels = ctx.getImageData(0,0,canvas.width,canvas.height).data;
        // Median corner luminance tolerates page numbers or art in one corner.
        var corners = [0,(canvas.width-1)*4,(canvas.height-1)*canvas.width*4,(canvas.width*canvas.height-1)*4];
        var luminance = corners.map(function(i){return (pixels[i]+pixels[i+1]+pixels[i+2])/3;}).sort(function(a,b){return a-b;});
        var background = (luminance[1]+luminance[2])/2;
        page.__background = background > 128 ? '#fff' : '#000';
        if ($cropBorders) {
          var minX=canvas.width,minY=canvas.height,maxX=-1,maxY=-1;
          for(var y=0;y<canvas.height;y++) for(var x=0;x<canvas.width;x++) {
            var i=(y*canvas.width+x)*4;
            if (Math.abs((pixels[i]+pixels[i+1]+pixels[i+2])/3-background)>35) {
              minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);
            }
          }
          // Keep a pixel margin and reject uniform images: blank pages must
          // remain full size, rather than collapsing to an empty rectangle.
          if(maxX>minX && maxY>minY) {
            minX=Math.max(0,minX-1);minY=Math.max(0,minY-1);
            maxX=Math.min(canvas.width,maxX+2);maxY=Math.min(canvas.height,maxY+2);
            page.__crop={x:minX/canvas.width*Number(page.dataset.pw),y:minY/canvas.height*Number(page.dataset.ph),
              width:(maxX-minX)/canvas.width*Number(page.dataset.pw),height:(maxY-minY)/canvas.height*Number(page.dataset.ph)};
          }
        }
      } catch(error) {
        // Cross-origin images without CORS remain readable at their full size.
        // Report the unsupported pixel operation; never hide an unreadable page.
        var bridge=_bridge();
        if(bridge) bridge.callHandler('onMangaImageTransformUnavailable', String(error.name || 'pixel_read_failed'));
      }
    }
    _layoutSource(page);
    _updateAutomaticBackground();
  }
  function _updateAutomaticBackground(){
    if (!${preferences.automaticBackground && !preferences.einkMode}) return;
    var page=document.querySelector('.manga-page[data-spread="'+CURRENT+'"]');
    if(page && page.__background) {
      document.body.style.background=page.__background;
      document.documentElement.style.background=page.__background;
    }
  }
  document.querySelectorAll('.manga-page').forEach(function(page){
    _layoutSource(page);
  });
  window.addEventListener('resize',function(){
    document.querySelectorAll('.manga-page').forEach(_layoutSource);
    _applyWidePolicy();
  });
  function _recenterPan(){
    PAN_X = window.innerWidth * (1 - ZOOM) / 2;
    PAN_Y = IS_WEBTOON ? 0 : window.innerHeight * (1 - ZOOM) / 2;
  }
  function _currentPageIsWide(){
    var page = document.querySelector('.manga-page[data-spread="'+CURRENT+'"]');
    if (!page) return false;
    var pw = Number(page.getAttribute('data-pw') || 0);
    var ph = Number(page.getAttribute('data-ph') || 1);
    return pw > ph * 1.15;
  }
  // 宽页自动放大的记账：{from: 放大前倍率, to: 自动放大到的倍率}，null = 没在放大。
  var AUTO_ZOOM = null;
  function _applyWidePolicy(){
    if (SPLIT_WIDE && !ROTATE_WIDE && !IS_WEBTOON && _currentPageIsWide()) {
      _applyPageHalf(); return;
    }
    ZOOM_REST = ZOOM_REST_DEFAULT;
    if(SPLIT_ACTIVE){
      SPLIT_ACTIVE=false;
      // 离开切半的宽页回默认缩放；不用文档初值 zoomPercent——那是重建文档时带的
      // 会话倍率，可能是上一页残留的放大。
      ZOOM=ZOOM_REST_DEFAULT;
      _recenterPan();_applyCanvas();
    }
    var autoWide = AUTO_ZOOM_WIDE && _currentPageIsWide();
    // 宽页自动放大只属于那一页：翻离时倍率仍是自动放大的值（用户没再动过）就
    // 还原。此前放大会一直带到后面的普通页上，把它们裁掉，而且静止倍率回到
    // 默认后，这份残留会被当成「用户放大」，点热区翻不了页。
    if (AUTO_ZOOM && !autoWide) {
      if (Math.abs(ZOOM - AUTO_ZOOM.to) < 0.0005) {
        ZOOM = AUTO_ZOOM.from;
        if (ZOOM <= 1) { _recenterPan(); } else { _clampPan(); }
        _applyCanvas();
      }
      AUTO_ZOOM = null;
    }
    if (!autoWide) return;
    var page = document.querySelector('.manga-page[data-spread="'+CURRENT+'"]');
    if (!page || !(page.offsetWidth > 0)) return;
    var fitWide = Math.min(ZOOM_MAX, window.innerWidth / page.offsetWidth);
    ZOOM_REST = Math.max(ZOOM_REST, fitWide);
    if (fitWide > ZOOM) {
      if (AUTO_ZOOM) { AUTO_ZOOM.to = fitWide; } else { AUTO_ZOOM = {from: ZOOM, to: fitWide}; }
      ZOOM = fitWide;
    }
    _clampPan();
    _applyCanvas();
  }
  function _applyPageHalf(){
    var page=document.querySelector('.manga-page[data-spread="'+CURRENT+'"]');
    var spread=page && page.closest('.manga-spread');
    if(!page || !spread) return;
    SPLIT_ACTIVE=true;
    var physicalHalf=$rtl ? 1-PAGE_HALF : PAGE_HALF;
    // Height-constrained landscape windows leave side gutters after fitting a
    // half page. Clip the other half instead of letting it show in that space.
    // The full source frame remains intact for OCR/capture coordinate mapping.
    page.style.clipPath=physicalHalf===0 ? 'inset(0 50% 0 0)' : 'inset(0 0 0 50%)';
    var halfWidth=page.offsetWidth/2;
    ZOOM=_clampZoom(Math.min(window.innerWidth/halfWidth,window.innerHeight/page.offsetHeight));
    ZOOM_REST=ZOOM;
    var pageLeft=page.offsetLeft-spread.offsetLeft;
    PAN_X=(window.innerWidth-halfWidth*ZOOM)/2-(pageLeft+physicalHalf*halfWidth)*ZOOM;
    PAN_Y=(window.innerHeight-page.offsetHeight*ZOOM)/2-page.offsetTop*ZOOM;
    _applyCanvas();
  }
  // 起始平移：页面从哪一侧开始看（设置「缩放起始位置」）。文档加载与换页复位共用。
  function _applyStartPan(){
    _recenterPan();
    if (!IS_WEBTOON && '$zoomStartPosition' === 'left') PAN_X = 0;
    if (!IS_WEBTOON && '$zoomStartPosition' === 'right') PAN_X = window.innerWidth * (1 - ZOOM);
  }
  // 换页复位（反馈 8HxGrnNy3x，所有者定为默认行为、无开关）：翻到另一跨页时，
  // 用户捏合 / 双击 / 滚轮 / 右键菜单带出的倍率与平移不跟到新页，回到默认缩放 +
  // 起始位置。宽页切半 / 宽页自动放大随后由 _applyWidePolicy 按新页重新套用。
  // 倍率变了才回报 Dart：会话倍率 _zoomPercent 是重建文档时的初值，不同步的话
  // 下次跨窗口重建又把放大带回来。
  function _resetZoomForNewPage(){
    _cancelDoubleTapZoom();
    var changed = Math.abs(ZOOM - ZOOM_REST_DEFAULT) > 0.0005;
    ZOOM = ZOOM_REST_DEFAULT;
    ZOOM_REST = ZOOM_REST_DEFAULT;
    AUTO_ZOOM = null;
    _applyStartPan();
    _applyCanvas();
    if (!changed) return;
    var b = _bridge();
    if (b) b.callHandler('onMangaZoomChanged', Math.round(ZOOM * 100));
  }
  _applyStartPan();
  var rightDrag = null;
  // ── 临时合成层提升（BUG-1759）──
  // will-change:transform 一旦常驻，Chromium 就把该层的栅格化尺度钉成只升不降：
  // 缩小后合成器拿旧尺度纹理做无 mipmap 缩小 → 锯齿；放大跨过旧尺度才重栅格。
  // 改为手势/动画期间临时挂（合成器快路径不变），最后一次变换后摘掉 → 层降级，
  // 内容按当前 ZOOM 重栅格，静止画面在任何倍率下都清晰。
  function _hintWillChange(el, ms){
    if (!el) return;
    el.style.willChange = 'transform';
    if (el.__wcTimer) clearTimeout(el.__wcTimer);
    el.__wcTimer = setTimeout(function(){
      el.__wcTimer = null;
      el.style.willChange = '';
    }, ms);
  }
  function _applyCanvas(){
    var canvas = document.getElementById('manga-canvas');
    if (!canvas) return;
    _hintWillChange(canvas, 200);
    canvas.style.transform =
      'translate(' + PAN_X + 'px,' + PAN_Y + 'px) scale(' + ZOOM + ')';
  }
  function _clampZoom(z){
    return Math.min(ZOOM_MAX, Math.max(_zoomFloor(), z));
  }
  // 当前跨页内容（一页或两页）在 #manga-canvas 本地坐标里的外接框（未乘 ZOOM）。
  // 用 getBoundingClientRect 而不是 offset* 现算：旋转宽页、裁边、跨页平移都已
  // 落进去，屏幕坐标减平移再除倍率就是本地坐标。没有可见页时返回 null。
  function _contentLocalRect(){
    var pages = document.querySelectorAll('.manga-page[data-spread="'+CURRENT+'"]');
    var l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
    for (var i = 0; i < pages.length; i++) {
      var rc = pages[i].getBoundingClientRect();
      if (!(rc.width > 0 && rc.height > 0)) continue;
      l = Math.min(l, rc.left); t = Math.min(t, rc.top);
      r = Math.max(r, rc.right); b = Math.max(b, rc.bottom);
    }
    if (!(r > l && b > t) || !(ZOOM > 0)) return null;
    return {l: (l - PAN_X) / ZOOM, t: (t - PAN_Y) / ZOOM,
            r: (r - PAN_X) / ZOOM, b: (b - PAN_Y) / ZOOM};
  }
  // 让当前跨页沿 axis（'fit_height' / 'fit_width'）正好撑满视口的倍率；算不出时 0。
  function _fitZoomFor(axis, rect){
    rect = rect || _contentLocalRect();
    if (!rect) return 0;
    return axis === 'fit_width'
        ? (window.innerWidth || 0) / (rect.r - rect.l)
        : (window.innerHeight || 0) / (rect.b - rect.t);
  }
  // 缩小下限：设置里的最小倍率；「最多缩到适应页高」时再抬到页高撑满视口的倍率。
  // 只抬到 1 为止——页面在默认适配下已经比视口矮（宽页 / 横屏）时，下限就是默认
  // 适配本身，不为凑页高把页面强行放大裁掉两边。条漫没有「一页」，不设。
  function _zoomFloor(){
    if (ZOOM_OUT_LIMIT !== 'fit_height' || IS_WEBTOON) return ZOOM_MIN;
    var fit = _fitZoomFor('fit_height');
    if (!(fit > 0) || !isFinite(fit)) return ZOOM_MIN;
    return Math.max(ZOOM_MIN, Math.min(1, ZOOM_MAX, fit));
  }
  // 以 (ax, ay) 屏幕点为锚缩放到 next：锚点下的图像内容保持不动。缩到 <=1 时回中，
  // 因为此时整页已完全放得下，任何残留平移都只是把页面推出视口。
  function _zoomAbout(next, ax, ay, silent){
    next = _clampZoom(next);
    if (Math.abs(next - ZOOM) < 0.0005) return false;
    // localX/localY 是锚点所指内容的**布局坐标**（未经 scale）。webtoon 的纵向屏幕
    // 坐标是 layout*ZOOM - scrollY，故补偿写回 scrollY；spread 是 layout*ZOOM + PAN_Y。
    var localX = (ax - PAN_X) / ZOOM;
    var localY = (IS_WEBTOON ? window.scrollY + ay : ay - PAN_Y) / ZOOM;
    ZOOM = next;
    PAN_X = ax - localX * ZOOM;
    PAN_Y = IS_WEBTOON ? 0 : ay - localY * ZOOM;
    // 缩到 <=1 时横向回中：整页已放得下，残留平移只会把页面推出视口。
    // webtoon 纵向不回中（内容仍长于视口），由紧随其后的 scrollTo 保住锚点。
    if (ZOOM <= 1) _recenterPan();
    _applyCanvas();
    if (IS_WEBTOON) window.scrollTo(0, Math.max(0, localY * ZOOM - ay));
    var b = _bridge();
    if (b && !silent) b.callHandler('onMangaZoomChanged', Math.round(ZOOM * 100));
    return true;
  }
  var doubleTapZoomFrame=null;
  function _cancelDoubleTapZoom(){
    if(doubleTapZoomFrame!==null){cancelAnimationFrame(doubleTapZoomFrame);doubleTapZoomFrame=null;}
  }
  // 动画缩放到 target（以 (x, y) 为锚）。收尾把 ZOOM 钉到 target 本身：_zoomAbout
  // 对 <0.0005 的差值是 no-op，不钉的话「回到正常比例」会停在 99.97% 这类值上。
  // after：落定后、回报 Dart 之前再摆一次位（快速缩回用它把页面摆正）。
  function _animateZoomTo(target,x,y,after){
    _cancelDoubleTapZoom();
    target=_clampZoom(target);
    function settle(){
      if(ZOOM!==target){ZOOM=target;if(ZOOM<=1)_recenterPan();_applyCanvas();}
      if(after)after();
      var b=_bridge();if(b)b.callHandler('onMangaZoomChanged',Math.round(ZOOM*100));
    }
    if(!${animateDoubleTap && !preferences.einkMode}){_zoomAbout(target,x,y,true);settle();return;}
    var startZoom=ZOOM,startTime=null;
    function frame(time){
      if(startTime===null)startTime=time;
      var t=Math.min(1,(time-startTime)/${doubleTapAnimationMs.clamp(100, 600)});
      var eased=1-Math.pow(1-t,3);
      _zoomAbout(startZoom+(target-startZoom)*eased,x,y,true);
      if(t<1)doubleTapZoomFrame=requestAnimationFrame(frame);
      else {doubleTapZoomFrame=null;settle();}
    }
    doubleTapZoomFrame=requestAnimationFrame(frame);
  }
  // 双击：不在正常比例（100%）就一击回到正常比例——缩小到贴合以下也一样；
  // 正好在 100% 才放大到 2×。旧判据 ZOOM>1.01 让缩小态双击先跳 2×，要再双击
  // 一次才回得来，用户只能靠无级捏合去「凑」100%。
  // 快速缩回手势选了双击：不在目标倍率就一击缩回目标（适应页高 / 页宽），已在
  // 目标上才放大一倍——与默认的「不在 100% 就回 100%」同一形状，只是落点换成目标。
  function _doubleTapZoom(x,y){
    if(QUICK_ZOOM_GESTURE==='double_tap'){
      var fit=_quickZoomFit();
      if(fit){
        if(Math.abs(ZOOM-fit.zoom)>0.01){_quickZoomTo(fit);return;}
        _animateZoomTo(ZOOM*2,x,y);
        return;
      }
    }
    _animateZoomTo(Math.abs(ZOOM-1)>0.01 ? 1 : 2,x,y);
  }
  // 快速缩回的目标：{zoom, rect}；条漫 / 算不出版面时 null（手势照旧）。
  function _quickZoomFit(){
    if(IS_WEBTOON)return null;
    var rect=_contentLocalRect();
    if(!rect)return null;
    var zoom=_fitZoomFor(QUICK_ZOOM_TARGET,rect);
    if(!(zoom>0)||!isFinite(zoom))return null;
    return {zoom:_clampZoom(zoom),rect:rect};
  }
  // 缩到目标倍率并把跨页摆正：放得下的方向居中；放不下的方向从起读处开始——
  // 适应页宽时页面比视口高，从页顶看；适应页高时宽页比视口宽，从阅读方向的
  // 起始侧看。目标倍率记成静止倍率：缩回来的就是读者要的「整页」状态，点热区
  // 照常翻页，不算「放大看细节」。
  function _quickZoomTo(fit){
    var rect=fit.rect;
    var cx=PAN_X+(rect.l+rect.r)/2*ZOOM, cy=PAN_Y+(rect.t+rect.b)/2*ZOOM;
    _animateZoomTo(fit.zoom,cx,cy,function(){
      ZOOM_REST=Math.max(ZOOM_REST_DEFAULT,ZOOM);
      if(ZOOM<=1){_recenterPan();_applyCanvas();return;}
      var vw=window.innerWidth,vh=window.innerHeight;
      var cw=(rect.r-rect.l)*ZOOM,ch=(rect.b-rect.t)*ZOOM;
      PAN_X=cw<=vw+0.5 ? vw/2-(rect.l+rect.r)/2*ZOOM
          : (IS_RTL ? vw-rect.r*ZOOM : -rect.l*ZOOM);
      PAN_Y=ch<=vh+0.5 ? vh/2-(rect.t+rect.b)/2*ZOOM : -rect.t*ZOOM;
      _clampPan();
      _applyCanvas();
    });
  }
  function _quickZoom(){
    var fit=_quickZoomFit();
    if(!fit)return false;
    _quickZoomTo(fit);
    return true;
  }
  // 捏合结束吸附：落在正常比例 ±ZOOM_SNAP 内就收回正好 100%（并回中）。
  // 无级捏合人手凑不准 100%，残留的 95%/104% 既不贴合、也不触发放大态平移。
  // 只在**这次捏合真的改变了缩放**时吸附：fromZoom 是捏合开始时的倍率，
  // 两指只是搭上屏幕（或几乎没动）时不吸附——否则设置里定好的 105% 会被
  // 任何一次两指触碰拉回 100%。阈值 PINCH_NOOP=2%：两指静置的抖动约几像素，
  // 在 ~200px 的指距上是 1% 量级的比例，再经 ^ZOOM_SENS 更小；而有意的捏合
  // 远超 2%。
  var ZOOM_SNAP=0.1;
  var PINCH_NOOP=0.02;
  function _snapPinchZoom(x,y,fromZoom){
    if(!(Math.abs(ZOOM-fromZoom)>PINCH_NOOP))return;
    if(ZOOM!==1&&Math.abs(ZOOM-1)<=ZOOM_SNAP+1e-9)_animateZoomTo(1,x,y);
  }
  document.addEventListener('pointerdown',_cancelDoubleTapZoom,{passive:true});
  window.__mangaSetZoom = function(percent){
    // 以视口顶部为锚：scrollY 是视觉坐标（随 ZOOM 线性伸缩），换算过之后
    // 「设置里改缩放」不再把 webtoon 跳到别的页。
    var anchorLayout = IS_WEBTOON ? window.scrollY / ZOOM : 0;
    ZOOM = _clampZoom(percent / 100);
    _recenterPan();
    _applyCanvas();
    if (IS_WEBTOON) window.scrollTo(0, anchorLayout * ZOOM);
  };
  // Wide-page paging is a view transform, so OCR and selection remain in the
  // same page DOM.  Dart may ask this function before a turn; true means that
  // the request was consumed by the second half of the current page.
  window.__mangaTurnWithinPage = function(forward){
    if (!SPLIT_WIDE || ROTATE_WIDE || IS_WEBTOON) return false;
    var page = document.querySelector('.manga-page[data-spread="'+CURRENT+'"]');
    if (!page) return false;
    var pw = Number(page.getAttribute('data-pw') || 0);
    var ph = Number(page.getAttribute('data-ph') || 0);
    if (!(pw > ph * 1.15)) return false;
    var next = PAGE_HALF + (forward ? 1 : -1);
    if (next < 0 || next > 1) return false;
    PAGE_HALF = next;
    _applyPageHalf();
    return true;
  };
  // Bridge helper for OCR/capture callers. It reports coordinates in the
  // source image, after CSS crop and optional wide-page rotation. The helper
  // deliberately uses getBoundingClientRect instead of guessed viewport math.
  window.__mangaViewportToPageRect = function(pageIndex, x, y, width, height){
    var page = document.querySelector('.manga-page[data-page="'+pageIndex+'"]');
    if (!page) return null;
    var r = page.getBoundingClientRect();
    var crop=page.__crop || {x:0,y:0,width:Number(page.dataset.pw),height:Number(page.dataset.ph)};
    var nx=(x-r.left)/r.width,ny=(y-r.top)/r.height;
    var nw=width/r.width,nh=height/r.height;
    return page.__rotated
      ? {x:crop.x+ny*crop.width,y:crop.y+(1-nx-nw)*crop.height,width:nh*crop.width,height:nw*crop.height}
      : {x:crop.x+nx*crop.width,y:crop.y+ny*crop.height,width:nw*crop.width,height:nh*crop.height};
  };
  _applyCanvas();
  // ── spread translateX：把固定 100vw 的 spread 容器平移到视口左边缘 ──
  // 翻页动画四选一（slide / cover / fade / none）与速度由设置决定；运行中经
  // __mangaSetPageAnimation 改（设置面板 / 系统「减弱动态效果」变化），不重建文档。
  // 规则：长距离跳页（> MAX_ANIM_DIST 跨页）一律瞬时；动画进行中来了新的翻页，
  // 先把当前动画直接落到终点再开始下一次（不排长队）。
  var PAGE_ANIM = '${pageAnimation.key}';
  var PAGE_ANIM_MS = ${pageAnimationSpeed.durationMs};
  var FOLLOW_DRAG = $followDrag;
  var MAX_ANIM_DIST = $kPageTurnAnimationMaxAnimatedDistance;
  var FOLLOW_COMMIT = $kPageTurnFollowCommitFraction;
  var FOLLOW_FLING = $kPageTurnFollowFlingVelocity;
  var FOLLOW_EDGE_DAMPING = 0.3;
  var PAGE_EASE = '$kMangaPageTurnEasing';
  // 纯投影（无动画语义）：把 target 跨页的 offsetLeft 现场重测并换算成 root 的
  // translateX，同时记入语义真值 CURRENT。翻页动画走 __mangaApplyTranslate；
  // 摆位/resize 重投影走 _reanchor 的无过渡路径——两边共用这一个投影实现，
  // fade 的「先淡出再位移」只属于翻页，不会在 resize 风暴里连环闪烁。
  function _translateToSpread(target){
    CURRENT = target;
    var root = document.getElementById('manga-root');
    if (!root) return;
    var spread = root.querySelector('.manga-spread[data-spread="'+target+'"]');
    root.style.transform =
      'translateX(' + (spread ? -spread.offsetLeft : 0) + 'px)';
    _applyWidePolicy();
    _updateAutomaticBackground();
    _warmNeighbours(target);
  }
  // 预解码邻页：文档生成时只有首屏 ±1 跨页是 eager，翻过去之后新的 ±2 还是
  // lazy——它们要等进了视口附近才开始取图 / 解码，下一次滑动跟手拖出来的就是
  // 一块空白，松手动画里再补解码掉帧。每次落位都把 ±2 跨页提成 eager 并请求
  // 异步解码（decode() 只排队、不阻塞主线程）。
  function _warmNeighbours(target){
    for (var d = -2; d <= 2; d++) {
      var imgs = document.querySelectorAll(
        '.manga-page[data-spread="'+(target + d)+'"] img');
      for (var i = 0; i < imgs.length; i++) {
        var im = imgs[i];
        if (im.loading === 'lazy') im.loading = 'eager';
        if (im.decode) im.decode().catch(function(){});
      }
    }
  }
  function _animMs(){ return PAGE_ANIM === 'none' ? 0 : PAGE_ANIM_MS; }
  function _spreadEl(i){
    var root = document.getElementById('manga-root');
    return root ? root.querySelector('.manga-spread[data-spread="'+i+'"]') : null;
  }
  // 无过渡落位（_reanchor 同一套：关过渡 → 写 transform → 强制 reflow → 还原）。
  function _snapToSpread(target){
    var root = document.getElementById('manga-root');
    var prevTransition = root ? root.style.transition : '';
    if (root) root.style.transition = 'none';
    _translateToSpread(target);
    if (root) {
      void root.offsetHeight;
      root.style.transition = prevTransition;
    }
  }
  // 只挪 strip 的像素位置（不改语义真值 CURRENT）：拖动跟手与覆盖层的底图用。
  function _setStripX(px){
    var root = document.getElementById('manga-root');
    if (!root) return;
    root.style.transition = 'none';
    root.style.transform = 'translateX(' + px + 'px)';
  }
  // 当前在播的翻页动画：{finish}。finish 把它直接落到终点（连按 / 新拖动 / 换设置）。
  var _pageAnim = null;
  function _finishPageAnim(){
    var a = _pageAnim;
    _pageAnim = null;
    if (a) a.finish();
  }
  // 登记一段时长 ms 的动画；到点或被 finish 时恰好执行一次 done。
  function _runPageAnim(ms, done){
    var a = {timer: null, finish: null};
    var ran = false;
    var run = function(){
      if (ran) return;
      ran = true;
      if (a.timer) { clearTimeout(a.timer); a.timer = null; }
      if (_pageAnim === a) _pageAnim = null;
      done();
    };
    a.finish = run;
    a.timer = setTimeout(run, ms + 34);
    _pageAnim = a;
    return a;
  }
  function _slideTurn(target, ms){
    var root = document.getElementById('manga-root');
    if (!root) { _translateToSpread(target); return; }
    root.style.transition = 'transform ' + ms + 'ms ' + PAGE_EASE;
    _hintWillChange(root, ms + 120);
    _translateToSpread(target);
    _runPageAnim(ms, function(){
      _snapToSpread(CURRENT);
      root.style.transition = '';
    });
  }
  // 淡入淡出：淡出半程 → 瞬时位移 → 淡入半程（位移本身不过渡，否则会同时看到
  // 滑动与淡入淡出）。
  function _fadeTurn(ms){
    var root = document.getElementById('manga-root');
    if (!root) { _translateToSpread(CURRENT); return; }
    var half = Math.max(1, Math.round(ms / 2));
    var phase = null;
    root.style.transition = 'opacity ' + half + 'ms ' + PAGE_EASE;
    root.style.opacity = '0';
    phase = setTimeout(function(){
      phase = null;
      _snapToSpread(CURRENT);
      root.style.opacity = '1';
    }, half);
    _runPageAnim(ms, function(){
      if (phase) { clearTimeout(phase); phase = null; }
      root.style.transition = 'none';
      _translateToSpread(CURRENT);
      root.style.opacity = '';
      void root.offsetHeight;
      root.style.transition = '';
    });
  }
  // ── 覆盖（cover）──
  // 前进：当前页带阴影整体移走，露出下面已经就位的目标页；后退：目标页带阴影
  // 盖回来。被移动的那一屏克隆进 #manga-viewport 里的绝对定位层（图片已缓存，克隆
  // 便宜），strip 本身瞬时定位，动画结束移除覆盖层。克隆去掉 data-* / id：OCR 替换、
  // 预解码、失败重取等选择器只会命中 strip 里的真页。
  // c = {from, to, forward, delta, layer, x}；delta = strip 从 from 到 to 的位移。
  function _coverBegin(from, to){
    var fromEl = _spreadEl(from), toEl = _spreadEl(to);
    var vp = document.getElementById('manga-viewport');
    if (!fromEl || !toEl || !vp) return null;
    var c = {from: from, to: to, forward: to > from,
      delta: fromEl.offsetLeft - toEl.offsetLeft, layer: null, x: 0};
    var src = c.forward ? fromEl : toEl;
    var layer = document.createElement('div');
    layer.className = 'manga-cover-layer';
    var clone = src.cloneNode(true);
    clone.removeAttribute('data-spread');
    var tagged = clone.querySelectorAll('[data-spread],[data-page],[id]');
    for (var i = 0; i < tagged.length; i++) {
      tagged[i].removeAttribute('data-spread');
      tagged[i].removeAttribute('data-page');
      tagged[i].removeAttribute('id');
    }
    layer.appendChild(clone);
    // 覆盖层要遮住下面那一屏的留白，底色跟随当前页面底色（含自动底色）。
    var bg = window.getComputedStyle ?
        window.getComputedStyle(document.body).backgroundColor : '';
    if (bg) layer.style.background = bg;
    c.layer = layer;
    _coverPlace(c, _coverStart(c));
    vp.appendChild(layer);
    _setStripX(c.forward ? -toEl.offsetLeft : -fromEl.offsetLeft);
    return c;
  }
  // 覆盖层在「没翻」/「翻完」时的位置。
  function _coverStart(c){ return c.forward ? 0 : -c.delta; }
  function _coverEnd(c){ return c.forward ? c.delta : 0; }
  function _coverPlace(c, x){
    c.x = x;
    c.layer.style.transition = 'none';
    c.layer.style.transform = 'translateX(' + x + 'px)';
  }
  function _coverRemove(c){
    if (c && c.layer && c.layer.parentNode) c.layer.parentNode.removeChild(c.layer);
  }
  // 覆盖层从当前位置动画到 toX，结束（或被 finish）时执行 done。
  function _coverAnimate(c, toX, ms, done){
    var layer = c.layer;
    _hintWillChange(layer, ms + 120);
    void layer.offsetWidth;
    layer.style.transition = 'transform ' + ms + 'ms ' + PAGE_EASE;
    layer.style.transform = 'translateX(' + toX + 'px)';
    c.x = toX;
    _runPageAnim(ms, done);
  }
  // 播一次覆盖翻页（c = 拖动里已经建好的覆盖层，null = 现建）。失败返回 false，
  // 调用方降为平移。
  function _coverTurn(from, to, ms, c){
    if (!c) c = _coverBegin(from, to);
    if (!c) return false;
    // 前进时底图就是目标页：立即走一遍完整落位（宽页策略 / 底色 / 预解码）。
    if (c.forward) _snapToSpread(to);
    _coverAnimate(c, _coverEnd(c), ms, function(){
      _coverRemove(c);
      _snapToSpread(CURRENT);
      var root = document.getElementById('manga-root');
      if (root) root.style.transition = '';
    });
    return true;
  }
  // 每次 Dart 推进跨页 +1。跟手拖动松手后要等 Dart 答复：Dart 换了页就由翻页
  // 动画接管；没换（到头、分镜翻页、半页翻页）才由拖动自己回弹（见 _swipeRelease）。
  var TURN_SERIAL = 0;
  // 跟手拖动松手后、等 Dart 答复期间的交接：Dart 换了页，翻页动画就从手指停下
  // 的位置接着走到目标，剩余时长按剩余距离等比缩短（{x, cover}）。
  var _dragHandoff = null;
  function _dropDragHandoff(){
    var h = _dragHandoff;
    _dragHandoff = null;
    if (!h) return;
    if (h.cover) _coverRemove(h.cover);
    _snapToSpread(CURRENT);
    var root = document.getElementById('manga-root');
    if (root) root.style.transition = '';
  }
  window.__mangaApplyTranslate = function(target){
    TURN_SERIAL++;
    // 翻到含失败页的跨页 = 读者要看它：重取一次。
    _retryFailedPagesWhere(function(page){
      return Number(page.getAttribute('data-spread')) === target;
    });
    var from = CURRENT;
    var handoff = _dragHandoff;
    _dragHandoff = null;
    // 连按：上一段动画直接落到终点，再开始这一次。
    _finishPageAnim();
    if(target !== from) _flashPageChange();
    if(target!==from) PAGE_HALF=target<from ? 1 : 0;
    if(target!==from) _resetZoomForNewPage();
    CURRENT = target;
    var ms = _animMs();
    var dist = Math.abs(target - from);
    var root = document.getElementById('manga-root');
    var cover = handoff ? handoff.cover : null;
    if (cover && (PAGE_ANIM !== 'cover' || cover.from !== from ||
        cover.to !== target)) {
      _coverRemove(cover);
      cover = null;
    }
    // 无动画 / 原地重放 / 长距离跳页：瞬时落位。
    if (!root || ms <= 0 || dist === 0 || dist > MAX_ANIM_DIST) {
      if (cover) _coverRemove(cover);
      _snapToSpread(target);
      if (root) root.style.transition = '';
      return;
    }
    _hintWillChange(root, ms + 120);
    // 被拖动过的翻页按平移收尾（页面已经跟着手指走了一截）；淡入淡出只给点按 /
    // 按键这类没有拖动的翻页。
    if (PAGE_ANIM === 'fade' && !handoff) { _fadeTurn(ms); return; }
    // 覆盖：宽页切半态降为平移（翻的视图是同一跨页的半边）。
    if (PAGE_ANIM === 'cover' && !SPLIT_ACTIVE) {
      var coverMs = ms;
      if (cover) {
        var span = Math.max(1, Math.abs(cover.delta));
        coverMs = Math.max(40, Math.round(
            ms * Math.min(1, Math.abs(_coverEnd(cover) - cover.x) / span)));
      }
      if (_coverTurn(from, target, coverMs, cover)) return;
    }
    if (cover) { _coverRemove(cover); _setStripX(handoff.x); }
    var slideMs = ms;
    var toEl = _spreadEl(target);
    if (handoff && toEl) {
      slideMs = Math.max(40, Math.round(ms * Math.min(1,
          Math.abs(-toEl.offsetLeft - handoff.x) /
          Math.max(1, window.innerWidth || 1))));
    }
    _slideTurn(target, slideMs);
  };
  // 运行中换翻页动画设置（设置面板 / 系统「减弱动态效果」切换）。
  function _rootTransitionDecl(){
    if (PAGE_ANIM === 'slide') {
      return 'transition:' + 'transform ' + PAGE_ANIM_MS + 'ms ' + PAGE_EASE + ';';
    }
    if (PAGE_ANIM === 'fade') {
      return 'transition:' + 'opacity ' + Math.round(PAGE_ANIM_MS / 2) + 'ms ' +
          PAGE_EASE + ';';
    }
    return '';
  }
  window.__mangaSetPageAnimation = function(anim, ms, follow){
    _finishPageAnim();
    PAGE_ANIM = String(anim);
    PAGE_ANIM_MS = Number(ms) || 0;
    FOLLOW_DRAG = !!follow;
    var css = document.getElementById('manga-anim-css');
    if (css) css.textContent = '#manga-root{' + _rootTransitionDecl() + '}';
  };
  // ── 纵向分页的相邻翻页平滑滚动（JS 逐帧，曲线与 CSS 过渡一致）──
  function _ease(t){
    // cubic-bezier(.2,.7,.2,1)：按 x 二分求参数，再取 y。
    var lo = 0, hi = 1, s = t;
    for (var i = 0; i < 24; i++) {
      s = (lo + hi) / 2;
      var bx = 3*(1-s)*(1-s)*s*0.2 + 3*(1-s)*s*s*0.2 + s*s*s;
      if (bx < t) lo = s; else hi = s;
    }
    return 3*(1-s)*(1-s)*s*0.7 + 3*(1-s)*s*s + s*s*s;
  }
  var _scrollAnimRaf = null;
  function _stopScrollAnim(){
    if (_scrollAnimRaf) { cancelAnimationFrame(_scrollAnimRaf); _scrollAnimRaf = null; }
  }
  function _animateScrollTo(top, ms){
    var y0 = window.scrollY, t0 = null;
    var step = function(now){
      if (t0 === null) t0 = now;
      var p = Math.min(1, (now - t0) / ms);
      window.scrollTo(0, y0 + (top - y0) * _ease(p));
      if (p < 1) { _scrollAnimRaf = requestAnimationFrame(step); return; }
      _scrollAnimRaf = null;
      // 动画期间的滚动上报被挡住了（中途的 topPage 是半路的页）：落定后补报一次。
      window.dispatchEvent(new Event('scroll'));
    };
    _scrollAnimRaf = requestAnimationFrame(step);
  }
  // ── webtoon scrollTo：恢复时把 data-spread==target 的页顶滚进视口，再按**页内**
  //    fraction 微调（HIGH-1：fraction 是 (scrollY-page.offsetTop)/page.offsetHeight
  //    页内归一化，与 onMangaScroll 报的口径一致；绝非文档全局 fraction）──
  window.__mangaScrollToSpread = function(target, fraction){
    var page = document.querySelector('.manga-page[data-spread="'+target+'"]');
    if (!page) return;
    var from = CURRENT;
    // 纵向分页的换页同样复位缩放；条漫是一整条连续长图，缩放属于整条，不复位。
    // 必须在下面按 ZOOM 换算滚动目标之前。
    if (IS_VERTICAL_PAGED && target !== from) _resetZoomForNewPage();
    CURRENT = target;
    RESTORE_FRACTION = fraction || 0;
    // offsetTop/offsetHeight 是布局坐标；#manga-canvas 被 scale(ZOOM) 后
    // 视觉（滚动）坐标 = 布局坐标 * ZOOM。缺这一步在缩放态下会定位到错误的页。
    var top = (page.offsetTop + (fraction || 0) * page.offsetHeight) * ZOOM;
    _stopScrollAnim();
    // 纵向分页的相邻翻页平滑滚动（时长按速度档）；条漫、跳多页、恢复页内位置、
    // 无动画 / 墨水屏一律瞬时。
    var ms = _animMs();
    if (IS_VERTICAL_PAGED && ms > 0 && !fraction &&
        Math.abs(target - from) === 1 && Math.abs(window.scrollY - top) > 1) {
      _animateScrollTo(top, ms);
      return;
    }
    window.scrollTo(0, top);
  };
  // 聚焦一个页面内的归一化分镜矩形。Dart 侧只传原图坐标，避免把 WebView
  // 缩放/双页布局细节泄漏到检测器；这里用页面实际 client rect 计算视口中心。
  window.__mangaFocusPanel = function(pageIndex, panel){
    if (!panel) return false;
    var page = document.querySelector('.manga-page[data-page="'+pageIndex+'"]');
    if (!page) return false;
    var r = page.getBoundingClientRect();
    var crop=page.__crop || {x:0,y:0,width:Number(page.dataset.pw),height:Number(page.dataset.ph)};
    var left = (Number(panel.left)*Number(page.dataset.pw)-crop.x)/crop.width;
    var top = (Number(panel.top)*Number(page.dataset.ph)-crop.y)/crop.height;
    var right = (Number(panel.right)*Number(page.dataset.pw)-crop.x)/crop.width;
    var bottom = (Number(panel.bottom)*Number(page.dataset.ph)-crop.y)/crop.height;
    if(page.__rotated){
      var oldLeft=left,oldRight=right;
      left=1-bottom;right=1-top;top=oldLeft;bottom=oldRight;
    }
    left=Math.max(0,Math.min(1,left));top=Math.max(0,Math.min(1,top));
    right=Math.max(left,Math.min(1,right));bottom=Math.max(top,Math.min(1,bottom));
    // left/top/right/bottom 是**归一化**分数（0..1）。两处几何都容易写错：
    //  ① `Math.max(1, right - left)` 恒为 1（分数永远 ≤1），pw 就变成整页宽，
    //     算出来的是「整页适配」而不是「分镜适配」，nextZoom 在默认 fitScreen 下
    //     恒等于当前 ZOOM——永远不放大到分镜，而 PAN 照样被改写，页面被推出视口；
    //  ② getBoundingClientRect() 已经含了 canvas 的 scale(ZOOM)，要先除回去才是
    //     ZOOM=1 下的版面尺寸，否则缩放越大算出的 fit 越小。
    var baseW = r.width / ZOOM;
    var baseH = r.height / ZOOM;
    var pw = Math.max(1, (right - left) * baseW);
    var ph = Math.max(1, (bottom - top) * baseH);
    var cx = r.left + (left + right) * 0.5 * r.width;
    var cy = r.top + (top + bottom) * 0.5 * r.height;
    var vw = window.innerWidth;
    var vh = window.innerHeight;
    var fit = Math.min(vw / pw, vh / ph);
    var nextZoom = _clampZoom(Math.max(1, Math.min(ZOOM_MAX, fit * 0.90)));
    // 分镜聚焦是阅读器自己放大的：点热区照常走下一格分镜。
    ZOOM_REST = nextZoom;
    if (IS_WEBTOON) {
      var localX = (cx - PAN_X) / ZOOM;
      var localY = (window.scrollY + cy) / ZOOM;
      ZOOM = nextZoom;
      PAN_X = vw * 0.5 - localX * ZOOM;
      PAN_Y = 0;
      _applyCanvas();
      window.scrollTo(0, Math.max(0, localY * ZOOM - vh * 0.5));
    } else {
      var localPanelX = (cx - PAN_X) / ZOOM;
      var localPanelY = (cy - PAN_Y) / ZOOM;
      ZOOM = nextZoom;
      PAN_X = vw * 0.5 - localPanelX * ZOOM;
      PAN_Y = vh * 0.5 - localPanelY * ZOOM;
      // _clampPan() 在 ZOOM <= 1 时直接 return，不夹也不居中——那时 PAN 停在
      // 分镜中心会把页面推出视口且没有任何东西把它拉回来。
      if (ZOOM <= 1) { _recenterPan(); } else { _clampPan(); }
      _applyCanvas();
    }
    return true;
  };
  // 后台 OCR 每完成一页就只替换该页透明文字层，不重建 WebView 文档、不打断阅读。
  window.__mangaReplaceOcr = function(pageIndex, html){
    var page = document.querySelector('.manga-page[data-page="'+pageIndex+'"]');
    if (!page) return;
    var boxes = page.querySelectorAll('.ocr-box');
    for (var i = 0; i < boxes.length; i++) boxes[i].remove();
    var source = page.querySelector('.manga-source') || page;
    if (html) source.insertAdjacentHTML('beforeend', html);
  };
  document.addEventListener('pointermove', function(e){
    if (rightDrag) {
      var dx = e.clientX - rightDrag.lastX;
      var dy = e.clientY - rightDrag.lastY;
      rightDrag.lastX = e.clientX;
      rightDrag.lastY = e.clientY;
      if (Math.abs(e.clientX - rightDrag.startX) > 4 ||
          Math.abs(e.clientY - rightDrag.startY) > 4) {
        rightDrag.moved = true;
      }
      if (rightDrag.moved && ZOOM > 1) {
        // 右键拖动是桌面上的主力平移手势，必须和触摸/左键拖动、惯性、方向键走
        // 同一个 _panBy；在这里手抄一份自增两个 PAN 分量再提交画布的代码，会同时
        // 丢掉 _panBy 里的两条规则（注意：本注释随文档注入 WebView，故不写出那两行
        // 自增语句的字面形式 —— manga_pan_ownership_test 按字面量计数）：
        // ① _clampPan：右键能把页面推出视口且回不来（左键会回弹，右键不会）；
        // ② webtoon 纵向分流：webtoon 纵向的唯一拥有者是 scrollY、PAN_Y 恒 0，
        //    手抄版把 PAN_Y 写成非 0，而 onMangaScroll 与 __mangaScrollToSpread
        //    都按 PAN_Y=0 用 scrollY/ZOOM 换算 offsetTop → 进度落库/恢复错页；
        //    _clampPan 又有意不碰 webtoon 的 PAN_Y，于是永远拉不回来。
        _panBy(dx, dy);
      }
      e.preventDefault();
      return;
    }
    // 捏合期间纵向由 _zoomAbout 的锚点补偿独占，不能再叠一层拖动位移。
    if (pinch) return;
    if (!panDrag || panDrag.id !== e.pointerId) return;
    var pnow = Date.now();
    var pdx = e.clientX - panDrag.lastX;
    var pdy = e.clientY - panDrag.lastY;
    var pdt = Math.max(1, pnow - panDrag.lastT);
    panDrag.lastX = e.clientX;
    panDrag.lastY = e.clientY;
    panDrag.lastT = pnow;
    panDrag.vy = pdy / pdt * 1000;
    // 松手速度取最近约 100ms 的位移 / 时间（见 _releaseVelocity）：只看最后一次
    // pointermove 时，两次事件间隔 1~2ms 的抖动会把速度放大成离谱值或压成 0，
    // 惯性一会儿飞很远、一会儿根本不滑——「滑动有卡顿感」的一半来源。
    var ps = panDrag.samples;
    ps.push({t: e.timeStamp, y: e.clientY});
    while (ps.length > 2 && e.timeStamp - ps[0].t > 100) ps.shift();
    _panBy(pdx, pdy);
    _swipeMove(e.clientX, e.clientY);
  }, {passive: false});
  var CURRENT = $currentSpread;
  var RESTORE_FRACTION = ${restoreFraction.toStringAsFixed(6)};
  // resize 已发生、_reanchor 还没跑的窗口期标志（见 resize 监听处的说明）。
  var _resizePending = false;
  // Online sources do not expose pixel dimensions before the first image
  // response. Replace the bootstrap ratio with the browser-decoded (and EXIF
  // oriented) dimensions as soon as each page loads. OCR coordinates and the
  // page box then share one exact geometry instead of a 1000x1400 placeholder.
  window.__mangaUpdatePageGeometry = function(pageIndex, width, height){
    if (!(width > 0 && height > 0)) return;
    var page = document.querySelector('.manga-page[data-page="'+pageIndex+'"]');
    if (!page) return;
    page.setAttribute('data-pw', String(width));
    page.setAttribute('data-ph', String(height));
    page.style.aspectRatio = width + ' / ' + height;
    _inspectSource(page);
    _applyWidePolicy();
  };
  document.querySelectorAll('.manga-page').forEach(function(page){
    var image = page.querySelector('img');
    if (!image) return;
    var apply = function(){
      if (!(image.naturalWidth > 0 && image.naturalHeight > 0)) return;
      window.__mangaUpdatePageGeometry(
        Number(page.getAttribute('data-page')),
        image.naturalWidth,
        image.naturalHeight
      );
    };
    image.addEventListener('load', apply);
    // 取页失败（拦截器回 502 / 网络断）：浏览器不会再自己请求这张图，整章不重开
    // 这页就一直白着。只打标记，重取由读者动作触发（_retryPageImage），不盲重试。
    image.addEventListener('error', function(){
      page.setAttribute('data-load-failed', '1');
    });
    if (image.complete) apply();
  });
  // 失败页重取：带一个新的 retry 查询参数换掉 src（拦截器只看 path，同一页照取；
  // 换 URL 才能绕开浏览器对失败资源的缓存）。
  var RETRY_SERIAL = 0;
  function _retryPageImage(page){
    if (!page || page.getAttribute('data-load-failed') !== '1') return false;
    var image = page.querySelector('img');
    if (!image) return false;
    page.removeAttribute('data-load-failed');
    var base = image.getAttribute('data-base-src');
    if (!base) {
      base = image.getAttribute('src') || '';
      image.setAttribute('data-base-src', base);
    }
    RETRY_SERIAL++;
    image.setAttribute('loading', 'eager');
    image.src = base + (base.indexOf('?') < 0 ? '?' : '&') + 'retry=' + RETRY_SERIAL;
    return true;
  }
  function _retryFailedPagesWhere(match){
    var failed = document.querySelectorAll('.manga-page[data-load-failed="1"]');
    for (var i = 0; i < failed.length; i++) {
      if (match(failed[i])) _retryPageImage(failed[i]);
    }
  }
  // 点击重取只认失败页中央那个重试符号的命中区（以页面中心为心的方块，边长
  // RETRY_HIT_PX，≥48dp），不认整页：单页模式下失败页铺满视口，按整页命中会把
  // 左右翻页热区的点击全吞掉，读者卡在失败页上翻不走（BUG：在线直读失败页吞翻页点击）。
  var RETRY_HIT_PX = 72;
  function _retryFailedPageAt(x, y){
    var failed = document.querySelectorAll('.manga-page[data-load-failed="1"]');
    var half = RETRY_HIT_PX / 2;
    for (var i = 0; i < failed.length; i++) {
      var r = failed[i].getBoundingClientRect();
      var cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
      if (Math.abs(x - cx) <= half && Math.abs(y - cy) <= half) {
        return _retryPageImage(failed[i]);
      }
    }
    return false;
  }
  // 摆位是「重投影」，不是「翻页」：必须无过渡落位。首次定位与 viewport resize
  // 共用这一个函数——两者本质相同：把语义真值（CURRENT 跨页 + RESTORE_FRACTION
  // 页内偏移 + ZOOM/PAN）投影成当前视口下的 px。
  //
  // 无过渡的原因（首次定位侧）：RTL（默认阅读方向）倒序写入 DOM 后，spread 0 的
  // offsetLeft 从 0 变成 (n-1)×100vw，首帧要把 #manga-root 从 transform:none 一路
  // 推到 -(n-1)×100vw；而 slide（默认动画）给 #manga-root 挂着 transition:transform，
  // 下面的双 rAF 又恰好是「保证过渡一定触发」的惯用法 —— 于是打开任何 RTL 书都会
  // 先看到整卷从最后一页扫回第一页（strip 是整卷长度，200 跨页就是 199 个视口的
  // 扫掠，途经的 lazy 图还会被连带解码）。
  //
  // resize 侧（BUG-1758）：布局全走视口单位（100vw/100vh），窗口一变浏览器立即
  // 重排；但 translateX / PAN / scrollY 是加载或手势那一刻由**旧视口**换算出的 px
  // 投影，此前没人重算——strip 钉在旧 px 上，视口里露出的就是错误的跨页（看似
  // 「随机页」），直到下次翻页被现场重测救回。现在 resize 直接重投影。
  //
  // 关过渡 → 写 transform → 读一次 offsetHeight 强制同步 reflow（让新值成为后续
  // 过渡的起点，否则还原后浏览器仍把这次位移算成一次过渡）→ 还原原过渡值。
  // 还原发生在 reflow 之后，真正的翻页动画不受影响（不是永久关掉过渡）。
  function _reanchor(){
    // PAN 也是旧视口的 px 投影：整页放得下时归中心（_recenterPan 的既有语义），
    // 放大态钳回新视口的合法区间（_clampPan 的既有语义）。
    if (ZOOM <= 1) { _recenterPan(); } else { _clampPan(); }
    _applyCanvas();
    if (IS_WEBTOON) {
      window.__mangaScrollToSpread(CURRENT, RESTORE_FRACTION);
      return;
    }
    // 动画里的像素都是旧视口算的：先落到终点再重投影。
    _finishPageAnim();
    var root = document.getElementById('manga-root');
    var prevTransition = root ? root.style.transition : '';
    if (root) root.style.transition = 'none';
    _translateToSpread(CURRENT);
    if (root) {
      void root.offsetHeight;
      root.style.transition = prevTransition;
    }
  }
  // 图片/布局完成前 offsetLeft/offsetTop 可能为 0；首帧后 + load 后各定位一次。
  if (document.readyState === 'complete') { _reanchor(); }
  window.addEventListener('load', _reanchor);
  requestAnimationFrame(function(){ requestAnimationFrame(_reanchor); });
  // resize 风暴（拖窗口边框）rAF 合并：每帧至多重投影一次。_resizePending 同时
  // 挡住 webtoon 滚动上报的窗口期——resize 与重投影之间若有迟到的节流上报，会把
  // 「视觉上错误的页」记成语义真值，重投影反而钉死漂移。
  var _reanchorRaf = null;
  window.addEventListener('resize', function(){
    _resizePending = true;
    if (_reanchorRaf) return;
    _reanchorRaf = requestAnimationFrame(function(){
      _reanchorRaf = null;
      _resizePending = false;
      _reanchor();
    });
  });

  // ── 手势消歧（pointer，覆盖触摸/鼠标）──
  // spx：按下时的 PAN_X。松手时「手指横移 − 画布实际横移」= 平移**没吃掉**的
  // 那段（贴边被 _clampPan 钳住的余量），它才参与 swipe 判定。
  var sx = 0, sy = 0, st = 0, spx = 0, has = false;
  // ── 横滑跟手（spread）──
  // 此前横滑是「松手才翻页」：拖动全程页面纹丝不动，松手后才从静止状态播一段
  // 翻页动画——手指走了 200px 页面一像素没动，这就是「滑动翻页不跟手」。现在
  // 横向锁定后 #manga-root 的 translateX 逐帧 = 落位值 + 手指横移（扣掉放大态
  // 平移吃掉的那段），1:1 跟随；松手由 _end 的阈值决定交给 Dart 翻页还是回弹。
  // 拖动中关掉 root 的 transition（否则每一帧都在追一段 ease-out，永远慢半拍），
  // 翻页 / 回弹动画都从手指停下的位置接着走。
  // 跟手只看设置开关（_followActive），**与翻页动画无关**（BUG-3624，对齐 Mihon：
  // ViewPager 的拖动永远跟手，「页面切换动画」只管点按 / 按键翻页）。此前跟手
  // 绑在 slide / cover 上：选了「无 / 淡入淡出」、墨水屏、系统「减弱动态效果」，
  // 或旧版关过「页面切换动画」被迁移成「无」的用户，拖动全程页面纹丝不动、
  // 松手才跳——这正是「不跟手」。动画只决定松手后怎么落位：无动画瞬时落位，
  // 淡入淡出在被拖过之后按平移收尾（手指已经把页面拖走一截，再淡出是两段动作）。
  // 「覆盖」跟手时动的是克隆层（见 _coverDrag），朝没有相邻跨页的方向拖按
  // FOLLOW_EDGE_DAMPING 阻尼，松手回弹，跨章仍交给 Dart。
  // swipe：null = 没有在跟的手势；axis 在越过 SWIPE_SLOP 后锁定为 'x' / 'y'。
  var SWIPE_SLOP = 8;
  var swipe = null;
  var swipeToken = 0;
  // 「放大时拖过边缘翻页」（反馈 EjyFnomM6w）：关掉后，用户放大看细节时拖到边缘
  // 只是贴边，余量不再交给翻页、页面也不跟手——放大看句子时手一滑就翻走是那位
  // 墨水屏用户的原话。未放大 / 只是默认倍率时照常滑动翻页。
  var ZOOMED_EDGE_TURN = ${preferences.zoomedEdgeTurn};
  function _zoomedEdgeTurnBlocked(){
    return !ZOOMED_EDGE_TURN && !IS_WEBTOON && _userZoomedIn();
  }
  function _followActive(){
    return FOLLOW_DRAG && !IS_WEBTOON;
  }
  function _start(x, y){
    has = true; sx = x; sy = y; st = Date.now(); spx = PAN_X;
    // 新的一次按下：在播的翻页动画直接落到终点，还挂着的上一次松手交接作废。
    _finishPageAnim();
    _dropDragHandoff();
    swipe = {axis: null, base: null, vx: 0, lastX: x, lastT: st, x: 0,
      cover: null, follow: _followActive() && !_zoomedEdgeTurnBlocked()};
  }
  function _swipeMove(x, y){
    if (!has || !swipe || IS_WEBTOON) return;
    var now = Date.now(), dt = Math.max(1, now - swipe.lastT);
    swipe.vx = (x - swipe.lastX) / dt * 1000;
    swipe.lastX = x; swipe.lastT = now;
    if (!swipe.axis) {
      var adx = Math.abs(x - sx), ady = Math.abs(y - sy);
      if (Math.max(adx, ady) < SWIPE_SLOP) return;
      swipe.axis = adx > ady ? 'x' : 'y';
    }
    // 宽页切半（SPLIT_ACTIVE）的翻页是同一跨页内的视图变换，平移整条 strip
    // 露出的是相邻跨页、不是另一半——这种页不跟手，保持松手判定。
    if (swipe.axis !== 'x' || SPLIT_ACTIVE || !swipe.follow) return;
    var root = document.getElementById('manga-root');
    if (!root) return;
    if (swipe.base === null) {
      var spread = root.querySelector('.manga-spread[data-spread="'+CURRENT+'"]');
      swipe.base = spread ? -spread.offsetLeft : 0;
      root.style.transition = 'none';
    }
    // 手指横移 − 画布平移吃掉的那段 = 交给翻页的余量（与 _end 的 ux 同口径）。
    var follow = (x - sx) - (PAN_X - spx);
    // 拖向的相邻跨页：内容左移（follow<0）露出 strip 右边那一屏；RTL 倒序排布时
    // 右边是上一跨页（与 _end 的 swipeRight === IS_RTL 同一镜像）。
    var nb = CURRENT + (((follow < 0) !== IS_RTL) ? 1 : -1);
    var hasNeighbour = follow !== 0 &&
        !!root.querySelector('.manga-spread[data-spread="'+nb+'"]');
    if (follow !== 0 && !hasNeighbour) follow *= FOLLOW_EDGE_DAMPING;
    _hintWillChange(root, PAGE_ANIM_MS + 400);
    // swipe.x 恒记「平移跟手时 strip 该在的位置」：覆盖层被放弃（Dart 换的不是拖向
    // 的那一页）时，降级的平移从这里接着走。
    swipe.x = swipe.base + follow;
    if (PAGE_ANIM === 'cover' && hasNeighbour) { _coverDrag(nb, follow); return; }
    if (swipe.cover) { _coverRemove(swipe.cover); swipe.cover = null; }
    root.style.transition = 'none';
    root.style.transform = 'translateX(' + swipe.x + 'px)';
  }
  // 「覆盖」跟手：动的是克隆层，strip 静止在底图位置。换了拖动方向（目标跨页变了）
  // 就拆掉旧层按新方向重建。
  function _coverDrag(nb, follow){
    var c = swipe.cover;
    if (c && c.to !== nb) { _coverRemove(c); c = null; swipe.cover = null; }
    if (!c) {
      c = _coverBegin(CURRENT, nb);
      if (!c) return;
      swipe.cover = c;
    }
    _hintWillChange(c.layer, PAGE_ANIM_MS + 400);
    _coverPlace(c, _coverStart(c) + follow);
  }
  // 回弹到当前跨页（instant = 瞬时，第二指落下进捏合时用）。
  function _swipeBounce(s, instant){
    var root = document.getElementById('manga-root');
    if (!root) return;
    var cur = _spreadEl(CURRENT);
    var dist = s.cover
        ? Math.abs(_coverStart(s.cover) - s.cover.x)
        : Math.abs((cur ? -cur.offsetLeft : 0) - s.x);
    var ms = instant ? 0 : Math.max(80, Math.round(
        _animMs() * Math.min(1, dist / Math.max(1, window.innerWidth || 1))));
    var done = function(){
      if (s.cover) _coverRemove(s.cover);
      _snapToSpread(CURRENT);
      root.style.transition = '';
    };
    if (ms <= 0 || _animMs() <= 0) { done(); return; }
    if (s.cover) { _coverAnimate(s.cover, _coverStart(s.cover), ms, done); return; }
    root.style.transition = 'transform ' + ms + 'ms ' + PAGE_EASE;
    _translateToSpread(CURRENT);
    _runPageAnim(ms, done);
  }
  // 结束跟手。turning=false：立即回弹到当前跨页。turning=true：只还原
  // transition，返回一个 settle 回调——Dart 处理完翻页请求后调用它：Dart 真换了
  // 页（TURN_SERIAL 变了）就什么都不做，由翻页动画接管；没换（到头 / 分镜翻页 /
  // 换章中）才回弹。新的一次拖动开始后旧 settle 作废。
  function _swipeRelease(turning, instant){
    var s = swipe;
    swipe = null;
    if (!s || s.base === null) return null;
    var root = document.getElementById('manga-root');
    if (!root) return null;
    var token = ++swipeToken;
    if (!turning) { _swipeBounce(s, instant); return null; }
    // 页面停在手指松开的位置等 Dart：换了页由 __mangaApplyTranslate 接着走，
    // 没换由下面的 settle 回弹。
    var handoff = {x: s.x, cover: s.cover};
    _dragHandoff = handoff;
    var serial = TURN_SERIAL;
    return function(){
      if (token !== swipeToken || swipe || TURN_SERIAL !== serial) return;
      if (_dragHandoff === handoff) _dragHandoff = null;
      _swipeBounce(s, false);
    };
  }
  // ── 触屏双指捏合缩放 ──
  // 此前触屏**完全无法缩放**：viewport 声明了 user-scalable=no（必须的：浏览器原生
  // 缩放会和 #manga-canvas 的 transform 打架），而 JS 侧没有任何 touch/多指处理。
  // 于是移动端漫画只能看 100%，这也是「缩放极其不灵敏」的一部分。
  // 这里自己实现：记录活跃触点，两指时按距离比例缩放并以两指中点为锚。
  var touchPts = {};
  // ── 拖动平移 / webtoon 自实现竖滚（BUG-1701）──
  // touch-action:none 之后浏览器不再做任何原生手势，纵向滚动的所有权落到这里：
  // - webtoon：纵向写 window.scrollY（触屏松手带惯性），放大后横向写 PAN_X；
  // - spread：只在放大态平移两轴；未放大时视口内无处可平移，拖动仍是 swipe 翻页。
  // 不按指针类型分叉：鼠标左键拖动与手指是同一语义，只有惯性是触屏独有。
  var panDrag = null;
  var flickRaf = null;
  var flickVy = 0;
  function _stopFlick(){
    if (flickRaf) { cancelAnimationFrame(flickRaf); flickRaf = null; }
    flickVy = 0;
  }
  // PAN 的合法区间：可见内容是**一个跨页**（100vw×100vh；webtoon 横向同宽，纵向归
  // window.scrollY）。#manga-canvas 是 transform-origin:0 0，内容被 scale 后宽
  // vw*ZOOM，于是 PAN_X 只能落在 [vw*(1-ZOOM), 0]——上界 0 = 内容左边缘贴视口左边，
  // 下界 = 右边缘贴视口右边。ZOOM<=1 时区间退化（内容比视口小），此时位置由
  // _recenterPan 居中拥有，不参与钳制。
  //
  // 此前 PAN 完全没有边界：拖动能把页面推出视口且回不来（放大后尤其容易），方向键
  // 平移是离散步进、按几十下必然踩到。钳制放在 _panBy 里，拖动/惯性/方向键三条
  // 平移路径共用同一条规则。
  function _clampPan(){
    if (ZOOM <= 1) return;
    var minX = window.innerWidth * (1 - ZOOM);
    if (PAN_X < minX) PAN_X = minX;
    if (PAN_X > 0) PAN_X = 0;
    if (!IS_WEBTOON) {
      var minY = window.innerHeight * (1 - ZOOM);
      if (PAN_Y < minY) PAN_Y = minY;
      if (PAN_Y > 0) PAN_Y = 0;
    }
  }
  function _panBy(dx, dy){
    var canvasMoved = false;
    if (!PAN_WIDE && _currentPageIsWide() && ZOOM <= 1) return;
    if (IS_WEBTOON) {
      if (dy) window.scrollBy(0, -dy);
      if (ZOOM > 1 && dx) { PAN_X += dx; canvasMoved = true; }
    } else if (ZOOM > 1) {
      if (dx) { PAN_X += dx; canvasMoved = true; }
      if (dy) { PAN_Y += dy; canvasMoved = true; }
    }
    if (canvasMoved) { _clampPan(); _applyCanvas(); }
  }
  // 方向键平移（Flutter 侧 ShortcutRegistry 驱动，见 MangaReaderInputAction.pan*）。
  // 参数是**视口比例**而不是像素：同一步长在 1080p 和 4K 上手感一致。
  // 符号按「视野怎么动」给（与滚动条直觉一致）：fx>0 = 视野右移，fy>0 = 视野下移；
  // _panBy 的入参是「内容怎么动」，故取负。
  // spread 模式在 ZOOM<=1 时整页已放得下，_panBy 自然 no-op（静默无效，不回落成翻页，
  // 免得和翻页键语义打架）；webtoon 的上下平移恒等于滚动文档，任何倍率都有效。
  window.__mangaPanBy = function(fx, fy){
    _panBy(-window.innerWidth * fx, -window.innerHeight * fy);
  };
  // 松手速度（px/s，向下拖为正）：最近约 100ms 窗口内的平均速度。手指停住
  // 超过 50ms 再抬起视为「按住后松开」，不带惯性。
  function _releaseVelocity(drag, upT){
    var ps = drag.samples;
    if (!ps || ps.length < 2) return drag.vy;
    var last = ps[ps.length - 1];
    if (upT - last.t > 50) return 0;
    var first = ps[0];
    var span = last.t - first.t;
    if (span < 8) return drag.vy;
    return (last.y - first.y) / span * 1000;
  }
  // 惯性：时间常数约 330ms（每秒衰减到 5%），滑行距离约为松手速度 × 0.33s，
  // 接近系统原生滚动的手感；旧值（每秒衰减到 0.2%，时间常数 160ms）一甩就
  // 急刹，读长条漫要不停地反复拨。低于 40px/s 停，阈值挡掉松手时的微抖动。
  function _startFlick(vy){
    if (!IS_WEBTOON || Math.abs(vy) < 80) return;
    flickVy = vy;
    var last = null;
    var step = function(now){
      if (typeof now !== 'number') now = Date.now();
      var dt = last === null ? 16 : Math.min(64, Math.max(1, now - last));
      last = now;
      flickVy *= Math.pow(0.05, dt / 1000);
      if (Math.abs(flickVy) < 40) { _stopFlick(); return; }
      window.scrollBy(0, -flickVy * dt / 1000);
      flickRaf = requestAnimationFrame(step);
    };
    flickRaf = requestAnimationFrame(step);
  }
  var pinch = null;
  // 双指点按（快速缩回手势之一）：两指先后落下、在 TWO_TAP_MS 内抬起，指距与中点
  // 都几乎没动、倍率没被捏动——它和捏合共用触点表与 pinch 记账，只在第一根手指
  // 抬起（捏合结束）时分流。没选这个手势时一律按捏合处理（吸附 100%）。
  var TWO_TAP_MS = 300, TWO_TAP_SLOP = 24;
  function _isTwoFingerTap(p){
    if (QUICK_ZOOM_GESTURE !== 'two_finger_tap' || IS_WEBTOON || !p) return false;
    if (!(p.t0 > 0) || Date.now() - p.t0 > TWO_TAP_MS) return false;
    var dx = p.cx - p.cx0, dy = p.cy - p.cy0;
    if (dx * dx + dy * dy > TWO_TAP_SLOP * TWO_TAP_SLOP) return false;
    if (p.span > TWO_TAP_SLOP) return false;
    return !(Math.abs(ZOOM - p.zoom) > PINCH_NOOP);
  }
  // 捏合结束后要吞掉配对的松手事件，否则手指抬起会被 _end 判成 swipe 翻页。
  // （注意：本注释随文档注入 WebView，不得出现松手事件的字面名——
  // manga_overlay_html_test 的 C1 不变式按该字面量计数，全文档恰好允许一个。）
  var pinchGuard = false;
  function _pinchGeom(){
    var ids = Object.keys(touchPts);
    if (ids.length < 2) return null;
    var a = touchPts[ids[0]], b = touchPts[ids[1]];
    var dx = a.x - b.x, dy = a.y - b.y;
    return {
      dist: Math.sqrt(dx * dx + dy * dy),
      cx: (a.x + b.x) / 2,
      cy: (a.y + b.y) / 2
    };
  }
  // Niratan-style hit testing: regions are explicit character rectangles.
  // Use a constant 4 screen-pixel slop at every zoom and choose the smallest
  // overlapping region, instead of asking browser caret geometry to guess.
  function _hitOcrChar(x, y){
    var stack = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
    var page = null, exact = [];
    for (var i = 0; i < stack.length; i++) {
      var el = stack[i];
      var charEl = el.closest && el.closest('.ocr-char');
      if (charEl && exact.indexOf(charEl) < 0) exact.push(charEl);
      if (!page && el.closest) page = el.closest('.manga-page');
    }
    var candidates = exact;
    if (!candidates.length && page) {
      candidates = Array.prototype.slice.call(page.querySelectorAll('.ocr-char'));
    }
    var best = null, bestArea = Infinity;
    for (var j = 0; j < candidates.length; j++) {
      var candidate = candidates[j];
      var r = candidate.getBoundingClientRect();
      if (x < r.left - 4 || x > r.right + 4 ||
          y < r.top - 4 || y > r.bottom + 4) continue;
      var area = Math.max(0.01, r.width * r.height);
      if (area < bestArea) { best = candidate; bestArea = area; }
    }
    return best;
  }
  // 三态结果：'miss' 没点到字；'same' 点的就是当前已选的字（点击路径按开关语义
  // 清掉选区，悬停路径原样保留）；'hit' 选中了新字、onTextSelected 随后由
  // fushiSelection 触发。Dart 侧的 barrier 转发（BUG-2553）要靠这个区分
  // 「换词」和「点空白 / 再点同一个词 → 关弹窗」。
  function _selectOcrCharDetail(x, y, fromHover){
    var charEl = _hitOcrChar(x, y);
    var selection = window.fushiSelection;
    if (!charEl || !selection) return 'miss';
    var node = charEl.firstChild;
    if (!node || node.nodeType !== Node.TEXT_NODE) return 'miss';
    window.__mangaLastOcrHit = {
      text: node.textContent || '',
      orientation: charEl.getAttribute('data-ocr-orientation') || '',
      x: x, y: y, zoom: ZOOM
    };
    if (selection.selection &&
        selection.selection.startNode === node &&
        selection.selection.startOffset === 0) {
      if (fromHover) return 'same';
      selection.clearSelection();
      return 'same';
    }
    selection.clearSelection();
    selection.selectFromPosition(node, 0, 40, x, y, fromHover);
    var bridge = _bridge();
    if (bridge) bridge.callHandler('onMangaOcrHitDebug',
      JSON.stringify(window.__mangaLastOcrHit));
    return 'hit';
  }
  function _selectOcrChar(x, y, fromHover){
    return _selectOcrCharDetail(x, y, fromHover) !== 'miss';
  }
  // BUG-2553：查词弹窗一开，Flutter 侧全屏 dismiss barrier 盖在 WebView 之上，
  // 底下的指针抬起事件一个都收不到——此前「点另一个词」= 点 barrier = 清整栈，
  // 第二次点击才到得了这里。Dart 把 barrier 上的点击/Shift 悬停逆映成 CSS 坐标
  // 转发到这两个入口：点击回三态字符串让 Dart 决定换词还是关栈；悬停只报是否命中。
  window.__mangaBarrierTapAt = function(x, y){
    try { return _selectOcrCharDetail(x, y, false); } catch (e) { return 'miss'; }
  };
  window.__mangaBarrierHoverAt = function(x, y){
    try { return _selectOcrChar(x, y, true); } catch (e) { return false; }
  };
  // Desktop Shift-hover lookup: mirror the EPUB reader's hover path. Throttle by
  // pointer distance so a stationary cursor does not repeat the same lookup.
  var shiftHoverX = -1, shiftHoverY = -1;
  document.addEventListener('mousemove', function(e){
    if (!e.$hoverKey && !${preferences.lookupOnHover}) { shiftHoverX = -1; shiftHoverY = -1; return; }
    var dx = e.clientX - shiftHoverX, dy = e.clientY - shiftHoverY;
    if (shiftHoverX >= 0 && dx * dx + dy * dy < 16) return;
    shiftHoverX = e.clientX; shiftHoverY = e.clientY;
    _selectOcrChar(e.clientX, e.clientY, true);
  }, {passive:true});
  // 点击热区翻页。此前漫画**没有任何点击翻页手段**：_onTap 命中不到 OCR 就只报
  // onTapEmpty（Dart 侧只回收焦点），触屏用户只能靠 swipe。
  //
  // 热区表由 Dart 的 mangaTapZones() 算好后注入（每项 [left,top,width,height,
  // forward]，视口归一化 0..1），**阅读方向镜像已经在 Dart 侧做完**，这里不得再
  // 镜像一次。JS 只做遍历命中这一件事：几何和镜像有单测钉着，注入后的脚本不必再
  // 靠人眼复核。命中不到的区域（如 left_right 布局的中央）仍走 onTapEmpty，把
  // 查词 / 呼出 chrome / 双击缩放留给它。
  var TAP_ZONE_PAGING = $tapZonePaging;
  var IS_RTL = $rtl;
  var TAP_ZONES = [$tapZonesJs];
  if (${preferences.showTapZonesOverlay} && TAP_ZONE_PAGING) {
    var navigationHint=document.createElement('div');navigationHint.id='manga-navigation-hint';
    TAP_ZONES.forEach(function(zone){
      var tile=document.createElement('span');
      tile.style.cssText='left:'+zone[0]*100+'%;top:'+zone[1]*100+'%;width:'+zone[2]*100+'%;height:'+zone[3]*100+'%;';
      tile.textContent=IS_WEBTOON ? (zone[4]?'↓':'↑') : ((zone[4]!==IS_RTL)?'→':'←');
      navigationHint.appendChild(tile);
    });document.body.appendChild(navigationHint);
  }
  function _dismissStartupHints(){
    ['manga-navigation-hint','manga-mode-hint'].forEach(function(id){var node=document.getElementById(id);if(node)node.remove();});
  }
  document.addEventListener('pointerdown',_dismissStartupHints,{once:true,passive:true});
  setTimeout(_dismissStartupHints,3000);
  function _tapZoneTurn(x, y){
    if (!TAP_ZONE_PAGING) return null;
    var w = window.innerWidth || 1, h = window.innerHeight || 1;
    var nx = x / w, ny = y / h;
    for (var i = 0; i < TAP_ZONES.length; i++){
      var z = TAP_ZONES[i];
      if (nx >= z[0] && nx < z[0] + z[2] && ny >= z[1] && ny < z[1] + z[3]) {
        return z[4] ? 'next' : 'prev';
      }
    }
    return null;
  }
  // webtoon 没有「页」可翻，热区改为滚动一屏（留 10% 重叠，避免跨越处的一行字
  // 恰好被跳过）。走 window.scrollBy 与拖动/惯性同一个纵向拥有者（scrollY），
  // 进度回报 onMangaScroll 照常触发。
  function _tapScroll(dir){
    window.scrollBy(0, dir * (window.innerHeight || 0) * 0.9);
  }
  // 双击缩放：只在**点击本来就是 no-op 的区域**上生效（没命中 OCR 字、也没命中
  // 翻页热区）。查词与热区翻页在 _onTap 里排在双击判定之前、命中即返回，所以
  // 它们零延迟——查词响应速度是用户明确抱怨过的一项，绝不能为等第二击推迟它。
  // 被推迟的只有**空白单击**的 onTapEmpty：它在 Dart 侧会切换悬浮栏，若第一击
  // 立刻上报，默认悬浮态下每次双击缩放都会连带闪一次顶栏/底栏（放大时弹出、
  // 缩回时收起）。所以空白单击先挂 DBL_MS 定时器，第二击到达就取消它只做缩放；
  // 没有第二击才把 onTapEmpty 补发出去。代价是 kindle 布局下中央也是翻页热区，
  // 双击缩放在该布局下只剩边角，属于该布局自身的取舍。
  // The window stays enabled when animation is disabled: Mihon separates the
  // double-tap gesture from its visual zoom animation.  A zero timeout would
  // make every double tap two independent empty taps.
  var DBL_MS = ${doubleTapAnimationMs.clamp(100, 600)}, DBL_SLOP = 30;
  var lastTapT = 0, lastTapX = 0, lastTapY = 0;
  var pendingEmptyTap = null;
  // 双击窗口按「第一击松手 → 第二击**按下**」计（反馈 IDF2uWUvlf，与 Android
  // GestureDetector 的 DOUBLE_TAP_TIMEOUT 同口径）。此前只在第二击**松手**时判，
  // 窗口里还得塞下第二击按住的那 ~100ms，挂起的 onTapEmpty 定时器又是从第一击
  // 松手起算——手指还按在屏上它就先发了，悬浮栏被切出来、双击缩放落空，只有
  // 快速三击（第二、三击凑成一对）才偶尔放大。第二击按下时落在挂起窗口内且离
  // 第一击够近，就当场取消挂起的单击并武装双击，松手时直接缩放。
  var dblArmed = false;
  function _armDoubleTapOnDown(x, y){
    dblArmed = false;
    if (pendingEmptyTap === null) return;
    var dx = x - lastTapX, dy = y - lastTapY;
    if ((dx * dx + dy * dy) > DBL_SLOP * DBL_SLOP) return;
    _cancelPendingEmptyTap();
    dblArmed = true;
  }
  function _consumeDoubleTap(x, y){
    var now = Date.now();
    var dx = x - lastTapX, dy = y - lastTapY;
    var armed = dblArmed;
    dblArmed = false;
    var isDouble = armed || ((now - lastTapT) <= DBL_MS &&
        (dx * dx + dy * dy) <= DBL_SLOP * DBL_SLOP);
    if (isDouble) { lastTapT = 0; return true; }
    lastTapT = now; lastTapX = x; lastTapY = y;
    return false;
  }
  function _cancelPendingEmptyTap(){
    if (pendingEmptyTap !== null) { clearTimeout(pendingEmptyTap); pendingEmptyTap = null; }
  }
  function _deferEmptyTap(){
    _cancelPendingEmptyTap();
    pendingEmptyTap = setTimeout(function(){
      pendingEmptyTap = null;
      var b = _bridge();
      if (b) b.callHandler('onTapEmpty');
    }, DBL_MS);
  }
  function _onTap(x, y){
    var b = _bridge();
    if (!b) return;
    if (_selectOcrChar(x, y, false)) return;
    var zone = _tapZoneTurn(x, y);
    // 放大看细节时点左右不翻页（BUG-3634）：此时画面只露出页面的一块，热区
    // 是按视口划的，点哪都可能落进翻页区，读者只想点一下收起工具栏或双击
    // 缩回，却被翻走。放大态这一击落到下面的空白点语义（双击缩回 / 切悬浮栏）；
    // 翻页靠贴边后继续拖（_end 的平移余量判据）。webtoon 的热区是纵向滚一屏，
    // 放大后仍是导航，照常生效。
    if (zone && !IS_WEBTOON && _userZoomedIn()) zone = null;
    if (zone) {
      if (IS_WEBTOON) { _tapScroll(zone === 'next' ? 1 : -1); return; }
      b.callHandler('onMangaTurn', zone);
      return;
    }
    // 翻页热区之外、点中失败页的重试符号：重取它，这一击不再做别的。必须排在
    // 热区之后——失败页上的左右热区照常翻页，翻走 / 翻回也会触发重取
    // （__mangaApplyTranslate）。
    if (_retryFailedPageAt(x, y)) return;
    // 第二击落在同一块空白上 → 取消第一击挂起的 onTapEmpty（否则悬浮栏会跟着
    // 闪一次），在该点缩放；等比在「贴合」与 2× 之间切换。
    if (IS_WEBTOON && !${preferences.webtoonDoubleTapZoom}) {
      b.callHandler('onTapEmpty'); return;
    }
    if (_consumeDoubleTap(x, y)) {
      _cancelPendingEmptyTap();
      _doubleTapZoom(x,y);
      return;
    }
    // 裸图 / 尚未完成 OCR 的区域不打开大图，继续留在阅读器。空白点是 no-op，
    // 只回传给 Dart 收回焦点 / 切换悬浮栏；OCR 只能在阅读器外触发，这里不再带
    // 落页 payload。延后 DBL_MS 发出，给第二击留出取消的窗口。
    _deferEmptyTap();
  }
  function _end(x, y){
    // 无配对 pointerdown（has=false）：合成事件或捕获丢失，没有位移可判 swipe →
    // 只能是 tap，直接走 tap 路径（不丢选词）。
    if (!has) { _swipeRelease(false); _onTap(x, y); return; }
    has = false;
    var dx = x - sx, dy = y - sy, el = Date.now() - st;
    var ax = Math.abs(dx), ay = Math.abs(dy);
    // 松手瞬时速度（最后一段 pointermove，px/s）：跟手之后手势的意图看的是
    // 「最后往哪甩」——拖过阈值再往回甩是取消，与 Mihon 的 ViewPager 同口径。
    var rvx = swipe ? swipe.vx : 0;
    // 放大态（ZOOM>1）的拖动先被 _panBy 消费为平移（放大后必须能看页面各处）；
    // 只有平移**贴边后没吃掉**的横向余量才算翻页 swipe——与 Mihon、与滚轮的
    // 「能平移就平移，贴边才翻页」（BUG-1760）同一口径。未放大时 _panBy 不动
    // PAN_X，余量 = 整段位移，判据与从前逐字一致。
    //
    // 此前这里是硬性的 `ZOOM <= 1`：捏合缩回「看起来贴合」时常停在 101%~105%，
    // 画面与贴合无从分辨，可左右滑永远只是挪几像素的平移、一页也翻不动，
    // 只剩点边缘能翻（用户 2026-10-02「划不动」）。
    var ux = dx - (PAN_X - spx), aux = Math.abs(ux);
    var vel = aux / Math.max(1, el) * 1000;
    var flingBack = rvx * ux < 0 && Math.abs(rvx) >= 900;
    // 跟手态：拖过 FOLLOW_COMMIT 个视口宽，或往翻页方向甩得够快（px/ms）才提交，
    // 否则回弹。没跟手（动画关 / 淡入淡出 / 设置关）沿用固定像素阈值。
    var followed = !!(swipe && swipe.follow && swipe.base !== null);
    var commit;
    if (followed) {
      var flingVel = Math.max(vel, (ux > 0 ? rvx : -rvx)) / 1000;
      commit = aux > FOLLOW_COMMIT * (window.innerWidth || 1) ||
          (aux >= 24 && flingVel > FOLLOW_FLING);
    } else {
      commit = aux >= 72 || (aux >= 36 && vel >= 900);
    }
    if (!IS_WEBTOON && ax > ay && (ux > 0) === (dx > 0) && !flingBack &&
        commit && !_zoomedEdgeTurnBlocked()) {
      var settle = _swipeRelease(true);
      var b = _bridge();
      if (!b) { if (settle) settle(); return; }
      // swipe 跟手：拖动内容向左（dx<0）露出的是 strip **右边**那一跨页。右边是哪
      // 一页取决于几何顺序——LTR 正序时右边是 next，RTL 倒序时右边是 prev（见文档
      // 生成处的 spreadOrder）。所以必须按 IS_RTL 镜像，RTL 下「向右滑 = 下一页」，
      // 与 Mihon 等 RTL 阅读器一致。
      //
      // 旧注释声称「dir 由 Dart 端依据阅读方向 clamp」——Dart 侧（_onMangaTurn）只有
      // `next ? +1 : -1` 和边界钳位，从来没有方向 clamp，按那句推理必然推错。
      var swipeRight = dx > 0;
      var answer = b.callHandler('onMangaTurn',
          (swipeRight === IS_RTL) ? 'next' : 'prev');
      // Dart 的处理器在翻页请求处理完（含换章）才答复。
      if (settle) {
        if (answer && answer.then) answer.then(settle, settle); else settle();
      }
    } else {
      _swipeRelease(false);
      if (ax < 20 && ay < 20 && el < 500) _onTap(x, y);
    }
  }
  // 触屏长按页图 → Dart 弹全局图片动作面板（保存 / 分享，image_actions_sheet.dart），
  // 作用于**被按住的那一页**（条漫 / 双页模式下命中的那页，不是当前跨页）。
  // 漫画页的触屏手势里长按原本是空的：单击 = OCR 查词 / 热区翻页 / 空白切栏，
  // 双击 = 缩放，拖动 = 翻页 / 平移 / 条漫滚动，双指 = 捏合；按住超过 500ms 的
  // 松手本来就不算单击（_end 的 el < 500），所以长按不抢任何已有功能。
  // 鼠标走右键菜单（onMangaContextMenu），这里只认触摸主触点。
  // 取消判据：移动超过 LONG_PRESS_SLOP、第二指落下（捏合）、松手 / 被系统夺走。
  // 触发后本次按压作废：跟手回弹、挂起的空白单击与双击武装清掉，松手不再走
  // 单击 / swipe 路径。
  var LONG_PRESS_MS = 500, LONG_PRESS_SLOP = 10;
  var longPress = null, longPressFired = null;
  function _mangaPageIndexAt(x, y){
    var stack = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
    for (var i = 0; i < stack.length; i++) {
      var el = stack[i];
      var page = el.closest ? el.closest('.manga-page') : null;
      // 翻页动画的克隆层摘掉了 data-page，不认；加载失败页没有图可存。
      if (!page || !page.hasAttribute('data-page')) continue;
      if (page.getAttribute('data-load-failed') === '1') return null;
      var index = Number(page.getAttribute('data-page'));
      return isFinite(index) && index >= 0 ? index : null;
    }
    return null;
  }
  function _cancelLongPress(){
    if (longPress) { clearTimeout(longPress.timer); longPress = null; }
  }
  function _armLongPress(e){
    _cancelLongPress();
    longPressFired = null;
    if (e.pointerType !== 'touch' || !e.isPrimary) return;
    var lp = {id: e.pointerId, x: e.clientX, y: e.clientY, timer: null};
    lp.timer = setTimeout(function(){
      if (longPress === lp) _fireLongPress();
    }, LONG_PRESS_MS);
    longPress = lp;
  }
  function _moveLongPress(e){
    if (!longPress || longPress.id !== e.pointerId) return;
    var dx = e.clientX - longPress.x, dy = e.clientY - longPress.y;
    if (dx * dx + dy * dy > LONG_PRESS_SLOP * LONG_PRESS_SLOP) _cancelLongPress();
  }
  function _fireLongPress(){
    var lp = longPress;
    longPress = null;
    if (!lp || pinch || pinchGuard) return;
    var page = _mangaPageIndexAt(lp.x, lp.y);
    if (page === null) return;
    longPressFired = lp.id;
    has = false;
    _swipeRelease(false);
    panDrag = null;
    _cancelPendingEmptyTap();
    dblArmed = false;
    var b = _bridge();
    if (b) b.callHandler('onMangaPageLongPress', JSON.stringify({page: page}));
  }
  // 松手时：本指已触发长按就吞掉这次松手（返回 true）。
  function _consumeLongPressRelease(id){
    _cancelLongPress();
    if (longPressFired !== null && longPressFired === id) {
      longPressFired = null;
      return true;
    }
    return false;
  }
  document.addEventListener('pointerdown', function(e){
    if (e.pointerType === 'touch') {
      // 触点表只靠「松手 / 取消」事件删条目，而这两个事件不保证到得了 document：
      // 手指按在随后被移出 DOM 的节点上（__mangaReplaceOcr 换掉 OCR 层、覆盖翻页
      // 拆掉克隆层），松手事件派给已脱离文档的节点，传播路径里没有 document。
      // 漏删的那根「幽灵指」会永久留在表里：下一次单指拖动被当成与它的捏合（大
      // 滑动 = 指距暴涨 = 放大到上限），pinchGuard 又要等表清空才解除，之后一切点击
      // 与滑动都被吞（卡死）。浏览器自己的 isPrimary 是权威信号：主触点 = 此刻屏上
      // 没有任何其它触摸指针，所以这是新一轮手势，表里剩下的全是幽灵，清空重来。
      if (e.isPrimary) {
        touchPts = {};
        pinch = null;
        pinchGuard = false;
      }
      touchPts[e.pointerId] = {x: e.clientX, y: e.clientY};
      var g = _pinchGeom();
      if (g && g.dist > 0) {
        // 第二指落下：进入捏合，取消已经开始的单指 swipe 计时与拖动。
        // t0 / cx0 / cy0 / span：双指点按判定（_isTwoFingerTap）用的起点与指距变化。
        pinch = {dist: g.dist, zoom: ZOOM, cx: g.cx, cy: g.cy,
          t0: Date.now(), cx0: g.cx, cy0: g.cy, dist0: g.dist, span: 0};
        pinchGuard = true;
        has = false;
        _cancelLongPress();
        // 跟到一半的页面立即复位（不播回弹），捏合从静止的当前跨页开始。
        _swipeRelease(false, true);
        panDrag = null;
        _stopFlick();
        return;
      }
    }
    if (e.button === 2) {
      rightDrag = {
        startX:e.clientX, startY:e.clientY,
        lastX:e.clientX, lastY:e.clientY, moved:false
      };
      e.preventDefault();
      return;
    }
    if (e.button !== 0) return;
    // 触屏惯例：滑动中按下即刹车（含纵向分页的平滑翻页滚动）。
    _stopFlick();
    _stopScrollAnim();
    panDrag = {
      id: e.pointerId, lastX: e.clientX, lastY: e.clientY,
      lastT: Date.now(), vy: 0, touch: e.pointerType === 'touch',
      samples: [{t: e.timeStamp, y: e.clientY}]
    };
    _armDoubleTapOnDown(e.clientX, e.clientY);
    _armLongPress(e);
    _start(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointermove', function(e){
    if (e.pointerType !== 'touch') return;
    _moveLongPress(e);
    if (!touchPts[e.pointerId]) return;
    touchPts[e.pointerId] = {x: e.clientX, y: e.clientY};
    if (!pinch) return;
    var g = _pinchGeom();
    if (!g || g.dist <= 0) return;
    e.preventDefault();
    pinch.cx = g.cx;
    pinch.cy = g.cy;
    if (pinch.dist0) {
      pinch.span = Math.max(pinch.span, Math.abs(g.dist - pinch.dist0));
    }
    _zoomAbout(
      pinch.zoom * Math.pow(g.dist / pinch.dist, ZOOM_SENS),
      g.cx,
      g.cy
    );
  }, {passive: false});
  document.addEventListener('pointerup', function(e){
    var drag = (panDrag && panDrag.id === e.pointerId) ? panDrag : null;
    if (drag) panDrag = null;
    if (_consumeLongPressRelease(e.pointerId)) {
      if (e.pointerType === 'touch') delete touchPts[e.pointerId];
      return;
    }
    if (e.pointerType === 'touch') {
      delete touchPts[e.pointerId];
      if (pinch) {
        // 不足两指即结束捏合并吸附（通常是两指中先抬起的那一指，另一指可能
        // 还在屏上）。剩下那一指仍不恢复 swipe：pinchGuard 等全部手指抬起，
        // 避免捏合尾巴被判成翻页。
        if (Object.keys(touchPts).length < 2) {
          var lastPinch = pinch;
          pinch = null;
          if (_isTwoFingerTap(lastPinch)) {
            // 双指点按 = 快速缩回。两指搭上时的几像素抖动可能已经让倍率动了
            // 一丝，先退回起点倍率（不回报），再从那里缩回目标。
            if (ZOOM !== lastPinch.zoom) {
              _zoomAbout(lastPinch.zoom, lastPinch.cx, lastPinch.cy, true);
            }
            _quickZoom();
          } else {
            _snapPinchZoom(lastPinch.cx, lastPinch.cy, lastPinch.zoom);
          }
        } else {
          // 三指及以上抬起一指：参与几何的那一对换了人，按新的一对重定基准，
          // 否则新指距 / 旧基准的比值会让倍率瞬间跳变。起点倍率保留，吸附判据
          // 仍以整次捏合开始时为准。
          var rg = _pinchGeom();
          if (rg && rg.dist > 0) {
            pinch.dist = rg.dist * Math.pow(pinch.zoom / ZOOM, 1 / ZOOM_SENS);
            pinch.cx = rg.cx;
            pinch.cy = rg.cy;
          }
        }
        return;
      }
      if (pinchGuard) {
        if (Object.keys(touchPts).length === 0) pinchGuard = false;
        return;
      }
      if (drag && drag.touch) _startFlick(_releaseVelocity(drag, e.timeStamp));
    }
    if (e.button === 2) {
      var drag = rightDrag;
      rightDrag = null;
      e.preventDefault();
      if (drag && !drag.moved) {
        var b = _bridge();
        if (b) b.callHandler('onMangaContextMenu', JSON.stringify({
          x:e.clientX, y:e.clientY
        }));
      }
      return;
    }
    if (e.button !== 0) return;
    _end(e.clientX, e.clientY);
  }, {passive: false});
  // 指针被系统夺走（触屏手势接管 / 窗口失焦 / 捕获丢失）时收不到松手事件，
  // 橡皮筋会挂在屏幕上直到下次拖拽。清掉起点与矩形，但保留模式（用户重画）。
  // 注意：本注释随文档注入 WebView，不能出现松手事件的字面名——
  // manga_overlay_html_test 的 C1 不变式按该字面量计数，恰好允许一个。
  document.addEventListener('pointercancel', function(e){
    _consumeLongPressRelease(e.pointerId);
    if (panDrag && panDrag.id === e.pointerId) {
      panDrag = null;
      // 系统夺走指针：跟到一半的页面不能挂在半路，回弹到当前跨页。
      has = false;
      _swipeRelease(false);
    }
    if (e.pointerType === 'touch') {
      delete touchPts[e.pointerId];
      if (Object.keys(touchPts).length < 2) pinch = null;
      if (Object.keys(touchPts).length === 0) pinchGuard = false;
    }
  }, {passive: true});
  document.addEventListener('contextmenu', function(e){
    e.preventDefault();
  }, {passive:false});

  // Ctrl/Command + wheel：以指针为锚、**按 ZOOM_STEP 网格定量**的缩放。
  //
  // 历史两版都不对：最早「e.deltaY 只当符号 + 恒 ±0.1 加法」，后改成按 delta 幅值的
  // 乘法 exp(steps*0.2*SENS)。乘法版的毛病是**每格缩多少取决于本机 deltaY 的绝对值**：
  // 注释假设一格 = 100，但 WebView2 在高 DPI 上根本不是 100（BUG-1065 实测 150% 缩放
  // 机器一格只有 67），于是用户实测「一格约 112%」——既不是设计值 22%，也无法预期。
  // 而右键菜单/设置滑块用的是 ±10 个百分点，同一个功能两套口径。
  //
  // 现在统一到菜单口径：一格滚轮 = 恰好一个 ZOOM_STEP 网格步，且目标值**对齐到网格**，
  // 所以序列恒为 100→110→120…，而不是 100→112→125…；捏合留下的非整值也会被拉回网格。
  // ZOOM_SENS 仍然管用（设置项承诺它覆盖滚轮），改为缩放**步长本身**而非指数底数。
  var ZOOM_STEP = Math.max(1, Math.round(10 * ZOOM_SENS));
  // 两种输入、两种语义，判据只看单个事件的幅值（BUG-2758）：
  // - 鼠标一格：deltaY 恒 >=40（57/67/100/120），一格 = 恰好一个网格步。
  // - 精密手势：触控板捏合在 Windows fork 与 Chromium 原生窗口里都合成为
  //   Ctrl+滚轮，deltaY = -100·ln(本次缩放比)，每个事件只有几个像素、连续到达；
  //   Ctrl+两指滚动同样是碎 delta。它表达的是「手指张开了多少」，必须连续跟手，
  //   与触屏捏合同口径（比例^ZOOM_SENS）。此前把它攒够 40 才走一格网格步，
  //   要张开约 1.5 倍才缩放 10%，而且 fork 根本没把捏合转进来。
  var PRECISE_ZOOM_DELTA = 40;
  function _wheelDeltaPx(e){
    var dy = e.deltaY || 0;
    if (e.deltaMode === 1) dy *= 16;
    else if (e.deltaMode === 2) dy *= window.innerHeight;
    return dy;
  }
  document.addEventListener('wheel', function(e){
    if (!(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    var dy = _wheelDeltaPx(e);
    if (dy === 0) return;
    if (Math.abs(dy) < PRECISE_ZOOM_DELTA) {
      _zoomAbout(ZOOM * Math.exp(-dy / 100 * ZOOM_SENS), e.clientX, e.clientY);
      return;
    }
    // 先把 ZOOM 化成保留 1 位小数的百分比再上下取整：ZOOM 是浮点，1.2 常存成
    // 1.2000000000000002，直接 Math.ceil(120.00000000000003 / 10) 会得 13 而不是 12，
    // 缩小一步就变成原地不动（_zoomAbout 的 0.0005 死区把它吃掉）。
    var cur = Math.round(ZOOM * 1000) / 10;
    var next = dy < 0
      ? (Math.floor(cur / ZOOM_STEP) + 1) * ZOOM_STEP
      : (Math.ceil(cur / ZOOM_STEP) - 1) * ZOOM_STEP;
    _zoomAbout(next / 100, e.clientX, e.clientY);
  }, {passive:false});

  // ── 桌面鼠标滚轮（仅 spread，BUG-051 / BUG-1760）──
  // 一条语义：**滚轮滚的是内容；没有内容可滚才翻页。**
  // - ZOOM<=1：整页放得下，页内无处可滚，滚轮是翻页（桌面端 swipe 的等价物，
  //   PC 漫画阅读器惯例）。
  // - ZOOM>1：滚轮是页内平移（用户报「放大阅读时经常误翻」）。走 _panBy（含钳制），
  //   贴边后继续滚才落入下面的翻页累计——阈值 40 保证不是惯性一冲就跨页；贴边
  //   翻页时下一页从顶部、上一页从底部接续，滚读连续。
  // webtoon 保留 WebView 自身的原生竖向滚动，故不在此接线（否则会抢走正常滚动）。
  // 一次滚轮事件流（尤其触控板惯性）可能连发多个 wheel，用 _wheelLock 在 110ms 内
  // 合并为一次翻页，避免一格滚动翻一叠页。
  if (!IS_WEBTOON) {
    var _wheelLock = false;
    var _wheelAccum = 0;
    var _wheelDir = 0;
    // BUG-2834：放大平移的滚轮缓动。每帧都经 _panBy 推进（不另写 PAN 增量），
    // 拖动 / 方向键 / 缩放 / 贴边翻页改了 PAN 就让位；推不动（视口变了）就停。
    var _wheelPan = null; // {tx, ty, x, y, dir, raf}
    function _wheelPanLive(dir){
      var w = _wheelPan;
      return !!w && w.dir === dir && PAN_X === w.x && PAN_Y === w.y;
    }
    function _wheelPanFrame(){
      var w = _wheelPan;
      if (!w) return;
      w.raf = 0;
      if (ZOOM <= 1 || PAN_X !== w.x || PAN_Y !== w.y) { _wheelPan = null; return; }
      var rx = w.tx - PAN_X, ry = w.ty - PAN_Y;
      var last = Math.abs(rx) <= 0.5 && Math.abs(ry) <= 0.5;
      _panBy(last ? rx : rx * 0.18, last ? ry : ry * 0.18);
      var stuck = PAN_X === w.x && PAN_Y === w.y;
      w.x = PAN_X; w.y = PAN_Y;
      if (last || stuck) { _wheelPan = null; return; }
      w.raf = requestAnimationFrame(_wheelPanFrame);
    }
    // 调用时 PAN 已是 _panBy 钳好的落点；(vx, vy) 是视觉位置。
    function _wheelPanEase(vx, vy, dir){
      if (typeof requestAnimationFrame !== 'function') return;
      var tx = PAN_X, ty = PAN_Y;
      PAN_X = vx; PAN_Y = vy;
      _applyCanvas();
      var w = _wheelPan;
      if (!_wheelPanLive(dir)) {
        if (w && w.raf && typeof cancelAnimationFrame === 'function') {
          cancelAnimationFrame(w.raf);
        }
        w = _wheelPan = {x: vx, y: vy, dir: dir, raf: 0};
      }
      w.tx = tx; w.ty = ty;
      if (!w.raf) w.raf = requestAnimationFrame(_wheelPanFrame);
    }
    document.addEventListener('wheel', function(e){
      if (e.ctrlKey || e.metaKey) return;
      e.preventDefault();
      var wdx = e.deltaX || 0;
      var wdy = e.deltaY || 0;
      if (e.deltaMode === 1) { wdx *= 16; wdy *= 16; }
      else if (e.deltaMode === 2) {
        wdx *= window.innerWidth;
        wdy *= window.innerHeight;
      }
      var d = wdy || wdx;
      if (d === 0) return;
      if (ZOOM > 1) {
        // 平移优先：动得了就消费掉本事件；动不了（已贴边/该轴无余量）落入翻页累计。
        // BUG-2834：落点照旧由 _panBy 一步算出（钳制只住在它里面），随即在同一任务
        // 内撤回、交给 _wheelPanEase 逐帧推过去——一格不再瞬跳。连拨同向从尚未到达
        // 的落点起算，不吃距离。
        var wdir = d > 0 ? 1 : -1;
        var live = _wheelPanLive(wdir);
        var vx = PAN_X, vy = PAN_Y;
        if (live) { PAN_X = _wheelPan.tx; PAN_Y = _wheelPan.ty; }
        var px = PAN_X, py = PAN_Y;
        _panBy(-wdx, -wdy);
        if (PAN_X !== px || PAN_Y !== py) {
          _wheelPanEase(vx, vy, wdir);
          _wheelAccum = 0;
          _wheelDir = 0;
          return;
        }
        PAN_X = vx; PAN_Y = vy;
        _applyCanvas();
        // 还在飞向边缘：等它落定，下一格才进翻页累计。
        if (live) return;
      }
      var dir = d > 0 ? 1 : -1;
      // 反向立刻清账：来回滚不该被上一方向的余量吃掉。
      if (dir !== _wheelDir) { _wheelAccum = 0; _wheelDir = dir; }
      if (_wheelLock) return;
      // 按累计位移而非「一个事件 = 一页」触发：鼠标一格（deltaY≈100）立刻翻一页，
      // 触控板的碎 delta 攒够一格才翻。旧实现是「首个事件就翻 + 320ms 全禁」，
      // 于是滚轮翻页上限约 3 页/秒，且触控板轻扫也会误翻——用户说的「翻页逻辑难受」。
      _wheelAccum += Math.abs(d);
      if (_wheelAccum < 40) return;
      _wheelAccum = 0;
      var b = _bridge();
      if (!b) return;
      _wheelLock = true;
      setTimeout(function(){ _wheelLock = false; }, 110);
      if (ZOOM > 1) {
        // 贴边翻页的续读体验：顺着滚动方向接上新页的开头/结尾。
        PAN_Y = dir > 0 ? 0 : window.innerHeight * (1 - ZOOM);
        _clampPan();
        _applyCanvas();
      }
      // 向下/向右滚 = 页序前进（next），向上/向左 = 后退（prev）；Dart 端按阅读
      // 方向已统一 clamp（与 swipe 同口径）。
      b.callHandler('onMangaTurn', dir > 0 ? 'next' : 'prev');
    }, {passive: false});
  }
  // ── 抑制原生拖拽残影（BUG-051「秃瓢」）──
  // 即使 user-select/user-drag 已禁，部分 WebView 仍会在拖动时发 dragstart 拉出
  // 残影；显式 preventDefault 兜底，让鼠标拖动只走 swipe 手势路径。
  document.addEventListener('dragstart', function(e){
    e.preventDefault();
  }, {passive: false});

  // ── webtoon 滚动报告（节流）──
  var flashTimer = null;
  function _flashPageChange(){
    if (!${preferences.flashOnPageChange}) return;
    var flash=document.getElementById('manga-flash');
    if(!flash) return;
    flash.style.opacity='1';
    if(flashTimer) clearTimeout(flashTimer);
    flashTimer=setTimeout(function(){flash.style.opacity='0';flashTimer=null;},80);
  }
  var lastReaderScroll = window.scrollY;
  var readerScrollDistance = 0;
  // 只有用户自己滚才收起工具栏：恢复位置、换窗、跳页、自动滚动都是程序滚动，
  // 不能每次开书 / 改设置就把顶栏收掉。滚轮、触摸、按键之后的一小段时间内的
  // scroll 事件（含惯性）才算用户滚动。
  var lastReaderUserInput = 0;
  function _noteReaderUserInput(){ lastReaderUserInput = Date.now(); }
  ['wheel','touchmove','keydown','pointerdown'].forEach(function(type){
    window.addEventListener(type,_noteReaderUserInput,{passive:true,capture:true});
  });
  window.addEventListener('scroll',function(){
    var delta = window.scrollY-lastReaderScroll;
    lastReaderScroll=window.scrollY;
    if(Date.now()-lastReaderUserInput>1200){ readerScrollDistance=0; return; }
    if(Math.sign(delta)!==Math.sign(readerScrollDistance)) readerScrollDistance=0;
    readerScrollDistance+=delta;
    if(Math.abs(readerScrollDistance)>=${preferences.readerHideThreshold.clamp(0, 100)} && delta!==0){
      var b=_bridge();if(b)b.callHandler('onMangaReaderHide',delta>0);
      readerScrollDistance=0;
    }
  },{passive:true});
  // Visibility is reported as original data-page indices, not spread indices.
  window.__mangaVisiblePages = function(){
    return Array.prototype.filter.call(document.querySelectorAll('.manga-page'),function(page){
      var r=page.getBoundingClientRect();
      return r.bottom>0 && r.top<window.innerHeight && r.right>0 && r.left<window.innerWidth;
    }).map(function(page){return Number(page.dataset.page);});
  };
  var autoScrollRunning=${preferences.autoScroll};
  var autoScrollPaused=false,autoFrame=null,lastAutoTime=null,autoPageTime=0;
  window.__mangaPauseAutoScroll=function(paused){autoScrollPaused=!!paused;lastAutoTime=null;};
  function _autoScrollFrame(time){
    autoFrame=null;
    if(!autoScrollRunning) return;
    if(!document.hidden && !autoScrollPaused && !has && !pinch && !rightDrag){
      if(lastAutoTime!==null){
        var dt=Math.min(100,time-lastAutoTime);
        if(IS_WEBTOON) window.scrollBy(0,${preferences.autoScrollSpeed.clamp(5, 200)}*dt/1000);
        else {
          autoPageTime+=dt;
          if(autoPageTime>=window.innerHeight/${preferences.autoScrollSpeed.clamp(5, 200)}*1000){
            autoPageTime=0;var b=_bridge();if(b)b.callHandler('onMangaTurn','next');
          }
        }
      }
      lastAutoTime=time;
    } else lastAutoTime=null;
    autoFrame=requestAnimationFrame(_autoScrollFrame);
  }
  if(autoScrollRunning) autoFrame=requestAnimationFrame(_autoScrollFrame);
  window.addEventListener('pagehide',function(){autoScrollRunning=false;if(autoFrame)cancelAnimationFrame(autoFrame);});
  // HIGH-1：报**页内** fraction（视口顶部所在页内的归一化偏移 0..1），与
  // __mangaScrollToSpread 的口径统一——绝不报文档全局 fraction（那会被当页内
  // offset 用，恢复/定位错一整页）。topPage = 视口顶部所在页的 data-spread，
  // fraction 与 topPage 同源（同一页）。
  if (IS_WEBTOON) {
    var _scrollTimer = null;
    var LAST_VISIBLE_PAGES = [];
    window.addEventListener('scroll', function(){
      if (_scrollTimer) return;
      _scrollTimer = setTimeout(function(){
        _scrollTimer = null;
        // resize 与重投影之间的窗口期：此刻几何是新视口的、scrollY 还是旧投影，
        // 视觉上停在错误的页；把它上报/记入真值会让 _reanchor 反过来钉死漂移。
        if (_resizePending) return;
        // 纵向分页平滑翻页途中：半路的 topPage 不是语义位置，落定后补报。
        if (_scrollAnimRaf) return;
        var b = _bridge();
        if (!b) return;
        // 换回布局坐标：scrollY 含 scale(ZOOM)，而 offsetTop/offsetHeight 不含。
        var y = window.scrollY / ZOOM;
        // 视口顶部所在页（getBoundingClientRect().bottom>1 的第一页）。
        var topPage = 0;
        var fraction = 0;
        var pages = document.querySelectorAll('.manga-page');
        for (var i = 0; i < pages.length; i++) {
          var r = pages[i].getBoundingClientRect();
          if (r.bottom > 1) {
            topPage = parseInt(pages[i].getAttribute('data-spread'), 10) || 0;
            // 页内归一化：(scrollY - page.offsetTop) / page.offsetHeight。
            var oh = pages[i].offsetHeight;
            if (oh > 0) {
              fraction = Math.min(1, Math.max(0, (y - pages[i].offsetTop) / oh));
            }
            break;
          }
        }
        // 语义真值跟随用户滚动：resize 重投影（_reanchor）要回到「现在看的位置」，
        // 不是文档加载那一刻的恢复位置。
        if(CURRENT!==topPage) _flashPageChange();
        CURRENT = topPage;
        _updateAutomaticBackground();
        RESTORE_FRACTION = fraction;
        var visiblePages = window.__mangaVisiblePages();
        // 长条：失败页**新进入**视口时重取一次（一直停在视口里不反复打源）。
        _retryFailedPagesWhere(function(page){
          var index = Number(page.getAttribute('data-page'));
          return visiblePages.indexOf(index) >= 0 &&
              LAST_VISIBLE_PAGES.indexOf(index) < 0;
        });
        LAST_VISIBLE_PAGES = visiblePages;
        b.callHandler('onMangaScroll', JSON.stringify({ fraction: fraction, topPage: topPage, visiblePages: visiblePages }));
      }, 120);
    }, {passive: true});
  }
})();
''';
}

/// 百分比格式化：去掉无意义尾零（10% 而非 10.0%），保留必要精度。
String _pct(double value) => '${_num(value)}%';

/// 数字格式化：去掉无意义尾零（1.6 而非 1.6000；10 而非 10.0000）。
String _num(double value) {
  final String s = value.toStringAsFixed(4);
  if (!s.contains('.')) {
    return s;
  }
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

String _escapeHtml(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String _escapeAttr(String input) {
  return _escapeHtml(input).replaceAll('"', '&quot;');
}
