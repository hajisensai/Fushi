import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/pkce_backend_auth_mixin.dart';
import 'package:hibiki/src/sync/pkce_oauth.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';

/// PKCE OAuth 认证外壳（[PkceBackendAuthMixin]）回归测试。
///
/// Dropbox / OneDrive 曾各持一份逐字相同的 handleAuthCode / 授权码兑换 /
/// restoreAuth / refreshAuth（含 HBK-AUDIT-159 的陈旧 token 丢弃语义），合并进
/// mixin 后由本文件钉住共享外壳的行为 + 每个后端各自的分叉点（redirect URI、
/// token 持久化键）。token 网络交换经 [PkceBackendAuthMixin.debugOAuthFlowOverride]
/// 注入 fake，不打真网络；fetchUserEmail 的真实 HTTP 调用被 flutter_test 的
/// mock HttpClient 以 400 立即拒绝并由后端自吞（非致命路径）。
void main() {
  // 装上 flutter_test 的全局 mock HttpOverrides（所有 HTTP 请求立即返回 400），
  // 保证 fetchUserEmail 不出网也不阻塞。
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<_BackendCase> cases = <_BackendCase>[
    _BackendCase(
      name: 'Dropbox',
      backend: DropboxSyncBackend.instance,
      expectedRedirectUri: 'hibiki://auth/dropbox',
      seedStored: (_FakeSyncRepository repo, String? json) =>
          repo.dropboxToken = json,
      readPersisted: (_FakeSyncRepository repo) => repo.dropboxToken,
    ),
    _BackendCase(
      name: 'OneDrive',
      backend: OneDriveSyncBackend.instance,
      expectedRedirectUri: 'hibiki://auth/onedrive',
      seedStored: (_FakeSyncRepository repo, String? json) =>
          repo.oneDriveToken = json,
      readPersisted: (_FakeSyncRepository repo) => repo.oneDriveToken,
    ),
  ];

  for (final _BackendCase c in cases) {
    group('${c.name} PKCE auth shell', () {
      late _FakeOAuthFlow flow;
      late _FakeSyncRepository repo;

      setUp(() {
        flow = _FakeOAuthFlow();
        repo = _FakeSyncRepository();
        c.backend.debugResetAuthState();
        c.backend.debugOAuthFlowOverride = flow;
      });

      tearDown(() {
        // 后端是进程级单例：测试间必须复位，防止 token/pending 状态串场。
        c.backend.debugResetAuthState();
      });

      test('handleAuthCode 无 pending flow 时抛 SyncAuthError', () async {
        await expectLater(
          c.backend.handleAuthCode('code-x'),
          throwsA(isA<SyncAuthError>()),
        );
        expect(flow.exchangeCalls, isEmpty,
            reason: '没有 pending flow 时绝不能拿 code 去兑换');
      });

      test('handleAuthCode 正常路径：兑换参数正确并持久化 refresh token', () async {
        c.backend.setPendingAuth(verifier: 'verifier-1', repo: repo);
        await c.backend.handleAuthCode('code-1');

        expect(flow.exchangeCalls, hasLength(1));
        expect(flow.exchangeCalls.single, <String, String>{
          'code': 'code-1',
          'verifier': 'verifier-1',
          // 移动端兑换必须回传该后端自己的 custom-scheme redirect URI。
          'redirectUri': c.expectedRedirectUri,
        });
        // refresh token 落到该后端自己的持久化键（Dropbox 键与 OneDrive 键
        // 不得互串）。
        expect(c.readPersisted(repo),
            jsonEncode(<String, String?>{'refresh_token': 'rt-exchanged'}));
        expect(await c.backend.isAuthenticated, isTrue);
      });

      test('handleAuthCode 消费掉 pending flow：二次回跳不能重放', () async {
        c.backend.setPendingAuth(verifier: 'verifier-1', repo: repo);
        await c.backend.handleAuthCode('code-1');

        await expectLater(
          c.backend.handleAuthCode('code-1'),
          throwsA(isA<SyncAuthError>()),
        );
        expect(flow.exchangeCalls, hasLength(1));
      });

      test('restoreAuth 有存储的 refresh token：刷新并恢复会话', () async {
        c.seedStored(
            repo, jsonEncode(<String, String>{'refresh_token': 'rt-stored'}));

        expect(await c.backend.restoreAuth(repo), isTrue);
        expect(flow.refreshCalls, <String>['rt-stored']);
        expect(await c.backend.isAuthenticated, isTrue);
      });

      test('restoreAuth 无存储 token：返回 false 且不发请求', () async {
        expect(await c.backend.restoreAuth(repo), isFalse);
        expect(flow.refreshCalls, isEmpty);
        expect(await c.backend.isAuthenticated, isFalse);
      });

      test('restoreAuth 存储 JSON 缺 refresh_token 字段：返回 false', () async {
        c.seedStored(repo, jsonEncode(<String, String>{}));

        expect(await c.backend.restoreAuth(repo), isFalse);
        expect(flow.refreshCalls, isEmpty);
      });

      test('restoreAuth 刷新被拒：丢弃陈旧 token（HBK-AUDIT-159）', () async {
        c.seedStored(
            repo, jsonEncode(<String, String>{'refresh_token': 'rt-dead'}));
        flow.refreshError = SyncAuthError('Token refresh failed: 400');

        expect(await c.backend.restoreAuth(repo), isFalse);
        expect(await c.backend.isAuthenticated, isFalse,
            reason: '刷新失败后必须报未认证，不能拿过期 token 循环撞 401');
        // refresh token 已被丢弃：后续 refreshAuth 必须直接报无票，而不是
        // 复用刚被拒绝的旧票。
        await expectLater(
          c.backend.refreshAuth(),
          throwsA(isA<SyncAuthError>()),
        );
        expect(flow.refreshCalls, <String>['rt-dead']);
      });

      test('refreshAuth 无 refresh token 时抛 SyncAuthError', () async {
        await expectLater(
          c.backend.refreshAuth(),
          throwsA(isA<SyncAuthError>()),
        );
        expect(flow.refreshCalls, isEmpty);
      });

      test('refreshAuth 轮换 refresh token；响应缺省时保留旧票', () async {
        c.seedStored(
            repo, jsonEncode(<String, String>{'refresh_token': 'rt-0'}));
        flow.refreshResult =
            const PkceTokens(accessToken: 'at-1', refreshToken: 'rt-1');
        expect(await c.backend.restoreAuth(repo), isTrue);

        // 响应不带新 refresh token：保留上一轮拿到的 rt-1。
        flow.refreshResult = const PkceTokens(accessToken: 'at-2');
        await c.backend.refreshAuth();
        await c.backend.refreshAuth();

        expect(flow.refreshCalls, <String>['rt-0', 'rt-1', 'rt-1']);
        expect(await c.backend.isAuthenticated, isTrue);
      });
    });
  }

  test('source guard: 两后端不再各持认证外壳副本，统一走 PkceBackendAuthMixin', () {
    const List<String> paths = <String>[
      'lib/src/sync/dropbox_sync_backend.dart',
      'lib/src/sync/onedrive_sync_backend.dart',
    ];
    for (final String path in paths) {
      final String source = File(path).readAsStringSync();
      expect(source, contains('PkceBackendAuthMixin'),
          reason: '$path 必须 with PkceBackendAuthMixin 共享认证外壳');
      for (final String local in <String>[
        'handleAuthCode(',
        'restoreAuth(',
        'refreshAuth(',
        '_exchangeCode(',
      ]) {
        expect(source.contains(local), isFalse,
            reason: '$path 不应再保留 $local 的本地副本（会与 mixin 版漂移）');
      }
    }
  });
}

