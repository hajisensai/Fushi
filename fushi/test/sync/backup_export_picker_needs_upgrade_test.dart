import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        backupExportCategoryRow,
        defaultBackupExportCategories,
        initialBackupExportSelection;
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

/// 设置页导出框对「需先升级」类别的处理（G7-5b 复核）：本机复习库还没迁移成新代时，复习一行默认不勾、开关不可点、
/// 副标题是需先升级的文案，确认后返回的类别里没有它；其余类别照常可勾。
void main() {
  const BackupContentSummary blocked = BackupContentSummary(
    counts: <BackupCategory, int>{BackupCategory.games: 3},
    present: <BackupCategory>{BackupCategory.games, BackupCategory.srs},
    needsUpgrade: <BackupCategory>{BackupCategory.srs},
  );
  const BackupContentSummary ready = BackupContentSummary(
    counts: <BackupCategory, int>{BackupCategory.srs: 5},
    present: <BackupCategory>{BackupCategory.srs},
  );

  test('初始勾选：需先升级的类别不在里面，其余默认类别照旧', () {
    final Set<BackupCategory> initial = initialBackupExportSelection(blocked);
    expect(initial, isNot(contains(BackupCategory.srs)));
    expect(
      initial,
      defaultBackupExportCategories()..remove(BackupCategory.srs),
    );
    expect(initialBackupExportSelection(ready), contains(BackupCategory.srs));
  });

  Future<List<bool>> pumpRow(
    WidgetTester tester,
    BackupCategory category,
    BackupContentSummary summary, {
    required bool selected,
  }) async {
    final List<bool> toggles = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                backupExportCategoryRow(
                  category: category,
                  summary: summary,
                  selected: selected,
                  onToggle: toggles.add,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return toggles;
  }

  testWidgets('需先升级的一行：副标题是需先升级、开关不可点', (WidgetTester tester) async {
    final List<bool> toggles = await pumpRow(
      tester,
      BackupCategory.srs,
      blocked,
      selected: false,
    );
    expect(find.text(t.backup_export_srs_needs_upgrade), findsOneWidget);
    final AdaptiveSettingsSwitchRow row = tester.widget(
      find.byType(AdaptiveSettingsSwitchRow),
    );
    expect(row.onChanged, isNull);
    expect(row.value, isFalse);
    await tester.tap(find.byType(AdaptiveSettingsSwitchRow));
    await tester.pump();
    expect(toggles, isEmpty);
  });

  testWidgets('能导出的一行：副标题带计数、开关可点', (WidgetTester tester) async {
    final List<bool> toggles = await pumpRow(
      tester,
      BackupCategory.srs,
      ready,
      selected: true,
    );
    expect(find.text(t.backup_export_srs_needs_upgrade), findsNothing);
    expect(find.textContaining('(5)'), findsOneWidget);
    await tester.tap(find.byType(AdaptiveSettingsSwitchRow));
    await tester.pump();
    expect(toggles, <bool>[false]);
  });
}
