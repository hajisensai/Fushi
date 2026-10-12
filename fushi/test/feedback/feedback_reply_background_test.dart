// 反馈回复的系统通知：后台 isolate 检查（只读清单、只推进水位）、与前台 snackbar 共用
// 水位去重、开关 ↔ 后台排程、桌面定时 tick 的去向、首次提交后只申请一次权限、通知
// 载荷与点击直达工单详情。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/feedback/feedback_reply_alerts.dart';
import 'package:fushi/src/feedback/feedback_reply_background.dart';
import 'package:fushi/src/feedback/feedback_reply_notifier.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_center_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_detail_page.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi_core/fushi_core.dart';
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
  int seenAt = 100,
}) => FeedbackTicket(
  id: id,
  ticket: 'T$id',
  title: 'title-$id',
  category: FeedbackCategory.bug,
  createdAt: 100,
  status: status,
  updatedAt: 100,
  seenAt: seenAt,
);

class _FakeScheduler implements FeedbackReplyBackgroundScheduler {
  _FakeScheduler({this.supported = true});

  @override
  final bool supported;

  final List<String> calls = <String>[];

  @override
  Future<void> schedule() async => calls.add('schedule');

  @override
  Future<void> cancel() async => calls.add('cancel');
}

void main() {
  late Directory root;
  late List<http.Request> requests;

  /// 服务端对每条工单报的 devReplyAt（null = 没有回复）。
  Map<String, int?> replies = <String, int?>{};
  int now = 1000000;
  const int minute = 60 * 1000;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    // 只认批量查进度；详情等别的请求一律 404（详情页显示错误态即可）。
    if (!r.url.path.endsWith('/feedback/status')) {
      return _json(<String, dynamic>{'error': 'not_found'}, 404);
    }
    final List<dynamic> asked =
        (jsonDecode(r.body) as Map<String, dynamic>)['items'] as List<dynamic>;
    return _json(<String, dynamic>{
      'items': <Object>[
        for (final dynamic a in asked)
          <String, dynamic>{
            'id': (a as Map<String, dynamic>)['id'],
            'category': 'bug',
            'title': 'server-${a['id']}',
            'status': 'in_progress',
            'createdAt': 100,
            'updatedAt': replies[a['id']] ?? 100,
            'devReplyAt': replies[a['id']],
          },
      ],
    });
  }

  LeaderboardClient client(Uri baseUrl) => LeaderboardClient(
    baseUrl: baseUrl,
    httpClientFactory: () async => MockClient(handle),
  );

  FeedbackService service() => FeedbackService(
    supportRoot: () async => root,
    client: () => client(Uri.parse('https://rank.example')),
  );

  FeedbackReplyNotifier checker(FeedbackService s) => FeedbackReplyNotifier(
    service: s,
    supportRoot: () async => root,
    nowMs: () => now,
  );

  Future<List<FeedbackReplyAlert>> poll() => pollFeedbackRepliesInBackground(
    supportRoot: root,
    client: client,
    defaultBaseUrl: Uri.parse('https://rank.example'),
    nowMs: now,
  );

  Future<void> seed(List<FeedbackTicket> tickets) =>
      FeedbackTicketStore(root).write(tickets);

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_bg_');
    requests = <http.Request>[];
    replies = <String, int?>{};
    now = 1000000;
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('通知载荷 / id', () {
    test('载荷往返；更新中心的 JSON 载荷与空值不认', () {
      final String p = encodeFeedbackNotificationPayload('abc123');
      expect(decodeFeedbackNotificationPayload(p), 'abc123');
      expect(
        decodeFeedbackNotificationPayload('{"kind":"video","entryId":"x"}'),
        isNull,
      );
      expect(decodeFeedbackNotificationPayload(null), isNull);
      expect(decodeFeedbackNotificationPayload('fushi-feedback:'), isNull);
    });

    test('通知 id 按反馈 id 稳定派生、落在更新中心之外的区间', () {
      expect(feedbackNotificationId('a1'), feedbackNotificationId('a1'));
      expect(feedbackNotificationId('a1'), isNot(feedbackNotificationId('a2')));
      expect(feedbackNotificationId('a1') >= 0x40000000, isTrue);
      final UpdateNotification n = feedbackReplyNotification(
        const FeedbackReplyAlert(id: 'a1', title: 'T', devReplyAt: 5),
        title: 'reply',
      );
      expect(decodeFeedbackNotificationPayload(n.payload), 'a1');
      expect(n.body, 'T');
      expect(n.grouped, isFalse);
    });
  });

  group('后台 isolate 检查', () {
    test('没有未结案反馈：不发请求', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa', status: FeedbackStatus.resolved),
      ]);
      expect(await poll(), isEmpty);
      expect(requests, isEmpty);
    });

    test('主 isolate 15 分钟内刚刷新过：交给它，不发请求', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      await FeedbackReplyStateStore(root).update(
        (FeedbackReplyState s) => s.copyWith(lastRefreshAt: now - 5 * minute),
      );
      expect(await poll(), isEmpty);
      expect(requests, isEmpty);
    });

    test('新回复只提醒一次；不写 tickets.json；用主 isolate 写下的服务器', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb'),
      ]);
      await FeedbackReplyStateStore(root).update(
        (FeedbackReplyState s) =>
            s.copyWith(serverUrl: 'https://custom.example'),
      );
      final String before = FeedbackTicketStore(root).file.readAsStringSync();
      replies = <String, int?>{'aaaaaaaaaa': 500};

      final List<FeedbackReplyAlert> first = await poll();
      expect(first.map((FeedbackReplyAlert a) => a.id), <String>['aaaaaaaaaa']);
      expect(first.single.title, 'server-aaaaaaaaaa');
      expect(requests.single.url.host, 'custom.example');
      expect(
        FeedbackTicketStore(root).file.readAsStringSync(),
        before,
        reason: '后台不写清单（主 isolate 可能同时在写）',
      );
      expect((await FeedbackReplyStateStore(root).read()).notifiedReplyAt, 500);

      now += 20 * minute;
      expect(await poll(), isEmpty, reason: '同一条回复不再提醒');
      replies = <String, int?>{'aaaaaaaaaa': 500, 'bbbbbbbbbb': 900};
      now += 20 * minute;
      expect((await poll()).map((FeedbackReplyAlert a) => a.id), <String>[
        'bbbbbbbbbb',
      ]);
    });

    test('用户已经看过的回复（seenAt ≥ devReplyAt）不提醒', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa', seenAt: 600)]);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      expect(await poll(), isEmpty);
    });

    test('任务本体：有新回复就发系统通知，载荷带反馈 id，标题取状态文件', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      await FeedbackReplyStateStore(
        root,
      ).update((FeedbackReplyState s) => s.copyWith(alertTitle: '开发者回复了你的反馈'));
      replies = <String, int?>{'aaaaaaaaaa': 500};
      final RecordingUpdateNotifier n = RecordingUpdateNotifier();
      final bool ok = await runFeedbackReplyBackgroundTask(
        notifier: n,
        supportRoot: () async => root,
        client: client,
        nowMs: () => now,
      );
      expect(ok, isTrue);
      expect(n.sent, hasLength(1));
      expect(n.sent.single.title, '开发者回复了你的反馈');
      expect(
        decodeFeedbackNotificationPayload(n.sent.single.payload),
        'aaaaaaaaaa',
      );
      expect(n.requestPermissionCalls, 0, reason: '后台绝不弹权限框');
    });

    test('没授权：什么都不发，但水位照样推进（不反复重试同一条）', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      final RecordingUpdateNotifier n = RecordingUpdateNotifier(
        permission: false,
      );
      await runFeedbackReplyBackgroundTask(
        notifier: n,
        supportRoot: () async => root,
        client: client,
        nowMs: () => now,
      );
      expect(n.sent, isEmpty);
      expect((await FeedbackReplyStateStore(root).read()).notifiedReplyAt, 500);
    });
  });

  group('与前台 snackbar 共用水位', () {
    test('后台已通知过的回复，回到前台不再弹 snackbar（红点照常）', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      expect(await poll(), hasLength(1));

      final FeedbackService s = service();
      final FeedbackReplyCheck r = await checker(s).check();
      expect(r.announce, isFalse);
      expect(r.unseen, 1);
      expect(s.unseenCount, 1);
    });

    test('前台已提示过的回复，后台不再发系统通知', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      expect((await checker(service()).check()).announce, isTrue);

      now += 20 * minute;
      expect(await poll(), isEmpty);
    });
  });

  group('FeedbackReplyAlerts', () {
    late bool enabled;
    late _FakeScheduler scheduler;
    late RecordingUpdateNotifier notifier;

    FeedbackReplyAlerts alerts({bool supported = true}) {
      scheduler = _FakeScheduler(supported: supported);
      return FeedbackReplyAlerts(
        checker: checker(service()),
        systemNotifier: notifier,
        scheduler: scheduler,
        readEnabled: () => enabled,
        writeEnabled: (bool v) async => enabled = v,
        serverUrl: () async => 'https://custom.example',
        alertTitle: () => 'TITLE',
      );
    }

    setUp(() {
      enabled = true;
      notifier = RecordingUpdateNotifier();
    });

    test('开 + 有未结案 → 排后台任务并写下运行环境；关 → 撤掉', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      final FeedbackReplyAlerts a = alerts();
      await a.syncSchedule();
      expect(scheduler.calls, <String>['schedule']);
      final FeedbackReplyState st = await FeedbackReplyStateStore(root).read();
      expect(st.serverUrl, 'https://custom.example');
      expect(st.alertTitle, 'TITLE');

      await a.setEnabled(false);
      expect(enabled, isFalse);
      expect(scheduler.calls, <String>['schedule', 'cancel']);
    });

    test('没有未结案反馈：撤掉后台任务（不让系统白拉起 app）', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa', status: FeedbackStatus.closed),
      ]);
      await alerts().syncSchedule();
      expect(scheduler.calls, <String>['cancel']);
    });

    test('没有系统后台任务的平台（桌面）：不碰排程', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      await alerts(supported: false).syncSchedule();
      expect(scheduler.calls, isEmpty);
    });

    test('桌面 tick：前台 → 应用内；后台 → 系统通知；关着 → 不发请求', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb'),
      ]);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      final FeedbackReplyAlerts a = alerts(supported: false);

      final ({FeedbackReplyDelivery delivery, FeedbackReplyCheck result}) fg =
          await a.tick(foreground: true);
      expect(fg.delivery, FeedbackReplyDelivery.inApp);
      expect(notifier.sent, isEmpty);

      replies = <String, int?>{'aaaaaaaaaa': 500, 'bbbbbbbbbb': 900};
      now += 20 * minute;
      final ({FeedbackReplyDelivery delivery, FeedbackReplyCheck result}) bg =
          await a.tick(foreground: false);
      expect(bg.delivery, FeedbackReplyDelivery.system);
      expect(notifier.sent, hasLength(1), reason: '只发新的那一条');
      expect(
        decodeFeedbackNotificationPayload(notifier.sent.single.payload),
        'bbbbbbbbbb',
      );
      expect(notifier.sent.single.title, 'TITLE');

      enabled = false;
      final int before = requests.length;
      now += 20 * minute;
      expect(
        (await a.tick(foreground: false)).delivery,
        FeedbackReplyDelivery.none,
      );
      expect(requests.length, before, reason: '开关关着这条路径不发请求');
    });

    test('首次提交后申请通知权限只申请一次；开关关着 / 已授权都不申请', () async {
      notifier = RecordingUpdateNotifier(permission: false);
      final FeedbackReplyAlerts a = alerts();
      await a.requestPermissionAfterSubmit();
      await a.requestPermissionAfterSubmit();
      expect(notifier.requestPermissionCalls, 1);

      root.deleteSync(recursive: true);
      root = Directory.systemTemp.createTempSync('fushi_feedback_bg_');
      notifier = RecordingUpdateNotifier(permission: false);
      enabled = false;
      await alerts().requestPermissionAfterSubmit();
      expect(notifier.requestPermissionCalls, 0);

      enabled = true;
      notifier = RecordingUpdateNotifier();
      await alerts().requestPermissionAfterSubmit();
      expect(notifier.requestPermissionCalls, 0);
    });
  });

  group('点击通知直达工单', () {
    late LeaderboardService board;

    Future<void> pumpHost(WidgetTester tester, FeedbackService f) async {
      board = LeaderboardService(
        database: () => throw UnimplementedError(),
        supportRoot: () async => root,
        profileId: () async => 1,
        httpClientFactory: () async =>
            MockClient((http.Request _) async => http.Response('{}', 404)),
        defaultBaseUrl: Uri.parse('https://rank.example'),
        isbnBackfill: (FushiDatabase _) async => 0,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            leaderboardServiceProvider.overrideWith((Ref _) => board),
            feedbackServiceProvider.overrideWith((Ref _) => f),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: GlobalKey<NavigatorState>(debugLabel: 'root'),
              home: const Scaffold(body: SizedBox()),
            ),
          ),
        ),
      );
    }

    BuildContext navContext(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator)).context;

    testWidgets('清单里有这条 → 详情页；没有 → 反馈中心', (WidgetTester tester) async {
      await tester.runAsync(
        () => seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]),
      );
      final FeedbackService f = FeedbackService(
        supportRoot: () async => root,
        client: () => client(Uri.parse('https://rank.example')),
        meta: () async => <String, Object?>{},
        logText: () => '',
        logEncoder: (String s) => Uint8List.fromList(utf8.encode(s)),
      );
      await pumpHost(tester, f);

      // 不 await：push 的 Future 要等页面关掉才完成。清单加载是真实文件 IO，放进
      // runAsync 走完。
      Future<void> open(String id) async {
        unawaited(openFeedbackTicket(navContext(tester), id));
        for (int i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await open('aaaaaaaaaa');
      final FeedbackDetailPage page = tester.widget<FeedbackDetailPage>(
        find.byType(FeedbackDetailPage),
      );
      expect(page.feedbackId, 'aaaaaaaaaa');

      Navigator.of(navContext(tester)).pop();
      await tester.pump(const Duration(milliseconds: 600));
      await open('zzzzzzzzzz');
      expect(find.byType(FeedbackCenterPage), findsOneWidget);
      expect(find.byType(FeedbackDetailPage), findsNothing);
    });
  });
}
