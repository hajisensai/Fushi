import 'dart:math' as math;
import 'dart:ui';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

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
    final Rect r = block.rectangle;
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
    final String writingMode =
        block.isVertical ? 'writing-mode:vertical-rl;' : '';
    final String orientation = block.isVertical ? 'vertical' : 'horizontal';
    final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
    final bool hasRegions = regions.isNotEmpty;
    final String inner = hasRegions
        ? _mangaCharacterRegionsHtml(
            block: block,
            regions: regions,
          )
        : block.lines.map(_escapeHtml).join('<br>');
    buffer.write('<p class="ocr-box" '
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
        '">$inner</p>');
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
  for (int candidateIndex = 0;
      candidateIndex < blocks.length;
      candidateIndex++) {
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
        (int a, int b) => _compareMangaBlockReadingOrder(blocks[a], blocks[b]));
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

double _mangaAxisOverlap(Rect a, Rect b, {required bool vertical}) {
  if (vertical) {
    return math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  }
  return math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));
}

double _mangaAxisLength(Rect rect, {required bool vertical}) =>
    vertical ? rect.height : rect.width;

double _mangaCrossThickness(Rect rect, {required bool vertical}) =>
    vertical ? rect.width : rect.height;

double _mangaCrossGap(Rect a, Rect b, {required bool vertical}) {
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
  final double candidateThickness =
      _mangaCrossThickness(candidate.rectangle, vertical: vertical);
  final double baseThickness =
      _mangaCrossThickness(base.rectangle, vertical: vertical);
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
  final double candidateLength =
      _mangaAxisLength(candidate.rectangle, vertical: vertical);
  final double baseLength =
      _mangaAxisLength(base.rectangle, vertical: vertical);
  final double overlap = _mangaAxisOverlap(candidate.rectangle, base.rectangle,
      vertical: vertical);
  if (candidateLength <= 0 ||
      baseLength <= 0 ||
      overlap / math.min(candidateLength, baseLength) < 0.45) {
    return null;
  }
  final double gap =
      _mangaCrossGap(candidate.rectangle, base.rectangle, vertical: vertical);
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
  final double overlap =
      _mangaAxisOverlap(a.rectangle, b.rectangle, vertical: vertical);
  if (overlap / math.min(aLength, bLength) < 0.30) {
    return false;
  }
  final double gap =
      _mangaCrossGap(a.rectangle, b.rectangle, vertical: vertical);
  final double maximumGap =
      math.max(8.0, math.max(a.fontSize, b.fontSize) * 0.90);
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

bool _mangaEndsSentence(String text) => RegExp(
      r'[。！？.!?‼⁉][」』）)\]】〉》〕｝}］”’]*$',
    ).hasMatch(text);

/// Returns character-level hit regions for every OCR producer.
///
/// Lens already supplies line-derived regions. Local ONNX and legacy mokuro
/// blocks do not, so they are subdivided here using `lines_coords` when
/// available and the block rectangle otherwise. This mirrors Niratan's native
/// reader: hit testing is based on explicit character geometry instead of
/// asking browser typography to approximate where transparent text landed.
List<MangaOcrTextRegion> mangaEffectiveTextRegions(MokuroBlock block) {
  final List<MangaOcrTextRegion>? supplied = block.regions;
  if (supplied != null && supplied.isNotEmpty) {
    return supplied;
  }
  if (block.lines.isEmpty || block.rectangle.isEmpty) {
    return const <MangaOcrTextRegion>[];
  }
  final List<Rect> lineRects = _mangaLineRects(block);
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
      final Rect lineRect = lineRects[lineIndex];
      for (int index = 0; index < characters.length; index++) {
        final Rect characterRect = block.isVertical
            ? Rect.fromLTWH(
                lineRect.left,
                lineRect.top + index * lineRect.height / characters.length,
                lineRect.width,
                lineRect.height / characters.length,
              )
            : Rect.fromLTWH(
                lineRect.left + index * lineRect.width / characters.length,
                lineRect.top,
                lineRect.width / characters.length,
                lineRect.height,
              );
        result.add(MangaOcrTextRegion(
          rectangle: characterRect,
          utf16Start: characters[index].start,
          utf16End: characters[index].end,
        ));
      }
    }
    utf16Base += line.length;
  }
  return result;
}

List<Rect> _mangaLineRects(MokuroBlock block) {
  final List<List<List<double>>>? coordinates = block.linesCoords;
  if (coordinates != null && coordinates.length == block.lines.length) {
    final List<Rect> parsed = <Rect>[];
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
      parsed.add(Rect.fromLTRB(left, top, right, bottom));
    }
    if (parsed.length == block.lines.length) {
      return parsed;
    }
  }

  final Rect rect = block.rectangle;
  final int count = block.lines.length;
  if (block.isVertical) {
    final double width = rect.width / count;
    return <Rect>[
      for (int index = 0; index < count; index++)
        Rect.fromLTWH(
          rect.right - (index + 1) * width,
          rect.top,
          width,
          rect.height,
        ),
    ];
  }
  final double height = rect.height / count;
  return <Rect>[
    for (int index = 0; index < count; index++)
      Rect.fromLTWH(
        rect.left,
        rect.top + index * height,
        rect.width,
        height,
      ),
  ];
}

