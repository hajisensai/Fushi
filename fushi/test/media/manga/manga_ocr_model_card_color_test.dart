import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart' show CustomThemeEntry;
import 'package:fushi/src/media/manga/manga_ocr_settings_section.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

void main() {
  late FushiDatabase database;
  late ThemeNotifier notifier;
  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    notifier = ThemeNotifier(database, () => const TextTheme());
  });
  tearDown(() async {
    notifier.dispose();
    await database.close();
  });
  for (final MangaOcrSettingsPresentation presentation
      in MangaOcrSettingsPresentation.values) {
    testWidgets(
      '${presentation.name}: model card uses its container foreground',
      (WidgetTester tester) async {
        // The real custom-theme editor allows a pinned light surface while the
        // system is dark. Container roles retain the dark brightness palette.
        const CustomThemeEntry entry = CustomThemeEntry(
          id: 'ocr-review',
          name: 'Light surface',
          seed: 0xFF6750A4,
          surfaceColor: 0xFFFFFFFF,
        );
        notifier.loadFromPrefsSnapshot(<String, String>{
          'app_theme_key': PrefCodec.encode('custom-theme:${entry.id}'),
          'custom_themes': PrefCodec.encode(<String>[
            jsonEncode(entry.toJson()),
          ]),
          'selected_custom_theme_id': PrefCodec.encode(entry.id),
          'brightness_mode': PrefCodec.encode('dark'),
        });
        final ThemeData theme = notifier.darkTheme;
        final ColorScheme scheme = theme.colorScheme;
        expect(scheme.surface, Colors.white);
        expect(scheme.onSurface.computeLuminance(), lessThan(0.1));
        expect(scheme.secondaryContainer.computeLuminance(), lessThan(0.1));
        await tester.pumpWidget(
          ProviderScope(
            child: TranslationProvider(
              child: MaterialApp(
                theme: theme,
                builder: (BuildContext context, Widget? child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: MangaOcrSettingsSection(
                      presentation: presentation,
                      service: _MissingModelsService(),
                      mokuroPathGetter: () => '',
                      mokuroPathSetter: (String _) async {},
                      probeExternal: (String _) async => null,
                      enginePreferenceGetter: () => 'local_onnx',
                      systemOcrRunner: _UnavailableSystemOcr(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final Finder cardFinder = find.byKey(
          const ValueKey<String>('manga_ocr_model_card'),
        );
        expect(
          tester.widget<FushiCard>(cardFinder).tone,
          FushiCardTone.secondary,
        );
        final RenderParagraph title = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: cardFinder,
            matching: find.text(t.manga_ocr_model_status_missing),
          ),
        );
        expect(
          title.text.style?.color,
          scheme.onSecondaryContainer,
          reason:
              'secondaryContainer requires its paired foreground; an '
              'explicit outer textTheme color overrides DefaultTextStyle',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _MissingModelsService extends Fake implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: false,
    recognizerReady: false,
    diskBytes: 0,
    totalBytes: 1,
  );
}

class _UnavailableSystemOcr extends Fake implements SystemOcrMangaRunner {
  @override
  Future<bool> isAvailable() async => false;
}
