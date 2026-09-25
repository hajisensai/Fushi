import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';

import 'fake_lnreader_runtime.dart';

/// 1×1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

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

    setUp(() async {
      requestedPaths.clear();
      root = await Directory.systemTemp.createTemp('lnreader_download_');
      images = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      imageBase = 'http://127.0.0.1:${images.port}';
      images.listen((HttpRequest request) async {
        requestedPaths.add(request.uri.path);
        if (request.uri.path == '/ok.png') {
          request.response.add(_png);
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
        builtinStoreUrl: 'http://127.0.0.1:1/unused.json',
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
        isNot(contains('images/c2-1.png')),
        reason: '404 的插图要从正文摘掉，不能留断链。',
      );
      expect(archive.findFile('OEBPS/images/c2-0.png'), isNotNull);
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
      expect(
        _entry(archive, 'OEBPS/chapter-2.xhtml'),
        isNot(contains('images/c2-0')),
      );
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