String _mangaCharacterRegionsHtml({
  required MokuroBlock block,
  required List<MangaOcrTextRegion> regions,
}) {
  final String sentence = block.lines.join();
  final Rect parent = block.rectangle;
  final double parentWidth = parent.width <= 0 ? 1 : parent.width;
  final double parentHeight = parent.height <= 0 ? 1 : parent.height;
  final StringBuffer buffer = StringBuffer();
  for (final MangaOcrTextRegion region in regions) {
    if (region.utf16Start < 0 ||
        region.utf16End <= region.utf16Start ||
        region.utf16End > sentence.length) {
      continue;
    }
    final Rect r = region.rectangle;
    final double leftPct = ((r.left - parent.left) / parentWidth) * 100;
    final double topPct = ((r.top - parent.top) / parentHeight) * 100;
    final double widthPct = (r.width / parentWidth) * 100;
    final double heightPct = (r.height / parentHeight) * 100;
    final String text = sentence.substring(region.utf16Start, region.utf16End);
    buffer.write('<span class="ocr-char" '
        'data-utf16-start="${region.utf16Start}" '
        'data-ocr-orientation="${block.isVertical ? 'vertical' : 'horizontal'}" '
        'style="left:${_pct(leftPct)};'
        'top:${_pct(topPct)};'
        'width:${_pct(widthPct)};'
        'height:${_pct(heightPct)};">'
        '${_escapeHtml(text)}</span>');
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
String mangaPageDivHtml(MokuroImage page, String imgSrc,
    {int spreadIndex = 0,
    int pagesInSpread = 1,
    int pageIndex = 0,
    bool isWebtoon = false,
    bool eager = false,
    bool ocrLoaded = true}) {
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
  final String sizingCss = isWebtoon
      ? ''
      : 'width:min(${_num(slotVw)}vw,${_num(100 * w / h)}vh);'
          'height:min(100vh,${_num(slotVw * h / w)}vw);';
  final String loading = eager && !isWebtoon ? 'eager' : 'lazy';
  final String fetchPriority = eager && !isWebtoon ? 'high' : 'auto';
  return '<div class="manga-page" data-spread="$spreadIndex" '
      'data-spread-pages="$pagesInSpread" '
      'data-page="$pageIndex" data-pw="${_num(w)}" data-ph="${_num(h)}" '
      'data-ocr-loaded="${ocrLoaded ? '1' : '0'}" '
      'style="position:relative;container-type:inline-size;'
      '$sizingCss'
      'aspect-ratio:${_num(w)}/${_num(h)};">'
      '<img src="${_escapeAttr(imgSrc)}" loading="$loading" '
      'fetchpriority="$fetchPriority" decoding="async" '
      'style="pointer-events:none;">'
      '${mangaOcrBoxesHtml(page)}'
      '</div>';
}

/// 自包含窗口文档：spread → flex-row（RTL 经 direction:rtl 排序）+ 视口裁剪 +
/// translateX 只显示当前跨页；webtoon → 竖向堆叠 + 滚动。内联选词 JS + 一个
/// 手势机（swipe→翻页 / scroll→滚动报告 / tap→选词或放大）。
///
/// OCR 框有两条明确的查词入口（单击 / Shift 悬停），都走同一个字级选词函数
/// `_selectOcrChar()`：命中层先定位到字符节点，再调
/// `fushiSelection.selectFromPosition(node, 0, 40, x, y)`。第三个参数是
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
  int documentGeneration = 0,
  Set<int>? ocrPageIndices,
  int zoomMinPercent = kMangaZoomMinPercent,
  int zoomMaxPercent = kMangaZoomMaxPercent,
  int zoomSensitivity = kMangaZoomSensitivityDefault,
  MangaPageAnimation pageAnimation = MangaPageAnimation.slide,
  bool tapZonePaging = true,
}) {
  final bool isWebtoon = mode == MangaReadingMode.webtoon;
  // spread 容器本身始终按 LTR 的几何顺序排列，保证 offsetLeft 是稳定的
  // 0/100vw/200vw；RTL 只施加到每个 spread 内部，让双页视觉页序反转。
  // 若把 direction:rtl 放在根 strip 上，Chromium 会把 wrapper 的 RTL 起点偏移
  // 混进 offsetLeft，translate 后整组图片向左错位、无法水平居中。
  final bool rtl = !isWebtoon && spreadDirection == 'rtl';
  final String pageDirectionCss = rtl ? 'direction:rtl;' : 'direction:ltr;';

  final StringBuffer pagesHtml = StringBuffer();
  final Map<int, StringBuffer> spreadPages = <int, StringBuffer>{};
  final int count =
      pages.length < imgSrcs.length ? pages.length : imgSrcs.length;
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
    final int pageNumber =
        (pageNumbers != null && i < pageNumbers.length) ? pageNumbers[i] : i;
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
    for (final int spreadIndex in spreadOrder) {
      pagesHtml.write('<div class="manga-spread" '
          'data-spread="$spreadIndex">${spreadPages[spreadIndex]}</div>');
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
          'width:100vw;align-items:flex-start;}'
          '.manga-page{width:100vw;}'
      : '#manga-viewport{overflow:hidden;width:100vw;height:100vh;}'
          '#manga-root{display:flex;flex-direction:row;direction:ltr;'
          'height:100vh;align-items:center;'
          '${_rootTransitionCss(pageAnimation)}will-change:transform;}'
          '.manga-spread{display:flex;flex:0 0 100vw;'
          'width:100vw;height:100vh;align-items:center;'
          'justify-content:center;$pageDirectionCss}';

  // spread 时 strip 包进 overflow:hidden 视口；webtoon 时 root 直接在 body。
  final String content = isWebtoon
      ? '<div id="manga-root">${pagesHtml.toString()}</div>'
      : '<div id="manga-viewport">'
          '<div id="manga-root">${pagesHtml.toString()}</div>'
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
      'html,body{margin:0;padding:0;background:#000;height:100%;touch-action:none;'
      '-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;}'
      '$rootSizing'
      '#manga-canvas{transform-origin:0 0;will-change:transform;}'
      '.manga-page{position:relative;flex:0 0 auto;'
      'container-type:inline-size;}'
      '.manga-page img{display:block;width:100%;height:100%;'
      'object-fit:contain;-webkit-user-drag:none;user-drag:none;}'
      '.ocr-box{margin:0;padding:0;pointer-events:auto;}'
      // Character geometry is entirely explicit. Keep the common hit-layer
      // declarations in one rule instead of repeating them for every OCR
      // character: dense magazine pages can contain several thousand regions.
      '.ocr-char{position:absolute;display:block;overflow:hidden;'
      'color:transparent;pointer-events:auto;line-height:1;'
      'writing-mode:horizontal-tb;}'
      '</style></head>'
      '<body>'
      '$body'
      '<script>$inlineSelectionJs</script>'
      '<script>'
      'window.__mangaDocumentGeneration=$documentGeneration;'
      '${_mangaGestureJs(
    isWebtoon: isWebtoon,
    rtl: rtl,
    currentSpread: currentSpread,
    restoreFraction: restoreFraction,
    zoomPercent: zoomPercent,
    zoomMinPercent: zoomMinPercent,
    zoomMaxPercent: zoomMaxPercent,
    zoomSensitivity: zoomSensitivity,
    pageAnimation: pageAnimation,
    tapZonePaging: tapZonePaging,
  )}'
      '</script>'
      '</body></html>';
}

