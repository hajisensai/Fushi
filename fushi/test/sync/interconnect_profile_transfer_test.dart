import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/interconnect_profile_transfer.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;

/// 互联「配置文件」（Profile）搬运的端点与门控测试。
///
/// 三道门必须**同时**成立才允许：TLS 会话、已配对 peer token、host 侧用户开关。
/// 这里覆盖不需要真 TLS 也能判定的两类不变式：
///   * 明文会话上端点恒 403（整份配置不允许降级到明文，与 service-config 同规矩）；
///   * host 能力位与「开关默认关 / 依赖未接线即不可用」的判据。
void main() {
  group('端点安全门（明文会话）', () {
    late Directory tempDir;
    late FushiSyncServer server;
    const String token = 'shared-token';

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hbk_profile_xfer');
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: false,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Uri profileUri() =>
        Uri.parse('http://127.0.0.1:${server.port}$kInterconnectProfilePath');

    Map<String, String> authHeaders() => <String, String>{
          'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        };

    test('GET 在明文会话上被拒（403 HTTPS required）', () async {
      final http.Response res = await http.get(
        profileUri(),
        headers: authHeaders(),
      );
      expect(res.statusCode, 403);
      expect(res.body, contains('HTTPS required'));
    });

    test('PUT 在明文会话上同样被拒（入站写不得走明文）', () async {
      final http.Response res = await http.put(
        profileUri(),
        headers: authHeaders(),
        body: '{}',
      );
      expect(res.statusCode, 403);
      expect(res.body, contains('HTTPS required'));
    });

    test('其它方法一律 405（端点只认 GET/PUT）', () async {
      final http.Response res = await http.delete(
        profileUri(),
        headers: authHeaders(),
      );
      expect(res.statusCode, 405);
    });

    test('capabilities 广播 profileTransfer，明文 host 上为 false', () async {
      final http.Response res = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
        headers: authHeaders(),
      );
      expect(res.statusCode, 200);
      final Map<String, dynamic> json =
          jsonDecode(res.body) as Map<String, dynamic>;
      final Map<String, dynamic> live =
          (json['liveLibrary'] as Map).cast<String, dynamic>();
      expect(live.containsKey('profileTransfer'), isTrue,
          reason: 'client 靠这个字段决定要不要显示配置传输入口');
      expect(live['profileTransfer'], false,
          reason: '无 TLS 时能力位必须为 false（与端点的 403 一致，别让 UI 给出假承诺）');
    });
  });

  group('host 侧开关判据', () {
    late FushiDatabase db;
    late Directory tempDir;

    AppModelLibraryHostService buildHost({
      required bool wireProfileCallbacks,
    }) {
      return AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: tempDir,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        isProfileTransferEnabled: wireProfileCallbacks
            ? () => SyncRepository(db).isInterconnectProfileTransferEnabled()
            : null,
        exportActiveProfileJson:
            wireProfileCallbacks ? () async => '{"type":"hibiki.profile"}' : null,
        importProfileJson: wireProfileCallbacks ? (String _) async => 'p' : null,
      );
    }

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tempDir = Directory.systemTemp.createTempSync('hbk_profile_host');
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('默认关：接线了回调但用户没开，仍然不可用', () async {
      final AppModelLibraryHostService host =
          buildHost(wireProfileCallbacks: true);
      expect(await host.isInterconnectProfileTransferEnabled(), isFalse,
          reason: '整份配置的读写必须是用户显式 opt-in（BUG-988 的规矩）');
    });

    test('用户开启后可用', () async {
      await SyncRepository(db).setInterconnectProfileTransferEnabled(true);
      final AppModelLibraryHostService host =
          buildHost(wireProfileCallbacks: true);
      expect(await host.isInterconnectProfileTransferEnabled(), isTrue);
    });

    test('依赖未接线时即使开关为真也不可用（不会抛给对端 500）', () async {
      await SyncRepository(db).setInterconnectProfileTransferEnabled(true);
      final AppModelLibraryHostService host =
          buildHost(wireProfileCallbacks: false);
      expect(await host.isInterconnectProfileTransferEnabled(), isFalse);
      // 端点在开关判据为假时就 403 了，永远走不到这两个方法；真被调到也要如实抛，
      // 不能静默返回空串让对端导入一份空配置。
      expect(host.exportInterconnectProfile(), throwsUnsupportedError);
      expect(
        host.importInterconnectProfile('{}'),
        throwsUnsupportedError,
      );
    });

    test('开关是设备本地的持久化偏好，读回与写入一致', () async {
      final SyncRepository repo = SyncRepository(db);
      expect(await repo.isInterconnectProfileTransferEnabled(), isFalse);
      await repo.setInterconnectProfileTransferEnabled(true);
      expect(await repo.isInterconnectProfileTransferEnabled(), isTrue);
      await repo.setInterconnectProfileTransferEnabled(false);
      expect(await repo.isInterconnectProfileTransferEnabled(), isFalse);
    });
  });

  group('端点源码守卫：三道门的顺序不得被抽掉', () {
    late String src;

    setUpAll(() {
      src = File('lib/src/sync/fushi_sync_server.dart').readAsStringSync();
    });

    test('handler 依次过 TLS → peer token → 能力探测 → 用户开关', () {
      final int at = src.indexOf('Future<shelf.Response> _handleInterconnectProfile(');
      expect(at, greaterThan(0), reason: '找不到配置传输端点 handler');
      final String body = src.substring(at, at + 2400);
      final int tls = body.indexOf('_securityContext == null');
      final int auth = body.indexOf('_validatePeerAuth(');
      final int cap = body.indexOf('library is! InterconnectProfileHost');
      final int gate = body.indexOf('isInterconnectProfileTransferEnabled()');
      expect(tls, greaterThan(0), reason: '必须要求 TLS');
      expect(auth, greaterThan(tls), reason: '必须要求已配对 peer token');
      expect(cap, greaterThan(auth), reason: '能力探测在鉴权之后');
      expect(gate, greaterThan(cap), reason: 'host 侧用户开关是最后一道门');
      // 开关关着必须是 403（明确拒绝），不能是 404（会被 client 当成「不支持」而静默）。
      final String gateTail = body.substring(gate, gate + 240);
      expect(gateTail, contains('shelf.Response.forbidden'),
          reason: '开关关着要 403，让 client 能把「关着」与「不支持」分开报');
    });

    test('入站导入永不覆盖 host 既有配置（契约写在接口文档里）', () {
      final String iface =
          File('lib/src/sync/interconnect_profile_transfer.dart')
              .readAsStringSync();
      expect(iface, contains('createNew'),
          reason: '入站一律新建 Profile 的契约必须留在接口文档里');
    });
  });
}
