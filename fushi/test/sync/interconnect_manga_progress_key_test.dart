/// BUG-5352：经互联收进本机的漫画行，书级进度要用**对端键**读写 host。
///
/// 真 [FushiSyncServer] + [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：
/// host 上是一本单卷漫画（bookKey = 对端键），client 上是经
/// [InterconnectMangaCatalog.entryFor] 收下的书架行（bookKey = `interconnect-…`）。
/// 修复前进度读写都拿本机键，host 永远回空、推上去判 missing。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 同步落地写章级进度时（第一次 [saveMangaChapterState]）先跑一次 [onFirstChapterWrite]，
/// 用来把「本机阅读器翻页」/「章级写失败」钉在书级写与章级写之间（BUG-5358）。
class _HookedDb extends FushiDatabase {
  _HookedDb() : super.forTesting(DatabaseConnection(NativeDatabase.memory()));

  Future<void> Function()? onFirstChapterWrite;

  @override
  Future<void> saveMangaChapterState({
    required String bookUid,
    required String chapterKey,
    required int lastPage,
    int lastFraction = -1,
    int? pageCount,
    int? readAt,
  }) async {
    final Future<void> Function()? hook = onFirstChapterWrite;
    onFirstChapterWrite = null;
    if (hook != null) await hook();
    await super.saveMangaChapterState(
      bookUid: bookUid,
      chapterKey: chapterKey,
      lastPage: lastPage,
      lastFraction: lastFraction,
      pageCount: pageCount,
      readAt: readAt,
    );
  }
}

const String _peerKey = 'mihon-573c-peer-volume';

Future<EpubBookRow> _seedHostVolume(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _peerKey,
      title: 'Peer volume',
      epubPath: '',
      extractDir: '/tmp/$_peerKey',
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
    ),
  );
  return (await db.getEpubBook(_peerKey))!;
}

/// client 收下对端 [_peerKey] 后的书架行（与 `addOnlineMangaShelfRow` 同一份身份推导）。
Future<EpubBookRow> _seedClientShelfRow(
  FushiDatabase db, {
  required bool chaptered,
}) async {
  final OnlineMangaLibraryEntry entry = InterconnectMangaCatalog.entryFor(
    RemoteBookInfo(
      title: 'Peer volume',
      hasContent: false,
      bookKey: _peerKey,
      format: 'manga',
      hasMangaContent: !chaptered,
      hasMangaChapters: chaptered,
    ),
  );
  final String localKey = InterconnectMangaCatalog.localBookKeyFor(_peerKey);
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: localKey,
      title: 'Peer volume',
      epubPath: '',
      extractDir: '',
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
      sourceMetadata: Value<String?>(entry.encode()),
    ),
  );
  return (await db.getEpubBook(localKey))!;
}

