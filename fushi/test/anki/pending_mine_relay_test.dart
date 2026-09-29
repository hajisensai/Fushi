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

/// 内存版资产层：一个命名空间 = 一个 name → bytes 的表。几台「设备」共用一个实例，
/// 就是它们共用的同步后端。记下请求数，并可让指定资产读取失败（模拟超限 / 坏文件）。
class _MemoryAssets implements SyncAssetStore {
  final Map<String, Map<String, List<int>>> spaces =
      <String, Map<String, List<int>>>{};
  int calls = 0;
  final Set<String> unreadable = <String>{};

  Map<String, List<int>> _ns(String id) =>
      spaces.putIfAbsent(id, () => <String, List<int>>{});

  Set<String> names(String ns) =>
      (spaces[ns] ?? const <String, List<int>>{}).keys.toSet();

  @override
  Future<String> ensureNamespace(String name) async {
    calls++;
    _ns(name);
    return name;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    calls++;
    return <AssetEntry>[
      for (final String n in _ns(namespaceId).keys)
        AssetEntry(id: '$namespaceId/$n', name: n),
    ];
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    calls++;
    final int cut = assetId.indexOf('/');
    final String name = assetId.substring(cut + 1);
    if (unreadable.contains(name)) throw StateError('too large: $name');
    final List<int>? bytes = _ns(assetId.substring(0, cut))[name];
    return bytes == null ? null : jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    calls++;
    _ns(namespaceId)[name] = utf8.encode(jsonEncode(json));
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    calls++;
    final int cut = id.indexOf('/');
    _ns(id.substring(0, cut)).remove(id.substring(cut + 1));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 落地设备本机的 Anki：记下收到的词（连同封面内容），全部成功。
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
    final String? cover = context.coverPath;
    added.add(
      '${fields['expression']}|${cover == null ? '' : File(cover).readAsStringSync()}',
    );
    return const MineOutcome.success(deckName: 'd');
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
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

/// 一台设备：自己的库、自己的载荷目录、自己的 deviceId。
class _Device {
  _Device(this.id, this.tmp)
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
  final Directory tmp;
  final FushiDatabase db;
  late final PendingMineStore store;

  PendingMineRelay relay({int landing = 0}) => PendingMineRelay(
    store: store,
    deviceId: id,
    deviceName: 'name-$id',
    landingClaimedAt: landing,
  );

  /// 没装 Anki 的设备在批量模式下制一张卡（封面临时文件随后即删）。
  Future<void> mineOffline(String word, {String cover = ''}) async {
    final File f = File('${tmp.path}/cover_${id}_$word.jpg')
      ..writeAsStringSync(cover.isEmpty ? 'cover-$word' : cover);
    await PendingMiningAnkiRepository(
      inner: _BatchOnly(),
      store: store,
      payloadBuilder: ForwardedMinePayloadBuilder(
        dictMediaLoader: (String d, String p) => null,
      ),
    ).mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{'expression': word}),
      context: AnkiMiningContext(sentence: 's', coverPath: f.path),
    );
    f.deleteSync();
  }

  /// 本机补发（交给本机 Anki）。
  Future<void> flushInto(_Anki anki) =>
      PendingMiningAnkiRepository(inner: anki, store: store).flush();
}

