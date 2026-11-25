import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlRoute;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_device_backups.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
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

import 'support/fake_rwkv.dart';

/// 自动备份第四期 A：设备经互联复制到服务端的定时还原点（`<数据目录>/interconnect/sync-data/fushi-data/
/// __backups__/<设备键>/<id>/`）的 admin 端点：按设备列出、下载 zip、删一份 / 删一台；网络来的名字（含编码过的
/// `..` / `/`）在动盘前拒掉，收件箱之外的东西一个不碰。互联服务不起（host 没 start），同步根按
/// [serverInterconnectSyncRoot] 的兜底规则算。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late AdminApi api;
  late String dataDir;
  late String syncRoot;

  const String phone = '0123456789abcdef';
  const String tablet = 'fedcba9876543210';
  const String id1 = '20261120-030000-000-fushi-scheduled';
  const String id2 = '20261124-030000-000-fushi-scheduled';
  const String id3 = '20261123-030000-000-fushi-scheduled';
  const String idHalf = '20261125-030000-000-fushi-scheduled';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_devbak_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dataDir = p.join(tmp.path, 'data');
    enginePaths = ServerPaths(dataDir);
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: dataDir,
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(dataDir);
    await paths.ensureLayout();
    final HeadlessHost host = HeadlessHost(
      srsRwkvHttpClient: noNetworkHttpClient,
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
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
    syncRoot = p.join(dataDir, 'interconnect', 'sync-data', 'fushi-data');
    expect(serverInterconnectSyncRoot(paths), syncRoot);
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 照设备上传的样子写一份副本：先 zip，后元数据（[meta] 为 false = 半截）。
  Directory putCopy(
    String device,
    String id, {
    required int createdAtMs,
    String? name,
    bool meta = true,
    List<int>? zip,
  }) {
    final Directory dir = Directory(
      p.join(syncRoot, kDeviceBackupsNamespace, device, id),
    )..createSync(recursive: true);
    final List<int> bytes = zip ?? List<int>.filled(10, 7);
    File(
      p.join(dir.path, kRestorePointArchiveFileName),
    ).writeAsBytesSync(bytes);
    if (meta) {
      final RestorePoint point = RestorePoint(
        id: id,
        directory: dir.path,
        kind: RestorePointKind.scheduled,
        database: RestorePointDatabase.fushi,
        createdAtMs: createdAtMs,
        fromSchema: 180,
        toSchema: 180,
        files: <RestorePointFile>[
          RestorePointFile(
            name: kRestorePointArchiveFileName,
            size: bytes.length,
          ),
        ],
        fullDatabase: true,
        appVersion: '1.2.3',
        deviceId: device,
        deviceName: name,
      );
      File(
        p.join(dir.path, kRestorePointMetaFileName),
      ).writeAsStringSync(jsonEncode(point.toJson()));
    }
    return dir;
  }

  Future<shelf.Response> send(String method, String path) => api.handle(
    shelf.Request(method, Uri.parse('http://localhost/api/admin/$path')),
  );

  Future<({int status, Map<String, Object?> json})> call(
    String method,
    String path,
  ) async {
    final shelf.Response r = await send(method, path);
    final String text = await r.readAsString();
    return (
      status: r.statusCode,
      json: text.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(text) as Map<String, Object?>),
    );
  }

  test('列表按设备分组，最新的设备在前；根只给相对数据目录的路径', () async {
    putCopy(phone, id1, createdAtMs: 1000, name: 'Pixel');
    putCopy(phone, id2, createdAtMs: 3000, name: 'Pixel 9');
    putCopy(tablet, id3, createdAtMs: 2000, name: 'iPad');
    putCopy(tablet, idHalf, createdAtMs: 4000, meta: false);

    final r = await call('GET', 'device-backups');
    expect(r.status, 200);
    expect(r.json['root'], 'interconnect/sync-data/fushi-data/__backups__');
    expect(
      jsonEncode(r.json),
      isNot(contains(tmp.path.replaceAll(r'\', r'\\'))),
    );
    final List<Object?> devices = r.json['devices']! as List<Object?>;
    expect(
      devices.map((Object? d) => (d! as Map<String, Object?>)['device']),
      <String>[phone, tablet],
    );
    final Map<String, Object?> a = devices.first! as Map<String, Object?>;
    expect(a['name'], 'Pixel 9');
    expect(a['count'], 2);
    expect(a['newestAtMs'], 3000);
    expect(a['incomplete'], 0);
    final List<Object?> copies = a['copies']! as List<Object?>;
    expect(
      copies.map((Object? c) => (c! as Map<String, Object?>)['id']),
      <String>[id2, id1],
    );
    expect((copies.first! as Map<String, Object?>)['appVersion'], '1.2.3');
    final Map<String, Object?> b = devices.last! as Map<String, Object?>;
    expect(b['count'], 1);
    expect(b['incomplete'], 1);
  });

  test('没有收件箱：空列表', () async {
    final r = await call('GET', 'device-backups');
    expect(r.status, 200);
    expect(r.json['devices'], isEmpty);
  });

  test('下载：原样字节 + zip 头 + 文件名只留安全字符', () async {
    final List<int> zip = utf8.encode('PK\u0003\u0004 not really a zip');
    putCopy(phone, id1, createdAtMs: 1000, name: 'Pixel 9 / "ü"', zip: zip);
    putCopy(tablet, id3, createdAtMs: 2000, zip: zip);

    final shelf.Response r = await send('GET', 'device-backups/$phone/$id1');
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], 'application/zip');
    expect(r.headers['content-length'], '${zip.length}');
    expect(
      r.headers['content-disposition'],
      'attachment; filename="fushi-Pixel-9-$id1.zip"',
    );
    expect(r.headers['cache-control'], 'no-store');
    final List<int> got = <int>[
      for (final List<int> chunk in await r.read().toList()) ...chunk,
    ];
    expect(got, zip);

    // 没有设备名：用设备键。
    final shelf.Response t = await send('GET', 'device-backups/$tablet/$id3');
    expect(
      t.headers['content-disposition'],
      'attachment; filename="fushi-$tablet-$id3.zip"',
    );
    await t.read().drain<void>();
  });

  test('不存在 / 不完整的副本：404', () async {
    putCopy(phone, idHalf, createdAtMs: 1000, meta: false);
    expect((await call('GET', 'device-backups/$phone/$idHalf')).status, 404);
    expect((await call('GET', 'device-backups/$phone/$id1')).status, 404);
    expect((await call('GET', 'device-backups/$tablet/$id1')).status, 404);
    expect((await call('DELETE', 'device-backups/$tablet/$id1')).status, 404);
    expect((await call('DELETE', 'device-backups/$tablet')).status, 404);
  });

  test('删一份只删那一份；删一台删这台的全部；删过再删 404', () async {
    final Directory c1 = putCopy(phone, id1, createdAtMs: 1000);
    final Directory c2 = putCopy(phone, id2, createdAtMs: 3000);
    final Directory c3 = putCopy(tablet, id3, createdAtMs: 2000);
    // 半截副本也能删（设备没来得及清的）。
    final Directory half = putCopy(tablet, idHalf, createdAtMs: 0, meta: false);

    final r = await call('DELETE', 'device-backups/$phone/$id1');
    expect(r.status, 200);
    expect(r.json['ok'], isTrue);
    expect(c1.existsSync(), isFalse);
    expect(c2.existsSync(), isTrue);
    expect((await call('DELETE', 'device-backups/$phone/$id1')).status, 404);

    expect(
      (await call('DELETE', 'device-backups/$tablet/$idHalf')).status,
      200,
    );
    expect(half.existsSync(), isFalse);

    expect((await call('DELETE', 'device-backups/$tablet')).status, 200);
    expect(c3.existsSync(), isFalse);
    expect(
      Directory(p.join(syncRoot, kDeviceBackupsNamespace, tablet)).existsSync(),
      isFalse,
    );
    expect(c2.existsSync(), isTrue);
    expect((await call('DELETE', 'device-backups/$tablet')).status, 404);
  });

  test('不合格的设备键 / id（含编码过的 .. 与 /）一律 400、不回显、收件箱外一个不碰', () async {
    putCopy(phone, id1, createdAtMs: 1000);
    // 收件箱外的哨兵：同步根下别的数据、数据目录里的文件。
    final File outsideSync = File(p.join(syncRoot, 'books', 'keep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep');
    final File outsideData = File(p.join(dataDir, 'keep.txt'))
      ..writeAsStringSync('keep');

    const List<String> badDevice = <String>[
      '%2E%2E%2Fbooks',
      '..%2F..%2F..',
      '0123%2F4567',
      'ABCDEF',
      '%20',
      '0123456789abcdefg',
      '%zz',
    ];
    for (final String d in badDevice) {
      for (final String method in <String>['DELETE', 'GET']) {
        final String path = method == 'GET'
            ? 'device-backups/$d/$id1'
            : 'device-backups/$d';
        final r = await call(method, path);
        expect(r.status, 400, reason: '$method $path');
        expect(jsonEncode(r.json), isNot(contains('books')), reason: path);
      }
    }
    const List<String> badId = <String>[
      '..%2F..%2Fbooks',
      '$id1%2F..',
      'not-an-id',
      '20261120-030000-000-fushi-manual',
    ];
    for (final String id in badId) {
      for (final String method in <String>['DELETE', 'GET']) {
        final r = await call(method, 'device-backups/$phone/$id');
        expect(r.status, 400, reason: '$method $id');
      }
    }
    // 多出来的路径段 / 空段：不是这组路由。
    for (final String path in <String>[
      'device-backups/$phone/$id1/backup.zip',
      'device-backups/$phone/$id1/..%2F..',
      'device-backups//$id1',
      'device-backups/$phone/',
    ]) {
      expect((await call('DELETE', path)).status, 404, reason: path);
    }
    // 整段的 `..`（字面或 `%2e%2e`）：URI 解析先把点段消掉（`%2e` 是非保留字符，先还原成 `.`），
    // 请求根本到不了这组路由，落到别的（不存在的）路由或方法兜底，404。
    for (final String path in <String>[
      'device-backups/$phone/../../backups',
      'device-backups/%2e%2e',
      'device-backups/$phone/%2e%2e',
      'device-backups/%2e%2e/%2e%2e/backups',
    ]) {
      expect((await call('DELETE', path)).status, 404, reason: path);
    }
    // 不支持的方法：兜底 404。
    expect((await call('POST', 'device-backups')).status, 404);
    expect((await call('PUT', 'device-backups/$phone/$id1')).status, 404);
    expect((await call('GET', 'device-backups/$phone')).status, 404);

    expect(outsideSync.readAsStringSync(), 'keep');
    expect(outsideData.readAsStringSync(), 'keep');
    expect(
      Directory(
        p.join(syncRoot, kDeviceBackupsNamespace, phone, id1),
      ).existsSync(),
      isTrue,
    );
  });

  test('整机备份路由不吞设备备份前缀', () async {
    putCopy(phone, id1, createdAtMs: 1000);
    expect((await call('GET', 'backups')).status, 200);
    final r = await call('GET', 'device-backups');
    expect((r.json['devices']! as List<Object?>).length, 1);
  });

  test('设备备份（整份数据库）不进远端 AI 助手的操作目录', () {
    final List<CtlRoute> routes = buildServerAdminOps(
      () =>
          (shelf.Request _) async => shelf.Response.ok('{}'),
    ).routes;
    expect(
      routes.where(
        (CtlRoute r) =>
            r.pattern.startsWith(kAdminDeviceBackupsPath) ||
            r.pattern.startsWith('/api/admin/backups'),
      ),
      isEmpty,
    );
  });

  test('WebUI：导航项与页面都在，脚本在 loaders 之后、首次出页之前登记', () {
    final String html = renderAdminWebUi(ServerConfig.languageChinese);
    expect(html, contains('<button class="nav-item" data-s="device-backups">'));
    expect(html, contains('<section id="s-device-backups">'));
    final int loaders = html.indexOf('const loaders = {');
    final int register = html.indexOf(
      "loaders['device-backups'] = loadDeviceBackups;",
    );
    final int start = html.indexOf('const startPage = ');
    expect(loaders, isNonNegative);
    expect(register, greaterThan(loaders));
    expect(start, greaterThan(register));
    // 导航项在「系统」组里、「设置」之前。
    final int system = html.indexOf('<div class="nav-group-label">系统</div>');
    final int nav = html.indexOf('data-s="device-backups"');
    final int settings = html.indexOf('data-s="settings"');
    expect(nav, greaterThan(system));
    expect(settings, greaterThan(nav));
  });
}
