import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:material_ui/material_ui.dart';

class _ReadyService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 1,
    totalBytes: 1,
    obtainedBytes: 1,
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
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

Widget _reduceMotion(BuildContext context, Widget? child) => MediaQuery(
  data: MediaQuery.of(context).copyWith(disableAnimations: true),
  child: child!,
);

void main() {
  const ValueKey<String> rowKey = ValueKey<String>('manga_ocr_ignore_furigana');

  Future<AdaptiveSettingsSwitchRow> pumpRow(
    WidgetTester tester,
    MangaOcrLocalModel model, {
    required bool stored,
    required List<bool> writes,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            builder: _reduceMotion,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MangaOcrSettingsSection(
                  service: _ReadyService(),
                  mokuroPathGetter: () => '',
                  mokuroPathSetter: (String _) async {},
                  probeExternal: (String _) async => null,
                  enginePreferenceGetter: () => 'local_onnx',
                  localModelGetter: () => model.key,
                  localModelSetter: (String _) async {},
                  ignoreFuriganaGetter: () => stored,
                  ignoreFuriganaSetter: (bool value) async => writes.add(value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.widget<AdaptiveSettingsSwitchRow>(find.byKey(rowKey));
  }

  testWidgets(
    'per-column models: the switch works and shows the stored value',
    (WidgetTester tester) async {
      final List<bool> writes = <bool>[];
      final AdaptiveSettingsSwitchRow row = await pumpRow(
        tester,
        MangaOcrLocalModel.mangaCtc,
        stored: false,
        writes: writes,
      );
      expect(row.value, isFalse);
      expect(row.subtitle, t.manga_ocr_ignore_furigana_desc);
      expect(row.onChanged, isNotNull);
      row.onChanged!(true);
      await tester.pumpAndSettle();
      expect(writes, <bool>[true]);
    },
  );

  for (final MangaOcrLocalModel model in <MangaOcrLocalModel>[
    MangaOcrLocalModel.charspotSmall,
    MangaOcrLocalModel.charspotNano,
    MangaOcrLocalModel.narSmall,
  ]) {
    testWidgets(
      '${model.key} skips furigana itself: the switch is on and not operable',
      (WidgetTester tester) async {
        final List<bool> writes = <bool>[];
        final AdaptiveSettingsSwitchRow row = await pumpRow(
          tester,
          model,
          stored: false,
          writes: writes,
        );
        expect(model.generation.recognizer.honoursIgnoreFurigana, isFalse);
        expect(row.value, isTrue, reason: 'furigana is in fact left out');
        expect(row.onChanged, isNull);
        expect(row.subtitle, t.manga_ocr_ignore_furigana_model_skips_desc);
        expect(writes, isEmpty, reason: 'the stored preference is untouched');
      },
    );
  }
}