/// 内联手势机 + 翻页/滚动几何。一个 pointerdown/pointerup 对（消歧 tap vs swipe）+
/// webtoon 滚动监听 + spread 鼠标滚轮翻页（BUG-051）。tap 命中 `.ocr-box` → 选词
/// （单击查词路径）；Shift 悬停是第二条显式查词路径。tap 命中裸图或未完成 OCR 的
/// 区域时保持在阅读器内，不打开独立大图。
/// swipe（仅 spread）→ `onMangaTurn`。spread 鼠标 `wheel` → `onMangaTurn`（桌面 swipe
/// 等价物，overflow:hidden 视口下滚轮本是死操作；带 320ms 锁合并连发）。webtoon 滚动
/// 节流 → `onMangaScroll`。`dragstart` 全程 preventDefault + CSS user-select/user-drag
/// 禁用，消除桌面拖动时的原生图片/选区残影（「秃瓢」）。手势阈值镜像 reader
/// （absDx>absDy 判 swipe，小位移判 tap）。spread translateX 在 [_mangaApplyTranslate]
/// 按 data-spread 测量。
/// `#manga-root` 的过渡声明，由翻页动画偏好决定。
///
/// `slide` = 旧行为（transform 过渡，时长由动画样式的统一值域给出）；`none` = 不声明过渡
/// （瞬时翻页，给要极限响应的用户）；`fade` = 只过渡 opacity，位移由 JS 在淡出后
/// 瞬时完成（见 `__mangaApplyTranslate`）。
String _rootTransitionCss(MangaPageAnimation animation) {
  switch (animation) {
    case MangaPageAnimation.none:
      return '';
    case MangaPageAnimation.slide:
      return 'transition:transform ${animation.durationMs}ms ease-out;';
    case MangaPageAnimation.fade:
      return 'transition:opacity ${animation.durationMs}ms ease-out;';
  }
}

