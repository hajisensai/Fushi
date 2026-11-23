/// 互联同步分章漫画的每章阅读进度（拍板 design-ic-manga-chapter-progress，反馈 2bNEiehLgw）。
///
/// 真 [FushiSyncServer] + [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：host 上是一部
/// 章节式漫画（bookKey = 对端键），client 上是经 [InterconnectMangaCatalog.entryFor] 收下的书架行
/// （bookKey = `interconnect-…`、`chaptered`）。修复前这类书的章级进度、已读标记、继续阅读落点都
/// 不跨设备：PC 上读到某章第 44 页，安卓接过来仍从头开始。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_manga_chapter_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _peerKey = 'mihon-573c-peer-series';
const String _token = 'interconnect-manga-chapter-progress';

Future<EpubBookRow> _seedHostSeries(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _peerKey,
      title: 'Peer series',
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

/// client 收下对端章节式条目后的书架行（与 `addOnlineMangaShelfRow` 同一份身份推导）。
Future<EpubBookRow> _seedClientShelfRow(FushiDatabase db) async {
  final OnlineMangaLibraryEntry entry = InterconnectMangaCatalog.entryFor(
    const RemoteBookInfo(
      title: 'Peer series',
      hasContent: false,
      bookKey: _peerKey,
      format: 'manga',
      hasMangaChapters: true,
    ),
  );
  final String localKey = InterconnectMangaCatalog.localBookKeyFor(_peerKey);
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: localKey,
      title: 'Peer series',
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

/// 按给定时间戳原样写一章（测试要控制 `updatedAt`）。
Future<void> _putChapter(
  FushiDatabase db,
  EpubBookRow book,
  String chapterKey, {
  required int page,
  required int at,
  int? pages,
  int? readAt,
}) => db.upsertMangaChapterStatesWhere(
  bookUid: book.uid,
  rows: <MangaChapterStateRow>[
    MangaChapterStateRow(
      bookUid: book.uid,
      chapterKey: chapterKey,
      lastPage: page,
      lastFraction: -1,
      pageCount: pages,
      readAt: readAt,
      updatedAt: at,
    ),
  ],
  replaces: (MangaChapterStateRow? existing, MangaChapterStateRow row) => true,
);

Future<MangaChapterStateRow?> _chapter(
  FushiDatabase db,
  EpubBookRow book,
  String chapterKey,
) => db.getMangaChapterState(bookUid: book.uid, chapterKey: chapterKey);

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late FushiDatabase clientDb;
  late InterconnectSyncBackend backend;

  Future<void> startServer({required bool withLibrary}) async {
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: withLibrary
          ? LocalLibraryHostService(
              db: hostDb,
              dictionaryResourceRoot: Directory(work.path),
              packages: SyncAssetPackageService(db: hostDb),
              refreshDictionaryCache: () async {},
              runExclusive: (Future<void> Function() body) => body(),
            )
          : null,
    );
    await server.start();
    final SyncRepository repo = SyncRepository(clientDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(_token);
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('ic_manga_chapters_');
    hostDb = _memDb();
    clientDb = _memDb();
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    await clientDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  SyncOrchestrator orchestrator() => SyncOrchestrator(
    db: clientDb,
    backend: backend,
    dictionaryResourceRoot: work,
    audioDatabaseRoot: work,
    tempDir: work,
    syncStats: false,
    syncAudioBookPosition: false,
    syncContent: false,
    syncMangaContent: false,
    syncAudioBookFiles: false,
    syncDictionary: false,
  );

  test('只有章节式互联漫画走章级同步', () async {
    await startServer(withLibrary: true);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);
    expect(InterconnectMangaChapterSync.hostBookKeyOf(book), _peerKey);
    expect(InterconnectBookProgressSync.syncsBookProgress(book), isFalse);
    final EpubBookRow host = await _seedHostSeries(hostDb);
    expect(InterconnectMangaChapterSync.syncsChapterProgress(host), isFalse);
  });

  test('host 上读到第 2 话第 44 页 → sweep 落到本机，updatedAt 逐字保留、继续阅读落在那一话', () async {
    await startServer(withLibrary: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostSeries(hostDb);
    await _putChapter(
      hostDb,
      hostBook,
      'ch-1',
      page: 19,
      pages: 20,
      readAt: now - 9000,
      at: now - 9000,
    );
    await _putChapter(hostDb, hostBook, 'ch-2', page: 43, at: now - 1000);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncMangaChapterProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.localBookProgressPulled, 1);

    final MangaChapterStateRow ch2 = (await _chapter(clientDb, book, 'ch-2'))!;
    expect(ch2.lastPage, 43);
    expect(ch2.updatedAt, now - 1000);
    expect(ch2.readAt, isNull);
    final MangaChapterStateRow ch1 = (await _chapter(clientDb, book, 'ch-1'))!;
    expect(ch1.readAt, now - 9000);
    expect(ch1.updatedAt, now - 9000);

    // 「继续阅读」按 updatedAt 选章：两端选到同一话。
    final OnlineMangaLibraryEntry entry =
        InterconnectBookProgressSync.interconnectMangaEntryOf(book)!;
    final OnlineMangaLibraryEntry withChapters = entry.copyWith(
      chapters: <OnlineMangaChapter>[
        const OnlineMangaChapter(
          key: 'ch-2',
          name: '2',
          raw: <String, Object?>{},
        ),
        const OnlineMangaChapter(
          key: 'ch-1',
          name: '1',
          raw: <String, Object?>{},
        ),
      ],
    );
    expect(
      continueMangaChapterIndex(
        withChapters,
        await clientDb.getMangaChapterStates(book.uid),
        target: MangaResumeTarget.lastPosition,
      ),
      0,
    );

    // 再跑一轮：两端已一致，什么都不写。
    final SyncRunReport again = SyncRunReport();
    await orchestrator().syncMangaChapterProgressLiveForTest(again, backend);
    expect(again.localBookProgressPulled, 0);
    expect(again.bookProgressSent, 0);
  });

  test('本机往后读、标已读 / 未读 → 推给 host；同一轮里 host 较新的章照样拉下来', () async {
    await startServer(withLibrary: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostSeries(hostDb);
    await _putChapter(
      hostDb,
      hostBook,
      'ch-1',
      page: 0,
      readAt: now - 9000,
      at: now - 9000,
    );
    await _putChapter(hostDb, hostBook, 'ch-2', page: 10, at: now - 5000);
    await _putChapter(hostDb, hostBook, 'ch-4', page: 7, at: now - 100);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);
    await _putChapter(clientDb, book, 'ch-2', page: 30, at: now - 1000);
    await _putChapter(clientDb, book, 'ch-4', page: 2, at: now - 4000);
    // 本机「标为未读」：readAt 置空、戳更新。
    await _putChapter(clientDb, book, 'ch-1', page: 0, at: now - 500);
    // 本机「标记已读」一章 host 从没碰过的。
    await _putChapter(
      clientDb,
      book,
      'ch-3',
      page: 0,
      readAt: now - 600,
      at: now - 600,
    );

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncMangaChapterProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.bookProgressSent, 1);
    expect(report.localBookProgressPulled, 1);

    final MangaChapterStateRow h1 = (await _chapter(hostDb, hostBook, 'ch-1'))!;
    expect(h1.readAt, isNull);
    expect(h1.updatedAt, now - 500);
    expect((await _chapter(hostDb, hostBook, 'ch-2'))!.lastPage, 30);
    expect((await _chapter(hostDb, hostBook, 'ch-3'))!.readAt, now - 600);
    // host 那份更新：不被本机旧值盖掉，反而落到本机。
    expect((await _chapter(hostDb, hostBook, 'ch-4'))!.lastPage, 7);
    final MangaChapterStateRow c4 = (await _chapter(clientDb, book, 'ch-4'))!;
    expect(c4.lastPage, 7);
    expect(c4.updatedAt, now - 100);
  });

  test('退出书的单本同步也走章级 LWW（不出冲突）', () async {
    await startServer(withLibrary: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EpubBookRow hostBook = await _seedHostSeries(hostDb);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);
    await _putChapter(clientDb, book, 'ch-7', page: 43, at: now - 10);

    final SyncConflict? conflict = await syncExitedBookOnChannel(
      db: clientDb,
      repo: SyncRepository(clientDb),
      backend: backend,
      book: book,
    );
    expect(conflict, isNull);
    final MangaChapterStateRow h7 = (await _chapter(hostDb, hostBook, 'ch-7'))!;
    expect(h7.lastPage, 43);
    expect(h7.updatedAt, now - 10);
  });

  test('host 上没有这本漫画 → 404 → 静默跳过，不报错', () async {
    await startServer(withLibrary: true);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);
    await _putChapter(clientDb, book, 'ch-1', page: 3, at: 1000);
    final MangaChapterSyncStep step = await InterconnectMangaChapterSync(
      db: clientDb,
      backend: backend,
    ).syncOne(book);
    expect(step.supported, isFalse);
    expect(step.pushed, 0);
  });

  test('老 host（不报能力位、端点 404）：sweep 与退出书都静默跳过', () async {
    await startServer(withLibrary: false);
    final EpubBookRow book = await _seedClientShelfRow(clientDb);
    await _putChapter(clientDb, book, 'ch-1', page: 3, at: 1000);

    final SyncRunReport report = SyncRunReport();
    await orchestrator().syncMangaChapterProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.bookProgressSent, 0);

    expect(
      await syncExitedBookOnChannel(
        db: clientDb,
        repo: SyncRepository(clientDb),
        backend: backend,
        book: book,
      ),
      isNull,
    );
    expect((await _chapter(clientDb, book, 'ch-1'))!.lastPage, 3);
  });
}
