// 首页「后台任务」入口（2026-11-03 顶栏让位）：同步 / 复习同步各一段弧，悬停
// 文字每项一行，明细弹层随数据刷新、带补刮的「去处理」动作。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_task_board.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

Widget _host(Widget child) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void _reset() {
  resetSyncTasksForTest();
  srsSyncProgress.value = null;
  srsMigrationProgress.value = null;
}

void main() {
  setUp(_reset);
  tearDown(_reset);

  group('syncBackgroundTasks', () {
    test('空闲时没有任务', () {
      expect(hasActiveSyncTasks(), isFalse);
      expect(syncBackgroundTasks(), isEmpty);
    });

    test('常规同步与复习同步并存 → 两项，各带自己的进度', () {
      final SyncTaskHandle sweep = beginSyncTask(SyncActivityKind.fullSweep);
      sweep.progress(
        const SyncProgress(
          phase: SyncPhase.dictionaries,
          itemIndex: 1,
          itemTotal: 4,
          title: 'Dict',
        ),
      );
      srsSyncProgress.value = const SrsSyncProgress(
        stage: SrsSyncStage.downloading,
        done: 25,
        total: 100,
      );
      final List<BackgroundTask> tasks = syncBackgroundTasks();
      expect(hasActiveSyncTasks(), isTrue);
      expect(tasks.map((BackgroundTask t) => t.id), <String>[
        'sync-${sweep.id}',
        'srs',
      ]);
      expect(tasks.first.line, contains('Dict'));
      expect(tasks.first.fraction, syncProgress.value!.fraction);
      expect(
        tasks.first.icon,
        FushiIcons.dictionary,
        reason: '条目种类决定图标：在同步的是词典',
      );
      expect(tasks.last.fraction, 0.25);
      expect(backgroundTasksIcon(tasks), FushiIcons.sync);
      expect(backgroundTasksTooltip(tasks).split('\n'), hasLength(2));
    });

    test('全量 sweep 与退出书同步并发 → 各占一项；全局三值取 sweep（主任务）', () {
      final SyncTaskHandle sweep = beginSyncTask(SyncActivityKind.fullSweep);
      sweep
        ..setChannel(
          SyncChannelScope.forBackendType(SyncBackendType.fushiServer),
        )
        ..progress(
          const SyncProgress(
            phase: SyncPhase.readingData,
            itemIndex: 2,
            itemTotal: 9,
            title: 'Movie',
            itemKind: SyncItemKind.video,
          ),
        );
      final SyncTaskHandle book = beginSyncTask(SyncActivityKind.singleBook)
        ..setTitle('BookA')
        ..waiting(<Object?>[sweep]);
      final List<BackgroundTask> tasks = syncBackgroundTasks();
      expect(tasks, hasLength(2));
      expect(tasks.first.icon, FushiIcons.video, reason: '说清在同步的是视频');
      expect(tasks.first.line, contains('Movie'));
      expect(tasks.first.detail, t.sync_task_channel_interconnect);
      expect(tasks.last.line, t.sync_progress_book_titled(title: 'BookA'));
      expect(
        tasks.last.detail,
        t.sync_task_waiting_for(what: t.sync_task_kind_full_sweep),
        reason: '排队中的那轮要说清在等谁',
      );
      expect(syncActivity.value?.kind, SyncActivityKind.fullSweep);
      expect(syncProgress.value?.title, 'Movie');
      expect(syncInProgress.value, isTrue);
      book.finish();
      sweep.finish();
      expect(syncInProgress.value, isFalse);
      expect(syncProgress.value, isNull);
    });

    test('每项的失败带着阶段与条目种类；有失败的那轮结束后留在明细里', () {
      int now = 1000;
      resetSyncTasksForTest(now: () => now);
      final SyncTaskHandle sweep = beginSyncTask(SyncActivityKind.fullSweep);
      sweep.progress(
        const SyncProgress(
          phase: SyncPhase.audiobooks,
          itemIndex: 0,
          itemTotal: 2,
          title: 'AB',
        ),
      );
      now = 5000;
      sweep.error('live push audiobook "AB": boom');
      final SyncTask live = syncTasks.value.single;
      expect(live.errors.single.phase, SyncPhase.audiobooks);
      expect(live.errors.single.itemKind, SyncItemKind.audiobook);
      expect(live.stageSince, 1000, reason: '记错误不算换步，「这一步已多久」不重置');
      sweep.finish();
      expect(hasActiveSyncTasks(), isFalse);
      final BackgroundTask kept = syncBackgroundTasks().single;
      expect(kept.finished, isTrue);
      expect(kept.errors, <String>['live push audiobook "AB": boom']);
      expect(kept.detail, t.sync_task_finished_with_errors(count: 1));
      expect(
        backgroundTasksTooltip(syncBackgroundTasks()),
        isEmpty,
        reason: '已结束的不进入口气泡 / 进度环',
      );
    });

    test('没有复习同步一轮在跑时显示旧文件迁移', () {
      srsMigrationProgress.value = const SrsSyncProgress(
        stage: SrsSyncStage.migrating,
        done: 1850,
        total: 29651,
      );
      final List<BackgroundTask> tasks = syncBackgroundTasks();
      expect(tasks.single.id, 'srs-migration');
      expect(tasks.single.line, contains('1850/29651'));
      expect(backgroundTasksIcon(tasks), FushiIcons.storage);
    });

    test('常规同步还没有阶段 tick 时也有文字（BUG-1260）', () {
      beginSyncTask(SyncActivityKind.fullSweep);
      expect(syncBackgroundTasks().single.line, t.sync_progress_preparing);
    });
  });

  testWidgets('进度环一项任务一段', (WidgetTester tester) async {
    const List<BackgroundTask> tasks = <BackgroundTask>[
      BackgroundTask(id: 'a', icon: FushiIcons.sync, line: 'A', fraction: 0.5),
      BackgroundTask(id: 'b', icon: FushiIcons.sync, line: 'B'),
    ];
    await tester.pumpWidget(_host(const BackgroundTasksGlyph(tasks: tasks)));
    final FushiSegmentedProgressRing ring = tester.widget(
      find.byType(FushiSegmentedProgressRing),
    );
    expect(ring.values, <double?>[0.5, null]);
    expect(find.byIcon(FushiIcons.sync), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有任务时不画环', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const BackgroundTasksGlyph(tasks: <BackgroundTask>[])),
    );
    expect(find.byType(FushiSegmentedProgressRing), findsNothing);
  });

  testWidgets('明细弹层随数据刷新，「去处理」关弹层再跳转', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    int opened = 0;
    List<BackgroundTask> tasks() => <BackgroundTask>[
      ...syncBackgroundTasks(),
      BackgroundTask(
        id: 'video-scrape',
        icon: FushiIcons.manageSearch,
        line: 'Scrape 3/9',
        fraction: 3 / 9,
        onOpen: () => opened++,
        openLabel: 'Open',
      ),
    ];
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showBackgroundTasksSheet(
              context: context,
              listenable: Listenable.merge(<Listenable>[
                syncBackgroundTasksListenable,
                tick,
              ]),
              tasks: tasks,
            ),
            child: const Text('show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('Scrape 3/9'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('background-task-sync-1')),
      findsNothing,
    );

    srsSyncProgress.value = const SrsSyncProgress(
      stage: SrsSyncStage.downloading,
      done: 5,
      total: 10,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('background-task-srs')),
      findsOneWidget,
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Scrape 3/9'), findsNothing);
  });

  testWidgets('明细行显示通道 / 这一步已多久，失败可展开逐项查看（反馈 kM-Gb_Xnu-）', (
    WidgetTester tester,
  ) async {
    final SyncTaskHandle sweep = beginSyncTask(SyncActivityKind.fullSweep)
      ..setChannel(SyncChannelScope.forBackendType(SyncBackendType.webDav))
      ..progress(
        const SyncProgress(
          phase: SyncPhase.readingData,
          itemIndex: 0,
          itemTotal: 3,
          title: 'BookA',
          itemKind: SyncItemKind.book,
        ),
      )
      ..error('books: BookA: SocketException');
    addTearDown(sweep.finish);
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showBackgroundTasksSheet(
              context: context,
              listenable: syncBackgroundTasksListenable,
              tasks: syncBackgroundTasks,
            ),
            child: const Text('show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    final String id = 'sync-${sweep.id}';
    final Text detail = tester.widget(
      find.byKey(ValueKey<String>('background-task-detail-$id')),
    );
    expect(detail.data, startsWith(t.sync_task_channel_cloud));
    expect(detail.data, contains(t.sync_task_stage_elapsed(elapsed: '0:00')));
    expect(find.text('books: BookA: SocketException'), findsNothing);
    await tester.tap(
      find.byKey(ValueKey<String>('background-task-errors-$id')),
    );
    await tester.pumpAndSettle();
    expect(find.text('books: BookA: SocketException'), findsOneWidget);
    expect(find.text(t.sync_task_errors_count(count: 1)), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(ValueKey<String>('background-task-errors-$id')))
          .height,
      greaterThanOrEqualTo(48),
      reason: '展开开关命中区 ≥48dp',
    );
    expect(tester.takeException(), isNull);
  });

  // 用户 2026-11-06 截图：任务行贴着弹层左右边缘、进度条画出圆角、末行压底边
  // （FushiModalSheetFrame 的 body 默认零内边距，弹层没给）。宽窄两种窗口都钉。
  for (final Size size in const <Size>[Size(1280, 800), Size(360, 760)]) {
    testWidgets('明细弹层的任务行与弹层边缘留白（${size.width.toInt()} 宽）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      srsSyncProgress.value = const SrsSyncProgress(stage: SrsSyncStage.media);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showBackgroundTasksSheet(
                context: context,
                listenable: syncBackgroundTasksListenable,
                tasks: syncBackgroundTasks,
              ),
              child: const Text('show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump(const Duration(seconds: 1));
      // 在弹层自身坐标系里量：桌面对话框入场带缩放，屏幕坐标会把留白一起缩。
      final RenderBox frame = tester.renderObject(
        find.byType(FushiModalSheetFrame),
      );
      final RenderBox row = tester.renderObject(
        find.byKey(const ValueKey<String>('background-task-srs')),
      );
      final Offset rowTopLeft = frame.globalToLocal(
        row.localToGlobal(Offset.zero),
      );
      final Offset rowBottomRight = frame.globalToLocal(
        row.localToGlobal(row.size.bottomRight(Offset.zero)),
      );
      expect(rowTopLeft.dx, greaterThanOrEqualTo(24));
      expect(frame.size.width - rowBottomRight.dx, greaterThanOrEqualTo(24));
      expect(frame.size.height - rowBottomRight.dy, greaterThanOrEqualTo(16));
      expect(tester.takeException(), isNull);
    });
  }
}
