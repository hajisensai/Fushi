import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_import_options_dialog.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// 「导入 Anki 包」选项对话框：样式（桌面不撑满、宽度合规、窄屏不溢出）、
/// 默认值 = Anki、恢复默认、记住上次的选择（导入选项对齐 Anki）。
/// 对话框的 Material 面（AlertDialog 本身占满路由区，量它没有意义）。
final Finder _dialogSurface = find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

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

  Future<Future<SrsAnkiImportOptions?>> open(
    WidgetTester tester,
    BuildContext host, {
    SrsAnkiImportOptions initial = const SrsAnkiImportOptions(),
    bool wholeCollection = false,
  }) async {
    final Future<SrsAnkiImportOptions?> result = showSrsImportOptionsDialog(
      context: host,
      fileName: 'Japanese Core 2k.apkg',
      initial: initial,
      wholeCollection: wholeCollection,
    );
    await tester.pumpAndSettle();
    return result;
  }

  Future<SrsAnkiImportOptions?> confirm(
    WidgetTester tester,
    Future<SrsAnkiImportOptions?> result,
  ) async {
    await tester.tap(find.byKey(const ValueKey<String>('srs-import-confirm')));
    await tester.pumpAndSettle();
    return result;
  }

  bool resetEnabled(WidgetTester tester, String rowKey) => tester
      .widget<FushiIconButton>(
        find.descendant(
          of: find.byKey(ValueKey<String>(rowKey)),
          matching: find.byType(FushiIconButton),
        ),
      )
      .enabled;

  testWidgets('桌面：对话框按内容收高、宽度在 MD3 对话框规范内，标题与文件名在顶部', (
    WidgetTester tester,
  ) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    await open(tester, host);
    expect(tester.takeException(), isNull);

    final Rect dialog = tester.getRect(_dialogSurface);
    expect(dialog.width, inInclusiveRange(480, 560));
    // 不撑满窗口高度：对话框底边紧跟内容，而不是被推到窗口底。
    final Rect options = tester.getRect(
      find.byKey(const ValueKey<String>('srs-import-options')),
    );
    final Rect confirmBtn = tester.getRect(
      find.byKey(const ValueKey<String>('srs-import-confirm')),
    );
    expect(dialog.height, lessThan(800 - 120));
    expect(confirmBtn.top - options.bottom, lessThan(120));
    expect(dialog.bottom - confirmBtn.bottom, lessThan(60));
    // 文件名在标题下、在选项之上。
    final Rect file = tester.getRect(
      find.byKey(const ValueKey<String>('srs-import-options-file')),
    );
    expect(file.bottom, lessThanOrEqualTo(options.top));
    expect(find.text('Japanese Core 2k.apkg'), findsOneWidget);
    // 宽屏：开关在标签右侧同一行（不堆叠）。
    final Rect schedRow = tester.getRect(
      find.byKey(const ValueKey<String>('srs-import-with-scheduling')),
    );
    expect(schedRow.height, lessThan(90));
  });

  testWidgets('窄屏（手机）：不溢出、不抛错，对话框在屏内', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(360, 760));
    await open(tester, host, wholeCollection: true);
    expect(tester.takeException(), isNull);
    final Rect dialog = tester.getRect(_dialogSurface);
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(360));
    expect(dialog.bottom, lessThanOrEqualTo(760));
  });

  testWidgets('默认值 = Anki 默认：两个开关关、合并关、更新两项「较新时」，恢复默认都不可点', (
    WidgetTester tester,
  ) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    final Future<SrsAnkiImportOptions?> result = await open(
      tester,
      host,
      initial: readSrsImportOptions(_MemoryPrefs()),
    );
    AdaptiveSettingsSwitchRow switchRow(String key) =>
        tester.widget<AdaptiveSettingsSwitchRow>(
          find.descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(AdaptiveSettingsSwitchRow),
            matchRoot: true,
          ),
        );
    expect(switchRow('srs-import-with-scheduling').value, isFalse);
    expect(switchRow('srs-import-with-deck-configs').value, isFalse);
    expect(switchRow('srs-import-merge-notetypes').value, isFalse);
    for (final String key in <String>[
      'srs-import-update-notes',
      'srs-import-update-notetypes',
    ]) {
      expect(
        tester
            .widget<AdaptiveSettingsPickerRow<SrsImportUpdateCondition>>(
              find.descendant(
                of: find.byKey(ValueKey<String>(key)),
                matching: find.byType(
                  AdaptiveSettingsPickerRow<SrsImportUpdateCondition>,
                ),
              ),
            )
            .selected,
        SrsImportUpdateCondition.ifNewer,
      );
      expect(resetEnabled(tester, key), isFalse);
    }
    expect(resetEnabled(tester, 'srs-import-merge-notetypes'), isFalse);
    expect(await confirm(tester, result), const SrsAnkiImportOptions());
  });

  testWidgets('改选项 → 确认返回新值；恢复默认把那一项还原', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    final Future<SrsAnkiImportOptions?> result = await open(
      tester,
      host,
      initial: const SrsAnkiImportOptions(
        updateNotes: SrsImportUpdateCondition.never,
        mergeNoteTypes: true,
      ),
    );
    expect(resetEnabled(tester, 'srs-import-update-notes'), isTrue);
    expect(resetEnabled(tester, 'srs-import-merge-notetypes'), isTrue);
    expect(resetEnabled(tester, 'srs-import-update-notetypes'), isFalse);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('srs-import-update-notes')),
        matching: find.byType(FushiIconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(resetEnabled(tester, 'srs-import-update-notes'), isFalse);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-import-with-scheduling')),
    );
    await tester.pumpAndSettle();
    expect(
      await confirm(tester, result),
      const SrsAnkiImportOptions(mergeNoteTypes: true, withScheduling: true),
    );
  });

  testWidgets('取消返回 null', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    final Future<SrsAnkiImportOptions?> result = await open(tester, host);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('「?」打开逐项说明', (WidgetTester tester) async {
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    await open(tester, host);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-import-options-help-button')),
    );
    await tester.pumpAndSettle();
    final Finder help = find.byKey(
      const ValueKey<String>('srs-import-options-help'),
    );
    expect(help, findsOneWidget);
    for (final String title in <String>[
      'Import all review progress',
      'Import all deck presets',
      'Merge note types',
      'Update notes',
      'Update note types',
    ]) {
      expect(
        find.descendant(of: help, matching: find.text(title)),
        findsOneWidget,
      );
    }
  });

  test('记住上次的选择：写进偏好、下次读回；坏值回落默认', () async {
    final _MemoryPrefs prefs = _MemoryPrefs();
    expect(readSrsImportOptions(prefs), const SrsAnkiImportOptions());
    const SrsAnkiImportOptions picked = SrsAnkiImportOptions(
      mergeNoteTypes: true,
      updateNotes: SrsImportUpdateCondition.always,
      updateNoteTypes: SrsImportUpdateCondition.never,
      withScheduling: true,
      withDeckConfigs: true,
    );
    await writeSrsImportOptions(prefs, picked);
    expect(prefs.values.keys, <String>[kSrsImportOptionsPrefKey]);
    expect(readSrsImportOptions(prefs), picked);
    prefs.values[kSrsImportOptionsPrefKey] = '{not json';
    expect(readSrsImportOptions(prefs), const SrsAnkiImportOptions());
  });

  testWidgets('上次的选择作为初值显示', (WidgetTester tester) async {
    final _MemoryPrefs prefs = _MemoryPrefs();
    await writeSrsImportOptions(
      prefs,
      const SrsAnkiImportOptions(withScheduling: true),
    );
    final BuildContext host = await pumpHost(tester, const Size(1280, 800));
    final Future<SrsAnkiImportOptions?> result = await open(
      tester,
      host,
      initial: readSrsImportOptions(prefs),
    );
    expect(
      tester
          .widget<AdaptiveSettingsSwitchRow>(
            find.byKey(const ValueKey<String>('srs-import-with-scheduling')),
          )
          .value,
      isTrue,
    );
    expect(
      await confirm(tester, result),
      const SrsAnkiImportOptions(withScheduling: true),
    );
  });

  testWidgets('手机（390 宽）：「合并笔记模板」开关与同组一样留在标签右侧；下拉不再重复行标题', (
    WidgetTester tester,
  ) async {
    final BuildContext host = await pumpHost(tester, const Size(390, 844));
    await open(tester, host);
    expect(tester.takeException(), isNull);

    // 对话框外边距按屏宽收窄（不再是固定 40）：正文更宽，标签少折行。
    final Rect dialog = tester.getRect(_dialogSurface);
    expect(dialog.width, greaterThan(390 - 2 * 24));

    // 开关在标签同一行右侧：开关的竖直中心落在标题文字的行范围内。
    for (final (String key, String title) in <(String, String)>[
      ('srs-import-with-scheduling', t.srs_import_with_scheduling),
      ('srs-import-merge-notetypes', t.srs_import_merge_notetypes),
    ]) {
      final Finder row = find.byKey(ValueKey<String>(key));
      final Rect sw = tester.getRect(
        find.descendant(of: row, matching: find.byType(Switch)),
      );
      final Rect label = tester.getRect(
        find.descendant(of: row, matching: find.text(title)),
      );
      expect(sw.left, greaterThan(label.right - 1), reason: '$key 开关在标签右侧');
      expect(
        sw.center.dy,
        inInclusiveRange(label.top - 24, label.bottom + 24),
        reason: '$key 开关没有被挤到标签下方',
      );
    }

    // 下拉行：行标题只出现一次（DropdownMenu 不再带同名浮动标签）。
    for (final (String key, String title) in <(String, String)>[
      ('srs-import-update-notes', t.srs_import_update_notes),
      ('srs-import-update-notetypes', t.srs_import_update_notetypes),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.text(title),
        ),
        findsOneWidget,
        reason: '$key 的标题不重复',
      );
    }
  });
}
