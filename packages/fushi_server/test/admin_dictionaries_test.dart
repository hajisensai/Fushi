import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/commands/dict_commands.dart'
    show DictArchiveImporter;
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_language.dart';
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

  /// [start]：真起 host（互联端口 0、无 TLS），引擎用 [dictionaryHost]——验「导入后
  /// 引擎即看到」与「引擎不可用 503」。默认不起，`ctx.host.dictionaries` 为 null。
  Future<({AdminApi api, ServerPaths paths})> build({
    int? uploadQuotaBytes,
    DictArchiveImporter? importer,
    ServerDictionaryHost? dictionaryHost,
    bool start = false,
  }) async {
    ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok', uploadQuotaBytes: uploadQuotaBytes);
    if (start) {
      config = config.copyWith(port: 0, bind: '127.0.0.1', tls: false);
    }
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
      dictionaryHost: dictionaryHost,
    );
    if (start) {
      await paths.ensureLayout();
      await host.start();
      addTearDown(host.stop);
    }
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
    return (api: AdminApi(ctx, dictionaryImporter: importer), paths: paths);
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

  test(
    'GET：带原始 languageOverride / packageLanguage，sourceLanguage 是生效值',
    () async {
      final (:AdminApi api, paths: _) = await build();
      await addDictionary(
        'CEDICT',
        metadataJson: '{"sourceLanguage":"ja"}',
        languageOverride: 'zh-Hans',
      );
      await addDictionary('Plain', order: 1);
      final ({int status, Map<String, dynamic> json}) r = await call(
        api,
        'GET',
        'dictionaries',
      );
      final List<Map<String, dynamic>> list = <Map<String, dynamic>>[
        for (final Object? e in r.json['dictionaries'] as List)
          Map<String, dynamic>.from(e! as Map),
      ];
      expect(list[0]['sourceLanguage'], 'zh-Hans');
      expect(list[0]['languageOverride'], 'zh-Hans');
      expect(list[0]['packageLanguage'], 'ja');
      expect(list[1].containsKey('sourceLanguage'), isFalse);
      expect(list[1]['languageOverride'], isNull);
      expect(list[1]['packageLanguage'], isNull);
    },
  );

  test('PUT languageOverride：设置（trim）→ 返回更新后的条目；空串 / null 清掉', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('JMdict', metadataJson: '{"sourceLanguage":"ja"}');

    final ({int status, Map<String, dynamic> json}) set = await call(
      api,
      'PUT',
      'dictionaries/JMdict',
      <String, Object?>{'languageOverride': '  zh-Hant '},
    );
    expect(set.status, 200, reason: '${set.json}');
    expect(set.json['name'], 'JMdict');
    expect(set.json['languageOverride'], 'zh-Hant');
    expect(set.json['sourceLanguage'], 'zh-Hant');
    expect(set.json['packageLanguage'], 'ja');
    expect(set.json['defaultEnabled'], isTrue);
    expect(set.json.containsKey('sizeBytes'), isTrue);
    expect((await rowOf('JMdict')).languageOverride, 'zh-Hant');
    // 只改语言，不碰默认开关。
    expect((await rowOf('JMdict')).hiddenLanguagesJson, '[]');

    final ({int status, Map<String, dynamic> json}) cleared = await call(
      api,
      'PUT',
      'dictionaries/JMdict',
      <String, Object?>{'languageOverride': '   '},
    );
    expect(cleared.status, 200, reason: '${cleared.json}');
    expect((await rowOf('JMdict')).languageOverride, isNull);
    expect(cleared.json['languageOverride'], isNull);
    expect(cleared.json['sourceLanguage'], 'ja');

    await call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
      'languageOverride': 'ko',
    });
    expect((await rowOf('JMdict')).languageOverride, 'ko');
    final ({int status, Map<String, dynamic> json}) nulled = await call(
      api,
      'PUT',
      'dictionaries/JMdict',
      <String, Object?>{'languageOverride': null},
    );
    expect(nulled.status, 200);
    expect((await rowOf('JMdict')).languageOverride, isNull);
  });

  test('PUT displayName：设置 / 清掉；与 defaultEnabled 可同一次请求', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('JMdict', languageOverride: 'ja');

    final ({int status, Map<String, dynamic> json}) set = await call(
      api,
      'PUT',
      'dictionaries/JMdict',
      <String, Object?>{'displayName': ' 辞書 ', 'defaultEnabled': false},
    );
    expect(set.status, 200, reason: '${set.json}');
    expect(set.json['displayName'], '辞書');
    expect(set.json['defaultEnabled'], isFalse);
    final DictionaryMetaRow row = await rowOf('JMdict');
    expect(row.displayName, '辞書');
    expect(row.hiddenLanguagesJson, '["ja"]');
    // 没带的字段不动。
    expect(row.languageOverride, 'ja');

    final ({int status, Map<String, dynamic> json}) cleared = await call(
      api,
      'PUT',
      'dictionaries/JMdict',
      <String, Object?>{'displayName': ''},
    );
    expect(cleared.status, 200);
    expect(cleared.json.containsKey('displayName'), isFalse);
    expect((await rowOf('JMdict')).displayName, isNull);
    expect((await rowOf('JMdict')).hiddenLanguagesJson, '["ja"]');
  });

  test('PUT 校验：坏语言标签 / 非字符串 / 空请求体 400，不落库；没有的词典 404', () async {
    final (:AdminApi api, paths: _) = await build();
    await addDictionary('JMdict', languageOverride: 'ja');

    for (final Object? bad in <Object?>[
      'j',
      'ja_JP',
      'zh Hans',
      'x' * 36,
      '日本語',
      42,
    ]) {
      final ({int status, Map<String, dynamic> json}) r = await call(
        api,
        'PUT',
        'dictionaries/JMdict',
        <String, Object?>{'languageOverride': bad},
      );
      expect(r.status, 400, reason: '$bad → ${r.json}');
      expect(r.json['error'], isA<String>());
    }
    expect(
      (await call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
        'displayName': 7,
      })).status,
      400,
    );
    expect(
      (await call(api, 'PUT', 'dictionaries/JMdict', <String, Object?>{
        'displayName': 'x' * 201,
      })).status,
      400,
    );
    expect(
      (await call(
        api,
        'PUT',
        'dictionaries/JMdict',
        <String, Object?>{},
      )).status,
      400,
    );
    expect((await rowOf('JMdict')).languageOverride, 'ja');

    expect(
      (await call(api, 'PUT', 'dictionaries/Nope', <String, Object?>{
        'languageOverride': 'ja',
      })).status,
      404,
    );
    expect(
      (await call(api, 'PUT', 'dictionaries/Nope', <String, Object?>{
        'displayName': 'x',
      })).status,
      404,
    );
  });

  // ── 导入（POST /api/admin/dictionaries/import） ─────────────────────────

  Future<({int status, Map<String, dynamic> json})> upload(
    AdminApi api,
    List<int> bytes, {
    String? filename,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final String query = filename == null
        ? ''
        : '?filename=${Uri.encodeQueryComponent(filename)}';
    final shelf.Response r = await api.handle(
      shelf.Request(
        'POST',
        Uri.parse('http://localhost/api/admin/dictionaries/import$query'),
        body: bytes,
        headers: <String, String>{
          'content-type': 'application/octet-stream',
          'content-length': '${bytes.length}',
          ...headers,
        },
      ),
    );
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(
        jsonDecode(await r.readAsString())! as Map,
      ),
    );
  }

  /// 暂存目录（`<data>/tmp/dict_upload_*`、`fushi_dict_import_*`）一个都不剩。
  void expectStagingClean(ServerPaths paths) {
    final List<String> left = paths.temp.existsSync()
        ? <String>[
            for (final FileSystemEntity e in paths.temp.listSync())
              p.basename(e.path),
          ]
        : <String>[];
    expect(left, isEmpty, reason: 'staging left behind: $left');
  }

  List<int> zipOf(Map<String, Object> jsonFiles) {
    final Archive archive = Archive();
    jsonFiles.forEach((String name, Object json) {
      final List<int> bytes = json is List<int>
          ? json
          : utf8.encode(jsonEncode(json));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    return ZipEncoder().encode(archive)!;
  }

  List<int> yomitanZip(String title) => zipOf(<String, Object>{
    'index.json': <String, Object>{
      'title': title,
      'revision': 'r1',
      'sourceLanguage': 'ja',
      'format': 3,
    },
    'term_bank_1.json': <Object>[
      <Object>[
        '食べる',
        'たべる',
        'v1',
        'v1',
        100,
        <String>['to eat'],
        1,
        '',
      ],
    ],
  });

  /// 照原生导入器的形状写输出：`<out>/<title>/index.json` + 一个数据文件。
  DictArchiveImporter fakeImporter({
    String title = 'FakeDict',
    List<String>? seenPaths,
  }) => (String archive, String outDir) async {
    seenPaths?.add(archive);
    final Directory dir = Directory(p.join(outDir, title))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'index.json')).writeAsStringSync(
      jsonEncode(<String, Object>{'title': title, 'revision': 'r2'}),
    );
    File(p.join(dir.path, 'blobs.bin')).writeAsBytesSync(<int>[1, 2, 3]);
    return FushiImportResult(
      success: true,
      title: title,
      termCount: 7,
      metaCount: 0,
      freqCount: 0,
      pitchCount: 0,
      mediaCount: 0,
      kanjiCount: 0,
      detectedType: 'term',
      error: '',
    );
  };

  /// 用一个独立 DB 导出 app 形状的 `.fushidict`（与互联推送收到的包同形）。
  Future<List<int>> fushidictPackage(String name) async {
    // 导出端是另一台设备的库：同进程第二个内存库是刻意的。
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final FushiDatabase src = FushiDatabase.forTesting(NativeDatabase.memory());
    try {
      final Directory root = Directory(p.join(tmp.path, 'export_src'))
        ..createSync(recursive: true);
      Directory(p.join(root.path, name)).createSync();
      File(
        p.join(root.path, name, 'blobs.bin'),
      ).writeAsBytesSync(List<int>.filled(16, 7));
      await src.upsertDictionaryMeta(
        DictionaryMetadataCompanion.insert(
          name: name,
          formatKey: 'yomichan',
          order: 0,
          type: const Value<String>('term'),
          metadataJson: const Value<String>('{"sourceLanguage":"ko"}'),
        ),
      );
      final File out = File(p.join(tmp.path, 'export_out', '$name.fushidict'));
      await SyncAssetPackageService(db: src).exportDictionaryPackage(
        dictionaryName: name,
        dictionaryResourceRoot: root,
        outputFile: out,
      );
      return out.readAsBytesSync();
    } finally {
      await src.close();
    }
  }

  test('导入 .fushidict：走互联同一条路径，落 DB + 资源目录，计入配额，暂存清掉', () async {
    final (:AdminApi api, :ServerPaths paths) = await build();
    final List<int> pkg = await fushidictPackage('PkgDict');

    final ({int status, Map<String, dynamic> json}) r = await upload(
      api,
      pkg,
      filename: 'PkgDict.fushidict',
    );
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['name'], 'PkgDict');
    expect(r.json['format'], 'fushidict');
    expect(r.json['type'], 'term');
    expect(r.json['replaced'], isFalse);
    expect(r.json['language'], 'ko');
    expect(r.json['termCount'], isNull);
    expect(r.json['kanjiCount'], isNull);
    expect((r.json['dictionary'] as Map)['present'], isTrue);
    expect(
      File(
        p.join(paths.dictionaryResources.path, 'PkgDict', 'blobs.bin'),
      ).lengthSync(),
      16,
    );
    expect(await api.uploads.used(), pkg.length);
    expectStagingClean(paths);

    // 同名再导 = 更新：本机改过的显示名不被包覆盖。
    await call(api, 'PUT', 'dictionaries/PkgDict', <String, Object?>{
      'displayName': '韩语词典',
    });
    final ({int status, Map<String, dynamic> json}) again = await upload(
      api,
      pkg,
      headers: <String, String>{
        'x-filename': Uri.encodeComponent('PkgDict.fushidict'),
      },
    );
    expect(again.status, 200, reason: '${again.json}');
    expect(again.json['replaced'], isTrue);
    expect((await rowOf('PkgDict')).displayName, '韩语词典');
    expectStagingClean(paths);
  });

  test('导入原始包（注入导入器）：dict add 同一函数，带语言 / 计数；改名 zip 以 .zip 交给导入器', () async {
    final List<String> seen = <String>[];
    final (:AdminApi api, :ServerPaths paths) = await build(
      importer: fakeImporter(seenPaths: seen),
    );
    await addDictionary('Existing', order: 4);

    final ({int status, Map<String, dynamic> json}) r = await upload(
      api,
      yomitanZip('FakeDict'),
      filename: 'my dict.zip',
    );
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['name'], 'FakeDict');
    expect(r.json['format'], 'archive');
    expect(r.json['termCount'], 7);
    expect(r.json['kanjiCount'], 0);
    expect(r.json['replaced'], isFalse);
    // sourceLanguage 原生写回的 index.json 里没有，从原包 index.json 补（同 dict add）。
    expect(r.json['language'], 'ja');
    final DictionaryMetaRow row = await rowOf('FakeDict');
    expect(row.order, 5);
    expect(jsonDecode(row.metadataJson), containsPair('revision', 'r2'));
    expect(
      File(
        p.join(paths.dictionaryResources.path, 'FakeDict', 'blobs.bin'),
      ).existsSync(),
      isTrue,
    );
    expect(p.basename(seen.single), 'my dict.zip');
    expectStagingClean(paths);

    // 内容是 zip、名字却是 .mdx：交给原生导入器时必须是 .zip（它按扩展名分派）。
    final ({int status, Map<String, dynamic> json}) renamed = await upload(
      api,
      yomitanZip('FakeDict'),
      filename: 'FakeDict.mdx',
    );
    expect(renamed.status, 200, reason: '${renamed.json}');
    expect(renamed.json['replaced'], isTrue);
    expect(p.basename(seen.last), 'FakeDict.zip');
    expectStagingClean(paths);
  });

  test('导入器报错 → 422 带原因，不落库，暂存清掉，不计配额', () async {
    final (:AdminApi api, :ServerPaths paths) = await build(
      importer: (String a, String o) async => const FushiImportResult(
        success: false,
        title: '',
        termCount: 0,
        metaCount: 0,
        freqCount: 0,
        pitchCount: 0,
        mediaCount: 0,
        kanjiCount: 0,
        detectedType: '',
        error: 'unsupported dictionary format',
      ),
    );
    final ({int status, Map<String, dynamic> json}) r = await upload(
      api,
      yomitanZip('X'),
      filename: 'x.zip',
    );
    expect(r.status, 422, reason: '${r.json}');
    expect(r.json['error'], contains('unsupported dictionary format'));
    expect(await db.getAllDictionaryMetadata(), isEmpty);
    expect(await api.uploads.used(), 0);
    expectStagingClean(paths);
  });

  test(
    '拒收：扩展名 415；缺文件名 / 空文件 / 不是 zip / zip 里没词典 / 假 .fushidict 400',
    () async {
      final (:AdminApi api, :ServerPaths paths) = await build(
        importer: fakeImporter(),
      );
      final List<int> notZip = utf8.encode('definitely not a zip archive');
      final List<({String? name, List<int> bytes, int status})> cases =
          <({String? name, List<int> bytes, int status})>[
            (name: 'notes.txt', bytes: notZip, status: 415),
            (name: null, bytes: notZip, status: 400),
            (name: 'empty.zip', bytes: <int>[], status: 400),
            (name: 'fake.zip', bytes: notZip, status: 400),
            (name: 'fake.fushidict', bytes: notZip, status: 400),
            (
              name: 'readme.zip',
              bytes: zipOf(<String, Object>{
                'readme.json': <String, Object>{'a': 1},
              }),
              status: 400,
            ),
            (name: 'yomitan.fushidict', bytes: yomitanZip('Y'), status: 400),
            (
              name: 'other.fushidict',
              bytes: zipOf(<String, Object>{
                'manifest.json': <String, Object>{'kind': 'book'},
              }),
              status: 400,
            ),
            (
              name: 'evil.fushidict',
              bytes: zipOf(<String, Object>{
                'manifest.json': <String, Object>{
                  'kind': 'dictionary',
                  'dictionary': <String, Object>{'name': '../escape'},
                },
              }),
              status: 400,
            ),
            for (final String bad in <String>['../x', 'a/b', r'a', '..', '.'])
              (
                name: 'bad.fushidict',
                bytes: zipOf(<String, Object>{
                  'manifest.json': <String, Object>{
                    'kind': 'dictionary',
                    'dictionary': <String, Object>{'name': bad},
                  },
                }),
                status: 400,
              ),
          ];
      for (final c in cases) {
        final ({int status, Map<String, dynamic> json}) r = await upload(
          api,
          c.bytes,
          filename: c.name,
        );
        expect(r.status, c.status, reason: '${c.name}: ${r.json}');
        expect(r.json['error'], isA<String>(), reason: '${c.name}');
        expectStagingClean(paths);
      }
      expect(await db.getAllDictionaryMetadata(), isEmpty);
      expect(await api.uploads.used(), 0);
    },
  );

  test('.fushidict 词典名含 `..` 但不是路径段（Dict..v2）照收', () async {
    final (:AdminApi api, :ServerPaths paths) = await build();
    final ({int status, Map<String, dynamic> json}) r = await upload(
      api,
      await fushidictPackage('Dict..v2'),
      filename: 'Dict..v2.fushidict',
    );
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['name'], 'Dict..v2');
    expectStagingClean(paths);
  });

  test('超上传配额 → 413（按实际字节判），暂存清掉、账本不动', () async {
    final (:AdminApi api, :ServerPaths paths) = await build(
      uploadQuotaBytes: 64,
      importer: fakeImporter(),
    );
    final List<int> big = yomitanZip('Big');
    expect(big.length, greaterThan(64));
    final ({int status, Map<String, dynamic> json}) declared = await upload(
      api,
      big,
      filename: 'big.zip',
    );
    expect(declared.status, 413, reason: '${declared.json}');
    expect(declared.json['error'], tr('上传配额已用完', 'upload quota exceeded'));
    expectStagingClean(paths);

    // 不报 Content-Length（分块传输）也拦得住：边收边判。
    final shelf.Response chunked = await api.handle(
      shelf.Request(
        'POST',
        Uri.parse(
          'http://localhost/api/admin/dictionaries/import?filename=b.zip',
        ),
        body: Stream<List<int>>.fromIterable(<List<int>>[
          big.sublist(0, 40),
          big.sublist(40),
        ]),
      ),
    );
    expect(chunked.statusCode, 413);
    expectStagingClean(paths);
    expect(await api.uploads.used(), 0);
    expect(await db.getAllDictionaryMetadata(), isEmpty);
  });

  test('引擎不可用（原生库加载失败）：原始包 503，.fushidict 照收', () async {
    final (:AdminApi api, :ServerPaths paths) = await build(
      start: true,
      dictionaryHost: ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: ServerPaths(
          p.join(tmp.path, 'data'),
        ).dictionaryResources,
        libraryPath: p.join(tmp.path, 'missing', 'libfushidicts_ffi.so'),
      ),
    );
    final ({int status, Map<String, dynamic> json}) raw = await upload(
      api,
      yomitanZip('NoEngine'),
      filename: 'n.zip',
    );
    expect(raw.status, 503, reason: '${raw.json}');
    expect(raw.json['error'], isA<String>());
    expectStagingClean(paths);

    final ({int status, Map<String, dynamic> json}) pkg = await upload(
      api,
      await fushidictPackage('StillOk'),
      filename: 'StillOk.fushidict',
    );
    expect(pkg.status, 200, reason: '${pkg.json}');
    expectStagingClean(paths);
  });

  // ── 真原生库：导入完引擎立即能查到（不用重启 / 手动重载） ──────────────
  final String? libPath = resolveFushiDictsLibraryPath();
  final bool haveLib = libPath != null && File(libPath).existsSync();
  test('真原生库：上传 Yomitan zip → 引擎即时装载、能查到；同名重导覆盖已映射的目录', () async {
    final (:AdminApi api, :ServerPaths paths) = await build(
      start: true,
      dictionaryHost: ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: ServerPaths(
          p.join(tmp.path, 'data'),
        ).dictionaryResources,
        libraryPath: libPath,
        transformsDir: Directory(
          p.join('..', '..', 'fushi', 'assets', 'transforms'),
        ),
      ),
    );
    addTearDown(() => FushiDicts.nativeLibraryPath = null);
    final ServerDictionaryHost engine = api.ctx.host.dictionaries!;
    expect(engine.available, isTrue, reason: engine.unavailableReason);
    expect(engine.loadedCount, 0);

    final ({int status, Map<String, dynamic> json}) r = await upload(
      api,
      yomitanZip('WebUiDict'),
      filename: 'WebUiDict.zip',
    );
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['name'], 'WebUiDict');
    expect(r.json['format'], 'archive');
    expect(r.json['termCount'], 1);
    expect(r.json['language'], 'ja');
    expect(r.json['replaced'], isFalse);
    expect(engine.loadedCount, 1);
    final DictionarySearchResult? hit = await ServerRemoteLookupService(
      engine,
    ).searchDictionary(term: '食べる', wildcards: false, maximumTerms: 5);
    expect(hit, isNotNull);
    expect(hit!.entries.first.dictionaryName, 'WebUiDict');
    expectStagingClean(paths);

    // 引擎此刻映射着 WebUiDict 的文件；同名重导要先释放映射再覆盖（BUG-1756）。
    final ({int status, Map<String, dynamic> json}) again = await upload(
      api,
      yomitanZip('WebUiDict'),
      filename: 'WebUiDict.zip',
    );
    expect(again.status, 200, reason: '${again.json}');
    expect(again.json['replaced'], isTrue);
    expect(engine.loadedCount, 1);
    expect(
      await ServerRemoteLookupService(
        engine,
      ).searchDictionary(term: '食べる', wildcards: false, maximumTerms: 5),
      isNotNull,
    );
    expectStagingClean(paths);
  }, skip: haveLib ? false : '没有 libfushidicts_ffi（设 $kFushiDictsLibEnv）');
}
