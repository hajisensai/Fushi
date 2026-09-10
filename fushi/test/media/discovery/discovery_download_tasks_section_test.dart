import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';

import '../../helpers/source_guard.dart';

/// BUG-1936：发现页直链下载队列（游戏 / 小说 / 有声书）必须出现在下载页任务 tab。
///
/// 队列本体是内存 [DiscoveryDownloadQueue]，这里用真队列 + 注入的 payload
/// resolver 驱动状态（永不完成 = 执行中 / 抛非瞬时错 = 失败），不起网络。

DiscoveryResourceItem _item(
  String id, {
  DiscoveryMediaKind kind = DiscoveryMediaKind.game,
  String? title,
}) => DiscoveryResourceItem(
  sourceId: 'src',
  title: title ?? 'title-$id',
  id: id,
  kind: kind,
  payloadKind: DiscoveryPayloadKind.httpFile,
  payload: const DiscoveryHttpPayload(url: 'https://example.com/a.zip'),
);

/// 永不完成的 resolver：任务停在 running，队列后面的停在 queued。
DiscoveryDownloadQueue _hangingQueue() => DiscoveryDownloadQueue(
  resolvePayload: (DiscoveryResourceItem item) =>
      Completer<DiscoveryPayload>().future,
  importer: (DiscoveryDownloadTask task, File file) async =>
      const DiscoveryImportOutcome(),
);

