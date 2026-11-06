/// 漫画整卷 OCR 流水线：逐页 检测 → 排序 → 单框/批识别，带逐页断点缓存、
/// 进度回调与取消令牌。
///
/// 缓存语义对齐 mokuro 的 `_ocr/` 目录：**一页一条结果**，页子任务完成即
/// 落缓存；中断重跑只补未完成页。缓存后端（文件/DB）由调用方实现
/// [OcrPageCache]，本层只依赖接口。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/reading_order.dart';

/// 逐页断点缓存接口。key = (bookId, pageIndex)。
abstract interface class OcrPageCache {
  Future<OcrPageResult?> read(String bookId, int pageIndex);
  Future<void> write(String bookId, OcrPageResult result);
}

/// 取消令牌：置位后流水线在下一个安全点（页间/块间/批次间）抛
/// [OcrCancelledException]；已完成页的缓存不回滚，重跑续传。
class OcrCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const OcrCancelledException();
    }
  }
}

class OcrCancelledException implements Exception {
  const OcrCancelledException();

  @override
  String toString() => 'OcrCancelledException';
}

/// 进度回调：completedPages 含缓存命中页；[pageIndex] 是刚完成的那一页的真实
/// 页号（整卷任务按 `startPage` 旋转顺序跑，完成计数不再等于页号 + 1）。
typedef OcrProgressCallback =
    void Function(int completedPages, int totalPages, int pageIndex);

/// 整卷处理顺序：从 [startPage]（越界时夹到合法范围）起向后到末页，再绕回
/// 0 补齐前面的页。阅读器从当前页开跑，读者眼前这页最先出结果——与 Lens /
/// 系统 OCR 路径同一口径（`manga_ocr_job_stream.dart`）。
List<int> mangaOcrPageOrder(int pageCount, int startPage) {
  if (pageCount <= 0) {
    return const <int>[];
  }
  final int start = startPage.clamp(0, pageCount - 1);
  return <int>[
    for (int page = start; page < pageCount; page++) page,
    for (int page = 0; page < start; page++) page,
  ];
}

/// 运行中可改道的整卷处理顺序：没有改道时给出的序列与 [mangaOcrPageOrder]
/// 完全相同；[focus] 把游标挪到读者当前页，之后从那页起向后取尚未给出的页，
/// 到末页再绕回。每页恰好给出一次。
///
/// 读者往前翻回去时也是「先那页、再往后接着跑」，已经处理过的页直接跳过。
class MangaOcrPageScheduler {
  MangaOcrPageScheduler(this.pageCount, int startPage)
    : _taken = List<bool>.filled(pageCount < 0 ? 0 : pageCount, false),
      _cursor = pageCount <= 0 ? 0 : startPage.clamp(0, pageCount - 1);

  final int pageCount;
  final List<bool> _taken;
  int _cursor;

  /// 读者翻到了 [pageIndex]：下一次 [next] 从它开始找。越界请求忽略。
  void focus(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pageCount) return;
    _cursor = pageIndex;
  }

  /// 下一页页号；全部给出过之后为 null。
  int? next() {
    for (int step = 0; step < pageCount; step++) {
      final int page = (_cursor + step) % pageCount;
      if (_taken[page]) continue;
      _taken[page] = true;
      _cursor = (page + 1) % pageCount;
      return page;
    }
    return null;
  }
}

/// 按页索引懒加载解码好的页面图像（由调用方实现，通常从压缩包/目录读）。
typedef OcrPageLoader = Future<img.Image> Function(int pageIndex);

/// 能给「已经识别好的文本」补行几何的识别器（旧版缓存升级用，BUG-2813）。
///
/// 结果必须与新识别这一块的结果一致：新识别里整块读文本的块，[text] 原样保留，
/// 只按块内检出的列/行把它切开并带回行框；做不到（没检到行）时返回不带行几何的
/// 结果。新识别里逐行读、带逐字命中格（[OcrRecognition.glyphBoxes]）的块，缓存
/// 文本给不出字格，实现应按新识别重读这一块并返回新文本（pipeline 以结果的
/// `text` 为准）。
abstract interface class LineLayoutOcrRecognizer implements OcrRecognizer {
  Future<OcrRecognition> layoutRecognized(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
  });
}

