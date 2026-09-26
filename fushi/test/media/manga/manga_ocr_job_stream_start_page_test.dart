import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 本地引擎的整卷任务「当前页优先」：阅读器传当前页，识别从它开始、再绕回开头
/// （与 Lens / 系统 OCR 同一口径）。这里钉死两件事：
/// 1. 起点一路传到本地服务；
/// 2. 逐页事件的 pageIndex 是真实页号——阅读器按它热替换文字层，拿完成计数
///    `pagesDone - 1` 猜页号会把第 30 页的结果贴到第 0 页上。
const String _signature = 'test-sig';

class _WidthDetector implements OcrDetector {
  @override
  Future<PageDetections> detect(img.Image page) async => PageDetections(
    textRegions: <DetectedTextRegion>[
      DetectedTextRegion(
        rect: OcrRect(
          left: 0,
          top: 0,
          right: page.width.toDouble(),
          bottom: 10,
        ),
        score: 0.9,
        classId: 0,
        insideBubble: true,
      ),
    ],
    bubbles: const <OcrRect>[],
  );
}

class _WidthRecognizer implements OcrRecognizer {
  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      'w${page.width}';
}

/// 真跑 [runMangaOcrFolderJob] 的本地服务替身：只换掉 ONNX 检测 / 识别。
class _FolderJobService implements MangaOcrService, MangaOcrPageService {
  final List<int> startPages = <int>[];

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
  Future<String> resolvePageCacheDirPath({
    required String imageDirPath,
  }) async => p.join(
    imageDirPath,
    kMangaOcrOutDirName,
    kMangaOcrPagesCacheDirName,
    _signature,
  );

  @override
  Future<MangaOcrPageSession> openPageSession({
    required String imageDirPath,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) => throw UnimplementedError();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) async* {
    startPages.add(startPage);
    final StreamController<MangaOcrVolumeEvent> events =
        StreamController<MangaOcrVolumeEvent>();
    int total = 0;
    unawaited(
      runMangaOcrFolderJob(
            imageDirPath: imageDirPath,
            detector: _WidthDetector(),
            recognizer: _WidthRecognizer(),
            engineSignature: _signature,
            startPage: startPage,
            onProgress: (int done, int pagesTotal, int pageIndex) {
              total = pagesTotal;
              events.add(
                MangaOcrVolumeEvent.page(
                  pagesDone: done,
                  pagesTotal: pagesTotal,
                  pageIndex: pageIndex,
                ),
              );
            },
          )
          .then((String path) {
            events.add(
              MangaOcrVolumeEvent.finished(
                pagesTotal: total,
                mangaJsonPath: path,
              ),
            );
          })
          .whenComplete(events.close),
    );
    yield* events.stream;
  }
}

/// 不按起点重排、也不报页号的旧式实现（远端 / 第三方）。
class _LegacyService extends _FolderJobService {
  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) async* {
    startPages.add(startPage);
    int total = 0;
    final List<MangaOcrVolumeEvent> pageEvents = <MangaOcrVolumeEvent>[];
    final String path = await runMangaOcrFolderJob(
      imageDirPath: imageDirPath,
      detector: _WidthDetector(),
      recognizer: _WidthRecognizer(),
      engineSignature: _signature,
      onProgress: (int done, int pagesTotal, int pageIndex) {
        total = pagesTotal;
        pageEvents.add(
          MangaOcrVolumeEvent.page(pagesDone: done, pagesTotal: pagesTotal),
        );
      },
    );
    yield* Stream<MangaOcrVolumeEvent>.fromIterable(pageEvents);
    yield MangaOcrVolumeEvent.finished(pagesTotal: total, mangaJsonPath: path);
  }
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('manga_ocr_start_page_');
    // 页宽逐页唯一（40/50/60/70），识别文本借页宽定位页。
    for (int i = 0; i < 4; i++) {
      File(p.join(dir.path, 'p${i + 1}.png')).writeAsBytesSync(
        img.encodePng(img.Image(width: 40 + 10 * i, height: 80)),
      );
    }
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MangaOcrJobSpec spec(MangaOcrService service, int startPage) =>
      MangaOcrJobSpec(
        engine: MangaOcrEngineId.localOnnx,
        engines: MangaOcrWizardEngines(service: service),
        imageDirPath: dir.path,
        lensLanguage: 'ja',
        startPage: startPage,
      );

  List<MangaOcrBackgroundEvent> progressOf(
    List<MangaOcrBackgroundEvent> events,
  ) => events.where((MangaOcrBackgroundEvent e) => !e.finished).toList();

  test('本地引擎：起点传到服务，逐页事件带真实页号与该页自己的文字层', () async {
    final _FolderJobService service = _FolderJobService();
    final List<MangaOcrBackgroundEvent> events = await mangaOcrLocalEvents(
      spec(service, 2),
    ).toList();

    expect(service.startPages, <int>[2]);
    final List<MangaOcrBackgroundEvent> progress = progressOf(events);
    expect(
      progress.map((MangaOcrBackgroundEvent e) => e.pageIndex).toList(),
      <int>[2, 3, 0, 1],
    );
    expect(
      progress.map((MangaOcrBackgroundEvent e) => e.pagesDone).toList(),
      <int>[1, 2, 3, 4],
    );
    for (final MangaOcrBackgroundEvent event in progress) {
      final int index = event.pageIndex!;
      expect(event.page!.url, 'p${index + 1}.png');
      expect(event.page!.blocks.single.lines.single, 'w${40 + 10 * index}');
    }
    expect(events.last.finished, isTrue);
  });

  test('整卷已缓存的快路径同样按起点顺序回放', () async {
    final _FolderJobService service = _FolderJobService();
    await mangaOcrLocalEvents(spec(service, 0)).drain<void>();
    service.startPages.clear();

    final List<MangaOcrBackgroundEvent> events = await mangaOcrLocalEvents(
      spec(service, 3),
    ).toList();

    expect(service.startPages, isEmpty, reason: '整卷命中缓存，不应再起任务');
    final List<MangaOcrBackgroundEvent> progress = progressOf(events);
    expect(
      progress.map((MangaOcrBackgroundEvent e) => e.pageIndex).toList(),
      <int>[3, 0, 1, 2],
    );
    for (final MangaOcrBackgroundEvent event in progress) {
      expect(event.page!.url, 'p${event.pageIndex! + 1}.png');
    }
  });

  test('不报页号的实现：退回按完成计数推页号', () async {
    final _LegacyService service = _LegacyService();
    final List<MangaOcrBackgroundEvent> events = await mangaOcrLocalEvents(
      spec(service, 2),
    ).toList();

    final List<MangaOcrBackgroundEvent> progress = progressOf(events);
    expect(
      progress.map((MangaOcrBackgroundEvent e) => e.pageIndex).toList(),
      <int>[0, 1, 2, 3],
    );
    for (final MangaOcrBackgroundEvent event in progress) {
      expect(event.page!.url, 'p${event.pageIndex! + 1}.png');
    }
  });
}
