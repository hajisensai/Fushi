import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_missing_images.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';

import 'fake_lnreader_runtime.dart';

/// 1×1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// AVIF 文件头（`ftyp` + brand `avif`）：[sniffLnReaderImageMediaType] 不认。
final Uint8List _avif = Uint8List.fromList(<int>[
  0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, //
  0x61, 0x76, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00, //
  0x61, 0x76, 0x69, 0x66, 0x6D, 0x69, 0x66, 0x31, //
  0x6D, 0x69, 0x61, 0x66,
]);

Archive _unzip(Uint8List bytes) => ZipDecoder().decodeBytes(bytes);

String _entry(Archive archive, String name) =>
    utf8.decode(archive.findFile(name)!.content as List<int>);

/// 🔴 本文件**不能**调 `TestWidgetsFlutterBinding.ensureInitialized()`：绑定会把
/// HttpClient 换成恒回 400 的模拟实现，插图下载全部「失败」、断言失去意义。
void main() {
  group('LnReaderBookDownload', () {
    late Directory root;
    late HttpServer images;
    late String imageBase;
    final List<String> requestedPaths = <String>[];

    /// `<Host 头里的主机名><路径>` → 那次请求的头。
    final Map<String, HttpHeaders> requestHeaders = <String, HttpHeaders>{};

    setUp(() async {
      requestedPaths.clear();
      requestHeaders.clear();
      root = await Directory.systemTemp.createTemp('lnreader_download_');
      images = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      imageBase = 'http://127.0.0.1:${images.port}';
      images.listen((HttpRequest request) async {
        requestedPaths.add(request.uri.path);
        requestHeaders['${request.headers.host}${request.uri.path}'] =
            request.headers;
        if (request.uri.path == '/ok.png') {
          request.response.add(_png);
        } else if (request.uri.path == '/auto.img') {
          // 按 Accept 协商格式的图床（Cloudflare Images / imgix auto=format）：
          // 客户端声明能收 AVIF 就回 AVIF，否则回原图。
          final String accept =
              request.headers.value(HttpHeaders.acceptHeader) ?? '';
          request.response.add(accept.contains('image/avif') ? _avif : _png);
        } else if (request.uri.path == '/redirect.png') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://localhost:${images.port}/ok.png',
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await images.close(force: true);
      await root.delete(recursive: true);
    });

    const LnReaderInstalledPlugin plugin = LnReaderInstalledPlugin(
      id: 'test.plugin',
      name: 'Test',
      site: 'https://example.com/',
      lang: '日本語',
      version: '1.0.0',
      url: '',
      iconUrl: '',
      storeUrl: '',
      enabled: true,
      pinned: false,
      sortOrder: 0,
      installedAt: 0,
    );

    const List<LnReaderChapter> chapters = <LnReaderChapter>[
      LnReaderChapter(name: '一', path: '/1'),
      LnReaderChapter(name: '二', path: '/2'),
      LnReaderChapter(name: '三', path: '/3'),
    ];

    const LnReaderNovel novel = LnReaderNovel(
      name: 'テスト小説',
      path: '/novel',
      chapters: chapters,
      totalPages: 1,
      author: '作者',
    );

    Future<(LnReaderManager, FakeLnReaderRuntime)> setUpManager({
      String? chapter2,
      LnReaderCloudflare? cloudflare,
    }) async {
      final FakeLnReaderRuntime runtime = FakeLnReaderRuntime(
        novelResult: novel,
        chapterHtml: <String, String>{
          '/2':
              chapter2 ??
              '<p>図<img src="$imageBase/ok.png"/>と<img src="$imageBase/missing.png"/></p>',
        },
      );
      final LnReaderManager manager = LnReaderManager(
        rootDirectory: root,
        runtime: runtime,
        httpClientFactory: HttpClient.new,
        cloudflare: cloudflare,
      );
      await manager.initialise();
      // 装载只需要插件文件存在。
      await manager.pluginFile(plugin.id).create(recursive: true);
      return (manager, runtime);
    }

    test('逐章抓取 → 一本 EPUB；失败插图只丢那一张；进度逐章上报', () async {
      final (LnReaderManager manager, FakeLnReaderRuntime runtime) =
          await setUpManager();
      Uint8List? imported;
      DuplicatePolicy? usedPolicy;
      final List<int> progress = <int>[];
      final String key =
          await LnReaderBookDownload(
            manager: manager,
            database: FushiDatabase.forTesting(NativeDatabase.memory()),
            httpClientFactory: HttpClient.new,
            isBlockedHost: (String _) => false,
            isBlockedAddress: (InternetAddress _) => false,
            importEpub:
                ({
                  required FushiDatabase db,
                  required Uint8List bytes,
                  required String fileName,
                  required DuplicatePolicy policy,
                }) async {
                  imported = bytes;
                  usedPolicy = policy;
                  expect(fileName, 'テスト小説.epub');
                  return 'book-key';
                },
          ).run(
            plugin: plugin,
            novel: novel,
            chapters: chapters,
            policy: const DuplicatePolicy.skip(),
            onProgress: (int done, int total) => progress.add(done),
          );
      expect(key, 'book-key');
      expect(usedPolicy, isA<SkipDuplicate>());
      expect(progress, <int>[0, 1, 2, 3]);
      expect(
        runtime.calls.where((String c) => c.startsWith('chapter:')),
        <String>['chapter:/1', 'chapter:/2', 'chapter:/3'],
      );
      final Archive archive = _unzip(imported!);
      final String second = _entry(archive, 'OEBPS/chapter-2.xhtml');
      expect(second, contains('src="images/c2-0.png"'));
      expect(
        second,
        isNot(contains('src="images/c2-1.png"')),
        reason: '404 的插图不能留断链。',
      );
      // 留缺图占位（带原图地址、引用页、插件 id），阅读器打开时据此提示并补取。
      final LnReaderMissingImage missing = parseLnReaderMissingImages(
        second,
      ).single;
      expect(missing.fileName, 'images/c2-1.png');
      expect(missing.url, '$imageBase/missing.png');
      expect(missing.pluginId, plugin.id);
      expect(missing.referer, isNotNull);
      expect(archive.findFile('OEBPS/images/c2-0.png'), isNotNull);
      expect(archive.findFile('OEBPS/images/c2-1.png'), isNull);
    });

    // 审查 B1：插图地址来自插件 / 站点。HttpClient 自动跟随重定向时只有首跳过
    // 名字判据，一个 302 指向 localhost 就能打到本机服务。
    test('插图经 302 跳到被拦主机：不跟随、只丢这张图', () async {
      final (
        LnReaderManager manager,
        FakeLnReaderRuntime _,
      ) = await setUpManager(
        chapter2: '<p>図<img src="$imageBase/redirect.png"/></p>',
      );
      Uint8List? imported;
      await LnReaderBookDownload(
        manager: manager,
        database: FushiDatabase.forTesting(NativeDatabase.memory()),
        httpClientFactory: HttpClient.new,
        // 测试服务器在回环上：放行 127.0.0.1，只拦 localhost（模拟「跳到本机」）；
        // 连接层放行，钉住的是「每一跳重新过名字判据」这一处。
        isBlockedHost: (String host) => host == 'localhost',
        isBlockedAddress: (InternetAddress _) => false,
        importEpub:
            ({
              required FushiDatabase db,
              required Uint8List bytes,
              required String fileName,
              required DuplicatePolicy policy,
            }) async {
              imported = bytes;
              return 'book-key';
            },
      ).run(
        plugin: plugin,
        novel: novel,
        chapters: chapters,
        policy: const DuplicatePolicy.skip(),
      );
      expect(requestedPaths, contains('/redirect.png'));
      expect(
        requestedPaths,
        isNot(contains('/ok.png')),
        reason: '重定向目标是被拦主机，一次都不能被请求到。',
      );
      final Archive archive = _unzip(imported!);
      final String second = _entry(archive, 'OEBPS/chapter-2.xhtml');
      expect(second, isNot(contains('src="images/c2-0')));
      expect(
        parseLnReaderMissingImages(second).single.url,
        contains('/redirect.png'),
      );
    });

    group('BUG-4819 章节插图的请求头', () {
      /// 过了 Cloudflare 验证的图床：jar 里有只发给 127.0.0.1 的放行 cookie。
      Future<LnReaderCloudflare> clearedCloudflare() async {
        final LnReaderCloudflare cloudflare = LnReaderCloudflare(
          MangaCookieJar(File('${root.path}/cookies.json')),
        );
        await cloudflare.jar.replaceForHost('127.0.0.1', const <MangaCookie>[
          MangaCookie(
            name: 'cf_clearance',
            value: 'token',
            domain: '127.0.0.1',
            hostOnly: true,
          ),
        ]);
        return cloudflare;
      }

      Future<LnReaderEpubChapter> fetchSecond(
        LnReaderManager manager, {
        LnReaderInstalledPlugin source = plugin,
      }) async {
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory(),
        );
        final LnReaderBookDownload download = LnReaderBookDownload(
          manager: manager,
          database: db,
          httpClientFactory: HttpClient.new,
          isBlockedHost: (String _) => false,
          isBlockedAddress: (InternetAddress _) => false,
        );
        final HttpClient client = download.openClient();
        try {
          final LnReaderPluginInfo info = await manager.load(plugin);
          return await download.fetchChapter(
            client: client,
            plugin: source,
            info: info,
            chapter: chapters[1],
            imagePrefix: 'images/c2-',
          );
        } finally {
          client.close(force: true);
          await db.close();
        }
      }

      // 拍板台 zCkIxtnwcV：源级开关「合并段内换行」只在开了的源上生效。
      test('源开了「合并段内换行」才把句中折行接回去', () async {
        final (LnReaderManager manager, FakeLnReaderRuntime _) =
            await setUpManager(chapter2: '<p>空を見上げると、</p><p>星が瞬いていた。</p>');
        final LnReaderEpubChapter off = await fetchSecond(manager);
        expect(off.xhtmlBody, '<p>空を見上げると、</p><p>星が瞬いていた。</p>');
        final LnReaderEpubChapter on = await fetchSecond(
          manager,
          source: plugin.copyWith(mergeLineBreaks: true),
        );
        expect(on.xhtmlBody, '<p>空を見上げると、星が瞬いていた。</p>');
      });

      test('与封面同一套头：放行 cookie、Accept、浏览器 UA；Referer 是章节页', () async {
        final (
          LnReaderManager manager,
          FakeLnReaderRuntime _,
        ) = await setUpManager(
          chapter2: '<p>図<img src="$imageBase/ok.png"/></p>',
          cloudflare: await clearedCloudflare(),
        );
        final LnReaderEpubChapter chapter = await fetchSecond(manager);
        expect(chapter.images, hasLength(1));
        final HttpHeaders headers = requestHeaders['127.0.0.1/ok.png']!;
        expect(
          headers.value(HttpHeaders.cookieHeader),
          'cf_clearance=token',
          reason: '修复前插图不带放行 cookie：过了验证的站点插图照样被拦。',
        );
        expect(headers.value(HttpHeaders.acceptHeader), contains('image/'));
        expect(
          headers.value(HttpHeaders.userAgentHeader),
          LnReaderFetchBridge.defaultUserAgent,
          reason: 'cf_clearance 绑定解题时的 UA。',
        );
        expect(
          headers.value(HttpHeaders.refererHeader),
          'https://example.com/2',
          reason: 'Referer 是章节页地址，不退成站点首页。',
        );
      });

      test('按 Accept 协商格式的图床：不声明 AVIF，拿回嗅探认得的原图（插图与封面）', () async {
        expect(
          sniffLnReaderImageMediaType(_avif),
          isNull,
          reason: '前提：嗅探不认 AVIF。认了的话这条测试与 Accept 的收窄都该重看。',
        );
        final (
          LnReaderManager manager,
          FakeLnReaderRuntime _,
        ) = await setUpManager(
          chapter2: '<p>図<img src="$imageBase/auto.img"/></p>',
        );
        final LnReaderEpubChapter chapter = await fetchSecond(manager);
        expect(
          chapter.images.single.mediaType,
          'image/png',
          reason: '声明 image/avif 时图床回 AVIF，嗅探不认，整张图被当成「不是图片」丢掉。',
        );
        expect(
          requestHeaders['127.0.0.1/auto.img']!.value(HttpHeaders.acceptHeader),
          LnReaderBookDownload.epubImageAccept,
        );
        expect(LnReaderBookDownload.epubImageAccept, isNot(contains('avif')));

        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory(),
        );
        final LnReaderBookDownload download = LnReaderBookDownload(
          manager: manager,
          database: db,
          httpClientFactory: HttpClient.new,
          isBlockedHost: (String _) => false,
          isBlockedAddress: (InternetAddress _) => false,
        );
        final HttpClient client = download.openClient();
        try {
          final LnReaderEpubImage? cover = await download.fetchCover(
            client: client,
            plugin: plugin,
            info: await manager.load(plugin),
            novel: LnReaderNovel(
              name: 'N',
              path: '/n',
              cover: '$imageBase/auto.img',
              chapters: const <LnReaderChapter>[],
              totalPages: 1,
            ),
          );
          expect(cover?.mediaType, 'image/png');
        } finally {
          client.close(force: true);
          await db.close();
        }
      });

      test('重定向到别的主机：上一跳的 cookie 不跟过去', () async {
        final (
          LnReaderManager manager,
          FakeLnReaderRuntime _,
        ) = await setUpManager(
          chapter2: '<p>図<img src="$imageBase/redirect.png"/></p>',
          cloudflare: await clearedCloudflare(),
        );
        final LnReaderEpubChapter chapter = await fetchSecond(manager);
        expect(chapter.images, hasLength(1));
        expect(
          requestHeaders['127.0.0.1/redirect.png']!.value(
            HttpHeaders.cookieHeader,
          ),
          'cf_clearance=token',
        );
        expect(
          requestHeaders['localhost/ok.png']!.value(HttpHeaders.cookieHeader),
          isNull,
        );
      });

      test('丢图不再无痕：丢了几张、第一张为什么丢进错误日志', () async {
        final (LnReaderManager manager, FakeLnReaderRuntime _) =
            await setUpManager();
        final LnReaderEpubChapter chapter = await fetchSecond(manager);
        expect(chapter.images, hasLength(1));
        expect(chapter.xhtmlBody, isNot(contains('src="images/c2-1.png"')));
        expect(
          parseLnReaderMissingImages(chapter.xhtmlBody).single.fileName,
          'images/c2-1.png',
        );
        final ErrorLogEntry entry = ErrorLogService.instance.entries.lastWhere(
          (ErrorLogEntry e) => e.source == 'LnReaderBookDownload.imagesDropped',
        );
        expect(entry.error, contains('test.plugin /2'));
        expect(entry.error, contains('dropped 1 of 2 images'));
        expect(entry.error, contains('127.0.0.1: HTTP 404'));
      });
    });

    test('任一章失败整次中止并指出是哪一章（不静默跳章）', () async {
      final (LnReaderManager manager, FakeLnReaderRuntime runtime) =
          await setUpManager();
      runtime.failingChapters = <String>{'/2'};
      bool imported = false;
      await expectLater(
        LnReaderBookDownload(
          manager: manager,
          database: FushiDatabase.forTesting(NativeDatabase.memory()),
          httpClientFactory: HttpClient.new,
          isBlockedHost: (String _) => false,
          isBlockedAddress: (InternetAddress _) => false,
          importEpub:
              ({
                required FushiDatabase db,
                required Uint8List bytes,
                required String fileName,
                required DuplicatePolicy policy,
              }) async {
                imported = true;
                return '';
              },
        ).run(
          plugin: plugin,
          novel: novel,
          chapters: chapters,
          policy: const DuplicatePolicy.skip(),
        ),
        throwsA(
          isA<LnReaderChapterDownloadException>()
              .having(
                (LnReaderChapterDownloadException e) => e.index,
                'index',
                1,
              )
              .having(
                (LnReaderChapterDownloadException e) => e.chapter.name,
                'chapter',
                '二',
              ),
        ),
      );
      expect(imported, isFalse);
      expect(runtime.calls, isNot(contains('chapter:/3')));
    });

    test('取消在章与章之间生效，不入库', () async {
      final (LnReaderManager manager, FakeLnReaderRuntime runtime) =
          await setUpManager();
      int done = 0;
      await expectLater(
        LnReaderBookDownload(
          manager: manager,
          database: FushiDatabase.forTesting(NativeDatabase.memory()),
          httpClientFactory: HttpClient.new,
          isBlockedHost: (String _) => false,
          isBlockedAddress: (InternetAddress _) => false,
          importEpub:
              ({
                required FushiDatabase db,
                required Uint8List bytes,
                required String fileName,
                required DuplicatePolicy policy,
              }) async => fail('cancelled downloads must not import'),
        ).run(
          plugin: plugin,
          novel: novel,
          chapters: chapters,
          policy: const DuplicatePolicy.skip(),
          onProgress: (int d, int _) => done = d,
          isCancelled: () => done >= 1,
        ),
        throwsA(isA<LnReaderDownloadCancelled>()),
      );
      expect(
        runtime.calls.where((String c) => c.startsWith('chapter:')),
        <String>['chapter:/1'],
      );
    });
  });
}
