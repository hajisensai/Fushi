import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/combo/combo_migration_report_dialog.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:material_ui/material_ui.dart';

/// 组合迁移报告的呈现（拍板台 design-combo-node-split 阶段 3）。
void main() {
  test('设置树上每个叶子都有界面名（新加叶子要在报告里能读懂）', () {
    for (final SettingsNode leaf in fushiSettingsTree.leaves) {
      expect(comboLeafLabel(leaf.id), isNot(leaf.id), reason: leaf.id);
    }
    expect(comboLeafLabel('future.leaf'), 'future.leaf', reason: '不认识的原样显示');
  });

  testWidgets('报告正文：各组合的拆分、冲突、忽略、复习库都显示', (WidgetTester tester) async {
    const ComboMigrationReport report = ComboMigrationReport(
      defaultName: 'Default',
      combos: <ComboMigrationEntry>[
        ComboMigrationEntry(
          name: 'Video',
          splitLeaves: <String>[FushiComboNode.miningNoteType],
        ),
        ComboMigrationEntry(name: 'Same', splitLeaves: <String>[]),
      ],
      conflicts: <ComboBindingConflict>[
        ComboBindingConflict(
          languageTag: 'ja',
          mediaType: 'video',
          languageProfile: 'JP',
          mediaTypeProfile: 'Video',
          leaves: <String>[FushiComboNode.appearanceFonts],
        ),
      ],
      ignored: <ComboIgnoredSplitEntry>[
        ComboIgnoredSplitEntry(
          profile: 'Book',
          scope: ComboScope.work,
          bindings: 2,
          leaves: <String>[FushiComboNode.other],
        ),
      ],
      srs: ComboSrsLibraryDecision(
        sharedProfile: 'Default',
        ownProfiles: <String>['Video'],
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ComboMigrationReportBody(report: report),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Default'), findsWidgets);
    expect(find.textContaining('Video'), findsWidgets);
    expect(find.textContaining('Same'), findsOneWidget);
    expect(find.textContaining('Book'), findsOneWidget);
    expect(find.textContaining('JP'), findsOneWidget);
  });
}
