import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_page_backdrop.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 「外观 › 页面背景」预设横排：行高随系统字号放大（`_presetRowHeight`）。写死
/// 112 时，2.0 倍字号下两行标签会把每个格子的 Column 撑出这一行（RenderFlex
/// overflow）。这里直接用 schema 里那一项的 builder 渲染真实选择器。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  SettingsCustomItem presetItem() {
    final SettingsDestination destination = buildPageBackdropDestination();
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        if (item.id == 'appearance.page_backdrop.preset') {
          return item as SettingsCustomItem;
        }
      }
    }
    throw StateError('preset picker item missing from the schema');
  }

  for (final double scale in <double>[1.0, 2.0]) {
    testWidgets('preset row does not overflow at text scale $scale', (
      WidgetTester tester,
    ) async {
      final AppModel model = AppModel(testPlatformServices());
      final SettingsCustomItem item = presetItem();
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(800, 600),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Consumer(
                    builder:
                        (BuildContext context, WidgetRef ref, Widget? child) {
                          final SettingsContext settingsContext =
                              SettingsContext(
                                context: context,
                                appModel: model,
                                ref: ref,
                                readerSource: ReaderFushiSource.instance,
                                refresh: () {},
                              );
                          return SingleChildScrollView(
                            child: item.builder(settingsContext),
                          );
                        },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 至少有一个两行标签真的在画（否则这条用例测不到撑高的那种情况）。
      expect(find.text(t.page_backdrop_preset_confetti), findsOneWidget);
    });
  }
}
