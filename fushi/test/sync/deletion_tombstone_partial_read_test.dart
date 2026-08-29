/// BUG-1934：远端删除墓碑「列出来了但没读成」的那一轮，不得推进删除消费基线。
///
/// 基线是**标量**（`sync_deletion_tombstones_baseline_ms`），UI 复核完一批候选就把它推到
/// 本轮最大 deletedAt。于是只要有一条标记本轮没读出来、而它的 deletedAt 又比推上去的值
/// 小，下轮它就落进 `at <= baseline` 的旧闻分支——**永久**不再弹确认，用户在对端删掉的东
/// 西在本机静默留存。触发它只需要一次 TLS 握手失败（真实报告里是
/// `HandshakeException: Connection terminated during handshake`）。
///
/// 这里跑真的 [SyncOrchestrator.syncDeletionTombstones]，把三种读失败形态（抛异常 / 读回
/// null / 内容非法）与基线推进的关系一起钉住。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';

void main() {
  late FushiDatabase db;
  late FakeAssetStore store;
  late _FlakyBackend backend;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    store = FakeAssetStore();
    backend = _FlakyBackend(store);
    tmp = await Directory.systemTemp.createTemp('tombstone_partial_read');
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
      );

  final String kind = SyncTombstoneKind.srtbook.dbValue;

  Future<void> addSrt(String uid) => db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: uid,
        title: uid,
        srtPath: '/tmp/$uid.srt',
        importedAt: 0,
      ));

  /// 造一条「对端删了这本书」的远端标记，返回它的资产 id。
  Future<String> putRemoteTombstone(String uid, int deletedAt) async {
    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    final String name = deletionTombstoneAssetName(kind, uid);
    await backend.putJsonAsset(
        ns, name, deletionTombstoneJson(kind, uid, deletedAt));
    return '$ns/$name';
  }

  /// 模仿 UI 复核完一批候选后的动作（`DeletionPromptPrompter` 的基线推进段）。
  Future<void> commitBaseline(SyncRunReport report) async {
    final SyncRepository repo = SyncRepository(db);
    for (final MapEntry<String, int> e
        in report.deletionTombstonesHighWaterMsByScope.entries) {
      if (e.value <= 0) continue;
      await repo.setDeletionTombstonesBaselineMs(
          SyncChannelScope.byId(e.key), e.value);
    }
  }

  test('基准：全部标记读得出来时，照常登记 high-water', () async {
    await addSrt('srt/a');
    await putRemoteTombstone('srt/a', 5000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, hasLength(1));
    expect(report.deletionTombstonesHighWaterMsByScope,
        <String, int>{SyncChannelScope.unscoped.id: 5000},
        reason: '完整观测的一轮必须照常推进基线，否则用户复核过的删除会反复骚扰');
  });

  test('一条读失败（抛）→ 候选照出，但本轮不登记 high-water', () async {
    await addSrt('srt/early');
    await addSrt('srt/late');
    // early 的 deletedAt 更小：它正是会被「推过头的基线」永久压制的那条。
    backend.failIds.add(await putRemoteTombstone('srt/early', 1000));
    await putRemoteTombstone('srt/late', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(
        report.deletionCandidates
            .map((DeletionPropagationCandidate c) => c.itemKey),
        <String>['srt/late'],
        reason: '读得出来的那条照常上报，不能因为同伴失败就一起哑掉');
    expect(report.deletionTombstonesHighWaterMsByScope, isEmpty,
        reason: '本轮观测不完整，不得认领「已复核到 9000」——那会把 deletedAt=1000 的 '
            'early 永久压成旧闻');
    expect(report.errors.any((String s) => s.contains('scan incomplete')),
        isTrue,
        reason: '基线被扣住这件事要在报告里留痕，否则只能靠猜');
  });

  test('回归：一轮部分失败 + 用户复核 → 下一轮读全后，被跳过的那条仍能弹出', () async {
    await addSrt('srt/early');
    await addSrt('srt/late');
    final String earlyId = await putRemoteTombstone('srt/early', 1000);
    await putRemoteTombstone('srt/late', 9000);

    // 第一轮：early 握手失败。
    backend.failIds.add(earlyId);
    final SyncRunReport run1 = SyncRunReport();
    await orchestrator().syncDeletionTombstones(run1);
    await commitBaseline(run1); // 用户处理完 late 的确认框。

    // 第二轮：网络恢复，early 读得出来了。
    backend.failIds.clear();
    final SyncRunReport run2 = SyncRunReport();
    await orchestrator().syncDeletionTombstones(run2);

    expect(
        run2.deletionCandidates
            .map((DeletionPropagationCandidate c) => c.itemKey),
        contains('srt/early'),
        reason: '这是本 bug 的要害：修复前 baseline 已被推到 9000，deletedAt=1000 的 '
            'early 从此永远进不了候选，对端的删除在本机静默丢失');
  });

  test('读回 null（后端把读失败映射成空）→ 同样扣住基线', () async {
    await addSrt('srt/early');
    await addSrt('srt/late');
    backend.nullIds.add(await putRemoteTombstone('srt/early', 1000));
    await putRemoteTombstone('srt/late', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionTombstonesHighWaterMsByScope, isEmpty,
        reason: 'SftpSyncBackend.getJsonAsset 把 SyncBackendError 吞成 null，'
            '按「已观测」处理会让同一次永久压制悄无声息地发生');
    expect(report.errors.any((String s) => s.contains('unreadable')), isTrue);
  });

  test('内容非法（永久坏文件）→ 记一条错误，但不扣住基线', () async {
    await addSrt('srt/late');
    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    await backend.putJsonAsset(ns, 'junk.json', <String, Object?>{'x': 1});
    await putRemoteTombstone('srt/late', 9000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionTombstonesHighWaterMsByScope,
        <String, int>{SyncChannelScope.unscoped.id: 9000},
        reason: '坏文件重试一万次还是坏的；为它永久钉住基线只会让用户每轮重看同一批确认框');
    expect(report.errors.any((String s) => s.contains('malformed')), isTrue,
        reason: '不再静默丢弃：坏标记要看得见');
  });
}

/// [FakeAssetStore] 之上的可控故障层：[failIds] 抛（模拟 TLS 握手中断），[nullIds] 返回
/// null（模拟把读失败映射成空的后端）。其余成员照旧委托，未用到的当场炸。
class _FlakyBackend implements SyncBackend {
  _FlakyBackend(this._store);
  final FakeAssetStore _store;
  final Set<String> failIds = <String>{};
  final Set<String> nullIds = <String>{};

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    if (failIds.contains(assetId)) {
      throw const HandshakeException('Connection terminated during handshake');
    }
    if (nullIds.contains(assetId)) return null;
    return _store.getJsonAsset(assetId);
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FlakyBackend.${invocation.memberName}');
}
