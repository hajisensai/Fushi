import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_relay.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 内存版资产层：一个命名空间 = 一个 name → bytes 的表。两台「设备」共用一个实例，
/// 就是它们共用的同步后端。
class _MemoryAssets implements SyncAssetStore {
  final Map<String, Map<String, List<int>>> spaces =
      <String, Map<String, List<int>>>{};

  Map<String, List<int>> _ns(String id) =>
      spaces.putIfAbsent(id, () => <String, List<int>>{});

  Set<String> names(String ns) => _ns(ns).keys.toSet();

  @override
  Future<String> ensureNamespace(String name) async {
    _ns(name);
    return name;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      <AssetEntry>[
        for (final String n in _ns(namespaceId).keys)
          AssetEntry(id: '$namespaceId/$n', name: n),
      ];

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    final int cut = assetId.indexOf('/');
    final List<int>? bytes = _ns(
      assetId.substring(0, cut),
    )[assetId.substring(cut + 1)];
    return bytes == null ? null : jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    _ns(namespaceId)[name] = utf8.encode(jsonEncode(json));
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    final int cut = id.indexOf('/');
    _ns(id.substring(0, cut)).remove(id.substring(cut + 1));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 落地设备本机的 Anki：记下收到的词，全部成功。
class _Anki implements BaseAnkiRepository {
  final List<String> added = <String>[];

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  bool get switchesAppPerNote => false;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final Map<String, Object?> fields =
        jsonDecode(rawPayloadJson) as Map<String, Object?>;
    added.add(
      '${fields['expression']}|${context.coverPath == null ? '' : File(context.coverPath!).readAsStringSync()}',
    );
    return const MineOutcome.success(deckName: 'd');
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 一台设备：自己的库、自己的载荷目录、自己的 deviceId。
class _Device {
  _Device(this.id, Directory tmp)
    : db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      ) {
    store = PendingMineStore(
      db: () => db,
      root: () async =>
          Directory('${tmp.path}/$id/${PendingMineStore.dirName}'),
    );
  }

  final String id;
  final FushiDatabase db;
  late final PendingMineStore store;

  PendingMineRelay relay({int landingClaimedAt = 0}) => PendingMineRelay(
    store: store,
    deviceId: id,
    deviceName: 'name-$id',
    landingClaimedAt: landingClaimedAt,
  );

  /// 没装 Anki 的设备在批量模式下制一张卡（封面临时文件随后即删）。
  Future<void> mineOffline(Directory tmp, String word) async {
    final File cover = File('${tmp.path}/cover_${id}_$word.jpg')
      ..writeAsStringSync('cover-$word');
    await PendingMiningAnkiRepository(
      inner: _BatchOnly(),
      store: store,
      payloadBuilder: ForwardedMinePayloadBuilder(
        dictMediaLoader: (String d, String p) => null,
      ),
    ).mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{'expression': word}),
      context: AnkiMiningContext(sentence: 's', coverPath: cover.path),
    );
    cover.deleteSync();
  }

  /// 本机补发（落地设备交给本机 Anki）。
  Future<void> flushInto(_Anki anki) =>
      PendingMiningAnkiRepository(inner: anki, store: store).flush();
}

/// 批量模式、没有 Anki 的后端：mineEntry 永远不该被调到。
class _BatchOnly implements BaseAnkiRepository {
  @override
  Future<AnkiSettings> loadSettings() async =>
      const AnkiSettings(batchMiningEnabled: true);

  @override
  bool get switchesAppPerNote => false;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory tmp;
  late _MemoryAssets assets;
  late _Device eink;
  late _Device phone;

  setUp(() async {
    PendingMiningAnkiRepository.debugReset();
    tmp = await Directory.systemTemp.createTemp('pending_mine_relay');
    assets = _MemoryAssets();
    eink = _Device('eink', tmp);
    phone = _Device('phone', tmp);
  });

