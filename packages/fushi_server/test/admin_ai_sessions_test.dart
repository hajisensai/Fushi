import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// BUG-4067 B：服务端管理页「AI 助手」——列出已配对设备经互联让服务端跑的会话（标
/// 发起设备名）、看一场的条目；只读。
void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_ai_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<AdminApi> build() async {
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    return AdminApi(
      AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: host,
        startedAt: DateTime.now(),
      ),
    );
  }

  Future<({int status, Map<String, Object?> json})> get(
    AdminApi api,
    String path,
  ) async {
    final shelf.Response r = await api.handle(
      shelf.Request('GET', Uri.parse('http://localhost/api/admin/$path')),
    );
    return (
      status: r.statusCode,
      json: Map<String, Object?>.from(
        jsonDecode(await r.readAsString())! as Map,
      ),
    );
  }

  test('列出会话并标发起设备名；读一场只给展示字段；不存在 404', () async {
    await db.upsertPairedPeer(
      FushiPairedPeersCompanion.insert(
        peerId: 'phone-1',
        deviceName: const Value<String?>('Pixel'),
        token: 'secret-token',
        pairedAtMs: 1,
      ),
    );
    await db.saveAiAgentSessionSnapshot(
      id: 'rm1',
      title: '字幕改中文',
      scene: 'remote',
      payloadJson: jsonEncode(<String, Object?>{
        'v': 1,
        'id': 'rm1',
        'entries': <Object?>[
          <String, Object?>{
            'id': 'e1',
            'kind': 'user',
            'createdAt': 10,
            'text': '字幕改中文',
            'status': 'done',
          },
          <String, Object?>{
            'id': 'e2',
            'kind': 'toolCall',
            'createdAt': 11,
            'toolName': 'server.settings.set',
            'arguments': <String, Object?>{'apiKey': 'leak-me'},
            'status': 'done',
          },
        ],
        'history': <Object?>[],
      }),
      totalTokens: 42,
      createdAt: 10,
      updatedAt: 20,
      profileUid: '',
      originPeerId: 'phone-1',
    );
    await db.saveAiAgentSessionSnapshot(
      id: 'rm2',
      title: '老会话',
      scene: 'remote',
      payloadJson: '{"entries":[]}',
      totalTokens: 0,
      createdAt: 1,
      updatedAt: 5,
      profileUid: '',
    );
    final AdminApi api = await build();

    final ({int status, Map<String, Object?> json}) list = await get(
      api,
      'ai/sessions',
    );
    expect(list.status, 200);
    final List<Map<String, Object?>> sessions = <Map<String, Object?>>[
      for (final Object? s in list.json['sessions']! as List)
        Map<String, Object?>.from(s! as Map),
    ];
    expect(sessions.map((Map<String, Object?> s) => s['id']), <String>[
      'rm1',
      'rm2',
    ]);
    expect(sessions.first['originDeviceName'], 'Pixel');
    expect(sessions.first['tokens'], 42);
    expect(sessions.last['originPeerId'], '');
    expect(sessions.last['originDeviceName'], isNull);

    final ({int status, Map<String, Object?> json}) one = await get(
      api,
      'ai/sessions/rm1',
    );
    expect(one.status, 200);
    expect(one.json['title'], '字幕改中文');
    final List<Object?> entries = one.json['entries']! as List;
    expect(entries, hasLength(2));
    expect((entries[1]! as Map)['toolName'], 'server.settings.set');
    expect(
      jsonEncode(one.json),
      isNot(contains('leak-me')),
      reason: '工具参数原文不出管理页',
    );
    expect(jsonEncode(list.json), isNot(contains('secret-token')));

    expect((await get(api, 'ai/sessions/nope')).status, 404);
  });

  test('管理页有「AI 助手」页并接上 ai/sessions', () {
    expect(adminWebUiHtml, contains('data-s="ai"'));
    expect(adminWebUiHtml, contains('<section id="s-ai">'));
    expect(adminWebUiHtml, contains("api('ai/sessions')"));
    expect(adminWebUiHtml, contains('ai:loadAi'));
  });
}
