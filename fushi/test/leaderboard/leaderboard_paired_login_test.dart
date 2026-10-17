import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/leaderboard/leaderboard_paired_login.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

/// 跟随已配对设备自动登录：真互联 host（[FushiSyncServer]，真 TLS）+ 真 host 侧
/// [AppLeaderboardLinkHost] + 真 client 侧 [LeaderboardPairedLogin]，排行榜服务端用假的。
///
/// 钉住的不变式：私钥 / 恢复码不经互联；host 开关关 / 明文 / 共享 token 都拒；
/// 失败退避（不每次都打服务端）；本机登录过（含主动退出）就不再自动登录。

const String _peerToken = 'peer-token-1';
const String _hostAccountId = 'HostAccount00001';

/// 假排行榜服务端：只认 `POST /v1/me/devices`（[linkStatus] 非 201 时按它回错）。
class _FakeRank {
  final List<http.Request> requests = <http.Request>[];
  int linkStatus = 201;
  String linkError = 'too_many_devices';

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (r.url.path == '/v1/me/devices' && r.method == 'POST') {
      if (linkStatus != 201) {
        return http.Response(
          jsonEncode(<String, String>{'error': linkError}),
          linkStatus,
        );
      }
      final LeaderboardDeviceLinkRequest req =
          LeaderboardDeviceLinkRequest.fromJson(
            (jsonDecode(r.body) as Map<Object?, Object?>)
                .cast<String, dynamic>(),
          );
      expect(req.verifyProof(), isTrue);
      return http.Response(
        jsonEncode(<String, Object?>{
          'id': _hostAccountId,
          'nickname': 'tom',
          'discriminator': 42,
          'avatar': null,
          'visibility': 'public',
          'createdAt': 1,
          'shelfCount': 3,
          'emailVerified': true,
          'uploadDevice': false,
          'role': 'user',
        }),
        201,
      );
    }
    return http.Response('{"error":"not_found"}', 404);
  }
}

