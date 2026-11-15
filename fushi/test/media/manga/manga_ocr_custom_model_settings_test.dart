import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_models_storage_section.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi_engine/ocr/manga_ocr_custom_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:material_ui/material_ui.dart';

/// Slot fake: the imported model lives in memory; [nextError] fails the next
/// import without touching what is there (like the real atomic import).
class _FakeSlot implements MangaOcrCustomModelSlot {
  MangaOcrCustomModelInfo? info;
  MangaOcrCustomModelImportException? nextError;
  final List<(String, String)> imports = <(String, String)>[];

  @override
  Future<MangaOcrCustomModelInfo?> readInfo() async => info;

  @override
  Future<MangaOcrCustomModelInfo> importModel({
    required String modelPath,
    required String dictPath,
  }) async {
    imports.add((modelPath, dictPath));
    final MangaOcrCustomModelImportException? error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    return info = MangaOcrCustomModelInfo(
      displayName: 'model_${imports.length}',
      dictFormat: PpOcrCharacterDictFormat.paddleYaml,
      sourceModelFileName: 'inference.onnx',
      sourceDictFileName: 'inference.yml',
      modelSha256: 'a' * 64,
      dictSha256: 'b' * 64,
      modelBytes: 1000,
      dictBytes: 100,
      dictEntries: 11945,
      outputClasses: 11947,
      importedAt: DateTime.utc(2026, 11, 14),
    );
  }
}

/// Service fake bound to the slot: ready exactly when something is imported
/// (detectors assumed present).
class _SlotService implements MangaOcrService {
  _SlotService(this.slot);

