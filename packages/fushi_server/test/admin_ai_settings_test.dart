import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// admin API 的 AI 提供商设置：读写往返、API key 不回显、留空不改、预设置空即关、
/// 配错整单 400 不落半截、写回 yaml。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_ai_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({AdminApi api, AdminContext ctx})> build() async {
    final ServerConfig config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(config: config, paths: paths, db: db, prefs: prefs, identity: identity, p2pAvailable: () => false);
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
    return (api: AdminApi(ctx), ctx: ctx);
  }

  Future<({int status, String text})> call(AdminApi api, String method, [Object? body]) async {
    final shelf.Response r = await api.handle(shelf.Request(
      method,
      Uri.parse('http://localhost/api/admin/settings'),
      body: body == null ? null : jsonEncode(body),
    ));
    return (status: r.statusCode, text: await r.readAsString());
  }

  Map<String, dynamic>? aiOf(String text) => (jsonDecode(text) as Map<String, dynamic>)['ai'] as Map<String, dynamic>?;

  test('默认没有 AI；设上 → key 只报 apiKeySet、写进 yaml；留空不改；预设置空即关', () async {
    final (:AdminApi api, :AdminContext ctx) = await build();
    final ({int status, String text}) initial = await call(api, 'GET');
    expect(initial.status, 200);
    expect(aiOf(initial.text), isNull);
    expect((jsonDecode(initial.text) as Map<String, dynamic>)['aiPresets'], contains('openai'));

    final ({int status, String text}) set = await call(api, 'PUT', <String, Object?>{
      'ai': <String, Object?>{'preset': 'openai', 'apiKey': 'sk-secret', 'model': null, 'baseUrl': null, 'webKnowledge': true},
    });
    expect(set.status, 200, reason: set.text);
    expect(set.text, isNot(contains('sk-secret')), reason: 'API key 不回显');
    expect(aiOf(set.text)!['apiKeySet'], isTrue);
    expect(aiOf(set.text)!['status'], 'ready');
    expect(aiOf(set.text)!['effectiveModel'], isNotEmpty, reason: '空模型 = 预设起点模型');
    expect(ctx.config.ai!.apiKey, 'sk-secret');
    expect(await configFile.readAsString(), contains('api_key: "sk-secret"'));

    // WebUI 保存整张表单：key 输入框留空 = 不改。
    final ({int status, String text}) keep = await call(api, 'PUT', <String, Object?>{
      'ai': <String, Object?>{'preset': 'openai', 'apiKey': null, 'model': 'gpt-x'},
    });
    expect(keep.status, 200, reason: keep.text);
    expect(ctx.config.ai!.apiKey, 'sk-secret');
    expect(ctx.config.ai!.model, 'gpt-x');

    // 不带 ai 的保存不动它。
    expect((await call(api, 'PUT', <String, Object?>{'deviceName': 'box'})).status, 200);
    expect(ctx.config.ai, isNotNull);

    final ({int status, String text}) off = await call(api, 'PUT', <String, Object?>{
      'ai': <String, Object?>{'preset': null},
    });
    expect(off.status, 200);
    expect(aiOf(off.text), isNull);
    expect(ctx.config.ai, isNull);
    expect(await configFile.readAsString(), isNot(contains('sk-secret')));
  });

  test('配错（未知预设 / 明文 HTTP 远端）整单 400 且不落半截；只缺 key 照存但未就绪', () async {
    final (:AdminApi api, :AdminContext ctx) = await build();
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{'preset': 'nope'},
      <String, Object?>{'preset': 'custom', 'baseUrl': 'http://example.com/v1', 'model': 'm', 'apiKey': 'k'},
      <String, Object?>{'preset': 'openai', 'protocol': 'smoke'},
    ]) {
      final ({int status, String text}) r = await call(api, 'PUT', <String, Object?>{'deviceName': 'changed', 'ai': bad});
      expect(r.status, 400, reason: '$bad → ${r.text}');
      expect(ctx.config.ai, isNull);
      expect(ctx.config.deviceName, isNot('changed'), reason: '不落半截');
    }
    final ({int status, String text}) partial = await call(api, 'PUT', <String, Object?>{
      'ai': <String, Object?>{'preset': 'deepseek'},
    });
    expect(partial.status, 200, reason: partial.text);
    expect(aiOf(partial.text)!['status'], 'incomplete');
    expect(aiOf(partial.text)!['apiKeySet'], isFalse);
    expect(ctx.config.ai!.provider(), isNull, reason: '没 key 的提供商不可用 → 能力位 no_provider');
  });
}
