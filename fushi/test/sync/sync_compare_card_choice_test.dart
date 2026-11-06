// 同步对比弹窗：人工裁决条目里「本地 / 远端」两张大卡本身就是选择控件（反馈 ZqCPfu8-of：以前卡片
// 只能看、下面的三段按钮条才能点，同一个状态画了两遍）。非人工条目的卡片只做展示、没有 button 语义。
import 'package:drift/drift.dart';
import 'dart:ui' show Tristate;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/sync_compare_fixture.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pump(WidgetTester tester, FushiDatabase db) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeCompareBackend fake = await seedCompareScenario(db);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: fake),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder card(String side, String title) =>
      find.byKey(ValueKey<String>('sync-choice-$side-$title'));

  SemanticsNode semanticsOfCard(
    WidgetTester tester,
    String side,
    String title,
  ) => tester.getSemantics(card(side, title));

  bool selected(WidgetTester tester, String side, String title) =>
      semanticsOfCard(tester, side, title).flagsCollection.isSelected ==
      Tristate.isTrue;

  testWidgets('点远端大卡即选远端；再点「跳过」回到不同步；没有第二套三段按钮', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db);

    const String title = 'Conflict A';
    expect(card('local', title), findsOneWidget);
    expect(card('remote', title), findsOneWidget);
    // 选择只有一套控件：不再有本地 / 跳过 / 远端三段按钮条。
    expect(find.byType(FushiSegmentedButton<SyncChoice>), findsNothing);

    expect(
      semanticsOfCard(tester, 'remote', title).flagsCollection.isButton,
      isTrue,
    );
    // 起点不论是哪一侧（对话框按较新一侧预选），先点本地，再点远端。
    await tester.tap(card('local', title));
    await tester.pumpAndSettle();
    expect(selected(tester, 'local', title), isTrue);
    expect(selected(tester, 'remote', title), isFalse);

    await tester.tap(card('remote', title));
    await tester.pumpAndSettle();
    expect(selected(tester, 'remote', title), isTrue);
    expect(selected(tester, 'local', title), isFalse);

    // 点本地：切到本地。
    await tester.tap(card('local', title));
    await tester.pumpAndSettle();
    expect(selected(tester, 'local', title), isTrue);
    expect(selected(tester, 'remote', title), isFalse);

    // 「跳过」撤销选择。
    final Finder skip = find.byKey(
      const ValueKey<String>('sync-choice-skip-$title'),
    );
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(selected(tester, 'local', title), isFalse);
    semantics.dispose();
  });

  testWidgets('不需要人工裁决的条目：卡片只展示，不可点、没有 button 语义', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await pump(tester, db);
    // 非冲突条目在冲突段之下，CustomScrollView 不构建视口外的 sliver：先滚过去。
    await tester.dragUntilVisible(
      find.text('Local newer'),
      find.byType(CustomScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Local newer'), findsOneWidget);
    expect(card('local', 'Local newer'), findsNothing);
    expect(card('remote', 'Local newer'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('sync-choice-skip-Local newer')),
      findsNothing,
    );
  });
}
