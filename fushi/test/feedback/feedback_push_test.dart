// iOS 远程推送（feedback_push.dart）：令牌登记对齐（开关 / 权限 / 结案 / 换令牌）、被推送
// 覆盖的反馈不再由本机路径重复提醒、原生半边与 CI 签名接线。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_push.dart';
import 'package:fushi/src/feedback/feedback_reply_notifier.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

FeedbackTicket _ticket(
  String id, {
  FeedbackStatus status = FeedbackStatus.open,
  bool viaAccount = false,
}) => FeedbackTicket(
  id: id,
  ticket: viaAccount ? '' : 'T$id',
  title: 'title-$id',
  category: FeedbackCategory.bug,
  createdAt: 100,
  status: status,
  updatedAt: 100,
  seenAt: 100,
);

class _FakePush implements RemotePushPlatform {
  _FakePush({this.token, this.supported = true});

  String? token;

  @override
  final bool supported;

  int tokenCalls = 0;

  @override
  Future<String?> deviceToken() async {
    tokenCalls++;
    return token;
  }

  @override
  Future<String?> takeLaunchFeedbackId() async => null;

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Stream<String> get foregroundPushes => const Stream<String>.empty();
}

const String _tokenA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _tokenB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory root;
  late List<http.Request> requests;
  Map<String, int?> replies = <String, int?>{};
  bool delivering = true;

  /// 反馈 id → 服务端对它的 PUT /push 回的错误状态码（模拟服务端已单方面删令牌 / 限流）。
  Map<String, int> pushErrors = <String, int>{};

  /// 反馈 id → 该条 PUT 时服务端答复的 delivering（缺省用 [delivering]）。
  Map<String, bool> deliveringById = <String, bool>{};
  int now = 1000000;
  const int minute = 60 * 1000;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (r.url.path.endsWith('/push')) {
      final String id = r.url.pathSegments[2];
      final int? err = pushErrors[id];
      if (err != null) return _json(<String, dynamic>{'error': 'x'}, err);
      return _json(<String, dynamic>{
        'registered': r.method == 'PUT',
        if (r.method == 'PUT') 'delivering': deliveringById[id] ?? delivering,
      });
    }
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

  LeaderboardIdentity? identity;

  LeaderboardClient client([Uri? baseUrl]) => LeaderboardClient(
    baseUrl: baseUrl ?? Uri.parse('https://rank.example'),
    httpClientFactory: () async => MockClient(handle),
    identity: identity,
  );

  Future<void> seed(List<FeedbackTicket> tickets) =>
      FeedbackTicketStore(root).write(tickets);

  FeedbackPushRegistrar registrar(
    _FakePush push, {
    bool enabled = true,
    bool permitted = true,
    Future<List<FeedbackTicket>> Function()? tickets,
  }) => FeedbackPushRegistrar(
    platform: push,
    tickets: tickets ?? () => FeedbackTicketStore(root).read(),
    client: client,
    stateStore: () async => FeedbackReplyStateStore(root),
    enabled: () => enabled,
    permitted: () async => permitted,
    lang: () => 'zh-CN',
    nowMs: () => now,
  );

  List<String> pushCalls() => <String>[
    for (final http.Request r in requests)
      if (r.url.path.endsWith('/push'))
        '${r.method} ${r.url.pathSegments[2]} '
            '${(jsonDecode(r.body) as Map<String, dynamic>)['token']}',
  ];

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_push_');
    requests = <http.Request>[];
    replies = <String, int?>{};
    delivering = true;
    pushErrors = <String, int>{};
    deliveringById = <String, bool>{};
    identity = null;
    now = 1000000;
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('令牌登记对齐', () {
    test('未结案的凭 ticket 登记一次；已结案的不登记；再 sync 不重复请求', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb', status: FeedbackStatus.resolved),
      ]);
      final _FakePush push = _FakePush(token: _tokenA);
      final FeedbackPushSyncResult r = await registrar(push).sync();
      expect(r.registered, <String>['aaaaaaaaaa']);
      expect(r.delivering, isTrue);
      expect(pushCalls(), <String>['PUT aaaaaaaaaa $_tokenA']);
      final http.Request put = requests.single;
      expect(put.headers['X-Fushi-Ticket'], 'Taaaaaaaaaa');
      expect(jsonDecode(put.body)['lang'], 'zh-CN');

      final FeedbackReplyState s = await FeedbackReplyStateStore(root).read();
      expect(s.pushToken, _tokenA);
      expect(s.pushRegistrations.keys, <String>['aaaaaaaaaa']);
      expect(s.pushCovered, <String>{'aaaaaaaaaa'});

      requests.clear();
      await registrar(push).sync();
      expect(pushCalls(), isEmpty, reason: '复核间隔内不重复登记');

      now += 20 * minute;
      await registrar(push).sync();
      expect(pushCalls(), <String>[
        'PUT aaaaaaaaaa $_tokenA',
      ], reason: '过了复核间隔向服务端重新登记（服务端可能已单方面删了令牌）');
    });

    test('服务端单方面删了令牌：复核 PUT 失败 → 不再算推送覆盖；服务端恢复后自愈', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      final _FakePush push = _FakePush(token: _tokenA);
      await registrar(push).sync();
      expect((await FeedbackReplyStateStore(root).read()).pushCovered, <String>{
        'aaaaaaaaaa',
      });

      // 例如反馈被结案清令牌后又被重开、本机清单还没刷新：服务端回 404。
      pushErrors = <String, int>{'aaaaaaaaaa': 404};
      now += 20 * minute;
      await registrar(push).sync();
      FeedbackReplyState s = await FeedbackReplyStateStore(root).read();
      expect(s.pushCovered, isEmpty, reason: 'PUT 成功才算覆盖');
      expect(s.pushRegistrations, isEmpty);

      // 本机路径因此照常提醒这条的新回复。
      replies = <String, int?>{'aaaaaaaaaa': 500};
      final List<FeedbackReplyAlert> bg = await pollFeedbackRepliesInBackground(
        supportRoot: root,
        client: (Uri u) => client(u),
        defaultBaseUrl: Uri.parse('https://rank.example'),
        nowMs: now,
      );
      expect(bg.map((FeedbackReplyAlert a) => a.id), <String>['aaaaaaaaaa']);

      // 失败的那条下次 sync 立刻重试（不等复核间隔），成功即恢复覆盖。
      pushErrors = <String, int>{};
      requests.clear();
      await registrar(push).sync();
      expect(pushCalls(), <String>['PUT aaaaaaaaaa $_tokenA']);
      s = await FeedbackReplyStateStore(root).read();
      expect(s.pushCovered, <String>{'aaaaaaaaaa'});
    });

    test('delivering 逐条记录：只有服务端答复会推送的那条算覆盖', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb'),
      ]);
      deliveringById = <String, bool>{'bbbbbbbbbb': false};
      await registrar(_FakePush(token: _tokenA)).sync();
      final FeedbackReplyState s = await FeedbackReplyStateStore(root).read();
      expect(s.pushRegistrations.keys.toSet(), <String>{
        'aaaaaaaaaa',
        'bbbbbbbbbb',
      });
      expect(s.pushCovered, <String>{'aaaaaaaaaa'});
    });

    test('账户条目（没有 ticket）凭账户签名登记、注销', () async {
      identity = LeaderboardIdentity.generate(random: Random(3));
      List<FeedbackTicket> mine = <FeedbackTicket>[
        _ticket('cccccccccc', viaAccount: true),
      ];
      final _FakePush push = _FakePush(token: _tokenA);
      await registrar(push, tickets: () async => mine).sync();
      expect(pushCalls(), <String>['PUT cccccccccc $_tokenA']);
      final http.Request put = requests.single;
      expect(put.headers.containsKey('X-Fushi-Ticket'), isFalse);
      expect(put.headers['X-Fushi-Account'], identity!.accountId);
      expect((await FeedbackReplyStateStore(root).read()).pushCovered, <String>{
        'cccccccccc',
      });

      requests.clear();
      mine = <FeedbackTicket>[
        _ticket('cccccccccc', viaAccount: true, status: FeedbackStatus.closed),
      ];
      await registrar(push, tickets: () async => mine).sync();
      expect(pushCalls(), <String>['DELETE cccccccccc $_tokenA']);
      expect(requests.single.headers['X-Fushi-Account'], identity!.accountId);
    });

    test(
      '旧版状态文件（pushRegistered + 全局 pushDelivering）平滑迁移、下次 sync 立即复核',
      () async {
        await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
        final File f = FeedbackReplyStateStore(root).file;
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(
          jsonEncode(<String, dynamic>{
            'lastRefreshAt': 0,
            'notifiedReplyAt': 0,
            'pushToken': _tokenA,
            'pushRegistered': <String>['aaaaaaaaaa'],
            'pushDelivering': true,
          }),
        );
        final FeedbackReplyState old = await FeedbackReplyStateStore(
          root,
        ).read();
        expect(old.pushCovered, <String>{'aaaaaaaaaa'});
        expect(old.pushRegistrations['aaaaaaaaaa']!.confirmedAt, 0);

        await registrar(_FakePush(token: _tokenA)).sync();
        expect(pushCalls(), <String>['PUT aaaaaaaaaa $_tokenA']);
        expect(
          (await FeedbackReplyStateStore(
            root,
          ).read()).pushRegistrations['aaaaaaaaaa']!.confirmedAt,
          now,
        );
      },
    );

    test('反馈结案 → 注销；开关关 → 全部注销并清空状态', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb'),
      ]);
      final _FakePush push = _FakePush(token: _tokenA);
      await registrar(push).sync();
      requests.clear();

      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa', status: FeedbackStatus.closed),
        _ticket('bbbbbbbbbb'),
      ]);
      await registrar(push).sync();
      expect(pushCalls(), <String>['DELETE aaaaaaaaaa $_tokenA']);
      expect(
        (await FeedbackReplyStateStore(root).read()).pushRegistrations.keys,
        <String>['bbbbbbbbbb'],
      );

      requests.clear();
      await registrar(push, enabled: false).sync();
      expect(pushCalls(), <String>['DELETE bbbbbbbbbb $_tokenA']);
      expect(push.tokenCalls, 2, reason: '关着不再向系统要令牌');
      final FeedbackReplyState s = await FeedbackReplyStateStore(root).read();
      expect(s.pushToken, isNull);
      expect(s.pushRegistrations, isEmpty);
      expect(s.pushCovered, isEmpty);
    });

    test('没授权 / 拿不到令牌（缺 entitlement）：不登记', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      await registrar(_FakePush(token: _tokenA), permitted: false).sync();
      await registrar(_FakePush()).sync();
      expect(pushCalls(), isEmpty);
      expect((await FeedbackReplyStateStore(root).read()).pushToken, isNull);
    });

    test('令牌变了：旧令牌注销、新令牌登记', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      final _FakePush push = _FakePush(token: _tokenA);
      await registrar(push).sync();
      requests.clear();
      push.token = _tokenB;
      await registrar(push).sync();
      expect(pushCalls(), <String>[
        'DELETE aaaaaaaaaa $_tokenA',
        'PUT aaaaaaaaaa $_tokenB',
      ]);
      expect((await FeedbackReplyStateStore(root).read()).pushToken, _tokenB);
    });

    test('平台不支持：什么都不做', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      final _FakePush push = _FakePush(token: _tokenA, supported: false);
      await registrar(push).sync();
      expect(push.tokenCalls, 0);
      expect(requests, isEmpty);
    });
  });

  group('被推送覆盖的反馈不重复提醒', () {
    Future<List<FeedbackReplyAlert>> poll() => pollFeedbackRepliesInBackground(
      supportRoot: root,
      client: (Uri u) => client(u),
      defaultBaseUrl: Uri.parse('https://rank.example'),
      nowMs: now,
    );

    test('服务端会推送：后台不发本地通知、前台不弹提示，水位照推', () async {
      await seed(<FeedbackTicket>[
        _ticket('aaaaaaaaaa'),
        _ticket('bbbbbbbbbb'),
      ]);
      await FeedbackReplyStateStore(root).update(
        (FeedbackReplyState s) => s.withPush(
          token: _tokenA,
          registrations: <String, FeedbackPushRegistration>{
            'aaaaaaaaaa': FeedbackPushRegistration(
              delivering: true,
              confirmedAt: now,
            ),
          },
        ),
      );
      replies = <String, int?>{'aaaaaaaaaa': 500, 'bbbbbbbbbb': 400};
      final List<FeedbackReplyAlert> bg = await poll();
      expect(bg.map((FeedbackReplyAlert a) => a.id), <String>['bbbbbbbbbb']);
      expect(
        (await FeedbackReplyStateStore(root).read()).notifiedAt('aaaaaaaaaa'),
        500,
      );

      replies = <String, int?>{'aaaaaaaaaa': 700};
      now += 20 * minute;
      final FeedbackReplyCheck fg = await FeedbackReplyNotifier(
        service: FeedbackService(
          supportRoot: () async => root,
          client: () => client(),
        ),
        supportRoot: () async => root,
        nowMs: () => now,
      ).check();
      expect(fg.announce, isFalse, reason: '推送已经提醒过');
      expect(fg.unseen, 1, reason: '红点照常');
      expect(
        (await FeedbackReplyStateStore(root).read()).notifiedAt('aaaaaaaaaa'),
        700,
      );
    });

    test('服务端还没配 APNs（delivering=false）：照旧由本机路径提醒', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      delivering = false;
      await registrar(_FakePush(token: _tokenA)).sync();
      expect((await FeedbackReplyStateStore(root).read()).pushCovered, isEmpty);
      replies = <String, int?>{'aaaaaaaaaa': 500};
      expect(await poll(), hasLength(1));
    });

    test('前台收到推送强制刷新：不受 15 分钟节流', () async {
      await seed(<FeedbackTicket>[_ticket('aaaaaaaaaa')]);
      final FeedbackReplyNotifier n = FeedbackReplyNotifier(
        service: FeedbackService(
          supportRoot: () async => root,
          client: () => client(),
        ),
        supportRoot: () async => root,
        nowMs: () => now,
      );
      await n.check();
      requests.clear();
      replies = <String, int?>{'aaaaaaaaaa': 500};
      expect((await n.check()).unseen, 0, reason: '节流内不刷新');
      expect(requests, isEmpty);
      expect((await n.check(force: true)).unseen, 1);
      expect(requests, hasLength(1));
    });
  });

  group('原生 / 签名接线', () {
    test('channel 名与方法 Dart / Swift 逐字一致；自己的推送先认领、别的交还 super', () {
      final String swift = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(swift, contains('"$kRemotePushChannel"'));
      for (final String m in <String>[
        '"register"',
        '"takeLaunchFeedbackId"',
        '"onTap"',
        '"onForegroundPush"',
      ]) {
        expect(swift, contains(m));
      }
      expect(swift, contains('FushiRemotePush.shared.install('));
      expect(
        swift,
        contains('UNUserNotificationCenter.current().delegate = self'),
      );
      expect(
        swift,
        contains('didRegisterForRemoteNotificationsWithDeviceToken'),
      );
      expect(
        swift,
        contains('didFailToRegisterForRemoteNotificationsWithError'),
      );
      // 两个委托回调都要把非反馈推送交还 super（flutter_local_notifications 靠它）。
      expect('super.userNotificationCenter('.allMatches(swift).length, 2);
      // 载荷键与服务端 pushPayload 一致。
      expect(swift, contains('userInfo["fushi"]'));
      expect(swift, contains('fushi["feedback"]'));
      final String server = File(
        '../services/leaderboard/src/feedback_push.js',
      ).readAsStringSync();
      expect(server, contains('fushi: { feedback: feedbackId }'));
    });

    test('aps-environment entitlement 只在描述文件带 Push 时才接入构建', () {
      final String ent = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      expect(ent, contains('<key>aps-environment</key>'));
      expect(ent, contains(r'$(FUSHI_APS_ENVIRONMENT)'));
      expect(
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
        isNot(contains('CODE_SIGN_ENTITLEMENTS')),
        reason: '无条件接入会让没开 Push 的描述文件签名失败（TestFlight 整条断）',
      );
      final RegExp assignment = RegExp(
        r'^\s*CODE_SIGN_ENTITLEMENTS\s*=',
        multiLine: true,
      );
      for (final String cfg in <String>['Debug', 'Release']) {
        expect(
          assignment.hasMatch(
            File('ios/Flutter/$cfg.xcconfig').readAsStringSync(),
          ),
          isFalse,
          reason: '$cfg.xcconfig 不得无条件接入 entitlements',
        );
      }
      final String wf = File(
        '../.github/workflows/release-desktop.yml',
      ).readAsStringSync();
      final int probe = wf.indexOf(':Entitlements:aps-environment');
      final int wire = wf.indexOf(
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements',
      );
      expect(probe, isNonNegative);
      expect(wire, greaterThan(probe));
      expect(
        wf.substring(probe, wire),
        contains(r'if [ -n "$APS_ENV" ]; then'),
      );
    });
  });
}
