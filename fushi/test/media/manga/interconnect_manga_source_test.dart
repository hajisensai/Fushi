import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_image_page.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 互联漫画源端到端：真 [FushiSyncServer] + 真 [InterconnectSyncBackend] + 真适配器。
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
        // 对端的在线书架条目（BUG-2474）：根目录占位、按章下载了两章。
        const RemoteBookInfo(
          title: 'チェンソーマン',
          bookKey: 'mihon-csm',
          hasContent: false,
          format: 'manga',
          hasMangaChapters: true,
        ),
      ];

  /// 章节式条目在 host 上已下载的章（key → 页字节）。
  static const List<String> chapterKeys = <String>[
    '/manga/csm/1',
    '/manga/csm/2'
  ];

  @override
  Future<RemoteMangaManifest> mangaChapterManifest(
    String bookKey,
    String chapterDigest,
  ) async {
    if (!isMangaChapterDigest(chapterDigest)) {
      throw ArgumentError.value(chapterDigest, 'chapterDigest');
    }
    final int chapter = _chapterIndex(bookKey, chapterDigest);
    return RemoteMangaManifest(
      bookKey: bookKey,
      title: 'チェンソーマン',
      pages: <RemoteMangaPageInfo>[
        for (int i = 0; i < 2; i++)
          RemoteMangaPageInfo(index: i, name: 'c${chapter}p$i.jpg'),
      ],
    );
  }

  @override
  Future<File> mangaChapterPageFile(
    String bookKey,
    String chapterDigest,
    int index,
  ) async {
    if (!isMangaChapterDigest(chapterDigest)) {
      throw ArgumentError.value(chapterDigest, 'chapterDigest');
    }
    final int chapter = _chapterIndex(bookKey, chapterDigest);
    if (index < 0 || index >= 2) {
      throw StateError('manga page out of range');
    }
    final File file = File(
      '${Directory.systemTemp.createTempSync('hbk_cpage').path}/p$index.jpg',
    );
    file.writeAsBytesSync(<int>[0xC0, chapter, index]);
    return file;
  }

  int _chapterIndex(String bookKey, String digest) {
    if (bookKey != 'mihon-csm') {
      throw StateError('manga book not found: $bookKey');
    }
    for (int i = 0; i < chapterKeys.length; i++) {
      if (mangaChapterDigest(chapterKeys[i]) == digest) return i;
    }
    throw StateError('manga chapter not downloaded: $digest');
  }

  @override
  Future<RemoteMangaManifest> mangaManifest(String bookKey) async {
    manifestCalls++;
    if (bookKey == 'mihon-csm') {
      return RemoteMangaManifest(
        bookKey: 'mihon-csm',
        title: 'チェンソーマン',
        pages: const <RemoteMangaPageInfo>[],
        chapters: <RemoteMangaChapterInfo>[
          for (int i = 0; i < chapterKeys.length; i++)
            RemoteMangaChapterInfo(
              key: chapterKeys[i],
              name: '第${i + 1}話',
              number: (i + 1).toDouble(),
              pageCount: 2,
            ),
        ],
      );
    }
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
  });

  tearDown(() async {
    await server.stop();
  });

  OnlineMangaLibraryEntry entryOf(RemoteBookInfo book) =>
      InterconnectMangaCatalog.entryFor(book);

  /// 清单里那本单卷漫画（BUG-2474 起清单还会有章节式条目，不能再 `.single`）。
  RemoteBookInfo volumeOf(List<RemoteBookInfo> series) =>
      series.firstWhere((RemoteBookInfo b) => b.bookKey == 'yotsuba-1');

  group('章节式在线条目（BUG-2474）', () {
    RemoteBookInfo csm() => const RemoteBookInfo(
          title: 'チェンソーマン',
          bookKey: 'mihon-csm',
          hasContent: false,
          format: 'manga',
          hasMangaChapters: true,
        );

    test('清单放行 hasMangaChapters 的条目；占位空合集仍不放行', () async {
      final List<RemoteBookInfo> series =
          await InterconnectMangaCatalog(backend).listSeries();
      expect(
        series.map((RemoteBookInfo b) => b.bookKey),
        containsAll(<String>['yotsuba-1', 'mihon-csm']),
      );
      expect(series.map((RemoteBookInfo b) => b.bookKey),
          isNot(contains('empty')));
      expect(InterconnectMangaCatalog.isReadableRemoteManga(csm()), isTrue);
      expect(
        InterconnectMangaCatalog.isReadableRemoteManga(const RemoteBookInfo(
          title: 'x',
          bookKey: 'empty',
          hasContent: false,
          format: 'manga',
        )),
        isFalse,
      );
    });

    test('种子条目没有章；refresh 后章表 = 对端已下载的章，字段逐字透传', () async {
      final OnlineMangaLibraryEntry seed = entryOf(csm());
      expect(seed.chapters, isEmpty);
      expect(seed.series.raw['chaptered'], isTrue);
      final OnlineMangaRefreshResult refreshed =
          await InterconnectLibraryAdapter(backend: backend).refresh(seed);
      expect(
        refreshed.chapters.map((OnlineMangaChapter c) => c.key),
        _MangaHost.chapterKeys,
      );
      expect(refreshed.chapters.first.name, '第1話');
      expect(refreshed.chapters.first.number, 1);
      expect(refreshed.chapters.first.raw['pageCount'], 2);
      expect(refreshed.series.raw['chaptered'], isTrue);
      // 单卷条目刷新后仍是整卷那一章（chaptered=false），两种形状不互相污染。
      final OnlineMangaRefreshResult volume =
          await InterconnectLibraryAdapter(backend: backend).refresh(entryOf(
        const RemoteBookInfo(
          title: 'よつばと！1',
          bookKey: 'yotsuba-1',
          hasContent: false,
          format: 'manga',
          hasMangaContent: true,
        ),
      ));
      expect(volume.chapters.single.key, 'yotsuba-1');
      expect(volume.series.raw['chaptered'], isFalse);
    });

    test('按章解析页表 → 走 /chapters/<digest>/… 端点取到该章该页的字节', () async {
      final InterconnectLibraryAdapter adapter =
          InterconnectLibraryAdapter(backend: backend);
      final OnlineMangaLibraryEntry seed = entryOf(csm());
      final OnlineMangaRefreshResult refreshed = await adapter.refresh(seed);
      final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
        runtime: seed.runtime,
        extensionPackage: seed.extensionPackage,
        sourceId: seed.sourceId,
        series: refreshed.series,
        chapters: refreshed.chapters,
      );
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[1],
      );
      expect(pages, hasLength(2));
      final InterconnectMangaPageRef ref =
          pages.last as InterconnectMangaPageRef;
      expect(ref.chapterDigest, mangaChapterDigest('/manga/csm/2'));
      expect(await adapter.fetchChapterPage(pages.first), <int>[0xC0, 1, 0]);
      expect(await adapter.fetchChapterPage(pages.last), <int>[0xC0, 1, 1]);
    });

    test('对端没下载的章：可重试的 runtimeFailure（不是「源被禁用」）', () async {
      final InterconnectLibraryAdapter adapter =
          InterconnectLibraryAdapter(backend: backend);
      final OnlineMangaLibraryEntry seed = entryOf(csm());
      await expectLater(
        adapter.resolveChapterPages(
          entry: seed,
          chapter: const OnlineMangaChapter(
            key: '/manga/csm/99',
            name: '',
            raw: <String, Object?>{},
          ),
        ),
        throwsA(isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable e) => e.reason,
          'reason',
          OnlineMangaUnavailableReason.runtimeFailure,
        )),
      );
    });
  });

  test('源清单只留「是漫画且有内容」的对端条目', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    // 单卷漫画 + 章节式在线条目都算「有内容」；占位空合集与 EPUB 不进源。
    expect(
      series.map((RemoteBookInfo b) => b.bookKey),
      <String>['yotsuba-1', 'mihon-csm'],
    );
  });

  test('书架身份用 interconnect 前缀，与其它运行时天然不撞键空间', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(
      entryOf(volumeOf(series)),
    );
    expect(bookKey, startsWith('interconnect-'));
    // 同一本反复推导必须逐字稳定——它同时是主键和磁盘目录名。
    expect(bookKey,
        OnlineMangaLibraryService.bookKeyOf(entryOf(volumeOf(series))));
  });

  test('refresh 给出整卷那一章', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaRefreshResult result =
        await InterconnectLibraryAdapter(backend: backend).refresh(
      entryOf(volumeOf(series)),
    );
    expect(result.series.title, 'よつばと！1');
    expect(result.chapters.length, 1);
    expect(result.chapters.single.key, 'yotsuba-1');
    expect(result.series.raw['readingMode'], 'spread');
  });

  test('解析页表 → 逐页真取到对端字节，且页序不串（两段式契约）', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(volumeOf(series));
    final InterconnectLibraryAdapter adapter =
        InterconnectLibraryAdapter(backend: backend);
    final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
      entry: entry,
      chapter: entry.chapters.single,
    );
    expect(pages, hasLength(3));
    expect(
      pages.map((OnlineMangaPageRef page) => page.index).toList(),
      <int>[0, 1, 2],
    );
    expect(pages, everyElement(isA<InterconnectMangaPageRef>()));

    for (int i = 0; i < 3; i++) {
      final Uint8List bytes = await adapter.fetchChapterPage(pages[i]);
      expect(bytes, Uint8List.fromList(pageBytes[i]));
    }
    expect(host.servedPages, <int>[0, 1, 2]);
  });

  test('取页不带缓存：每次 fetchChapterPage 都真打对端（落盘归下载服务）', () async {
    final List<RemoteBookInfo> series = await InterconnectMangaCatalog(
      backend,
    ).listSeries();
    final OnlineMangaLibraryEntry entry = entryOf(volumeOf(series));
    final InterconnectLibraryAdapter adapter =
        InterconnectLibraryAdapter(backend: backend);
    final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
      entry: entry,
      chapter: entry.chapters.single,
    );
    await adapter.fetchChapterPage(pages[0]);
    await adapter.fetchChapterPage(pages[0]);
    expect(host.servedPages, <int>[0, 0]);
  });

  test('别的运行时的页引用一律拒绝（密封分派不靠猜）', () async {
    await expectLater(
      InterconnectLibraryAdapter(backend: backend).fetchChapterPage(
        const AidokuMangaPageRef(
          index: 0,
          page: AidokuImagePage(
            url: 'https://cdn.example/p.jpg',
            headers: <String, String>{},
            context: <String, String>{},
          ),
        ),
      ),
      throwsArgumentError,
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
