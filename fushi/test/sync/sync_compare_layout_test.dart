import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/sync_compare_fixture.dart';

/// C3：同步对比对话框排版——pinned 段头带计数、批量裁决挪到冲突段头、
/// 「只看冲突」筛选，且渲染集 = 应用集。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pump(
    WidgetTester tester,
    FushiDatabase db,
    FakeCompareBackend fake, {
    bool conflictsOnly = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(
              db: db,
              backend: fake,
              conflictsOnly: conflictsOnly,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('段头 pinned 且带计数：冲突 2 / 全部书籍 2 / 词典 1',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db, await seedCompareScenario(db));

    // 主体高度上限 640，词典段在首屏之下；CustomScrollView 不构建视口外的 sliver，
    // 先滚到底——pinned 段头滚过去仍钉在顶上，三个都在树里。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(find.byType(SliverPersistentHeader), findsNWidgets(3));
    for (final SliverPersistentHeader h
        in tester.widgetList<SliverPersistentHeader>(
            find.byType(SliverPersistentHeader))) {
      expect(h.pinned, isTrue, reason: '段头必须钉在滚动容器顶上');
    }
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text(t.sync_compare_all_books), findsOneWidget);
    expect(find.text(t.sync_compare_dictionaries), findsOneWidget);
    // 计数 chip：冲突 2、其它书 2（本地更新 + 远端更新；远端独有也算「其它」→ 3）。
    final List<String> tags = tester
        .widgetList<FushiTag>(find.byType(FushiTag))
        .map((FushiTag t) => t.text)
        .toList();
    expect(tags, <String>['2', '3', '1']);
  });

  testWidgets('批量裁决菜单挂在冲突段头上，不在标题行', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db, await seedCompareScenario(db));

    final Finder menu = find.byType(FushiOverflowMenu<SyncChoice>);
    expect(menu, findsOneWidget);
    expect(
      find.ancestor(of: menu, matching: find.byType(SliverPersistentHeader)),
      findsOneWidget,
      reason: '批量裁决只作用于冲突项，应挂在冲突段头',
    );
  });

  testWidgets('「只看冲突」：隐藏其它书与词典，Apply 计数跟随可见集', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db, await seedCompareScenario(db));

    // 初始：冲突 2（默认远端更新→用远端）+ 本地更新 + 远端更新 = 4 项可应用。
    expect(find.text(t.sync_compare_apply(count: 4)), findsOneWidget);
    expect(find.text('Local newer'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('JMdict'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('JMdict'), findsOneWidget);

    final Finder chip = find.byType(FilterChip);
    expect(chip, findsOneWidget);
    expect(
      find.text('${t.sync_compare_only_conflicts} · 2'),
      findsOneWidget,
      reason: '筛选 chip 上带冲突数',
    );
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.text('Local newer'), findsNothing);
    expect(find.text('JMdict'), findsNothing);
    expect(find.text(t.sync_compare_all_books), findsNothing);
    expect(find.text(t.sync_compare_dictionaries), findsNothing);
    expect(find.text('Conflict A'), findsOneWidget);
    expect(find.text(t.sync_compare_apply(count: 2)), findsOneWidget,
        reason: '渲染集 = 应用集：只看冲突时只应用冲突');

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('Local newer'), findsOneWidget);
    expect(find.text(t.sync_compare_apply(count: 4)), findsOneWidget);
  });

  testWidgets('冲突解决弹窗（conflictsOnly）没有筛选 chip', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db, await seedCompareScenario(db), conflictsOnly: true);

    expect(find.byType(FilterChip), findsNothing);
    expect(find.text(t.sync_compare_all_books), findsNothing);
    expect(find.text(t.sync_compare_apply(count: 2)), findsOneWidget);
  });
}
