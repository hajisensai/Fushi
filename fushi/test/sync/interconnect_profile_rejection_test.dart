/// BUG-5261（反馈 G-ebgSnoK8）：互联「上传 / 下载配置」被 host 拒绝时，host 以前回
/// 英文自由文本（`Profile transfer disabled on host`），client 原样拼成「配置传输失败：
/// 服务端拒绝了这次请求：Profile transfer disabled on host（登录没问题）」上屏——没翻译，
/// 也没告诉用户去对端打开开关。
///
/// 现在 host 回结构化码，client 抛 [InterconnectProfileRejected]，友好错误翻译按码给出
/// 本地化原因。这里对真 TLS 的 [FushiSyncServer] + 真 [InterconnectSyncBackend] 跑完整
/// 链路（选路探测用假的）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_profile_transfer.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:path/path.dart' as p;

const String _peerToken = 'peer-token';
const String _sharedToken = 'shared-token';

class _ProfileHost implements FushiLibraryHostService, InterconnectProfileHost {
  bool enabled = false;
  bool hasProfile = true;

  @override
  Future<bool> isInterconnectProfileTransferEnabled() async => enabled;

  @override
  Future<String> exportInterconnectProfile() async {
    if (!hasProfile) {
      throw const InterconnectProfileUnavailableException('nothing yet');
    }
    return '{}';
  }

  @override
  Future<String> importInterconnectProfile(String json) async => 'imported';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;
  late _ProfileHost host;
  late FushiSyncServer server;
  late String fingerprint;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi-profile-reject-');
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    host = _ProfileHost();
    final ({String certificatePem, String privateKeyPem}) generated =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-profile-reject',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    fingerprint = FushiTlsIdentityStore.fingerprintOf(generated.certificatePem);
    server = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync'),
      port: 0,
      token: _sharedToken,
      allowLan: false,
      libraryService: host,
      securityContext: SecurityContext()
        ..useCertificateChainBytes(utf8.encode(generated.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(generated.privateKeyPem)),
      hostFingerprint: fingerprint,
    )..pairedPeerTokensProvider = (() async => <String>{_peerToken});
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  InterconnectSyncBackend backend() =>
      InterconnectSyncBackend.withProbe((String url, String token) async {
        return true;
      });

  Future<void> pair({String token = _peerToken}) =>
      repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: 'https://127.0.0.1:${server.port}',
          enabled: true,
          token: token,
          fingerprintSha256: fingerprint,
        ),
      ]);

  Matcher rejectedWith(InterconnectProfileDenial denial) => throwsA(
    isA<InterconnectProfileRejected>().having(
      (InterconnectProfileRejected e) => e.denial,
      'denial',
      denial,
    ),
  );

  Future<String> failureText(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (e) {
      return t.interconnect_profile_failed(message: friendlySyncErrorDetail(e));
    }
    fail('expected the transfer to be rejected');
  }

  test('host 开关关着：下载 / 上传都抛 disabled，上屏的是本地化的可操作原因', () async {
    await pair();
    final InterconnectSyncBackend b = backend();

    await expectLater(
      b.getRemoteProfileJson(repo: repo),
      rejectedWith(InterconnectProfileDenial.disabled),
    );
    await expectLater(
      b.putRemoteProfileJson('{}', repo: repo),
      rejectedWith(InterconnectProfileDenial.disabled),
    );

    final String shown = await failureText(
      () => b.getRemoteProfileJson(repo: repo),
    );
    expect(
      shown,
      t.interconnect_profile_failed(
        message: t.interconnect_profile_reason_disabled,
      ),
      reason: '不再是「服务端拒绝了这次请求：<host 英文原文>」',
    );
    expect(shown, isNot(contains('Profile transfer disabled on host')));
  });

  test('只带共享 token（没走配对）：peer_token_required → 提示重新配对', () async {
    host.enabled = true;
    await pair(token: _sharedToken);
    final InterconnectSyncBackend b = backend();

    await expectLater(
      b.getRemoteProfileJson(repo: repo),
      rejectedWith(InterconnectProfileDenial.peerTokenRequired),
    );
    expect(
      await failureText(() => b.putRemoteProfileJson('{}', repo: repo)),
      contains(t.interconnect_profile_reason_pairing),
    );
  });

  test('开关开着但 host 还没有配置可给：409 profile_unavailable', () async {
    host
      ..enabled = true
      ..hasProfile = false;
    await pair();
    final InterconnectSyncBackend b = backend();

    await expectLater(
      b.getRemoteProfileJson(repo: repo),
      rejectedWith(InterconnectProfileDenial.unavailable),
    );
    expect(
      await failureText(() => b.getRemoteProfileJson(repo: repo)),
      contains(t.interconnect_profile_reason_unavailable),
    );
  });

  test('开关开着：照常往返（拒绝码不误伤正常路径）', () async {
    host.enabled = true;
    await pair();
    final InterconnectSyncBackend b = backend();

    expect(await b.getRemoteProfileJson(repo: repo), '{}');
    expect(await b.putRemoteProfileJson('{}', repo: repo), 'imported');
  });

  test('每个拒绝码都有专属文案（不落到通用的「服务端拒绝」）', () {
    for (final InterconnectProfileDenial d
        in InterconnectProfileDenial.values) {
      expect(
        friendlySyncErrorDetail(InterconnectProfileRejected(d)),
        interconnectProfileDenialText(d),
      );
      expect(
        parseInterconnectProfileDenialBody(interconnectProfileDenialBody(d)),
        d,
      );
    }
    expect(
      parseInterconnectProfileDenialBody('Profile transfer disabled on host'),
      isNull,
      reason: '老 host 的自由文本不是拒绝码，交回统一的 checkStatus',
    );
  });
}
