import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/download/online_manga_download_gate.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Kavita 章节经运行时无关的 [MangaDownloadService] 逐页下载：页表来自
/// `chapter-info`，页字节来自 `Reader/image`（全部 mock，无真实服务器）。
const int _pages = 4;
const String _chapterKey = '201';

KavitaServerConfig _server() => KavitaServerConfig(
  id: 'srv',
  name: 'Home',
  serverUrl: Uri.parse('https://kavita.test'),
  apiKey: 'SECRETKEY',
);

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.kavita,
  extensionPackage: kKavitaMangaPackage,
  sourceId: 'srv',
  series: OnlineMangaSeries(
    key: '42',
    title: 'Kavita series',
    raw: <String, Object?>{'seriesId': 42, 'libraryId': 1},
  ),
  chapters: <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: _chapterKey,
      name: 'Ch. 5',
      number: 5,
      raw: <String, Object?>{'chapterId': 201, 'volumeId': 11, 'pages': _pages},
    ),
  ],
);

class _NoopKeepAlive implements DownloadKeepAlive {
  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {}

  @override
  Future<void> stop() async {}
}

class _Kavita {
  final Map<int, int> imageRequests = <int, int>{};

  /// 非空时取图先卡在这里（取消用）。
  Completer<void>? gate;

  static Uint8List pngOf(int page) => Uint8List.fromList(
    img.encodePng(img.Image(width: 60 + page, height: 90 + page)),
  );

  KavitaApi api() => KavitaApi(
    serverUrl: 'https://kavita.test',
    apiKey: 'SECRETKEY',
    client: MockClient((http.Request r) async {
      switch (r.url.path) {
        case '/api/Plugin/authenticate':
          return http.Response('{"token":"jwt"}', 200);
        case '/api/Reader/chapter-info':
          return http.Response(
            jsonEncode(<String, Object?>{
              'pages': _pages,
              'seriesId': 42,
              'volumeId': 11,
              'libraryId': 1,
              'seriesFormat': 1,
            }),
            200,
          );
        case '/api/Reader/image':
          final int page = int.parse(r.url.queryParameters['page']!);
          imageRequests[page] = (imageRequests[page] ?? 0) + 1;
          final Completer<void>? pending = gate;
          if (pending != null) await pending.future;
          return http.Response.bytes(pngOf(page), 200);
        case '/api/Image/series-cover':
          return http.Response.bytes(pngOf(0), 200);
      }
      return http.Response('not found', 404);
    }),
  );
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late _Kavita kavita;
  late OnlineMangaLibraryService library;
  late String bookKey;
  late String bookDir;

  MangaDownloadService build() => MangaDownloadService(
    database: db,
    serviceFor: (OnlineMangaRuntimeKind runtime) => library,
    keepAlive: _NoopKeepAlive(),
    wait: (Duration duration) async {},
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-kavita-download-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    kavita = _Kavita();
    final KavitaApi api = kavita.api();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: KavitaLibraryAdapter(
        servers: () => <KavitaServerConfig>[_server()],
        apiFor: (KavitaServerConfig _) => api,
      ),
    );
    final EpubBookRow row = await library.add(_entry());
    bookKey = row.bookKey;
    bookDir = row.extractDir;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MangaDownloadJobRow> job() async => (await db.findMangaDownloadJob(
    kind: MangaDownloadJobKind.chapter,
    bookKey: bookKey,
    chapterKey: _chapterKey,
  ))!;

  test('a Kavita chapter downloads page by page into N files', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow queued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _entry().chapters.single,
      autoOcr: false,
    );
    expect(queued.runtime, 'kavita');
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await job();
    expect(done.status, MangaDownloadJobStatus.done, reason: done.lastError);
    expect(done.pagesDone, _pages);
    expect(done.pagesTotal, _pages);
    expect(done.lastError ?? '', isNot(contains('SECRETKEY')));

    final Directory chapterDir = mangaChapterDirectory(bookDir, _chapterKey);
    final List<File> files = Directory(p.join(chapterDir.path, 'images'))
        .listSync()
        .whereType<File>()
        .where((File f) => !f.path.endsWith('.tmp'))
        .toList();
    expect(files, hasLength(_pages));
    final MokuroPayload payload = parseMangaJson(
      mangaChapterJsonFile(chapterDir).readAsStringSync(),
    );
    expect(payload.images, hasLength(_pages));
    expect(payload.images.first.size.width, 60);
    expect(payload.images.last.size.width, 60 + _pages - 1);
    for (int page = 0; page < _pages; page++) {
      expect(kavita.imageRequests[page], 1, reason: 'page $page fetched once');
    }
    expect(await isChapterDownloaded(bookDir, _chapterKey), isTrue);
    downloads.dispose();
  });

  test(
    'cancelling a running Kavita download deletes the partial chapter',
    () async {
      kavita.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow queued = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _entry().chapters.single,
        autoOcr: false,
      );
      await downloads.start();
      while ((kavita.imageRequests[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await job()).status, MangaDownloadJobStatus.running);
      final Directory chapterDir = mangaChapterDirectory(bookDir, _chapterKey);
      expect(chapterDir.existsSync(), isTrue);

      await downloads.cancel(queued.jobId);
      kavita.gate!.complete();
      await downloads.whenIdle;

      expect((await job()).status, MangaDownloadJobStatus.cancelled);
      expect(chapterDir.existsSync(), isFalse);
      expect(await isChapterDownloaded(bookDir, _chapterKey), isFalse);
      downloads.dispose();
    },
  );

  test('download gate: Kavita downloads stay available on iOS (user-configured '
      'server, 2026-10-27)', () {
    // 用户自己的服务器下载到本机是自有内容的离线副本，不是下载中心。
    expect(
      onlineMangaChapterDownloadsAvailable(
        OnlineMangaRuntimeKind.kavita,
        isIOS: true,
      ),
      isTrue,
    );
    expect(
      onlineMangaChapterDownloadsAvailable(
        OnlineMangaRuntimeKind.kavita,
        isIOS: false,
      ),
      isTrue,
    );
    // 互联对端在 iOS 上必须仍可下载（下载服务文件头的合规说明）。
    for (final OnlineMangaRuntimeKind kind in <OnlineMangaRuntimeKind>[
      OnlineMangaRuntimeKind.interconnect,
      OnlineMangaRuntimeKind.mihon,
    ]) {
      expect(onlineMangaChapterDownloadsAvailable(kind, isIOS: true), isTrue);
    }
  });
}