String _mangaGestureJs({
  required bool isWebtoon,
  required bool rtl,
  required int currentSpread,
  required double restoreFraction,
  required int zoomPercent,
  required int zoomMinPercent,
  required int zoomMaxPercent,
  required int zoomSensitivity,
  required MangaPageAnimation pageAnimation,
  required bool tapZonePaging,
}) {
  // RTL：strip 视觉镜像，但 DOM offsetLeft 仍是几何坐标；translateX 统一把目标跨页
  // 首页 offsetLeft 平移到视口左边缘（width=100vw 的视口里目标跨页正好填满）。
  return '''
(function(){
  function _bridge(){ return window.flutter_inappwebview; }
  // ── canvas zoom/pan ──
  var ZOOM_MIN = ${zoomMinPercent / 100.0};
  var ZOOM_MAX = ${zoomMaxPercent / 100.0};
  // 灵敏度倍率（设置项，100% = 基准）。
  var ZOOM_SENS = ${zoomSensitivity / 100.0};
  var ZOOM = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, ${zoomPercent / 100.0}));
  // 纵向位置的唯一拥有者（BUG-1701）：webtoon 是竖滚文档，纵向归 window.scrollY，
  // PAN_Y 恒 0；spread 是 100vh 定高、overflow:hidden 的视口，不滚动，纵向归 PAN_Y。
  // 此前两模式共用 PAN_Y 公式，于是 webtoon 每次缩放都额外把整条长图平移
  // innerHeight*(1-ZOOM)/2 —— 画面自己上下跳一截。IS_WEBTOON 必须在这里就绪：
  // 下面的 _recenterPan / _applyCanvas 在文档解析期就会跑。
  var IS_WEBTOON = $isWebtoon;
  var PAN_X = 0;
  var PAN_Y = 0;
  function _recenterPan(){
    PAN_X = window.innerWidth * (1 - ZOOM) / 2;
    PAN_Y = IS_WEBTOON ? 0 : window.innerHeight * (1 - ZOOM) / 2;
  }
  _recenterPan();
  var rightDrag = null;
  function _applyCanvas(){
    var canvas = document.getElementById('manga-canvas');
    if (canvas) canvas.style.transform =
      'translate(' + PAN_X + 'px,' + PAN_Y + 'px) scale(' + ZOOM + ')';
  }
  function _clampZoom(z){
    return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z));
  }
  // 以 (ax, ay) 屏幕点为锚缩放到 next：锚点下的图像内容保持不动。缩到 <=1 时回中，
  // 因为此时整页已完全放得下，任何残留平移都只是把页面推出视口。
  function _zoomAbout(next, ax, ay){
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
    if (b) b.callHandler('onMangaZoomChanged', Math.round(ZOOM * 100));
    return true;
  }
  window.__mangaSetZoom = function(percent){
    // 以视口顶部为锚：scrollY 是视觉坐标（随 ZOOM 线性伸缩），换算过之后
    // 「设置里改缩放」不再把 webtoon 跳到别的页。
    var anchorLayout = IS_WEBTOON ? window.scrollY / ZOOM : 0;
    ZOOM = _clampZoom(percent / 100);
    _recenterPan();
    _applyCanvas();
    if (IS_WEBTOON) window.scrollTo(0, anchorLayout * ZOOM);
  };
  _applyCanvas();
  // ── spread translateX：把固定 100vw 的 spread 容器平移到视口左边缘 ──
  // 动画样式由设置决定：slide/none 直接改 transform（过渡与否交给 CSS）；fade 先
  // 淡出、位移完成后再淡入（位移本身不过渡，否则会同时看到滑动与淡入淡出）。
  var PAGE_ANIM = '${pageAnimation.key}';
  var PAGE_ANIM_MS = ${pageAnimation.durationMs};
  var _fadeTimer = null;
  window.__mangaApplyTranslate = function(target){
    var root = document.getElementById('manga-root');
    if (!root) return;
    var spread = root.querySelector('.manga-spread[data-spread="'+target+'"]');
    var offset = spread ? -spread.offsetLeft : 0;
    if (PAGE_ANIM !== 'fade') {
      root.style.transform = 'translateX(' + offset + 'px)';
      return;
    }
    if (_fadeTimer) clearTimeout(_fadeTimer);
    root.style.opacity = '0';
    _fadeTimer = setTimeout(function(){
      _fadeTimer = null;
      root.style.transform = 'translateX(' + offset + 'px)';
      root.style.opacity = '1';
    }, PAGE_ANIM_MS);
  };
  // ── webtoon scrollTo：恢复时把 data-spread==target 的页顶滚进视口，再按**页内**
  //    fraction 微调（HIGH-1：fraction 是 (scrollY-page.offsetTop)/page.offsetHeight
  //    页内归一化，与 onMangaScroll 报的口径一致；绝非文档全局 fraction）──
  window.__mangaScrollToSpread = function(target, fraction){
    var page = document.querySelector('.manga-page[data-spread="'+target+'"]');
    if (!page) return;
    // offsetTop/offsetHeight 是布局坐标；#manga-canvas 被 scale(ZOOM) 后
    // 视觉（滚动）坐标 = 布局坐标 * ZOOM。缺这一步在缩放态下会定位到错误的页。
    var top = (page.offsetTop + (fraction || 0) * page.offsetHeight) * ZOOM;
    window.scrollTo(0, top);
  };
  // 后台 OCR 每完成一页就只替换该页透明文字层，不重建 WebView 文档、不打断阅读。
  window.__mangaReplaceOcr = function(pageIndex, html){
    var page = document.querySelector('.manga-page[data-page="'+pageIndex+'"]');
    if (!page) return;
    var boxes = page.querySelectorAll('.ocr-box');
    for (var i = 0; i < boxes.length; i++) boxes[i].remove();
    if (html) page.insertAdjacentHTML('beforeend', html);
  };
  // ── 框选识别模式 ──
  // Dart 经 window.__mangaSetRescanMode(true/false) 进入/退出。模式内：
  // - pointer 拖出橡皮筋矩形（fixed 定位半透明框，纯视觉反馈）；
  // - 查词 tap / swipe 翻页 / 滚轮翻页全部旁路（框选手势独占指针）；
  // - 松手把视口矩形换算成**页图像素坐标**（框中心命中的 .manga-page 的
  //   data-page/data-pw/data-ph + getBoundingClientRect 线性映射；spread 跨页时
  //   以框中心判定落页并 clamp 进该页），经 onMangaBoxSelected 回 Dart；
  // - 任一维 < 8px（视口坐标）忽略并保持模式（用户重画）；
  // - 有效框发出后自动退出模式（Dart 端收到即复位按钮态）。
  var RESCAN = false;
  var rescanStart = null;
  var rescanEl = null;
  window.__mangaSetRescanMode = function(on){
    RESCAN = !!on;
    if (!RESCAN) _rescanClear();
  };
  function _rescanClear(){
    if (rescanEl && rescanEl.parentNode) rescanEl.parentNode.removeChild(rescanEl);
    rescanEl = null;
    rescanStart = null;
  }
  function _rescanUpdate(x, y){
    if (!rescanStart) return;
    if (!rescanEl) {
      rescanEl = document.createElement('div');
      rescanEl.id = 'manga-rescan-rect';
      rescanEl.style.cssText = 'position:fixed;z-index:2147483647;'
        + 'pointer-events:none;border:2px solid rgba(66,165,245,0.9);'
        + 'background:rgba(66,165,245,0.25);';
      document.body.appendChild(rescanEl);
    }
    rescanEl.style.left = Math.min(rescanStart.x, x) + 'px';
    rescanEl.style.top = Math.min(rescanStart.y, y) + 'px';
    rescanEl.style.width = Math.abs(x - rescanStart.x) + 'px';
    rescanEl.style.height = Math.abs(y - rescanStart.y) + 'px';
  }
  function _rescanFinish(x, y){
    var start = rescanStart;
    _rescanClear();
    if (!start) return;
    if (Math.abs(x - start.x) < 8 || Math.abs(y - start.y) < 8) return;
    var cx = (start.x + x) / 2, cy = (start.y + y) / 2;
    var pages = document.querySelectorAll('.manga-page');
    var target = null, tr = null;
    for (var i = 0; i < pages.length; i++) {
      var r = pages[i].getBoundingClientRect();
      if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
        target = pages[i];
        tr = r;
        break;
      }
    }
    if (!target || tr.width <= 0 || tr.height <= 0) return;
    var pw = parseFloat(target.getAttribute('data-pw')) || 0;
    var ph = parseFloat(target.getAttribute('data-ph')) || 0;
    if (pw <= 0 || ph <= 0) return;
    var pageIndex = parseInt(target.getAttribute('data-page'), 10) || 0;
    function toPx(v){ return Math.min(pw, Math.max(0, (v - tr.left) / tr.width * pw)); }
    function toPy(v){ return Math.min(ph, Math.max(0, (v - tr.top) / tr.height * ph)); }
    RESCAN = false;
    var b = _bridge();
    if (!b) return;
    b.callHandler('onMangaBoxSelected', JSON.stringify({
      pageIndex: pageIndex,
      left: toPx(Math.min(start.x, x)),
      top: toPy(Math.min(start.y, y)),
      right: toPx(Math.max(start.x, x)),
      bottom: toPy(Math.max(start.y, y))
    }));
  }
  document.addEventListener('pointermove', function(e){
    if (RESCAN && rescanStart) { _rescanUpdate(e.clientX, e.clientY); return; }
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
    _panBy(pdx, pdy);
  }, {passive: false});
  var CURRENT = $currentSpread;
  var RESTORE_FRACTION = ${restoreFraction.toStringAsFixed(6)};
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
    if (!IS_WEBTOON) {
      var slots = Number(page.getAttribute('data-spread-pages')) || 1;
      slots = slots <= 1 ? 1 : slots;
      var slotVw = 100 / slots;
      page.style.width =
        'min(' + slotVw + 'vw,' + (100 * width / height) + 'vh)';
      page.style.height =
        'min(100vh,' + (slotVw * height / width) + 'vw)';
    }
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
    if (image.complete) apply();
  });
  // 首次定位是「摆位」，不是「翻页」：必须无过渡落位。
  //
  // RTL（默认阅读方向）倒序写入 DOM 后，spread 0 的 offsetLeft 从 0 变成
  // (n-1)×100vw，首帧 __mangaApplyTranslate(CURRENT) 要把 #manga-root 从
  // transform:none 一路推到 -(n-1)×100vw；而 slide（默认动画）给 #manga-root 挂着
  // transition:transform，下面的双 rAF 又恰好是「保证过渡一定触发」的惯用法 ——
  // 于是打开任何 RTL 书都会先看到整卷从最后一页扫回第一页（strip 是整卷长度，
  // 200 跨页就是 199 个视口的扫掠，途经的 lazy 图还会被连带解码）。
  //
  // 关过渡 → 写 transform → 读一次 offsetHeight 强制同步 reflow（让新值成为后续
  // 过渡的起点，否则还原后浏览器仍把这次位移算成一次过渡）→ 还原原过渡值。
  // 还原发生在 reflow 之后，真正的翻页动画不受影响（不是永久关掉过渡）。
  function _initPosition(){
    if (IS_WEBTOON) {
      window.__mangaScrollToSpread(CURRENT, RESTORE_FRACTION);
      return;
    }
    var root = document.getElementById('manga-root');
    var prevTransition = root ? root.style.transition : '';
    if (root) root.style.transition = 'none';
    window.__mangaApplyTranslate(CURRENT);
    if (root) {
      void root.offsetHeight;
      root.style.transition = prevTransition;
    }
  }
  // 图片/布局完成前 offsetLeft/offsetTop 可能为 0；首帧后 + load 后各定位一次。
  if (document.readyState === 'complete') { _initPosition(); }
  window.addEventListener('load', _initPosition);
  requestAnimationFrame(function(){ requestAnimationFrame(_initPosition); });

  // ── 手势消歧（pointer，覆盖触摸/鼠标）──
  var sx = 0, sy = 0, st = 0, has = false;
  function _start(x, y){ has = true; sx = x; sy = y; st = Date.now(); }
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
  // 惯性：每秒衰减到 0.2%，低于 40px/s 停。阈值挡掉松手时的微抖动，
  // 否则每次抬手都会看到一小段无意的漂移。
  function _startFlick(vy){
    if (!IS_WEBTOON || Math.abs(vy) < 80) return;
    flickVy = vy;
    var last = Date.now();
    var step = function(){
      var now = Date.now();
      var dt = Math.min(64, Math.max(1, now - last));
      last = now;
      flickVy *= Math.pow(0.002, dt / 1000);
      if (Math.abs(flickVy) < 40) { _stopFlick(); return; }
      window.scrollBy(0, -flickVy * dt / 1000);
      flickRaf = requestAnimationFrame(step);
    };
    flickRaf = requestAnimationFrame(step);
  }
  var pinch = null;
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
  function _selectOcrChar(x, y, fromHover){
    var charEl = _hitOcrChar(x, y);
    var selection = window.fushiSelection;
    if (!charEl || !selection) return false;
    var node = charEl.firstChild;
    if (!node || node.nodeType !== Node.TEXT_NODE) return false;
    window.__mangaLastOcrHit = {
      text: node.textContent || '',
      orientation: charEl.getAttribute('data-ocr-orientation') || '',
      x: x, y: y, zoom: ZOOM
    };
    if (selection.selection &&
        selection.selection.startNode === node &&
        selection.selection.startOffset === 0) {
      if (fromHover) return true;
      selection.clearSelection();
      return true;
    }
    selection.clearSelection();
    selection.selectFromPosition(node, 0, 40, x, y);
    var bridge = _bridge();
    if (bridge) bridge.callHandler('onMangaOcrHitDebug',
      JSON.stringify(window.__mangaLastOcrHit));
    return true;
  }
  // Desktop Shift-hover lookup: mirror the EPUB reader's hover path. Throttle by
  // pointer distance so a stationary cursor does not repeat the same lookup.
  var shiftHoverX = -1, shiftHoverY = -1;
  document.addEventListener('mousemove', function(e){
    if (RESCAN) return;
    if (!e.shiftKey) { shiftHoverX = -1; shiftHoverY = -1; return; }
    var dx = e.clientX - shiftHoverX, dy = e.clientY - shiftHoverY;
    if (shiftHoverX >= 0 && dx * dx + dy * dy < 16) return;
    shiftHoverX = e.clientX; shiftHoverY = e.clientY;
    _selectOcrChar(e.clientX, e.clientY, true);
  }, {passive:true});
  // 点击边缘翻页（仅 spread）。此前漫画**没有任何点击翻页手段**：_onTap 命中不到
  // OCR 就只报 onTapEmpty（Dart 侧只回收焦点），触屏用户只能靠 swipe。
  // 左右各占 TAP_ZONE 宽度；中间留白仍走 onTapEmpty，避免抢走查词/呼出 chrome。
  // 方向按阅读方向镜像：LTR 右边缘前进，RTL 左边缘前进。
  var TAP_ZONE_PAGING = $tapZonePaging;
  var IS_RTL = $rtl;
  var TAP_ZONE = 0.25;
  function _tapZoneTurn(x){
    if (!TAP_ZONE_PAGING || IS_WEBTOON) return null;
    var w = window.innerWidth || 1;
    if (x <= w * TAP_ZONE) return IS_RTL ? 'next' : 'prev';
    if (x >= w * (1 - TAP_ZONE)) return IS_RTL ? 'prev' : 'next';
    return null;
  }
  function _onTap(x, y){
    var b = _bridge();
    if (!b) return;
    if (_selectOcrChar(x, y, false)) return;
    var zone = _tapZoneTurn(x);
    if (zone) { b.callHandler('onMangaTurn', zone); return; }
    // 裸图 / 尚未完成 OCR 的区域不打开大图，继续留在阅读器。
    b.callHandler('onTapEmpty');
  }
  function _end(x, y){
    // 无配对 pointerdown（has=false）：合成事件或捕获丢失，没有位移可判 swipe →
    // 只能是 tap，直接走 tap 路径（不丢选词）。
    if (!has) { _onTap(x, y); return; }
    has = false;
    var dx = x - sx, dy = y - sy, el = Date.now() - st;
    var ax = Math.abs(dx), ay = Math.abs(dy);
    var vel = ax / Math.max(1, el) * 1000;
    // ZOOM>1 时拖动已被 _panBy 消费为平移（放大后必须能看页面各处），
    // 此时再判 swipe 会让每次平移都翻页。翻页仍可用点击边缘 / 滚轮 / 音量键。
    if (!IS_WEBTOON && ZOOM <= 1 &&
        ax > ay && (ax >= 72 || (ax >= 36 && vel >= 900))) {
      var b = _bridge();
      if (!b) return;
      // swipe 跟手：拖动内容向左（dx<0）露出的是 strip **右边**那一跨页。右边是哪
      // 一页取决于几何顺序——LTR 正序时右边是 next，RTL 倒序时右边是 prev（见文档
      // 生成处的 spreadOrder）。所以必须按 IS_RTL 镜像，RTL 下「向右滑 = 下一页」，
      // 与 Mihon 等 RTL 阅读器一致。
      //
      // 旧注释声称「dir 由 Dart 端依据阅读方向 clamp」——Dart 侧（_onMangaTurn）只有
      // `next ? +1 : -1` 和边界钳位，从来没有方向 clamp，按那句推理必然推错。
      var swipeRight = dx > 0;
      b.callHandler('onMangaTurn',
          (swipeRight === IS_RTL) ? 'next' : 'prev');
    } else if (ax < 20 && ay < 20 && el < 500) {
      _onTap(x, y);
    }
  }
  document.addEventListener('pointerdown', function(e){
    if (e.pointerType === 'touch') {
      touchPts[e.pointerId] = {x: e.clientX, y: e.clientY};
      var g = _pinchGeom();
      if (g && g.dist > 0) {
        // 第二指落下：进入捏合，取消已经开始的单指 swipe 计时与拖动。
        pinch = {dist: g.dist, zoom: ZOOM};
        pinchGuard = true;
        has = false;
        panDrag = null;
        _stopFlick();
        return;
      }
    }
    if (RESCAN) { rescanStart = {x: e.clientX, y: e.clientY}; return; }
    if (e.button === 2) {
      rightDrag = {
        startX:e.clientX, startY:e.clientY,
        lastX:e.clientX, lastY:e.clientY, moved:false
      };
      e.preventDefault();
      return;
    }
    if (e.button !== 0) return;
    // 触屏惯例：滑动中按下即刹车。
    _stopFlick();
    panDrag = {
      id: e.pointerId, lastX: e.clientX, lastY: e.clientY,
      lastT: Date.now(), vy: 0, touch: e.pointerType === 'touch'
    };
    _start(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointermove', function(e){
    if (e.pointerType !== 'touch') return;
    if (!touchPts[e.pointerId]) return;
    touchPts[e.pointerId] = {x: e.clientX, y: e.clientY};
    if (!pinch) return;
    var g = _pinchGeom();
    if (!g || g.dist <= 0) return;
    e.preventDefault();
    _zoomAbout(
      pinch.zoom * Math.pow(g.dist / pinch.dist, ZOOM_SENS),
      g.cx,
      g.cy
    );
  }, {passive: false});
  document.addEventListener('pointerup', function(e){
    var drag = (panDrag && panDrag.id === e.pointerId) ? panDrag : null;
    if (drag) panDrag = null;
    if (e.pointerType === 'touch') {
      delete touchPts[e.pointerId];
      if (pinch) {
        // 还剩一指时仍不恢复 swipe：等全部手指抬起，避免捏合尾巴被判成翻页。
        if (Object.keys(touchPts).length < 2) pinch = null;
        return;
      }
      if (pinchGuard) {
        if (Object.keys(touchPts).length === 0) pinchGuard = false;
        return;
      }
      if (drag && drag.touch) _startFlick(drag.vy);
    }
    // 必须排在 _end 的 tap/swipe 消歧之前：框选松手不得被判成 tap 查词或 swipe 翻页。
    if (RESCAN) { _rescanFinish(e.clientX, e.clientY); return; }
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
    if (panDrag && panDrag.id === e.pointerId) panDrag = null;
    if (e.pointerType === 'touch') {
      delete touchPts[e.pointerId];
      if (Object.keys(touchPts).length < 2) pinch = null;
      if (Object.keys(touchPts).length === 0) pinchGuard = false;
    }
    if (RESCAN) _rescanClear();
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
  // 「一格」的判定复用本文件翻页滚轮的同一套累计口径（阈值 40 + 反向清账，见下方
  // BUG-051 段）：鼠标一格无论 deltaY 是 57/67/100 都 >=40，恒好一步；触控板的碎
  // delta 攒够 40 才走一步。跨过阈值即清零、不留余数——留余数会让 deltaY=57 这类值
  // 攒出 1,1,2,1,1,2 的非匀速台阶，正好毁掉「一格 = 10%」这个承诺。
  var _zoomAccum = 0;
  var _zoomDir = 0;
  function _wheelZoomNotch(e){
    var dy = e.deltaY || 0;
    if (e.deltaMode === 1) dy *= 16;
    else if (e.deltaMode === 2) dy *= window.innerHeight;
    if (dy === 0) return 0;
    var dir = dy > 0 ? -1 : 1;
    if (dir !== _zoomDir) { _zoomAccum = 0; _zoomDir = dir; }
    _zoomAccum += Math.abs(dy);
    if (_zoomAccum < 40) return 0;
    _zoomAccum = 0;
    return dir;
  }
  document.addEventListener('wheel', function(e){
    if (RESCAN) return;
    if (!(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    var dir = _wheelZoomNotch(e);
    if (dir === 0) return;
    // 先把 ZOOM 化成保留 1 位小数的百分比再上下取整：ZOOM 是浮点，1.2 常存成
    // 1.2000000000000002，直接 Math.ceil(120.00000000000003 / 10) 会得 13 而不是 12，
    // 缩小一步就变成原地不动（_zoomAbout 的 0.0005 死区把它吃掉）。
    var cur = Math.round(ZOOM * 1000) / 10;
    var next = dir > 0
      ? (Math.floor(cur / ZOOM_STEP) + 1) * ZOOM_STEP
      : (Math.ceil(cur / ZOOM_STEP) - 1) * ZOOM_STEP;
    _zoomAbout(next / 100, e.clientX, e.clientY);
  }, {passive:false});

  // ── 桌面鼠标滚轮翻页（仅 spread，BUG-051）──
  // spread 的 #manga-viewport 是 overflow:hidden，滚轮本就无处可滚（死操作）；
  // 把它复用为翻页——这是桌面端 swipe 的等价物（PC 漫画阅读器惯例）。webtoon 保留
  // WebView 自身的原生竖向滚动，故不在此接线（否则会抢走正常滚动）。一次滚轮事件
  // 流（尤其触控板惯性）可能连发多个 wheel，用 _wheelLock 在 320ms 内合并为一次翻页，
  // 避免一格滚动翻一叠页。
  if (!IS_WEBTOON) {
    var _wheelLock = false;
    var _wheelAccum = 0;
    var _wheelDir = 0;
    document.addEventListener('wheel', function(e){
      if (RESCAN) return;
      if (e.ctrlKey || e.metaKey) return;
      e.preventDefault();
      var d = e.deltaY || e.deltaX || 0;
      if (e.deltaMode === 1) d *= 16;
      else if (e.deltaMode === 2) d *= window.innerHeight;
      if (d === 0) return;
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
  // HIGH-1：报**页内** fraction（视口顶部所在页内的归一化偏移 0..1），与
  // __mangaScrollToSpread 的口径统一——绝不报文档全局 fraction（那会被当页内
  // offset 用，恢复/定位错一整页）。topPage = 视口顶部所在页的 data-spread，
  // fraction 与 topPage 同源（同一页）。
  if (IS_WEBTOON) {
    var _scrollTimer = null;
    window.addEventListener('scroll', function(){
      if (_scrollTimer) return;
      _scrollTimer = setTimeout(function(){
        _scrollTimer = null;
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
        b.callHandler('onMangaScroll', JSON.stringify({ fraction: fraction, topPage: topPage }));
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
