// 开发者回复的被动发现：没有未结案反馈不发请求；15 分钟节流（时间戳落盘）；刷新失败不记
// 时间戳；同一批新回复只提示一次，更新的回复才再提示；应用内提示带「查看」。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/feedback/feedback_reply_notifier.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

FeedbackTicket _ticket(
  String id, {
  FeedbackStatus status = FeedbackStatus.open,
}) => FeedbackTicket(
  id: id,
  ticket: 'T$id',
  title: id,
  category: FeedbackCategory.bug,
  createdAt: 100,
  status: status,
  updatedAt: 100,
  seenAt: 100,
);

void main() {
  late Directory root;
  late List<http.Request> requests;

  /// 服务端当前对每条工单报的 devReplyAt（null = 没有回复）；failing = 返回 503。
  Map<String, int?> replies = <String, int?>{};
  bool failing = false;
  int now = 1000000;

  /// 非 null 时，每个请求登记后都卡在这里，直到它完成（模拟一次进行中的刷新）。
  Completer<void>? gate;

  FeedbackService service() => FeedbackService(
    supportRoot: () async => root,
    client: () => LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async => MockClient((http.Request r) async {
        requests.add(r);
        final Completer<void>? held = gate;
        if (held != null) await held.future;
        if (failing) return _json(<String, dynamic>{}, 503);
        final List<dynamic> asked =
            (jsonDecode(r.body) as Map<String, dynamic>)['items']
                as List<dynamic>;
        return _json(<String, dynamic>{
          'items': <Object>[
            for (final dynamic a in asked)
              <String, dynamic>{
                'id': (a as Map<String, dynamic>)['id'],
                'category': 'bug',
                'title': 'x',
                'status': 'in_progress',
                'createdAt': 100,
                'updatedAt': replies[a['id']] ?? 100,
                'devReplyAt': replies[a['id']],
              },
          ],
        });
      }),
    ),
  );

  FeedbackReplyNotifier notifier(FeedbackService s) => FeedbackReplyNotifier(
    service: s,
    supportRoot: () async => root,
    nowMs: () => now,
  );

  /// 应用内提示的条数（0 = 这次不提示）。
  Future<int> notice(FeedbackReplyNotifier n) async {
    final FeedbackReplyCheck r = await n.check();
    return r.announce ? r.unseen : 0;
  }

  Future<void> seed(List<FeedbackTicket> tickets) =>
      FeedbackTicketStore(root).write(tickets);

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_notify_');
    requests = <http.Request>[];
    replies = <String, int?>{};
    failing = false;
    now = 1000000;
    gate = null;
  });
  tearDown(() => root.deleteSync(recursive: true));

  const int minute = 60 * 1000;

  test('没有任何反馈 / 只有已结案的反馈：完全不发请求', () async {
    final FeedbackReplyNotifier n = notifier(service());
    expect(await notice(n), 0);
    await seed(<FeedbackTicket>[
      _ticket('aaaaaaaaaa', status: FeedbackStatus.resolved),
      _ticket('bbbbbbbbbb', status: FeedbackStatus.closed),
    ]);
    expect(await notice(notifier(service())), 0);
    expect(requests, isEmpty);
  });

  test('有未结案反馈：刷新一次；15 分钟内不再发；过了窗口再发', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
    final FeedbackReplyNotifier n = notifier(service());
    expect(await notice(n), 0, reason: '没有新回复不提示');
    expect(requests, hasLength(1));

    now += 14 * minute;
    await n.check();
    expect(requests, hasLength(1), reason: '14 分钟内被节流');

    // 节流时间戳落盘：重启（新实例）也不重置。
    await notifier(service()).check();
    expect(requests, hasLength(1));

    now += 2 * minute;
    await n.check();
    expect(requests, hasLength(2), reason: '满 15 分钟再刷新');
  });

  test('新回复只提示一次；更新的回复才再提示；红点（unseenCount）照常', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa'), _ticket('bbbbbbbbbb')]);
    final FeedbackService s = service();
    final FeedbackReplyNotifier n = notifier(s);
    replies = <String, int?>{'aaaaaaaaaa': 500};
    expect(await notice(n), 1);
    expect(s.unseenCount, 1);

    // 用户没看，下个窗口同一批回复仍未读：红点在，但不重复提示。
    now += 20 * minute;
    expect(await notice(n), 0);
    expect(s.unseenCount, 1);

    // 重启后同样不重复。
    now += 20 * minute;
    expect(await notice(notifier(service())), 0);

    // 另一条有了更新的回复：再提示一次（共 2 条未读）。
    replies = <String, int?>{'aaaaaaaaaa': 500, 'bbbbbbbbbb': 900};
    now += 20 * minute;
    expect(await notice(n), 2);
  });

  test('刷新失败不记时间戳：下次前台立刻重试', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
    final FeedbackReplyNotifier n = notifier(service());
    failing = true;
    expect(await notice(n), 0);
    expect(requests, hasLength(1));
    failing = false;
    replies = <String, int?>{'aaaaaaaaaa': 500};
    expect(await notice(n), 1, reason: '失败没占用节流窗口');
    expect(requests, hasLength(2));
  });

  testWidgets('应用内提示：显示条数与「查看」；0 条不弹', (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    showFeedbackReplyNotice(ctx, 0);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('feedback-reply-notice')),
      findsNothing,
    );
    showFeedbackReplyNotice(ctx, 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.feedback_reply_notice(n: 2)), findsOneWidget);
    expect(find.text(t.feedback_reply_notice_open), findsOneWidget);
    // 反馈 eiFcN3DZQ3：被动提醒不能常驻挡住底部按钮——到时自己收起，也不补常驻
    // 提示条才有的关闭按钮。
    expect(
      find.byKey(const ValueKey<String>('fushi-snackbar-close')),
      findsNothing,
    );
    await tester.pump(kFeedbackReplyNoticeDuration);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.feedback_reply_notice(n: 2)), findsNothing);
  });

  Future<void> waitForRequests(int n) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (requests.length < n) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $n requests');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('刷新进行中再调 refresh：合并到那一次，等它结束并拿到同一个成败', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
    final FeedbackService s = service();
    final Completer<void> held = gate = Completer<void>();
    final Future<void> first = s.refresh();
    await waitForRequests(1);
    expect(s.refreshing, isTrue);

    bool secondSettled = false;
    final Future<void> second = s.refresh();
    unawaited(
      second.then<void>(
        (_) => secondSettled = true,
        onError: (Object _) => secondSettled = true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(secondSettled, isFalse, reason: '已有刷新在进行时不能立刻返回（调用方会当成功处理）');

    failing = true;
    final Future<void> firstFails = expectLater(first, throwsA(anything));
    final Future<void> secondFails = expectLater(
      second,
      throwsA(anything),
      reason: '合并进来的调用必须拿到那次刷新的失败',
    );
    held.complete();
    await firstFails;
    await secondFails;
    expect(requests, hasLength(1), reason: '合并而不是再发一轮');
    expect(s.refreshing, isFalse);
  });

  test('反馈中心的刷新进行中触发被动检查：等那次刷新结束；失败不记时间戳', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
    final FeedbackService s = service();
    final FeedbackReplyNotifier n = notifier(s);
    final Completer<void> held = gate = Completer<void>();
    final Future<void> center = s.refresh();
    await waitForRequests(1);

    final Future<int> checked = notice(n);
    // 让 check() 走到 service.refresh()（读本机缓存与节流状态都是本地 IO）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    failing = true;
    final Future<void> centerFails = expectLater(center, throwsA(anything));
    held.complete();
    await centerFails;
    expect(await checked, 0);

    // 修复前：check() 拿到的是「立刻返回」，把那次失败的刷新当成功记了时间戳，
    // 同一时刻再检查会被 15 分钟节流挡住、不发请求。
    gate = null;
    failing = false;
    replies = <String, int?>{'aaaaaaaaaa': 500};
    final int before = requests.length;
    expect(await notice(n), 1, reason: '失败的那次刷新没有占用节流窗口');
    expect(requests.length, greaterThan(before));
  });

  test('反馈中心的刷新进行中触发被动检查：拿到的是那次刷新落下的新进展', () async {
    await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
    final FeedbackService s = service();
    final FeedbackReplyNotifier n = notifier(s);
    replies = <String, int?>{'aaaaaaaaaa': 500};
    final Completer<void> held = gate = Completer<void>();
    final Future<void> center = s.refresh();
    await waitForRequests(1);

    final Future<int> checked = notice(n);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    held.complete();
    await center;
    expect(await checked, 1, reason: '修复前 check() 在结果落下前就读 tickets，新回复漏提示');
  });
}
