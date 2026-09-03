import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';

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
                DiscoveryDownloadTasksSection(queueOverride: queue),
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
    final int mokuro = code.indexOf('const MokuroMoeTasksSection(),');
    final int direct = code.indexOf('const DiscoveryDownloadTasksSection(),');
    expect(
      direct,
      greaterThan(-1),
      reason:
          '任务 tab 必须渲染 DiscoveryDownloadTasksSection——发现页 toast'
          '「已加入下载」之后用户就是来这里找任务的',
    );
    expect(mokuro, greaterThan(-1));
    expect(direct, greaterThan(mokuro), reason: '与漫画目录队列区并列、紧随其后（同屏任务视图的固定次序）');
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
      destinationDir: '',
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
