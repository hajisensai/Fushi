import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';

/// BUG-1911：「刚开始下载的、下载一半的应该也进到库里面占位。否则不知道是否加入了，
/// 毕竟发现已经获取到对应的名称和封面了」（用户 2026-08-28）。
///
/// **刻意不往 `Galgames` 表写占位行**：那张表的 `exePath` 是 NOT NULL、且没有任何状态列
/// ——一行存在就等于「本机有一个可启动的 exe」。为占位造一行意味着要么写个假路径，
/// 要么加 schema 列 + 迁移，还得回答「下载失败/取消后这行归谁删」「同步与墓碑怎么算」。
/// 而下载队列本身就是这些条目此刻的唯一真相源，并且随手带着用户说的那两样东西
/// （`item.title` / `item.coverUrl`）。所以占位是**渲染**出来的、不是**存**出来的：
/// 下载完成走既有入库路径落成真条目，失败/取消则自然消失。
DiscoveryResourceItem _item({
  required String title,
  DiscoveryMediaKind kind = DiscoveryMediaKind.game,
  String? coverUrl,
}) =>
    DiscoveryResourceItem(
      sourceId: 'shinnku',
      title: title,
      id: title,
      kind: kind,
      payloadKind: DiscoveryPayloadKind.httpFile,
      coverUrl: coverUrl,
    );

DiscoveryDownloadTask _task({
  required String title,
  DiscoveryMediaKind kind = DiscoveryMediaKind.game,
  DiscoveryDownloadStatus status = DiscoveryDownloadStatus.running,
  int receivedBytes = 0,
  int? totalBytes,
  String? coverUrl,
}) =>
    DiscoveryDownloadTask.forTesting(
      item: _item(title: title, kind: kind, coverUrl: coverUrl),
      status: status,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('pendingGameDownloads', () {
    test('只收「游戏域 + 尚未结束」的任务', () {
      final List<DiscoveryDownloadTask> tasks = <DiscoveryDownloadTask>[
        _task(title: '在下', status: DiscoveryDownloadStatus.running),
        _task(title: '排队', status: DiscoveryDownloadStatus.queued),
        _task(title: '重试', status: DiscoveryDownloadStatus.waitingRetry),
        // 已完成的会走既有入库路径变成真条目，再占位就是重复。
        _task(title: '完成', status: DiscoveryDownloadStatus.done),
        _task(title: '失败', status: DiscoveryDownloadStatus.failed),
        _task(title: '取消', status: DiscoveryDownloadStatus.cancelled),
        // 别的媒体域的下载不该出现在游戏库里。
        _task(title: '一本书', kind: DiscoveryMediaKind.novel),
      ];

      expect(
        pendingGameDownloads(tasks)
            .map((DiscoveryDownloadTask t) => t.item.title)
            .toList(),
        <String>['在下', '排队', '重试'],
      );
    });
  });

  group('pendingGameDownloadLabel', () {
    test('有总大小时显示百分比', () {
      expect(
        pendingGameDownloadLabel(_task(
          title: 'x',
          receivedBytes: 250,
          totalBytes: 1000,
        )),
        '25%',
      );
    });

    test('总大小未知时退回「下载中」而不是显示 NaN/0%', () {
      expect(
        pendingGameDownloadLabel(_task(title: 'x')),
        t.game_library_downloading,
      );
    });

    test('排队/重试各有自己的文案', () {
      expect(
        pendingGameDownloadLabel(
            _task(title: 'x', status: DiscoveryDownloadStatus.queued)),
        t.game_library_download_queued,
      );
      expect(
        pendingGameDownloadLabel(
            _task(title: 'x', status: DiscoveryDownloadStatus.waitingRetry)),
        t.game_library_download_retrying,
      );
    });
  });

  testWidgets('占位卡渲染发现页拿到的名称，并给出进度', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 168,
              height: 260,
              child: buildPendingGameDownloadCard(
                _task(title: '9-nine-', receivedBytes: 500, totalBytes: 1000),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('9-nine-'), findsOneWidget,
        reason: '名称必须来自发现页条目 —— 用户正是靠它确认「加进来了」');
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.5, 0.001));
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('没有封面时不崩，退回占位图标', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 168,
              height: 260,
              child: buildPendingGameDownloadCard(_task(title: '无封面')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  test('占位是渲染出来的，不是往 Galgames 表写假行（BUG-1911）', () {
    final String page = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();

    // 库页必须跟着下载队列刷新，否则占位卡不会随进度更新/消失。
    expect(page.contains('discoveryDownloadQueue.addListener'), isTrue);
    expect(page.contains('discoveryDownloadQueue.removeListener'), isTrue,
        reason: '监听必须解绑，否则页面销毁后队列还持有回调');

    // 占位路径绝不能碰写库原语 —— 那正是本条刻意避开的设计。
    final int start =
        page.indexOf('List<DiscoveryDownloadTask> pendingGameDownloads(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('/// 合集详情页的 game 成员卡', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);
    for (final String writer in <String>[
      'upsertGalgame(',
      'addAll(',
      'setGames(',
      'newGalgameEntryFromExe(',
    ]) {
      expect(body.contains(writer), isFalse,
          reason: '占位不得调用写库原语 $writer —— Galgames.exePath 是 NOT NULL，'
              '为占位造行等于埋下孤儿数据');
    }
  });
}
