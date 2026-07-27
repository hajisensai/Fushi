/// 漫画整卷 OCR 流水线：逐页 检测 → 排序 → 逐框识别，带逐页断点缓存、
/// 进度回调与取消令牌。
///
/// 缓存语义对齐 mokuro 的 `_ocr/` 目录：**一页一条结果**，页子任务完成即
/// 落缓存；中断重跑只补未完成页。缓存后端（文件/DB）由调用方实现
/// [OcrPageCache]，本层只依赖接口。
library;

import 'package:image/image.dart' as img;

import 'package:hibiki/src/ocr/ocr_types.dart';
import 'package:hibiki/src/ocr/reading_order.dart';

/// 逐页断点缓存接口。key = (bookId, pageIndex)。
abstract interface class OcrPageCache {
  Future<OcrPageResult?> read(String bookId, int pageIndex);
  Future<void> write(String bookId, OcrPageResult result);
}

/// 取消令牌：置位后流水线在下一个安全点（页间/块间）抛
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

bool isVerticalBlock(OcrRect box) =>
    box.height > box.width * kVerticalAspectThreshold;

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

  /// 处理单页：检测 → 阅读顺序 → 逐框识别。
  Future<OcrPageResult> processPage({
    required int pageIndex,
    required img.Image image,
    OcrCancelToken? cancelToken,
  }) async {
    final PageDetections detections = await _detector.detect(image);
    final List<OcrRect> boxes = <OcrRect>[
      for (final DetectedTextRegion region in detections.textRegions)
        region.rect,
    ];
    final List<int> order =
        computeReadingOrder(boxes, rightToLeft: rightToLeft);

    final List<OcrBlock> blocks = <OcrBlock>[];
    for (final int index in order) {
      cancelToken?.throwIfCancelled();
      final DetectedTextRegion region = detections.textRegions[index];
      final String text = await _recognizer.recognize(image, region.rect);
      if (text.isEmpty) {
        continue;
      }
      blocks.add(OcrBlock(
        box: region.rect,
        vertical: isVerticalBlock(region.rect),
        lines: <String>[text],
        score: region.score,
        insideBubble: region.insideBubble,
      ));
    }
    return OcrPageResult(
      pageIndex: pageIndex,
      imageWidth: image.width,
      imageHeight: image.height,
      blocks: blocks,
    );
  }
}
