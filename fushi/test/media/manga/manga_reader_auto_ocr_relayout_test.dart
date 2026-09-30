import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_auto_ocr.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 本地模型已就绪的服务替身；整卷任务本体由 buildEvents 替身接管，不会被调用。
class _ReadyLocalService extends MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 0,
    totalBytes: 0,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => throw StateError('buildEvents stub owns the job');
}

/// BUG-2813：已识别本地卷的「只补行几何」升级只能交给本地引擎——偏好解析到别的
/// 引擎时什么都不排、也绝不弹 Google Lens 上传同意框。
void main() {
  Future<MangaReaderVolumeOcrOutcome> start({
    required MangaOcrEnginePreference preference,
    required List<MangaOcrJobSpec> built,
    required List<bool> lensAsked,
    required MangaOcrJobRegistry registry,
  }) => startMangaReaderVolumeOcr(
    bookKey: 'book',
    imageDirPath: 'vol',
    mangaJsonPath: 'vol/manga.json',
    volumeTitle: 'vol',
    startPage: 0,
    engines: MangaOcrWizardEngines(service: _ReadyLocalService()),
    registry: registry,
    preference: preference,
    lensLanguage: 'ja',
    confirmLensUpload: () async {
      lensAsked.add(true);
      return true;
    },
    requiredEngine: MangaOcrEngineId.localOnnx,
    buildEvents: (MangaOcrJobSpec spec) {
      built.add(spec);
      return const Stream<MangaOcrBackgroundEvent>.empty();
    },
  );

  test('偏好是 Google Lens：不排任务、不问上传', () async {
    final List<MangaOcrJobSpec> built = <MangaOcrJobSpec>[];
    final List<bool> lensAsked = <bool>[];
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final MangaReaderVolumeOcrOutcome outcome = await start(
      preference: MangaOcrEnginePreference.googleLens,
      built: built,
      lensAsked: lensAsked,
      registry: registry,
    );
    expect(outcome, isA<MangaReaderVolumeOcrNotApplicable>());
    expect(built, isEmpty);
    expect(lensAsked, isEmpty);
    expect(registry.queuedDirectories('book'), isEmpty);
    expect(registry.running('book'), isNull);
  });

  test('偏好是本地 ONNX：排一个本地整卷任务', () async {
    final List<MangaOcrJobSpec> built = <MangaOcrJobSpec>[];
    final List<bool> lensAsked = <bool>[];
    final MangaReaderVolumeOcrOutcome outcome = await start(
      preference: MangaOcrEnginePreference.localOnnx,
      built: built,
      lensAsked: lensAsked,
      registry: MangaOcrJobRegistry(),
    );
    expect(outcome, isA<MangaReaderVolumeOcrQueued>());
    expect(built.single.engine, MangaOcrEngineId.localOnnx);
    expect(lensAsked, isEmpty);
  });
}
