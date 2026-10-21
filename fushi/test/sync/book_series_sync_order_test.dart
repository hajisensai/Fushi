import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

/// BUG-3652：书系列合集的卷序在同步里收敛。
///
/// 原路径：书架归组（`BookSeriesGrouper._healSeriesOrder`）把错序的系列合集按卷号
/// 重排，但（刻意）不动 orderUpdatedAt；下一轮同步两端都为 0 → 平手取远端 → 远端
/// 旧错序整表覆盖本机、再发布出去；下次打开书架又自愈，再同步又被冲回——顺序
/// 永远来回翻，正确顺序传不上共享清单。书的 wire 成员键不带书名，合并引擎自己排
/// 不了，所以由持有书架的一端在合并时注入同一判据（[loadBookSeriesRuleOrder]）。
const String _dm = '絶対に働きたくないダンジョンマスターが惰眠をむさぼるまで';
const String _name = 'ダンマス';

/// 用户原样书名：1、2 卷是全角空格 + 全角数字，3 卷起半角。bookKey = 书名 = wire 键。
final List<String> _volumeOrder = <String>[
  '$_dm　１',
  '$_dm　２',
  for (int n = 3; n <= 17; n++) '$_dm $n',
];

/// 手动「建系列」按选择顺序尾插：3..17 在前，1、2 在最后。
final List<String> _wrongOrder = <String>[
  ..._volumeOrder.skip(2),
  ..._volumeOrder.take(2),
];

class _Device {
  _Device() : db = FushiDatabase.forTesting(NativeDatabase.memory());

  final FushiDatabase db;
  int baseline = 0;

  Future<void> addBooks(Iterable<String> titles) async {
    for (final String title in titles) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/b/$title',
          extractDir: '/b/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          format: const Value<String>('epub'),
        ),
      );
    }
  }

  /// 按 [bookKeys] 顺序建合集；本机有这本书用 uid，没有就是透传行（对端 bookKey）。
  Future<void> createCollection(List<String> bookKeys) async {
    final int id = await db.createMediaCollection(_name);
    for (final String key in bookKeys) {
      await db.addToCollection(
        id,
        MediaKind.epub,
        await db.resolveEpubBookUid(key) ?? key,
      );
    }
  }

  /// 合集成员按展示序，换成 bookKey（= 书名）。
  Future<List<String>> order() async {
    final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
      _name,
      'collection',
    );
    if (row == null) return const <String>[];
    final Map<String, String> keyByUid = <String, String>{
      for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.bookKey,
    };
    return <String>[
      for (final MediaCollectionItemRow i in await db.getCollectionItems(
        row.id,
      ))
        keyByUid[i.entryKey] ?? i.entryKey,
    ];
  }

  Future<int> orderUpdatedAt() async =>
      (await db.getMediaCollectionByNaturalKey(
        _name,
        'collection',
      ))!.orderUpdatedAt;

  /// 一轮读-合并-应用-发布（与三个同步入口同一组调用）；返回本端改写的合集数。
  Future<int> mergeWith(
    CollectionManifest remote,
    void Function(CollectionManifest merged) publish,
  ) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: await loadLocalCollectionManifest(db),
      remote: remote,
      lastSyncedAtMs: baseline,
      nowMs: now,
      ruleOrder: await loadBookSeriesRuleOrder(db),
    );
    final int changed = await applyCollectionLocalChanges(db, outcome.changes);
    publish(outcome.merged.withLastWrittenAt(now));
    baseline = now;
    return changed;
  }
}

List<String> _orderIn(CollectionManifest manifest) {
  final CollectionManifestEntry entry = manifest.collections.singleWhere(
    (CollectionManifestEntry e) => e.name == _name,
  );
  final List<CollectionManifestMember> members =
      List<CollectionManifestMember>.of(entry.members)..sort(
        (CollectionManifestMember a, CollectionManifestMember b) =>
            a.sortIndex.compareTo(b.sortIndex),
      );
  return <String>[for (final CollectionManifestMember m in members) m.entryKey];
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 3));

/// 互联 live 通道的假 host：GET 返回共享清单，POST 整份替换并计数。
class _FakeLiveHost extends InterconnectSyncBackend {
  _FakeLiveHost(this.manifest)
    : super.withProbe((String url, String token) async => true);

