import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/commands/backup_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'command_harness.dart';

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

Set<String> _zipNames(File zip) {
  final InputFileStream input = InputFileStream(zip.path);
  try {
    return ZipDecoder()
        .decodeBuffer(input)
        .files
        .map((ArchiveFile f) => f.name)
        .toSet();
  } finally {
    input.closeSync();
  }
}

/// 手造一个备份包（测还原的拒绝路径）。
File _craftZip(String path, Map<String, String> entries) {
  final Archive a = Archive();
  entries.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return File(path)..writeAsBytesSync(ZipEncoder().encode(a)!);
}

String _manifest({int schema = 1}) => jsonEncode(<String, Object?>{
  'format': kServerBackupFormat,
  'formatVersion': 1,
  'createdAt': DateTime.utc(2026).toIso8601String(),
  'schemaVersion': schema,
  'includesDocuments': true,
  'hasConfig': false,
});

void main() {
  group('backup create / restore（CLI）', () {
    late CommandHarness h;
    late BackupModule module;

    setUp(() async {
      h = await CommandHarness.create();
      module = BackupModule(out: h.out, err: h.err);
    });
    tearDown(() => h.dispose());

    String data(String rel) => p.join(h.dataDir, rel);

    Future<void> setPref(String value) async {
      final FushiDatabase db = h.openDb();
      await ServerPrefs(db).setRaw('backup_test_marker', value);
      await db.close();
    }

    Future<String?> getPref() async {
      final FushiDatabase db = h.openDb();
      final String? v = await ServerPrefs(db).getRaw('backup_test_marker');
      await db.close();
      return v;
    }

    test('往返：数据库、数据目录文件、配置原样回来，旧数据挪到旁边', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      // 第一次跑建好库与布局。
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      await out.delete();
      await setPref('before');
      _write(data('support/dictionaries/d.txt'), 'dict');
      _write(data('documents/fushi_books/b.txt'), 'book');
      _write(data('logs/x.log'), 'log');

      expect(
        await h.run(module, <String>[
          'backup',
          'create',
          '-o',
          out.path,
          '--json',
        ]),
        0,
        reason: h.err.toString(),
      );
      final Set<String> names = _zipNames(out);
      expect(names, contains('manifest.json'));
      expect(names, contains('config/fushi_server.yaml'));
      expect(names, contains('data/support/fushi.db'));
      expect(names, contains('data/support/dictionaries/d.txt'));
      expect(names, contains('data/documents/fushi_books/b.txt'));
      expect(names.where((String n) => n.startsWith('data/logs/')), isEmpty);
      expect(names, isNot(contains('data/fushi_server.lock')));
      expect(names.where((String n) => n.endsWith('-wal')), isEmpty);

      // 备份之后改动，再还原。
      await setPref('after');
      File(data('support/dictionaries/d.txt')).deleteSync();
      final String originalConfig = h.configFile.readAsStringSync();
      final ServerConfig cfg = await ServerConfig.load(h.configFile);
      await cfg.copyWith(deviceName: 'changed').save(h.configFile);

      expect(
        await h.run(module, <String>[
          'backup',
          'restore',
          out.path,
          '--yes',
          '--json',
        ]),
        0,
        reason: h.err.toString(),
      );
      expect(await getPref(), 'before');
      expect(
        File(data('support/dictionaries/d.txt')).readAsStringSync(),
        'dict',
      );
      expect(
        File(data('documents/fushi_books/b.txt')).readAsStringSync(),
        'book',
      );
      expect(h.configFile.readAsStringSync(), originalConfig);
      final Map<String, Object?> r = h.json();
      final Directory previous = Directory(r['previousData']! as String);
      expect(
        File(p.join(previous.path, 'logs', 'x.log')).existsSync(),
        isTrue,
        reason: '旧数据整体保留（含不进备份的日志）',
      );
      expect(
        File(r['previousConfig']! as String).readAsStringSync(),
        contains('changed'),
      );
      await previous.delete(recursive: true);
    });

    test('--no-documents 跳过 documents/', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      _write(data('documents/fushi_books/b.txt'), 'book');
      expect(
        await h.run(module, <String>[
          'backup',
          'create',
          '-o',
          out.path,
          '--no-documents',
          '--force',
        ]),
        0,
      );
      expect(
        _zipNames(out).where((String n) => n.startsWith('data/documents/')),
        isEmpty,
      );
      expect(readServerBackupManifest(out).includesDocuments, isFalse);
    });

    test('没加 --yes 不还原；输出不能放进数据目录', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      expect(await h.run(module, <String>['backup', 'restore', out.path]), 64);
      expect(
        await h.run(module, <String>[
          'backup',
          'create',
          '-o',
          data('inside.zip'),
        ]),
        64,
      );
      expect(File(data('inside.zip')).existsSync(), isFalse);
    });

    test('包里 schema 比本版本新 / 有越界路径 → 拒绝，数据不动', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      await setPref('keep');

      final File newer = _craftZip(
        p.join(h.tmp.path, 'newer.zip'),
        <String, String>{
          'manifest.json': _manifest(schema: 99999),
          'data/support/fushi.db': 'x',
        },
      );
      expect(
        await h.run(module, <String>['backup', 'restore', newer.path, '--yes']),
        65,
      );
      expect(h.err.toString(), contains('schema'));

      final File slip =
          _craftZip(p.join(h.tmp.path, 'slip.zip'), <String, String>{
            'manifest.json': _manifest(),
            'data/support/fushi.db': 'x',
            'data/../../evil.txt': 'x',
          });
      expect(
        await h.run(module, <String>['backup', 'restore', slip.path, '--yes']),
        65,
      );
      expect(File(p.join(h.tmp.path, 'evil.txt')).existsSync(), isFalse);

      final File notBackup = _craftZip(
        p.join(h.tmp.path, 'other.zip'),
        <String, String>{'hello.txt': 'x'},
      );
      expect(
        await h.run(module, <String>[
          'backup',
          'restore',
          notBackup.path,
          '--yes',
        ]),
        65,
      );

      expect(await getPref(), 'keep');
      expect(
        h.tmp.listSync().where(
          (FileSystemEntity e) => p.basename(e.path).contains('pre-restore'),
        ),
        isEmpty,
      );
    });

    test('包里数据库不是 SQLite / 配置无效 → 换数据之前拒绝，数据与配置都不动', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      await setPref('keep');
      final String config = h.configFile.readAsStringSync();

      final File garbageDb = _craftZip(
        p.join(h.tmp.path, 'garbage.zip'),
        <String, String>{
          'manifest.json': _manifest(),
          'data/support/fushi.db': 'not a database',
        },
      );
      expect(
        await h.run(module, <String>[
          'backup',
          'restore',
          garbageDb.path,
          '--yes',
        ]),
        65,
      );
      expect(h.err.toString(), contains('SQLite'));

      final File badConfig = _craftZip(
        p.join(h.tmp.path, 'bad_config.zip'),
        <String, String>{
          'manifest.json': _manifest(),
          'data/support/fushi.db': 'SQLite format 3\u0000rest',
          // libraries[0] 没有 path：ServerConfig.parse 抛 FormatException。
          'config/fushi_server.yaml': 'libraries:\n  - kind: video\n',
        },
      );
      expect(
        await h.run(module, <String>[
          'backup',
          'restore',
          badConfig.path,
          '--yes',
        ]),
        65,
      );
      expect(h.err.toString(), contains('config file'));

      expect(await getPref(), 'keep');
      expect(h.configFile.readAsStringSync(), config);
      expect(
        h.tmp.listSync().where(
          (FileSystemEntity e) =>
              p.basename(e.path).contains('pre-restore') ||
              p.basename(e.path).contains('.restore-'),
        ),
        isEmpty,
      );
    });

    test('凭据权限：备份包 0600，属主专用文件还原后仍是 0600', () async {
      final File out = File(p.join(h.tmp.path, 'b.zip'));
      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
      );
      await out.delete();
      final String secret = data('support/interconnect_client/peers.json');
      _write(secret, '{"token":"t"}');
      expect((await Process.run('chmod', <String>['600', secret])).exitCode, 0);
      _write(data('support/dictionaries/d.txt'), 'dict');

      expect(
        await h.run(module, <String>['backup', 'create', '-o', out.path]),
        0,
        reason: h.err.toString(),
      );
      expect(out.statSync().mode & 0x1FF, 0x180, reason: '备份包只给属主读写');

      File(secret).deleteSync();
      expect(
        await h.run(module, <String>[
          'backup',
          'restore',
          out.path,
          '--yes',
          '--json',
        ]),
        0,
        reason: h.err.toString(),
      );
      expect(File(secret).readAsStringSync(), '{"token":"t"}');
      expect(File(secret).statSync().mode & 0x1FF, 0x180);
      // 普通文件不被收紧（还是按 umask）。
      expect(
        File(data('support/dictionaries/d.txt')).statSync().mode & 0x3F,
        isNot(0),
      );
      await Directory(
        h.json()['previousData']! as String,
      ).delete(recursive: true);
    }, testOn: '!windows');
  });

  group('admin API /api/admin/backups', () {
    late Directory tmp;
    late FushiDatabase db;
    late AdminApi api;
    late String dataDir;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_admin_backup_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
      final ServerConfig config = ServerConfig.defaults(
        dataDir: p.join(tmp.path, 'data'),
      ).copyWith(adminToken: 'tok');
      await config.save(configFile);
      dataDir = config.dataDir;
      final ServerPrefs prefs = ServerPrefs(db);
      final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
      final ServerPaths paths = ServerPaths(config.dataDir);
      await paths.ensureLayout();
      api = AdminApi(
        AdminContext(
          config: config,
          configFile: configFile,
          paths: paths,
          log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
          db: db,
          identity: identity,
          host: HeadlessHost(
            config: config,
            paths: paths,
            db: db,
            prefs: prefs,
            identity: identity,
            p2pAvailable: () => false,
          ),
          startedAt: DateTime.now(),
        ),
      );
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<shelf.Response> call(String method, String path, [Object? body]) =>
        api.handle(
          shelf.Request(
            method,
            Uri.parse('http://localhost/api/admin/$path'),
            body: body == null ? null : jsonEncode(body),
          ),
        );

    Future<Map<String, dynamic>> json(shelf.Response r) async =>
        Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map);

    test('后台生成 → 列出 → 下载 → 删除；生成中再开回 409', () async {
      _write(p.join(dataDir, 'documents', 'big.bin'), 'media');
      final shelf.Response started = await call(
        'POST',
        'backups',
        <String, Object?>{'documents': false},
      );
      expect(started.statusCode, 202);
      final String name = (await json(started))['name'] as String;
      expect((await call('POST', 'backups')).statusCode, 409);
      await api.backups.pending;

      final Map<String, dynamic> list = await json(
        await call('GET', 'backups'),
      );
      expect(list['running'], isNull);
      expect(list['lastError'], isNull);
      expect((list['items'] as List<dynamic>).single['name'], name);

      final shelf.Response download = await call('GET', 'backups/$name');
      expect(download.statusCode, 200);
      final File got = File(p.join(tmp.path, 'got.zip'))
        ..writeAsBytesSync(
          await download.read().expand((List<int> c) => c).toList(),
        );
      final Set<String> names = _zipNames(got);
      expect(names, contains('data/support/fushi.db'));
      expect(names, contains('config/fushi_server.yaml'));
      expect(
        names.where((String n) => n.startsWith('data/documents/')),
        isEmpty,
      );
      expect(
        names.where((String n) => n.startsWith('data/backups/')),
        isEmpty,
        reason: '备份不把备份目录自己装进去',
      );

      expect((await call('DELETE', 'backups/$name')).statusCode, 200);
      expect(
        ((await json(await call('GET', 'backups')))['items'] as List<dynamic>),
        isEmpty,
      );
    });

    test('只认备份文件名：越界 / 其它文件一律 404', () async {
      _write(p.join(dataDir, 'backups', 'notes.txt'), 'x');
      expect((await call('GET', 'backups/notes.txt')).statusCode, 404);
      expect(
        (await call(
          'GET',
          'backups/${Uri.encodeComponent('../fushi_server.yaml')}',
        )).statusCode,
        404,
      );
      expect((await call('DELETE', 'backups/notes.txt')).statusCode, 404);
      expect(
        File(p.join(dataDir, 'backups', 'notes.txt')).existsSync(),
        isTrue,
      );
    });
  });
}