void main() {
  late Directory tmp;
  late _MemoryAssets assets;
  late _Device eink;
  late _Device phone;
  const String ns = PendingMineRelay.namespace;

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

  Iterable<String> records() => assets
      .names(ns)
      .where(
        (String n) => !n.startsWith('landing.') && !n.contains('.landed.'),
      );

  test('没开落地、也没有待发卡：一个请求都不发', () async {
    final PendingMineRelayReport r = await phone.relay().run(assets);
    expect(r.uploaded + r.received + r.acknowledged, 0);
    expect(assets.calls, 0);
    expect(assets.spaces, isEmpty, reason: '连中转目录都不建');
  });

  test('没有任何设备认领落地：制卡设备只看一眼，不上传', () async {
    await eink.mineOffline('猫');
    final PendingMineRelayReport r = await eink.relay().run(assets);

    expect(r.uploaded, 0);
    expect(assets.names(ns), isEmpty);
    expect(await eink.store.count(), 1, reason: '卡留在本机队列');
  });

  test('全流程：上传 → 落地设备收下并交给 Anki → 回执 → 制卡设备出队', () async {
    await eink.mineOffline('猫');
    await eink.mineOffline('犬');

    await phone.relay(landing: 100).run(assets);
    expect(assets.names(ns), <String>{'landing.phone.json'});

    expect((await eink.relay().run(assets)).uploaded, 2);
    expect(records(), hasLength(2));
    expect((await eink.relay().run(assets)).uploaded, 0, reason: '不重复上传');

    final Future<int> arrived = PendingMineRelay.arrivals.first;
    expect((await phone.relay(landing: 100).run(assets)).received, 2);
    expect(await arrived, 2);

    final _Anki anki = _Anki();
    await phone.flushInto(anki);
    expect(anki.added, <String>['猫|cover-猫', '犬|cover-犬']);
    expect(await phone.store.count(), 0, reason: '已落地的不再显示为待发');

    expect((await phone.relay(landing: 100).run(assets)).acknowledged, 2);
    expect(await phone.store.rows(), isEmpty);
    expect(records(), isEmpty);

    expect((await eink.relay().run(assets)).acknowledged, 2);
    expect(await eink.store.rows(), isEmpty);
    expect(assets.names(ns), <String>{'landing.phone.json'});

    await phone.relay(landing: 100).run(assets);
    await phone.flushInto(anki);
    expect(anki.added, hasLength(2), reason: '落地设备不会重落');
  });

  test('关掉「本机落地」即撤销认领：之后没人收，制卡设备不再上传', () async {
    await phone.relay(landing: 100).run(assets);
    // 开关关了但本机没卡：不碰远端。
    await phone.relay().run(assets);
    expect(assets.names(ns), contains('landing.phone.json'));

    // 本机有卡要中转时顺带撤掉遗留认领。
    await phone.mineOffline('鳥');
    await phone.relay().run(assets);
    expect(assets.names(ns), isNot(contains('landing.phone.json')));

    await eink.mineOffline('魚');
    expect((await eink.relay().run(assets)).uploaded, 0);
  });

  test('认领按时刻后者胜；更早认领的设备不收新卡', () async {
    final _Device laptop = _Device('laptop', tmp);
    addTearDown(laptop.db.close);

    await phone.relay(landing: 100).run(assets);
    await laptop.relay(landing: 200).run(assets);
    await eink.mineOffline('鳥');
    await eink.relay().run(assets);

    expect((await phone.relay(landing: 100).run(assets)).received, 0);
    expect((await laptop.relay(landing: 200).run(assets)).received, 1);
  });

  test('落地设备易主：老设备手上还没交的卡交出去，由新落地设备收，不会各落一次', () async {
    final _Device laptop = _Device('laptop', tmp);
    addTearDown(laptop.db.close);

    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('蛙');
    await eink.relay().run(assets);
    expect((await phone.relay(landing: 100).run(assets)).received, 1);

    // 手机的 Anki 离线，用户改让笔记本落地：笔记本认领的这一轮就从远端记录收下。
    expect((await laptop.relay(landing: 200).run(assets)).received, 1);
    await phone.relay(landing: 100).run(assets);
    expect(await phone.store.rows(), isEmpty, reason: '老落地设备交出');

    final _Anki phoneAnki = _Anki();
    await phone.flushInto(phoneAnki);
    final _Anki laptopAnki = _Anki();
    await laptop.flushInto(laptopAnki);
    expect(phoneAnki.added, isEmpty);
    expect(laptopAnki.added, hasLength(1));
  });

  test('一张读不出的卡（超限 / 坏文件）不挡住其余的卡', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('壊');
    await eink.mineOffline('良');
    await eink.relay().run(assets);
    final String bad = records().firstWhere(
      (String n) =>
          (jsonDecode(utf8.decode(assets.spaces[ns]![n]!))
              as Map<String, Object?>)['expression'] ==
          '壊',
    );
    assets.unreadable.add(bad);

    final PendingMineRelayReport r = await phone
        .relay(landing: 100)
        .run(assets);
    expect(r.received, 1);
    expect(r.errors, hasLength(1));
    expect(
      (await phone.store.all()).map((PendingMineRow row) => row.expression),
      <String>['良'],
    );
  });

  test('超过上限的卡不走中转，留在本机并说明原因', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline(
      '巨',
      cover: 'x' * (PendingMineRelay.maxRecordBytes + 1),
    );

    expect((await eink.relay().run(assets)).uploaded, 0);
    expect(records(), isEmpty);
    final PendingMineRow row = (await eink.store.all()).single;
    expect(row.status, PendingMineStatus.failed);
    expect(row.lastError, contains('Too large'));
  });

  test('制卡设备上传前自己先交给了 Anki：不再上传，落地设备不落', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('魚');

    final _Anki einkAnki = _Anki();
    await eink.flushInto(einkAnki);
    expect(einkAnki.added, hasLength(1));
    expect(await eink.store.rows(), isEmpty);
    expect((await eink.relay().run(assets)).uploaded, 0);
    expect(records(), isEmpty);
    expect((await phone.relay(landing: 100).run(assets)).received, 0);
  });

  test('BUG-2778：已上传到中转的卡本机不再补发，只由落地设备落一次', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('魚');
    expect((await eink.relay().run(assets)).uploaded, 1);

    final _Anki einkAnki = _Anki();
    await eink.flushInto(einkAnki);
    expect(einkAnki.added, isEmpty, reason: '已交给落地设备，本机不补发');
    expect(await eink.store.sendable(), isEmpty);
    expect(await eink.store.count(), 1, reason: '等回执才出队');

    await phone.relay(landing: 100).run(assets);
    final _Anki phoneAnki = _Anki();
    await phone.flushInto(phoneAnki);
    expect(phoneAnki.added, hasLength(1));

    await phone.relay(landing: 100).run(assets);
    await eink.relay().run(assets);
    await eink.flushInto(einkAnki);
    expect(einkAnki.added, isEmpty);
    expect(await eink.store.rows(), isEmpty);
  });

  test('BUG-2778：本机补发已认领（sending）的卡不会再被上传', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('鴨');
    final PendingMineRow row = (await eink.store.all()).single;
    expect(await eink.store.markSending(row.id), isTrue);

    expect((await eink.relay().run(assets)).uploaded, 0);
    expect(records(), isEmpty);
    expect(await eink.store.markUploaded(row.id), isFalse);
  });

  test('BUG-2778：制卡设备改当落地设备——撤回远端记录，交回本机补发', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('鶴');
    await eink.relay().run(assets);
    expect(records(), hasLength(1));

    // eink 后认领，成了落地设备。
    await eink.relay(landing: 200).run(assets);
    expect(records(), isEmpty, reason: '远端记录撤回');
    expect((await eink.store.all()).single.uploaded, isFalse);

    final _Anki einkAnki = _Anki();
    await eink.flushInto(einkAnki);
    expect(einkAnki.added, hasLength(1));
    expect((await phone.relay(landing: 100).run(assets)).received, 0);
  });

  test('BUG-2778：远端文件名当 id——恶意 id（../x 等）被拒，不写出载荷目录', () async {
    await phone.relay(landing: 100).run(assets);
    Map<String, Object?> body(String id) => <String, Object?>{
      'id': id,
      'createdAt': 1,
      'expression': '毒',
      'reading': '',
      'originDeviceId': 'attacker',
      'payload': <String, Object?>{
        'rawPayloadJson': '{"expression":"毒"}',
        'sentence': '',
      },
    };
    for (final String id in <String>[
      '../x',
      '..',
      r'..\x',
      'a/b',
      'x' * 129,
      '',
    ]) {
      assets.spaces[ns]!['$id.json'] = utf8.encode(jsonEncode(body(id)));
    }

    final PendingMineRelayReport r = await phone
        .relay(landing: 100)
        .run(assets);
    expect(r.received, 0);
    expect(await phone.store.rows(), isEmpty);
    expect(File('${tmp.path}/phone/x.json').existsSync(), isFalse);
    expect(PendingMineStore.isValidId('../x'), isFalse);
    expect(PendingMineStore.isValidId(PendingMineStore.newId()), isTrue);
    await expectLater(
      phone.store.insertRemote(
        id: '../x',
        createdAt: 1,
        expression: '毒',
        reading: '',
        originDeviceId: 'attacker',
        payloadJson: '{}',
      ),
      throwsArgumentError,
    );
  });

  test('BUG-2778：同一张卡经两条同步通道各传一份，落地设备只落一次', () async {
    final _MemoryAssets drive = assets;
    final _MemoryAssets webdav = _MemoryAssets();
    await phone.relay(landing: 100).run(drive);
    await phone.relay(landing: 100).run(webdav);

    await eink.mineOffline('狐');
    expect((await eink.relay().run(drive)).uploaded, 1);
    // 第二条通道看到「上传过但这里没有记录」，再传一份。
    expect((await eink.relay().run(webdav)).uploaded, 1);

    final _Anki phoneAnki = _Anki();
    expect((await phone.relay(landing: 100).run(drive)).received, 1);
    await phone.flushInto(phoneAnki);
    expect(phoneAnki.added, hasLength(1));
    await phone.relay(landing: 100).run(drive); // 回执、删行

    // 另一条通道再见到同 id：墓碑拦下，只写回执、撤记录。
    final PendingMineRelayReport second = await phone
        .relay(landing: 100)
        .run(webdav);
    expect(second.received, 0);
    expect(second.acknowledged, 1);
    await phone.flushInto(phoneAnki);
    expect(phoneAnki.added, hasLength(1), reason: '不重复落地');
    expect(
      webdav
          .names(ns)
          .where(
            (String n) => !n.startsWith('landing.') && !n.contains('.landed.'),
          ),
      isEmpty,
    );
    expect(await phone.store.rows(), isEmpty);
  });

  test('用户在制卡设备上删掉已上传的卡：远端记录一并撤掉', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('虫');
    await eink.relay().run(assets);

    await eink.store.discard((await eink.store.all()).single);
    expect(await eink.store.count(), 0);
    await eink.relay().run(assets);

    expect(await eink.store.rows(), isEmpty);
    expect((await phone.relay(landing: 100).run(assets)).received, 0);
  });

  test('补发拿着过期快照（上传前读的行）送达：以库里此刻为准，不直接删行', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('馬');
    final PendingMineRow stale = (await eink.store.all()).single;
    expect(stale.uploaded, isFalse);
    await eink.relay().run(assets); // 期间中转上传了它

    await eink.store.markDelivered(stale);
    expect(
      (await eink.store.rows()).single.status,
      PendingMineStatus.landed,
      reason: '远端还有一份，得留着去撤',
    );

    await eink.relay().run(assets);
    expect(records(), isEmpty);
    expect(await eink.store.rows(), isEmpty);
  });

  test('回执处理到一半被杀（行已标 landed、远端没清完）：下一轮收敛', () async {
    await phone.relay(landing: 100).run(assets);
    await eink.mineOffline('羊');
    await eink.relay().run(assets);
    await phone.relay(landing: 100).run(assets);
    await phone.flushInto(_Anki());
    await phone.relay(landing: 100).run(assets); // 写回执

    // 模拟：制卡设备已把行标 landed（先落库的意图），随后进程被杀。
    await eink.store.markDelivered((await eink.store.all()).single);
    await eink.relay().run(assets);

    expect(await eink.store.rows(), isEmpty);
    expect(assets.names(ns), <String>{'landing.phone.json'});
  });
}
