import 'dart:async';

import 'package:fushi/src/ocr/ocr_inference.dart';

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

  /// 删除已下载模型，释放磁盘；返回**实际释放的字节数**。
  ///
  /// 返回值不是「清单总和」这种推算值，而是删除前模型目录的真实递归占用，
  /// 因此把未完成的 `.part`、旧清单遗留档一并计入——用户看到的释放量与磁盘
  /// 实际变化一致（BUG-1732）。
  Future<int> deleteModels();

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
    required this.diskBytes,
    required this.totalBytes,
  });

  final bool detectorReady;
  final bool recognizerReady;

  /// 模型目录的**真实递归占用**字节数。
  ///
  /// BUG-1732：这里以前叫 `downloadedBytes`，只累加清单里列出且已就绪的文件——
  /// 于是「设置页显示 450 MB」与「删掉后磁盘少了多少」是两个数：中断留下的
  /// `.part`、上游换档后遗留的旧模型档都不在清单里，用户既看不到也不知道能删。
  /// 真相源只能是磁盘本身，故改为按目录实际大小记账。
  final int diskBytes;

  /// 全套模型的预期总字节数（清单常量之和，用于展示「需要下多少」）。
  final int totalBytes;

  bool get allReady => detectorReady && recognizerReady;

  /// 磁盘上是否还留着任何模型文件（含未完成的 `.part` 与遗留档）。
  ///
  /// 与 [allReady] 分开：非本地引擎下「模型不全但仍占着几百 MB」必须能被看见、
  /// 能被删，否则用户永远找不到那块空间。
  bool get hasAnyFiles => diskBytes > 0;
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

/// 一次本地整卷 OCR 实际生效的推理加速状态。
///
/// BUG-1163：GPU EP 被插件拒绝时实现会静默重建 CPU 会话，用户在耗时的整卷
/// OCR 上完全看不出自己在跑 CPU。这个值对象是把那条降级路径抬到接口面上的
/// 唯一载体——它随每个 [MangaOcrVolumeEvent] 一起回传，UI 必须展示。
///
/// 注意 [degraded] 只表示**非预期**降级（EP 被拒 / EP 探测失败）。按平台策略
/// 本来就该走 CPU 的组合（例如 Windows 无 CUDA 时识别模型走 CPU）不算降级。
class MangaOcrAcceleration {
  const MangaOcrAcceleration({
    required this.detection,
    required this.recognition,
    this.degradeReasons = const <String>[],
  });

  /// 检测模型实际生效的执行后端。
  final OcrExecutionProvider detection;

  /// 识别模型（encoder/decoder）实际生效的执行后端。
  final OcrExecutionProvider recognition;

  /// 非空表示发生过非预期降级，逐条给出原因（EP 拒绝码 / 探测异常）。
  final List<String> degradeReasons;

  bool get degraded => degradeReasons.isNotEmpty;

  /// 展示用短标签：两个模型同后端时只显示一个。
  String get label => detection == recognition
      ? detection.name.toUpperCase()
      : '${detection.name.toUpperCase()}/${recognition.name.toUpperCase()}';

  @override
  String toString() => degraded
      ? 'MangaOcrAcceleration($label, degraded: ${degradeReasons.join('; ')})'
      : 'MangaOcrAcceleration($label)';
}

/// 整卷 OCR 进度事件。
class MangaOcrVolumeEvent {
  const MangaOcrVolumeEvent.page({
    required this.pagesDone,
    required this.pagesTotal,
    this.acceleration,
  })  : mangaJsonPath = null,
        finished = false;

  const MangaOcrVolumeEvent.finished({
    required this.pagesTotal,
    required String this.mangaJsonPath,
    this.acceleration,
  })  : pagesDone = pagesTotal,
        finished = true;

  final int pagesDone;
  final int pagesTotal;

  /// finished 事件携带产出的 manga.json 绝对路径。
  final String? mangaJsonPath;
  final bool finished;

  /// 本次任务实际生效的推理加速状态；null = 该引擎不做本地推理（云端/远端）。
  final MangaOcrAcceleration? acceleration;
}
