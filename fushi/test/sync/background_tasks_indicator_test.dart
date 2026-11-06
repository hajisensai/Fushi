// 首页「后台任务」入口（2026-11-03 顶栏让位）：同步 / 复习同步各一段弧，悬停
// 文字每项一行，明细弹层随数据刷新、带补刮的「去处理」动作。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

Widget _host(Widget child) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void _reset() {
  syncInProgress.value = false;
  syncProgress.value = null;
  syncActivity.value = null;
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
      syncInProgress.value = true;
      syncProgress.value = const SyncProgress(
        phase: SyncPhase.dictionaries,
        itemIndex: 1,
        itemTotal: 4,
        title: 'Dict',
      );
      srsSyncProgress.value = const SrsSyncProgress(
        stage: SrsSyncStage.downloading,
        done: 25,
        total: 100,
      );
      final List<BackgroundTask> tasks = syncBackgroundTasks();
      expect(hasActiveSyncTasks(), isTrue);
      expect(tasks.map((BackgroundTask t) => t.id), <String>['sync', 'srs']);
      expect(tasks.first.line, contains('Dict'));
      expect(tasks.first.fraction, syncProgress.value!.fraction);
      expect(tasks.last.fraction, 0.25);
      expect(backgroundTasksIcon(tasks), FushiIcons.sync);
      expect(backgroundTasksTooltip(tasks).split('\n'), hasLength(2));
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
      syncInProgress.value = true;
      expect(syncBackgroundTasks().single.line, isNotEmpty);
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
      find.byKey(const ValueKey<String>('background-task-sync')),
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
