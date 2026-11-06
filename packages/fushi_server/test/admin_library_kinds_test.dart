import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 扫描根 kind 的一致性：admin API 新增库根、yaml 加载与扫描器分派认同一份
/// `kServerLibraryRootKinds`；`music` 明确拒绝并指向缺口文档；有声书根可「移除并清理」。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_kinds_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    EpubStorage.debugBaseDirectoryOverride = null;
  });

  tearDown(() async {
    await db.close();
    engineLog = const StderrEngineLogSink();
    EpubStorage.debugBaseDirectoryOverride = null;
    enginePaths = const UninstalledEnginePaths();
    AudiobookStorage.documentsRootResolver = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<({AdminApi api, AdminContext ctx})> build({
    List<LibraryRootConfig> libraries = const <LibraryRootConfig>[],
  }) async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok', libraries: libraries);
    await config.save(configFile);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    installServerHostBindings(
      config: config,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
    );
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
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
    return (api: AdminApi(ctx), ctx: ctx);
  }

  Future<({int status, Map<String, dynamic> json})> call(
    AdminApi api,
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(
        jsonDecode(await r.readAsString())! as Map,
      ),
    );
  }

  test('admin 新增库根：video / book / manga / audiobook 都收', () async {
    final (:AdminApi api, :AdminContext ctx) = await build();
    for (final String kind in kServerLibraryRootKinds) {
      final (:int status, json: _) = await call(
        api,
        'POST',
        '/api/admin/libraries',
        <String, Object?>{
          'path': p.join(tmp.path, 'lib_$kind'),
          'kind': kind,
          'id': kind,
        },
      );
      expect(status, 200, reason: kind);
    }
    expect(
      ctx.config.libraries.map((LibraryRootConfig l) => l.kind),
      kServerLibraryRootKinds,
    );
    // 写回的 yaml 能原样读回（加载校验与新增校验同一份清单）。
    final ServerConfig reloaded = await ServerConfig.load(configFile);
    expect(
      reloaded.libraries.map((LibraryRootConfig l) => l.kind),
      kServerLibraryRootKinds,
    );
  });

  test('admin 新增 music 根：400，说明指向缺口文档；未知 kind 同样 400', () async {
    final (:AdminApi api, :AdminContext ctx) = await build();
    final ({int status, Map<String, dynamic> json}) music = await call(
      api,
      'POST',
      '/api/admin/libraries',
      <String, Object?>{'path': p.join(tmp.path, 'music'), 'kind': 'music'},
    );
    expect(music.status, 400);
    expect(music.json['error'], contains('docs/agent/server-parity-gaps.md'));
    final ({int status, Map<String, dynamic> json}) typo = await call(
      api,
      'POST',
      '/api/admin/libraries',
      <String, Object?>{'path': p.join(tmp.path, 'x'), 'kind': 'vidoe'},
    );
    expect(typo.status, 400);
    expect(typo.json['error'], contains('vidoe'));
    expect(ctx.config.libraries, isEmpty);
  });

  test('yaml 里的 music / 未知 kind：加载即报错，不会静默变成跳过的库根', () {
    for (final String kind in <String>['music', 'vidoe']) {
      expect(
        () => ServerConfig.parse(
          'libraries:\n  - id: m\n    path: /srv/x\n    kind: $kind\n',
          configDir: tmp.path,
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains(kind),
          ),
        ),
      );
    }
  });

  test('有声书根：扫描认领的书在目录删掉后 purge 回收，再移除库根', () async {
    final Directory root = Directory(p.join(tmp.path, 'ab'));
    File(p.join(root.path, 'Neko', '01.mp3'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[7, 7, 7]);
    File(
      p.join(root.path, 'Neko', 'neko.srt'),
    ).writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n');
    final (:AdminApi api, :AdminContext ctx) = await build(
      libraries: <LibraryRootConfig>[
        LibraryRootConfig(id: 'ab', path: root.path, kind: 'audiobook'),
      ],
    );
    expect((await ctx.scanLibraries()).audiobooksAdded, 1);
    root.deleteSync(recursive: true);

    final (:int status, :Map<String, dynamic> json) = await call(
      api,
      'DELETE',
      '/api/admin/libraries/ab?purge=true',
    );

    expect(status, 200);
    expect((json['purge'] as Map)['deleted'], 1);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getAllSrtBooks(), isEmpty);
    expect(ctx.config.libraries, isEmpty);
  });
}
