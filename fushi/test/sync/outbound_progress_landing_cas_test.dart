import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_state_apply_lock.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

/// BUG-3522：本机落 `reader_positions` / 播放断点的出站写口（云导入、互联 client
/// 落地）在「读本地 → 等网络 → 写本地」之间不持任何与 host PUT 共享的锁，且是
/// 无条件写。BUG-3519 让 host 的进度 PUT 只拿同步状态窄锁之后，下面这条时间线
/// 成立：电脑既当互联 host 又跑云同步 → 云导入判定后在等网络 → 手机 PUT 新进度
/// Y 落库、手机记基线 → 云导入用云端旧值 X 盖掉 Y → 手机下一轮 applyRemote，
/// 进度倒退。
///
/// 修法是「比较后写入」：落地时在事务里重读本地时间戳，仍等于判定时读到的值才写，
/// 否则放弃交给下一轮。这里的并发写者一律用**生产接线的真 host 服务**
/// （`LocalLibraryHostService` + app 的窄锁），不是手写一条 upsert 冒充。

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _key = 'book-a';
const int _pageCount = 200;

LocalLibraryHostService _appWiredHost(FushiDatabase db) =>
    LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: runExclusiveWithSync,
      runSyncStateExclusive: runExclusiveWithSyncStateApply,
    );

/// 页式书：`sectionIndex` 就是 0-based 页码，云导入不经字符表折算，断言直观。
Future<EpubBookRow> _seedBook(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _key,
      title: _key,
      epubPath: '/tmp/$_key.epub',
      extractDir: '/tmp/$_key',
      chapterCount: _pageCount,
      chaptersJson: '[]',
      importedAt: 1,
      format: Value(BookFormat.manga.dbValue),
    ),
  );
  await db.upsertAudiobook(
    AudiobooksCompanion.insert(
      bookKey: _key,
      alignmentFormat: 'srt',
      alignmentPath: '/tmp/$_key.srt',
    ),
  );
  return (await db.getEpubBook(_key))!;
}

Future<void> _setLocal(FushiDatabase db, EpubBookRow book, int page, int at) =>
    db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(book.uid),
        sectionIndex: Value(page),
        normCharOffset: const Value(0),
        charOffset: const Value(0),
        updatedAt: Value(at),
      ),
    );

RemoteBookProgress _page(int page, int at) => RemoteBookProgress(
  sectionIndex: page,
  normCharOffset: 0,
  charOffset: 0,
  updatedAtMs: at,
);

/// 云文件箱：一本书的 progress（+ 可选 audioBook）。[onFetchProgress] /
/// [onFetchAudio] 在「网络读」返回前执行——模拟云导入等网络期间别的写者插队。
class _CloudBackend implements SyncBackend {
  _CloudBackend({
    required this.remotePage,
    required this.remoteAt,
    this.remoteAudioSec,
    this.onFetchProgress,
    this.onFetchAudio,
  });

  final int remotePage;
  final int remoteAt;
  final double? remoteAudioSec;
  final Future<void> Function()? onFetchProgress;
  final Future<void> Function()? onFetchAudio;

  static const String _root = 'root';
  static const String _folder = 'folder1';

  @override
  Future<String> findOrCreateRootFolder() async => _root;
  @override
  String? get cachedRootFolderId => _root;
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => _folder;
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async => SyncFileTrio(
    progress: SyncFileRef(
      id: 'prog1',
      name: 'progress_1_6_${remoteAt}_0.0.json',
    ),
    audioBook: remoteAudioSec == null
        ? null
        : SyncFileRef(id: 'audio1', name: 'audioBook_1_6_$remoteAt.json'),
  );
  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    await onFetchProgress?.call();
    return TtuProgress(
      dataId: 0,
      exploredCharCount: remotePage,
      progress: 0,
      lastBookmarkModified: remoteAt,
    );
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    await onFetchAudio?.call();
    return TtuAudioBook(
      title: _key,
      playbackPositionSec: remoteAudioSec!,
      lastAudioBookModified: remoteAt,
    );
  }

  @override
  void clearCache() {}
  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void evictFolderId(String folderId) {}
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected backend call: ${invocation.memberName}',
  );
}

