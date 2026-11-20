// 整机备份与复习库换代迁移互斥（G10-4 定的语义，第六波服务端收尾补端到端）：经 admin API + 真 HeadlessHost——迁移在跑时
// `POST /api/admin/backups` 回 409 `srs_migration_running`、不出包；迁完之后照常备份，包里是新代库。迁移的执行端换成
// 替身（让迁移停在「进行中」），其余（ServerSrs、AdminBackups、createServerBackup、复习库）都是真的。
//
// 另：被杀进程留下的换代过程文件（`srs4.db-migrating` / `srs4.db-creating` / `srs.db-gen4-prepare` 及其 -wal / -shm /
// -journal）不进包（server_backup.dart 的排除表，文件名对 native `files.rs` 的 GEN4_TEMP / GEN4_CREATING / PREPARE_COPY）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';

/// 迁移执行端替身：状态命令先报「要迁移」，[run] 挂到测试给结论为止；结论之后状态命令报 [after]。
final class _HeldMigration implements SrsGen4MigrationBackend {
  SrsGenState state = SrsGenState.needsMigration;
  final Completer<SrsGen4MigrationOutcome> verdict =
      Completer<SrsGen4MigrationOutcome>();
  int runs = 0;

  @override
  SrsGen4MigrationStatus status(String dir) =>
      SrsGen4MigrationStatus(state: state);

  @override
  Future<List<String>> legacyProfiles(String dir) async => <String>[kJa];

  @override
  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  }) {
    runs++;
    return verdict.future;
  }

  @override
  bool cancel(String dir, {String? runId}) {
    if (!verdict.isCompleted) {
      verdict.complete(
        const SrsGen4MigrationOutcome(
          verdict: SrsGen4MigrationVerdict.cancelled,
        ),
      );
    }
    return true;
  }

  void commit() {
    state = SrsGenState.ready;
    verdict.complete(
      const SrsGen4MigrationOutcome(verdict: SrsGen4MigrationVerdict.committed),
    );
  }
}

Set<String> _entries(File zip) {
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

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late _HeldMigration migration;
  late ServerConfig config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_backup_mig_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
      port: 0,
      bind: '127.0.0.1',
      tls: false,
      adminToken: 'tok',
      srs: const ServerSrsConfig(profiles: <String>[kJa]),
    );
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    migration = _HeldMigration();
    host = HeadlessHost(
      srsRwkvHttpClient: noNetworkHttpClient,
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
      srsMigration: migration,
    );
    await host.start();
    api = AdminApi(
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
  });

  tearDown(() async {
    if (!migration.verdict.isCompleted) migration.commit();
    await host.stop();
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/$path'),
        headers: const <String, String>{'Authorization': 'Bearer tok'},
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      r.statusCode,
      Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map),
    );
  }

  Directory backupsDir() => Directory(p.join(config.dataDir, 'backups'));

  List<File> backups() => backupsDir().existsSync()
      ? backupsDir()
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.zip'))
            .toList()
      : const <File>[];

  test('迁移在跑：整机备份 409 srs_migration_running、不出包；迁完照常备份，包里是新代库', () async {
    final srs = host.srs!;
    for (int i = 0; i < 500 && !srs.migrationRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(srs.migrationRunning, isTrue, reason: '启动即后台迁移');
    expect(migration.runs, 1);

    var (int code, Map<String, dynamic> body) = await call(
      'POST',
      'backups',
      <String, Object?>{'documents': false},
    );
    expect(code, 409, reason: '$body');
    expect(body['error'], 'srs_migration_running');
    expect(backups(), isEmpty);
    (code, body) = await call('GET', 'backups');
    expect(body['running'], isNull, reason: '被拒的请求没有留下在跑的备份');

    migration.commit();
    for (int i = 0; i < 500 && srs.migrationRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(srs.migrationRunning, isFalse);
    await srs.applyConfig();

    (code, body) = await call('POST', 'backups', <String, Object?>{
      'documents': false,
    });
    expect(code, 202, reason: '$body');
    await api.backups.pending;
    (code, body) = await call('GET', 'backups');
    expect(body['lastError'], isNull, reason: '$body');
    final List<File> made = backups();
    expect(made, hasLength(1));
    expect(_entries(made.single), contains('data/support/srs4.db'));
    expect(migration.runs, 1, reason: '备份没有引发再迁一次');
  });

  test('被杀进程留下的换代过程文件不进包', () async {
    final Directory support = Directory(p.join(config.dataDir, 'support'));
    const List<String> leftovers = <String>[
      'srs4.db-migrating',
      'srs4.db-migrating-wal',
      'srs4.db-creating',
      'srs4.db-creating-journal',
      'srs.db-gen4-prepare',
      'srs.db-gen4-prepare-shm',
    ];
    for (final String name in leftovers) {
      File(p.join(support.path, name)).writeAsStringSync('left by a kill');
    }
    final File zip = await createServerBackup(
      db: db,
      dataDir: config.dataDir,
      configFile: null,
      output: File(p.join(tmp.path, 'out', 'leftovers.zip')),
      includeDocuments: false,
    );
    final Set<String> entries = _entries(zip);
    for (final String name in leftovers) {
      expect(entries, isNot(contains('data/support/$name')), reason: name);
    }
  });
}