  final _FakeSlot slot;
  int deleteCalls = 0;
  int downloadCalls = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async {
    final bool imported = slot.info != null;
    return MangaOcrModelStatus(
      detectorReady: true,
      recognizerReady: imported,
      diskBytes: imported ? 22 * 1024 * 1024 : 0,
      totalBytes: 22 * 1024 * 1024,
      obtainedBytes: imported ? 22 * 1024 * 1024 : 0,
    );
  }

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    downloadCalls++;
  }

  @override
  Future<int> deleteModels() async {
    deleteCalls++;
    slot.info = null;
    return 22 * 1024 * 1024;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

Widget _reduceMotion(BuildContext context, Widget? child) => MediaQuery(
  data: MediaQuery.of(context).copyWith(disableAnimations: true),
  child: child!,
);

void main() {
  const ValueKey<String> importKey = ValueKey<String>(
    'manga_ocr_custom_model_import',
  );
  const ValueKey<String> deleteKey = ValueKey<String>(
    'manga_ocr_custom_model_delete',
  );

  Future<void> pumpSection(
    WidgetTester tester, {
    required _FakeSlot slot,
    required _SlotService service,
    required List<bool> picks,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            builder: _reduceMotion,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MangaOcrSettingsSection(
                  service: service,
                  mokuroPathGetter: () => '',
                  mokuroPathSetter: (String _) async {},
                  probeExternal: (String _) async => null,
                  enginePreferenceGetter: () => 'local_onnx',
                  localModelGetter: () => MangaOcrLocalModel.custom.key,
                  localModelSetter: (String _) async {},
                  customModelSlot: slot,
                  pickCustomModelFile: (bool dictionary) async {
                    picks.add(dictionary);
                    return dictionary ? '/dl/inference.yml' : '/dl/model.onnx';
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('custom slot: add, failed replace, replace, delete', (
    WidgetTester tester,
  ) async {
    final _FakeSlot slot = _FakeSlot();
    final _SlotService service = _SlotService(slot);
    final List<bool> picks = <bool>[];
    await pumpSection(tester, slot: slot, service: service, picks: picks);

    // Empty: says so, offers "Add model…", no model download.
    expect(find.text(t.manga_ocr_custom_model_empty_title), findsOneWidget);
    expect(find.text(t.manga_ocr_custom_model_add_button), findsOneWidget);
    expect(find.text(t.manga_ocr_download), findsNothing);
    expect(find.byKey(deleteKey), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('manga_ocr_import_button')),
      findsNothing,
      reason: 'the known-files offline import does not apply to this slot',
    );

    // Add: picks the .onnx first, then the dictionary.
    await tapKey(tester, find.byKey(importKey));
    expect(picks, <bool>[false, true]);
    expect(slot.imports.single, ('/dl/model.onnx', '/dl/inference.yml'));
    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);
    expect(find.textContaining('model_1'), findsOneWidget);
    expect(find.text(t.manga_ocr_custom_model_replace_button), findsOneWidget);
    expect(find.byKey(deleteKey), findsOneWidget);

    // A rejected replace keeps the installed model.
    slot.nextError = const MangaOcrCustomModelImportException(
      MangaOcrCustomModelImportError.classCountMismatch,
      modelClasses: 11947,
      dictEntries: 19053,
    );
    await tapKey(tester, find.byKey(importKey));
    expect(slot.imports, hasLength(2));
    expect(find.textContaining('model_1'), findsOneWidget);
    expect(find.text(t.manga_ocr_model_status_ready), findsOneWidget);

    // A good replace shows the new model.
    await tapKey(tester, find.byKey(importKey));
    expect(slot.imports, hasLength(3));
    expect(find.textContaining('model_3'), findsOneWidget);
    expect(find.textContaining('model_1'), findsNothing);

    // Delete asks first, then empties the slot.
    await tapKey(tester, find.byKey(deleteKey));
    expect(
      find.text(t.manga_ocr_custom_model_delete_confirm_message),
      findsOneWidget,
    );
    await tester.tap(find.text(t.manga_ocr_custom_model_delete_button).last);
    await tester.pumpAndSettle();
    expect(service.deleteCalls, 1);
    expect(find.text(t.manga_ocr_custom_model_empty_title), findsOneWidget);
    expect(service.downloadCalls, 0);
    // Let the toasts time out.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling a picker imports nothing', (
    WidgetTester tester,
  ) async {
    final _FakeSlot slot = _FakeSlot();
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            builder: _reduceMotion,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MangaOcrSettingsSection(
                  service: _SlotService(slot),
                  mokuroPathGetter: () => '',
                  mokuroPathSetter: (String _) async {},
                  probeExternal: (String _) async => null,
                  enginePreferenceGetter: () => 'local_onnx',
                  localModelGetter: () => MangaOcrLocalModel.custom.key,
                  localModelSetter: (String _) async {},
                  customModelSlot: slot,
                  pickCustomModelFile: (bool dictionary) async =>
                      dictionary ? null : '/dl/model.onnx',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, find.byKey(importKey));
    expect(slot.imports, isEmpty);
    expect(find.text(t.manga_ocr_custom_model_empty_title), findsOneWidget);
  });

  testWidgets(
    'storage page: empty slot offers no download, filled one is deletable',
    (WidgetTester tester) async {
      final _FakeSlot slot = _FakeSlot();
      final _SlotService service = _SlotService(slot);
      Future<void> pumpStorage() async {
        await tester.pumpWidget(
          ProviderScope(
            child: TranslationProvider(
              child: MaterialApp(
                builder: _reduceMotion,
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: MangaOcrModelsStorageSection(
                      key: UniqueKey(),
                      serviceFor: (MangaOcrLocalModel _) => service,
                      models: const <MangaOcrLocalModel>[
                        MangaOcrLocalModel.custom,
                      ],
                      customModelSlot: slot,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpStorage();
      expect(
        find.textContaining(t.manga_ocr_custom_model_empty_title),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('ocr-models-download-custom')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('ocr-models-delete-custom')),
        findsNothing,
      );

      await slot.importModel(modelPath: '/dl/a.onnx', dictPath: '/dl/a.yml');
      await pumpStorage();
      expect(
        find.textContaining(t.manga_ocr_model_status_ready),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('ocr-models-delete-custom')),
        findsOneWidget,
      );
    },
  );

  test('every import error has its own message', () {
    final Set<String> messages = <String>{
      for (final MangaOcrCustomModelImportError error
          in MangaOcrCustomModelImportError.values)
        customMangaOcrImportErrorText(
          MangaOcrCustomModelImportException(
            error,
            detail: 'detail',
            modelClasses: 11947,
            dictEntries: 19053,
          ),
        ),
    };
    // modelTooLarge / dictTooLarge share a sentence with different limits.
    expect(messages, hasLength(MangaOcrCustomModelImportError.values.length));
    final String mismatch = customMangaOcrImportErrorText(
      const MangaOcrCustomModelImportException(
        MangaOcrCustomModelImportError.classCountMismatch,
        modelClasses: 11947,
        dictEntries: 19053,
      ),
    );
    expect(mismatch, contains('11945'));
    expect(mismatch, contains('19053'));
    expect(mismatch, contains('7108'));
  });

  test('custom slot has a label and a description saying what it accepts', () {
    expect(
      localModelLabel(MangaOcrLocalModel.custom),
      t.manga_ocr_custom_model_label,
    );
    expect(localModelDescription(MangaOcrLocalModel.custom), contains('ONNX'));
    expect(platformMangaOcrLocalModels(), contains(MangaOcrLocalModel.custom));
  });
}