Future<SyncBookResult> _cloudSync(
  FushiDatabase db,
  _CloudBackend backend,
  EpubBookRow book, {
  bool syncAudioBook = false,
}) => SyncManager(db: db, backend: backend).syncBook(
  book: book,
  syncStats: false,
  statsSyncMode: StatisticsSyncMode.merge,
  syncAudioBook: syncAudioBook,
);

/// 互联 host 的进度存储（client 侧视角的远端）。[onPut] 在 PUT 提交前执行。
class _HostBackend extends InterconnectSyncBackend {
  _HostBackend() : super.withProbe((String url, String token) async => true);

  final Map<String, RemoteBookProgress> books = <String, RemoteBookProgress>{};
  final Map<String, PlaybackPosition> audio = <String, PlaybackPosition>{};
  Future<void> Function()? onPut;

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      books[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    await onPut?.call();
    books[bookKey] = progress;
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteAudiobookPosition(
    String bookKey,
  ) async => audio[bookKey] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    await onPut?.call();
    audio[bookKey] = (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 对端 PUT 的时间戳取「当前时刻之前」，避开 BUG-3367 的未来戳截断。
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int phoneAt = now - 60000;

  group('仓储层 CAS 原语', () {
    late FushiDatabase db;
    late EpubBookRow book;

    setUp(() async {
      db = _memDb();
      book = await _seedBook(db);
    });
    tearDown(() => db.close());

    ReaderPositionsCompanion pos(int page, int at) => ReaderPositionsCompanion(
      bookUid: Value(book.uid),
      sectionIndex: Value(page),
      normCharOffset: const Value(0),
      updatedAt: Value(at),
    );

    test('时间戳仍等于期望值才写', () async {
      await _setLocal(db, book, 10, 1000);
      expect(
        await db.upsertReaderPositionIfUnchanged(
          pos(20, 2000),
          expectedUpdatedAt: 1000,
        ),
        isTrue,
      );
      expect((await db.getReaderPosition(book.uid))!.sectionIndex, 20);
    });

    test('时间戳已被改写则放弃，行保持原样', () async {
      await _setLocal(db, book, 10, 1500);
      expect(
        await db.upsertReaderPositionIfUnchanged(
          pos(20, 2000),
          expectedUpdatedAt: 1000,
        ),
        isFalse,
      );
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.sectionIndex, 10);
      expect(row.updatedAt, 1500);
    });

    test('无行按 0 比较：期望 0 可插入，期望非 0 不插入', () async {
      expect(
        await db.upsertReaderPositionIfUnchanged(
          pos(5, 2000),
          expectedUpdatedAt: 1000,
        ),
        isFalse,
      );
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(
        await db.upsertReaderPositionIfUnchanged(
          pos(5, 2000),
          expectedUpdatedAt: 0,
        ),
        isTrue,
      );
      expect((await db.getReaderPosition(book.uid))!.sectionIndex, 5);
    });

    test('偏好时间戳 CAS：一致才执行写入，不一致不执行', () async {
      const String stamp = 'audiobook_pos_at_x';
      bool wrote = false;
      Future<void> write() async {
        wrote = true;
        await db.setPrefTyped<int>('audiobook_pos_x', 42);
      }

      await db.setPrefTyped<int>(stamp, 700);
      expect(
        await db.runIfIntPrefUnchanged(
          stampKey: stamp,
          expectedStamp: 600,
          write: write,
        ),
        isFalse,
      );
      expect(wrote, isFalse);
      expect(await db.getPrefTyped<int>('audiobook_pos_x', 0), 0);

      expect(
        await db.runIfIntPrefUnchanged(
          stampKey: stamp,
          expectedStamp: 700,
          write: write,
        ),
        isTrue,
      );
      expect(await db.getPrefTyped<int>('audiobook_pos_x', 0), 42);
    });
  });

  group('云导入（SyncManager）', () {
    late FushiDatabase db;
    late EpubBookRow book;
    late LocalLibraryHostService host;
    late String dim;

    setUp(() async {
      db = _memDb();
      book = await _seedBook(db);
      host = _appWiredHost(db);
      // 本机第 10 页 @1000，与云端在 1000 达成过一致；之后云端被别的设备推到
      // 第 50 页 @5000 —— 自动路径判「只远端动了」→ 导入。
      await _setLocal(db, book, 10, 1000);
    });
    tearDown(() => db.close());

    Future<void> seedBaseline(_CloudBackend backend) async {
      dim = progressBaselineDimensionOf(backend);
      await db.setSyncBaseline(_key, dim, 1000);
    }

    test('对照：无插队时照常导入并推进基线', () async {
      final _CloudBackend backend = _CloudBackend(
        remotePage: 50,
        remoteAt: 5000,
      );
      await seedBaseline(backend);
      final SyncBookResult r = await _cloudSync(db, backend, book);
      expect(r.direction, SyncResult.imported);
      expect((await db.getReaderPosition(book.uid))!.sectionIndex, 50);
      expect(await db.getSyncBaseline(_key, dim), 5000);
    });

    test('判定后等网络期间对端 PUT 了新进度：不被云端旧值盖掉，不记基线', () async {
      final _CloudBackend backend = _CloudBackend(
        remotePage: 50,
        remoteAt: 5000,
        // 手机经互联 PUT 第 120 页（真 host 服务、生产窄锁）。
        onFetchProgress: () => host.putBookProgress(_key, _page(120, phoneAt)),
      );
      await seedBaseline(backend);

      final SyncBookResult r = await _cloudSync(db, backend, book);

      expect(r.direction, SyncResult.skipped);
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.sectionIndex, 120, reason: '对端新进度必须保留');
      expect(row.updatedAt, phoneAt);
      // host 回给对端的仍是对端那份，对端下一轮不会 applyRemote 倒退。
      final RemoteBookProgress served = await host.getBookProgress(_key);
      expect(served.sectionIndex, 120);
      expect(served.updatedAtMs, phoneAt);
      expect(await db.getSyncBaseline(_key, dim), 1000, reason: '放弃落地不推进基线');
    });

    test('有声书断点：拉取期间对端 PUT 了新断点，不被云端旧断点盖掉', () async {
      await db.setPrefTyped<int>(audiobookPositionPrefKey(_key), 1000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey(_key), 100);
      final _CloudBackend backend = _CloudBackend(
        remotePage: 50,
        remoteAt: 5000,
        remoteAudioSec: 30,
        onFetchAudio: () => host.putAudiobookPosition(_key, 64000, phoneAt),
      );
      await seedBaseline(backend);

      await _cloudSync(db, backend, book, syncAudioBook: true);

      expect(await host.getAudiobookPosition(_key), (
        positionMs: 64000,
        updatedAtMs: phoneAt,
      ));
    });

    test('有声书断点对照：无插队时照常导入', () async {
      await db.setPrefTyped<int>(audiobookPositionPrefKey(_key), 1000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey(_key), 100);
      final _CloudBackend backend = _CloudBackend(
        remotePage: 50,
        remoteAt: 5000,
        remoteAudioSec: 30,
      );
      await seedBaseline(backend);

      await _cloudSync(db, backend, book, syncAudioBook: true);

      expect(
        await db.getPrefTyped<int>(audiobookPositionPrefKey(_key), 0),
        30000,
      );
    });
  });

