/// TODO-2470 死角① 的端到端两侧：纯字幕书的删除墓碑要能**发布**出去，对端也要能把它
/// **消费**成一条待确认候选。
///
/// 单靠 repo 层「有没有写墓碑」不够——墓碑写了但 `_collectPresentDeletionKeys` 漏收
/// srtbook 键，对端照样永远不弹确认，用户看到的仍是「勾了没用」。这里跑真的
/// `SyncOrchestrator.syncDeletionTombstones`，把两侧一起钉住。
///
/// 同时钉住那条互斥规则的**消费侧**：srt-backed 行（bookKey 非空）身份是 bookKey，
/// 不得被当成 srtbook 在库键，否则同一资产会弹出两条重复确认。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';

void main() {
  late HibikiDatabase db;
  late FakeAssetStore store;
  late _FakeBackend backend;
  late Directory tmp;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    store = FakeAssetStore();
    backend = _FakeBackend(store);
    tmp = await Directory.systemTemp.createTemp('srt_tombstone_sync');
  });
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  SyncOrchestrator orchestrator() => SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
        syncLocalAudio: false,
      );

  Future<void> addSrt(String uid, {String bookKey = ''}) =>
      db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: uid,
        title: uid,
        srtPath: '/tmp/$uid.srt',
        importedAt: 0,
        bookKey: Value(bookKey),
      ));

  /// 造一条「对端删了这本纯字幕书」的远端标记。
  Future<void> putRemoteTombstone(String uid, int deletedAt) async {
    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    await backend.putJsonAsset(
      ns,
      deletionTombstoneAssetName(SyncTombstoneKind.srtbook.dbValue, uid),
      deletionTombstoneJson(SyncTombstoneKind.srtbook.dbValue, uid, deletedAt),
    );
  }

  test('发布：本机 srtbook 墓碑被写成远端标记并标记已发布', () async {
    await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.srtbook.dbValue, 'srt/gone', 1000);

    await orchestrator().syncDeletionTombstones(SyncRunReport());

    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    final List<AssetEntry> children = await backend.listChildren(ns);
    expect(children.where((AssetEntry e) => !e.isFolder), hasLength(1),
        reason: '发布层按行遍历墓碑表，新种类无需改动就该被发出去');

    final SyncDeletionTombstoneRow row = (await db
            .getSyncDeletionTombstonesOfType(SyncTombstoneKind.srtbook.dbValue))
        .single;
    expect(row.remotePublishedAt, isNot(0), reason: '发布后要标记，避免每轮重发');
  });

  test('消费：远端 srtbook 标记 + 本地 standalone 在库 → 产出 deleteLocal 候选', () async {
    await addSrt('srt/lonely');
    await putRemoteTombstone('srt/lonely', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, hasLength(1),
        reason: '这是「另一台设备删了这本纯字幕书」在本机弹确认的唯一来源；'
            '在库键漏收 srtbook 会让它永远不弹');
    final DeletionPropagationCandidate c = report.deletionCandidates.single;
    expect(c.mediaType, SyncTombstoneKind.srtbook.dbValue);
    expect(c.itemKey, 'srt/lonely');
    expect(c.direction, DeletionPropagationDirection.deleteLocal);
    expect(report.deletionTombstonesHighWaterMs, 9000);
  });

  test('消费：srt-backed 行（bookKey 非空）不算 srtbook 在库键 → 不产候选', () async {
    await addSrt('srt/paired', bookKey: 'BookA');
    await putRemoteTombstone('srt/paired', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, isEmpty,
        reason: '它的身份是 bookKey、走 book 种类；两侧都收会让同一资产弹两条重复确认');
  });

  test('消费：本地已无此书 → 不产候选（两端都删，已收敛）', () async {
    await putRemoteTombstone('srt/already-gone', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, isEmpty);
  });

  test('消费：deletedAt 不晚于基线的旧标记不再弹', () async {
    await addSrt('srt/old');
    await putRemoteTombstone('srt/old', 500);
    await SyncRepository(db).setDeletionTombstonesBaselineMs(1000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, isEmpty,
        reason: '因果基线守卫：用户已复核过的删除不该反复骚扰');
  });
}

/// 只实现删除墓碑路径真正走到的成员，其余抛 [UnimplementedError]——被误用时会当场
/// 炸出来，而不是悄悄返回一个假值让断言变得没有意义。
class _FakeBackend implements SyncBackend {
  _FakeBackend(this._store);
  final FakeAssetStore _store;

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeBackend.${invocation.memberName}');
}
