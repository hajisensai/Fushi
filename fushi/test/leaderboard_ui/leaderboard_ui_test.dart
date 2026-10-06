import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_account_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_share_card.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_sign_in_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/utils.dart'
    show FushiDestructiveConfirmDialog, FushiLoadingView, FushiSelectableChip;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../helpers/glass_unwrap.dart';

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
  Map<String, dynamic>? rankMe = <String, dynamic>{'value': 3, 'rank': 2};
  bool shelfPrivate = true;

  /// 用户卡的 `relation`；null = 旧服务端（没有这个字段）。
  String? otherRelation;

  /// 带 X-Fushi-Account 的请求一律 401 unknown_account（账户已在别处删除）。
  bool accountGone = false;

  /// 为 true 时回自己的用户卡 / 书架（分享卡片取数用）；默认 404。
  bool selfShareData = false;

  /// 非 null 时每个请求先交给它：返回 false 则回 503（测试用 Completer 控制先后）。
  Future<bool> Function(http.Request r)? hold;

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
    final Future<bool> Function(http.Request r)? gate = hold;
    if (gate != null && !await gate(r)) {
      return _json(<String, dynamic>{'error': 'unavailable'}, 503);
    }
    final String path = r.url.path;
    if (accountGone && r.headers.containsKey('X-Fushi-Account')) {
      return _json(<String, dynamic>{'error': 'unknown_account'}, 401);
    }
    if (path == '/v1/login') return _json(_self());
    if (path == '/v1/me/devices') {
      return _json(<String, dynamic>{
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{
            'keyId': 'KeyHere000000001',
            'createdAt': 1700000000000,
            'lastUsedAt': 1790000000000,
            'current': true,
          },
          <String, dynamic>{
            'keyId': 'KeyOld0000000002',
            'createdAt': 1700000000000,
            'lastUsedAt': null,
            'current': false,
          },
        ],
      });
    }
    if (path.startsWith('/v1/me/devices/') && r.method == 'DELETE') {
      return http.Response('', 204);
    }
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
        'me': rankMe,
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
        if (otherRelation != null) 'relation': otherRelation,
      });
    }
    if (selfShareData && path == '/v1/users/$_selfId') {
      return _json(<String, dynamic>{
        'account': _account(_selfId, 'Me', 42),
        'createdAt': 1700000000000,
        'firstRecordDate': '2026-01-02',
        'visibility': 'public',
        'shelfVisible': true,
        'rankComputedAt': 1790000000000,
        'stats': <String, dynamic>{
          'book': <String, dynamic>{'value': 30, 'rank': 3},
          'manga': <String, dynamic>{'value': 12, 'rank': null},
          'chars': <String, dynamic>{'value': 888888, 'rank': 5},
        },
      });
    }
    if (selfShareData && path == '/v1/users/$_selfId/shelf') {
      return _json(<String, dynamic>{
        'account': _account(_selfId, 'Me', 42),
        'status': 'finished',
        'rows': <Map<String, dynamic>>[
          <String, dynamic>{
            'work': <String, dynamic>{
              'id': 'w1',
              'kind': 'book',
              'title': 'w1',
              'author': '',
              'nsfw': false,
            },
            'finishedAt': 1,
            'finishedDate': '2026-09-28',
            'readers': 1,
            'wall': <Object?>[],
          },
        ],
        'next': null,
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
  /// 表单页（注册 / 登录 / 账户）比默认 800x600 高：ListView 懒构建，屏外的行不存在。
  /// 把测试视口拉高，整页都建出来。
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// 同 [settle]，但每轮给真实 zone 留出落盘时间（账户文件读写是真 IO），转满 10 轮
  /// 后再一直转到 [done] 成立（上限 [maxRounds] 轮）。
  ///
  /// 不押固定轮数：账户落盘是「写临时文件 + flush → 起 `chmod` 子进程 → rename」，
  /// CI 机器忙时子进程起得慢，固定 10 轮 × 10ms 会在落盘前就去读账户文件（读到
  /// null）。到上限仍不成立就交给后面的 expect 如实报错。
  Future<void> settleIo(
    WidgetTester tester,
    bool Function() done, {
    int maxRounds = 300,
  }) async {
    // 至少转满原先的 10 轮（让后续的尾活照旧有机会跑），再按条件续转。
    for (int i = 0; i < maxRounds && (i < 10 || !done()); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

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
        'retry': t.leaderboard_error_nickname_retry,
        'not_configured': t.leaderboard_error_not_configured,
        'cannot_remove_current': t.leaderboard_error_cannot_remove_current,
        'too_many_devices': t.leaderboard_error_too_many_devices,
        'unknown_account': t.leaderboard_error_unknown_account,
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
      // 503 not_configured 是「服务还没部署」，不是额度。
      expect(
        leaderboardSyncErrorText(
          const LeaderboardApiException(503, 'not_configured'),
        ),
        t.leaderboard_error_not_configured,
      );
      expect(
        leaderboardErrorText(const LeaderboardConsentRequired()),
        t.leaderboard_error_consent_required,
      );
    });
  });

  testWidgets('未开启：说明卡列出公开项与三个入口，零网络请求', (WidgetTester tester) async {
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('leaderboard-intro')),
      findsOneWidget,
    );
    expect(find.text(t.leaderboard_intro_public_works), findsOneWidget);
    // 如实列出：每部作品的字数与时长、每日字数（按日期）都会公开。
    expect(find.text(t.leaderboard_intro_public_work_stats), findsOneWidget);
    expect(find.text(t.leaderboard_intro_public_chars), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('leaderboard-intro-account-gone')),
      findsNothing,
    );
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
    tallView(tester);
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
      tester.widget<FilledButton>(glassUnwrap<FilledButton>(byKey('leaderboard-signin-send'))).onPressed,
      isNull,
      reason: '冷却中不能重发',
    );
    FilledButton submit() =>
        tester.widget<FilledButton>(glassUnwrap<FilledButton>(byKey('leaderboard-signin-submit')));
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
    expect(byKey('leaderboard-signin-to-login'), findsOneWidget);

    server.registerError = (400, 'nickname_crowded');
    await tester.tap(byKey('leaderboard-signin-submit'));
    await settle(tester);
    expect(errorText(), t.leaderboard_error_nickname_crowded);
    expect(service.status, LeaderboardStatus.disabled);

    // 走完冷却，让周期 Timer 自己停掉。
    await tester.pump(const Duration(seconds: 61));
    expect(
      tester.widget<FilledButton>(glassUnwrap<FilledButton>(byKey('leaderboard-signin-send'))).onPressed,
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

  testWidgets('快照还没刷新到我：显示实时值与「刷新后排名」；本期没数据才说还没上榜', (
    WidgetTester tester,
  ) async {
    server.rankMe = <String, dynamic>{'value': 9, 'rank': null};
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);
    expect(
      find.text(
        t.leaderboard_board_me_pending(
          value: leaderboardMetricValue(LeaderboardMetric.book, 9),
          time: leaderboardDateTime(
            1790000000000 + kLeaderboardSnapshotInterval.inMilliseconds,
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(find.text(t.leaderboard_board_me_unranked), findsNothing);
  });

  testWidgets('本期没有数据：显示「还没有上榜」', (WidgetTester tester) async {
    server.rankMe = null;
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);
    expect(find.text(t.leaderboard_board_me_unranked), findsOneWidget);
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
          .widget<TextButton>(glassUnwrap<TextButton>(find.byKey(const ValueKey<String>('leaderboard-sync-now'))),)
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
      window: LeaderboardWindow.month,
      periodLabel: '2026-09',
      finishedCount: 5,
      chars: 123456,
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

  /// 分享取数用的假客户端：书架回 [dates]（倒序，`(id, finishedDate, nsfw)`），
  /// 字数榜回 777，用户卡累计 book 30 + manga 12 + game 4、字数 888888。
  /// 请求记进 [seen]。
  LeaderboardClient shareClient(
    List<(String, String, bool)> dates,
    List<Uri> seen,
  ) {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      for (final (String id, String date, bool nsfw) in dates)
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
    return LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async => MockClient((http.Request r) async {
        seen.add(r.url);
        final Object body;
        if (r.url.path.endsWith('/shelf')) {
          body = <String, dynamic>{
            'account': _account(_selfId, 'Me', 42),
            'status': 'finished',
            'rows': rows,
            'next': 'more',
          };
        } else if (r.url.path == '/v1/users/$_selfId') {
          body = <String, dynamic>{
            'account': _account(_selfId, 'Me', 42),
            'createdAt': 1,
            'firstRecordDate': null,
            'visibility': 'public',
            'shelfVisible': true,
            'stats': <String, dynamic>{
              'book': <String, dynamic>{'value': 30, 'rank': 3},
              'manga': <String, dynamic>{'value': 12, 'rank': null},
              'video': <String, dynamic>{'value': 0, 'rank': null},
              'game': <String, dynamic>{'value': 4, 'rank': null},
              'chars': <String, dynamic>{'value': 888888, 'rank': 5},
            },
          };
        } else {
          body = <String, dynamic>{
            'metric': 'chars',
            'window': r.url.queryParameters['window'],
            'scope': 'global',
            'from': '2026-09-01',
            'computedAt': 1,
            'total': 1,
            'me': <String, dynamic>{'value': 777, 'rank': 1},
            'rows': <Object?>[],
          };
        }
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
      }),
    );
  }

  final LeaderboardAccount shareSelf = LeaderboardAccount.fromJson(
    _account(_selfId, 'Me', 42),
  );

  test('分享卡片取数：只数本月读完、跳过 nsfw 封面、本月字数取 me', () async {
    final List<Uri> seen = <Uri>[];
    final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
      shareClient(<(String, String, bool)>[
        ('w1', '2026-09-20', false),
        ('w2', '2026-09-03', true),
        ('w3', '2026-08-30', false),
      ], seen),
      shareSelf,
      now: DateTime.utc(2026, 9, 28, 12),
    );
    expect(data.window, LeaderboardWindow.month);
    expect(data.finishedCount, 2);
    expect(data.covers.map((LeaderboardWork w) => w.id), <String>['w1']);
    expect(data.chars, 777);
    expect(data.periodLabel, '2026-09');
    expect(data.accountTag, 'Me#0042');
    expect(
      seen.where((Uri u) => u.path == '/v1/rank').single.queryParameters,
      containsPair('window', 'month'),
    );
  });

  test('分享周期起点与服务端同口径：UTC 日期，周 = 本周一，月 = 1 日', () {
    // 2026-09-28 是周一；UTC 周日 23 点仍属上一周（本地时区已是周一也一样）。
    expect(
      leaderboardShareWindowStart(
        LeaderboardWindow.week,
        DateTime.utc(2026, 9, 30, 8),
      ),
      '2026-09-28',
    );
    expect(
      leaderboardShareWindowStart(
        LeaderboardWindow.week,
        DateTime.utc(2026, 9, 27, 23),
      ),
      '2026-09-21',
    );
    expect(
      leaderboardShareWindowStart(
        LeaderboardWindow.month,
        DateTime.utc(2026, 9, 30, 8),
      ),
      '2026-09-01',
    );
    expect(
      leaderboardShareWindowStart(
        LeaderboardWindow.all,
        DateTime.utc(2026, 9, 30, 8),
      ),
      isNull,
    );
  });

  test('分享周期标签：「总」是本地日期（按传入偏移），周 / 月仍按 UTC 周期锚点', () {
    // 偏移显式传入，与跑测试的机器时区无关（CI 是 UTC：toLocal() == toUtc()，
    // 靠进程时区的断言在那里分不出本地 / UTC 两种实现）。每例 UTC 日期都与本地日期
    // 不同，按 UTC 取日期的实现两例都红。
    const Duration east = Duration(hours: 8);
    const Duration west = Duration(hours: -8);
    for (final (DateTime instant, Duration offset, String expected)
        in <(DateTime, Duration, String)>[
          // UTC 09-30 16:30 = 东八区 10-01 00:30。
          (DateTime.utc(2026, 9, 30, 16, 30), east, '2026-10-01'),
          // UTC 10-02 07:30 = 西八区 10-01 23:30。
          (DateTime.utc(2026, 10, 2, 7, 30), west, '2026-10-01'),
        ]) {
      expect(
        leaderboardSharePeriodLabel(
          LeaderboardWindow.all,
          instant,
          localOffset: offset,
        ),
        expected,
        reason: '$instant $offset',
      );
      // 同一时刻换成本机本地表示，截至日期不变（只认时刻 + 偏移）。
      expect(
        leaderboardSharePeriodLabel(
          LeaderboardWindow.all,
          instant.toLocal(),
          localOffset: offset,
        ),
        expected,
        reason: '${instant.toLocal()} $offset',
      );
    }
    // 周 / 月是服务端周期锚点：不随用户偏移变。
    final DateTime utc = DateTime.utc(2026, 9, 30, 23, 30);
    for (final Duration offset in <Duration>[Duration.zero, east, west]) {
      expect(
        leaderboardSharePeriodLabel(
          LeaderboardWindow.week,
          utc,
          localOffset: offset,
        ),
        '2026-09-28',
      );
      expect(
        leaderboardSharePeriodLabel(
          LeaderboardWindow.month,
          utc,
          localOffset: offset,
        ),
        '2026-09',
      );
    }
  });

  test('分享卡片取数（周）：只数本周一以来读完，字数取周榜 me', () async {
    final List<Uri> seen = <Uri>[];
    final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
      shareClient(<(String, String, bool)>[
        ('w1', '2026-09-29', false),
        ('w2', '2026-09-28', false),
        ('w3', '2026-09-27', false),
      ], seen),
      shareSelf,
      window: LeaderboardWindow.week,
      now: DateTime.utc(2026, 9, 30, 8),
    );
    expect(data.window, LeaderboardWindow.week);
    expect(data.finishedCount, 2);
    expect(data.covers.map((LeaderboardWork w) => w.id), <String>['w1', 'w2']);
    expect(data.periodLabel, '2026-09-28');
    expect(data.chars, 777);
    expect(
      seen.where((Uri u) => u.path == '/v1/rank').single.queryParameters,
      containsPair('window', 'week'),
    );
  });

  test('分享卡片取数（总）：读完数与字数取用户卡累计，书架只翻一页取封面', () async {
    final List<Uri> seen = <Uri>[];
    final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
      shareClient(<(String, String, bool)>[
        ('w1', '2026-09-29', false),
        ('w2', '2025-01-01', false),
      ], seen),
      shareSelf,
      window: LeaderboardWindow.all,
      // UTC 09-30 20:00 = 东八区 10-01 04:00：截至日期是本地的 10-01，不是 UTC 的
      // 09-30（偏移传入 → 取数链路的本地日期也与机器时区无关）。
      now: DateTime.utc(2026, 9, 30, 20),
      localOffset: const Duration(hours: 8),
    );
    expect(data.window, LeaderboardWindow.all);
    // 累计 = book 30 + manga 12 + video 0 + game 4；字数不算作品。
    expect(data.finishedCount, 46);
    expect(data.chars, 888888);
    expect(data.periodLabel, '2026-10-01');
    // 不受周期截断：老作品也进封面拼图。
    expect(data.covers.map((LeaderboardWork w) => w.id), <String>['w1', 'w2']);
    // 书架回了 next 也不继续翻；不请求字数榜。
    expect(seen.where((Uri u) => u.path.endsWith('/shelf')), hasLength(1));
    expect(seen.where((Uri u) => u.path == '/v1/rank'), isEmpty);
  });

  testWidgets('分享对话框：默认用传入周期，可切到「总」，复制链接写剪贴板', (WidgetTester tester) async {
    server.selfShareData = true;
    final LeaderboardService service = await activeService(tester);
    // 页头的分享按钮只在 self 到手后才可点；这里直接挂对话框，先把 self 拉下来。
    await tester.runAsync(service.refreshSelf);
    final List<String> clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardShareDialog(initialWindow: LeaderboardWindow.week),
      ),
    );
    await settle(tester);
    expect(
      find.text(t.leaderboard_share_card_finished_week(n: 1)),
      findsOneWidget,
    );
    expect(
      server.requests.any(
        (http.Request r) =>
            r.url.path == '/v1/rank' &&
            r.url.queryParameters['window'] == 'week',
      ),
      isTrue,
    );

    await tester.tap(
      find.byKey(
        ValueKey<String>(
          'leaderboard-share-window-${t.leaderboard_window_all}',
        ),
      ),
    );
    await settle(tester);
    expect(
      find.text(t.leaderboard_share_card_finished_all(n: 42)),
      findsOneWidget,
    );
    expect(
      find.text(t.leaderboard_share_card_chars(n: 888888)),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('leaderboard-share-copy-link')),
    );
    await settle(tester);
    expect(clipboard, <String>['https://rank.example/u/$_selfId']);
    // 等提示 Toast 的计时器走完，免得测试收尾时留有挂起计时器。
    await tester.pump(const Duration(seconds: 5));
  });

  /// 对话框底部按钮（adaptiveDialogAction）的 onPressed 是否非空。
  bool shareActionEnabled(WidgetTester tester, String key) => tester
      .widget<ButtonStyleButton>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        ),
      )
      .enabled;

  testWidgets('分享对话框：周期错误按周期存，同周期请求在途时切回复用，不被旧失败盖住', (
    WidgetTester tester,
  ) async {
    server.selfShareData = true;
    final LeaderboardService service = await activeService(tester);
    await tester.runAsync(service.refreshSelf);
    // 周榜请求（= 「周」卡片取数）逐个挂起，由测试决定成败与先后。
    final List<Completer<bool>> weekGates = <Completer<bool>>[];
    server.hold = (http.Request r) {
      if (r.url.path != '/v1/rank' ||
          r.url.queryParameters['window'] != 'week') {
        return Future<bool>.value(true);
      }
      final Completer<bool> gate = Completer<bool>();
      weekGates.add(gate);
      return gate.future;
    };
    Finder chip(String label) =>
        find.byKey(ValueKey<String>('leaderboard-share-window-$label'));

    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardShareDialog(initialWindow: LeaderboardWindow.week),
      ),
    );
    await settle(tester);
    expect(weekGates, hasLength(1));
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isFalse);

    // 周还在加载 → 切到总（取到数据）→ 切回周：复用在途请求，不再发第二次。
    await tester.tap(chip(t.leaderboard_window_all));
    await settle(tester);
    expect(
      find.text(t.leaderboard_share_card_finished_all(n: 42)),
      findsOneWidget,
    );
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isTrue);
    await tester.tap(chip(t.leaderboard_window_week));
    await settle(tester);
    expect(weekGates, hasLength(1));
    expect(find.byType(FushiLoadingView), findsOneWidget);
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isFalse);

    // 周失败：只在周这一格显示错误，分享不可点；总那一格照旧是卡片。
    weekGates.single.complete(false);
    await settle(tester);
    expect(find.byType(LeaderboardErrorView), findsOneWidget);
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isFalse);
    await tester.tap(chip(t.leaderboard_window_all));
    await settle(tester);
    expect(find.byType(LeaderboardErrorView), findsNothing);
    expect(
      find.text(t.leaderboard_share_card_finished_all(n: 42)),
      findsOneWidget,
    );

    // 切回周 = 重取；第二次成功后显示卡片而不是残留的错误，分享可点。
    await tester.tap(chip(t.leaderboard_window_week));
    await settle(tester);
    expect(weekGates, hasLength(2));
    weekGates.last.complete(true);
    await settle(tester);
    expect(find.byType(LeaderboardErrorView), findsNothing);
    expect(
      find.text(t.leaderboard_share_card_finished_week(n: 1)),
      findsOneWidget,
    );
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分享对话框：卡片已在、主页链接没了（退出本机账户）时「复制链接」与「分享」禁用', (
    WidgetTester tester,
  ) async {
    server.selfShareData = true;
    final LeaderboardService service = await activeService(tester);
    await tester.runAsync(service.refreshSelf);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardShareDialog(initialWindow: LeaderboardWindow.week),
      ),
    );
    await settle(tester);
    // 前提：卡片已取到、两颗按钮都可点。
    expect(find.byType(LeaderboardShareCard), findsOneWidget);
    expect(shareActionEnabled(tester, 'leaderboard-share-copy-link'), isTrue);
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isTrue);

    // 对话框开着时本机账户被退出：self / client 清空 → 主页链接拼不出，而已取到的
    // 卡片数据仍在缓存里照常显示。此时分享按钮的禁用只能来自 url == null。
    // 不能 `runAsync(service.signOutLocally)`：退出排在串行写队列上，队列里的前一段
    // future 属于 fake zone，真实 zone 里 await 它永远等不到。在 fake zone 里发起，
    // 交替给真实 zone 落盘时间。
    unawaited(service.signOutLocally());
    await settleIo(tester, () => service.self == null);
    expect(service.self, isNull);
    expect(find.byType(LeaderboardShareCard), findsOneWidget);
    expect(shareActionEnabled(tester, 'leaderboard-share-copy-link'), isFalse);
    expect(shareActionEnabled(tester, 'leaderboard-share-image'), isFalse);
  });

  testWidgets('排行页切到「总」后点页头分享：对话框初始就是「总」', (WidgetTester tester) async {
    tallView(tester);
    server.selfShareData = true;
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    await settle(tester);

    await tester.tap(
      find.byKey(
        ValueKey<String>('leaderboard-window-${t.leaderboard_window_all}'),
      ),
    );
    await settle(tester);
    final Finder share = find.byKey(
      const ValueKey<String>('leaderboard-header-share'),
    );
    expect(tester.widget<OutlinedButton>(glassUnwrap<OutlinedButton>(share)).onPressed, isNotNull);
    await tester.tap(share);
    await settle(tester);

    expect(find.byType(LeaderboardShareDialog), findsOneWidget);
    expect(
      tester
          .widget<FushiSelectableChip>(
            find.byKey(
              ValueKey<String>(
                'leaderboard-share-window-${t.leaderboard_window_all}',
              ),
            ),
          )
          .selected,
      isTrue,
    );
    expect(
      find.text(t.leaderboard_share_card_finished_all(n: 42)),
      findsOneWidget,
    );
  });

  Finder byKey(String k) => find.byKey(ValueKey<String>(k));
  Finder editable(String k) =>
      find.descendant(of: byKey(k), matching: find.byType(EditableText));

  testWidgets('登录页：展示公开清单；不勾同意也能登录，但本机上传默认关闭', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardSignInPage(mode: LeaderboardSignInMode.login),
      ),
    );
    await settle(tester);

    expect(byKey('leaderboard-public-data'), findsOneWidget);
    expect(find.text(t.leaderboard_signin_consent_login), findsOneWidget);

    await tester.enterText(editable('leaderboard-signin-email'), 'a@b.cd');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    await tester.enterText(editable('leaderboard-signin-code'), '123456');
    await tester.pump();
    final FilledButton submit = tester.widget<FilledButton>(glassUnwrap<FilledButton>(byKey('leaderboard-signin-submit')),);
    expect(submit.onPressed, isNotNull, reason: '登录不强制勾同意');
    await tester.tap(byKey('leaderboard-signin-submit'));
    // 账户先落盘再激活（`_adopt`）：状态翻成 active 时文件已写完。
    await settleIo(tester, () => service.status == LeaderboardStatus.active);
    expect(service.status, LeaderboardStatus.active);
    final LeaderboardLocalAccount? saved = await tester
        .runAsync<LeaderboardLocalAccount?>(
          () => LeaderboardStore(supportRoot: root, profileId: 1).read(),
        );
    expect(saved!.uploadEnabled, isFalse);
    expect(saved.consentAt, isNull);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('登录页勾了同意：本机上传开', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardSignInPage(mode: LeaderboardSignInMode.login),
      ),
    );
    await settle(tester);
    await tester.enterText(editable('leaderboard-signin-email'), 'a@b.cd');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    await tester.enterText(editable('leaderboard-signin-code'), '123456');
    await tester.tap(byKey('leaderboard-signin-consent'));
    await tester.pump();
    await tester.tap(byKey('leaderboard-signin-submit'));
    // 账户先落盘再激活（`_adopt`）：状态翻成 active 时文件已写完。
    await settleIo(tester, () => service.status == LeaderboardStatus.active);
    final LeaderboardLocalAccount? saved = await tester
        .runAsync<LeaderboardLocalAccount?>(
          () => LeaderboardStore(supportRoot: root, profileId: 1).read(),
        );
    expect(saved!.uploadEnabled, isTrue);
    expect(saved.consentAt, now);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('走错路径：登录发码后「去注册」、注册 email_taken「改为登录」，邮箱都带过去', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardSignInPage(mode: LeaderboardSignInMode.login),
      ),
    );
    await settle(tester);
    String email() => tester
        .widget<EditableText>(editable('leaderboard-signin-email'))
        .controller
        .text;

    expect(byKey('leaderboard-signin-to-register'), findsNothing);
    await tester.enterText(editable('leaderboard-signin-email'), 'a@b.cd');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    expect(find.text(t.leaderboard_signin_login_code_hint), findsOneWidget);
    await tester.tap(byKey('leaderboard-signin-to-register'));
    await settle(tester);
    expect(find.text(t.leaderboard_signin_register_title), findsWidgets);
    expect(byKey('leaderboard-signin-nickname'), findsOneWidget);
    expect(email(), 'a@b.cd');
    expect(
      tester.widget<FilledButton>(glassUnwrap<FilledButton>(byKey('leaderboard-signin-send'))).onPressed,
      isNotNull,
      reason: '登录码不能拿来注册：切换后可以立刻发注册码',
    );

    server.registerError = (409, 'email_taken');
    await tester.tap(byKey('leaderboard-signin-send'));
    await settle(tester);
    await tester.enterText(editable('leaderboard-signin-code'), '123456');
    await tester.enterText(editable('leaderboard-signin-nickname'), 'Neko');
    await tester.tap(byKey('leaderboard-signin-consent'));
    await tester.pump();
    await tester.tap(byKey('leaderboard-signin-submit'));
    await settle(tester);
    await tester.tap(byKey('leaderboard-signin-to-login'));
    await settle(tester);
    expect(byKey('leaderboard-signin-nickname'), findsNothing);
    expect(find.text(t.leaderboard_signin_login_title), findsWidgets);
    expect(email(), 'a@b.cd');
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('同意勾选行只占一个焦点位（复选框不单独可聚焦）', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = buildService();
    await tester.runAsync(service.load);
    await tester.pumpWidget(
      wrap(
        service,
        const LeaderboardSignInPage(mode: LeaderboardSignInMode.register),
      ),
    );
    await settle(tester);
    final Element tile = byKey('leaderboard-signin-consent').evaluate().single;
    bool insideTile(FocusNode n) {
      final BuildContext? ctx = n.context;
      if (ctx == null) return false;
      if (identical(ctx, tile)) return true;
      bool found = false;
      ctx.visitAncestorElements((Element a) {
        found = identical(a, tile);
        return !found;
      });
      return found;
    }

    final int focusable = FocusManager.instance.rootScope.traversalDescendants
        .where(insideTile)
        .length;
    expect(focusable, 1);
  });

  testWidgets('账户页：self 晚到时昵称框补上；用户改过的不覆盖', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = await activeService(tester);
    expect(service.self, isNull);
    await tester.pumpWidget(wrap(service, const LeaderboardAccountPage()));
    await settle(tester);
    Finder nickField() => find.descendant(
      of: find.byType(LeaderboardAccountPage),
      matching: find.byType(EditableText),
    );
    String nick() =>
        tester.widget<EditableText>(nickField().first).controller.text;
    expect(nick(), '');

    await tester.runAsync(service.refreshSelf);
    await tester.pump();
    expect(nick(), 'Me');

    await tester.enterText(nickField().first, 'Edited');
    await tester.runAsync(service.refreshSelf);
    await tester.pump();
    expect(nick(), 'Edited', reason: '用户已编辑，不被服务端值覆盖');
  });

  testWidgets('账户页：已登录设备列表，本机标注、其余二次确认后解绑', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = await activeService(tester);
    await tester.pumpWidget(wrap(service, const LeaderboardAccountPage()));
    await settle(tester);

    await tester.scrollUntilVisible(
      byKey('leaderboard-device-KeyOld0000000002'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(byKey('leaderboard-device-KeyHere000000001'), findsOneWidget);
    expect(
      find.textContaining(t.leaderboard_account_device_current),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: byKey('leaderboard-device-KeyHere000000001'),
        matching: find.byType(TextButton),
      ),
      findsNothing,
      reason: '本机不能在这里解绑',
    );
    await tester.tap(
      find.descendant(
        of: byKey('leaderboard-device-KeyOld0000000002'),
        matching: find.byType(TextButton),
      ),
    );
    await settle(tester);
    expect(
      server.requests.where((http.Request r) => r.method == 'DELETE'),
      isEmpty,
      reason: '先确认',
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(FushiDestructiveConfirmDialog),
            matching: find.text(t.leaderboard_account_device_remove),
          )
          .last,
    );
    await settle(tester);
    expect(
      server.requests
          .where((http.Request r) => r.method == 'DELETE')
          .map((http.Request r) => r.url.path),
      <String>['/v1/me/devices/KeyOld0000000002'],
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('账户页：未同意的账户打开上传先弹公开清单确认', (WidgetTester tester) async {
    tallView(tester);
    final LeaderboardService service = buildService();
    await tester.runAsync(() async {
      await LeaderboardStore(supportRoot: root, profileId: 1).write(
        LeaderboardLocalAccount(
          recoveryCode: LeaderboardIdentity.generate().toRecoveryCode(),
          accountId: _selfId,
          uploadEnabled: false,
        ),
      );
      await service.load();
    });
    await tester.pumpWidget(wrap(service, const LeaderboardAccountPage()));
    await settle(tester);
    await tester.tap(byKey('leaderboard-account-upload'));
    await settle(tester);
    expect(byKey('leaderboard-public-data'), findsOneWidget);
    await tester.tap(byKey('leaderboard-upload-consent-ok'));
    await settleIo(tester, () => service.account?.uploadEnabled ?? false);
    expect(service.account!.uploadEnabled, isTrue);
    expect(service.account!.consentAt, now);
  });

  testWidgets('账户已在别处删除：榜单请求 401 后自动回到说明页并提示原因', (WidgetTester tester) async {
    final LeaderboardService service = await activeService(tester);
    server.accountGone = true;
    await tester.pumpWidget(wrap(service, const LeaderboardTab()));
    // 401 之后 `_clearLocal` 排进串行写队列、真删账户文件（真 IO）才清空账户；
    // 固定轮数的 settle 在 CI 忙时等不到它（2026-10-01 develop run 36830851605
    // 读到 active）。按条件转，到上限仍不成立交给下面的 expect 如实报错。
    await settleIo(tester, () => service.status == LeaderboardStatus.disabled);
    await tester.pump();
    expect(service.status, LeaderboardStatus.disabled);
    expect(byKey('leaderboard-intro'), findsOneWidget);
    expect(byKey('leaderboard-intro-account-gone'), findsOneWidget);
    expect(find.text(t.leaderboard_error_unknown_account), findsOneWidget);
  });

  testWidgets('用户页：服务端给 relation none 时不再拉好友列表；缺字段才回退', (
    WidgetTester tester,
  ) async {
    Future<void> open() async {
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
    }

    server.otherRelation = 'none';
    await open();
    expect(
      server.requests.where((http.Request r) => r.url.path == '/v1/friends'),
      isEmpty,
    );
    expect(byKey('leaderboard-user-add-friend'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    server.otherRelation = null;
    server.requests.clear();
    await open();
    expect(
      server.requests.where((http.Request r) => r.url.path == '/v1/friends'),
      hasLength(1),
      reason: '旧服务端没有 relation 字段：回退按好友列表推断',
    );
  });
}
