import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart' show FushiDicts;
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart' show GameStreamRejection, kGameStreamWireVersion;
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
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

import 'dictionary_host_test.dart' show importTestDictionary;

/// 整个 [HeadlessHost] 起来之后，互联的查词 / 历史 / 游戏串流路由与 capabilities
/// 是否如实：查词随词典引擎可用性接线（有 libfushidicts_ffi 时真查一次），游戏串流
/// 恒回带版本号的 `game_stream_off` 拒绝（client 据 code 显示「该主机未提供游戏串流」）。
void main() {
  final String? libPath = resolveFushiDictsLibraryPath();
  final bool haveLib = libPath != null && File(libPath).existsSync();

  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late HttpClient client;
  late String token;
  late ServerConfig hostConfig;
  late ServerPaths hostPaths;
  late ServerIdentity hostIdentity;

  setUp(() async {
    client = HttpClient();
    tmp = await Directory.systemTemp.createTemp('fushi_host_remote_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(port: 0, bind: '127.0.0.1', tls: false);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    token = identity.hostToken;
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    hostConfig = config;
    hostPaths = paths;
    hostIdentity = identity;
    if (haveLib) {
      // 导入在 host 起来之前做（模拟「已推送过词典的服务端重启」），先指定原生库。
      FushiDicts.nativeLibraryPath = libPath;
      await importTestDictionary(db, paths.dictionaryResources, tmp, title: 'HostTestDict');
    }
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
      dictionaryHost: ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: paths.dictionaryResources,
        // 没有原生库时显式指向不存在的路径：测「加载失败照常起服务」这条路。
        libraryPath: haveLib ? libPath : p.join(tmp.path, 'missing', 'libfushidicts_ffi.so'),
        transformsDir: Directory(p.join('..', '..', 'fushi', 'assets', 'transforms')),
      ),
    );
    await host.start();
  });

  tearDown(() async {
    client.close(force: true);
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<HttpClientResponse> send(String method, String path, [Object? body]) async {
    final HttpClientRequest req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${host.port}$path'));
    req.headers.set('Authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    return req.close();
  }

  Future<Map<String, dynamic>> json(HttpClientResponse res) async =>
      Map<String, dynamic>.from(jsonDecode(await utf8.decodeStream(res)) as Map);

  test('游戏串流：路由回 game_stream_off，capabilities 报 gameStream: false', () async {
    final HttpClientResponse res = await send('POST', '/api/game-stream/sessions', <String, String>{'clientId': 'c'});
    expect(res.statusCode, 404);
    final Map<String, dynamic> body = await json(res);
    expect(body['version'], kGameStreamWireVersion);
    expect(body['code'], GameStreamRejection.streamOff);
    final Map<String, dynamic> caps = await json(await send('GET', '/api/capabilities'));
    expect(caps['gameStream'], isFalse);
  });

  test(
    '没带 fushi-anki-sync 时制卡路由不接线，capabilities 报 mining: false',
    () async {
      // 测试环境没有 helper：落地会话为空，制卡如实不提供（而不是收下请求再报错）。
      expect(host.anki?.available, isFalse);
      final Map<String, dynamic> caps = await json(await send('GET', '/api/capabilities'));
      expect(caps['mining'], isFalse);
      final HttpClientResponse mine = await send('POST', '/api/mine', <String, Object>{
        'fields': <String, String>{},
        'sentence': '',
      });
      expect(mine.statusCode, 404);
      await mine.drain<void>();
    },
    skip: Platform.environment.containsKey('FUSHI_ANKI_SYNC') ? '设置了 FUSHI_ANKI_SYNC，helper 可能可用' : false,
  );

  test('查词：capabilities 与路由随词典引擎可用性一致', () async {
    final Map<String, dynamic> caps = await json(await send('GET', '/api/capabilities'));
    expect(caps['lookup'], <String, Object>{'dictionary': haveLib, 'history': haveLib});
    expect(host.dictionaries?.available, haveLib);
    final HttpClientResponse res = await send('POST', '/api/lookup/dictionary', <String, Object>{
      'term': '食べた',
      'maximumTerms': 10,
      'record': true,
    });
    if (!haveLib) {
      expect(res.statusCode, 404);
      await res.drain<void>();
      return;
    }
    expect(res.statusCode, 200);
    final Map<String, dynamic> body = await json(res);
    expect(body['type'], 'dictionaryResult');
    final Map<String, dynamic> result = Map<String, dynamic>.from(body['result'] as Map);
    expect(result['searchTerm'], '食べた');
    expect(jsonEncode(result['entries']), contains('食べる'));
    expect(body['popupJson'], contains('to eat'));
    // record: true → 查词历史落服务端 DB（写入是排队的，等一拍）。
    List<DictionaryHistoryRow> rows = const <DictionaryHistoryRow>[];
    for (int i = 0; i < 50 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rows = await db.getAllDictionaryHistory();
    }
    expect(rows, hasLength(1));
    expect(jsonDecode(rows.single.resultJson)['searchTerm'], '食べた');
  });

  group('admin 代调互联（/api/admin/host/*）', () {
    Future<shelf.Response> viaAdmin(String method, String rest, {Map<String, String>? headers}) {
      final AdminApi api = AdminApi(
        AdminContext(
          config: hostConfig,
          configFile: File(p.join(tmp.path, 'fushi_server.yaml')),
          paths: hostPaths,
          log: ServerLog(file: File(p.join(tmp.path, 'admin.log'))),
          db: db,
          identity: hostIdentity,
          host: host,
          startedAt: DateTime.now(),
        ),
      );
      return api.handle(shelf.Request(method, Uri.parse('http://localhost/api/admin/host/$rest'), headers: headers));
    }

    test('以 host 身份进到互联接口：调用方自带的凭据被剥掉，不影响鉴权', () async {
      final shelf.Response res = await viaAdmin(
        'GET',
        'capabilities',
        headers: <String, String>{'authorization': 'Basic ${base64Encode(utf8.encode('x:wrong'))}'},
      );
      expect(res.statusCode, 200);
      final Map<String, dynamic> caps = Map<String, dynamic>.from(jsonDecode(await res.readAsString()) as Map);
      expect(caps['gameStream'], isFalse);
    });

    test('配对路由（含 dot-segment 绕行写法）一律 403，不进互联', () async {
      for (final String rest in <String>['pair', 'pair/v2', 'pair/v2/confirm', 'x/../pair', 'x/%2E%2E/pair/v2']) {
        final shelf.Response res = await viaAdmin('POST', rest);
        expect(res.statusCode, 403, reason: rest);
        await res.readAsString();
      }
    });
  });
}
