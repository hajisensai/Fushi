import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_share_card.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_sign_in_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _selfId = 'SelfAccount001';
const String _otherId = 'OtherAccount01';

Map<String, dynamic> _account(String id, String nick, int disc) =>
    <String, dynamic>{
      'id': id,
      'nickname': nick,
      'discriminator': disc,
      'avatar': null,
    };

/// 假排行榜服务端：按路径回固定形状；各测试改字段制造错误。
class _FakeServer {
  final List<http.Request> requests = <http.Request>[];

  /// 非 null 时 /v1/email/code 回这个错误（[status, code]）。
  (int, String)? codeError;

  /// 非 null 时 /v1/register 回这个错误。
  (int, String)? registerError;

  int? rankComputedAt = 1790000000000;
  bool shelfPrivate = true;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );

  http.Response _error((int, String) e) =>
      _json(<String, dynamic>{'error': e.$2}, e.$1);

  Map<String, dynamic> _self() => <String, dynamic>{
    ..._account(_selfId, 'Me', 42),
    'visibility': 'public',
    'createdAt': 1700000000000,
    'shelfCount': 3,
    'emailVerified': true,
    'uploadDevice': true,
  };

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final String path = r.url.path;
    if (path == '/v1/email/code') {
      final (int, String)? e = codeError;
      return e == null
          ? _json(<String, dynamic>{'sent': true}, 202)
          : _error(e);
    }
    if (path == '/v1/register') {
      final (int, String)? e = registerError;
      return e == null ? _json(_self(), 201) : _error(e);
    }
    if (path == '/v1/me') return _json(_self());
    if (path == '/v1/rank') {
      return _json(<String, dynamic>{
        'metric': r.url.queryParameters['metric'],
        'window': r.url.queryParameters['window'],
        'scope': r.url.queryParameters['scope'],
        'from': '2026-09-21',
        'computedAt': rankComputedAt,
        'total': 2,
        'me': <String, dynamic>{'value': 3, 'rank': 2},
        'rows': <Map<String, dynamic>>[
          <String, dynamic>{
            'rank': 1,
            'value': 9,
            'account': _account(_otherId, 'Alice', 7),
          },
          <String, dynamic>{
            'rank': 2,
            'value': 3,
            'account': _account(_selfId, 'Me', 42),
          },
        ],
      });
    }
    if (path == '/v1/works/popular') {
      return _json(<String, dynamic>{
        'window': 'week',
        'kind': 'book',
        'from': '2026-09-21',
        'computedAt': null,
        'rows': <Object?>[],
      });
    }
    if (path == '/v1/users/$_otherId') {
      return _json(<String, dynamic>{
        'account': _account(_otherId, 'Alice', 7),
        'createdAt': 1700000000000,
        'firstRecordDate': '2026-01-02',
        'visibility': 'friends',
        'shelfVisible': false,
        'rankComputedAt': 1790000000000,
        'stats': <String, dynamic>{
          'book': <String, dynamic>{'value': 12, 'rank': 3},
          'chars': <String, dynamic>{'value': 50000, 'rank': null},
        },
      });
    }
    if (path == '/v1/users/$_otherId/shelf') {
      if (shelfPrivate) {
        return _json(<String, dynamic>{'error': 'shelf_private'}, 403);
      }
    }
    if (path == '/v1/friends') {
      return _json(<String, dynamic>{
        'friends': <Object?>[],
        'incoming': <Object?>[],
        'outgoing': <Object?>[],
      });
    }
    return _json(<String, dynamic>{'error': 'not_found'}, 404);
  }
}