  CollectionManifest manifest;
  int puts = 0;

  @override
  Future<CollectionManifest?> getRemoteCollectionManifest() async => manifest;

  @override
  Future<CollectionManifest> putRemoteCollectionManifest(
    CollectionManifest m,
  ) async {
    puts++;
    manifest = m;
    return m;
  }
}

void main() {
  final List<_Device> devices = <_Device>[];
  _Device device() {
    final _Device d = _Device();
    devices.add(d);
    return d;
  }

  tearDown(() async {
    for (final _Device d in devices) {
      await d.db.close();
    }
    devices.clear();
  });

  /// 有全套书、合集按错序手建，打开书架时自愈成卷序；同时返回自愈**之前**发布
  /// 出去的错序清单（双方 orderUpdatedAt 都是 0）。
  Future<({_Device device, CollectionManifest stale})> healedDevice() async {
    final _Device d = device();
    await d.addBooks(_volumeOrder);
    await d.createCollection(_wrongOrder);
    final CollectionManifest stale = await loadLocalCollectionManifest(d.db);
    expect(_orderIn(stale), _wrongOrder);
    await BookSeriesGrouper(d.db).groupAll();
    expect(await d.order(), _volumeOrder, reason: '前提：书架归组已自愈');
    expect(await d.orderUpdatedAt(), 0, reason: '自愈不伪装成用户手动排序');
    return (device: d, stale: stale);
  }

  test('复现：不注入规则序时，平手取远端把自愈的卷序冲回旧错序', () async {
    final (:device, :stale) = await healedDevice();
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: await loadLocalCollectionManifest(device.db),
      remote: stale,
      lastSyncedAtMs: 0,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(_orderIn(outcome.merged), _wrongOrder, reason: '修复前发布出去的就是错序');
    expect(outcome.changes.isEmpty, isFalse, reason: '修复前本机卷序被改回错序');
  });

  test('本地自愈 → 同步合并远端错序（双方 orderUpdatedAt=0）→ 发布：落盘与发布都是卷序，'
      '再同步不写库', () async {
    final (:device, :stale) = await healedDevice();
    CollectionManifest published = stale;

    expect(
      await device.mergeWith(stale, (CollectionManifest m) => published = m),
      0,
      reason: '本机已是卷序，合并结果也是卷序，不写库',
    );
    expect(await device.order(), _volumeOrder);
    expect(_orderIn(published), _volumeOrder, reason: '共享清单拿到正确顺序');
    expect(await device.orderUpdatedAt(), 0);

    await _tick();
    final String before = published.canonicalJson();
    expect(
      await device.mergeWith(
        published,
        (CollectionManifest m) => published = m,
      ),
      0,
      reason: '收敛：第二轮不再写库',
    );
    expect(published.canonicalJson(), before, reason: '发布内容不再变化');
    expect(
      (await BookSeriesGrouper(device.db).groupAll()).updatedCollectionIds,
      isEmpty,
      reason: '书架重载不再需要自愈（不会来回翻）',
    );
  });

  test('单份共享清单：有书的对端收到卷序直接收敛，没书的对端照转卷序', () async {
    final (device: _Device healer, :stale) = await healedDevice();
    // 对端 B：同一套书、同一错序合集，还没打开过书架。
    final _Device b = device();
    await b.addBooks(_volumeOrder);
    await b.createCollection(_wrongOrder);
    // 对端 C：本机一本书都没有，合集全是透传行，自己定不了序。
    final _Device c = device();
    await c.createCollection(_wrongOrder);

    CollectionManifest shared = stale;
    Future<int> sync(_Device d) =>
        d.mergeWith(shared, (CollectionManifest m) => shared = m);

    expect(await sync(c), 0);
    expect(_orderIn(shared), _wrongOrder);
    await _tick();
    expect(await sync(healer), 0);
    expect(_orderIn(shared), _volumeOrder);
    await _tick();
    expect(await sync(c), 1, reason: '没书的对端平手取远端 = 卷序');
    await _tick();
    expect(await sync(b), 1);

    for (final _Device d in <_Device>[healer, b, c]) {
      expect(await d.order(), _volumeOrder);
    }
    for (int round = 0; round < 2; round++) {
      for (final _Device d in <_Device>[healer, b, c]) {
        await _tick();
        expect(await sync(d), 0, reason: '收敛后每端每轮零改写');
      }
    }
    expect(_orderIn(shared), _volumeOrder);
  });

  test('云通道 per-device 文件：陈旧的错序对端文件不再把有书的一端冲回', () async {
    final (device: _Device healer, stale: _) = await healedDevice();
    final _Device c = device();
    await c.createCollection(_wrongOrder);
    final Map<String, CollectionManifest> files =
        <String, CollectionManifest>{};
    Future<int> sync(String id, _Device d) => d.mergeWith(
      CollectionSyncEngine.combinePeers(files.values.toList()),
      (CollectionManifest m) => files[id] = m,
    );

    expect(await sync('c', c), 0);
    for (int round = 0; round < 3; round++) {
      await _tick();
      expect(await sync('healer', healer), 0, reason: '第 $round 轮');
      expect(await healer.order(), _volumeOrder);
      expect(_orderIn(files['healer']!), _volumeOrder);
    }
  });

  group('三个同步入口都按卷序合并', () {
    test('云通道 SyncOrchestrator.syncCollections', () async {
      final Directory work = await Directory.systemTemp.createTemp('bss_');
      addTearDown(() => work.delete(recursive: true));
      final FakeAssetStore store = FakeAssetStore();
      SyncOrchestrator orch(FushiDatabase db, String id) => SyncOrchestrator(
        db: db,
        backend: FakeSyncBackend(store),
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
        deviceId: id,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

      // 有书的一端合集还是错序（没打开过书架）：同步合并即按卷序落盘并发布。
      final _Device a = device();
      await a.addBooks(_volumeOrder);
      await a.createCollection(_wrongOrder);
      final SyncRunReport first = await orch(a.db, 'a').runCollectionsOnly();
      expect(first.errors, isEmpty);
      expect(await a.order(), _volumeOrder);

      // 没书的一端只能从共享清单拿顺序。
      final _Device e = device();
      expect((await orch(e.db, 'e').runCollectionsOnly()).errors, isEmpty);
      expect(await e.order(), _volumeOrder, reason: '发布出去的是卷序');

      await _tick();
      final SyncRunReport again = await orch(a.db, 'a').runCollectionsOnly();
      expect(again.collectionsUpdated, 0, reason: '收敛：再同步不写库');
    });

    test('互联 live 通道 _syncCollectionsLive', () async {
      final (:device, :stale) = await healedDevice();
      final _FakeLiveHost host = _FakeLiveHost(stale);
      SyncOrchestrator orch() => SyncOrchestrator(
        db: device.db,
        backend: host,
        dictionaryResourceRoot: Directory.systemTemp,
        audioDatabaseRoot: Directory.systemTemp,
        tempDir: Directory.systemTemp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

      final SyncRunReport first = SyncRunReport();
      await orch().syncCollectionsLiveForTest(first, host);
      expect(first.errors, isEmpty);
      expect(first.collectionsUpdated, 0);
      expect(await device.order(), _volumeOrder);
      expect(_orderIn(host.manifest), _volumeOrder, reason: 'POST 回 host 的是卷序');
      expect(host.puts, 1);

      await _tick();
      final SyncRunReport again = SyncRunReport();
      await orch().syncCollectionsLiveForTest(again, host);
      expect(again.collectionsUpdated, 0);
      expect(host.puts, 1, reason: '收敛：清单字节不变不再 POST');
    });

    test('互联 host 收 POST：mergeCollectionManifest', () async {
      final (:device, :stale) = await healedDevice();
      final LocalLibraryHostService svc = LocalLibraryHostService(
        db: device.db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: device.db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );

      final CollectionManifest merged = await svc.mergeCollectionManifest(
        stale,
      );
      expect(await device.order(), _volumeOrder, reason: 'host 本机不被冲回错序');
      expect(_orderIn(merged), _volumeOrder, reason: '返回给 client 的是卷序');

      await _tick();
      final CollectionManifest again = await svc.mergeCollectionManifest(
        merged,
      );
      expect(again.canonicalJson(), merged.canonicalJson());
      expect(await device.order(), _volumeOrder);
    });
  });
}
