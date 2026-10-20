import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_export_options_dialog.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// 「导出（.apkg）」选项对话框：三个开关、FSRS-7 提示、记住上次的选择
/// （所有者 2026-10-20：「导出同理，支持是否兼容 anki 等开关，这些开关都会记忆」）。
void main() {
  Future<BuildContext> pumpHost(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return host;
  }

  Future<Future<SrsAnkiExportOptions?>> open(
    WidgetTester tester,
    BuildContext host, {
    SrsAnkiExportOptions initial = const SrsAnkiExportOptions(),
    bool usesFsrs7 = false,
  }) async {
    final Future<SrsAnkiExportOptions?> result = showSrsExportOptionsDialog(
      context: host,
      initial: initial,
      usesFsrs7: usesFsrs7,
    );
    await tester.pumpAndSettle();
    return result;
  }

  bool switchValue(WidgetTester tester, String key) => tester
      .widget<AdaptiveSettingsSwitchRow>(find.byKey(ValueKey<String>(key)))
      .value;

  Future<void> toggle(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('初值显示；改开关 → 确认返回新值', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 900));
    final Future<SrsAnkiExportOptions?> result = await open(tester, host);
    expect(switchValue(tester, 'srs-export-with-scheduling'), isTrue);
    expect(switchValue(tester, 'srs-export-with-deck-configs'), isTrue);
    expect(switchValue(tester, 'srs-export-anki-compatible'), isFalse);

    await toggle(tester, 'srs-export-with-scheduling');
    await toggle(tester, 'srs-export-anki-compatible');
    await tester.tap(find.byKey(const ValueKey<String>('srs-export-confirm')));
    await tester.pumpAndSettle();
    expect(
      await result,
      const SrsAnkiExportOptions(withScheduling: false, ankiCompatible: true),
    );
  });

  testWidgets('取消返回 null', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 900));
    final Future<SrsAnkiExportOptions?> result = await open(tester, host);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('FSRS-7 提示：只在范围有 FSRS-7 且带预设时出现', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 900));
    final Finder note = find.byKey(
      const ValueKey<String>('srs-export-fsrs7-note'),
    );
    await open(tester, host);
    expect(note, findsNothing);
    Navigator.of(host).pop();
    await tester.pumpAndSettle();

    await open(tester, host, usesFsrs7: true);
    expect(note, findsOneWidget);
    await toggle(tester, 'srs-export-with-deck-configs');
    expect(note, findsNothing, reason: '不带预设时不写 FSRS 参数，提示无意义');
  });

  testWidgets('窄屏（手机）：不溢出、不抛错', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(390, 844));
    await open(tester, host, usesFsrs7: true);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('srs-export-options')),
      findsOneWidget,
    );
  });

  test('记住上次的选择：写进偏好、下次读回；坏值回落默认', () async {
    final _MemoryPrefs prefs = _MemoryPrefs();
    expect(readSrsExportOptions(prefs), const SrsAnkiExportOptions());
    const SrsAnkiExportOptions chosen = SrsAnkiExportOptions(
      withDeckConfigs: false,
      ankiCompatible: true,
    );
    await writeSrsExportOptions(prefs, chosen);
    expect(readSrsExportOptions(prefs), chosen);
    prefs.values[kSrsExportOptionsPrefKey] = '{not json';
    expect(readSrsExportOptions(prefs), const SrsAnkiExportOptions());
  });
}
