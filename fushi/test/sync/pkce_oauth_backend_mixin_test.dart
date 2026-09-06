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

    // 类头锚点：`PkceOAuthBackendMixin` 只能在 with 列表里算数。两个文件的 dartdoc
    // 里就写着 `[PkceOAuthBackendMixin]`，扫全文件是恒真的——把 with 列表里的 mixin
    // 删掉，那种断言照样绿（真正会红的是编译器，不是这条守卫）。
    const Map<String, String> declarations = <String, String>{
      'lib/src/sync/dropbox_sync_backend.dart':
          'class DropboxSyncBackend extends SyncBackend',
      'lib/src/sync/onedrive_sync_backend.dart':
          'class OneDriveSyncBackend extends SyncBackend',
    };
    // 抽 mixin 之后，每个后端**唯一**剩下的自有认证代码就是 readStoredToken /
    // writeStoredToken 两个存储钩子。它们接错对家照样编译、照样跑绿所有行为测试，
    // 后果却是两个后端共用一份凭据：登录 Dropbox 顶掉 OneDrive 的 token。
    // 这是 mixin 抽取最典型的复制粘贴翻车点，只能靠字面量守。
    const Map<String, String> ownProvider = <String, String>{
      'lib/src/sync/dropbox_sync_backend.dart': 'Dropbox',
      'lib/src/sync/onedrive_sync_backend.dart': 'OneDrive',
    };

    for (final String path in backends) {
      test(path, () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
        final String src = f.readAsStringSync();

        final int classAt = src.indexOf(declarations[path]!);
        expect(classAt, isNonNegative, reason: '$path 的类声明变了，守卫需更新');
        final int braceAt = src.indexOf('{', classAt);
        expect(braceAt, greaterThan(classAt), reason: '$path 扫不到类头结尾');
        expect(src.substring(classAt, braceAt),
            contains('PkceOAuthBackendMixin'),
            reason: '$path 的 with 列表里必须有 PkceOAuthBackendMixin');

        for (final String needle in banned) {
          expect(src, isNot(contains(needle)),
              reason: '$path 里出现 `$needle`——认证外壳应只在 mixin 里有一份');
        }

        final String own = ownProvider[path]!;
        final String other = own == 'Dropbox' ? 'OneDrive' : 'Dropbox';
        expect(src, contains('repo.get${own}Token()'),
            reason: '$path 的 readStoredToken 必须读自己那把存储键');
        expect(src, contains('repo.set${own}Token('),
            reason: '$path 的 writeStoredToken 必须写自己那把存储键');
        expect(src, isNot(contains('${other}Token')),
            reason: '$path 碰了对家的凭据键：两个后端会共用一份 token，'
                '登录一边顶掉另一边');
      });
    }

    test('Dropbox 的 revoke 必须排在 super.signOut 之前', () {
      // 抽 mixin 之前，撤销服务端 token 和清空本地凭据在同一个方法体里，顺序一眼
      // 可见。现在清空搬进了 mixin，顺序变成跨文件的隐式约定：把
      // `await super.signOut(repo: repo)` 挪到 revoke 前面，全套测试照样绿，
      // 而线上会拿 `Bearer null` 去 revoke——请求静默失败，服务端 token 永不撤销。
      const String path = 'lib/src/sync/dropbox_sync_backend.dart';
      final String src = File(path).readAsStringSync();
      const String anchor = 'Future<void> signOut({required SyncRepository repo';
      final int at = src.indexOf(anchor);
      expect(at, isNonNegative, reason: 'signOut 签名变了，守卫需更新');
      final int end = src.indexOf('\n  }', at);
      expect(end, greaterThan(at), reason: '扫不到 signOut 结尾，守卫需更新');
      final String body = src.substring(at, end);

      final int revokeAt = body.indexOf('/auth/token/revoke');
      final int superAt = body.indexOf('super.signOut(');
      expect(revokeAt, isNonNegative, reason: 'Dropbox 登出必须撤销服务端 token');
      expect(superAt, isNonNegative, reason: '清空本地凭据必须复用 mixin 的 signOut');
      expect(revokeAt, lessThan(superAt),
          reason: 'super.signOut 会把 accessToken 置空；顺序反了就是拿 '
              '`Bearer null` 去 revoke——静默失败，服务端 token 永不撤销');
    });
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
