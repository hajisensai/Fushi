// BUG-5169：Google Drive 同步并行通道同时遇到 401 时，令牌刷新不能关掉别的通道
// 还在用的连接，也不能各自刷新一遍；刷新后的请求必须用新令牌，之后每轮同步不受影响。
//
// 走真实代码路径：GoogleDriveHandler._call → GoogleDriveAuth.refreshAuth →
// googleapis_auth.refreshCredentials（打假 token 端点）→ 用新 client 重试。唯一的假件是
// 底层 HTTP client：它像 IOClient 一样，close 之后再发请求就抛
// 「Client is already closed」，这样「刷新关掉了在用的连接」能被直接看到。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/google_drive_auth.dart';
import 'package:fushi/src/sync/google_drive_handler.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:http/http.dart' as http;

/// 假的 Google 服务端 + 底层连接。只认 [validToken]；token 端点每次换发一个新令牌，
/// 发令牌前等 [tokenGate]，好让多个 401 在刷新完成前全部到齐。
class _FakeGoogle extends http.BaseClient {
  _FakeGoogle({required this.validToken});

  String validToken;
  int tokenRequests = 0;
  int closeCount = 0;
  Completer<void>? tokenGate;
  final List<String> driveAuthHeaders = <String>[];

  bool get closed => closeCount > 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) {
      // 与 package:http 的 IOClient 关闭后的行为一致。
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    if (request.url.host == 'oauth2.googleapis.com') {
      tokenRequests++;
      final Completer<void>? gate = tokenGate;
      if (gate != null) await gate.future;
      validToken = 'token-$tokenRequests';
      return _json(<String, Object?>{
        'access_token': validToken,
        'expires_in': 3600,
        'token_type': 'Bearer',
      }, 200);
    }
    final String header = request.headers['Authorization'] ?? '';
    driveAuthHeaders.add(header);
    if (header != 'Bearer $validToken') {
      return _json(<String, Object?>{
        'error': <String, Object?>{
          'code': 401,
          'message': 'Request had invalid authentication credentials.',
        },
      }, 401);
    }
    return _json(<String, Object?>{
      'files': <Object?>[
        <String, Object?>{
          'id': 'f1',
          'name': 'probe',
          'mimeType': 'application/octet-stream',
        },
      ],
    }, 200);
  }

  @override
  void close() => closeCount++;

  static http.StreamedResponse _json(Map<String, Object?> body, int status) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

auth.AccessCredentials _staleCredentials() => auth.AccessCredentials(
  auth.AccessToken(
    'Bearer',
    'token-stale',
    DateTime.now().toUtc().add(const Duration(minutes: 30)),
  ),
  'refresh-token',
  <String>['https://www.googleapis.com/auth/drive.appdata'],
);

Future<void> _pumpUntil(bool Function() condition) async {
  for (int i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  final GoogleDriveAuth driveAuth = GoogleDriveAuth.instance;
  final GoogleDriveHandler handler = GoogleDriveHandler.instance;

  tearDown(() async {
    await driveAuth.signOut();
    handler.clearCache();
  });

  test('并行通道同时 401：只刷新一次、不关连接，全部用新令牌成功', () async {
    // 服务端已经不认 token-stale（访问令牌过期），会话里装的正是它。
    final _FakeGoogle google = _FakeGoogle(validToken: 'not-yet-issued');
    final Completer<void> gate = Completer<void>();
    google.tokenGate = gate;
    final auth.AuthClient staleClient = driveAuth.debugInstallDesktopSession(
      google,
      _staleCredentials(),
    );

    // 同步各通道（tombstones / videos / aggregate / settings / collections）是
    // Future.wait 并行跑的。
    final List<Future<List<AssetEntry>>> channels = <Future<List<AssetEntry>>>[
      for (int i = 0; i < 4; i++) handler.listChildrenRaw('parent-$i'),
    ];

    // 四个请求都带旧令牌吃了 401，且都在等同一次刷新。
    await _pumpUntil(
      () =>
          google.driveAuthHeaders
              .where((String h) => h == 'Bearer token-stale')
              .length ==
          4,
    );
    await _pumpUntil(() => google.tokenRequests == 1);
    gate.complete();

    final List<List<AssetEntry>> results = await Future.wait(channels);
    for (final List<AssetEntry> entries in results) {
      expect(entries.map((AssetEntry e) => e.name), <String>['probe']);
    }
    expect(google.tokenRequests, 1, reason: '并发 401 必须共用一次刷新');
    expect(google.closed, isFalse, reason: '刷新令牌不能关掉在用的底层连接');

    final auth.AuthClient current = await driveAuth.getAuthClient();
    expect(identical(current, staleClient), isFalse);
    expect(current.credentials.accessToken.data, 'token-1');

    // 下一轮同步：直接用新令牌，不再 401、不再刷新。
    google.driveAuthHeaders.clear();
    final List<AssetEntry> next = await handler.listChildrenRaw('again');
    expect(next.single.name, 'probe');
    expect(google.driveAuthHeaders, <String>['Bearer token-1']);
    expect(google.tokenRequests, 1);
  });

  test('迟到的 401（带的是已被换掉的 client）不再触发刷新', () async {
    final _FakeGoogle google = _FakeGoogle(validToken: 'not-yet-issued');
    final auth.AuthClient staleClient = driveAuth.debugInstallDesktopSession(
      google,
      _staleCredentials(),
    );

    await driveAuth.refreshAuth(rejected: staleClient);
    expect(google.tokenRequests, 1);
    final auth.AuthClient fresh = await driveAuth.getAuthClient();

    // 刷新完成后才回来的旧请求的 401：当前 client 已经是新的，不该再换一遍令牌。
    await driveAuth.refreshAuth(rejected: staleClient);
    expect(google.tokenRequests, 1);
    expect(identical(await driveAuth.getAuthClient(), fresh), isTrue);

    // 新令牌本身被拒才再刷新。
    await driveAuth.refreshAuth(rejected: fresh);
    expect(google.tokenRequests, 2);
    expect(google.closed, isFalse);
  });

  test('底层连接只在登出 / 换会话时关', () async {
    final _FakeGoogle first = _FakeGoogle(validToken: 'x');
    driveAuth.debugInstallDesktopSession(first, _staleCredentials());
    await driveAuth.refreshAuth();
    expect(first.closeCount, 0);

    // 重新登录装入新会话：旧会话的连接关一次。
    final _FakeGoogle second = _FakeGoogle(validToken: 'x');
    driveAuth.debugInstallDesktopSession(second, _staleCredentials());
    expect(first.closeCount, 1);
    expect(second.closeCount, 0);

    await driveAuth.signOut();
    expect(second.closeCount, 1);
    expect(first.closeCount, 1);
  });
}
