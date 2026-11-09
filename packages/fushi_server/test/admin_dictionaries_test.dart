import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
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

/// admin API 的词典端点（`/api/admin/dictionaries*`）：清单（目录字段 + 占用 + 默认开关 +
/// 资源目录在不在）、改服务端默认开关（`hiddenLanguagesJson` 里增删 `ja`）、删除、
/// 重载。这里不起原生引擎（host 未 start），只验 DB / 目录 / 响应形状。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_dicts_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({AdminApi api, ServerPaths paths})> build() async {
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
    return (api: AdminApi(ctx), paths: paths);
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

  Future<void> addDictionary(
    String name, {
    int order = 0,
    String type = 'term',
    String hidden = '[]',
    String metadataJson = '{}',
    String? displayName,
    String? languageOverride,
  }) => db.upsertDictionaryMeta(
    DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: 'yomichan',
      order: order,
      type: Value<String>(type),
      hiddenLanguagesJson: Value<String>(hidden),
      metadataJson: Value<String>(metadataJson),
      displayName: Value<String?>(displayName),
      languageOverride: Value<String?>(languageOverride),
    ),
  );

  Future<DictionaryMetaRow> rowOf(String name) async =>
      (await db.getAllDictionaryMetadata()).firstWhere(
        (DictionaryMetaRow r) => r.name == name,
      );

  test('GET：按服务端顺序列出，带目录字段 / 占用 / 默认开关 / 目录在不在', () async {
    final (:AdminApi api, :ServerPaths paths) = await build();
    await addDictionary(
      'JMdict',
      order: 1,
      metadataJson: '{"revision":"jmdict4","sourceLanguage":"ja"}',
      displayName: '辞書',
    );
    await addDictionary('Freq', type: 'frequency', hidden: '["ja"]');
    final Directory dir = Directory(
      p.join(paths.dictionaryResources.path, 'JMdict'),
    )..createSync(recursive: true);
    File(
      p.join(dir.path, 'blobs.bin'),
    ).writeAsBytesSync(List<int>.filled(10, 1));
    Directory(p.join(dir.path, 'media')).createSync();
    File(p.join(dir.path, 'media', 'a.svg')).writeAsBytesSync(<int>[1, 2, 3]);

    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'GET',
      'dictionaries',
    );
    expect(status, 200, reason: '$json');
    expect(json['engineAvailable'], isFalse);
    final List<Map<String, dynamic>> list = <Map<String, dynamic>>[
      for (final Object? e in json['dictionaries'] as List)
        Map<String, dynamic>.from(e! as Map),
    ];
    expect(list.map((Map<String, dynamic> d) => d['name']), <String>[
      'Freq',
      'JMdict',
    ]);
    final Map<String, dynamic> freq = list[0];
    expect(freq['type'], 'frequency');
    expect(freq['defaultEnabled'], isFalse);
    expect(freq['present'], isFalse);
    expect(freq['sizeBytes'], 0);
    expect(freq.containsKey('revision'), isFalse);
    final Map<String, dynamic> jm = list[1];
    expect(jm['type'], 'term');
    expect(jm['formatKey'], 'yomichan');
    expect(jm['revision'], 'jmdict4');
    expect(jm['sourceLanguage'], 'ja');
    expect(jm['displayName'], '辞書');
    expect(jm['defaultEnabled'], isTrue);
    expect(jm['present'], isTrue);
    expect(jm['sizeBytes'], 13);
    expect(jm['order'], 1);
  });

  test(
    'PUT defaultEnabled：写 hiddenLanguagesJson ["ja"] / []，GET 跟着变',
    () async {
      final (:AdminApi api, paths: _) = await build();
      await addDictionary('JMdict');

      final ({int status, Map<String, dynamic> json}) off = await call(
        api,
        'PUT',
        'dictionaries/JMdict',
        <String, Object?>{'defaultEnabled': false},
      );
      expect(off.status, 200, reason: '${off.json}');
      expect(off.json['defaultEnabled'], isFalse);
      expect((await rowOf('JMdict')).hiddenLanguagesJson, '["ja"]');
      final ({int status, Map<String, dynamic> json}) listed = await call(
        api,
        'GET',
        'dictionaries',
      );
      expect(
        ((listed.json['dictionaries'] as List).single as Map)['defaultEnabled'],
        isFalse,
      );

      final ({int status, Map<String, dynamic> json}) on = await call(
        api,
        'PUT',
        'dictionaries/JMdict',
        <String, Object?>{'defaultEnabled': true},
      );
      expect(on.status, 200);
      expect((await rowOf('JMdict')).hiddenLanguagesJson, '[]');
    },
  );

  test('PUT defaultEnabled：只增删 ja，hiddenLanguagesJson 里别的语言原样保留', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('Oxford', hidden: '["en","zh"]');

    expect(
      (await call(api, 'PUT', 'dictionaries/Oxford', <String, Object?>{
        'defaultEnabled': false,
      })).status,
      200,
    );
    expect((await rowOf('Oxford')).hiddenLanguagesJson, '["en","zh","ja"]');
    // 重复关闭不叠第二个 ja。
    await call(api, 'PUT', 'dictionaries/Oxford', <String, Object?>{
      'defaultEnabled': false,
    });
    expect((await rowOf('Oxford')).hiddenLanguagesJson, '["en","zh","ja"]');

    expect(
      (await call(api, 'PUT', 'dictionaries/Oxford', <String, Object?>{
        'defaultEnabled': true,
      })).status,
      200,
    );
    expect((await rowOf('Oxford')).hiddenLanguagesJson, '["en","zh"]');
  });

  test('PUT defaultEnabled 并发：都在库锁里串行，最后一次写入生效', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('JMdict', hidden: '["en"]');
    await Future.wait(<Future<Object?>>[
      call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
        'defaultEnabled': false,
      }),
      call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
        'defaultEnabled': true,
      }),
      call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
        'defaultEnabled': false,
      }),
    ]);
    expect((await rowOf('JMdict')).hiddenLanguagesJson, '["en","ja"]');
  });

  test('PUT：名字要 URL 编码（含空格 / 非 ASCII）；没有的词典 404；非 bool 400', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('大辞林 第四版');
    final ({int status, Map<String, dynamic> json}) ok = await call(
      api,
      'PUT',
      'dictionaries/${Uri.encodeComponent('大辞林 第四版')}',
      <String, Object?>{'defaultEnabled': false},
    );
    expect(ok.status, 200, reason: '${ok.json}');
    expect((await rowOf('大辞林 第四版')).hiddenLanguagesJson, '["ja"]');

    expect(
      (await call(api, 'PUT', 'dictionaries/Nope', <String, Object?>{
        'defaultEnabled': true,
      })).status,
      404,
    );
    expect(
      (await call(
        api,
        'PUT',
        'dictionaries/${Uri.encodeComponent('大辞林 第四版')}',
        <String, Object?>{'defaultEnabled': 'yes'},
      )).status,
      400,
    );
  });

  test('DELETE：删 DB 元数据与资源目录；没有的词典 404', () async {
    final (:AdminApi api, :ServerPaths paths) = await build();
    await addDictionary('JMdict');
    await addDictionary('Keep', order: 1);
    final Directory dir = Directory(
      p.join(paths.dictionaryResources.path, 'JMdict'),
    )..createSync(recursive: true);
    File(p.join(dir.path, 'blobs.bin')).writeAsStringSync('x');

    final ({int status, Map<String, dynamic> json}) r = await call(
      api,
      'DELETE',
      'dictionaries/JMdict',
    );
    expect(r.status, 200, reason: '${r.json}');
    expect(
      (await db.getAllDictionaryMetadata()).map(
        (DictionaryMetaRow r) => r.name,
      ),
      <String>['Keep'],
    );
    expect(dir.existsSync(), isFalse);
    expect((await call(api, 'DELETE', 'dictionaries/JMdict')).status, 404);
  });

  test('POST reload：引擎没起时 503（不假装成功）', () async {
    final (:AdminApi api, paths: _) = await build();
    final ({int status, Map<String, dynamic> json}) r = await call(
      api,
      'POST',
      'dictionaries/reload',
    );
    expect(r.status, 503);
    expect(r.json['error'], isA<String>());
  });
}
