import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// Long-lived hosts select the current local model for each new operation.
/// A stream captures its service before subscription so an in-flight job never
/// changes models when the user changes their preference.
class SelectedMangaOcrService
    implements MangaOcrService, MangaOcrModelPreparationService {
  SelectedMangaOcrService(this._select);
  final MangaOcrService Function() _select;

  @override
  bool get isSupportedPlatform => _select().isSupportedPlatform;

  @override
  Future<MangaOcrModelStatus> modelStatus() => _select().modelStatus();

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => _select().downloadModels();

  @override
  Stream<MangaOcrDownloadEvent> prepareModels() {
    final MangaOcrService selected = _select();
    return selected is MangaOcrModelPreparationService
        ? (selected as MangaOcrModelPreparationService).prepareModels()
        : const Stream<MangaOcrDownloadEvent>.empty();
  }

  @override
  Future<int> deleteModels() => _select().deleteModels();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      _select().ocrFolder(imageDirPath: imageDirPath, volumeTitle: volumeTitle);
}