Future<void> _setPage(FushiDatabase db, EpubBookRow book, int page, int at) =>
    db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value<String>(book.uid),
        sectionIndex: Value<int>(page),
        normCharOffset: const Value<int>(0),
        charOffset: const Value<int>(0),
        updatedAt: Value<int>(at),
      ),
    );

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late LocalLibraryHostService host;
  late _HookedDb clientDb;
  late InterconnectSyncBackend backend;
  const String token = 'interconnect-manga-progress-key';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('ic_manga_progress_key_');
    hostDb = _memDb();
    host = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
    clientDb = _HookedDb();
    final SyncRepository repo = SyncRepository(clientDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    await clientDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  InterconnectBookProgressSync newSync() =>
      InterconnectBookProgressSync(db: clientDb, backend: backend);

  test('单卷互联漫画：host 读到第 44 页 → client 拉到本机，章级进度也落到同一页', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostVolume(hostDb);
    await _setPage(hostDb, hostBook, 43, now - 1000);
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: false,
    );
    expect(book.bookKey, isNot(_peerKey));
    expect(InterconnectBookProgressSync.hostBookKeyOf(book), _peerKey);

    final InterconnectBookProgressSync sync = newSync();
    final RemoteBookProgress remote = await sync.remoteProgress(book);
    expect(remote.sectionIndex, 43);
    expect(remote.updatedAtMs, now - 1000);

    final BookProgressSyncStep step = await sync.syncOne(book, remote: remote);
    expect(step.action, BookProgressSyncAction.applyRemote);
    expect(step.localChanged, isTrue);
    expect((await clientDb.getReaderPosition(book.uid))!.sectionIndex, 43);
    // 书架在线条目开章只认章级进度：唯一一章（key = 对端键）必须落到同一页。
    final MangaChapterStateRow? chapter = await clientDb.getMangaChapterState(
      bookUid: book.uid,
      chapterKey: InterconnectMangaCatalog.chapterFor(_peerKey).key,
    );
    expect(chapter, isNotNull);
    expect(chapter!.lastPage, 43);
  });

  test('sweep 批量快照按对端键取 host 进度', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostVolume(hostDb);
    await _setPage(hostDb, hostBook, 43, now - 1000);
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: false,
    );

    final List<Future<RemoteBookProgressRead>> reads = await newSync()
        .readRemoteForSweep(<EpubBookRow>[book]);
    final RemoteBookProgressRead read = await reads.single;
    expect(read.error, isNull);
    expect(read.progress!.sectionIndex, 43);
  });

  test('单卷互联漫画：client 往后读了 → 推给 host 的对端那一行', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostVolume(hostDb);
    await _setPage(hostDb, hostBook, 43, now - 5000);
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: false,
    );
    final InterconnectBookProgressSync sync = newSync();
    await sync.syncOne(book, remote: await sync.remoteProgress(book));

    await _setPage(clientDb, book, 60, now);
    final BookProgressSyncStep step = await sync.syncOne(
      book,
      remote: await sync.remoteProgress(book),
    );

    expect(step.action, BookProgressSyncAction.pushLocal);
    expect(step.pushed, isTrue);
    expect((await host.getBookProgress(_peerKey)).sectionIndex, 60);
  });

  // BUG-5358：同步落地先比较后写书级、再写章级。两次写之间本机阅读器翻页（阅读器
  // 同样先书级后章级），章级若照写 host 旧页，书级是新页、章级退回旧页，书架开章
  // 只认章级 → 新页丢失。两张表的落地在一个事务里，阅读器的写只能整体排在前或后。
  test('单卷互联漫画：同步落地夹着本机翻页 → 书级与章级都保留本机新页', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostVolume(hostDb);
    await _setPage(hostDb, hostBook, 43, now - 1000);
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: false,
    );
    final String chapterKey = InterconnectMangaCatalog.chapterFor(_peerKey).key;

    // 阅读器的写入协议：一个事务，先书级后章级（`MangaFushiPage._persistPosition`）。
    // 在根 zone 里起，模拟与同步并发的另一个写者（不并进同步的事务）。
    Future<void> readerTurnsTo60() => clientDb.transaction(() async {
      await _setPage(clientDb, book, 60, now + 10);
      await clientDb.saveMangaChapterState(
        bookUid: book.uid,
        chapterKey: chapterKey,
        lastPage: 60,
      );
    });
    Future<void>? reader;
    clientDb.onFirstChapterWrite = () async {
      reader = Zone.root.run(readerTurnsTo60);
      // 并发写者能插队就让它先写完（修复前它在此刻已落盘）；被事务挡在后面时
      // 它在事务结束前不会完成，等到上限后照常继续。
      await Future.any(<Future<void>>[
        reader!,
        Future<void>.delayed(const Duration(milliseconds: 300)),
      ]);
    };

    final InterconnectBookProgressSync sync = newSync();
    final BookProgressSyncStep step = await sync.syncOne(
      book,
      remote: await sync.remoteProgress(book),
    );
    expect(step.action, BookProgressSyncAction.applyRemote);
    expect(reader, isNotNull, reason: '钩子必须在同步写章级时触发');
    await reader;

    expect((await clientDb.getReaderPosition(book.uid))!.sectionIndex, 60);
    final MangaChapterStateRow? chapter = await clientDb.getMangaChapterState(
      bookUid: book.uid,
      chapterKey: chapterKey,
    );
    expect(chapter!.lastPage, 60, reason: '章级不得被同步退回 host 旧页');
  });

  test('单卷互联漫画：章级写失败 → 书级一并回滚，不留半截、不记基线', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostVolume(hostDb);
    await _setPage(hostDb, hostBook, 43, now - 1000);
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: false,
    );
    clientDb.onFirstChapterWrite = () async =>
        throw StateError('chapter write failed');

    final InterconnectBookProgressSync sync = newSync();
    await expectLater(
      sync.syncOne(book, remote: await sync.remoteProgress(book)),
      throwsA(isA<StateError>()),
    );

    expect(await clientDb.getReaderPosition(book.uid), isNull);
    expect(
      await clientDb.getMangaChapterState(
        bookUid: book.uid,
        chapterKey: InterconnectMangaCatalog.chapterFor(_peerKey).key,
      ),
      isNull,
    );
    expect(await sync.baseline(book), isNull);

    // 下一轮照常拉到两张表。
    final BookProgressSyncStep retry = await sync.syncOne(
      book,
      remote: await sync.remoteProgress(book),
    );
    expect(retry.action, BookProgressSyncAction.applyRemote);
    expect((await clientDb.getReaderPosition(book.uid))!.sectionIndex, 43);
  });

  test('章节式互联漫画：书级位置不带章身份，不参与书级进度同步', () async {
    final EpubBookRow book = await _seedClientShelfRow(
      clientDb,
      chaptered: true,
    );
    expect(InterconnectBookProgressSync.hostBookKeyOf(book), isNull);
    expect(InterconnectBookProgressSync.syncsBookProgress(book), isFalse);
    expect(() => newSync().remoteProgress(book), throwsA(isA<ArgumentError>()));
  });

  test('普通书：wire 键就是本机键', () async {
    await clientDb.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'plain-book',
        title: 'plain',
        epubPath: '/tmp/plain.epub',
        extractDir: '/tmp/plain',
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 1,
      ),
    );
    final EpubBookRow book = (await clientDb.getEpubBook('plain-book'))!;
    expect(InterconnectBookProgressSync.hostBookKeyOf(book), 'plain-book');
  });
}
