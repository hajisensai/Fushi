import 'dart:async';

/// 漫画整卷 OCR 服务的稳定接口（设计 docs/specs/2026-07-24-manga-ocr-design.md §5.3 生产者 B）。
///
/// UI 层（设置页 / OCR 导入向导）只依赖本接口；真实实现（ONNX 流水线 +
/// 模型下载管理）在 [manga_ocr_service_impl.dart]，测试用 fake 实现。
/// 取消语义：取消 Stream 订阅即请求中止；实现方须在页边界尽快停止并
/// 保留逐页断点缓存（重跑只补缺页）。
abstract class MangaOcrService {
  /// 当前平台是否支持内置 OCR（P2 先桌面；移动端待 P4 真机基准）。
  bool get isSupportedPlatform;

  /// 模型就绪状态与磁盘占用。
  Future<MangaOcrModelStatus> modelStatus();

  /// 按需下载全部模型文件（检测器 + 识别 encoder/decoder + vocab）。
  /// 事件按文件粒度报告字节进度；出错以 error 事件结束流。
  Stream<MangaOcrDownloadEvent> downloadModels();

  /// 删除已下载模型，释放磁盘。
  Future<void> deleteModels();

  /// 对一个裸图片目录跑整卷 OCR，产出内部 manga.json（不落库；落库由
  /// 导入器接手）。事件：逐页完成进度 → 最终 [MangaOcrVolumeEvent.finished]
  /// 携带 manga.json 绝对路径。
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  });
}

/// 模型就绪状态。
class MangaOcrModelStatus {
  const MangaOcrModelStatus({
    required this.detectorReady,
    required this.recognizerReady,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final bool detectorReady;
  final bool recognizerReady;

  /// 已就绪文件的磁盘字节数。
  final int downloadedBytes;

  /// 全套模型的预期总字节数（用于设置页展示体积）。
  final int totalBytes;

  bool get allReady => detectorReady && recognizerReady;
}

/// 模型下载进度事件。
class MangaOcrDownloadEvent {
  const MangaOcrDownloadEvent({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    this.done = false,
  });

  final String fileName;
  final int receivedBytes;
  final int totalBytes;

  /// 全部文件完成时最后发一次 done=true。
  final bool done;
}

/// 整卷 OCR 进度事件。
class MangaOcrVolumeEvent {
  const MangaOcrVolumeEvent.page({
    required this.pagesDone,
    required this.pagesTotal,
  })  : mangaJsonPath = null,
        finished = false;

  const MangaOcrVolumeEvent.finished({
    required this.pagesTotal,
    required String this.mangaJsonPath,
  })  : pagesDone = pagesTotal,
        finished = true;

  final int pagesDone;
  final int pagesTotal;

  /// finished 事件携带产出的 manga.json 绝对路径。
  final String? mangaJsonPath;
  final bool finished;
}
