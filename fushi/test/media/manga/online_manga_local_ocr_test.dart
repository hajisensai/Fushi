import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_online_ocr.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_auto_start.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';

void main() {
  test('online pages materialize current-first for offline OCR', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-online-local-ocr-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final Directory sources = Directory(
      '${root.path}${Platform.pathSeparator}source-pages',
    );
    await sources.create(recursive: true);
    final List<File> sourceFiles = <File>[
      for (int index = 0; index < 2; index++)
        await File(
          '${sources.path}${Platform.pathSeparator}$index.jpg',
        ).writeAsBytes(<int>[index + 1]),
    ];
    final _LocalOnlineSession session = _LocalOnlineSession(sourceFiles);
    final Directory imagesDirectory = await materializeOnlineMangaPages(
      session: session,
      managedDirectory: Directory(
        '${root.path}${Platform.pathSeparator}managed',
      ),
      initialPayload: _payload(2),
      startPage: 1,
    );

    expect(
      imagesDirectory
          .listSync()
          .whereType<File>()
          .map((File file) => file.uri.pathSegments.last)
          .where((String name) => name.endsWith('.jpg'))
          .toList()
        ..sort(),
      <String>['page-000001.jpg', 'page-000002.jpg'],
    );
    expect(
      session.localFileRequests,
      <int>[1, 0],
      reason: 'the tapped/current page is materialized first',
    );
  });

  testWidgets('online chapter keeps a ready local ONNX preference', (
    WidgetTester tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final MangaOcrAutoStartResult result =
        await startOnlineMangaOcrWithPreferredEngine(
          context: context,
          bookKey: 'online-book',
          session: _LocalOnlineSession(<File>[File('unused-online-page')]),
          managedDirectory: Directory('unused-online-chapter'),
          initialPayload: _payload(1),
          startPage: 0,
          lensLanguage: 'ja',
          enginesOverride: MangaOcrWizardEngines(
            service: _ReadyLocalOcrService(),
            lensRunner: _UnusedLensRunner(),
            initialEnginePreference: MangaOcrEnginePreference.localOnnx.key,
          ),
          lensDisclosureGate: (BuildContext _) async =>
              throw StateError('local ONNX must not ask for a Lens upload'),
        );

    expect(result.started, isTrue);
    expect(result.engine, MangaOcrEngineId.localOnnx);
  });
}

MokuroPayload _payload(int pages) => MokuroPayload(
  images: <MokuroImage>[
    for (int index = 0; index < pages; index++)
      MokuroImage(
        url: 'page-${(index + 1).toString().padLeft(6, '0')}.jpg',
        size: const Size(1000, 1400),
        blocks: const <MokuroBlock>[],
      ),
  ],
);

class _LocalOnlineSession implements MangaReaderSession {
  _LocalOnlineSession(this.files);

  final List<File> files;
  final List<int> localFileRequests = <int>[];

  @override
  int get pageCount => files.length;

  @override
  Future<MangaPageBytes> page(int index) async => MangaPageBytes(
    bytes: await files[index].readAsBytes(),
    contentType: 'image/jpeg',
  );

  @override
  Future<File?> localFile(int index) async {
    localFileRequests.add(index);
    return files[index];
  }

  @override
  String cacheIdentity(int index) => 'fixture-$index';

  @override
  Future<void> prefetchAround(int index) async {}

  @override
  Future<void> close() async {}
}

class _ReadyLocalOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 100,
    totalBytes: 100,
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
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

class _UnusedLensRunner implements GoogleLensMangaOcrRunner {
  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
  }) => throw StateError('local ONNX must not invoke Google Lens');

  @override
  Future<void> clearCache(String imageDirPath) async {}
}
