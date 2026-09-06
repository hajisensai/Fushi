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

  testWidgets('筛选开着时冲突归零：chip 必须留下，否则再也退不出「只看冲突」',
      (WidgetTester tester) async {
    // 一个开关不能在自己是 ON 的时候把自己的 OFF 入口删掉。
    // 这条路径全程走的是既有 UI：冲突行本身带删除菜单（真冲突两边都有远端副本，
    // remoteFolderId 必非空），把最后一条冲突的远端删掉后 _conflictCount 归零。
    // chip 的显示条件若只看 _conflictCount > 0，它就会连同自己的关闭入口一起消失，
    // 而 _filterConflicts 仍是 true —— 非冲突的书和词典段全部不可见也不可达，
    // Apply 恒为 0，用户只能关掉对话框重开。
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final FakeCompareBackend fake = await seedCompareScenario(db);
    await pump(tester, db, fake);

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('Conflict A'), findsOneWidget);
    expect(find.text('Conflict B'), findsOneWidget);

    for (int i = 0; i < 2; i++) {
      await tester.tap(find.byType(FushiOverflowMenu<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.sync_compare_delete_book).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
      await tester.pumpAndSettle();
    }

    expect(fake.deleted, hasLength(2), reason: '两条冲突的远端副本都删掉了');
    expect(find.text('Conflict A'), findsNothing);
    expect(find.text('Conflict B'), findsNothing);

    final Finder chip = find.byType(FilterChip);
    expect(chip, findsOneWidget,
        reason: '筛选仍开着，chip 就必须留下——它是唯一的关闭入口');
    expect(find.text('${t.sync_compare_only_conflicts} · 0'), findsOneWidget);

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('Local newer'), findsOneWidget,
        reason: '关掉筛选后非冲突条目必须重新可见可应用');
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
