import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/deletion_prompt.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/sync_conflict_prompter.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

// BUG-1571：双通道（云备份 + 互联）sweep 逐通道调 `onReport`，两批候选在同一次 sweep
// 内先后到达同一个 prompter。旧实现只有一个 `dialogOpen` 单飞位，第一批弹窗还开着时，
// 第二批被 `shouldPrompt` 直接判 false **丢掉**（既不 snooze、也不推进基线，就是没了）。
// 修法是排队：后到的那批在前一个弹窗关闭后接着弹。

/// `NativeDatabase.memory()` 默认**关**外键，而生产连接经 applyPragmas 开着；
/// 不显式打开的话涉及约束/级联的用例会假绿。
FushiDatabase _memDb() => FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory(
        setup: (dynamic rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      )),
    );

DeletionCandidateView _view(String key, String title) => DeletionCandidateView(
      candidate: DeletionPropagationCandidate(
        mediaType: 'book',
        itemKey: key,
        direction: DeletionPropagationDirection.deleteLocal,
      ),
      title: title,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  /// 装一个带 navigatorKey 的真实 app，让 `navigatorKey.currentContext` 非空。
  Future<void> pumpApp(
      WidgetTester tester, GlobalKey<NavigatorState> navKey) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('home')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('两条通道先后 present：第一批弹窗关闭后第二批仍然弹出', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final DeletionPromptPrompter prompter = DeletionPromptPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await pumpApp(tester, navKey);

    final List<String> applied = <String>[];
    Future<void> apply(List<DeletionPropagationCandidate> confirmed) async {
      applied
          .addAll(confirmed.map((DeletionPropagationCandidate c) => c.itemKey));
    }

    // 通道一（云）与通道二（互联）在同一次 sweep 内先后调 present，都不 await。
    final Future<void> cloud = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('cloud-1', 'Cloud Book')],
      highWaterMs: 100,
      applyDeletions: apply,
      source: ConflictSource.auto,
      inBook: false,
    );
    final Future<void> live = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('live-1', 'Live Book')],
      highWaterMs: 200,
      applyDeletions: apply,
      source: ConflictSource.auto,
      inBook: false,
    );
    unawaited(cloud);
    unawaited(live);
    await tester.pumpAndSettle();

    // 第一批：云通道的候选在弹。
    expect(find.text('Cloud Book'), findsOneWidget);
    expect(find.text('Live Book'), findsNothing);

    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();
    await cloud;

    // 第二批不该消失：排队呈现，现在轮到互联通道那批。
    expect(find.text('Live Book'), findsOneWidget,
        reason: '单飞位挡下的候选必须排队重现，不能被静默丢弃');

    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();
    await live;

    expect(applied, <String>['cloud-1', 'live-1']);
    // 两批都被用户复核过 → 基线推进到两者中的更高水位。
    expect(await SyncRepository(db).getDeletionTombstonesBaselineMs(), 200);
  });

  testWidgets('第二批被用户取消：只 snooze 自己，不推进基线到它的水位', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final DeletionPromptPrompter prompter = DeletionPromptPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await pumpApp(tester, navKey);

    Future<void> apply(List<DeletionPropagationCandidate> confirmed) async {}

    final Future<void> cloud = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('cloud-1', 'Cloud Book')],
      highWaterMs: 100,
      applyDeletions: apply,
      source: ConflictSource.auto,
      inBook: false,
    );
    final Future<void> live = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('live-1', 'Live Book')],
      highWaterMs: 999,
      applyDeletions: apply,
      source: ConflictSource.auto,
      inBook: false,
    );
    unawaited(cloud);
    unawaited(live);
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();
    await cloud;

    expect(find.text('Live Book'), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    await live;

    // 取消的那批不推进基线：下次会话还会再问。
    expect(await SyncRepository(db).getDeletionTombstonesBaselineMs(), 100);
  });

  testWidgets('队列不因前一个弹窗抛异常而断链', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final DeletionPromptPrompter prompter = DeletionPromptPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await pumpApp(tester, navKey);

    final Future<void> boom = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('cloud-1', 'Cloud Book')],
      highWaterMs: 100,
      applyDeletions: (List<DeletionPropagationCandidate> _) async =>
          throw StateError('apply failed'),
      source: ConflictSource.auto,
      inBook: false,
    );
    final Future<void> live = prompter.present(
      navigatorKey: navKey,
      db: db,
      views: <DeletionCandidateView>[_view('live-1', 'Live Book')],
      highWaterMs: 200,
      applyDeletions: (List<DeletionPropagationCandidate> _) async {},
      source: ConflictSource.auto,
      inBook: false,
    );
    unawaited(boom.catchError((Object _) {
      // 异常照常抛给调用方（这里吞掉只是为了不让测试因未捕获错误失败）。
    }));
    unawaited(live);
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.delete_prompt_delete_selected));
    await tester.pumpAndSettle();

    expect(find.text('Live Book'), findsOneWidget,
        reason: '前一个弹窗抛异常不得把后续候选卡死在队列里');
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    await live;
  });

  test('两个 prompter 共用同一套排队机制', () {
    // 冲突弹窗那侧是同一个 bug 的另一半（sync_conflict_prompter.dart 的 dialogOpen
    // 单飞）：类型检查而非源码扫描——把 `with PromptQueue` 摘掉就红。
    expect(SyncConflictPrompter(), isA<PromptQueue>());
    expect(DeletionPromptPrompter(), isA<PromptQueue>());
  });
}
