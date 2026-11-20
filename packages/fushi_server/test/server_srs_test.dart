// 服务端复习库（docs/specs/2026-11-05-server-srs-design.md §4.1–§4.4）：真 SrsStorage + 本机互联同步目录，
// 两台「手机」各用一份 profile（一门语言一份）往服务端目录里同步。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_srs/fushi_srs.dart' show SrsDayContext, SrsNoteView;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'dart:convert';

import 'support/fake_rwkv.dart';

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
      // RWKV 权重不联网下载（下载当场失败 = RWKV 没就绪）。
      rwkvHttpClient: noNetworkHttpClient,
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
    final SrsStorage storage = await SrsStorage.open(directory: dir.path);
    addTearDown(storage.close);
    return SrsDbStore.open(
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
    for (final SrsNoteCacheRow row in await s.noteRows()) {
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
    expect(File(SrsStorage.gen4PathIn(support.path)).existsSync(), isFalse);
  });

  group('serverSrsPickReportedName：几份说明文件里挑名字不看列举顺序', () {
    /// [entries] 按给的顺序和反过来的顺序各建一份 Map（模拟目录列举的两种顺序），两份挑出来的必须一样。
    String? pickBothOrders(
      List<(String, String, int?)> entries, {
      required String? own,
    }) {
      String? pick(Iterable<(String, String, int?)> order) =>
          serverSrsPickReportedName(
            <String, String>{
              for (final (String w, String n, int? _) in order) w: n,
            },
            <String, int>{
              for (final (String w, String _, int? at) in order)
                if (at != null) w: at,
            },
            own: own,
          );
      final String? forward = pick(entries);
      final String? backward = pick(entries.reversed);
      expect(backward, forward, reason: '两种列举顺序挑出的名字不同');
      return forward;
    }

    test('跳过服务端自己那份，不管它排在前面还是后面', () {
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('server#0', '日本語', 300),
          ('phone#0', 'Japanese', 100),
        ], own: 'server#0'),
        'Japanese',
      );
    });

    test('几台设备报的名字不同时取说明文件最新的', () {
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('a#0', '旧名', 100),
          ('b#0', '新名', 200),
          ('server#0', '服务端', 300),
        ], own: 'server#0'),
        '新名',
      );
    });

    test('一样新、或都没有时刻时按写入者名取最小的；没有时刻的排在有时刻的后面', () {
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('b#0', 'B', 100),
          ('a#0', 'A', 100),
        ], own: null),
        'A',
      );
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('b#0', 'B', null),
          ('a#0', 'A', null),
        ], own: null),
        'A',
      );
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('a#0', 'A', null),
          ('b#0', 'B', 1),
        ], own: null),
        'B',
      );
    });

    test('不合格的外来名字跳过；只剩自己那份时返回 null（由调用方沿用自己上次发布的）', () {
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('a#0', 'J\u0007P', 500),
          ('b#0', 'x' * 101, 400),
          ('c#0', 'ok', 100),
        ], own: null),
        'ok',
      );
      expect(
        pickBothOrders(<(String, String, int?)>[
          ('server#0', '日本語', 100),
          ('a#0', 'J\u0007P', 200),
        ], own: 'server#0'),
        isNull,
      );
    });
  });

  test('srs.db 打不开（原生库缺 / 路径坏）：start 不抛，那份标成出错，服务照常起', () async {
    final Directory bad = Directory(p.join(tmp.path, 'not-a-dir'));
    File(bad.path).writeAsStringSync('this is a file, not a directory');
    final ServerSrs broken = ServerSrs(
      // RWKV 权重不联网下载（下载当场失败 = RWKV 没就绪）。
      rwkvHttpClient: noNetworkHttpClient,
      support: bad,
      syncData: syncData,
      deviceId: 'server-device',
      hostId: kHostId,
      config: () => const ServerSrsConfig(profiles: <String>[kJa]),
      engine: () => null,
    );
    addTearDown(broken.stop);
    await broken.start();
    expect(broken.profile(kJa)?.state, ServerSrsProfileState.failed);
    expect(broken.profile(kJa)?.lastError, contains('srs.db'));
    expect(broken.remoteStore, isNull);
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
    // 每轮发布说明文件只读自己绑定的那一个目录（不把整棵同步根重读一遍）。
    expect(
      (await srsListRemoteProfiles(
        LocalDirectoryAssetStore(srs.syncRoot),
        onlyDirs: <String>{ja.sync2Dir!},
      )).map((SrsRemoteProfile r) => r.uid),
      <String>[ja.sync2Dir!],
    );
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

  // BUG-4286：状态里的笔记数是打开时从同步位置读的设备报数，之后服务端加卡 / 设备再同步都不变。
  test('note count follows the served store after server writes and device '
      'uploads', () async {
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    await addNote(ja, '食べる');
    expect((await phoneSync(ja)).error, isNull);
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.start();
    await srs.syncNow();
    int notes() => srs.profile(kJa)!.toJson(isDefault: true)['notes']! as int;
    expect(notes(), 1);

    // 服务端自己写（AnkiConnect / 互联制卡）。
    await addNote(srs.storeFor(kJa)!, '飲む');
    await srs.syncNow(kJa);
    expect(notes(), 2);

    // 设备又加一张同步进来。
    await addNote(ja, '走る');
    expect((await phoneSync(ja)).error, isNull);
    await srs.syncNow(kJa);
    expect(notes(), 3);

    // 重新套用配置（WebUI 保存）：设备报的旧数不覆盖库里的数。
    await srs.applyConfig();
    expect(notes(), 3);
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
    expect(
      await srs.onClientWrite(
        'fushi-data/fushi-srs/$kJa/v4/devices/x/seg-1.bin',
      ),
      <String>[kJa],
    );
    expect(await srs.onClientWrite('fushi-data/books/whatever.epub'), isEmpty);
    expect(await changed.timeout(const Duration(seconds: 20)), kJa);
    expect(await expressions(srs.storeFor(kJa)!), <String>['飲む']);
  });

  // 第六波服务端收尾：无头服务端以前不发布 profile 说明文件，只有服务端写过的新代集合在别的设备的关联列表 /
  // WebUI 里没有名字与笔记数。
  test('服务端发布自己的 profile 说明文件：笔记数向内核要，名字取管理员起的 / 别的设备报的 / 自己上次发布的', () async {
    await srs.stop();
    srs = ServerSrs(
      rwkvHttpClient: noNetworkHttpClient,
      support: support,
      syncData: syncData,
      deviceId: 'server-device',
      hostId: kHostId,
      config: () => config,
      engine: () => null,
      deviceName: () => 'NAS',
    );
    // 几份说明文件之间怎么挑名字不看目录列举顺序（[serverSrsPickReportedName]，两种顺序在下面的单测里各跑一遍）；
    // 这里只测装配：管理员起名、设备报名、设备改名、外来名字过滤、设备离开后沿用。
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.start();
    await srs.syncNow();
    final SrsDbStore served = srs.storeFor(kJa)!;
    // 手机只同步、不发布说明文件：位置目录里没有任何名字。
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    await addNote(ja, '食べる');
    expect((await phoneSync(ja)).error, isNull);
    await srs.syncNow(kJa);
    final String dir = served.sync2Dir!;
    final String serverWriter = srsV2WriterName(served.sync2Device!);
    final LocalDirectoryAssetStore assets = LocalDirectoryAssetStore(
      srs.syncRoot,
    );
    Future<SrsRemoteProfile> listed() async => (await srsListRemoteProfiles(
      assets,
    )).singleWhere((SrsRemoteProfile r) => r.uid == dir);
    Future<Map<String, Object?>> ownFile() async {
      final File f = File(
        p.join(
          srs.syncRoot.path,
          kSrsSync2Namespace,
          dir,
          'v4',
          'devices',
          served.sync2Device!,
          kSrsProfileInfoName,
        ),
      );
      return (jsonDecode(await f.readAsString()) as Map)
          .cast<String, Object?>();
    }

    // 没有任何名字来源：照样发布（笔记数、有数据、设备名），名字空。
    SrsRemoteProfile r = await listed();
    expect(r.writers, contains(serverWriter));
    expect(r.noteCount, 1);
    expect(r.hasNotes, isTrue);
    expect(r.devices, contains('NAS'));
    expect(r.names, isEmpty);
    expect(srs.profile(kJa)!.name, '');

    // 服务端自己写了一张：下一轮发布的笔记数跟着内核走。
    await addNote(served, '飲む');
    await srs.syncNow(kJa);
    expect((await ownFile())['notes'], 2);

    // 管理员起名：发布出去，WebUI / 远程复习列表也用它。
    config = const ServerSrsConfig(
      profiles: <String>[kJa],
      profileNames: <String, String>{kJa: '日本語'},
    );
    await srs.applyConfig();
    await srs.syncNow(kJa);
    expect((await listed()).names, <String>{'日本語'});
    expect(srs.profile(kJa)!.name, '日本語');

    // 去掉管理员的名字，手机报了名字：取手机报的（不拿自己那份旧名字当来源）。
    Future<void> phoneNames(String name) => srsPublishProfileInfo(
      assets,
      profileUid: kJa,
      dir: ja.sync2Dir,
      writerId: ja.sync2Device!,
      name: name,
      hasNotes: true,
    );
    await phoneNames('Japanese');
    final SrsRemoteProfile both = await listed();
    expect(both.nameOf, <String, String>{
      serverWriter: '日本語',
      srsV2WriterName(ja.sync2Device!): 'Japanese',
    });
    // 挑名字按说明文件的修改时刻：每个报了名字的写入者都要带上时刻（本地目录给得出）。
    expect(both.nameAtOf.keys.toSet(), both.nameOf.keys.toSet());
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.applyConfig();
    await srs.syncNow(kJa);
    expect(srs.profile(kJa)!.name, 'Japanese');
    expect((await ownFile())['name'], 'Japanese');

    // 手机改名：服务端跟着改。
    await phoneNames('JP');
    await addNote(served, '走る');
    await srs.syncNow(kJa);
    expect((await ownFile())['name'], 'JP');
    expect((await listed()).names, <String>{'JP'});

    // 设备报的名字是外来输入：超长 / 带控制字符的不采用（与管理员起名同一个口径），服务端沿用自己上次发布的。
    for (final String bad in <String>['J\u0007P', 'x' * 101]) {
      await phoneNames(bad);
      await srs.syncNow(kJa);
      expect(srs.profile(kJa)!.name, 'JP', reason: bad);
      expect((await ownFile())['name'], 'JP', reason: bad);
    }

    // 手机离开（删了自己的说明文件）：名字靠服务端上次发布的那份留着。
    await srsRemoveOwnProfileFolder(
      assets,
      profileUid: kJa,
      dir: ja.sync2Dir,
      deviceId: 'phone-ja',
      v2Device: ja.sync2Device,
    );
    await srs.applyConfig();
    await srs.syncNow(kJa);
    r = await listed();
    expect(r.writers, <String>[serverWriter]);
    expect(r.names, <String>{'JP'});
    expect(srs.profile(kJa)!.name, 'JP');
  });

  test('写入按绑定的位置目录找 profile：目录名不当 uid，坏路径与没提供的 profile 不叫醒（G10-4）', () async {
    config = const ServerSrsConfig(profiles: <String>[kJa, kZh]);
    await srs.start();
    await srs.syncNow();
    final SrsDbStore ja = srs.storeFor(kJa)!;
    const String ns = 'fushi-data/fushi-srs';
    expect(await srs.onClientWrite('$ns/$kJa/v4/meta.json'), <String>[kJa]);
    expect(await srs.onClientWrite('$ns/$kZh/v4/meta.json'), <String>[kZh]);

    // kJa 并入位置目录 `0000-home` 上的集合：之后那个目录的写入叫醒它，它原来的 uid 目录不再算它的。
    final Map<String, Object?> joined =
        (await ja.sync2Command(<String, Object?>{
          'op': 'collection_join',
          'into': '0193a1b2-0000-7000-8000-0000000000aa',
          'dir': '0000-home',
          'now': ja.now().$1,
        })).map;
    expect(joined['outcome'], 'joined', reason: '$joined');
    expect(await srs.onClientWrite('$ns/0000-home/v4/meta.json'), <String>[
      kJa,
    ]);
    expect(await srs.onClientWrite('$ns/$kJa/v4/meta.json'), isEmpty);

    // 补充名同样按绑定的目录：落在 kJa 绑定目录里的段补上（再补同名 = 没变），没人绑的目录里的段不碰库。
    Future<bool?> hinted(String device, String name) async =>
        (await ja.sync2Command(<String, Object?>{
              'op': 'device_hint',
              'device': device,
              'hint': name,
            })).map['changed']
            as bool?;
    const String dev = '0194b0c1-3333-7444-8555-666677778888';
    const String stranger = '0194b0c1-3333-7444-8555-666677779999';
    const String seg = 'seg-000000000001-000000000002-c3c3c3c3.bin';
    await srs.onClientUpload('$ns/0000-home/v4/devices/$dev/$seg', 'Pixel');
    expect(await hinted(dev, 'Pixel'), isFalse);
    await srs.onClientUpload('$ns/zz-nobody/v4/devices/$stranger/$seg', 'Evil');
    expect(await hinted(stranger, 'Evil'), isTrue);

    // 对端写的路径不可信：坏目录名（内核拒绝）、空段、`..`、别的命名空间一律不叫醒任何一份。
    for (final String bad in <String>[
      '$ns/${'a' * 300}/v4/meta.json',
      '$ns//v4/meta.json',
      '$ns/../$kJa/v4/meta.json',
      '$ns/.',
      'fushi-data/books/$kJa/v4/meta.json',
    ]) {
      expect(await srs.onClientWrite(bad), isEmpty, reason: bad);
    }

    // 绑定还在库里、但管理员不再提供的 profile 不叫醒。
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.applyConfig();
    expect(await srs.onClientWrite('$ns/$kZh/v4/meta.json'), isEmpty);
  });

  test('远程复习的「今天」按客户端带来的偏移算；不带时按服务端时区', () async {
    final SrsDbStore ja = await phone(kJa, 'phone-ja');
    await addNote(ja, '食べる');
    await phoneSync(ja);
    config = const ServerSrsConfig(profiles: <String>[kJa]);
    await srs.start();
    await srs.syncNow();

    final SrsRemoteStoreService remote = srs.remoteStore!;
    final int hostOff = SrsDayContext.localOffsetMin();
    final int off = hostOff == -300 ? 330 : -300;
    Future<int> offsetOf(Map<String, Object?> body) async =>
        SrsRemoteWire.dayContextFrom(
          (await _call(remote, body))['result'],
        ).utcOffsetMin;
    expect(
      await offsetOf(<String, Object?>{
        'op': 'dayContext',
        'profile': kJa,
        kSrsRemoteDeviceOffsetKey: off,
      }),
      off,
    );
    expect(
      await offsetOf(<String, Object?>{'op': 'dayContext', 'profile': kJa}),
      hostOff,
    );
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
        Uri.parse('http://host/api/srs/remote2/call'),
        body: jsonEncode(<String, Object?>{
          'g': 4,
          'op': 'hello',
          'profile': kJa,
        }),
      ),
      'POST',
      '/api/srs/remote2/call',
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
      Uri.parse('http://host/api/srs/remote2/call'),
      body: jsonEncode(<String, Object?>{'g': 4, ...body}),
    ),
    'POST',
    '/api/srs/remote2/call',
  );
  expect(res.statusCode, 200);
  return (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();
}
