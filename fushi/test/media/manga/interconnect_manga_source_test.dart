import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_reader_chapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 互联漫画源端到端：真 [FushiSyncServer] + 真 [InterconnectSyncBackend] + 真适配器
/// + 真页缓存。
///
/// 不 mock backend 的理由：这个源的全部价值就在「HTTP 往返 + 鉴权 + 缓存」这条链上，
/// 把 backend 换成假的等于把被测对象换掉了。
class _MangaHost extends Fake
    implements FushiLibraryHostService, MangaLibraryHost {
  _MangaHost(this.pageBytes);

  final List<List<int>> pageBytes;
  int manifestCalls = 0;
  final List<int> servedPages = <int>[];

  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[
        const RemoteBookInfo(
          title: 'よつばと！1',
          bookKey: 'yotsuba-1',
          hasContent: false,
          format: 'manga',
          hasMangaContent: true,
          mangaReadingMode: 'spread',
        ),
        // 有 manga 行但没内容（占位合集）：不该出现在源里。
        const RemoteBookInfo(
          title: '空合集',
          bookKey: 'empty',
          hasContent: false,
          format: 'manga',
        ),
        // 普通 EPUB：漫画源里不该出现。
        const RemoteBookInfo(
          title: '吾輩は猫である',
          bookKey: 'neko',
          hasContent: true,
        ),
      ];

  @override
  Future<RemoteMangaManifest> mangaManifest(String bookKey) async {
    manifestCalls++;
    if (bookKey != 'yotsuba-1') {
      throw StateError('manga book not found: $bookKey');
    }
    return RemoteMangaManifest(
      bookKey: 'yotsuba-1',
      title: 'よつばと！1',
      readingMode: 'spread',
      pages: <RemoteMangaPageInfo>[
        for (int i = 0; i < pageBytes.length; i++)
          RemoteMangaPageInfo(index: i, name: 'p$i.jpg'),
      ],
    );
  }

  @override
  Future<File> mangaPageFile(String bookKey, int index) async {
    if (bookKey != 'yotsuba-1' || index < 0 || index >= pageBytes.length) {
      throw StateError('manga page out of range: $bookKey#$index');
    }
    servedPages.add(index);
    final File file = File(
      '${Directory.systemTemp.createTempSync('hbk_page').path}/p$index.jpg',
    );
    file.writeAsBytesSync(pageBytes[index]);
    return file;
  }
}

/// 老版本 host：库服务在，但不供漫画页。
class _LegacyHost extends Fake implements FushiLibraryHostService {
  @override
  Future<List<RemoteBookInfo>> listBooks() async => const <RemoteBookInfo>[
        RemoteBookInfo(
          title: 'よつばと！1',
          bookKey: 'yotsuba-1',
          hasContent: false,
          format: 'manga',
          hasMangaContent: true,
        ),
      ];
}

