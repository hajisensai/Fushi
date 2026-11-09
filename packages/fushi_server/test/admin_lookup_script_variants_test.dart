import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 服务端「中文查词简繁互查」开关（PR #3003 遗留：之前只读一个服务端上没有任何入口
/// 能写的偏好键，浏览器扩展经服务端查词永远不互查）：配置项 `lookup_chinese_script_variants`
/// 经 admin API（WebUI「设置」页 / `ctl settings set`）读写、落 yaml、推进 host 的实时配置。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_zh_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({AdminApi api, AdminContext ctx, HeadlessHost host})> build() async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    final AdminContext ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
    );
    return (api: AdminApi(ctx), ctx: ctx, host: host);
  }

  Future<({int status, Map<String, dynamic> json})> call(
    AdminApi api,
    String method,
    String path, [
    Object? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final Object? decoded = jsonDecode(await r.readAsString());
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(decoded! as Map),
    );
  }

  test('GET settings：默认关，且不在「需重启」清单里', () async {
    final (:AdminApi api, ctx: _, host: _) = await build();
    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'GET',
      'settings',
    );
    expect(status, 200);
    expect(json['lookupChineseScriptVariants'], isFalse);
    expect(
      (json['restartRequiredKeys'] as List).contains(
        'lookupChineseScriptVariants',
      ),
      isFalse,
    );
  });

  test('PUT 开 → 写回 yaml 并推进 host 实时配置；再 PUT 关回去', () async {
    final (:AdminApi api, :AdminContext ctx, :HeadlessHost host) =
        await build();
    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'lookupChineseScriptVariants': true},
    );
    expect(status, 200, reason: '$json');
    expect(json['lookupChineseScriptVariants'], isTrue);
    expect(
      (await ServerConfig.load(configFile)).lookupChineseScriptVariants,
      isTrue,
    );
    expect(ctx.config.lookupChineseScriptVariants, isTrue);
    expect(
      host.config.lookupChineseScriptVariants,
      isTrue,
      reason: '查词 service 现读 host.config；没推进去就要重启才生效',
    );

    // 缺省 = 不改。
    await call(api, 'PUT', 'settings', <String, Object?>{'deviceName': 'nas'});
    expect(host.config.lookupChineseScriptVariants, isTrue);

    await call(api, 'PUT', 'settings', <String, Object?>{
      'lookupChineseScriptVariants': false,
    });
    expect(host.config.lookupChineseScriptVariants, isFalse);
    expect(
      (await ServerConfig.load(configFile)).lookupChineseScriptVariants,
      isFalse,
    );
  });

  test('非 bool → 400，不落盘', () async {
    final (:AdminApi api, ctx: _, :HeadlessHost host) = await build();
    final (:int status, json: _) = await call(
      api,
      'PUT',
      'settings',
      <String, Object?>{'lookupChineseScriptVariants': 'yes'},
    );
    expect(status, 400);
    expect(host.config.lookupChineseScriptVariants, isFalse);
    expect(
      (await ServerConfig.load(configFile)).lookupChineseScriptVariants,
      isFalse,
    );
  });

  test('AI 助手的 server.settings.set 可改（可撤销清单里有它）', () {
    expect(kServerAgentSettingKeys, contains('lookupChineseScriptVariants'));
  });

  test('服务端开关只管没自带开关的请求方，且只在中文时生效', () {
    // 浏览器扩展 / 旧客户端：不带 zhScriptVariants → 用服务端开关。
    expect(
      serverLookupUsesChineseScriptVariants(
        requested: null,
        language: 'zh-TW',
        serverToggle: true,
      ),
      isTrue,
    );
    expect(
      serverLookupUsesChineseScriptVariants(
        requested: null,
        language: 'zh-TW',
        serverToggle: false,
      ),
      isFalse,
    );
    // 请求方自带开关时以请求方为准。
    expect(
      serverLookupUsesChineseScriptVariants(
        requested: false,
        language: 'zh',
        serverToggle: true,
      ),
      isFalse,
    );
  });
}
