import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:path/path.dart' as p;
import '../../helpers/glass_unwrap.dart';

class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({required this.ready});

  bool ready;
  final StreamController<MangaOcrDownloadEvent> downloads =
      StreamController<MangaOcrDownloadEvent>();

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
    detectorReady: ready,
    recognizerReady: ready,
    diskBytes: ready ? 50 : 0,
    totalBytes: 50,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    yield* downloads.stream;
    ready = true;
  }

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

void main() {
  late FushiDatabase db;
  late Directory imageDir;
  late Map<MangaOcrLocalModel, _FakeOcrService> services;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    imageDir = Directory.systemTemp.createTempSync('manga_ocr_wizard_model');
    File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    services = <MangaOcrLocalModel, _FakeOcrService>{
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
        model: _FakeOcrService(ready: false),
    };
  });

  tearDown(() async {
    for (final _FakeOcrService service in services.values) {
      if (!service.downloads.isClosed) unawaited(service.downloads.close());
    }
    await db.close();
    if (imageDir.existsSync()) imageDir.deleteSync(recursive: true);
  });

  testWidgets('local engine downloads the only model without a picker', (
    WidgetTester tester,
  ) async {
    final List<String> storedModels = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: MangaOcrWizardDialog(
                engines: MangaOcrWizardEngines(
                  service: services[MangaOcrLocalModel.mangaCtc]!,
                  initialEnginePreference: 'local_onnx',
                  localModel: MangaOcrLocalModel.mangaCtc,
                  localModelSetter: (String value) async =>
                      storedModels.add(value),
                  modelServiceFor: (MangaOcrLocalModel model) =>
                      services[model]!,
                ),
                db: db,
                initialImageDir: imageDir.path,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 五端都只列得出逐列 CTC 一个模型：只有一个选项的模型下拉不画；选中的
    // 模型没下时下载入口仍在向导里，开跑按钮置灰。
    expect(platformMangaOcrLocalModels(), <MangaOcrLocalModel>[
      MangaOcrLocalModel.mangaCtc,
    ]);
    final Finder modelField = find.byKey(
      const ValueKey<String>('manga_ocr_wizard_local_model'),
    );
    expect(modelField, findsNothing);
    final Finder run = find.widgetWithText(
      FilledButton,
      t.manga_ocr_wizard_run,
    );
    expect(
      tester.widget<FilledButton>(glassUnwrap<FilledButton>(run)).onPressed,
      isNull,
    );
    final Finder download = find.byKey(
      const ValueKey<String>('manga_ocr_wizard_model_download'),
    );
    expect(download, findsOneWidget);

    // 引擎分段在测试字体下折成多行，向导内容区比 800x600 默认窗口高：下载
    // 入口落在可滚动内容区下部、被固定的动作栏盖住，先滚到可见再点。
    await tester.ensureVisible(download);
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('manga_ocr_wizard_model_progress')),
      findsOneWidget,
    );
    await services[MangaOcrLocalModel.mangaCtc]!.downloads.close();
    await tester.pumpAndSettle();
    expect(download, findsNothing);
    expect(
      tester.widget<FilledButton>(glassUnwrap<FilledButton>(run)).onPressed,
      isNotNull,
    );
    // 没有选择器就不会改写模型偏好。
    expect(storedModels, isEmpty);
  });
}
