import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pkce_oauth.dart';
import 'package:fushi/src/sync/pkce_oauth_backend_mixin.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// Dropbox / OneDrive 共用的 PKCE 认证外壳 [PkceOAuthBackendMixin]。
///
/// 抽 mixin 之前两个后端各有一份逐字相同的实现，且**两边都没有单测**
/// （2026-07-24 审查 §三-1）。这里用 fake [PkceOAuthFlow] 把 token 端点隔开，
/// 直接锁四条行为：换码落库、恢复保留旧 refresh token、恢复失败清空状态
/// （HBK-AUDIT-159）、无 pending 流拒绝回跳。
void main() {
  group('PkceOAuthBackendMixin', () {
    late _FakeFlow flow;
    late _TestBackend backend;
    final SyncRepository repo = _UnusedRepo();

    setUp(() {
      flow = _FakeFlow();
      backend = _TestBackend(flow);
    });

    test('exchangeCode：写入两个 token、取邮箱、把 refresh token 落库', () async {
      flow.onExchange =
          (String code, String redirectUri, String verifier) async {
        expect(code, 'code-1');
        expect(redirectUri, 'fushi://auth/test');
        expect(verifier, 'v-1');
        return const PkceTokens(accessToken: 'a1', refreshToken: 'r1');
      };

      await backend.exchangeForTest(
        code: 'code-1',
        verifier: 'v-1',
        redirectUri: 'fushi://auth/test',
        repo: repo,
      );

      expect(backend.access, 'a1');
      expect(backend.refresh, 'r1');
      expect(await backend.isAuthenticated, isTrue);
      expect(await backend.currentEmail, 'u@example.com');
      expect(backend.emailFetches, 1);
      expect(jsonDecode(backend.stored!), {'refresh_token': 'r1'});
    });

    test('restoreAuth：用落库 refresh token 换新 access；响应缺 refresh_token 时保留旧值',
        () async {
      backend.stored = jsonEncode({'refresh_token': 'r-stored'});
      flow.onRefresh = (String refreshToken) async {
        expect(refreshToken, 'r-stored');
        return const PkceTokens(accessToken: 'a-new');
      };

      expect(await backend.restoreAuth(repo), isTrue);
      expect(backend.access, 'a-new');
      expect(backend.refresh, 'r-stored');
      expect(backend.emailFetches, 1);
      expect(flow.refreshCalls, 1);
    });

    test(
        'restoreAuth：刷新失败必须清空两个 token，isAuthenticated 如实报 false（HBK-AUDIT-159）',
        () async {
      backend.stored = jsonEncode({'refresh_token': 'r-stale'});
      backend.seedAccess('a-stale');
      flow.onRefresh = (_) async => throw SyncAuthError('invalid_grant');

      expect(await backend.restoreAuth(repo), isFalse);
      expect(backend.access, isNull);
      expect(backend.refresh, isNull);
      expect(await backend.isAuthenticated, isFalse);
      expect(backend.emailFetches, 0);
    });

    test('restoreAuth：没落库 / 落库缺 refresh_token 都直接 false，不打 token 端点', () async {
      flow.onRefresh = (_) async => fail('must not refresh');

      backend.stored = null;
      expect(await backend.restoreAuth(repo), isFalse);

      backend.stored = jsonEncode({'other': 1});
      expect(await backend.restoreAuth(repo), isFalse);
      expect(flow.refreshCalls, 0);
    });

    test(
        'refreshAuth：provider 回了新 refresh token 就替换；没有 refresh token 时抛 SyncAuthError',
        () async {
      await expectLater(backend.refreshAuth(), throwsA(isA<SyncAuthError>()));

      backend.stored = jsonEncode({'refresh_token': 'r1'});
      flow.onRefresh =
          (_) async => const PkceTokens(accessToken: 'a2', refreshToken: 'r2');
      expect(await backend.restoreAuth(repo), isTrue);
      expect(backend.refresh, 'r2');
    });

    test('handleAuthCode：没有 pending 流时拒绝，且不碰 token 端点', () async {
      flow.onExchange = (_, __, ___) async => fail('must not exchange');
      await expectLater(
        backend.handleAuthCode('unsolicited'),
        throwsA(isA<SyncAuthError>()),
      );
    });

    test('signOut：清 token 与邮箱、清文件夹缓存、删落库 token', () async {
      backend.stored = jsonEncode({'refresh_token': 'r1'});
      flow.onRefresh = (_) async => const PkceTokens(accessToken: 'a1');
      expect(await backend.restoreAuth(repo), isTrue);

      await backend.signOut(repo: repo);

      expect(backend.access, isNull);
      expect(backend.refresh, isNull);
      expect(await backend.currentEmail, isNull);
      expect(backend.clearCacheCalls, 1);
      expect(backend.stored, isNull);
    });
  });

  group('源码守卫：两个 OAuth 后端不再各写一份认证外壳', () {
    const List<String> backends = <String>[
      'lib/src/sync/dropbox_sync_backend.dart',
      'lib/src/sync/onedrive_sync_backend.dart',
    ];
    // 抽走前两边逐字重复的五段；任何一段回流都说明有人又复制了一份。
    const List<String> banned = <String>[
      'Future<void> handleAuthCode(',
      'Future<bool> restoreAuth(',
      'Future<void> refreshAuth(',
      'Future<void> authenticate(',
      'get _authHeaders',
    ];

    for (final String path in backends) {
      test(path, () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
        final String src = f.readAsStringSync();
        expect(src, contains('PkceOAuthBackendMixin'),
            reason: '$path 必须混入 PkceOAuthBackendMixin');
        for (final String needle in banned) {
          expect(src, isNot(contains(needle)),
              reason: '$path 里出现 `$needle`——认证外壳应只在 mixin 里有一份');
        }
      });
    }
  });
}

