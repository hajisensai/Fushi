import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// admin API「移除并清理」（`DELETE /api/admin/libraries/<id>?purge=true`）与
/// `serve --no-prune` 的作用范围（BUG-2809）。
///
/// - purge 是显式用户意图：整个目录已经删掉（最常见的用法）也要清得掉，不能被
///   扫描时的「库根不存在」护栏拦下后却照样把根从配置里移走——那样这些行不在任何
///   库根下，再也没有机会被清理。
/// - 对账没做成（拿不到刮削租约）→ 409，库根保留。
/// - `serve --no-prune` 管本进程所有扫描，不只是启动那一次。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;
  late VideoBookRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_purge_');
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    repo = VideoBookRepository(db);
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<({AdminApi api, AdminContext ctx})> build({
    required List<LibraryRootConfig> libraries,
    bool? pruneOverride,
  }) async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok', libraries: libraries);
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
    final AdminContext ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
      pruneOverride: pruneOverride,
    );
    return (api: AdminApi(ctx), ctx: ctx);
  }

  Future<({int status, Map<String, dynamic> json})> purge(
    AdminApi api,
    String id,
  ) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        'DELETE',
        Uri.parse('http://localhost/api/admin/libraries/$id?purge=true'),
      ),
    );
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(
        jsonDecode(await r.readAsString())! as Map,
      ),
    );
  }

  Future<String> addVideo(String path) async {
    final String uid = 'video/${p.basename(path)}';
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(p.basenameWithoutExtension(path)),
        videoPath: Value(path),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    return uid;
  }

  test('整个目录已删掉：purge 照样回收条目，再移除库根', () async {
    final String gone = p.join(tmp.path, 'gone_library');
    await addVideo(p.join(gone, 'a.mkv'));
    await addVideo(p.join(gone, 'b.mkv'));
    final (:AdminApi api, :AdminContext ctx) = await build(
      libraries: <LibraryRootConfig>[
        LibraryRootConfig(id: 'v', path: gone, kind: 'video'),
      ],
    );

    final (:int status, :Map<String, dynamic> json) = await purge(api, 'v');

    expect(status, 200);
    expect((json['purge'] as Map)['deleted'], 2);
    expect(await repo.listAll(), isEmpty);
    expect(ctx.config.libraries, isEmpty);
  });

  test('对账没做成（刮削资料清理在跑）→ 409，库根保留', () async {
    final String gone = p.join(tmp.path, 'gone_library');
    await addVideo(p.join(gone, 'a.mkv'));
    final (:AdminApi api, :AdminContext ctx) = await build(
      libraries: <LibraryRootConfig>[
        LibraryRootConfig(id: 'v', path: gone, kind: 'video'),
      ],
    );
    final VideoScrapeOperationLease maintenance =
        VideoScrapeOperationGate.tryEnterMaintenance()!;
    addTearDown(maintenance.release);

    final (:int status, :Map<String, dynamic> json) = await purge(api, 'v');

    expect(status, 409);
    expect(json['error'], contains('library root kept'));
    expect(await repo.listAll(), hasLength(1));
    expect(ctx.config.libraries, hasLength(1));
  });

  test('serve --no-prune 覆盖配置：WebUI 触发的扫描也不清理', () async {
    final Directory root = Directory(p.join(tmp.path, 'library'))..createSync();
    final String keep = p.join(root.path, 'keep.mkv');
    final String drop = p.join(root.path, 'drop.mkv');
    File(keep).writeAsStringSync('x');
    File(drop).writeAsStringSync('x');
    final (api: _, :AdminContext ctx) = await build(
      libraries: <LibraryRootConfig>[
        LibraryRootConfig(id: 'v', path: root.path, kind: 'video'),
      ],
      pruneOverride: false,
    );
    expect(ctx.config.scanPrune, isTrue);
    await ctx.scanLibraries();
    File(drop).deleteSync();

    final ScanSummary noPrune = await ctx.scanLibraries();
    expect(noPrune.videosPruned, 0);
    expect(await repo.listAll(), hasLength(2));

    // 请求里显式给的仍优先于启动参数。
    final ScanSummary explicit = await ctx.scanLibraries(prune: true);
    expect(explicit.videosPruned, 1);
    expect(await repo.listAll(), hasLength(1));
  });
}