Future<InterconnectSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final SyncRepository repo = SyncRepository(
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory())),
  );
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String url, String tok) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  // 刻意**不**装 TestWidgetsFlutterBinding：它会把所有 HttpClient 请求短路成 400，
  // 而本文件的全部价值就在真 HTTP 往返上（同 `fushi_client_live_book_test.dart`）。
  const String token = 'manga-source-token';
  // 每页 4 字节，末位是页序：能逐字节断言「第 N 页拿到的确实是第 N 页」。
  final List<List<int>> pageBytes = <List<int>>[
    <int>[0xFF, 0xD8, 0xFF, 0],
    <int>[0xFF, 0xD8, 0xFF, 1],
    <int>[0xFF, 0xD8, 0xFF, 2],
  ];

  late _MangaHost host;
  late FushiSyncServer server;
  late InterconnectSyncBackend backend;
  late Directory managed;

  setUp(() async {
    host = _MangaHost(pageBytes);
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_mangasrc').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
    backend = await _buildBackend(
      base: 'http://127.0.0.1:${server.port}',
      token: token,
    );
    managed = Directory.systemTemp.createTempSync('hbk_mangasrc_managed');
  });

  tearDown(() async {
    await server.stop();
    if (managed.existsSync()) managed.deleteSync(recursive: true);
  });

  OnlineMangaLibraryEntry entryOf(RemoteBookInfo book) =>
      InterconnectMangaCatalog.entryFor(book);

  test('源清单只留「是漫画且有内容」的对端条目', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    expect(series.map((RemoteBookInfo b) => b.bookKey), <String>['yotsuba-1']);
  });

  test('书架身份用 interconnect 前缀，与其它运行时天然不撞键空间', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(
      entryOf(series.single),
    );
    expect(bookKey, startsWith('interconnect-'));
    // 同一本反复推导必须逐字稳定——它同时是主键和磁盘目录名。
    expect(
        bookKey, OnlineMangaLibraryService.bookKeyOf(entryOf(series.single)));
  });

  test('refresh 给出整卷那一章', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaRefreshResult result =
        await InterconnectLibraryAdapter(backend: backend).refresh(
      entryOf(series.single),
    );
    expect(result.series.title, 'よつばと！1');
    expect(result.chapters.length, 1);
    expect(result.chapters.single.key, 'yotsuba-1');
    expect(result.series.raw['readingMode'], 'spread');
  });

  test('开章 → 逐页真取到对端字节，且页序不串', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(series.single);
    final OnlineMangaReaderChapter chapter =
        await InterconnectLibraryAdapter(backend: backend).openChapter(
      entry: entry,
      chapter: entry.chapters.single,
      managedDirectory: managed,
      persistProgress: false,
    );
    expect(chapter.pageCount, 3);
    expect(chapter.pageIdentities.toSet().length, 3, reason: '每页身份必须互不相同');

    final MangaReaderSession session = await chapter.openPageSession();
    addTearDown(session.close);
    for (int i = 0; i < 3; i++) {
      final MangaPageBytes page = await session.page(i);
      expect(page.bytes, Uint8List.fromList(pageBytes[i]));
    }
    expect(host.servedPages, <int>[0, 1, 2]);
  });

  test('页图落磁盘缓存，第二次读不再打对端', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(series.single);
    final OnlineMangaReaderChapter chapter =
        await InterconnectLibraryAdapter(backend: backend).openChapter(
      entry: entry,
      chapter: entry.chapters.single,
      managedDirectory: managed,
      persistProgress: false,
    );
    final MangaReaderSession session = await chapter.openPageSession();
    addTearDown(session.close);

    await session.page(0);
    expect(host.servedPages, <int>[0]);
    await session.page(0);
    expect(host.servedPages, <int>[0], reason: '命中磁盘缓存就不该再向对端要一次');
  });

  test('预取失败不冒泡（相邻页抖动不该打断当前页阅读）', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(series.single);
    final OnlineMangaReaderChapter chapter =
        await InterconnectLibraryAdapter(backend: backend).openChapter(
      entry: entry,
      chapter: entry.chapters.single,
      managedDirectory: managed,
      persistProgress: false,
    );
    final MangaReaderSession session = await chapter.openPageSession();
    addTearDown(session.close);
    await server.stop(); // 对端下线 → 预取全部失败
    await expectLater(session.prefetchAround(1), completes);
  });

  test('身份掺入配对凭据命名空间：换对端不复用上一台的页缓存', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(series.single);
    final InterconnectReaderChapter chapter = InterconnectReaderChapter(
      backend: backend,
      bookKey: 'yotsuba-1',
      title: 'よつばと！1',
      pages: const <RemoteMangaPageInfo>[
        RemoteMangaPageInfo(index: 0, name: 'p0.jpg'),
      ],
      managedDirectory: managed,
      persistProgress: false,
    );
    final InterconnectSyncBackend other = await _buildBackend(
      base: 'http://127.0.0.1:${server.port}',
      token: 'a-different-token',
    );
    final InterconnectReaderChapter otherChapter = InterconnectReaderChapter(
      backend: other,
      bookKey: 'yotsuba-1',
      title: 'よつばと！1',
      pages: const <RemoteMangaPageInfo>[
        RemoteMangaPageInfo(index: 0, name: 'p0.jpg'),
      ],
      managedDirectory: managed,
      persistProgress: false,
    );
    expect(entry.series.key, 'yotsuba-1');
    expect(
      chapter.pageIdentities.single,
      isNot(otherChapter.pageIdentities.single),
    );
  });

  group('对端不供漫画页（老版本 Fushi）', () {
    late FushiSyncServer legacy;
    late InterconnectSyncBackend legacyBackend;

    setUp(() async {
      legacy = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_legacy').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _LegacyHost(),
      );
      await legacy.start();
      legacyBackend = await _buildBackend(
        base: 'http://127.0.0.1:${legacy.port}',
        token: token,
      );
    });

    tearDown(() async => legacy.stop());

    test('清单照常列出（books 端点是老端点），但开章报「源不可用」而不是「重试」', () async {
      final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
        legacyBackend,
      ).listSeries();
      expect(series.single.bookKey, 'yotsuba-1');

      await expectLater(
        InterconnectLibraryAdapter(backend: legacyBackend).refresh(
          entryOf(series.single),
        ),
        throwsA(
          isA<OnlineMangaUnavailable>().having(
            (OnlineMangaUnavailable e) => e.reason,
            'reason',
            OnlineMangaUnavailableReason.sourceDisabled,
          ),
        ),
      );
    });
  });
}