/// 逐行（竖排逐列）识别整块、直接交回每行文本与行框的识别器。
///
/// 与 [LineLayoutOcrRecognizer] 的区别：那边是整块识别完再按检出的列长估算切分；
/// 这边每行本来就是单独识别的，行文本与行框天然一一对应，不用估算——整块交它的
/// 块，路由识别器直接采用它的结果。
///
/// [vertical] 是调用方对块方向的判断，实现可按检出的行改判，结果里的 `vertical`
/// 是最终方向。[lineHints] 是调用方已检出的原始行框（页面坐标、未滤振假名），
/// 给了就不再检测。有行几何时结果的 `lines` / `lineBoxes` 是阅读序、页面坐标，
/// `lines.join() == text`；一行都没检到时只给整块文本（不带行几何）。
abstract interface class LineOcrRecognizer implements OcrRecognizer {
  Future<OcrRecognition> recognizeWithLines(
    img.Image page,
    OcrRect box, {
    required bool vertical,
    List<OcrRect>? lineHints,
  });
}

/// 补检：页面文字检测器没过正式阈值的文字（低分的装饰性标题等），由实现方复核后
/// 补回来（`page_text_sweep.dart`）。[candidates] 是检测器的弱候选
/// （[PageDetections.weakTextRegions]），[covered] 是已有文字块的框，落在里面的
/// 不再补；返回的块自带行几何，页面坐标。
abstract interface class OcrPageTextSweeper {
  Future<List<OcrBlock>> sweep(
    img.Image page, {
    required List<DetectedTextRegion> candidates,
    required List<OcrRect> covered,
  });
}

/// 竖排判定的长宽比阈值：高 > 宽 * 阈值 视为竖排。
///
/// 检测器返回的是轴对齐框，倾斜竖排会被横向外接矩形拉宽；1.5 会把真实封面上
/// 约 1.4:1 的竖排误判为横排。1.25 仍让接近方形（≤1.2:1）的块保持横排，同时
/// 覆盖这类倾斜竖排。
const double kVerticalAspectThreshold = 1.25;

/// 控制单次调用的工作量，在密集页的批次之间仍可响应取消。
/// 识别后端可以把本批进一步拆小；这里不并发处理页面或识别批次。
const int _recognitionBatchSize = 8;

bool isVerticalBlock(OcrRect box) =>
    box.height > box.width * kVerticalAspectThreshold;

/// 子块面积不超过父块的这个比例才算「被包含的子块」：几乎同大的两个框是同一块
/// 被检出两次（NMS 只删 IoU >= 0.7 的），不是父子。
const double kOcrLeafMaxAreaRatio = 0.8;

/// 子块至少这么大比例的面积落在父块里才算被父块几何包含（检测框边缘有几像素
/// 的出入，不要求严格包含）。
const double kOcrLeafMinInsideRatio = 0.9;

/// 父块被至少这么多个已识别子块几何包含时，父块让位给子块。
const int kOcrContainerMinLeaves = 2;

/// 父块的行（按面积）至少这么大比例被子块盖住，才让位：父块里没有子块认领的那些
/// 行，删掉父块就没人读了——宁可留着大框，也不丢字。
const double kOcrContainerMinCoveredRatio = 0.75;

double _intersectionArea(OcrRect a, OcrRect b) {
  final double w = math.min(a.right, b.right) - math.max(a.left, b.left);
  final double h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  return w <= 0 || h <= 0 ? 0 : w * h;
}

bool _isLeafOf(OcrRect outer, OcrRect inner) =>
    inner.area > 0 &&
    inner.area <= kOcrLeafMaxAreaRatio * outer.area &&
    _intersectionArea(outer, inner) >= kOcrLeafMinInsideRatio * inner.area;

