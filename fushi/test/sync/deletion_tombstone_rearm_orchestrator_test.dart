/// BUG-2044 的**生产接线**测试：删后重加仲裁必须真的挂在
/// `SyncOrchestrator._collectPresentDeletionKeys` 上，而不只是纯函数
/// `tombstoneAppliesTo` 自己对。
///
/// `deletion_propagation_test.dart` 全是手搓 map 喂纯谓词，没有一条穿过 orchestrator：
/// 把 `_collectPresentDeletionKeys` 的时刻源整批改回 `null`（= 修复没接上，退化成旧的
/// 纯集合语义），那批用例一条都不红。这里照 `srt_book_tombstone_sync_test.dart` 的范式
/// 跑真的 `SyncOrchestrator.syncDeletionTombstones`（内存 DB + fake backend），把
/// 「墓碑 → 在库时刻 → 候选」这条真实链路一起钉住。
///
/// 覆盖两类资产：
/// - `favoritesentence`（用户实报的那类，时刻源 = `FavoriteSentence.createdAt`）；
/// - `book`（时刻源 = `epub_books.importedAt`），证明这不是一个资产的偶然。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';

void main() {
  late FushiDatabase db;
  late FakeAssetStore store;
  late _FakeBackend backend;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    store = FakeAssetStore();
    backend = _FakeBackend(store);
    tmp = await Directory.systemTemp.createTemp('deletion_rearm_sync');
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

  /// 造一条「对端删了这个 itemKey」的远端标记（与云通道消费端读的是同一批文件）。
  Future<void> putRemoteTombstone(
      String mediaType, String itemKey, int deletedAt) async {
    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    await backend.putJsonAsset(
      ns,
      deletionTombstoneAssetName(mediaType, itemKey),
      deletionTombstoneJson(mediaType, itemKey, deletedAt),
    );
  }

  FavoriteSentence sentence(int createdAtMs) => FavoriteSentence(
        text: 'いつか君と話したい',
        bookTitle: 'Some Book',
        bookKey: 'BookA',
        sectionIndex: 3,
        normCharOffset: 42,
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      );

  Future<String> addSentence(int createdAtMs) async {
    final FavoriteSentence s = sentence(createdAtMs);
    await FavoriteSentenceRepository(db).add(s);
    return FavoriteSentenceRepository.itemKeyOf(s);
  }

  Future<String> addBook(String bookKey, int importedAt) =>
      db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '/tmp/$bookKey.epub',
        extractDir: '/tmp/$bookKey',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: importedAt,
      ));

  group('favoritesentence（BUG-2044 用户实报的资产类）', () {
    test('重加晚于墓碑 → 不产候选（墓碑管不着这条新收藏）', () async {
      final String key = await addSentence(9000);
      await putRemoteTombstone(
          SyncTombstoneKind.favoritesentence.dbValue, key, 5000);

      final SyncRunReport report = SyncRunReport();
      await orchestrator().syncDeletionTombstones(report);

      expect(report.deletionCandidates, isEmpty,
          reason: '取消收藏写的远端墓碑永不 GC；重新收藏后它必须被 createdAt 仲裁掉，'
              '否则用户会被问「其他设备已删除，要不要删掉你刚收藏的句子」。'
              '在库时刻源接不上（退化成 null）时这里会产出 1 条候选。');
    });

    test('本地早于墓碑 → 仍产 deleteLocal 候选（真实跨端删除不被压制）', () async {
      final String key = await addSentence(5000);
      await putRemoteTombstone(
          SyncTombstoneKind.favoritesentence.dbValue, key, 9000);

      final SyncRunReport report = SyncRunReport();
      await orchestrator().syncDeletionTombstones(report);

      expect(report.deletionCandidates, hasLength(1),
          reason: '仲裁只该挡「删后重加」，不该把真实的对端删除一起挡掉');
      final DeletionPropagationCandidate c = report.deletionCandidates.single;
      expect(c.mediaType, SyncTombstoneKind.favoritesentence.dbValue);
      expect(c.itemKey, key);
      expect(c.direction, DeletionPropagationDirection.deleteLocal);
      expect(report.deletionTombstonesHighWaterMsByScope,
          <String, int>{SyncChannelScope.unscoped.id: 9000});
    });

    test('时刻相等 → 判给重加，不产候选（判据是严格大于，与 aggregate 侧同律）', () async {
      final String key = await addSentence(7000);
      await putRemoteTombstone(
          SyncTombstoneKind.favoritesentence.dbValue, key, 7000);

      final SyncRunReport report = SyncRunReport();
      await orchestrator().syncDeletionTombstones(report);

      expect(report.deletionCandidates, isEmpty);
    });
  });

  group('book（时刻源 = epub_books.importedAt）', () {
    test('重新导入晚于墓碑 → 不产候选', () async {
      await addBook('BookRearmed', 9000);
      await putRemoteTombstone(
          SyncTombstoneKind.book.dbValue, 'BookRearmed', 5000);

      final SyncRunReport report = SyncRunReport();
      await orchestrator().syncDeletionTombstones(report);

      expect(report.deletionCandidates, isEmpty,
          reason: 'importedAt 接不上（退化成 null）时这里会产出 1 条候选');
    });

    test('导入早于墓碑 → 仍产 deleteLocal 候选', () async {
      await addBook('BookStale', 5000);
      await putRemoteTombstone(
          SyncTombstoneKind.book.dbValue, 'BookStale', 9000);

      final SyncRunReport report = SyncRunReport();
      await orchestrator().syncDeletionTombstones(report);

      expect(report.deletionCandidates, hasLength(1));
      expect(report.deletionCandidates.single.itemKey, 'BookStale');
      expect(report.deletionCandidates.single.direction,
          DeletionPropagationDirection.deleteLocal);
    });
  });

  test('audiobook 无自身时刻列 → 保持旧的纯集合语义（缺时刻宁可多问一次）', () async {
    await addBook('BookWithAudio', 9000);
    await db.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: 'BookWithAudio',
      alignmentFormat: 'srt',
      alignmentPath: '/tmp/BookWithAudio/align.srt',
    ));
    await putRemoteTombstone(
        SyncTombstoneKind.audiobook.dbValue, 'BookWithAudio', 5000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncDeletionTombstones(report);

    expect(report.deletionCandidates, hasLength(1),
        reason: '有声书表没有导入时刻列，绝不能借同 bookKey 的 epub importedAt '
            '编造一个时刻——那会把「书早就在、有声书是后加的」记成前者，'
            '静默压制一次真实的跨端删除');
    expect(report.deletionCandidates.single.mediaType,
        SyncTombstoneKind.audiobook.dbValue);
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