  group('互联 client 落地（InterconnectBookProgressSync）', () {
    late FushiDatabase db;
    late EpubBookRow book;
    late _HostBackend remoteHost;
    late InterconnectBookProgressSync sync;
    late LocalLibraryHostService localHost;

    setUp(() async {
      db = _memDb();
      book = await _seedBook(db);
      remoteHost = _HostBackend();
      sync = InterconnectBookProgressSync(db: db, backend: remoteHost);
      localHost = _appWiredHost(db);
      // 本机与远端 host 在第 30 页达成一致；之后远端 host 被推到第 80 页。
      await _setLocal(db, book, 30, 1000);
      await sync.recordBaseline(book, _page(30, 1000));
      remoteHost.books[_key] = _page(80, 2000);
    });
    tearDown(() => db.close());

    test('判定为 applyRemote 后本地被对端 PUT 改写：不落地、不记基线', () async {
      final RemoteBookProgress local = await sync.localProgress(book);
      final RemoteBookProgress remote = await sync.remoteProgress(book);
      expect(
        await sync.decide(book, local: local, remote: remote),
        BookProgressSyncAction.applyRemote,
      );

      // 判定之后、落地之前：手机经本机 host PUT 第 120 页。
      await localHost.putBookProgress(_key, _page(120, phoneAt));

      expect(await sync.applyRemote(book, remote, local: local), isFalse);
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.sectionIndex, 120);
      expect(row.updatedAt, phoneAt);
      expect(
        (await sync.baseline(book))!.matches(_page(30, 1000)),
        isTrue,
        reason: '放弃落地不推进基线',
      );
    });

    test('对照：无插队时 applyRemote 照常落地并记基线', () async {
      final RemoteBookProgress local = await sync.localProgress(book);
      final RemoteBookProgress remote = await sync.remoteProgress(book);
      expect(await sync.applyRemote(book, remote, local: local), isTrue);
      expect((await db.getReaderPosition(book.uid))!.sectionIndex, 80);
      expect((await sync.baseline(book))!.matches(remote), isTrue);
    });

    test('pushLocal 抬戳写回期间本地被改写：不用抬戳旧位置盖掉', () async {
      // 本机读到第 40 页 @1500（早于 host 的 2000 → 推送时要抬戳写回本地）。
      await _setLocal(db, book, 40, 1500);
      await sync.recordBaseline(book, _page(30, 1000));
      remoteHost.books[_key] = _page(30, 2000);
      final RemoteBookProgress local = await sync.localProgress(book);
      final RemoteBookProgress remote = await sync.remoteProgress(book);
      remoteHost.onPut = () =>
          localHost.putBookProgress(_key, _page(120, phoneAt));

      await sync.pushLocal(book, local: local, remote: remote, nowMs: 3000);

      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.sectionIndex, 120);
      expect(row.updatedAt, phoneAt);
    });
  });

  group('互联 client 落地（InterconnectPlaybackPositionSync）', () {
    late FushiDatabase db;
    late _HostBackend remoteHost;
    late InterconnectPlaybackPositionSync sync;
    late LocalLibraryHostService localHost;

    setUp(() async {
      db = _memDb();
      await _seedBook(db);
      remoteHost = _HostBackend();
      sync = InterconnectPlaybackPositionSync(
        db: db,
        backend: remoteHost,
        kind: PlaybackPositionKind.audiobook,
      );
      localHost = _appWiredHost(db);
      await db.setPrefTyped<int>(audiobookPositionPrefKey(_key), 1000);
      await db.setPrefTyped<int>(audiobookPositionAtPrefKey(_key), 100);
      await sync.recordBaseline(_key, 1000);
      remoteHost.audio[_key] = (positionMs: 5000, updatedAtMs: 200);
    });
    tearDown(() => db.close());

    test('判定为 applyRemote 后本端断点被对端 PUT 改写：不落地、不记基线', () async {
      final PlaybackPosition local = await sync.localPosition(_key);
      final PlaybackPosition remote = await sync.remotePosition(_key);
      expect(
        await sync.decide(_key, local: local, remote: remote),
        BookProgressSyncAction.applyRemote,
      );

      await localHost.putAudiobookPosition(_key, 64000, phoneAt);

      expect(await sync.applyRemote(_key, remote, local: local), isFalse);
      expect(await sync.localPosition(_key), (
        positionMs: 64000,
        updatedAtMs: phoneAt,
      ));
      expect(await sync.baseline(_key), 1000);
    });

    test('对照：无插队时 applyRemote 照常落地', () async {
      final PlaybackPosition local = await sync.localPosition(_key);
      final PlaybackPosition remote = await sync.remotePosition(_key);
      expect(await sync.applyRemote(_key, remote, local: local), isTrue);
      expect(await sync.localPosition(_key), remote);
      expect(await sync.baseline(_key), 5000);
    });
  });
}