/// [parent] 的行有多少被 [leaves] 盖住了（0–1，按行面积）：每行被子块盖住的
/// 面积（各子块交集相加、封顶到行面积）占全部行面积的比例。
///
/// 父块没有行几何时返回 0（不让位）：不知道它的字落在哪儿，就没法确认删掉它
/// 不丢字。逐行识别器（逐列 CTC、横排 PP rec）总会给行几何，没有的只是整块
/// 识别、一行都没检到的块。
double _leafCoverage(OcrBlock parent, List<OcrBlock> leaves) {
  final List<OcrRect>? lines = parent.lineBoxes;
  if (lines == null || lines.isEmpty) return 0;
  double total = 0;
  double covered = 0;
  for (final OcrRect line in lines) {
    total += line.area;
    double inLeaves = 0;
    for (final OcrBlock leaf in leaves) {
      inLeaves += _intersectionArea(line, leaf.box);
    }
    covered += math.min(line.area, inLeaves);
  }
  return total <= 0 ? 0 : covered / total;
}

/// 去掉「容器块」：几何上包含至少 [kOcrContainerMinLeaves] 个已识别子块、且行
/// 基本被子块盖住（[kOcrContainerMinCoveredRatio]）的父块，保留叶子块。
///
/// 为什么：检测器会在一页几段相邻文字外面再框一个大框（人物资料页上从页顶到页底
/// 的那种），NMS 只删 IoU >= 0.7 的，大框与每个小块的 IoU 都很低，父子全进
/// manga.json——大框盖在几个小块上，点哪儿都可能命中它，它的行几何又是在一张跨
/// 栏的大裁图里检出来的。叶子块是检测器对单段文字的判断，几何更贴字。
///
/// 只看几何，不看父块宽高、不要求父块文本逐字包含子块文本：父块文本是另一次
/// 识别，字稍有出入（大裁图里读错一两个字）就不再成立。只包含一个子块时不动
/// （那是「父块漏读小字」的情形，见 [_suppressRecognizedContainedBlocks]）。
List<OcrBlock> _dropContainerBlocks(List<OcrBlock> blocks) {
  return <OcrBlock>[
    for (final OcrBlock parent in blocks)
      if (!_isContainerBlock(parent, blocks)) parent,
  ];
}

bool _isContainerBlock(OcrBlock parent, List<OcrBlock> blocks) {
  final List<OcrBlock> leaves = <OcrBlock>[
    for (final OcrBlock child in blocks)
      if (!identical(child, parent) &&
          child.text.isNotEmpty &&
          _isLeafOf(parent.box, child.box))
        child,
  ];
  if (leaves.length < kOcrContainerMinLeaves) return false;
  return _leafCoverage(parent, leaves) >= kOcrContainerMinCoveredRatio;
}

/// 全页识别完成后才判包含重复，允许子框补回父块漏读的小字号正文。
/// 必须逐字包含完整子文本，不折叠空白或标点。横排按识别路由的宽 >= 高
/// 判断，不用展示方向的 1.25 阈值。筛选只删除结果，不改变阅读顺序；父子框
/// 即使分属不同批次或子框先识别，也按同样规则处理。
List<OcrBlock> _suppressRecognizedContainedBlocks(List<OcrBlock> blocks) {
  return blocks.where((OcrBlock child) {
    final OcrRect inner = child.box;
    final String text = child.text;
    if (text.isEmpty || inner.area <= 0 || inner.width < inner.height) {
      return true;
    }
    return !blocks.any((OcrBlock parent) {
      final OcrRect outer = parent.box;
      return parent.score > child.score &&
          outer.width >= outer.height &&
          outer.left <= inner.left &&
          outer.top <= inner.top &&
          outer.right >= inner.right &&
          outer.bottom >= inner.bottom &&
          parent.text.contains(text);
    });
  }).toList();
}

/// 字格只在区间落在块文本里时采用（与行几何同口径：给错了宁可退回均分）。
bool _glyphsFit(OcrRecognition recognition, String text) {
  final List<OcrGlyphBox>? glyphs = recognition.glyphBoxes;
  return glyphs != null && ocrGlyphBoxesFitText(glyphs, text);
}

