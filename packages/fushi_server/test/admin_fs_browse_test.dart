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
import 'package:fushi_server/src/admin/fs_browse.dart';
import 'package:fushi_server/src/admin/web_ui.dart';
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
import 'support/fake_rwkv.dart';

/// WebUI 路径框「浏览…」：`GET /api/admin/fs/browse` 的目录清单（[FsBrowser]）与页面接线。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_fs_browse_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  List<Map<String, Object?>> entriesOf(Map<String, Object?> r) =>
      (r['entries']! as List<Object?>).cast<Map<String, Object?>>();

  List<String> namesOf(Map<String, Object?> r) => entriesOf(
    r,
  ).map((Map<String, Object?> e) => e['name']! as String).toList();

  Future<void> seed() async {
    await Directory(
      p.join(tmp.path, 'Videos', 'Season1'),
    ).create(recursive: true);
    await Directory(p.join(tmp.path, 'anime')).create();
    await Directory(p.join(tmp.path, 'Books')).create();
    await File(p.join(tmp.path, 'ffmpeg.exe')).writeAsString('x');
    await File(p.join(tmp.path, 'a.txt')).writeAsString('x');
  }

  group('FsBrowser', () {
    test('目录模式只列子目录，按名字不分大小写排序，附上级路径', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser().browse(
        tmp.path,
        includeFiles: false,
      );
      expect(r['path'], p.normalize(tmp.path));
      expect(r['parent'], p.dirname(p.normalize(tmp.path)));
      expect(namesOf(r), <String>['anime', 'Books', 'Videos']);
      expect(
        entriesOf(r).every((Map<String, Object?> e) => e['dir'] == true),
        isTrue,
      );
      expect(entriesOf(r).first['path'], p.join(tmp.path, 'anime'));
      expect(r['truncated'], isFalse);
    });

    test('文件模式目录在前、文件在后', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser().browse(
        tmp.path,
        includeFiles: true,
      );
      expect(namesOf(r), <String>[
        'anime',
        'Books',
        'Videos',
        'a.txt',
        'ffmpeg.exe',
      ]);
      expect(entriesOf(r).last['dir'], isFalse);
    });

    test('path 指向文件：打开所在目录并标出该文件', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser().browse(
        p.join(tmp.path, 'ffmpeg.exe'),
        includeFiles: true,
      );
      expect(r['path'], p.normalize(tmp.path));
      expect(r['selected'], 'ffmpeg.exe');
      expect(r.containsKey('fellBack'), isFalse);
    });

    test('path 不存在：打开最近的已存在上级，fellBack', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser().browse(
        p.join(tmp.path, 'Videos', 'nope', 'deeper'),
        includeFiles: false,
      );
      expect(r['path'], p.join(tmp.path, 'Videos'));
      expect(r['fellBack'], isTrue);
      expect(namesOf(r), <String>['Season1']);
    });

    test('多余的分隔符与 .. 被规整', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser().browse(
        '${tmp.path}${Platform.pathSeparator}Videos${Platform.pathSeparator}..'
        '${Platform.pathSeparator}${Platform.pathSeparator}Books',
        includeFiles: false,
      );
      expect(r['path'], p.join(tmp.path, 'Books'));
    });

    test('超过 maxEntries 截断并标 truncated', () async {
      await seed();
      final Map<String, Object?> r = await FsBrowser(
        maxEntries: 2,
      ).browse(tmp.path, includeFiles: false);
      expect(namesOf(r), <String>['anime', 'Books']);
      expect(r['truncated'], isTrue);
    });

    test('Windows：空路径 / 相对路径列盘符，盘符根的上级回到盘符清单', () async {
      final FsBrowser b = FsBrowser(
        isWindows: true,
        windowsDrives: () => <String>[r'C:\', r'D:\'],
      );
      for (final String raw in <String>['', 'relative\\dir']) {
        final Map<String, Object?> r = await b.browse(raw, includeFiles: false);
        expect(r['path'], '', reason: raw);
        expect(r['parent'], isNull, reason: raw);
        expect(namesOf(r), <String>[r'C:\', r'D:\'], reason: raw);
      }
    });

    test('非 Windows：空路径打开 /，没有上级', () async {
      if (Platform.isWindows) return; // `/` 在 Windows 上是当前盘根，语义不同。
      final Map<String, Object?> r = await FsBrowser().browse(
        '',
        includeFiles: false,
      );
      expect(r['path'], '/');
      expect(r['parent'], isNull);
    });
  });

  group('GET /api/admin/fs/browse', () {
    late FushiDatabase db;
    late File configFile;

    setUp(() {
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
    });

    Future<AdminApi> build() async {
      final ServerConfig config = ServerConfig.defaults(
        dataDir: p.join(tmp.path, 'data'),
      ).copyWith(adminToken: 'tok');
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
        srsRwkvHttpClient: noNetworkHttpClient,
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

    Future<({int status, Map<String, dynamic> json})> get(
      AdminApi api,
      String query,
    ) async {
      final shelf.Response r = await api.handle(
        shelf.Request(
          'GET',
          Uri.parse('http://localhost/api/admin/fs/browse?$query'),
        ),
      );
      return (
        status: r.statusCode,
        json: Map<String, dynamic>.from(
          jsonDecode(await r.readAsString())! as Map,
        ),
      );
    }

    test('path / files 参数透传，回包是目录清单', () async {
      await seed();
      final AdminApi api = await build();
      final String q = 'path=${Uri.encodeQueryComponent(tmp.path)}';
      final ({int status, Map<String, dynamic> json}) dirs = await get(api, q);
      expect(dirs.status, 200);
      expect(
        namesOf(dirs.json),
        containsAllInOrder(<String>['anime', 'Books']),
      );
      expect(namesOf(dirs.json), isNot(contains('ffmpeg.exe')));
      final ({int status, Map<String, dynamic> json}) files = await get(
        api,
        '$q&files=1',
      );
      expect(namesOf(files.json), contains('ffmpeg.exe'));
    });
  });

  group('页面接线', () {
    test('库路径框带「浏览…」，设置页工具 / 库路径用文件选择', () {
      expect(adminWebUiHtml, contains('data-browse="lib-path"'));
      expect(
        adminWebUiHtml,
        contains('<dialog class="kit-dialog fs-dialog" id="fs-dlg"'),
      );
      expect(adminWebUiHtml, contains("api('fs/browse?path='"));
      for (final String k in <String>[
        "['ffmpeg',",
        "['ffprobe',",
        "['onnxruntimeLibrary',",
        "['torrent.library',",
      ]) {
        final int i = adminWebUiHtml.indexOf(k);
        expect(i, isNonNegative, reason: k);
        expect(
          adminWebUiHtml.substring(i, adminWebUiHtml.indexOf(']', i)),
          endsWith(
            "'file','${k == "['torrent.library'," ? 'downloads' : 'tools'}'",
          ),
          reason: k,
        );
      }
      expect(
        adminWebUiHtml,
        contains("else if(type==='file'){ ctl = pathCtl(id, v, true);"),
      );
    });
  });
}
