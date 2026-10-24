// BUG-3548 / BUG-3549：牌组列表刷新与后台导入。
//
// - 后台导入控制器：串行、进度、完成 / 失败回调、完成后让牌组列表重读、迁移用的临时包结束后删除。
// - 任务条（MD3 / Apple）：运行中显示进度条，结束后显示结果与「关闭」。
// - 牌组列表：新建牌组后列表只等牌组行重读，不等同步冲突扫描（冲突数是另一个 provider）。
// - 删牌组（BUG-3543）：删除进行中行变成「正在删除」+ 进度条且不可点，删完立即从列表消失；
//   删除由 app 级控制器跑完，途中牌组列表页被销毁（切走复习 tab）删除照样做完、列表照样重读。
// - 取消：排队中的导入可以取消（不再开始跑、收尾照做、result 以取消异常结束）；运行中的不能。
// - 完成回调抛异常不能停掉后面排队的导入。
//
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_import_tasks_bar.dart';
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 可手动推进的假导入：每次调用登记一个待完成的导入。
class _FakeRunner {
  final List<_Pending> calls = <_Pending>[];

  Future<SrsImportReport> call({
    required SrsDbStore store,
    required SrsMediaStore media,
    required File file,
    required SrsAnkiImportOptions options,
    required void Function(double progress) onProgress,
    required bool Function() shouldStop,
  }) {
    final _Pending p = _Pending(file, onProgress, shouldStop);
    calls.add(p);
    return p.done.future;
  }
}

class _Pending {
  _Pending(this.file, this.onProgress, this.shouldStop);

  final File file;
  final void Function(double progress) onProgress;
  final bool Function() shouldStop;
  final Completer<SrsImportReport> done = Completer<SrsImportReport>();
}