Future<void> _pump(
  WidgetTester tester,
  DiscoveryDownloadQueue queue, {
  Size size = const Size(800, 700),
  Future<bool> Function(String path)? pathRevealer,
  RevealHost? Function()? revealHostProbe,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                DiscoveryDownloadTasksSection(
                  queueOverride: queue,
                  pathRevealer: pathRevealer,
                  // 默认按桌面渲染：这套行的动作在三桌面端都在，测试不该跟着
                  // 跑测试的宿主平台变结论（CI 是 Linux，本机是 Windows）。
                  revealHostProbe: revealHostProbe ?? () => RevealHost.windows,
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _row(String id) =>
    find.byKey(ValueKey<String>('discovery-download-src-$id'));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('下载页任务 tab 挂了直链队列区块（BUG-1936 接线守卫）', () {
    final File f = File('lib/src/pages/implementations/downloads_page.dart');
    expect(
      f.existsSync(),
      isTrue,
      reason: '找不到 downloads_page.dart（路径变了要同步本守卫）',
    );
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());
    final int mokuro = code.indexOf('MokuroMoeTasksSection(');
    final int direct = code.indexOf('DiscoveryDownloadTasksSection(');
    expect(
      direct,
      greaterThan(-1),
      reason:
          '任务 tab 必须渲染 DiscoveryDownloadTasksSection——发现页 toast'
          '「已加入下载」之后用户就是来这里找任务的',
    );
    expect(mokuro, greaterThan(-1));
    expect(code, contains('tasksBuilder:'));
    expect(code, contains('additionalTasks:'));
    expect(code, contains('unified: true'));
    expect(code, isNot(contains('legacyHeight')));
  });

  testWidgets('队列为空不占位', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = _hangingQueue();
    addTearDown(queue.dispose);
    await _pump(tester, queue);
    expect(find.byType(DiscoveryDownloadTasksSection), findsOneWidget);
    expect(find.textContaining(t.download_direct_queue_section), findsNothing);
  });

  testWidgets('入队后出现区块：标题带计数、每条带域标签与状态、可取消排队中的任务', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = _hangingQueue();
    addTearDown(queue.dispose);
    await _pump(tester, queue);

    queue.enqueue(_item('g1', title: 'Game One'), destinationDir: '');
    queue.enqueue(
      _item('n1', kind: DiscoveryMediaKind.novel, title: 'Novel One'),
      destinationDir: '',
    );
    await tester.pump();

    expect(
      find.text('${t.download_direct_queue_section} (0/2)'),
      findsOneWidget,
    );
    expect(_row('g1'), findsOneWidget);
    expect(_row('n1'), findsOneWidget);
    expect(find.text('Game One'), findsOneWidget);
    expect(
      find.text(
        '${discoveryMediaKindLabel(DiscoveryMediaKind.game)} · '
        '${t.download_task_status_downloading} · 0 B',
      ),
      findsOneWidget,
      reason: '首个任务已被队列拿去执行（总大小未知 → 只报已收字节）',
    );
    expect(
      find.text(
        '${discoveryMediaKindLabel(DiscoveryMediaKind.novel)} · '
        '${t.download_status_queued}',
      ),
      findsOneWidget,
      reason: '第二个排队中；域标签让用户一眼分清是游戏还是小说',
    );

    // 取消排队中的小说任务：排队态取消 = 直接移出队列。
    await tester.tap(
      find.descendant(of: _row('n1'), matching: find.byIcon(Icons.close)),
    );
    await tester.pump();
    expect(_row('n1'), findsNothing);
    expect(
      find.text('${t.download_direct_queue_section} (0/1)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败任务：红色错误文案 + 行内重试 + 头部「重试」批量入口', (WidgetTester tester) async {
    bool fail = true;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) {
        if (fail) throw StateError('boom');
        return Completer<DiscoveryPayload>().future;
      },
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);

    queue.enqueue(_item('g1', title: 'Game One'), destinationDir: '');
    // StateError 不是瞬时错误 → 不自动退避重试，直接落 failed。
    await tester.pump();
    await tester.pump();
    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(
      find.text('${t.download_direct_queue_section} (1/1)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('${t.manga_online_failed}: Bad state: boom'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-download-retry-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-download-clear-finished')),
      findsOneWidget,
      reason: 'failed 是终态，可被「清除已完成」清掉',
    );

    // 行内重试：就地复活同一任务对象（不是再入队一条同名任务）。
    fail = false;
    await tester.tap(
      find.descendant(of: _row('g1'), matching: find.byIcon(Icons.refresh)),
    );
    await tester.pump();
    expect(queue.tasks.single, same(task));
    expect(task.status, DiscoveryDownloadStatus.running);
    expect(
      find.text('${t.download_direct_queue_section} (0/1)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('行内「打开文件位置」调文件管理器；失败出声', (
    WidgetTester tester,
  ) async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) =>
          throw StateError('boom'),
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    final List<String> revealed = <String>[];
    await _pump(
      tester,
      queue,
      pathRevealer: (String path) async {
        revealed.add(path);
        return false; // 路径已不在 / 启动失败
      },
    );
    queue.enqueue(_item('g1', title: 'Game One'), destinationDir: r'C:\dl');
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-download-src-g1-location')),
    );
    await tester.pump();
    await tester.pump();
    expect(revealed, <String>[r'C:\dl']);
    expect(
      find.text(t.download_task_location_open_failed),
      findsOneWidget,
      reason: 'reveal 失败必须出声，不能点了什么都不发生',
    );
  });

  test('打开文件位置的目标：落盘文件优先于目标目录，都没有则不画按钮', () {
    DiscoveryDownloadTask task({String dir = '', String? filePath}) =>
        DiscoveryDownloadTask.forTesting(
          item: _item('x'),
          destinationDir: dir,
          filePath: filePath,
        );
    expect(
      discoveryDownloadRevealTarget(
        task(dir: r'C:\dl', filePath: r'C:\dl.zip'),
      ),
      r'C:\dl.zip',
      reason: '下完了就选中文件本身，用户要的是那个文件',
    );
    expect(
      discoveryDownloadRevealTarget(task(dir: r'C:\dl')),
      r'C:\dl',
      reason: '还没下完只能打开目标目录',
    );
    expect(discoveryDownloadRevealTarget(task()), isNull);
    expect(discoveryDownloadRevealTarget(task(dir: '  ')), isNull);
  });

  testWidgets('行内「删除任务」：确认后摘行、文件留着；取消则什么都不做', (
    WidgetTester tester,
  ) async {
    // 用「必失败」的 resolver 让两条都停在终态：running 行的进度环是无限动画，
    // 会让确认框的 pumpAndSettle 永远等不到静止。
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) =>
          throw StateError('boom'),
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);
    queue.enqueue(_item('g1', title: 'Game One'), destinationDir: r'C:\dl');
    queue.enqueue(
      _item('g2', title: 'Game Two'),
      destinationDir: r'C:\dl',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(queue.totalCount, 2);
    expect(
      queue.tasks.every((DiscoveryDownloadTask t) => t.isFinished),
      isTrue,
    );

    Finder deleteButton(String id) =>
        find.byKey(ValueKey<String>('discovery-download-src-$id-delete'));

    // 取消确认：任务留着。
    await tester.tap(deleteButton('g1'));
    await tester.pumpAndSettle();
    expect(
      find.text(t.download_task_delete_files),
      findsNothing,
      reason: '直链行不提供「同时删除已下载文件」——完成的文件已经入库',
    );
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(queue.totalCount, 2);
    expect(_row('g1'), findsOneWidget);

    // 确认：这行消失。
    await tester.tap(deleteButton('g1'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'video-download-job-delete-confirm-discovery-src-g1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(queue.totalCount, 1);
    expect(_row('g1'), findsNothing);
    expect(_row('g2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动端没有文件管理器契约：隐藏「打开文件位置」，删除仍在', (
    WidgetTester tester,
  ) async {
    final DiscoveryDownloadQueue queue = _hangingQueue();
    addTearDown(queue.dispose);
    await _pump(tester, queue, revealHostProbe: () => null);
    queue.enqueue(_item('g1', title: 'Game One'), destinationDir: '/sdcard/dl');
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('discovery-download-src-g1-location')),
      findsNothing,
      reason: '画一个点了没反应的按钮比没有按钮更糟',
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-download-src-g1-delete')),
      findsOneWidget,
    );
  });

  testWidgets('360 逻辑像素宽不溢出', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = _hangingQueue();
    addTearDown(queue.dispose);
    await _pump(tester, queue, size: const Size(360, 640));
    queue.enqueue(
      _item(
        'g1',
        title:
            'A very long game title that keeps going and going '
            'to force wrapping on narrow phones',
      ),
      // 非空目录 = 「打开文件位置」也在 → 量的是三个动作全在的最宽形态。
      destinationDir: r'C:\dl',
    );
    await tester.pump();
    expect(_row('g1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('discoveryDownloadStatusLabel', () {
    DiscoveryDownloadTask task({
      DiscoveryDownloadStatus status = DiscoveryDownloadStatus.running,
      int received = 0,
      int? total,
    }) => DiscoveryDownloadTask.forTesting(
      item: _item('x'),
      status: status,
      receivedBytes: received,
      totalBytes: total,
    );

    test('下载中有总大小 → 已收/总 + 百分比；无总大小 → 只报已收', () {
      expect(
        discoveryDownloadStatusLabel(
          task(received: 512 * 1024 * 1024, total: 2048 * 1024 * 1024),
          3,
        ),
        '${t.download_task_status_downloading} · 512 MiB / 2.0 GiB (25%)',
      );
      expect(
        discoveryDownloadStatusLabel(task(received: 900), 3),
        '${t.download_task_status_downloading} · 900 B',
      );
      expect(discoveryDownloadProgress(task(received: 1, total: 4)), 0.25);
      expect(
        discoveryDownloadProgress(task(received: 1)),
        isNull,
        reason: '总大小未知 → 不定进度环',
      );
    });

    test('完成：入库摘要优先；排队/取消走各自文案', () {
      final DiscoveryDownloadTask done =
          task(status: DiscoveryDownloadStatus.done)
            ..importOutcome = const DiscoveryImportOutcome(
              importedCount: 1,
              summary: 'Imported: Game One',
            );
      expect(
        discoveryDownloadStatusLabel(done, 3),
        '${t.download_task_status_completed} · Imported: Game One',
      );
      expect(
        discoveryDownloadStatusLabel(
          task(status: DiscoveryDownloadStatus.done),
          3,
        ),
        t.download_task_status_completed,
      );
      expect(
        discoveryDownloadStatusLabel(
          task(status: DiscoveryDownloadStatus.queued),
          3,
        ),
        t.download_status_queued,
      );
      expect(
        discoveryDownloadStatusLabel(
          task(status: DiscoveryDownloadStatus.cancelled),
          3,
        ),
        t.download_status_cancelled,
      );
    });
  });
}
