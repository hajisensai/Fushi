import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_dictionaries.dart';
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

/// WebUI「词典」页的 admin 端点：导入（zip 正文）/ 列出 / 排序 / 隐藏 / 删除 / 试查。
/// 引擎没加载（测试里不起 host）时导入删除照样落 DB 与资源目录，试查报 409。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPaths paths;
  late AdminDictionaries dicts;

  /// 假导入器：把 zip 正文当词典标题（`title|type`），写出一个最小词典目录。
  Future<FushiImportResult> fakeImporter(String archive, String outDir) async {
    final List<String> parts = File(archive).readAsStringSync().split('|');
    final String title = parts.first;
    if (title == 'BAD') {
      return const FushiImportResult(
        success: false,
        title: '',
        termCount: 0,
        metaCount: 0,
        freqCount: 0,
        pitchCount: 0,
        mediaCount: 0,
        kanjiCount: 0,
        detectedType: '',
        error: 'bad zip',
      );
    }
    final Directory d = Directory(p.join(outDir, title))
      ..createSync(recursive: true);
    File(p.join(d.path, 'blobs.bin')).writeAsStringSync('x');
    return FushiImportResult(
      success: true,
      title: title,
      termCount: 3,
      metaCount: 0,
      freqCount: 0,
      pitchCount: 0,
      mediaCount: 0,
      kanjiCount: 0,
      detectedType: parts.length > 1 ? parts[1] : 'term',
      error: '',
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_dict_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    dicts = AdminDictionaries(
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
      importer: fakeImporter,
    );
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<({int status, Map<String, Object?> json})> call(
    String method,
    String path, {
    Object? body,
  }) async {
    final shelf.Request req = shelf.Request(
      method,
      Uri.parse('http://localhost/api/admin/$path'),
      body: body is String ? body : (body == null ? null : jsonEncode(body)),
    );
    final shelf.Response? r = await dicts.route(
      method,
      '/${req.url.path}',
      req,
    );
    expect(r, isNotNull, reason: '$method $path not routed');
    return (
      status: r!.statusCode,
      json: jsonDecode(await r.readAsString()) as Map<String, Object?>,
    );
  }

  List<Map<String, Object?>> listOf(Map<String, Object?> json) =>
      (json['dictionaries']! as List<Object?>).cast<Map<String, Object?>>();

  test('导入 zip：落 DB 与资源目录，清单按导入顺序', () async {
    final r1 = await call('PUT', 'dictionaries', body: 'JMdict');
    expect(r1.status, 200);
    expect(r1.json['name'], 'JMdict');
    expect(r1.json['replaced'], isFalse);
    await call('PUT', 'dictionaries', body: 'JPDB|frequency');

    final s = await call('GET', 'dictionaries');
    expect(s.status, 200);
    final List<Map<String, Object?>> list = listOf(s.json);
    expect(list.map((Map<String, Object?> d) => d['name']), <String>[
      'JMdict',
      'JPDB',
    ]);
    expect(list[1]['type'], 'frequency');
    expect(list.every((Map<String, Object?> d) => d['present'] == true), true);
    expect(
      Directory(p.join(paths.dictionaryResources.path, 'JMdict')).existsSync(),
      isTrue,
    );
    final Map<String, Object?> engine =
        s.json['engine']! as Map<String, Object?>;
    expect(engine['available'], isFalse);
    expect(engine['transformsLoaded'], isFalse);

    final r3 = await call('PUT', 'dictionaries', body: 'JMdict');
    expect(r3.json['replaced'], isTrue, reason: '同名视为更新');
  });

  test('导入失败报 422，空正文报 400', () async {
    expect((await call('PUT', 'dictionaries', body: 'BAD')).status, 422);
    expect((await call('PUT', 'dictionaries', body: '')).status, 400);
    expect(await db.getAllDictionaryMetadata(), isEmpty);
  });

  test('排序：整份新顺序生效；缺项 / 重复报 400', () async {
    for (final String n in <String>['A', 'B', 'C']) {
      await call('PUT', 'dictionaries', body: n);
    }
    final r = await call(
      'PUT',
      'dictionaries/order',
      body: <String, Object?>{
        'names': <String>['C', 'A', 'B'],
      },
    );
    expect(r.status, 200);
    expect(listOf(r.json).map((Map<String, Object?> d) => d['name']), <String>[
      'C',
      'A',
      'B',
    ]);
    expect(
      (await call(
        'PUT',
        'dictionaries/order',
        body: <String, Object?>{
          'names': <String>['C', 'A'],
        },
      )).status,
      400,
    );
    expect(
      (await call(
        'PUT',
        'dictionaries/order',
        body: <String, Object?>{
          'names': <String>['C', 'A', 'A'],
        },
      )).status,
      400,
    );
  });

  test('隐藏只动 ja 标记，保留其它语言的隐藏', () async {
    await call('PUT', 'dictionaries', body: 'JMdict');
    final DictionaryMetaRow row = (await db.getAllDictionaryMetadata()).single;
    await db.upsertDictionaryMeta(
      row
          .toCompanion(false)
          .copyWith(hiddenLanguagesJson: const Value<String>('["zh"]')),
    );

    final r = await call(
      'PATCH',
      'dictionaries/JMdict',
      body: <String, Object?>{'hidden': true},
    );
    expect(r.status, 200);
    expect(listOf(r.json).single['hidden'], isTrue);
    expect(
      jsonDecode(
        (await db.getAllDictionaryMetadata()).single.hiddenLanguagesJson,
      ),
      unorderedEquals(<String>['zh', 'ja']),
    );

    await call(
      'PATCH',
      'dictionaries/JMdict',
      body: <String, Object?>{'hidden': false},
    );
    expect(
      jsonDecode(
        (await db.getAllDictionaryMetadata()).single.hiddenLanguagesJson,
      ),
      <String>['zh'],
    );
    expect(
      (await call(
        'PATCH',
        'dictionaries/Nope',
        body: <String, Object?>{'hidden': true},
      )).status,
      404,
    );
  });

  test('删除：DB 行与资源目录都没了；不存在的报 404', () async {
    await call('PUT', 'dictionaries', body: 'JMdict');
    final r = await call('DELETE', 'dictionaries/JMdict');
    expect(r.status, 200);
    expect(listOf(r.json), isEmpty);
    expect(
      Directory(p.join(paths.dictionaryResources.path, 'JMdict')).existsSync(),
      isFalse,
    );
    expect((await call('DELETE', 'dictionaries/JMdict')).status, 404);
  });

  test('CJK 词典名经百分号编码路径可删', () async {
    await call('PUT', 'dictionaries', body: '大辞林');
    final r = await call(
      'DELETE',
      'dictionaries/${Uri.encodeComponent('大辞林')}',
    );
    expect(r.status, 200);
    expect(listOf(r.json), isEmpty);
  });

  test('引擎不可用且用真导入器时，导入直接报 409', () async {
    final AdminDictionaries real = AdminDictionaries(dicts.ctx);
    final shelf.Request req = shelf.Request(
      'PUT',
      Uri.parse('http://localhost/api/admin/dictionaries'),
      body: 'zip',
    );
    final shelf.Response? r = await real.route(
      'PUT',
      '/api/admin/dictionaries',
      req,
    );
    expect(r!.statusCode, 409);
    expect(await r.readAsString(), contains('dictionary engine unavailable'));
  });

  test('引擎不可用时试查报 409', () async {
    expect((await call('GET', 'dictionaries/lookup?q=食べた')).status, 409);
  });

  test('AdminApi 把 /api/admin/dictionaries 交给词典端点', () async {
    final AdminApi api = AdminApi(dicts.ctx);
    final shelf.Response r = await api.handle(
      shelf.Request(
        'GET',
        Uri.parse('http://localhost/api/admin/dictionaries'),
      ),
    );
    expect(r.statusCode, 200);
    expect(
      (jsonDecode(await r.readAsString()) as Map<String, Object?>),
      containsPair('dictionaries', isEmpty),
    );
  });

  test('WebUI 有「词典」页', () {
    expect(adminWebUiHtml, contains('data-s="dictionaries"'));
    expect(adminWebUiHtml, contains('id="s-dictionaries"'));
    expect(adminWebUiHtml, contains('dictionaries:loadDictionaries'));
  });
}