void main() {
  late Directory root;
  late FushiDatabase hostDb;
  late FushiDatabase phoneDb;
  late _FakeRank rank;
  late LeaderboardService hostService;
  late LeaderboardService phoneService;
  late bool hostLinkEnabled;
  late Set<String> ownerTokens;
  late int now;
  late List<http.Request> hostRequests;
  FushiSyncServer? server;

  LeaderboardService service(String dir, FushiDatabase db) =>
      LeaderboardService(
        database: () => db,
        supportRoot: () async => Directory('${root.path}/$dir')..createSync(),
        profileId: () async => 1,
        httpClientFactory: () async => MockClient(rank.handle),
        defaultBaseUrl: Uri.parse('https://rank.example'),
        clockMs: () => now,
      );

  Future<void> giveHostAnAccount() async {
    final LeaderboardIdentity id = LeaderboardIdentity.generate();
    await LeaderboardStore(
      supportRoot: Directory('${root.path}/host'),
      profileId: 1,
    ).write(
      LeaderboardLocalAccount(
        recoveryCode: id.toRecoveryCode(),
        accountId: _hostAccountId,
        consentAt: 1,
      ),
    );
  }

  Future<void> startHost({bool tls = true, bool withHost = true}) async {
    SecurityContext? ctx;
    if (tls) {
      final ({String certificatePem, String privateKeyPem}) id =
          FushiSelfSignedCertGenerator.generate(
            commonName: 'fushi-test',
            sanIpAddresses: <String>['127.0.0.1'],
          );
      ctx = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(id.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
    }
    final FushiSyncServer started =
        FushiSyncServer(
            syncDataDir: '${root.path}/sync',
            port: 0,
            token: 'shared-token',
            allowLan: false,
            securityContext: ctx,
          )
          ..pairedPeerTokensProvider = (() async => <String>{_peerToken})
          ..leaderboardLinkHost = withHost
              ? AppLeaderboardLinkHost(
                  enabled: () async => hostLinkEnabled,
                  isOwnerDevicePeer: (String token) async =>
                      ownerTokens.contains(token),
                  service: () => hostService,
                )
              : null;
    await started.start();
    server = started;
  }

  Future<void> pairPhone({bool tls = true, String token = _peerToken}) =>
      SyncRepository(phoneDb).setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: '${tls ? 'https' : 'http'}://127.0.0.1:${server!.port}',
          fingerprintSha256: tls ? 'aa:bb' : null,
          deviceName: 'Desk PC',
          token: token,
        ),
      ]);

  /// 互联传输：记下发往 host 的每个请求（断言载荷里没有私钥），https 走信任任意证书的
  /// client（生产是指纹钉扎，钉扎本身另有测试）。
  InterconnectPostTransport transport() {
    http.Client record(http.Client inner) =>
        _RecordingClient(inner, (http.BaseRequest r) {
          if (r is http.Request) hostRequests.add(r);
        });
    return InterconnectPostTransport(
      repo: SyncRepository(phoneDb),
      httpClient: record(http.Client()),
      pinnedClientFactory: (String _) => record(
        IOClient(
          HttpClient()
            ..badCertificateCallback = (X509Certificate _, String _, int _) =>
                true,
        ),
      ),
    );
  }

  LeaderboardPairedLogin runner() => LeaderboardPairedLogin(
    service: phoneService,
    repository: SyncRepository(phoneDb),
    transport: transport,
    clockMs: () => now,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lb_paired_login_');
    hostDb = FushiDatabase.forTesting(NativeDatabase.memory());
    phoneDb = FushiDatabase.forTesting(NativeDatabase.memory());
    rank = _FakeRank();
    hostLinkEnabled = true;
    ownerTokens = <String>{_peerToken};
    now = DateTime.now().millisecondsSinceEpoch;
    hostRequests = <http.Request>[];
    await giveHostAnAccount();
    hostService = service('host', hostDb);
    phoneService = service('phone', phoneDb);
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    hostService.dispose();
    phoneService.dispose();
    await hostDb.close();
    await phoneDb.close();
    root.deleteSync(recursive: true);
  });

  test('手机无账户 + 已配对 host 已登录：自动登录到同一账户，私钥不经互联', () async {
    await startHost();
    await pairPhone();
    final LeaderboardPairedLoginSuccess? done = await runner().maybeRun();

    expect(done, isNotNull);
    expect(done!.peerName, 'Desk PC');
    expect(done.self.account.id, _hostAccountId);
    expect(phoneService.status, LeaderboardStatus.active);
    final LeaderboardLocalAccount phone = phoneService.account!;
    expect(phone.accountId, _hostAccountId);
    // 与「邮箱登录没勾同意」一致：上传默认关、不记同意时刻。
    expect(phone.uploadEnabled, isFalse);
    expect(phone.consentAt, isNull);

    // 互联上只走了公钥 + 证明，没有任何私钥 / 恢复码。
    expect(hostRequests, hasLength(1));
    final Map<String, dynamic> wire =
        (jsonDecode(hostRequests.single.body) as Map<Object?, Object?>)
            .cast<String, dynamic>();
    expect(wire.keys.toSet(), <String>{'pubkey', 'time', 'proof'});
    final LeaderboardIdentity phoneKey = LeaderboardIdentity.fromRecoveryCode(
      phone.recoveryCode,
    );
    expect(wire['pubkey'], phoneKey.pubkeyBase64Url);
    expect(hostRequests.single.body, isNot(contains('FUSHI1-')));
    final String hostCode = (await LeaderboardStore(
      supportRoot: Directory('${root.path}/host'),
      profileId: 1,
    ).read())!.recoveryCode;
    expect(phone.recoveryCode, isNot(hostCode));

    // 服务端那一跳是 host 用**自己的**钥匙签的，body 里是手机的公钥。
    final http.Request link = rank.requests.single;
    expect(link.url.path, '/v1/me/devices');
    expect(
      link.headers['X-Fushi-Account'],
      LeaderboardIdentity.fromRecoveryCode(hostCode).accountId,
    );
    expect(
      (jsonDecode(link.body) as Map<Object?, Object?>)['pubkey'],
      phoneKey.pubkeyBase64Url,
    );
  });

  test('退出后不再自动登录；已有账户时也不发请求', () async {
    await startHost();
    await pairPhone();
    expect(await runner().maybeRun(), isNotNull);
    expect(await runner().maybeRun(), isNull, reason: '已有账户');
    await phoneService.signOutLocally();
    expect(await phoneService.canFollowPairedLogin(), isFalse);
    expect(await runner().maybeRun(), isNull);
    expect(hostRequests, hasLength(1));
  });

  test('client 开关关掉：一个请求都不发', () async {
    await startHost();
    await pairPhone();
    await SyncRepository(phoneDb).setLeaderboardFollowPairedLoginEnabled(false);
    expect(await runner().maybeRun(), isNull);
    expect(hostRequests, isEmpty);
  });

  test('host 开关关掉：403 disabled，手机不落档并退避', () async {
    hostLinkEnabled = false;
    await startHost();
    await pairPhone();
    final LeaderboardPairedLogin r = runner();
    expect(await r.maybeRun(), isNull);
    expect(phoneService.status, LeaderboardStatus.disabled);
    expect(rank.requests, isEmpty, reason: '开关关时 host 不碰服务端');
    expect(
      r.nextAttemptAt,
      now + kLeaderboardPairedLoginBaseBackoff.inMilliseconds,
    );
    // 退避期内不再打 host。
    expect(await r.maybeRun(), isNull);
    expect(hostRequests, hasLength(1));
    // 退避过了再试：这回开关开着，成功。
    hostLinkEnabled = true;
    now = r.nextAttemptAt!;
    expect(await r.maybeRun(), isNotNull);
  });

  test('发起的 peer 没被 host 标记为「我的设备」：403 not_owner_device，不碰服务端', () async {
    ownerTokens = <String>{};
    await startHost();
    await pairPhone();
    final LeaderboardPairedLogin r = runner();
    expect(await r.maybeRun(), isNull);
    expect(phoneService.status, LeaderboardStatus.disabled);
    expect(rank.requests, isEmpty);
    expect(
      r.nextAttemptAt,
      now + kLeaderboardPairedLoginBaseBackoff.inMilliseconds,
    );
    // host 主人之后把它标记为我的设备：退避过后自动登录成功。
    ownerTokens = <String>{_peerToken};
    now = r.nextAttemptAt!;
    expect(await r.maybeRun(), isNotNull);
  });

  test('旧版服务端（404）/ 满 10 台：退避到上限，不反复打服务端', () async {
    await startHost();
    await pairPhone();
    rank.linkStatus = 404;
    rank.linkError = 'not_found';
    final LeaderboardPairedLogin r = runner();
    expect(await r.maybeRun(), isNull);
    expect(
      r.nextAttemptAt,
      now + kLeaderboardPairedLoginMaxBackoff.inMilliseconds,
    );

    rank.linkStatus = 409;
    rank.linkError = 'too_many_devices';
    final LeaderboardPairedLogin r2 = runner();
    expect(await r2.maybeRun(), isNull);
    expect(
      r2.nextAttemptAt,
      now + kLeaderboardPairedLoginMaxBackoff.inMilliseconds,
    );
    expect(phoneService.status, LeaderboardStatus.disabled);
  });

  test('host 本机没登录：409 no_account', () async {
    await LeaderboardStore(
      supportRoot: Directory('${root.path}/host'),
      profileId: 1,
    ).delete();
    hostService.dispose();
    hostService = service('host', hostDb);
    await startHost();
    await pairPhone();
    expect(await runner().maybeRun(), isNull);
    expect(rank.requests, isEmpty);
  });

  group('端点门', () {
    Future<({int status, String body})> post(
      String scheme, {
      String token = _peerToken,
      Object? body,
    }) async {
      final HttpClient c = HttpClient()
        ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
      try {
        final HttpClientRequest req = await c.postUrl(
          Uri.parse(
            '$scheme://127.0.0.1:${server!.port}$kInterconnectLeaderboardLinkPath',
          ),
        );
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        req.add(
          utf8.encode(
            jsonEncode(
              body ??
                  LeaderboardDeviceLinkRequest.sign(
                    LeaderboardIdentity.generate(),
                    now,
                  ).toJson(),
            ),
          ),
        );
        final HttpClientResponse res = await req.close();
        return (status: res.statusCode, body: await utf8.decodeStream(res));
      } finally {
        c.close(force: true);
      }
    }

    Future<Map<String, dynamic>> capabilities(String scheme) async {
      final HttpClient c = HttpClient()
        ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
      try {
        final HttpClientRequest req = await c.getUrl(
          Uri.parse('$scheme://127.0.0.1:${server!.port}/api/capabilities'),
        );
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('hibiki:$_peerToken'))}',
        );
        return (jsonDecode(await utf8.decodeStream(await req.close()))
                as Map<Object?, Object?>)
            .cast<String, dynamic>();
      } finally {
        c.close(force: true);
      }
    }

    test('明文 host：403 https_required，能力位不声明', () async {
      await startHost(tls: false);
      final ({int status, String body}) r = await post('http');
      expect(r.status, 403);
      expect(r.body, contains('https_required'));
      expect(
        (await capabilities('http'))[kInterconnectLeaderboardLinkCapability],
        isNull,
      );
      expect(rank.requests, isEmpty);
    });

    test('HTTPS：声明能力；共享 token 403；伪造证明 400；未装配 404', () async {
      await startHost();
      expect(
        (await capabilities('https'))[kInterconnectLeaderboardLinkCapability],
        isTrue,
      );
      final ({int status, String body}) shared = await post(
        'https',
        token: 'shared-token',
      );
      expect(shared.status, 403);
      expect(shared.body, contains('paired_peer_required'));

      final Map<String, dynamic> forged = LeaderboardDeviceLinkRequest.sign(
        LeaderboardIdentity.generate(),
        now,
      ).toJson()..['pubkey'] = LeaderboardIdentity.generate().pubkeyBase64Url;
      final ({int status, String body}) bad = await post('https', body: forged);
      expect(bad.status, 400);
      expect(rank.requests, isEmpty);

      await server!.stop();
      await startHost(withHost: false);
      expect((await post('https')).status, 404);
      expect(
        (await capabilities('https'))[kInterconnectLeaderboardLinkCapability],
        isNull,
      );
    });
  });

  group('已配对 host 交来的服务地址', () {
    Map<String, dynamic> account() => <String, dynamic>{
      'id': _hostAccountId,
      'nickname': 'tom',
      'discriminator': 42,
      'avatar': null,
      'visibility': 'public',
      'createdAt': 1,
      'shelfCount': 3,
      'emailVerified': true,
      'uploadDevice': false,
      'role': 'user',
    };

    Future<void> adopt(String? serverUrl) => phoneService.adoptFromPairedDevice(
      (LeaderboardDeviceLinkRequest _) async =>
          (account: account(), serverUrl: serverUrl),
    );

    for (final String bad in <String>[
      'http://rank.example',
      'http://evil.example',
      'ftp://rank.example',
      'https://',
      'https://user:pass@evil.example',
      'not a url',
    ]) {
      test('拒绝 $bad，本机不落账户', () async {
        await expectLater(adopt(bad), throwsFormatException);
        expect(phoneService.account, isNull);
      });
    }

    test('接受 https 地址', () async {
      await adopt('https://rank2.example');
      expect(phoneService.account!.serverUrl, 'https://rank2.example');
    });

    test('接受与本机默认服务地址一致的地址', () async {
      await adopt('https://rank.example');
      expect(phoneService.account!.accountId, _hostAccountId);
    });
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner, this._onSend);

  final http.Client _inner;
  final void Function(http.BaseRequest request) _onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _onSend(request);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