SrsImportReport _report(int added) => SrsImportReport()..notesAdded = added;

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget _app({
  required bool apple,
  required Widget home,
  required List<Override> overrides,
}) => ProviderScope(
  overrides: overrides,
  child: TranslationProvider(
    child: MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        designSystem: apple
            ? FushiDesignSystem.cupertino
            : FushiDesignSystem.material,
        glass: FushiGlassMaterial.off,
        glassDesign: apple,
      ),
      builder: (BuildContext context, Widget? child) =>
          FushiGlassScope(child: child!),
      home: home,
    ),
  ),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('srs_import_task_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  group('SrsImportController', () {
    test('enqueueJob：成功与失败都在 result 完成前执行收尾（Anki 集合快照的临时目录）', () async {
      final SrsImportController c = SrsImportController(onDataChanged: () {});
      addTearDown(c.dispose);
      final List<String> order = <String>[];

      final Completer<SrsImportReport> okJob = Completer<SrsImportReport>();
      final SrsImportTask ok = c.enqueueJob(
        displayName: 'User 1',
        job: (void Function(double progress) onProgress, _) {
          onProgress(0.5);
          return okJob.future;
        },
        cleanup: () async => order.add('cleanup-ok'),
      );
      final SrsImportTask bad = c.enqueueJob(
        displayName: 'User 2',
        job: (void Function(double progress) onProgress, _) =>
            Future<SrsImportReport>.error(StateError('boom')),
        cleanup: () async => order.add('cleanup-bad'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ok.status, SrsImportTaskStatus.running);
      expect(ok.progress.value, 0.5);
      expect(bad.status, SrsImportTaskStatus.queued);

      okJob.complete(_report(3));
      final SrsImportReport report = await ok.result;
      order.add('result-ok');
      expect(report.notesAdded, 3);
      await expectLater(bad.result, throwsStateError);
      order.add('result-bad');
      expect(order.indexOf('cleanup-ok'), lessThan(order.indexOf('result-ok')));
      expect(
        order.indexOf('cleanup-bad'),
        lessThan(order.indexOf('result-bad')),
      );
      expect(order, containsAll(<String>['cleanup-ok', 'cleanup-bad']));
      expect(bad.status, SrsImportTaskStatus.failed);
    });

    test('串行：第二个导入排队到第一个结束；进度、完成回调与牌组列表重读', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final SrsMediaStore media = SrsMediaStore(tmp);
      final _FakeRunner runner = _FakeRunner();
      int dataChanged = 0;
      final List<SrsImportTask> finished = <SrsImportTask>[];
      final SrsImportController c = SrsImportController(
        onDataChanged: () => dataChanged++,
        onFinished: finished.add,
        runner: runner.call,
      );
      addTearDown(c.dispose);

      final SrsImportTask a = c.enqueue(
        store: store,
        media: media,
        file: File('${tmp.path}/a.apkg'),
      );
      final SrsImportTask b = c.enqueue(
        store: store,
        media: media,
        file: File('${tmp.path}/b.colpkg'),
        displayName: 'Collection',
      );
      await Future<void>.delayed(Duration.zero);
      expect(a.status, SrsImportTaskStatus.running);
      expect(b.status, SrsImportTaskStatus.queued);
      expect(b.displayName, 'Collection');
      expect(runner.calls, hasLength(1), reason: '同一时刻只跑一个导入');
      expect(c.busy, isTrue);

      runner.calls.single.onProgress(0.4);
      expect(a.progress.value, 0.4);

      runner.calls.single.done.complete(_report(3));
      expect((await a.result).notesAdded, 3);
      await Future<void>.delayed(Duration.zero);
      expect(a.status, SrsImportTaskStatus.done);
      expect(dataChanged, 1, reason: '完成后牌组列表重读');
      expect(finished, <SrsImportTask>[a]);
      expect(b.status, SrsImportTaskStatus.running);
      expect(runner.calls, hasLength(2));

      runner.calls.last.done.completeError(
        const SrsImportException(SrsImportException.corrupt, 'bad'),
      );
      await expectLater(b.result, throwsA(isA<SrsImportException>()));
      await Future<void>.delayed(Duration.zero);
      expect(b.status, SrsImportTaskStatus.failed);
      expect(b.error, isA<SrsImportException>());
      expect(dataChanged, 2, reason: '失败也可能已写入一部分批次，一样重读');
      expect(finished, <SrsImportTask>[a, b]);
      expect(c.busy, isFalse);

      c.dismiss(a);
      expect(c.tasks, <SrsImportTask>[b]);
    });

    test('迁移用的临时包：结束后删除（失败也删）', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final _FakeRunner runner = _FakeRunner();
      final SrsImportController c = SrsImportController(
        onDataChanged: () {},
        runner: runner.call,
      );
      addTearDown(c.dispose);
      final File pkg = File('${tmp.path}/export.colpkg')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final SrsImportTask task = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: pkg,
        deleteFileWhenDone: true,
      );
      await Future<void>.delayed(Duration.zero);
      runner.calls.single.done.completeError(StateError('boom'));
      await expectLater(task.result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(pkg.existsSync(), isFalse);
    });

    test('取消：排队中的任务不再开始跑、收尾照做、result 以取消结束；运行中的不能取消', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final _FakeRunner runner = _FakeRunner();
      int dataChanged = 0;
      final List<SrsImportTask> finished = <SrsImportTask>[];
      final SrsImportController c = SrsImportController(
        onDataChanged: () => dataChanged++,
        onFinished: finished.add,
        runner: runner.call,
      );
      addTearDown(c.dispose);
      final SrsImportTask a = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/a.apkg'),
      );
      final File pkg = File('${tmp.path}/b.colpkg')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final SrsImportTask b = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: pkg,
        deleteFileWhenDone: true,
      );
      final SrsImportTask third = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/c.apkg'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(a.status, SrsImportTaskStatus.running);
      expect(a.canCancel, isTrue);
      expect(b.canCancel, isTrue);

      expect(await c.cancel(b), isTrue);
      expect(b.status, SrsImportTaskStatus.cancelled);
      expect(b.isFinished, isTrue);
      expect(b.canCancel, isFalse);
      await expectLater(b.result, throwsA(isA<SrsImportCancelledException>()));
      expect(pkg.existsSync(), isFalse, reason: '取消也执行收尾（删临时包）');
      expect(finished, <SrsImportTask>[b]);
      expect(dataChanged, 0, reason: '没写过库，不必重读');
      expect(await c.cancel(b), isFalse, reason: '已结束的再取消什么也不做');

      runner.calls.single.done.complete(_report(1));
      await a.result;
      await Future<void>.delayed(Duration.zero);
      expect(runner.calls, hasLength(2), reason: '取消的 b 被跳过，接着跑第三个');
      expect(runner.calls.last.file.path, endsWith('c.apkg'));
      expect(third.status, SrsImportTaskStatus.running);
      runner.calls.last.done.complete(_report(2));
      await third.result;

      c.dismiss(b);
      expect(c.tasks, isNot(contains(b)));
    });

    test('运行中取消：请求停止，引擎在批间停下后任务进入已取消、列表重读、接着跑下一个', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final _FakeRunner runner = _FakeRunner();
      int dataChanged = 0;
      final List<SrsImportTask> finished = <SrsImportTask>[];
      final SrsImportController c = SrsImportController(
        onDataChanged: () => dataChanged++,
        onFinished: finished.add,
        runner: runner.call,
      );
      addTearDown(c.dispose);
      final SrsImportTask a = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/a.apkg'),
      );
      final SrsImportTask next = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/b.apkg'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(a.status, SrsImportTaskStatus.running);
      expect(runner.calls.single.shouldStop(), isFalse);

      expect(await c.cancel(a), isTrue);
      expect(a.stopping, isTrue, reason: '请求了停止，引擎还没停下');
      expect(a.status, SrsImportTaskStatus.running);
      expect(a.canCancel, isFalse, reason: '已请求停止，不再显示取消');
      expect(await c.cancel(a), isFalse);
      expect(runner.calls.single.shouldStop(), isTrue, reason: '停止信号传到了引擎');

      // 引擎在两批之间停下。
      runner.calls.single.done.completeError(const SrsImportStopped());
      await expectLater(a.result, throwsA(isA<SrsImportCancelledException>()));
      expect(a.status, SrsImportTaskStatus.cancelled);
      expect(a.isFinished, isTrue);
      expect(dataChanged, 1, reason: '叫停前已落库的批要让列表重读');
      expect(finished, <SrsImportTask>[a]);

      await Future<void>.delayed(Duration.zero);
      expect(runner.calls, hasLength(2), reason: '接着跑下一个');
      expect(next.status, SrsImportTaskStatus.running);
      expect(runner.calls.last.shouldStop(), isFalse, reason: '停止信号只属于被取消的任务');
      runner.calls.last.done.complete(_report(1));
      await next.result;
    });

    test('完成回调抛异常：记日志，后面排队的导入照常开始', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      final _FakeRunner runner = _FakeRunner();
      int calls = 0;
      final SrsImportController c = SrsImportController(
        onDataChanged: () {},
        onFinished: (SrsImportTask task) {
          calls++;
          throw StateError('toast exploded');
        },
        runner: runner.call,
      );
      addTearDown(c.dispose);
      final SrsImportTask a = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/a.apkg'),
      );
      final SrsImportTask b = c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/b.apkg'),
      );
      await Future<void>.delayed(Duration.zero);
      runner.calls.single.done.complete(_report(1));
      expect((await a.result).notesAdded, 1);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(b.status, SrsImportTaskStatus.running, reason: '队列没被回调异常停住');
      expect(runner.calls, hasLength(2));
      runner.calls.last.done.complete(_report(2));
      expect((await b.result).notesAdded, 2);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(c.busy, isFalse);
    });
  });

  group('SrsDeckDeleteController', () {
    test('删完让列表重读；失败也重读并撤掉删除中；同一牌组不重复删', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      int dataChanged = 0;
      final SrsDeckDeleteController c = SrsDeckDeleteController(
        onDataChanged: () => dataChanged++,
      );
      addTearDown(c.dispose);
      final String deck = await store.createDeck('Old');

      final Future<void> deleting = c.delete(store, deck);
      expect(c.isDeleting(deck), isTrue);
      expect(c.deleting.keys, <String>[deck]);
      await c.delete(store, deck); // 已经在删：直接返回
      await deleting;
      expect(dataChanged, 1);
      expect(c.isDeleting(deck), isTrue, reason: '列表重读掉它之前保持删除中');
      c.pruneDeleted(<String>[store.defaultDeckId]);
      expect(c.deleting, isEmpty);

      await expectLater(
        c.delete(store, store.defaultDeckId),
        throwsStateError,
        reason: '默认牌组不可删',
      );
      expect(c.isDeleting(store.defaultDeckId), isFalse);
      expect(dataChanged, 2);
    });
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 任务条：运行中显示进度条；完成后显示结果与「关闭」，关掉后收起', (
      WidgetTester tester,
    ) async {
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        openSrsTestStore,
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      final _FakeRunner runner = _FakeRunner();
      final SrsImportController c = SrsImportController(
        onDataChanged: () {},
        runner: runner.call,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _app(
          apple: apple,
          overrides: <Override>[
            srsImportControllerProvider.overrideWithValue(c),
          ],
          home: const Scaffold(body: SrsImportTasksBar()),
        ),
      );
      c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/Japanese.apkg'),
      );
      await _settle(tester);
      expect(find.text('Importing Japanese.apkg…'), findsOneWidget);
      expect(find.byType(FushiLinearProgressIndicator), findsOneWidget);

      // 四个数各不相同：任一项接错（如恢复数显示成新增数）都对不上。
      runner.calls.single.done.complete(
        _report(12)
          ..notesRestored = 3
          ..notesUpdated = 2
          ..notesSkipped = 7,
      );
      await _settle(tester);
      const String doneLabel =
          'Imported Japanese.apkg: 12 new, 3 restored, 2 updated, 7 unchanged';
      expect(find.text(doneLabel), findsOneWidget);
      expect(find.byType(FushiLinearProgressIndicator), findsNothing);
      final Finder dismiss = find.byKey(
        const ValueKey<String>('srs-import-task-dismiss-1'),
      );
      expect(dismiss, findsOneWidget);
      await tester.tap(dismiss);
      await _settle(tester);
      expect(c.tasks, isEmpty);
      expect(find.text(doneLabel), findsNothing);
    });

    testWidgets('[$ds] 删牌组：进行中显示「正在删除」与进度条、行不可点；删完立即消失，卡移到默认牌组', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 库开在后台 isolate（与 app 同一种连接）：fake zone 里收不到它的回包，删除会停在进行中，
      // 直到 runAsync 推进。
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        () async {
          final FushiDatabase db = FushiDatabase.forTesting(
            NativeDatabase.memory(),
          );
          // 与 app 同一种连接：srs.db 上的语句跨 isolate 在 Rust 连接上执行。
          final SrsStorage srs = await SrsStorage.open(
            path: SrsStorage.pathIn(tmp.path),
          );
          addTearDown(() => tester.runAsync(srs.close));
          return (
            db,
            await SrsDbStore.open(
              db: srs.db,
              core: srs.core,
              profileUid: kSrsTestProfile,
              deviceId: 'dev',
              engine: const SrsTestEngine(),
            ),
          );
        },
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      final (String deck, String child) = (await tester.runAsync(() async {
        final String deck = await store.createDeck('Old');
        final String child = await store.createDeck('Sub', parentId: deck);
        for (int i = 0; i < 3; i++) {
          await store.createNote(
            noteTypeId: store.lapisNoteTypeId,
            fieldsById: <String, String>{
              (await store.noteType(store.lapisNoteTypeId))!.fields.first.id:
                  'w$i',
            },
            deckId: i.isEven ? deck : child,
          );
        }
        return (deck, child);
      }))!;
      final SrsImportController c = SrsImportController(onDataChanged: () {});
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _app(
          apple: apple,
          overrides: <Override>[
            appProvider.overrideWith(
              (Ref ref) => AppModel(testPlatformServices()),
            ),
            srsStoreProvider.overrideWith((Ref ref) async => store),
            srsConflictCountProvider.overrideWith((Ref ref) async => 0),
            srsImportControllerProvider.overrideWithValue(c),
            srsCardFaceBuilderProvider.overrideWithValue(
              (BuildContext context, SrsCardFace face) =>
                  SrsPlainCardFace(face: face),
            ),
          ],
          home: const SrsDeckListPage(),
        ),
      );
      await _settle(tester);
      final Finder row = find.byKey(ValueKey<String>('srs-deck-$deck'));
      expect(row, findsOneWidget);

      // 右键行：两套设计系统都弹同一份牌组菜单。
      await tester.tap(find.text('Old'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.srs_deck_delete).last);
      await tester.pumpAndSettle();
      // 卡片去向二选一（BUG-3647）：保留卡片 = 移到上级（这里是默认牌组）。
      await tester.tap(find.text(t.srs_deck_delete_move_cards));
      // 不推进数据库（fake zone 里真异步不走）：删除停在进行中。
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(
        find.byKey(ValueKey<String>('srs-deck-deleting-$deck')),
        findsOneWidget,
      );
      // 子牌组随父牌组一起显示删除中。
      expect(
        find.byKey(ValueKey<String>('srs-deck-deleting-$child')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byType(FushiLinearProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(ValueKey<String>('srs-deck-deleting-$deck')),
          matching: find.byWidgetPredicate(
            (Widget w) => w is IgnorePointer && w.ignoring,
          ),
        ),
        findsWidgets,
        reason: '删除中的行不可点',
      );

      // 推进后台库直到删完（库在后台 isolate，往返由 runAsync 送达）。
      for (int i = 0; i < 400 && row.evaluate().isNotEmpty; i++) {
        await _settle(tester, rounds: 1);
      }
      expect(row, findsNothing, reason: '删完列表立即重读，牌组消失');
      expect(find.byKey(ValueKey<String>('srs-deck-$child')), findsNothing);
      expect(find.textContaining(t.srs_deck_deleting), findsNothing);
      final List<SrsCardCacheRow> cards = (await tester.runAsync(
        store.allCardRows,
      ))!;
      expect(cards, hasLength(3));
      expect(
        cards.every((SrsCardCacheRow x) => x.deckId == store.defaultDeckId),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('[$ds] 牌组列表：新建牌组立即出现，不等同步冲突扫描；有导入任务时列表最前是任务条', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        openSrsTestStore,
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      final _FakeRunner runner = _FakeRunner();
      final SrsImportController c = SrsImportController(
        onDataChanged: () {},
        runner: runner.call,
      );
      addTearDown(c.dispose);
      // 冲突扫描永远不结束：牌组列表不许被它挡住。
      final Completer<int> conflicts = Completer<int>();
      await tester.pumpWidget(
        _app(
          apple: apple,
          overrides: <Override>[
            appProvider.overrideWith(
              (Ref ref) => AppModel(testPlatformServices()),
            ),
            srsStoreProvider.overrideWith((Ref ref) async => store),
            srsConflictCountProvider.overrideWith(
              (Ref ref) => conflicts.future,
            ),
            srsImportControllerProvider.overrideWithValue(c),
            srsCardFaceBuilderProvider.overrideWithValue(
              (BuildContext context, SrsCardFace face) =>
                  SrsPlainCardFace(face: face),
            ),
          ],
          home: const SrsDeckListPage(),
        ),
      );
      await _settle(tester);
      expect(find.text('Default'), findsOneWidget);

      final String id = (await tester.runAsync(
        () => store.createDeck('Kanji'),
      ))!;
      ProviderScope.containerOf(
        tester.element(find.byType(SrsDeckListPage)),
      ).read(srsRevisionProvider.notifier).state++;
      await _settle(tester);
      expect(
        find.byKey(ValueKey<String>('srs-deck-$id')),
        findsOneWidget,
        reason: '新牌组随牌组行重读出现，不等冲突数',
      );
      expect(find.text('Kanji'), findsOneWidget);

      expect(
        find.byKey(const ValueKey<String>('srs-import-tasks')),
        findsNothing,
      );
      c.enqueue(
        store: store,
        media: SrsMediaStore(tmp),
        file: File('${tmp.path}/Kanji.apkg'),
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-import-tasks')),
        findsOneWidget,
      );
      expect(find.text('Importing Kanji.apkg…'), findsOneWidget);
      runner.calls.single.done.complete(_report(1));
      await _settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      '[$ds] 任务条：排队中 / 运行中都有「取消」；排队中点了即「已取消」，运行中点了先「正在停止」、引擎停下后「已取消」',
      (WidgetTester tester) async {
        final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
          openSrsTestStore,
        ))!;
        addTearDown(() => tester.runAsync(db.close));
        final _FakeRunner runner = _FakeRunner();
        final SrsImportController c = SrsImportController(
          onDataChanged: () {},
          runner: runner.call,
        );
        addTearDown(c.dispose);
        await tester.pumpWidget(
          _app(
            apple: apple,
            overrides: <Override>[
              srsImportControllerProvider.overrideWithValue(c),
            ],
            home: const Scaffold(body: SrsImportTasksBar()),
          ),
        );
        final SrsImportTask a = c.enqueue(
          store: store,
          media: SrsMediaStore(tmp),
          file: File('${tmp.path}/A.apkg'),
        );
        final SrsImportTask b = c.enqueue(
          store: store,
          media: SrsMediaStore(tmp),
          file: File('${tmp.path}/B.apkg'),
        );
        await _settle(tester);
        final Finder cancelA = find.byKey(
          ValueKey<String>('srs-import-task-cancel-${a.id}'),
        );
        expect(cancelA, findsOneWidget, reason: '运行中的导入也能取消');
        final Finder cancel = find.byKey(
          ValueKey<String>('srs-import-task-cancel-${b.id}'),
        );
        expect(cancel, findsOneWidget);
        expect(find.text('Waiting to import B.apkg'), findsOneWidget);

        await tester.tap(cancel);
        await _settle(tester);
        expect(b.status, SrsImportTaskStatus.cancelled);
        expect(find.text('Cancelled import of B.apkg'), findsOneWidget);
        expect(cancel, findsNothing);
        expect(
          find.byKey(ValueKey<String>('srs-import-task-dismiss-${b.id}')),
          findsOneWidget,
        );

        // 运行中的 A：点取消 → 正在停止（取消按钮收起），引擎在批间停下 → 已取消。
        await tester.tap(cancelA);
        await _settle(tester);
        expect(a.stopping, isTrue);
        expect(cancelA, findsNothing);
        expect(
          find.text(
            'Stopping import of A.apkg… (already imported notes are kept)',
          ),
          findsOneWidget,
        );
        expect(runner.calls.single.shouldStop(), isTrue);
        runner.calls.single.done.completeError(const SrsImportStopped());
        await _settle(tester);
        expect(a.status, SrsImportTaskStatus.cancelled);
        expect(find.text('Cancelled import of A.apkg'), findsOneWidget);
        expect(
          find.byKey(ValueKey<String>('srs-import-task-dismiss-${a.id}')),
          findsOneWidget,
        );
        expect(runner.calls, hasLength(1), reason: '取消的 B 没有被拿去跑');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('[$ds] 删牌组途中牌组列表页被销毁（切走复习 tab）：删除照样做完、无异常、列表重读', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        () async {
          final FushiDatabase db = FushiDatabase.forTesting(
            NativeDatabase.memory(),
          );
          // 与 app 同一种连接：srs.db 上的语句跨 isolate 在 Rust 连接上执行。
          final SrsStorage srs = await SrsStorage.open(
            path: SrsStorage.pathIn(tmp.path),
          );
          addTearDown(() => tester.runAsync(srs.close));
          return (
            db,
            await SrsDbStore.open(
              db: srs.db,
              core: srs.core,
              profileUid: kSrsTestProfile,
              deviceId: 'dev',
              engine: const SrsTestEngine(),
            ),
          );
        },
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      final String deck = (await tester.runAsync(() async {
        final String deck = await store.createDeck('Old');
        for (int i = 0; i < 3; i++) {
          await store.createNote(
            noteTypeId: store.lapisNoteTypeId,
            fieldsById: <String, String>{
              (await store.noteType(store.lapisNoteTypeId))!.fields.first.id:
                  'w$i',
            },
            deckId: deck,
          );
        }
        return deck;
      }))!;
      final SrsImportController imports = SrsImportController(
        onDataChanged: () {},
      );
      addTearDown(imports.dispose);
      // 容器比页面活得久（app 根容器）：页面换下去，删牌组控制器还在。
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appProvider.overrideWith(
            (Ref ref) => AppModel(testPlatformServices()),
          ),
          srsStoreProvider.overrideWith((Ref ref) async => store),
          srsConflictCountProvider.overrideWith((Ref ref) async => 0),
          srsImportControllerProvider.overrideWithValue(imports),
          srsCardFaceBuilderProvider.overrideWithValue(
            (BuildContext context, SrsCardFace face) =>
                SrsPlainCardFace(face: face),
          ),
        ],
      );
      addTearDown(container.dispose);
      final ValueNotifier<bool> showPage = ValueNotifier<bool>(true);
      addTearDown(showPage.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              theme: buildFushiThemeData(
                scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
                textTheme: Typography.material2021().black,
                designSystem: apple
                    ? FushiDesignSystem.cupertino
                    : FushiDesignSystem.material,
                glass: FushiGlassMaterial.off,
                glassDesign: apple,
              ),
              builder: (BuildContext context, Widget? child) =>
                  FushiGlassScope(child: child!),
              home: ValueListenableBuilder<bool>(
                valueListenable: showPage,
                builder: (BuildContext context, bool show, Widget? _) => show
                    ? const SrsDeckListPage()
                    : const Scaffold(body: Text('elsewhere')),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      final int revisionBefore = container.read(srsRevisionProvider);
      expect(find.byKey(ValueKey<String>('srs-deck-$deck')), findsOneWidget);

      await tester.tap(find.text('Old'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.srs_deck_delete).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.srs_deck_delete_move_cards));
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      final SrsDeckDeleteController deleter = container.read(
        srsDeckDeleteControllerProvider,
      );
      expect(deleter.isDeleting(deck), isTrue);
      expect(
        find.byKey(ValueKey<String>('srs-deck-deleting-$deck')),
        findsOneWidget,
      );

      // 删除还在进行（库在后台 isolate，没推进）：切走，页面销毁。
      showPage.value = false;
      await tester.pump();
      expect(find.byType(SrsDeckListPage), findsNothing);

      // 推进后台库直到删完：进度写入、重读都发生在页面销毁之后。循环里不碰 store——删除的
      // 独占区在 fake zone 里，runAsync 里读库会排在它后面等不到释放（挂死）；控制器在
      // deleteDeck 返回后才让列表重读，重读信号一到就说明独占区已释放。
      for (
        int i = 0;
        i < 400 && container.read(srsRevisionProvider) == revisionBefore;
        i++
      ) {
        await _settle(tester, rounds: 1);
      }
      expect(tester.takeException(), isNull);
      expect(
        container.read(srsRevisionProvider),
        greaterThan(revisionBefore),
        reason: '页面不在也让列表重读',
      );
      final List<SrsCardCacheRow> cards = (await tester.runAsync(
        store.allCardRows,
      ))!;
      expect(cards, hasLength(3));
      expect(
        cards.every((SrsCardCacheRow x) => x.deckId == store.defaultDeckId),
        isTrue,
        reason: '删除没有停在一半：卡都移到了默认牌组',
      );
      final SrsDeckListData list = (await tester.runAsync<SrsDeckListData?>(
        () => container.read(srsDeckListProvider.future),
      ))!;
      expect(
        list.decks.map((SrsDeckSummary d) => d.deck.id),
        isNot(contains(deck)),
        reason: '列表缓存里没有已删的牌组',
      );

      // 回到复习 tab：牌组不在、也不再显示删除中。
      showPage.value = true;
      await _settle(tester);
      expect(find.byKey(ValueKey<String>('srs-deck-$deck')), findsNothing);
      expect(find.textContaining(t.srs_deck_deleting), findsNothing);
      expect(deleter.deleting, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
