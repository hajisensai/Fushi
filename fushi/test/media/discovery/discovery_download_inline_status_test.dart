import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/discovery_download_inline_status.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import '../../helpers/source_guard.dart';

/// 发现源直链下载的行内状态（Audiobookshelf 条目页的下载入口用它）。
///
/// iOS 没有「浏览」模块（下载中心按 App Store 合规不装配），队列任务列表看不到，
/// 而用户自己服务器的下载到本机在 iOS 上保留（2026-10-27 用户拍板）——进度必须在
/// 触发下载的那一页就地可见。这里用真队列 + 注入的 resolver / 已存在的目标文件驱动
/// 状态，不起网络。

const String _source = 'abs-server-1';

DiscoveryResourceItem _item(String id) => DiscoveryResourceItem(
  sourceId: _source,
  title: 'title-$id',
  id: id,
  kind: DiscoveryMediaKind.audiobook,
  payloadKind: DiscoveryPayloadKind.httpFile,
);

Future<void> _pump(
  WidgetTester tester,
  DiscoveryDownloadQueue queue, {
  String itemId = 'book',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: DiscoveryDownloadInlineStatus(
              queue: queue,
              sourceId: _source,
              itemId: itemId,
              idleBuilder: (BuildContext context) =>
                  const Text('idle', key: ValueKey<String>('idle')),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _status(DiscoveryDownloadStatus status) =>
    find.byKey(ValueKey<String>('discovery-inline-status-${status.name}'));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('latestDiscoveryDownloadTask', () {
    test('按 sourceId + id 取最近入队的那条，含已结束任务；别的资源不串', () {
      final DiscoveryDownloadTask oldDone = DiscoveryDownloadTask.forTesting(
        item: _item('book'),
        status: DiscoveryDownloadStatus.done,
      );
      final DiscoveryDownloadTask other = DiscoveryDownloadTask.forTesting(
        item: _item('other'),
        status: DiscoveryDownloadStatus.running,
      );
      final DiscoveryDownloadTask newer = DiscoveryDownloadTask.forTesting(
        item: _item('book'),
        status: DiscoveryDownloadStatus.failed,
      );
      final List<DiscoveryDownloadTask> tasks = <DiscoveryDownloadTask>[
        oldDone,
        other,
        newer,
      ];
      expect(
        latestDiscoveryDownloadTask(tasks, sourceId: _source, id: 'book'),
        same(newer),
      );
      expect(
        latestDiscoveryDownloadTask(tasks, sourceId: _source, id: 'other'),
        same(other),
      );
      expect(
        latestDiscoveryDownloadTask(tasks, sourceId: 'elsewhere', id: 'book'),
        isNull,
        reason: '同 id 不同服务器是另一个资源',
      );
    });
  });

  testWidgets('没有任务时渲染 idle（下载按钮）', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) =>
          Completer<DiscoveryPayload>().future,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);
    expect(find.byKey(const ValueKey<String>('idle')), findsOneWidget);

    // 别的资源的任务不影响本行。
    queue.enqueue(_item('other'), destinationDir: '');
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('idle')), findsOneWidget);
  });

  testWidgets('下载中：行内状态文案 + 进度条', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) =>
          Completer<DiscoveryPayload>().future,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);

    queue.enqueue(_item('book'), destinationDir: '');
    await tester.pump();
    expect(_status(DiscoveryDownloadStatus.running), findsOneWidget);
    expect(
      find.textContaining(t.download_task_status_downloading),
      findsOneWidget,
    );
    expect(find.byType(FushiLinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('idle')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排队中：行内状态 + 不定进度，取消后回到 idle', (WidgetTester tester) async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) =>
          Completer<DiscoveryPayload>().future,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);

    // 队列单跑道：前一条一直在跑，本条停在 queued。
    queue.enqueue(_item('other'), destinationDir: '');
    queue.enqueue(_item('book'), destinationDir: '');
    await tester.pump();
    expect(_status(DiscoveryDownloadStatus.queued), findsOneWidget);
    expect(find.text(t.download_status_queued), findsOneWidget);
    final FushiLinearProgressIndicator bar = tester.widget(
      find.byType(FushiLinearProgressIndicator),
    );
    expect(bar.value, isNull, reason: '排队中没有字节进度，画不定进度');

    // 排队中的任务取消即移除 → 本行回到「下载」按钮。
    queue.cancel(queue.tasks.last);
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('idle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败：红色错误原文 + 行内重试，重试就地复活同一条任务', (WidgetTester tester) async {
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

    queue.enqueue(_item('book'), destinationDir: '');
    await tester.pump();
    await tester.pump();
    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(_status(DiscoveryDownloadStatus.failed), findsOneWidget);
    expect(
      find.textContaining('${t.manga_online_failed}: Bad state: boom'),
      findsOneWidget,
    );
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);

    fail = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery-inline-status-retry')),
    );
    await tester.pump();
    expect(queue.tasks, hasLength(1), reason: '重试不新建任务');
    expect(_status(DiscoveryDownloadStatus.running), findsOneWidget);
    queue.cancel(task);
    await tester.pump();
  });

  testWidgets('完成：显示完成与入库摘要', (WidgetTester tester) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'fushi_inline_status_',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    // 目标文件已存在 → 队列跳过下载直接入库，不碰网络。
    File('${dir.path}${Platform.pathSeparator}book.m4b').writeAsStringSync('x');
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) async =>
          const DiscoveryHttpPayload(
            url: 'https://example.com/book.m4b',
            fileName: 'book.m4b',
          ),
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(importedCount: 1, summary: 'My Book'),
    );
    addTearDown(queue.dispose);
    await _pump(tester, queue);

    // 入队放进 runAsync：队列的执行体要做真文件 IO，留在假时钟 zone 里不会推进。
    await tester.runAsync(() async {
      queue.enqueue(_item('book'), destinationDir: dir.path);
      for (int i = 0; i < 200 && !queue.tasks.single.isFinished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(queue.tasks.single.status, DiscoveryDownloadStatus.done);
    expect(_status(DiscoveryDownloadStatus.done), findsOneWidget);
    expect(
      find.text('${t.download_task_status_completed} · My Book'),
      findsOneWidget,
    );
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);
  });

  test('ABS 条目页的整本与单集下载都接行内状态，身份与入队的同一条', () {
    final String page = compactCode(
      File(
        'lib/src/pages/implementations/audiobookshelf/'
        'audiobookshelf_item_page.dart',
      ).readAsStringSync(),
    );
    expect(
      page,
      contains(
        'DiscoveryDownloadInlineStatus(key:ValueKey<String>('
        "'abs-download-status-\${_resourceIdFor(episode)}'),"
        'queue:_appModel.discoveryDownloadQueue,sourceId:_sourceId,'
        'itemId:_resourceIdFor(episode),',
      ),
    );
    expect(page, contains('item:_resourceFor(episode),'));
    expect(page, contains('sourceId:_sourceId,id:_resourceIdFor(episode),'));
    // 整本：idle 是下载按钮；单集：下载从菜单触发，行内只在有任务时出现。
    expect(
      page,
      contains(
        'if(userConfiguredServersAvailable)...<Widget>[SizedBox('
        'height:tokens.spacing.gap),_downloadStatus(null,',
      ),
    );
    expect(
      page,
      contains(
        'downloadStatus:userConfiguredServersAvailable?_downloadStatus('
        'episode,',
      ),
    );
  });
}
