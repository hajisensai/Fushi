/// `export` 端到端：临时数据目录 + 真实 `FushiDatabase` 登记一本词典与一个本地音频库，
/// 经命令模块导出，再用同一个引擎服务把包导回另一个库，证明包是可用的同步资产包；
/// 另钉用法错误 64、找不到资产 66、输出已存在 1。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/sync/local_audio_library_store.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/export_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File configFile;
  late ServerPaths paths;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_export_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final String dataDir = p.join(tmp.path, 'data');
    await ServerConfig.defaults(dataDir: dataDir).save(configFile);
    paths = ServerPaths(dataDir);
    await paths.ensureLayout();
    final FushiDatabase db = FushiDatabase(paths.support.path);
    await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(name: 'JMdict', formatKey: 'yomichan', order: 0));
    final Directory res = Directory(p.join(paths.dictionaryResources.path, 'JMdict'));
    await res.create(recursive: true);
    await File(p.join(res.path, 'styles.css')).writeAsString('.x{}');
    // 本地音频库：登记格式与 app LocalAudioManager 同形（偏好 local_audio_dbs）。
    final File audioDb = File(p.join(paths.support.path, 'local_audio_1.db'));
    await audioDb.writeAsBytes(<int>[...utf8.encode('SQLite format 3'), 0, ...List<int>.filled(84, 0)]);
    final ServerPrefs prefs = ServerPrefs(db);
    await prefs.setPref(
      LocalAudioLibraryStore.entriesPrefKey,
      jsonEncode(<Object?>[LocalAudioDbEntry(path: audioDb.path, displayName: 'NHK', enabled: true).toJson()]),
    );
    await db.close();
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> export(List<String> args) {
    final ExportModule module = ExportModule(out: out, err: err);
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'export',
      parser.parse(<String>['export', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  test('dictionary：导出的包能被引擎导回另一个库', () async {
    final String target = p.join(tmp.path, 'out', 'JMdict.fushidict');
    expect(await export(<String>['dictionary', 'JMdict', '-o', target, '--json']), 0, reason: err.toString());
    final Map<String, Object?> r = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(r['kind'], 'dictionary');
    expect(r['file'], target);
    expect(r['bytes'], greaterThan(0));

    final Directory other = await Directory(p.join(tmp.path, 'other')).create();
    final FushiDatabase otherDb = FushiDatabase(other.path);
    final Directory otherRoot = Directory(p.join(other.path, 'dicts'));
    await SyncAssetPackageService(
      db: otherDb,
    ).importDictionaryPackage(packageFile: File(target), dictionaryResourceRoot: otherRoot);
    expect((await otherDb.getAllDictionaryMetadata()).map((DictionaryMetaRow m) => m.name), contains('JMdict'));
    expect(await File(p.join(otherRoot.path, 'JMdict', 'styles.css')).readAsString(), '.x{}');
    await otherDb.close();
  });

  test('local-audio：包内带 .db 与 manifest', () async {
    final String target = p.join(tmp.path, 'NHK.fushiaudiolib');
    expect(await export(<String>['local-audio', 'NHK', '-o', target]), 0, reason: err.toString());
    final Archive zip = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    expect(
      zip.files.map((ArchiveFile f) => f.name),
      containsAll(<String>['manifest.json', 'resources/local_audio_1.db']),
    );
    expect(out.toString(), contains('NHK'));
  });

  test('找不到资产 = 66', () async {
    expect(await export(<String>['dictionary', 'nope', '-o', p.join(tmp.path, 'a')]), 66);
    expect(await export(<String>['audiobook', 'nope', '-o', p.join(tmp.path, 'b')]), 66);
    expect(await export(<String>['local-audio', 'nope', '-o', p.join(tmp.path, 'c')]), 66);
    expect(err.toString(), contains('nope'));
  });

  test('输出已存在 = 1，--force 覆盖', () async {
    final File target = File(p.join(tmp.path, 'exists.fushidict'));
    await target.writeAsString('old');
    expect(await export(<String>['dictionary', 'JMdict', '-o', target.path]), 1);
    expect(await target.readAsString(), 'old');
    // --force 但源不存在：旧文件不能被先删掉。
    expect(await export(<String>['dictionary', 'nope', '-o', target.path, '--force']), 66);
    expect(await target.readAsString(), 'old');
    expect(await export(<String>['dictionary', 'JMdict', '-o', target.path, '--force']), 0, reason: err.toString());
    expect(await target.length(), greaterThan(3));
  });

  test('用法错误 = 64', () async {
    expect(await export(<String>['dictionary', 'JMdict']), 64);
    expect(await export(<String>['books', 'x', '-o', 'y']), 64);
    expect(await export(<String>['dictionary', '-o', 'y']), 64);
  });
}