/// 一块的识别结果落成 [OcrBlock]：新识别与旧版缓存升级共用，两条路落出的块
/// 同一口径。
///
/// 行几何只在「拼回去就是原文」时采用：识别器给错了宁可退回整块单行，也不让
/// 覆盖层的字与句子文本错位；字格另须区间落在文本里。
OcrBlock _blockFromRecognition(
  OcrRecognition recognition, {
  required OcrRect box,
  required double score,
  required bool insideBubble,
  required double? confidence,
}) {
  final String text = recognition.text;
  final List<String>? lines = recognition.lines;
  final bool hasLayout =
      lines != null && lines.isNotEmpty && lines.join() == text;
  return OcrBlock(
    box: box,
    vertical: recognition.vertical,
    lines: hasLayout ? lines : <String>[text],
    lineBoxes: hasLayout ? recognition.lineBoxes : null,
    lineTilt: hasLayout ? recognition.lineTilt : 0,
    score: score,
    insideBubble: insideBubble,
    confidence: confidence,
    glyphBoxes: hasLayout && _glyphsFit(recognition, text)
        ? recognition.glyphBoxes
        : null,
  );
}

/// 整页识别完的收尾：容器块让位给叶子块，再删文本确认的横排包含重复。
/// 新识别与旧版缓存升级共用。
List<OcrBlock> _finishRecognizedBlocks(List<OcrBlock> blocks) =>
    _suppressRecognizedContainedBlocks(_dropContainerBlocks(blocks));

/// 整卷编排器。检测器/识别器经窄接口注入（模型路径、EP 选择在其构造侧）。
class MangaOcrPipeline {
  MangaOcrPipeline({
    required OcrDetector detector,
    required OcrRecognizer recognizer,
    this.cache,
    this.rightToLeft = true,
    OcrPageTextSweeper? sweeper,
  }) : _detector = detector,
       _recognizer = recognizer,
       _sweeper = sweeper;

  final OcrDetector _detector;
  final OcrRecognizer _recognizer;
  final OcrPageTextSweeper? _sweeper;
  final OcrPageCache? cache;

  /// 阅读方向（日漫 RTL 默认）。
  final bool rightToLeft;

  /// 处理整卷。返回**按页序**排列的结果（含缓存命中页），与 [startPage] 无关。
  ///
  /// 处理顺序见 [mangaOcrPageOrder]：从 [startPage] 起、绕回开头补齐（有
  /// [takeFocus] 改道时以 [MangaOcrPageScheduler] 为准）。
  /// 中断（[cancelToken] 置位）抛 [OcrCancelledException]；已完成页已落
  /// 缓存，重跑时只补缺页。
  ///
  /// [legacyCaches]：识别文本与当前版本相同、只缺行几何的旧版逐页缓存。当前缓存
  /// 缺页而旧缓存有这一页、且识别器能补排版（[LineLayoutOcrRecognizer]）时，
  /// 只补算行几何写成当前版本，不重新识别（BUG-2813）。
  ///
  /// [takeFocus]：每页开始前取一次读者当前页（没有新请求返回 null），有就把
  /// 处理游标挪过去（[MangaOcrPageScheduler]）——读者翻到哪页，下一页就先跑哪页。
  Future<List<OcrPageResult>> processBook({
    required String bookId,
    required int pageCount,
    required OcrPageLoader loadPage,
    int startPage = 0,
    OcrCancelToken? cancelToken,
    OcrProgressCallback? onProgress,
    List<OcrPageCache> legacyCaches = const <OcrPageCache>[],
    int? Function()? takeFocus,
  }) async {
    final List<OcrPageResult?> results = List<OcrPageResult?>.filled(
      pageCount,
      null,
    );
    final MangaOcrPageScheduler scheduler = MangaOcrPageScheduler(
      pageCount,
      startPage,
    );
    int completed = 0;
    while (true) {
      final int? focused = takeFocus?.call();
      if (focused != null) scheduler.focus(focused);
      final int? page = scheduler.next();
      if (page == null) break;
      cancelToken?.throwIfCancelled();
      final OcrPageResult? cached = await cache?.read(bookId, page);
      if (cached != null) {
        results[page] = cached;
        completed++;
        onProgress?.call(completed, pageCount, page);
        continue;
      }
      final img.Image image = await loadPage(page);
      final OcrPageResult result =
          await _relayoutLegacyPage(
            bookId: bookId,
            pageIndex: page,
            image: image,
            legacyCaches: legacyCaches,
            cancelToken: cancelToken,
          ) ??
          await processPage(
            pageIndex: page,
            image: image,
            cancelToken: cancelToken,
          );
      await cache?.write(bookId, result);
      results[page] = result;
      completed++;
      onProgress?.call(completed, pageCount, page);
    }
    return <OcrPageResult>[
      for (final OcrPageResult? result in results) result!,
    ];
  }

