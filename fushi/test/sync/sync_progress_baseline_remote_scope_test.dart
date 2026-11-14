/// BUG-4434（步骤 8 接线）：SyncManager 的文件箱进度基线挂在当前远端名下。
///
/// 此前 SyncManager 用 `progressBaselineDimensionOf` 的固定维度读写基线：在远端 A
/// 达成一致（基线 = 本地戳 L）后换到远端 B，B 上是更早的旧进度——本地 == 基线、
/// B ≠ 基线 → 判「只远端动了」→ B 的旧进度静默导入本机。修复后基线按远端分槽，
/// B 的作用域没有基线，两边不等判冲突；互联文件箱在会话中途换 host 时不落地、不写
/// 基线。
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_baseline_scope.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

const String _title = 'Remote Scope Book';
final String _assetKey = sanitizeTtuFilename(_title);

FushiDatabase _memDb() {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  return db;
}

/// 一个远端文件箱：身份 + 那本书的进度文件（文件名编码时间戳与分数）。
class _Box {
  _Box(this.identity);

  final String identity;
  int? timestampMs;
  double fraction = 0;
  TtuProgress? exported;

  String get scopedDimension =>
      remoteScopedKey('progress', syncRemoteTag(identity));
}

/// 内存文件箱假后端，报出远端身份（[SyncRemoteIdentified]）。只实现
/// SyncManager 单本同步会碰到的成员，其余一碰就抛。
class _BoxBackend implements SyncBackend, SyncRemoteIdentified {
  _BoxBackend(this.box, {this.identityError});

  final _Box box;
  final Exception? identityError;

  @override
  Future<String> syncRemoteIdentity() async {
    final Exception? e = identityError;
    if (e != null) throw e;
    return box.identity;
  }

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'folder';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final int? ts = box.timestampMs;
    return SyncFileTrio(
      progress: ts == null
          ? null
          : SyncFileRef(id: 'p', name: progressFileName(ts, box.fraction)),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async => TtuProgress(
    dataId: 0,
    exploredCharCount: (box.fraction * 1000).round(),
    progress: box.fraction,
    lastBookmarkModified: box.timestampMs!,
  );

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    box.exported = progress;
    box.timestampMs = progress.lastBookmarkModified;
    box.fraction = progress.progress;
  }

  String? _root;
  final Map<String, String> _folders = <String, String>{};
  @override
  void clearCache() {
    _root = null;
    _folders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _root = rootFolderId;
    if (titleToFolderId != null) _folders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _root;
  @override
  Map<String, String> get cachedFolderIds => _folders;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// `sync_baselines` 全表（任意维度）。
Future<List<SyncBaselineRow>> _allBaselines(FushiDatabase db) =>
    db.select(db.syncBaselines).get();

Future<EpubBookRow> _seedBook(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _title,
      title: _title,
      epubPath: '/fake/book.epub',
      extractDir: '/fake/extract',
      chapterCount: 1,
      chaptersJson: '[{"characters":1000}]',
      importedAt: 1,
    ),
  );
  return (await db.getAllEpubBooks()).single;
}

Future<void> _seedPosition(
  FushiDatabase db,
  String uid, {
  required int updatedAt,
  required double fraction,
}) => db.upsertReaderPosition(
  ReaderPositionsCompanion(
    bookUid: Value(uid),
    sectionIndex: const Value(0),
    normCharOffset: Value((fraction * 10000).round()),
    updatedAt: Value(updatedAt),
  ),
);

Future<SyncBookResult> _sync(
  FushiDatabase db,
  SyncBackend backend,
  EpubBookRow book,
) => SyncManager(db: db, backend: backend).syncBook(
  book: book,
  syncStats: false,
  statsSyncMode: StatisticsSyncMode.merge,
  syncAudioBook: false,
);

/// 互联文件箱假后端：会话钉在 hostId `a`，在 [switchOnImport] / [switchOnExport]
/// 时故障切换到 `b`（真 [InterconnectSyncBackend.checkHostPin] 核对）。
class _SwitchingFileBox extends InterconnectSyncBackend {
  _SwitchingFileBox({this.switchOnImport = false, this.switchOnExport = false})
    : super.withProbe((String url, String token) async => true) {
    debugSwitchHostScope('a');
  }

  final bool switchOnImport;
  final bool switchOnExport;
  int remoteTs = 0;
  int progressWrites = 0;

