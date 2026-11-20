// 设计稿 §6.3「服务端先升级，客户端还是旧版本」（规划 §6「§6.3 每一行一个测试」，交接「第六波 服务端收尾」）：真原生库、
// 真协议 3 `srs.db`（夹具 fixtures/srs_protocol3_two_profiles.db.gz）、真 HeadlessHost 经 HTTP。服务端启动即无头迁移到
// 新代并提供复习；还在协议 3 上的旧客户端从三条路碰到它：
//
// - 同步（服务端的互联 host 目录）：服务端的第一轮在旧根 `v3/meta.json` 立围栏（`minReader` 4）。协议 3 的读者见到
//   `minReader` 大于自己（3）就整轮停下、提示升级（v3.3.0 `srs_location_store.dart` 的 meta 判据），所以经新服务端同步的
//   旧客户端被挡住、什么都不写。旧客户端重建了 `minReader 3` 的 meta（云盘先删后传、旧版本的位置迁移）时，服务端下一轮
//   把围栏写回去。
// - 远程复习：能力位同时声明 V1（拒绝桩）与 V2；旧客户端发 V1 请求 → 426 `upgrade_required`（旧客户端据此提示本机该升级），
//   按能力位判定的旧客户端是「本机需要升级」。新客户端照常握手。
// - 互联制卡：线格式与代无关（字段 + 句子，`target` 可选），旧客户端不带 `target` 发过来照常落进新代库的默认 profile。
//
// 「客户端先升级，服务端还是旧版本」与「服务端一直不升级」在 fushi/test/srs/srs_generation_old_server_e2e_test.dart。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_remote_generation.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

/// 夹具里有笔记与复习的 profile（与 server_srs_migration_e2e_test.dart 同一个）。
const String kMain = '0193a1b2-0000-7000-8000-00000000beef';

/// 协议 3 的读者版本：位置 meta 的 `minReader` 大于它就停下。
const int kProtocol3Reader = 3;

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late HttpClient client;
  late String token;

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_gen_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          port: 0,
          bind: '127.0.0.1',
          tls: false,
          srs: const ServerSrsConfig(profiles: <String>[kMain]),
        );
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    token = identity.hostToken;
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    // 升级前的服务端留下的协议 3 复习库。
    File(SrsStorage.legacyPathIn(paths.support.path)).writeAsBytesSync(
      gzip.decode(
        File(
          p.join('test', 'fixtures', 'srs_protocol3_two_profiles.db.gz'),
        ).readAsBytesSync(),
      ),
    );
    host = HeadlessHost(
      srsRwkvHttpClient: noNetworkHttpClient,
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    await host.start();
  });

  tearDown(() async {
    client.close(force: true);
    await host.stop();
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<(int, Map<String, dynamic>)> send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${host.port}$path'),
    );
    req.headers.set(
      'Authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res = await req.close();
    final String text = await utf8.decodeStream(res);
    final Object? decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      res.statusCode,
      decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{'body': decoded},
    );
  }

  test('服务端先升级、客户端还是旧版本：同步被围栏挡住，远程复习明确拒绝，制卡照常落进新代库', () async {
    final ServerSrs srs = host.srs!;
    for (int i = 0; i < 1500 && srs.migrationRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(srs.migrationRunning, isFalse);
    expect(srs.generation.verdict, 'committed', reason: '启动即无头迁移');
    await srs.applyConfig();
    await srs.syncNow(kMain);
    final ServerSrsProfile prof = srs.profile(kMain)!;
    expect(
      prof.state,
      ServerSrsProfileState.ready,
      reason: '${prof.lastError}',
    );
    final String dir = prof.store!.sync2Dir!;

    // ── 同步：旧根上的围栏 ──
    final File meta3 = File(
      p.join(srs.syncRoot.path, kSrsSync2Namespace, dir, 'v3', 'meta.json'),
    );
    Map<String, Object?> fence() =>
        (jsonDecode(meta3.readAsStringSync()) as Map).cast<String, Object?>();
    expect(meta3.existsSync(), isTrue, reason: '服务端第一轮立了围栏');
    final List<int> fenceBytes = meta3.readAsBytesSync();
    expect(
      fence()['minReader'] as int,
      greaterThan(kProtocol3Reader),
      reason: '协议 3 的读者见到它就停下：${fence()}',
    );
    expect(
      File(
        p.join(srs.syncRoot.path, kSrsSync2Namespace, dir, 'v4', 'meta.json'),
      ).existsSync(),
      isTrue,
    );
    // 旧客户端重建了 minReader 3 的 meta（云盘先删后传 / 旧版本的位置迁移）：服务端下一轮写回围栏。
    meta3.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'collection': fence()['collection'],
        'minReader': kProtocol3Reader,
        'v': 3,
      }),
    );
    await srs.syncNow(kMain);
    expect(meta3.readAsBytesSync(), fenceBytes, reason: '围栏写回原样');

    // ── 远程复习 ──
    final (int capCode, Map<String, dynamic> caps) = await send(
      'GET',
      '/api/capabilities',
    );
    expect(capCode, 200);
    expect(caps[kSrsRemoteStoreCapability], isTrue, reason: 'V1 拒绝桩仍声明');
    expect(caps[kSrsRemoteStoreCapabilityV2], isTrue);
    final SrsRemoteHostGeneration hostGen = srsRemoteHostGenerationOf(caps);
    expect(
      srsRemoteHostCompat(hostGen, client: SrsRemoteWireVersion.v1),
      SrsRemoteHostCompat.clientNeedsUpgrade,
      reason: '按能力位判定的旧客户端：本机需要升级',
    );
    final (int v1Code, Map<String, dynamic> v1) = await send(
      'POST',
      '${kSrsRemoteStorePathPrefix}call',
      <String, Object?>{'op': 'hello'},
    );
    expect(v1Code, 426, reason: '$v1');
    expect(v1['error'], SrsRemoteStoreError.upgradeRequired, reason: '$v1');
    final (int v2Code, Map<String, dynamic> v2) = await send(
      'POST',
      '${kSrsRemoteStoreV2PathPrefix}call',
      <String, Object?>{kSrsRemoteGenerationKey: 4, 'op': 'hello'},
    );
    expect(v2Code, 200, reason: '新客户端照常握手：$v2');

    // ── 互联制卡：旧客户端不带 target ──
    final int before = await prof.store!.userNoteCount();
    final (int mineCode, Map<String, dynamic> mined) = await send(
      'POST',
      '/api/mine',
      <String, Object?>{
        'fields': <String, Object?>{
          'expression': '泳ぐ',
          'reading': 'およぐ',
          'glossary': 'to swim',
        },
        'sentence': '海で泳ぐ。',
      },
    );
    expect(mineCode, 200, reason: '$mined');
    expect(mined['result'], 'success', reason: '$mined');
    expect(await prof.store!.userNoteCount(), before + 1);
  });
}
