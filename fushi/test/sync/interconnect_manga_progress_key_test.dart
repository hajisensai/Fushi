/// BUG-5352：经互联收进本机的漫画行，书级进度要用**对端键**读写 host。
///
/// 真 [FushiSyncServer] + [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：
/// host 上是一本单卷漫画（bookKey = 对端键），client 上是经
/// [InterconnectMangaCatalog.entryFor] 收下的书架行（bookKey = `interconnect-…`）。
/// 修复前进度读写都拿本机键，host 永远回空、推上去判 missing。
library;

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
  late FushiDatabase clientDb;
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
    clientDb = _memDb();
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
