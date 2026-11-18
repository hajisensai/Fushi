/// 直读章「边看边识别」的值类型与识别器接口：引擎解析结局、单页 / 文字图识别器、
/// 大模型重读段。
///
/// 从 `manga_reader_stream_ocr.dart` 拆出：那边解析引擎要读 AppModel 的 OCR 设置，
/// 而视频图形字幕 OCR（`graphic_subtitle_ocr.dart`）只用这些类型、引擎由调用方注入，
/// 直接 import 那边会把视频播放控制器整串拖进 AppModel 的 import 大环
/// （`import_cycle_guard_test.dart`）。这个文件只依赖 fushi_engine，不许 import AppModel 一侧。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart'
    show MangaOcrEngineId;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 读者当前页之后还要预先识别几页（双页展开时第二页也在眼前）。
const int kMangaStreamOcrLookahead = 2;

/// 识别一张已落盘的直读页图。
abstract interface class MangaStreamPageRecognizer {
  Future<MokuroImage> recognize(File pageFile);

  /// 释放常驻资源（本地 ONNX 的页会话 isolate）；幂等。
  Future<void> close();
}

/// 识别器的可选能力：直接识别一张已裁好的文字图（字幕位图），不走漫画整页管线
/// （检测器 / 补检 / PNG 落盘 / 逐页缓存）。可同时在途 [parallelism] 个请求。
abstract interface class MangaStreamTextImageRecognizer {
  int get parallelism;

  /// [rgba] 为 [width]×[height]×4 字节的不透明 RGBA 像素。
  Future<OcrRecognition> recognizeTextImage(
    Uint8List rgba, {
    required int width,
    required int height,
  });
}

/// 文字图识别并行开几个会话：每个会话一个 isolate、每会话 ORT 2 线程
/// （`planOcrAcceleration`），按核数留出播放与界面的余量，最多 3 个。
int defaultMangaStreamTextImageParallelism([int? processors]) =>
    ((processors ?? Platform.numberOfProcessors) ~/ 4).clamp(1, 3);

/// [prepareMangaStreamOcr] 的结局。
sealed class MangaStreamOcrSetup {
  const MangaStreamOcrSetup();
}

final class MangaStreamOcrReady extends MangaStreamOcrSetup {
  const MangaStreamOcrReady(this.engine, this.recognizer, {this.ai});

  final MangaOcrEngineId engine;
  final MangaStreamPageRecognizer recognizer;

  /// 设置里开了大模型识别时的第二段（[MangaStreamPageOcr.ai]）；null = 不经大模型。
  final MangaStreamAiRefinement? ai;
}

/// 没有可用引擎（与整卷路径同一判据）。
final class MangaStreamOcrNoEngine extends MangaStreamOcrSetup {
  const MangaStreamOcrNoEngine();
}

/// 解析到 Google Lens，但用户没同意上传。
final class MangaStreamOcrLensDeclined extends MangaStreamOcrSetup {
  const MangaStreamOcrLensDeclined();
}

/// 解析到的引擎只会整卷跑（外部 mokuro CLI / 已配对主机）：直读章不识别，
/// 下载后照常由整卷任务处理。
final class MangaStreamOcrUnsupported extends MangaStreamOcrSetup {
  const MangaStreamOcrUnsupported();
}

/// 直读章的大模型第二段：本地结果已经交给读者之后，再把该页的块交给
/// [MangaAiOcrRefiner] 重读。
///
/// 不套在识别器里：那样本地结果要等大模型全部批次（每批最长 90 秒、可重试错误
/// 还会继续下一批）才交出，读者眼前这页长时间没有文字层，后面的页也一起排队。
class MangaStreamAiRefinement {
  MangaStreamAiRefinement({
    required MangaAiOcrRefiner refiner,
    MangaAiOcrCache? cache,
  }) : _refiner = refiner,
       _cache = cache;

  final MangaAiOcrRefiner _refiner;
  final MangaAiOcrCache? _cache;

  /// 重读 [local]；没换成任何块（含失败、已取消）返回 null，读者保留本地结果。
  Future<MokuroImage?> refine(MokuroImage local, File pageFile) async {
    final Uint8List bytes = await pageFile.readAsBytes();
    final ({MokuroImage page, MangaAiOcrPageStats stats}) result =
        await _refiner.refinePage(local, bytes, cache: _cache);
    return result.stats.replaced == 0 ? null : result.page;
  }

  /// 这个块要不要送大模型（按用户选的档位）。
  bool wants(MokuroBlock block) => _refiner.wants(block);

  /// 跨页批量重读一批已裁好的文字图（字幕整轨用）：与 [refine] 同一缓存、同一
  /// 校验；返回与 [items] 等长的新文字（null = 不换）。可并发调用。
  /// [nearby]：附近已读文字（前几条台词），只作消歧提示。
  Future<List<String?>> refineCrops(
    List<MangaAiOcrCropRequest> items, {
    List<String> nearby = const <String>[],
  }) => _refiner.refineCrops(items, cache: _cache, nearby: nearby);

  /// 中止在途请求、释放常驻 HTTP 客户端，此后不再发请求。
  void cancel() => _refiner.dispose();

  /// 给用户看的重读来源：供应商名 · 模型（模型空则只有供应商名）。
  String get providerLabel {
    final String model = _refiner.provider.model.trim();
    final String name = _refiner.provider.name.trim();
    return model.isEmpty ? name : '$name · $model';
  }
}