/// 把 token 端点两次交换换成可编程的桩；未设置的回调一律 fail，避免静默通过。
class _FakeFlow extends PkceOAuthFlow {
  _FakeFlow()
      : super(
          clientId: 'real-client-id',
          tokenEndpoint: 'https://example.invalid/token',
        );

  Future<PkceTokens> Function(String code, String redirectUri, String verifier)?
      onExchange;
  Future<PkceTokens> Function(String refreshToken)? onRefresh;
  int refreshCalls = 0;

  @override
  Future<PkceTokens> exchangeCode({
    required String code,
    required String redirectUri,
    required String verifier,
  }) {
    final Future<PkceTokens> Function(String, String, String)? cb = onExchange;
    if (cb == null) fail('exchangeCode not expected');
    return cb(code, redirectUri, verifier);
  }

  @override
  Future<PkceTokens> refreshTokens({required String refreshToken}) {
    refreshCalls++;
    final Future<PkceTokens> Function(String)? cb = onRefresh;
    if (cb == null) fail('refreshTokens not expected');
    return cb(refreshToken);
  }
}

/// 最小宿主：只实现 mixin 的 provider 钩子，其余 [SyncBackend] 成员经
/// [noSuchMethod] 兜底（本测试不碰文件夹/文件操作）。
class _TestBackend extends SyncBackend with PkceOAuthBackendMixin {
  _TestBackend(this.flow);

  final _FakeFlow flow;
  String? stored;
  int emailFetches = 0;
  int clearCacheCalls = 0;

  @override
  PkceOAuthFlow get oauth => flow;

  @override
  String get providerName => 'Test';

  @override
  String get mobileRedirectUri => 'fushi://auth/test';

  @override
  Uri buildAuthUrl(String challenge, String redirectUri) => Uri.parse(
      'https://example.invalid/authorize?c=$challenge&r=$redirectUri');

  @override
  Future<String?> readStoredToken(SyncRepository repo) async => stored;

  @override
  Future<void> writeStoredToken(SyncRepository repo, String? token) async {
    stored = token;
  }

  @override
  Future<void> fetchUserEmail() async {
    emailFetches++;
    email = 'u@example.com';
  }

  @override
  void clearCache() {
    clearCacheCalls++;
  }

  // 受保护状态的测试口——只在子类内部触碰 @protected 成员。
  String? get access => accessToken;
  String? get refresh => refreshToken;
  void seedAccess(String token) => accessToken = token;
  Future<void> exchangeForTest({
    required String code,
    required String verifier,
    required String redirectUri,
    required SyncRepository repo,
  }) =>
      exchangeCode(
        code: code,
        verifier: verifier,
        redirectUri: redirectUri,
        repo: repo,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}

/// mixin 的存取钩子已被 [_TestBackend] 截住，repo 只是个占位。
class _UnusedRepo implements SyncRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('repo not used in this test');
}