/// 一个后端的参数化测试口径：mixin 视角的实例 + 各自的分叉点断言钩子。
class _BackendCase {
  _BackendCase({
    required this.name,
    required this.backend,
    required this.expectedRedirectUri,
    required this.seedStored,
    required this.readPersisted,
  });

  final String name;
  final PkceBackendAuthMixin backend;

  /// 该后端移动端兑换时必须使用的 custom-scheme redirect URI。
  final String expectedRedirectUri;

  /// 往 fake repo 里预置该后端持久化键下的 token JSON。
  final void Function(_FakeSyncRepository repo, String? json) seedStored;

  /// 读出该后端持久化键下的 token JSON。
  final String? Function(_FakeSyncRepository repo) readPersisted;
}

/// 记录调用并返回预置 token 的 fake PKCE 交换器（不打网络）。
class _FakeOAuthFlow extends PkceOAuthFlow {
  _FakeOAuthFlow()
      : super(
          clientId: 'test-client',
          tokenEndpoint: 'https://token.invalid/oauth',
        );

  final List<Map<String, String>> exchangeCalls = <Map<String, String>>[];
  final List<String> refreshCalls = <String>[];

  PkceTokens exchangeResult = const PkceTokens(
      accessToken: 'at-exchanged', refreshToken: 'rt-exchanged');
  PkceTokens refreshResult =
      const PkceTokens(accessToken: 'at-refreshed', refreshToken: 'rt-rotated');

  /// 非 null 时 [refreshTokens] 抛出它（模拟 provider 拒绝刷新）。
  Exception? refreshError;

  @override
  Future<PkceTokens> exchangeCode({
    required String code,
    required String redirectUri,
    required String verifier,
  }) async {
    exchangeCalls.add(<String, String>{
      'code': code,
      'redirectUri': redirectUri,
      'verifier': verifier,
    });
    return exchangeResult;
  }

  @override
  Future<PkceTokens> refreshTokens({required String refreshToken}) async {
    refreshCalls.add(refreshToken);
    final Exception? error = refreshError;
    if (error != null) throw error;
    return refreshResult;
  }
}

/// 只实现两个 OAuth 后端会触达的 token 键；其余成员不会被认证外壳走到。
class _FakeSyncRepository implements SyncRepository {
  String? dropboxToken;
  String? oneDriveToken;

  @override
  Future<String?> getDropboxToken() async => dropboxToken;

  @override
  Future<void> setDropboxToken(String? token) async => dropboxToken = token;

  @override
  Future<String?> getOneDriveToken() async => oneDriveToken;

  @override
  Future<void> setOneDriveToken(String? token) async => oneDriveToken = token;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used by the auth shell');
}