  /// 旧版缓存有这一页就只补行几何返回；没有 / 识别器不会补 / 页尺寸对不上时
  /// 返回 null，由调用方完整识别。
  Future<OcrPageResult?> _relayoutLegacyPage({
    required String bookId,
    required int pageIndex,
    required img.Image image,
    required List<OcrPageCache> legacyCaches,
    OcrCancelToken? cancelToken,
  }) async {
    final OcrRecognizer recognizer = _recognizer;
    if (recognizer is! LineLayoutOcrRecognizer) return null;
    for (final OcrPageCache legacyCache in legacyCaches) {
      final OcrPageResult? legacy = await legacyCache.read(bookId, pageIndex);
      if (legacy == null) continue;
      // 旧结果的坐标系必须就是这张图（v2 起统一按 EXIF 摆正后的像素）。
      if (legacy.imageWidth != image.width ||
          legacy.imageHeight != image.height) {
        return null;
      }
      final List<OcrBlock> blocks = <OcrBlock>[];
      for (final OcrBlock block in legacy.blocks) {
        cancelToken?.throwIfCancelled();
        final String text = block.text;
        if (block.lineBoxes != null || text.isEmpty) {
          blocks.add(block);
          continue;
        }
        final OcrRecognition laidOut = await recognizer.layoutRecognized(
          image,
          block.box,
          text,
          vertical: block.vertical,
        );
        // 识别器重读了这一块却读空：退回缓存文本（不丢字），只是没有行几何。
        final OcrRecognition recognition = laidOut.text.isEmpty
            ? OcrRecognition(text: text, vertical: block.vertical)
            : laidOut;
        blocks.add(
          _blockFromRecognition(
            recognition,
            box: block.box,
            score: block.score,
            insideBubble: block.insideBubble,
            // 整块文本沿用缓存时识别器不出分，沿用缓存里的置信度。
            confidence: recognition.confidence ?? block.confidence,
          ),
        );
      }
      return OcrPageResult(
        pageIndex: pageIndex,
        imageWidth: legacy.imageWidth,
        imageHeight: legacy.imageHeight,
        // 与新识别同一套整页收尾：旧版缓存写在容器块让位（v7）之前，块补上行几何
        // 后才判得出容器块（[_leafCoverage] 按行几何算）。
        blocks: _finishRecognizedBlocks(blocks),
      );
    }
    return null;
  }