  @override
  Future<InterconnectHostScope> liveHostScope() async =>
      const InterconnectHostScope(
        pin: InterconnectHostPin(
          identity: InterconnectScopeIdentity.host('a'),
          serial: 1,
        ),
        adoption: LegacyBaselineAdoption.keep,
      );

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'folder';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async => SyncFileTrio(
    progress: SyncFileRef(id: 'p', name: progressFileName(remoteTs, 0.3)),
  );

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    if (switchOnImport) debugSwitchHostScope('b');
    return TtuProgress(
      dataId: 0,
      exploredCharCount: 300,
      progress: 0.3,
      lastBookmarkModified: remoteTs,
    );
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    progressWrites++;
    if (switchOnExport) debugSwitchHostScope('b');
  }
}

String _hostScoped(String hostId) => remoteScopedKey(
  'progress__fushiServer',
  syncRemoteTag('fushiServer\n$hostId'),
);

void main() {
  test('agreement on remote A is not reused against remote B: B holding an '
      'older progress is a conflict, not an import', () async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db);
    await _seedPosition(db, book.uid, updatedAt: 200, fraction: 0.6);

    final _Box a = _Box('remote-A')
      ..timestampMs = 200
      ..fraction = 0.6;
    expect(
      (await _sync(db, _BoxBackend(a), book)).direction,
      SyncResult.synced,
    );
    expect(await db.getSyncBaseline(_assetKey, a.scopedDimension), 200);

    final _Box b = _Box('remote-B')
      ..timestampMs = 100
      ..fraction = 0.3;
    final SyncBookResult onB = await _sync(db, _BoxBackend(b), book);
    expect(onB.direction, SyncResult.conflict);
    // 冲突上报仍用逻辑维度（裁决簿 / 弹窗按它认）。
    expect(onB.conflictDimension, 'progress');
    final ReaderPositionRow pos = (await db.getReaderPosition(book.uid))!;
    expect(pos.updatedAt, 200);
    expect(pos.normCharOffset, 6000);
    expect(await db.getSyncBaseline(_assetKey, b.scopedDimension), isNull);
    expect(await db.getSyncBaseline(_assetKey, a.scopedDimension), 200);

    // 回到 A：A 没动、本地又读了 → 导出，A 的基线前进。
    await _seedPosition(db, book.uid, updatedAt: 300, fraction: 0.7);
    expect(
      (await _sync(db, _BoxBackend(a), book)).direction,
      SyncResult.exported,
    );
    expect(a.exported!.lastBookmarkModified, 300);
    expect(await db.getSyncBaseline(_assetKey, a.scopedDimension), 300);
  });

  test('legacy unsuffixed `progress` row is adopted by the first remote and '
      'the decision is unchanged', () async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db);
    await _seedPosition(db, book.uid, updatedAt: 200, fraction: 0.6);
    await db.setSyncBaseline(_assetKey, 'progress', 100);

    // A 上是本地上次同步后的值（== 旧基线）、本地往前读了 → 导出。
    final _Box a = _Box('remote-A')
      ..timestampMs = 100
      ..fraction = 0.4;
    expect(
      (await _sync(db, _BoxBackend(a), book)).direction,
      SyncResult.exported,
    );
    expect(await db.getSyncBaseline(_assetKey, a.scopedDimension), 200);
    expect(await db.getSyncBaseline(_assetKey, 'progress'), isNull);
  });

  _BoxBackend unidentified(_Box box) => _BoxBackend(
    box,
    identityError: SyncRemoteIdentityUnavailableError(SyncBackendType.dropbox),
  );

  test('remote identity unavailable, both sides moved → that book is skipped '
      'with an error, nothing written; the phase finishes and reports one '
      'error carrying the results', () async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db);
    await _seedPosition(db, book.uid, updatedAt: 200, fraction: 0.6);
    final _Box box = _Box('unused')
      ..timestampMs = 300
      ..fraction = 0.9;
    final _BoxBackend backend = unidentified(box);

    final SyncBookResult single = await _sync(db, backend, book);
    expect(single.direction, SyncResult.skipped);
    expect(single.error, isNotNull);

    // 评审 compat-2：不再在开轮直接抛 SyncRemoteIdentityUnavailableError 中断整段，
    // 逐本跑完后带着结果报一次错。
    Object? thrown;
    try {
      await SyncManager(db: db, backend: backend).syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<SyncBooksIncompleteError>());
    final SyncBooksIncompleteError incomplete =
        thrown! as SyncBooksIncompleteError;
    expect(incomplete.cause, isA<SyncRemoteIdentityUnavailableError>());
    expect(incomplete.results.single.direction, SyncResult.skipped);
    expect(incomplete.results.single.error, isNotNull);
    final ReaderPositionRow pos = (await db.getReaderPosition(book.uid))!;
    expect(pos.updatedAt, 200);
    expect(box.exported, isNull);
    expect(await _allBaselines(db), isEmpty);
  });

  // 评审 compat-2：OAuth 邮箱一次取失败（升级后第一次启动还没记过账号）时，不需要
  // 共同祖先的书照常同步——新导入的书照常导出，只是不写基线（挑不出槽）。修复前开轮
  // 就抛，整段书都不传。
  test('remote identity unavailable, single-sided change → still exported, '
      'no baseline written anywhere', () async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db);
    await _seedPosition(db, book.uid, updatedAt: 200, fraction: 0.6);
    final _Box box = _Box('unused'); // 远端还没有这本书的进度。

    Object? thrown;
    try {
      await SyncManager(db: db, backend: unidentified(box)).syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<SyncBooksIncompleteError>());
    expect(
      (thrown! as SyncBooksIncompleteError).results.single.direction,
      SyncResult.exported,
    );
    expect(box.exported!.lastBookmarkModified, 200);
    expect(await _allBaselines(db), isEmpty);
  });

  test('remote identity unavailable, remote-only progress → still imported, '
      'no baseline written anywhere', () async {
    final FushiDatabase db = _memDb();
    final EpubBookRow book = await _seedBook(db);
    final _Box box = _Box('unused')
      ..timestampMs = 300
      ..fraction = 0.5;

    final SyncBookResult result = await _sync(db, unidentified(box), book);
    expect(result.direction, SyncResult.imported);
    expect((await db.getReaderPosition(book.uid))!.updatedAt, 300);
    expect(await _allBaselines(db), isEmpty);
  });

  group('interconnect file box pinned to the session host', () {
    test('host changes while reading the remote progress → no import, no '
        'baseline, phase ends', () async {
      final FushiDatabase db = _memDb();
      final EpubBookRow book = await _seedBook(db);
      await _seedPosition(db, book.uid, updatedAt: 100, fraction: 0.6);
      await db.setSyncBaseline(_assetKey, _hostScoped('a'), 100);
      final _SwitchingFileBox backend = _SwitchingFileBox(switchOnImport: true)
        ..remoteTs = 200;

      await expectLater(
        SyncManager(db: db, backend: backend).syncAllBooks(
          syncStats: false,
          statsSyncMode: StatisticsSyncMode.merge,
          syncAudioBook: false,
        ),
        throwsA(isA<InterconnectHostChangedException>()),
      );
      final ReaderPositionRow pos = (await db.getReaderPosition(book.uid))!;
      expect(pos.updatedAt, 100);
      expect(pos.normCharOffset, 6000);
      expect(backend.progressWrites, 0);
      expect(await db.getSyncBaseline(_assetKey, _hostScoped('a')), 100);
      expect(await db.getSyncBaseline(_assetKey, _hostScoped('b')), isNull);
      expect(
        await db.getSyncBaseline(_assetKey, 'progress__fushiServer'),
        isNull,
      );
    });

    test('host changes during the upload → no baseline recorded', () async {
      final FushiDatabase db = _memDb();
      final EpubBookRow book = await _seedBook(db);
      await _seedPosition(db, book.uid, updatedAt: 300, fraction: 0.6);
      await db.setSyncBaseline(_assetKey, _hostScoped('a'), 100);
      final _SwitchingFileBox backend = _SwitchingFileBox(switchOnExport: true)
        ..remoteTs = 100;

      await expectLater(
        SyncManager(db: db, backend: backend).syncAllBooks(
          syncStats: false,
          statsSyncMode: StatisticsSyncMode.merge,
          syncAudioBook: false,
        ),
        throwsA(isA<InterconnectHostChangedException>()),
      );
      expect(backend.progressWrites, 1);
      expect(await db.getSyncBaseline(_assetKey, _hostScoped('a')), 100);
      expect(await db.getSyncBaseline(_assetKey, _hostScoped('b')), isNull);
      expect(
        await db.getSyncBaseline(_assetKey, 'progress__fushiServer'),
        isNull,
      );
    });
  });
}