void main() {
  late Directory root;
  late _FakeServer server;
  late int now;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lb_ui_');
    server = _FakeServer();
    now = DateTime(2026, 9, 28, 12).millisecondsSinceEpoch;
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  LeaderboardService buildService() => LeaderboardService(
    database: () => throw StateError('no database in UI tests'),
    supportRoot: () async => root,
    profileId: () async => 1,
    httpClientFactory: () async => MockClient(server.handle),
    defaultBaseUrl: Uri.parse('https://rank.example'),
    clockMs: () => now,
    isbnBackfill: (FushiDatabase _) async => 0,
  );

  /// 写一份本机账户文件（= 已开启），并把服务读进内存。真实 IO 必须在 runAsync 里。
  Future<LeaderboardService> activeService(
    WidgetTester tester, {
    bool blockedElsewhere = false,
  }) async {
    final LeaderboardService service = buildService();
    await tester.runAsync(() async {
      await LeaderboardStore(supportRoot: root, profileId: 1).write(
        LeaderboardLocalAccount(
          recoveryCode: LeaderboardIdentity.generate().toRecoveryCode(),
          accountId: _selfId,
          consentAt: 1,
          lastSyncAt: now,
          uploadBlockedByOtherDevice: blockedElsewhere,
        ),
      );
      await service.load();
    });
    expect(service.status, LeaderboardStatus.active);
    return service;
  }

  Widget wrap(LeaderboardService service, Widget child) => ProviderScope(
    overrides: <Override>[
      leaderboardServiceProvider.overrideWith((Ref _) => service),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  /// 让 MockClient 的 future / stream 走完（不能 pumpAndSettle：转圈动画永不停）。
  ///
  /// 服务的 `load()` future 是在 runAsync（真实 zone）里建的：对已完成 future 的
  /// `.then` 回调排在它自己的 zone 的微任务队列上，fake zone 的 pump 冲不到，所以
  /// 每轮先让真实 zone 转一圈。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('错误码 → 人话', () {
    test('服务端错误码逐个映射，未知码带原码', () {
      final Map<String, String> expected = <String, String>{
        'bad_code': t.leaderboard_error_bad_code,
        'code_expired': t.leaderboard_error_code_expired,
        'too_many_attempts': t.leaderboard_error_too_many_attempts,
        'email_taken': t.leaderboard_error_email_taken,
        'rate_limited': t.leaderboard_error_rate_limited,
        'daily_budget': t.leaderboard_error_daily_budget,
        'email_not_configured': t.leaderboard_error_email_not_configured,
        'nickname_rejected': t.leaderboard_error_nickname_rejected,
        'nickname_crowded': t.leaderboard_error_nickname_crowded,
        'bad_nickname': t.leaderboard_error_bad_nickname,
        'no_account': t.leaderboard_error_no_account,
        'shelf_private': t.leaderboard_user_shelf_private,
      };
      for (final MapEntry<String, String> e in expected.entries) {
        expect(
          leaderboardErrorText(LeaderboardApiException(400, e.key)),
          e.value,
          reason: e.key,
        );
      }
      expect(
        leaderboardErrorText(const LeaderboardApiException(418, 'teapot')),
        contains('teapot'),
      );
      expect(
        leaderboardErrorText(const SocketException('down')),
        t.leaderboard_error_network,
      );
    });

    test('同步失败：429 / 503 一律是「今日额度已满」', () {
      expect(
        leaderboardSyncErrorText(const LeaderboardApiException(429, 'x')),
        t.leaderboard_sync_quota,
      );
      expect(
        leaderboardSyncErrorText(
          const LeaderboardApiException(503, 'daily_budget'),
        ),
        t.leaderboard_sync_quota,
      );
      expect(
        leaderboardSyncErrorText(const LeaderboardUploadOwnedElsewhere()),
        t.leaderboard_sync_owned_elsewhere,
      );
    });
  });

  testWidgets('未开启：说明卡列出公开 / 不上传项与三个入口，零网络请求', (WidgetTester tester) async {
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('leaderboard-intro')),
      findsOneWidget,
    );
    expect(find.text(t.leaderboard_intro_public_works), findsOneWidget);
    expect(find.text(t.leaderboard_intro_private_position), findsOneWidget);
    expect(find.text(t.leaderboard_intro_email_note), findsOneWidget);
    for (final String key in <String>[
      'leaderboard-intro-register',
      'leaderboard-intro-login',
      'leaderboard-intro-recovery',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    expect(server.requests, isEmpty);
  });

  testWidgets('注册流程：发码失败、验证码错、邮箱已注册都就地显示人话', (WidgetTester tester) async {
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardSignInPage(mode: LeaderboardSignInMode.register),
      ),
    );
    await settle(tester);

    Finder byKey(String k) => find.byKey(ValueKey<String>(k));
    String errorText() =>
        tester.widget<Text>(byKey('leaderboard-signin-error')).data!;
    Finder field(String k) =>
        find.descendant(of: byKey(k), matching: find.byType(EditableText));

    // 邮箱形状不对：本地就拦下，不发请求。
    await tester.enterText(field('leaderboard-signin-email'), 'nope');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_bad_email);
    expect(server.requests, isEmpty);

    // 服务端没配邮件：503 email_not_configured。
    server.codeError = (503, 'email_not_configured');
    await tester.enterText(field('leaderboard-signin-email'), 'a@b.cd');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_email_not_configured);

    // 发码成功 → 进入 60 秒冷却，提交按钮在填齐前禁用。
    server.codeError = null;
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    expect(byKey('leaderboard-signin-error'), findsNothing);
    expect(
      tester.widget<FilledButton>(byKey('leaderboard-signin-send')).onPressed,
      isNull,
      reason: '冷却中不能重发',
    );
    FilledButton submit() =>
        tester.widget<FilledButton>(byKey('leaderboard-signin-submit'));
    expect(submit().onPressed, isNull);

    await tester.enterText(field('leaderboard-signin-code'), '123456');
    await tester.enterText(field('leaderboard-signin-nickname'), 'Neko');
    await tester.pump();
    expect(submit().onPressed, isNull, reason: '没勾同意不能注册');
    await tester.tap(byKey('leaderboard-signin-consent'));
    await tester.pump();
    expect(submit().onPressed, isNotNull);

    server.registerError = (400, 'bad_code');
    await tester.tap(byKey('leaderboard-signin-submit'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_bad_code);

    server.registerError = (409, 'email_taken');
    await tester.tap(byKey('leaderboard-signin-submit'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_email_taken);

    server.registerError = (400, 'nickname_crowded');
    await tester.tap(byKey('leaderboard-signin-submit'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_nickname_crowded);
    expect(service.status, LeaderboardStatus.disabled);

    // 走完冷却，让周期 Timer 自己停掉。
    await tester.pump(const Duration(seconds: 61));
    expect(
      tester.widget<FilledButton>(byKey('leaderboard-signin-send')).onPressed,
      isNotNull,
    );
  });

  testWidgets('已开启：页头、我的名次、榜单行与「更新于」', (WidgetTester tester) async {
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('leaderboard-active')),
      findsOneWidget,
    );
    expect(find.text('Me#0042'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('leaderboard-rank-$_otherId')),
      findsOneWidget,
    );
    expect(find.text('Alice#0007'), findsOneWidget);
    expect(
      find.text(
        t.leaderboard_board_me(
          rank: 2,
          value: leaderboardMetricValue(LeaderboardMetric.book, 3),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.leaderboard_board_updated(time: '')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('leaderboard-sync-claim')),
      findsNothing,
    );
    final http.Request rank = server.requests.firstWhere(
      (http.Request r) => r.url.path == '/v1/rank',
    );
    expect(rank.url.queryParameters['metric'], 'book');
    expect(rank.url.queryParameters['window'], 'week');
    expect(rank.url.queryParameters['scope'], 'global');
    expect(rank.headers.containsKey('X-Fushi-Sig'), isTrue);
  });

  testWidgets('榜单快照未生成：显示「榜单生成中」；上传设备在别处：给出接管按钮', (WidgetTester tester) async {
    server.rankComputedAt = null;
    final LeaderboardService service = await activeService(
      tester,
      blockedElsewhere: true,
    );
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);

    expect(find.text(t.leaderboard_board_generating), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('leaderboard-sync-elsewhere')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('leaderboard-sync-claim')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey<String>('leaderboard-sync-now')),
          )
          .onPressed,
      isNull,
      reason: '被挡住时「立即同步」必然 409，直接禁用',
    );
  });

  testWidgets('用户页：书架 403 shelf_private 显示「仅好友可见」，资料卡照常', (
    WidgetTester tester,
  ) async {
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          leaderboardServiceProvider.overrideWith((Ref _) => service),
        ],
        child: const MaterialApp(
          home: LeaderboardUserPage(accountId: _otherId),
        ),
      ),
    );
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('leaderboard-user-card')),
      findsOneWidget,
    );
    expect(find.text('Alice#0007'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('leaderboard-shelf-private')),
      findsOneWidget,
    );
    expect(find.text(t.leaderboard_user_shelf_private), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('leaderboard-user-add-friend')),
      findsOneWidget,
    );
  });

  testWidgets('分享卡片：渲染不抛，RepaintBoundary 能栅格化成 PNG', (
    WidgetTester tester,
  ) async {
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    final GlobalKey boundary = GlobalKey();
    const LeaderboardShareCardData data = LeaderboardShareCardData(
      accountTag: 'Me#0042',
      monthLabel: '2026-09',
      finishedCount: 5,
      monthChars: 123456,
      covers: <LeaderboardWork>[
        LeaderboardWork(
          id: 'w1',
          kind: LeaderboardKind.book,
          title: 'A',
          author: 'x',
        ),
        LeaderboardWork(
          id: 'w2',
          kind: LeaderboardKind.game,
          title: 'B',
          author: 'y',
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        service,
        Center(
          child: RepaintBoundary(
            key: boundary,
            child: const LeaderboardShareCard(data: data),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text(t.leaderboard_share_card_finished(n: 5)), findsOneWidget);

    final Uint8List? png = await tester.runAsync(
      () => captureLeaderboardShareCardPng(boundary, pixelRatio: 1),
    );
    expect(png, isNotNull);
    expect(png!.length, greaterThan(100));
    expect(png.sublist(0, 4), <int>[0x89, 0x50, 0x4e, 0x47]);
  });

  test('分享卡片取数：只数本月读完、跳过 nsfw 封面、本月字数取 me', () async {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      for (final (String id, String date, bool nsfw)
          in <(String, String, bool)>[
            ('w1', '2026-09-20', false),
            ('w2', '2026-09-03', true),
            ('w3', '2026-08-30', false),
          ])
        <String, dynamic>{
          'work': <String, dynamic>{
            'id': id,
            'kind': 'book',
            'title': id,
            'author': '',
            'cover': '/img/covers/$id.jpg',
            'nsfw': nsfw,
          },
          'finishedAt': 1,
          'finishedDate': date,
          'readers': 1,
          'wall': <Object?>[],
        },
    ];
    final LeaderboardClient client = LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async => MockClient((http.Request r) async {
        final Object body = r.url.path.endsWith('/shelf')
            ? <String, dynamic>{
                'account': _account(_selfId, 'Me', 42),
                'status': 'finished',
                'rows': rows,
                'next': 'more',
              }
            : <String, dynamic>{
                'metric': 'chars',
                'window': 'month',
                'scope': 'global',
                'from': '2026-09-01',
                'computedAt': 1,
                'total': 1,
                'me': <String, dynamic>{'value': 777, 'rank': 1},
                'rows': <Object?>[],
              };
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
      }),
    );
    final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
      client,
      LeaderboardAccount.fromJson(_account(_selfId, 'Me', 42)),
      now: DateTime(2026, 9, 28),
    );
    expect(data.finishedCount, 2);
    expect(data.covers.map((LeaderboardWork w) => w.id), <String>['w1']);
    expect(data.monthChars, 777);
    expect(data.monthLabel, '2026-09');
    expect(data.accountTag, 'Me#0042');
  });
}
