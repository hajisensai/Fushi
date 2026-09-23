/// 漫画整卷 OCR 流水线：逐页 检测 → 排序 → 单框/批识别，带逐页断点缓存、
/// 进度回调与取消令牌。
///
/// 缓存语义对齐 mokuro 的 `_ocr/` 目录：**一页一条结果**，页子任务完成即
/// 落缓存；中断重跑只补未完成页。缓存后端（文件/DB）由调用方实现
/// [OcrPageCache]，本层只依赖接口。
library;

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

/// 进度回调：completedPages 含缓存命中页。
typedef OcrProgressCallback = void Function(int completedPages, int totalPages);

/// 按页索引懒加载解码好的页面图像（由调用方实现，通常从压缩包/目录读）。
typedef OcrPageLoader = Future<img.Image> Function(int pageIndex);

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

/// 全页识别完成后才判包含重复，允许子框补回父块漏读的小字号正文。
/// 必须逐字包含完整子文本，不折叠空白或标点。横排按识别路由的宽 >= 高
/// 判断，不用展示方向的 1.25 阈值。筛选只删除结果，不改变阅读顺序；父子框
/// 即使分属不同批次或子框先识别，也按同样规则处理。
List<OcrBlock> _suppressRecognizedContainedBlocks(List<OcrBlock> blocks) {
  return blocks.where((OcrBlock child) {
    final OcrRect inner = child.box;
    final String text = child.lines.single;
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
          parent.lines.single.contains(text);
    });
  }).toList();
}

/// 整卷编排器。检测器/识别器经窄接口注入（模型路径、EP 选择在其构造侧）。
class MangaOcrPipeline {
  MangaOcrPipeline({
    required OcrDetector detector,
    required OcrRecognizer recognizer,
    this.cache,
    this.rightToLeft = true,
  })  : _detector = detector,
        _recognizer = recognizer;

  final OcrDetector _detector;
  final OcrRecognizer _recognizer;
  final OcrPageCache? cache;

  /// 阅读方向（日漫 RTL 默认）。
  final bool rightToLeft;

  /// 处理整卷。返回按页序排列的结果（含缓存命中页）。
  ///
  /// 中断（[cancelToken] 置位）抛 [OcrCancelledException]；已完成页已落
  /// 缓存，重跑时只补缺页。
  Future<List<OcrPageResult>> processBook({
    required String bookId,
    required int pageCount,
    required OcrPageLoader loadPage,
    OcrCancelToken? cancelToken,
    OcrProgressCallback? onProgress,
  }) async {
    final List<OcrPageResult> results = <OcrPageResult>[];
    int completed = 0;
    for (int page = 0; page < pageCount; page++) {
      cancelToken?.throwIfCancelled();
      final OcrPageResult? cached = await cache?.read(bookId, page);
      if (cached != null) {
        results.add(cached);
        completed++;
        onProgress?.call(completed, pageCount);
        continue;
      }
      final img.Image image = await loadPage(page);
      final OcrPageResult result = await processPage(
        pageIndex: page,
        image: image,
        cancelToken: cancelToken,
      );
      await cache?.write(bookId, result);
      results.add(result);
      completed++;
      onProgress?.call(completed, pageCount);
    }
    return results;
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
    final List<int> order =
        computeReadingOrder(boxes, rightToLeft: rightToLeft);

    final List<OcrBlock> blocks = <OcrBlock>[];
    final OcrRecognizer recognizer = _recognizer;
    final int batchSize =
        recognizer is BatchOcrRecognizer ? _recognitionBatchSize : 1;
    for (int start = 0; start < order.length; start += batchSize) {
      cancelToken?.throwIfCancelled();
      final int end = (start + batchSize).clamp(0, order.length);
      final List<DetectedTextRegion> regions = <DetectedTextRegion>[
        for (int index = start; index < end; index++)
          detections.textRegions[order[index]],
      ];
      final List<String> texts = recognizer is BatchOcrRecognizer
          ? await recognizer.recognizeBatch(image, <OcrRect>[
              for (final DetectedTextRegion region in regions) region.rect,
            ])
          : <String>[await recognizer.recognize(image, regions.single.rect)];
      cancelToken?.throwIfCancelled();
      if (texts.length != regions.length) {
        throw StateError('OCR batch returned ${texts.length} results '
            'for ${regions.length} regions');
      }
      for (int i = 0; i < regions.length; i++) {
        final String text = texts[i];
        if (text.isEmpty) {
          continue;
        }
        final DetectedTextRegion region = regions[i];
        blocks.add(OcrBlock(
          box: region.rect,
          vertical: isVerticalBlock(region.rect),
          lines: <String>[text],
          score: region.score,
          insideBubble: region.insideBubble,
        ));
      }
    }
    return OcrPageResult(
      pageIndex: pageIndex,
      imageWidth: image.width,
      imageHeight: image.height,
      blocks: _suppressRecognizedContainedBlocks(blocks),
    );
  }
}
