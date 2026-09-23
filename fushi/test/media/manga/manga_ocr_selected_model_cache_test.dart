import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _SelectedModelService implements MangaOcrService, MangaOcrPageService {
  _SelectedModelService(this.cachePath);
  final String cachePath;
  int jobs = 0;

  @override
  bool get isSupportedPlatform => true;
  @override
  Future<String> resolvePageCacheDirPath({
    required String imageDirPath,
  }) async => cachePath;
  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) async* {
    jobs++;
  }

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
  Future<MangaOcrPageSession> openPageSession({
    required String imageDirPath,
    void Function(MangaOcrAcceleration)? onAcceleration,
  }) async => throw StateError('not used by volume cache recovery');
}

void main() {
  test(
    'selected service cache is used for replay and re-recognition',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'ocr_selected_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final File page = File(p.join(dir.path, '001.png'))
        ..writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
      final Directory selected = Directory(
        p.join(
          dir.path,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          'selected-model-fingerprint',
        ),
      );
      final Directory other = Directory(p.join(selected.parent.path, 'classic'))
        ..createSync(recursive: true);
      final File unrelated = File(p.join(other.path, 'keep.json'))
        ..writeAsStringSync('{}');
      final MangaOcrFilePageCache cache = MangaOcrFilePageCache(
        cacheDir: selected,
        pageNames: <String>['001.png'],
        pageFiles: <File>[page],
      );
      await cache.write(
        'manga_ocr',
        const OcrPageResult(
          pageIndex: 0,
          imageWidth: 4,
          imageHeight: 4,
          blocks: <OcrBlock>[
            OcrBlock(
              box: OcrRect(left: 0, top: 0, right: 4, bottom: 4),
              vertical: true,
              lines: <String>['選択中のモデル'],
            ),
          ],
        ),
      );
      final _SelectedModelService service = _SelectedModelService(
        selected.path,
      );
      MangaOcrJobSpec spec(bool onlyMissing) => MangaOcrJobSpec(
        engine: MangaOcrEngineId.localOnnx,
        engines: MangaOcrWizardEngines(service: service),
        imageDirPath: dir.path,
        lensLanguage: 'ja',
        onlyMissing: onlyMissing,
      );
      final events = await mangaOcrLocalEvents(spec(true)).toList();
      expect(service.jobs, 0, reason: 'must replay the selected model cache');
      expect(events.first.page!.blocks.single.lines, <String>['選択中のモデル']);
      expect(events.last.finished, isTrue);
      await mangaOcrLocalEvents(spec(false)).drain<void>();
      expect(service.jobs, 1);
      expect(selected.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );
}
