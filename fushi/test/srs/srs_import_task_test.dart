// BUG-3540 / BUG-3541：牌组列表刷新与后台导入。
//
// - 后台导入控制器：串行、进度、完成 / 失败回调、完成后让牌组列表重读、迁移用的临时包结束后删除。
// - 任务条（MD3 / Apple）：运行中显示进度条，结束后显示结果与「关闭」。
// - 牌组列表：新建牌组后列表只等牌组行重读，不等同步冲突扫描（冲突数是另一个 provider）。
// - 删牌组（BUG-3543）：删除进行中行变成「正在删除」+ 进度条且不可点，删完立即从列表消失。
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
  }) {
    final _Pending p = _Pending(file, onProgress);
    calls.add(p);
    return p.done.future;
  }
}

class _Pending {
  _Pending(this.file, this.onProgress);

  final File file;
  final void Function(double progress) onProgress;
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
        job: (void Function(double progress) onProgress) {
          onProgress(0.5);
          return okJob.future;
        },
        cleanup: () async => order.add('cleanup-ok'),
      );
      final SrsImportTask bad = c.enqueueJob(
        displayName: 'User 2',
        job: (void Function(double progress) onProgress) =>
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

      runner.calls.single.done.complete(_report(12));
      await _settle(tester);
      expect(
        find.text('Imported Japanese.apkg: 12 notes added'),
        findsOneWidget,
      );
      expect(find.byType(FushiLinearProgressIndicator), findsNothing);
      final Finder dismiss = find.byKey(
        const ValueKey<String>('srs-import-task-dismiss-1'),
      );
      expect(dismiss, findsOneWidget);
      await tester.tap(dismiss);
      await _settle(tester);
      expect(c.tasks, isEmpty);
      expect(find.text('Imported Japanese.apkg: 12 notes added'), findsNothing);
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
            NativeDatabase.createInBackground(File('${tmp.path}/srs.db')),
          );
          return (
            db,
            await SrsDbStore.open(
              db: db,
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
      // 确认框：标题与确认按钮同名，按钮在后。
      await tester.tap(find.text(t.srs_deck_delete).last);
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
  }
}
