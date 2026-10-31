// 漫画阅读器快捷设置「错开一页」（跨页偏移）：紧挨单双页，切换后把
// `spreadOffset` 补丁交给页面（落本书覆盖并立即重排）；条漫下没有配对可错开，禁用。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_quick_settings_sheet.dart';
import 'package:material_ui/material_ui.dart';

const Key _shiftKey = ValueKey<String>('manga_quick_spread_shift');

Future<List<Map<String, Object?>>> _pump(
  WidgetTester tester, {
  required MangaReaderPreferences prefs,
  required MangaReadingMode mode,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<Map<String, Object?>> patches = <Map<String, Object?>>[];
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MangaReaderQuickSettingsSheet(
            preferences: prefs,
            currentMode: mode,
            spreadPreference: MangaSpreadPreference.auto,
            onSpreadPreferenceChanged: (_) {},
            onPatch: (Map<String, Object?> patch) async => patches.add(patch),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return patches;
}

bool _switchValue(WidgetTester tester) => tester
    .widget<Switch>(
      find.descendant(of: find.byKey(_shiftKey), matching: find.byType(Switch)),
    )
    .value;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('翻页布局：开关显示全局默认值，切换写 spreadOffset 补丁', (
    WidgetTester tester,
  ) async {
    final List<Map<String, Object?>> patches = await _pump(
      tester,
      prefs: const MangaReaderPreferences(),
      mode: MangaReadingMode.spread,
    );
    expect(find.text(t.manga_quick_spread_shift), findsOneWidget);
    expect(_switchValue(tester), isTrue, reason: '默认偏移 1 = 开');

    await tester.tap(find.byKey(_shiftKey));
    await tester.pumpAndSettle();
    expect(patches, <Map<String, Object?>>[
      <String, Object?>{'spreadOffset': 0},
    ]);
    expect(_switchValue(tester), isFalse, reason: '乐观状态立即反映');
  });

  testWidgets('条漫布局：开关禁用，点了不产生补丁', (WidgetTester tester) async {
    final List<Map<String, Object?>> patches = await _pump(
      tester,
      prefs: const MangaReaderPreferences(),
      mode: MangaReadingMode.webtoon,
    );
    await tester.tap(find.byKey(_shiftKey));
    await tester.pumpAndSettle();
    expect(patches, isEmpty);
  });
}