  /// 处理单页：检测 → 阅读顺序 → 按识别器能力单框或有界批识别。
  Future<OcrPageResult> processPage({
    required int pageIndex,
    required img.Image image,
    OcrCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final PageDetections detections = await _detector.detect(image);
    cancelToken?.throwIfCancelled();
    final List<OcrRect> boxes = <OcrRect>[
      for (final DetectedTextRegion region in detections.textRegions)
        region.rect,
    ];
    final List<int> order = computeReadingOrder(
      boxes,
      rightToLeft: rightToLeft,
    );

    final List<OcrBlock> blocks = <OcrBlock>[];
    final OcrRecognizer recognizer = _recognizer;
    final int batchSize = recognizer is BatchOcrRecognizer
        ? _recognitionBatchSize
        : 1;
    for (int start = 0; start < order.length; start += batchSize) {
      cancelToken?.throwIfCancelled();
      final int end = (start + batchSize).clamp(0, order.length);
      final List<DetectedTextRegion> regions = <DetectedTextRegion>[
        for (int index = start; index < end; index++)
          detections.textRegions[order[index]],
      ];
      final List<OcrRecognition> recognized = await _recognizeRegions(
        recognizer,
        image,
        regions,
      );
      cancelToken?.throwIfCancelled();
      if (recognized.length != regions.length) {
        throw StateError(
          'OCR batch returned ${recognized.length} results '
          'for ${regions.length} regions',
        );
      }
      for (int i = 0; i < regions.length; i++) {
        final OcrRecognition recognition = recognized[i];
        final String text = recognition.text;
        if (text.isEmpty) {
          continue;
        }
        final DetectedTextRegion region = regions[i];
        blocks.add(
          _blockFromRecognition(
            recognition,
            box: region.rect,
            score: region.score,
            insideBubble: region.insideBubble,
            confidence: recognition.confidence,
          ),
        );
      }
    }
    return OcrPageResult(
      pageIndex: pageIndex,
      imageWidth: image.width,
      imageHeight: image.height,
      blocks: await _withSweptBlocks(
        image,
        _finishRecognizedBlocks(blocks),
        candidates: detections.weakTextRegions,
        // 识别为空的检测框也算覆盖：检测器认过、识别器读不出的地方，补检再读一遍
        // 多半也是同一团笔触。
        covered: boxes,
        cancelToken: cancelToken,
      ),
    );
  }

  /// 有补检器时把补回的块并进来，再按全部块重排阅读序；没补到块时原样返回。
  Future<List<OcrBlock>> _withSweptBlocks(
    img.Image image,
    List<OcrBlock> blocks, {
    required List<DetectedTextRegion> candidates,
    required List<OcrRect> covered,
    OcrCancelToken? cancelToken,
  }) async {
    final OcrPageTextSweeper? sweeper = _sweeper;
    if (sweeper == null || candidates.isEmpty) return blocks;
    cancelToken?.throwIfCancelled();
    final List<OcrBlock> swept = await sweeper.sweep(
      image,
      candidates: candidates,
      covered: covered,
    );
    if (swept.isEmpty) return blocks;
    final List<OcrBlock> all = <OcrBlock>[...blocks, ...swept];
    return <OcrBlock>[
      for (final int index in computeReadingOrder(<OcrRect>[
        for (final OcrBlock block in all) block.box,
      ], rightToLeft: rightToLeft))
        all[index],
    ];
  }

  /// 块方向只有一个拥有者：识别器定了（[OrientedOcrRecognizer]）就用它的，
  /// 否则按检测框外形（[isVerticalBlock]）兜底（BUG-2783）。
  static Future<List<OcrRecognition>> _recognizeRegions(
    OcrRecognizer recognizer,
    img.Image image,
    List<DetectedTextRegion> regions,
  ) async {
    final List<OcrRect> boxes = <OcrRect>[
      for (final DetectedTextRegion region in regions) region.rect,
    ];
    if (recognizer is OrientedOcrRecognizer) {
      return recognizer.recognizeOriented(image, boxes);
    }
    if (recognizer is ScoredOcrRecognizer &&
        recognizer is! BatchOcrRecognizer) {
      final ScoredOcrText scored = await recognizer.recognizeScored(
        image,
        boxes.single,
      );
      return <OcrRecognition>[
        OcrRecognition(
          text: scored.text,
          vertical: isVerticalBlock(boxes.single),
          confidence: scored.confidence,
        ),
      ];
    }
    final List<String> texts = recognizer is BatchOcrRecognizer
        ? await recognizer.recognizeBatch(image, boxes)
        : <String>[await recognizer.recognize(image, boxes.single)];
    if (texts.length != boxes.length) {
      throw StateError(
        'OCR batch returned ${texts.length} results '
        'for ${boxes.length} regions',
      );
    }
    return <OcrRecognition>[
      for (int i = 0; i < boxes.length; i++)
        OcrRecognition(text: texts[i], vertical: isVerticalBlock(boxes[i])),
    ];
  }
}
