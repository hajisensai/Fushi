// 服务端复习库（docs/specs/2026-11-05-server-srs-design.md §4.1–§4.4）：真 SrsStorage + 本机互联同步目录，
// 两台「手机」各用一份 profile（一门语言一份）往服务端目录里同步。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'dart:convert';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';
const String kHostId = 'server-srs-test-host';

void main() {
  late Directory tmp;
  late Directory support;
  late Directory syncData;
  late ServerSrsConfig config;
  late ServerSrs srs;
  int published = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_');
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    syncData = Directory(p.join(tmp.path, 'interconnect'))..createSync();
    config = const ServerSrsConfig();
    published = 0;
    srs = ServerSrs(
      support: support,
      syncData: syncData,
      deviceId: 'server-device',
      hostId: kHostId,
      config: () => config,
      engine: () => null,
      onPublished: () => published++,
    );
  });

  tearDown(() async {
    await srs.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  /// 一台手机：自己的 srs.db，经互联写进服务端同步目录（与真实客户端写到的是同一块目录）。
  Future<SrsDbStore> phone(String uid, String deviceId) async {
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
      profileUid: uid,
      deviceId: deviceId,
    );
  }

  Future<SrsSync2Report> phoneSync(SrsDbStore s) => srsRunLocationRound(
    SrsLocationBackend(LocalDirectoryAssetStore(srs.syncRoot)),
    s,
    srsInterconnectDirectoryKey(kHostId),
  );

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): expression,
    },
  );

  Future<List<String>> expressions(SrsDbStore s) async {
    final List<String> out = <String>[];
    for (final SrsNoteCacheRow row in await (s.db.select(
      s.db.srsNotesCache,
    )..where((n) => n.profileUid.equals(s.profileUid))).get()) {
      final SrsNoteView? n = await s.note(row.id);
      final String? e = n?.field(srsLapisFieldId(s.profileUid, 'Expression'));
      if (e != null) out.add(e);
    }
    return out..sort();
  }

  test('没选 profile：什么都不开，远程复习不可用', () async {
    await srs.start();
    expect(srs.remoteStore, isNull);
    expect(srs.profiles, isEmpty);
    expect(File(SrsStorage.pathIn(support.path)).existsSync(), isFalse);
  });

  test('两份 profile 各自同步：手机的卡收进对应那份，服务端写的卡发回手机', () async {
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    final SrsDbStore zh = await phone(kZh, 'phone-zh');
    await addNote(ja, '食べる');
    await addNote(zh, '吃饭');
    expect((await phoneSync(ja)).error, isNull);
    expect((await phoneSync(zh)).error, isNull);

    // 管理员从同步目录里列出的 profile 里勾两份。
    await srs.start();
    final List<String> found =
        (await srs.discoverProfiles()).map((r) => r.uid).toList()..sort();
    expect(found, <String>[kJa, kZh]);
    config = const ServerSrsConfig(profiles: <String>[kJa, kZh]);
    await srs.applyConfig();
    await srs.syncNow();

    expect(srs.readyProfiles.map((ServerSrsProfile x) => x.uid), <String>[
      kJa,
      kZh,
    ]);
    expect(await expressions(srs.storeFor(kJa)!), <String>['食べる']);
    expect(await expressions(srs.storeFor(kZh)!), <String>['吃饭']);
    expect(srs.storeFor(null)!.profileUid, kJa, reason: '默认 = 第一份');

    // 服务端自己往中文那份写一张（AnkiConnect / 互联制卡走的就是这条），发出去，手机收到。
    await addNote(srs.storeFor(kZh)!, '喝水');
    await srs.syncNow(kZh);
    expect(published, greaterThan(0));
    expect((await phoneSync(zh)).error, isNull);
    expect(await expressions(zh), <String>['吃饭', '喝水']);
    // 日语那份不受影响。
    expect((await phoneSync(ja)).error, isNull);
    expect(await expressions(ja), <String>['食べる']);
  });

  test('已配对设备写进来的文件只叫醒对应那份 profile', () async {
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    expect((await phoneSync(ja)).error, isNull);
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.start();
    await srs.syncNow();

    await addNote(ja, '飲む');
    expect((await phoneSync(ja)).error, isNull);
    final Future<String> changed = srs.changes.stream.first;
    srs.onClientWrite('fushi-data/fushi-srs/$kJa/v3/devices/x/seg-1.bin');
    srs.onClientWrite('fushi-data/books/whatever.epub');
    expect(await changed.timeout(const Duration(seconds: 20)), kJa);
    expect(await expressions(srs.storeFor(kJa)!), <String>['飲む']);
  });

  test('远程复习：握手列出两份，点名中文那份读到中文；去掉那份后回 profile_changed', () async {
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    final SrsDbStore zh = await phone(kZh, 'phone-zh');
    await addNote(ja, '食べる');
    await addNote(zh, '吃饭');
    await phoneSync(ja);
    await phoneSync(zh);
    config = const ServerSrsConfig(
      profiles: <String>[kJa, kZh],
      defaultProfile: kZh,
    );
    await srs.start();
    await srs.syncNow();

    final SrsRemoteStoreService remote = srs.remoteStore!;
    final Map<String, Object?> hello = await _call(remote, <String, Object?>{
      'op': 'hello',
    });
    expect(hello['profile'], kZh, reason: '配置的默认 profile');
    expect(
      (hello['profiles']! as List<Object?>)
          .map((Object? e) => (e! as Map)['uid'])
          .toList(),
      <String>[kJa, kZh],
    );
    final Map<String, Object?> jaHello = await _call(remote, <String, Object?>{
      'op': 'hello',
      'profile': kJa,
    });
    expect(jaHello['profile'], kJa);

    config = const ServerSrsConfig(profiles: <String>[kZh]);
    await srs.applyConfig();
    final shelf.Response gone = await handleSrsRemoteStoreRequest(
      remote,
      shelf.Request(
        'POST',
        Uri.parse('http://host/api/srs/remote/call'),
        body: jsonEncode(<String, Object?>{'op': 'hello', 'profile': kJa}),
      ),
      'POST',
      '/api/srs/remote/call',
    );
    expect(gone.statusCode, 409);
    expect(
      (jsonDecode(await gone.readAsString()) as Map)['error'],
      SrsRemoteStoreError.profileChanged,
    );
  });
}

Future<Map<String, Object?>> _call(
  SrsRemoteStoreService service,
  Map<String, Object?> body,
) async {
  final shelf.Response res = await handleSrsRemoteStoreRequest(
    service,
    shelf.Request(
      'POST',
      Uri.parse('http://host/api/srs/remote/call'),
      body: jsonEncode(body),
    ),
    'POST',
    '/api/srs/remote/call',
  );
  expect(res.statusCode, 200);
  return (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();
}
