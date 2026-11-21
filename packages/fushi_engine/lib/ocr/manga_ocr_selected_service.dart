import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// Long-lived hosts select the current local model for each new operation.
/// A stream captures its service before subscription so an in-flight job never
/// changes models when the user changes their preference.
class SelectedMangaOcrService implements MangaOcrService {
  SelectedMangaOcrService(this._select);
  final MangaOcrService Function() _select;

  @override
  bool get isSupportedPlatform => _select().isSupportedPlatform;

  @override
  Future<MangaOcrModelStatus> modelStatus() => _select().modelStatus();

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => _select().downloadModels();

  @override
  Future<int> deleteModels() => _select().deleteModels();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => _select().ocrFolder(
    imageDirPath: imageDirPath,
    volumeTitle: volumeTitle,
    startPage: startPage,
  );

  /// 当前选中模型的整卷引擎签名（见 [MangaOcrEngineSignatureSource]）；选中的服务
  /// 报不出签名时为 null。不把本类声明成签名源：被包的服务未必是。
  Future<String?> resolveEngineSignature() async {
    final MangaOcrService selected = _select();
    return selected is MangaOcrEngineSignatureSource
        ? (selected as MangaOcrEngineSignatureSource).resolveEngineSignature()
        : null;
  }
}

/// [service] 整卷任务此刻会用的引擎签名；报不出时为 null（调用方不做按签名分区的
/// 事，比如互联 host 的内容去重）。
Future<String?> resolveMangaOcrEngineSignature(MangaOcrService service) async {
  if (service is MangaOcrEngineSignatureSource) {
    return (service as MangaOcrEngineSignatureSource).resolveEngineSignature();
  }
  if (service is SelectedMangaOcrService) {
    return service.resolveEngineSignature();
  }
  return null;
}
