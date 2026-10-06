import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_models_storage_section.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

class _FakeService implements MangaOcrService {
  _FakeService({this.ready = false, this.diskBytes = 0});

  bool ready;
  int diskBytes;
  int deleteCalls = 0;
  final StreamController<MangaOcrDownloadEvent> events =
      StreamController<MangaOcrDownloadEvent>();

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
    detectorReady: ready,
    recognizerReady: ready,
    diskBytes: diskBytes,
    totalBytes: 4096,
    obtainedBytes: ready ? 4096 : 0,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    yield* events.stream;
    ready = true;
    diskBytes = 4096;
  }

  @override
  Future<int> deleteModels() async {
    deleteCalls++;
    final int freed = diskBytes;
    ready = false;
    diskBytes = 0;
    return freed;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

void main() {
  late ProviderContainer container;
  late Map<MangaOcrLocalModel, _FakeService> services;

  setUp(() {
    container = ProviderContainer();
    services = <MangaOcrLocalModel, _FakeService>{
      MangaOcrLocalModel.baberu: _FakeService(ready: true, diskBytes: 4096),
      MangaOcrLocalModel.mangaCtc: _FakeService(),
    };
  });

  tearDown(() {
    container.dispose();
    for (final _FakeService service in services.values) {
      if (!service.events.isClosed) unawaited(service.events.close());
    }
  });

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MangaOcrModelsStorageSection(
                  models: services.keys.toList(),
                  serviceFor: (MangaOcrLocalModel model) => services[model]!,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists every model with its own status and actions', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester);
    for (final MangaOcrLocalModel model in services.keys) {
      expect(
        find.byKey(ValueKey<String>('ocr-models-row-${model.key}')),
        findsOneWidget,
      );
      expect(find.text(localModelLabel(model)), findsOneWidget);
    }
    // 就绪的给删除，未下载的给下载。
    expect(
      find.byKey(const ValueKey<String>('ocr-models-delete-baberu')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('ocr-models-download-manga_ctc')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('ocr-models-delete-manga_ctc')),
      findsNothing,
    );
  });

  testWidgets('download goes through the shared background registry', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('ocr-models-download-manga_ctc')),
    );
    await tester.pump();
    final MangaOcrModelDownloads downloads = container.read(
      mangaOcrModelDownloadsProvider,
    );
    expect(downloads.isActive(MangaOcrLocalModel.mangaCtc), isTrue);
    expect(
      find.byKey(const ValueKey<String>('ocr-models-cancel-manga_ctc')),
      findsOneWidget,
    );

    // 离开存储页，下载照跑。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    expect(downloads.isActive(MangaOcrLocalModel.mangaCtc), isTrue);
    await services[MangaOcrLocalModel.mangaCtc]!.events.close();
    await tester.pump();
    expect(downloads.isActive(MangaOcrLocalModel.mangaCtc), isFalse);

    await pumpSection(tester);
    expect(
      find.byKey(const ValueKey<String>('ocr-models-delete-manga_ctc')),
      findsOneWidget,
    );
  });

  testWidgets('delete uses the service primitive after confirmation', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('ocr-models-delete-baberu')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_delete));
    await tester.pumpAndSettle();
    expect(services[MangaOcrLocalModel.baberu]!.deleteCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('ocr-models-download-baberu')),
      findsOneWidget,
    );
  });
}
