import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/manual_sync_ui.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

/// BUG-1323 / BUG-1324：同步层两处「把错误压平」的独立缺陷。
///
/// - BUG-1323：`WebDavOps.checkStatus` 把 401（凭据不被接受）和 403（凭据没问题，
///   服务端按策略拒绝这一次请求）一律压成 `SyncAuthError('Authentication failed')`，
///   服务端在响应体里写的真实原因被整个丢弃。后果有两层：文案把用户引去重配一个
///   根本没问题的凭据；`manual_sync_ui` 还会据此把好端端的会话 signOut 掉。
/// - BUG-1324：`SyncRunReport.errors` 是扁平字符串，鉴权失败在拼进字符串那一刻就
///   没法再分辨，UI 只数了个 `errors.length` 变成「N 项失败」。
///
/// 这里逐条钉住**用户在两种情况下分别看到什么**。文案一律与 i18n getter 比较
/// （语言无关），不硬编码英文。
void main() {
  group('BUG-1323 checkStatus：401 与 403 不再是同一件事', () {
    final WebDavOps ops = WebDavOps(
      baseUrl: 'http://127.0.0.1:1/dav',
      username: 'u',
      password: 'p',
    );

    test('401 保持 credentials，措辞与改动前逐字相同', () {
      SyncAuthError? caught;
      try {
        ops.checkStatus(401, 'GET /x');
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.kind, SyncAuthFailureKind.credentials);
      expect(caught.isForbidden, isFalse);
      expect(caught.message, 'Authentication failed');
      expect(caught.serverReason, isNull);
      expect(caught.toString(), 'SyncAuthError: Authentication failed');
    });

    test('403 变 forbidden，且把以前被丢掉的操作上下文带上', () {
      SyncAuthError? caught;
      try {
        ops.checkStatus(403, 'GET /api/interconnect/service-config');
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.kind, SyncAuthFailureKind.forbidden);
      expect(caught.isForbidden, isTrue);
      expect(caught.message, contains('403'));
      expect(caught.message, contains('/api/interconnect/service-config'));
      expect(caught.message, isNot(equals('Authentication failed')));
    });

    test('403 的服务端原因原样保留，并进 toString', () {
      SyncAuthError? caught;
      try {
        ops.checkStatus(403, 'GET /svc',
            serverReason: 'HTTPS required for service config');
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught!.serverReason, 'HTTPS required for service config');
      expect(caught.toString(), contains('HTTPS required for service config'));
    });

    test('404 / 5xx / 2xx 契约不变（都不是鉴权错误）', () {
      expect(
        () => ops.checkStatus(404, 'GET /x'),
        throwsA(isA<SyncBackendError>().having(
            (SyncBackendError e) => e.isRetryable, 'isRetryable', isTrue)),
      );
      expect(() => ops.checkStatus(500, 'GET /x'),
          throwsA(isA<SyncBackendError>()));
      expect(() => ops.checkStatus(207, 'PROPFIND /x'), returnsNormally);
    });
  });

  group('BUG-1323 真实 HTTP 响应：服务端说的原因必须活着到达上层', () {
    late HttpServer server;
    late String base;
    late int status;
    late String body;

    setUp(() async {
      status = 403;
      body = 'HTTPS required for service config';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}/dav';
      server.listen((HttpRequest req) async {
        req.response.statusCode = status;
        req.response.write(body);
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    WebDavOps opsFor() =>
        WebDavOps(baseUrl: base, username: 'u', password: 'p');

    test('testConnection 的 403 把响应体当拒绝原因带回来', () async {
      SyncAuthError? caught;
      try {
        await opsFor().testConnection();
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.isForbidden, isTrue);
      expect(caught.serverReason, 'HTTPS required for service config');
    });

    test('testConnection 的 401 仍是 credentials，措辞不变', () async {
      status = 401;
      SyncAuthError? caught;
      try {
        await opsFor().testConnection();
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.kind, SyncAuthFailureKind.credentials);
      expect(caught.message, 'Authentication failed');
    });

    test('propfindChildren 的 403 同样带回原因', () async {
      SyncAuthError? caught;
      try {
        await opsFor().propfindChildren('$base/sub');
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.isForbidden, isTrue);
      expect(caught.serverReason, 'HTTPS required for service config');
    });

    test('403 但服务端一个字都没说：serverReason 为 null，不编造原因', () async {
      body = '   ';
      SyncAuthError? caught;
      try {
        await opsFor().testConnection();
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught!.isForbidden, isTrue);
      expect(caught.serverReason, isNull);
    });

    test('超长错误体被截断，不把整页 HTML 灌进提示', () async {
      body = 'x' * 5000;
      SyncAuthError? caught;
      try {
        await opsFor().testConnection();
      } on SyncAuthError catch (e) {
        caught = e;
      }
      expect(caught!.serverReason, isNotNull);
      expect(caught.serverReason!.length, lessThan(400));
      expect(caught.serverReason, endsWith('...'));
    });
  });

  group('BUG-1323 用户到底看到什么', () {
    test('凭据错（401）看到「登录已过期，请重新登录」，逐字未变', () {
      final SyncAuthError e = SyncAuthError('Authentication failed');
      expect(friendlySyncError(e), t.sync_err_auth_expired);
    });

    test('服务端拒绝（403）且说了原因：原因原样出现，且不再谎称登录过期', () {
      final SyncAuthError e = SyncAuthError(
        'Server refused (403): GET /api/interconnect/service-config',
        kind: SyncAuthFailureKind.forbidden,
        serverReason: 'HTTPS required for service config',
      );
      final String shown = friendlySyncError(e);
      expect(shown, contains('HTTPS required for service config'));
      expect(shown, isNot(equals(t.sync_err_auth_expired)));
      expect(
        shown,
        t.sync_err_forbidden_detail(
            reason: 'HTTPS required for service config'),
      );
    });

    test('服务端拒绝但没给原因：明说这不是登录问题', () {
      final SyncAuthError e = SyncAuthError(
        'Server refused (403): GET /x',
        kind: SyncAuthFailureKind.forbidden,
      );
      expect(friendlySyncError(e), t.sync_err_forbidden);
      expect(friendlySyncError(e), isNot(equals(t.sync_err_auth_expired)));
    });

    test('403 的分流按类型走，不靠消息里有没有 auth 字样', () {
      // 防回归：把类型分支删掉后，这个 message 会被字符串层的
      // `error is SyncAuthError && l.contains('auth')` 抓成「登录已过期」。
      final SyncAuthError e = SyncAuthError(
        'authentication context: refused',
        kind: SyncAuthFailureKind.forbidden,
        serverReason: 'policy',
      );
      expect(friendlySyncError(e), isNot(equals(t.sync_err_auth_expired)));
      expect(friendlySyncError(e), contains('policy'));
    });

    test('Google Drive 的 403 insufficient_scope 仍走重新授权（TODO-836 不回归）', () {
      // 它不经 checkStatus，kind 保持默认 credentials，故仍落在 scope 分支。
      final SyncAuthError e = SyncAuthError('insufficient_scope');
      expect(friendlySyncError(e), t.sync_err_scope_upgrade);
    });
  });

  group('BUG-1323 403 不得毁掉一个好端端的会话', () {
    test('凭据类失败必须登出（TODO-836 契约）', () {
      expect(shouldSignOutOnAuthError(SyncAuthError('Authentication failed')),
          isTrue);
      expect(shouldSignOutOnAuthError(SyncAuthError('insufficient_scope')),
          isTrue);
    });

    test('服务端拒绝不得登出', () {
      expect(
        shouldSignOutOnAuthError(SyncAuthError(
          'Server refused (403): GET /svc',
          kind: SyncAuthFailureKind.forbidden,
          serverReason: 'HTTPS required for service config',
        )),
        isFalse,
      );
    });

    test('手动同步的 catch 走的是这个判断，不是自己再写一遍', () {
      final String src =
          File('lib/src/sync/manual_sync_ui.dart').readAsStringSync();
      expect(src, contains('on SyncAuthError catch'));
      expect(src, contains('if (shouldSignOutOnAuthError(e)) {'));
      expect(src, contains('await backend.signOut(repo: repo)'));
    });
  });

  group('BUG-1324 鉴权失败必须带类型活到 UI', () {
    test('日志行与改动前逐字相同（errors 的既有契约不动）', () {
      final SyncRunReport r = SyncRunReport();
      r.noteError(
          'service config live sync', SyncAuthError('Authentication failed'));
      expect(r.errors, <String>[
        'service config live sync: SyncAuthError: Authentication failed',
      ]);
    });

    test('SyncAuthError 额外留一份带类型的', () {
      final SyncRunReport r = SyncRunReport();
      r.noteError(
        'service config live sync',
        SyncAuthError('Server refused (403): GET /svc',
            kind: SyncAuthFailureKind.forbidden,
            serverReason: 'HTTPS required for service config'),
      );
      expect(r.authFailures, hasLength(1));
      expect(r.authFailures.single.isForbidden, isTrue);
      expect(r.authFailures.single.label, 'service config live sync');
      expect(r.authFailures.single.serverReason,
          'HTTPS required for service config');
    });

    test('非鉴权错误不进 authFailures（不许扩大化）', () {
      final SyncRunReport r = SyncRunReport();
      r.noteError('video assets sync', SyncBackendError('500'));
      r.noteError('import book "x"', const FormatException('bad json'));
      expect(r.errors, hasLength(2));
      expect(r.authFailures, isEmpty);
    });

    test('同因失败去重：一轮几百本书只留一条', () {
      final SyncRunReport r = SyncRunReport();
      for (int i = 0; i < 200; i++) {
        r.noteError(
            'import book "b$i"', SyncAuthError('Authentication failed'));
      }
      expect(r.errors, hasLength(200));
      expect(r.authFailures, hasLength(1));
      expect(r.authFailures.single.label, 'import book "b0"');
    });

    test('不同原因分别留一条', () {
      final SyncRunReport r = SyncRunReport();
      r.noteError('a', SyncAuthError('Authentication failed'));
      r.noteError(
          'b',
          SyncAuthError('Server refused (403): x',
              kind: SyncAuthFailureKind.forbidden));
      expect(r.authFailures, hasLength(2));
    });

    test('mergeFrom 合并双通道的 authFailures 并去重', () {
      final SyncRunReport cloud = SyncRunReport()
        ..noteError('a', SyncAuthError('Authentication failed'));
      final SyncRunReport live = SyncRunReport()
        ..noteError('b', SyncAuthError('Authentication failed'))
        ..noteError(
            'c',
            SyncAuthError('Server refused (403): x',
                kind: SyncAuthFailureKind.forbidden));
      cloud.mergeFrom(live);
      expect(cloud.errors, hasLength(3));
      expect(cloud.authFailures, hasLength(2));
    });
  });

  group('BUG-1324 「N 项失败」不再是唯一一句话', () {
    test('零失败时摘要逐字不变', () {
      expect(summarizeSyncReport(SyncRunReport()),
          t.sync_now_done(detail: t.sync_now_no_changes));
    });

    test('非鉴权失败时摘要逐字不变（回归护栏）', () {
      final SyncRunReport r = SyncRunReport()
        ..noteError('video assets sync', SyncBackendError('500'));
      expect(
        summarizeSyncReport(r),
        '${t.sync_now_done(detail: t.sync_now_no_changes)}'
        '${t.sync_now_failed_suffix(count: 1)}',
      );
    });

    test('服务端拒绝时摘要把服务端给的原因摆出来', () {
      final SyncRunReport r = SyncRunReport()
        ..noteError(
          'service config live sync',
          SyncAuthError('Server refused (403): GET /svc',
              kind: SyncAuthFailureKind.forbidden,
              serverReason: 'HTTPS required for service config'),
        );
      final String shown = summarizeSyncReport(r);
      expect(shown, contains('HTTPS required for service config'));
      expect(shown, isNot(contains(t.sync_err_auth_expired)));
    });

    test('凭据错时摘要说去重新登录', () {
      final SyncRunReport r = SyncRunReport()
        ..noteError('import book "x"', SyncAuthError('Authentication failed'));
      expect(summarizeSyncReport(r), contains(t.sync_err_auth_expired));
    });
  });
}
