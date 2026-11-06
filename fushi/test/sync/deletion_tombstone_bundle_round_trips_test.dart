/// SDbJAx1Db6：云同步的删除墓碑阶段每轮逐条 GET 全部远端标记（标记永不 GC、只增不减），
/// 用户日志里这一阶段单独占 196–236 s，且一次 TLS 握手中断就连环刷几十条
/// `HandshakeException`。修复后读侧改成「每台设备一份合并清单 + 指纹覆盖的逐条标记免读」，
/// 每轮逐条读有上限，传输失败有预算。
///
/// 这里跑真的 [SyncOrchestrator.syncDeletionTombstones]，用**计数**假远端（给内容指纹的
/// 后端口径）钉住每轮的 GET 次数，并验证旧格式（只有逐条标记、旧客户端写的）仍被消费。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/deletion_tombstone_bundle.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';

void main() {
  late FakeAssetStore store;
  late _CountingBackend backend;
  late Directory tmp;
  final List<FushiDatabase> dbs = <FushiDatabase>[];

  setUp(() async {
    store = FakeAssetStore(reportRevisions: true);
    backend = _CountingBackend(store);
    tmp = await Directory.systemTemp.createTemp('tombstone_bundle_rt');
  });
  tearDown(() async {
    for (final FushiDatabase db in dbs) {
      await db.close();
    }
    dbs.clear();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  FushiDatabase newDb() {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    dbs.add(db);
    return db;
  }

  SyncOrchestrator orchestrator(FushiDatabase db, String deviceId) =>
      SyncOrchestrator(
        db: db,
        backend: backend,
        deviceId: deviceId,
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

  final String kind = SyncTombstoneKind.srtbook.dbValue;

  Future<void> addSrt(FushiDatabase db, String uid) => db.upsertSrtBook(
    SrtBooksCompanion.insert(
      uid: uid,
      title: uid,
      srtPath: '/tmp/$uid.srt',
      importedAt: 0,
      localAddedAt: const Value<int?>(0),
    ),
  );

  /// 旧客户端发布的一条逐条标记。
  Future<void> putLegacyMarker(String uid, int deletedAt) async {
    final String ns = await store.ensureNamespace(kSyncTombstonesNamespace);
    await store.putJsonAsset(
      ns,
      deletionTombstoneAssetName(kind, uid),
      deletionTombstoneJson(kind, uid, deletedAt),
    );
  }

  Future<void> commitBaseline(FushiDatabase db, SyncRunReport report) async {
    final SyncRepository repo = SyncRepository(db);
    for (final MapEntry<String, int> e
        in report.deletionTombstonesHighWaterMsByScope.entries) {
      await repo.setDeletionTombstonesBaselineMs(
        SyncChannelScope.byId(e.key),
        e.value,
      );
    }
  }

  test('300 条旧标记：每轮逐条读有上限，读过一次后稳态只剩 1 次 GET（清单）', () async {
    final FushiDatabase db = newDb();
    for (int i = 0; i < 300; i++) {
      await putLegacyMarker('srt/$i', 1000 + i);
    }
    await addSrt(db, 'srt/7');

    // 第一轮：至多读 kDeletionTombstoneMarkerReadsPerRound 条，其余推迟。
    backend.reset();
    final SyncRunReport r1 = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r1);
    expect(
      backend.gets,
      kDeletionTombstoneMarkerReadsPerRound,
      reason: '修复前这里是 300（每条一个往返），且每轮都是 300',
    );
    expect(
      r1.deletionTombstonesHighWaterMsByScope,
      isEmpty,
      reason: '推迟了一部分 = 不完整观测，不得推进基线（BUG-1934）',
    );
    expect(r1.errors.any((String s) => s.contains('deferred')), isTrue);
    expect(r1.deletionCandidates.map((c) => c.itemKey), <String>['srt/7']);

    // 第二轮：读剩下的 100 条 + 自己的清单 1 次。
    backend.reset();
    final SyncRunReport r2 = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r2);
    expect(backend.gets, 1 + 100);
    expect(
      r2.deletionTombstonesHighWaterMsByScope,
      isNotEmpty,
      reason: '这一轮把列出的标记全部观测到了',
    );

    // 第三轮（稳态）：所有逐条标记都被自己的清单按指纹覆盖，一条都不读。
    backend.reset();
    final SyncRunReport r3 = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r3);
    expect(backend.gets, 1, reason: '稳态 = 只读自己的合并清单');
    expect(backend.puts, 0, reason: '清单内容没变，不重写');
    expect(r3.deletionCandidates.map((c) => c.itemKey), <String>[
      'srt/7',
    ], reason: '跳过 GET 不能丢信息：候选仍来自清单里记的内容');
    expect(r3.errors, isEmpty);
  });

  test('另一台新设备：一份清单就拿到别人读过的全部旧标记，不再逐条读', () async {
    final FushiDatabase a = newDb();
    for (int i = 0; i < 50; i++) {
      await putLegacyMarker('srt/$i', 1000 + i);
    }
    await orchestrator(a, 'devA').syncDeletionTombstones(SyncRunReport());

    final FushiDatabase b = newDb();
    await addSrt(b, 'srt/3');
    backend.reset();
    final SyncRunReport rb = SyncRunReport();
    await orchestrator(b, 'devB').syncDeletionTombstones(rb);
    expect(backend.gets, 1, reason: '只读 devA 的清单（devB 还没有自己的）');
    expect(rb.deletionCandidates.map((c) => c.itemKey), <String>['srt/3']);
    expect(rb.deletionTombstonesHighWaterMsByScope, <String, int>{
      SyncChannelScope.unscoped.id: 1003,
    });
  });

  test('旧客户端改写了某条标记（内容指纹变了）→ 重新读它，拿到更新的 deletedAt', () async {
    final FushiDatabase db = newDb();
    await addSrt(db, 'srt/x');
    await putLegacyMarker('srt/x', 1000);
    final SyncRunReport r1 = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r1);
    await commitBaseline(db, r1); // 用户复核了 deletedAt=1000 那次。

    await putLegacyMarker('srt/x', 5000); // 删后重加又删，旧客户端覆盖了同名文件。
    backend.reset();
    final SyncRunReport r2 = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r2);
    expect(backend.gets, 2, reason: '自己的清单 1 次 + 指纹变了的那条 1 次');
    expect(r2.deletionCandidates.map((c) => c.itemKey), <String>[
      'srt/x',
    ], reason: '指纹不匹配就绝不能按清单里的旧内容跳过');
  });

  test('连接坏了：传输失败到预算就停读，剩下的推迟，且不推进基线', () async {
    final FushiDatabase db = newDb();
    for (int i = 0; i < 40; i++) {
      await putLegacyMarker('srt/$i', 1000 + i);
    }
    backend.failAllGets = true;
    final SyncRunReport r = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r);
    expect(
      backend.gets,
      kDeletionTombstoneReadFailureBudget,
      reason: '修复前 40 条逐条撞握手，每条都要等一次 TLS 超时',
    );
    expect(
      r.errors.where((String s) => s.contains('HandshakeException')).length,
      kDeletionTombstoneReadFailureBudget,
    );
    expect(r.errors.any((String s) => s.contains('deferred')), isTrue);
    expect(r.deletionTombstonesHighWaterMsByScope, isEmpty);
  });

  test('本机墓碑：照旧写逐条标记（旧客户端兼容），同时进本机清单', () async {
    final FushiDatabase db = newDb();
    await db.writeSyncDeletionTombstone(kind, 'srt/gone', 1234);
    await orchestrator(db, 'devA').syncDeletionTombstones(SyncRunReport());

    final String ns = await store.ensureNamespace(kSyncTombstonesNamespace);
    final Object? legacy = await store.getJsonAsset(
      '$ns/${deletionTombstoneAssetName(kind, 'srt/gone')}',
    );
    expect(
      parseDeletionTombstoneJson(legacy)?.deletedAt,
      1234,
      reason: '旧客户端只认逐条标记，新客户端不能停写',
    );
    final DeletionTombstoneBundle? bundle = DeletionTombstoneBundle.tryParse(
      await store.getJsonAsset(
        '$ns/$kDeletionTombstoneBundlesFolder/'
        '${deletionTombstoneBundleNameFor('devA')}',
      ),
    );
    expect(bundle, isNotNull);
    expect(
      bundle!.entries[deletionTombstoneBundleKey(kind, 'srt/gone')]?.deletedAt,
      1234,
    );
  });

  test('后端不给内容指纹（FTP / SFTP 口径）→ 照旧逐条读，语义不变', () async {
    store = FakeAssetStore();
    backend = _CountingBackend(store);
    final FushiDatabase db = newDb();
    await addSrt(db, 'srt/1');
    for (int i = 0; i < 5; i++) {
      await putLegacyMarker('srt/$i', 1000 + i);
    }
    await orchestrator(db, 'devA').syncDeletionTombstones(SyncRunReport());
    backend.reset();
    final SyncRunReport r = SyncRunReport();
    await orchestrator(db, 'devA').syncDeletionTombstones(r);
    expect(
      backend.gets,
      5,
      reason:
          '没有可靠指纹就不能断言「内容没变」，只能读（本机无墓碑、无指纹可记 ⇒ '
          '也不写空清单）',
    );
    expect(r.deletionCandidates.map((c) => c.itemKey), <String>['srt/1']);
  });
}

/// 计数假远端：统计 getJsonAsset / putJsonAsset 往返次数；[failAllGets] 模拟 TLS 握手中断。
class _CountingBackend implements SyncBackend {
  _CountingBackend(this._store);
  final FakeAssetStore _store;
  int gets = 0;
  int puts = 0;
  bool failAllGets = false;

  void reset() {
    gets = 0;
    puts = 0;
  }

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _store.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    gets++;
    if (failAllGets) {
      throw const HandshakeException('Connection terminated during handshake');
    }
    return _store.getJsonAsset(assetId);
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) {
    puts++;
    return _store.putJsonAsset(namespaceId, name, json);
  }

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_CountingBackend.${invocation.memberName}');
}