  tearDown(() async {
    await eink.db.close();
    await phone.db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  const String ns = PendingMineRelay.namespace;

  test('没有任何设备认领落地时，制卡设备什么都不上传', () async {
    await eink.mineOffline(tmp, '猫');
    final PendingMineRelayReport r = await eink.relay().run(assets);

    expect(r.uploaded, 0);
    expect(assets.names(ns), isEmpty);
    expect(await eink.store.count(), 1, reason: '卡留在本机队列');
  });

  test('全流程：上传 → 落地设备收下并交给 Anki → 回执 → 制卡设备出队', () async {
    await eink.mineOffline(tmp, '猫');
    await eink.mineOffline(tmp, '犬');

    // 手机打开「本机落地」，同步一轮：写认领。
    await phone.relay(landingClaimedAt: 100).run(assets);
    expect(assets.names(ns), <String>{PendingMineRelay.landingFile});

    // 墨水屏同步：看到认领，上传两张。
    final PendingMineRelayReport up = await eink.relay().run(assets);
    expect(up.uploaded, 2);
    expect(assets.names(ns).length, 3);
    // 再同步一轮不重复上传。
    expect((await eink.relay().run(assets)).uploaded, 0);

    // 手机同步：收下两张，并通知补发。
    final Future<int> arrived = PendingMineRelay.arrivals.first;
    final PendingMineRelayReport down = await phone
        .relay(landingClaimedAt: 100)
        .run(assets);
    expect(down.received, 2);
    expect(await arrived, 2);
    expect(await phone.store.count(), 2);

    // 手机交给本机 Anki：媒体随卡过来了。
    final _Anki anki = _Anki();
    await phone.flushInto(anki);
    expect(anki.added, <String>['猫|cover-猫', '犬|cover-犬']);
    expect(await phone.store.count(), 0, reason: '已落地的不再显示为待发');

    // 手机下一轮：写回执、撤记录、删本地行。
    final PendingMineRelayReport ack = await phone
        .relay(landingClaimedAt: 100)
        .run(assets);
    expect(ack.acknowledged, 2);
    expect(await phone.store.rows(), isEmpty);
    expect(
      assets.names(ns).where((String n) => n.endsWith('.landed.json')).length,
      2,
    );

    // 墨水屏下一轮：看到回执，出队并清掉回执。
    final PendingMineRelayReport done = await eink.relay().run(assets);
    expect(done.acknowledged, 2);
    expect(await eink.store.rows(), isEmpty);
    expect(assets.names(ns), <String>{PendingMineRelay.landingFile});

    // 落地设备再同步也不会重落。
    await phone.relay(landingClaimedAt: 100).run(assets);
    await phone.flushInto(anki);
    expect(anki.added, hasLength(2));
  });

  test('认领按时刻后者胜；先认领的设备不再收新卡', () async {
    final _Device laptop = _Device('laptop', tmp);
    addTearDown(laptop.db.close);

    await phone.relay(landingClaimedAt: 100).run(assets);
    await laptop.relay(landingClaimedAt: 200).run(assets);
    // 手机的认领更早：不能把笔记本的认领抢回来。
    await phone.relay(landingClaimedAt: 100).run(assets);
    final Object? claim = await assets.getJsonAsset(
      '$ns/${PendingMineRelay.landingFile}',
    );
    expect((claim! as Map<String, Object?>)['deviceId'], 'laptop');

    await eink.mineOffline(tmp, '鳥');
    await eink.relay().run(assets);
    expect((await phone.relay(landingClaimedAt: 100).run(assets)).received, 0);
    expect((await laptop.relay(landingClaimedAt: 200).run(assets)).received, 1);
  });

  test('制卡设备自己先交给了 Anki：撤掉远端记录，落地设备不再落', () async {
    await phone.relay(landingClaimedAt: 100).run(assets);
    await eink.mineOffline(tmp, '魚');
    await eink.relay().run(assets);

    // 墨水屏这时连上了自己的 Anki，直接补发成功。
    await eink.flushInto(_Anki());
    expect(await eink.store.count(), 0);
    await eink.relay().run(assets);
    expect(
      assets.names(ns).where((String n) => n != PendingMineRelay.landingFile),
      isEmpty,
    );

    expect((await phone.relay(landingClaimedAt: 100).run(assets)).received, 0);
  });

  test('用户在制卡设备上删掉已上传的卡：远端记录一并撤掉', () async {
    await phone.relay(landingClaimedAt: 100).run(assets);
    await eink.mineOffline(tmp, '虫');
    await eink.relay().run(assets);

    await eink.store.discard((await eink.store.all()).single);
    expect(await eink.store.count(), 0);
    await eink.relay().run(assets);

    expect(await eink.store.rows(), isEmpty);
    expect((await phone.relay(landingClaimedAt: 100).run(assets)).received, 0);
  });
}
