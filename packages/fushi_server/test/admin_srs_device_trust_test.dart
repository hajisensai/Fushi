// 服务端确认复习同步设备（BUG-4306 的服务端入口）：服务端开库之后才第一次同步过来的设备，它的删除在服务端的库里
// 扣着；admin API `GET /api/admin/srs/devices` 列出、`POST /api/admin/srs/devices/trust` 信任 / 拒绝。真
// HeadlessHost + 真 srs.db，两台「手机」经互联同步目录同步；鉴权经真 AdminServer（没有 token 一律 401）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_server.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminContext ctx;
  late AdminApi api;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_srs_trust_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config =
        ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
          port: 0,
          bind: '127.0.0.1',
          tls: false,
          adminToken: 'tok',
          adminPort: 0,
          adminBind: '127.0.0.1',
        );
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    await host.start();
    ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
    );
    api = AdminApi(ctx);
  });

  tearDown(() async {
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
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      r.statusCode,
      Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map),
    );
  }

  Future<SrsDbStore> phone(String deviceId) async {
    final Directory dir = Directory(p.join(tmp.path, 'phone_$deviceId'))
      ..createSync();
    final SrsStorage storage = await SrsStorage.open(
      path: SrsStorage.pathIn(dir.path),
      inline: true,
    );
    addTearDown(storage.close);
    return SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kJa,
      deviceId: deviceId,
    );
  }

  Future<void> phoneSync(SrsDbStore s) async {
    final SrsSync2Report r = await srsRunLocationRound(
      SrsLocationBackend(LocalDirectoryAssetStore(host.srs!.syncRoot)),
      s,
      host.srs!.directoryKey,
    );
    expect(r.error, isNull);
  }

  Future<bool> hidden(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.hidden;

  /// 手机 A 先有一张卡，服务端开始提供（全新库首轮认识 A，A 可信）；之后新手机 B 加入并删掉那张卡：B 在服务端
  /// 待确认，删除扣着。
  Future<(SrsDbStore, String)> heldOnServer() async {
    final SrsDbStore a = await phone('phone-a');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{srsLapisFieldId(kJa, 'Expression'): '魚'},
    );
    await phoneSync(a);
    expect(
      (await call('PUT', 'srs', <String, Object?>{
        'addProfiles': <String>[kJa],
      })).$1,
      200,
    );
    await host.srs!.syncNow();
    final SrsDbStore server = host.srs!.storeFor(kJa)!;
    expect(await hidden(server, noteId), isFalse);

    final SrsDbStore b = await phone('phone-b');
    await phoneSync(b);
    expect(await hidden(b, noteId), isFalse);
    await b.deleteNote(noteId);
    await phoneSync(b);
    await host.srs!.syncNow();
    expect(await hidden(server, noteId), isFalse);
    return (b, noteId);
  }

  test('列出 → 信任：扣着的删除在服务端生效，再列为空', () async {
    final (SrsDbStore b, String noteId) = await heldOnServer();
    final SrsDbStore server = host.srs!.storeFor(kJa)!;

    var (int code, Map<String, dynamic> body) = await call(
      'GET',
      'srs/devices',
    );
    expect(code, 200, reason: '$body');
    final Map<String, dynamic> prof = Map<String, dynamic>.from(
      (body['profiles'] as List).single as Map,
    );
    expect(prof['uid'], kJa);
    final Map<String, dynamic> d = Map<String, dynamic>.from(
      (prof['untrusted'] as List).single as Map,
    );
    expect(d['device'], b.sync2Device);
    expect(d['trust'], 'pending');
    expect(d['heldDeletes'], 1);
    expect(d['heldPurges'], 0);
    expect(d['trustSince'], isA<int>());
    expect(await hidden(server, noteId), isFalse, reason: '确认前删除扣着');

    // 不点名 profile：只在 kJa 里待确认，自动认出那份。
    (code, body) = await call('POST', 'srs/devices/trust', <String, Object?>{
      'device': b.sync2Device,
      'trust': true,
    });
    expect(code, 200, reason: '$body');
    expect((body['device'] as Map)['trust'], 'trusted');
    expect((body['profile'] as Map)['untrusted'], isEmpty);
    expect(await hidden(server, noteId), isTrue);

    (code, body) = await call('GET', 'srs/devices?profile=$kJa');
    expect(code, 200);
    expect(((body['profiles'] as List).single as Map)['untrusted'], isEmpty);

    // 收敛：服务端与 B 再同步一轮，两边都已删。
    await host.srs!.syncNow();
    await phoneSync(b);
    expect(await hidden(b, noteId), isTrue);
    expect(await hidden(server, noteId), isTrue);
  });

  test('拒绝：继续扣着、列为已拒绝；之后仍可信任', () async {
    final (SrsDbStore b, String noteId) = await heldOnServer();
    final SrsDbStore server = host.srs!.storeFor(kJa)!;
    var (int code, Map<String, dynamic> body) = await call(
      'POST',
      'srs/devices/trust',
      <String, Object?>{
        'device': b.sync2Device,
        'trust': false,
        'profile': kJa,
      },
    );
    expect(code, 200, reason: '$body');
    expect((body['device'] as Map)['trust'], 'rejected');
    expect(await hidden(server, noteId), isFalse);
    (code, body) = await call('GET', 'srs/devices');
    expect(
      (((body['profiles'] as List).single as Map)['untrusted'] as List)
          .single['trust'],
      'rejected',
    );
    (code, body) = await call('POST', 'srs/devices/trust', <String, Object?>{
      'device': b.sync2Device,
      'trust': true,
      'profile': kJa,
    });
    expect(code, 200, reason: '$body');
    expect(await hidden(server, noteId), isTrue);
  });

  test('参数与拒绝原因：坏正文 400、没提供的 profile / 不认识的设备 404、本机 / 已可信 409', () async {
    final (SrsDbStore b, _) = await heldOnServer();
    final String self = host.srs!.storeFor(kJa)!.sync2Device!;
    Future<(int, Object?)> trust(Map<String, Object?> body) async {
      final (int code, Map<String, dynamic> r) = await call(
        'POST',
        'srs/devices/trust',
        body,
      );
      return (code, r['reason'] ?? r['error']);
    }

    expect((await trust(<String, Object?>{'trust': true})).$1, 400);
    expect(
      (await trust(<String, Object?>{
        'device': b.sync2Device,
        'trust': 'yes',
      })).$1,
      400,
    );
    expect(
      await trust(<String, Object?>{
        'device': b.sync2Device,
        'trust': true,
        'profile': '01928c3e-0000-7000-8000-00000000b0b0',
      }),
      (404, 'profile_not_served'),
    );
    expect(
      await trust(<String, Object?>{
        'device': '01928c3e-0000-7000-8000-00000000dead',
        'trust': true,
      }),
      (404, 'device_unknown'),
    );
    expect(
      await trust(<String, Object?>{
        'device': self,
        'trust': true,
        'profile': kJa,
      }),
      (409, 'device_self'),
    );
    expect(
      (await trust(<String, Object?>{
        'device': b.sync2Device,
        'trust': true,
      })).$1,
      200,
    );
    expect(
      await trust(<String, Object?>{
        'device': b.sync2Device,
        'trust': false,
        'profile': kJa,
      }),
      (409, 'device_trusted'),
    );
    expect(
      (await call(
        'GET',
        'srs/devices?profile=01928c3e-0000-7000-8000-00000000b0b0',
      )).$1,
      404,
    );
  });

  test('鉴权：没有 / 错的管理员 token 一律 401，不进复习库', () async {
    final AdminServer server = AdminServer(ctx: ctx, token: 'tok', api: api);
    await server.start();
    addTearDown(server.stop);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<int> send(String method, String path, {String? token}) async {
      final HttpClientRequest req = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}/api/admin/$path'),
      );
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      if (method == 'POST') {
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode(<String, Object?>{
            'device': '01928c3e-0000-7000-8000-00000000dead',
            'trust': true,
          }),
        );
      }
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    expect(await send('GET', 'srs/devices'), 401);
    expect(await send('POST', 'srs/devices/trust'), 401);
    expect(await send('GET', 'srs/devices', token: 'wrong'), 401);
    expect(await send('POST', 'srs/devices/trust', token: 'wrong'), 401);
    expect(await send('GET', 'srs/devices', token: 'tok'), 200);
    // 有 token 时才进到路由（没有提供任何 profile → 不认识的设备）。
    expect(await send('POST', 'srs/devices/trust', token: 'tok'), 404);
  });
}
