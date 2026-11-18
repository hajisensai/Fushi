import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:path/path.dart' as p;

import 'fake_lnreader_runtime.dart';

/// 1×1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void _unzipInto(Uint8List bytes, String dir) {
  for (final ArchiveFile file in ZipDecoder().decodeBytes(bytes)) {
    if (!file.isFile) continue;
    final File out = File(p.join(dir, file.name));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content as List<int>);
  }
}

/// 🔴 本文件**不能**调 `TestWidgetsFlutterBinding.ensureInitialized()`：绑定会把
/// HttpClient 换成恒回 400 的模拟实现，插图下载全部「失败」。
/// 可以把某一章的取章卡在半路的执行面：测排队顺序用。
class _GatedLnReaderRuntime extends FakeLnReaderRuntime {
  _GatedLnReaderRuntime({super.chapterHtml});

  /// 章节路径 → 放行闸。取到这一章时先等闸开。
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  /// 章节路径 → 「已经开始取这一章」。
  final Map<String, Completer<void>> reached = <String, Completer<void>>{};

  void gate(String path) {
    gates[path] = Completer<void>();
    reached[path] = Completer<void>();
  }

  @override
  Future<String> chapter(String pluginId, String path) async {
    final Completer<void>? gate = gates[path];
    if (gate != null) {
      reached[path]!.complete();
      await gate.future;
    }
    return super.chapter(pluginId, path);
  }
}

void main() {
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
  );

  group('LnReaderOnlineBookDescriptor', () {
    test('编码往返；在线漫画 / 普通书 / 损坏的描述符一律不认', () {
      const LnReaderOnlineBookDescriptor descriptor =
          LnReaderOnlineBookDescriptor(
            pluginId: 'p',
            novelPath: '/n',
            chapters: chapters,
          );
      final LnReaderOnlineBookDescriptor parsed =
          LnReaderOnlineBookDescriptor.tryParse(descriptor.encode())!;
      expect(parsed.isNovel('p', '/n'), isTrue);
      expect(parsed.chapters.map((LnReaderChapter c) => c.path), <String>[
        '/1',
        '/2',
        '/3',
      ]);
      expect(parsed.chapters[1].name, '二');

      expect(LnReaderOnlineBookDescriptor.tryParse(null), isNull);
      expect(
        LnReaderOnlineBookDescriptor.tryParse(
          '{"type":"hibiki-online-manga","version":3}',
        ),
        isNull,
      );
      expect(
        LnReaderOnlineBookDescriptor.tryParse('{"a":1,"sectionChars":[1,2]}'),
        isNull,
      );
      expect(
        LnReaderOnlineBookDescriptor.tryParse(
          '${LnReaderOnlineBookDescriptor.marker} not json',
        ),
        isNull,
      );
    });
  });

  group('LnReaderOnlineLibrary / LnReaderOnlineChapterLoader', () {
    late Directory root;
    late Directory books;
    late HttpServer images;
    late String imageBase;
    late FushiDatabase db;
    late LnReaderManager manager;
    late _GatedLnReaderRuntime runtime;
    late int imports;
    late int rebuilds;
    final List<LnReaderOnlineChapterLoader> loaders =
        <LnReaderOnlineChapterLoader>[];

    setUp(() async {
      imports = 0;
      rebuilds = 0;
      root = await Directory.systemTemp.createTemp('lnreader_online_');
      books = Directory(p.join(root.path, 'books'))..createSync();
      images = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      imageBase = 'http://127.0.0.1:${images.port}';
      images.listen((HttpRequest request) async {
        if (request.uri.path == '/ok.png') {
          request.response.add(_png);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final Directory pluginRoot = Directory(p.join(root.path, 'lnreader'))
        ..createSync();
      // 预置已装插件（加载器按描述符里的插件 id 在已装列表里找）。
      await File(p.join(pluginRoot.path, 'state.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'stores': <Object?>[],
          'installed': <Object?>[
            <String, Object?>{
              'id': plugin.id,
              'name': plugin.name,
              'site': plugin.site,
              'lang': plugin.lang,
              'version': plugin.version,
              'url': '',
              'iconUrl': '',
              'storeUrl': '',
              'enabled': true,
              'pinned': false,
              'sortOrder': 0,
              'installedAt': 0,
            },
          ],
        }),
      );
      runtime = _GatedLnReaderRuntime(
        chapterHtml: <String, String>{
          '/2': '<p>本文です<img src="$imageBase/ok.png"/></p>',
          '/3': '<p>第三章の本文</p>',
          '/4': '<p>新しい章</p>',
        },
      );
      manager = LnReaderManager(
        rootDirectory: pluginRoot,
        runtime: runtime,
        httpClientFactory: HttpClient.new,
      );
      await manager.initialise();
      await manager.pluginFile(plugin.id).create(recursive: true);
    });

    tearDown(() async {
      // 后台预取还在写盘时删目录，Windows 上会报占用。
      for (final LnReaderOnlineChapterLoader loader in loaders) {
        await loader.whenIdle();
      }
      loaders.clear();
      manager.dispose();
      await images.close(force: true);
      await db.close();
      await root.delete(recursive: true);
    });

    LnReaderBookDownload download() => LnReaderBookDownload(
      manager: manager,
      database: db,
      httpClientFactory: HttpClient.new,
      isBlockedHost: (String _) => false,
      isBlockedAddress: (InternetAddress _) => false,
    );

    String chaptersJson(int count) => jsonEncode(<Object?>[
      for (int i = 0; i < count; i++)
        <String, Object?>{
          'id': 'chapter-${i + 1}',
          'href': 'OEBPS/chapter-${i + 1}.xhtml',
          'mediaType': 'application/xhtml+xml',
          'characters': 0,
          'charCaliber': 2,
        },
    ]);

    /// 真解压、真插行：与 `EpubImporter.import` 同样的落盘形状。
    LnReaderOnlineLibrary library() => LnReaderOnlineLibrary(
      manager: manager,
      database: db,
      download: download(),
      importEpub:
          ({
            required FushiDatabase db,
            required Uint8List bytes,
            required String fileName,
            required DuplicatePolicy policy,
          }) async {
            imports++;
            expect(policy, isA<DuplicatePolicy>());
            final String dir = p.join(books.path, 'book$imports');
            _unzipInto(bytes, dir);
            await db.insertEpubBook(
              EpubBooksCompanion.insert(
                bookKey: 'book$imports',
                title: novel.name,
                epubPath: fileName,
                extractDir: dir,
                chapterCount: chapters.length,
                chaptersJson: chaptersJson(chapters.length),
                importedAt: 0,
              ),
            );
            return 'book$imports';
          },
      rebuildInPlace:
          ({required String epubFilePath, required String extractDir}) async {
            rebuilds++;
            Directory(extractDir).deleteSync(recursive: true);
            _unzipInto(File(epubFilePath).readAsBytesSync(), extractDir);
            final int count = Directory(p.join(extractDir, 'OEBPS'))
                .listSync()
                .where(
                  (FileSystemEntity e) =>
                      p.basename(e.path).startsWith('chapter-'),
                )
                .length;
            return (
              chapterCount: count,
              chaptersJson: chaptersJson(count),
              coverPath: null,
            );
          },
    );

    /// 直接构造（生产工厂用的是真拦截判据，回环图片服务器会被当本机地址拦掉）。
    Future<LnReaderOnlineChapterLoader> loaderFor(String bookKey) async {
      final EpubBookRow row = (await db.getEpubBook(bookKey))!;
      final LnReaderOnlineChapterLoader loader = LnReaderOnlineChapterLoader(
        manager: manager,
        database: db,
        download: download(),
        bookKey: bookKey,
        extractDir: row.extractDir,
        descriptor: LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata)!,
      );
      loaders.add(loader);
      return loader;
    }

    test('首次在线打开：全章占位书入库并写描述符；再开同一部不重复入库', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      expect(imports, 1);
      final EpubBookRow row = (await db.getEpubBook(key))!;
      final LnReaderOnlineBookDescriptor descriptor =
          LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata)!;
      expect(descriptor.isNovel(plugin.id, novel.path), isTrue);
      for (int i = 0; i < chapters.length; i++) {
        final String xhtml = lnReaderOnlineChapterFile(
          row.extractDir,
          i,
        ).readAsStringSync();
        expect(xhtml, contains(kLnReaderPendingChapterAttribute));
        expect(xhtml, contains('PENDING'));
        expect(xhtml, contains(chapters[i].name));
      }
      // 建书时不取任何正文。
      expect(
        runtime.calls.where((String c) => c.startsWith('chapter:')),
        isEmpty,
      );

      expect(
        await library().ensureBook(
          plugin: plugin,
          novel: novel,
          pendingText: 'PENDING',
        ),
        key,
      );
      expect(imports, 1);
      expect(rebuilds, 0);
    });

    test('在线书的书行才建加载器；普通书连 LNReader 管理器都不碰', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      final LnReaderOnlineChapterLoader? loader =
          lnReaderOnlineChapterLoaderFor(
            row: row,
            extractDir: row.extractDir,
            database: db,
            manager: () => manager,
            onlineSourcesAvailable: true,
          );
      expect(loader?.bookKey, key);
      expect(loader?.descriptor.chapters.length, chapters.length);

      bool touched = false;
      expect(
        lnReaderOnlineChapterLoaderFor(
          row: null,
          extractDir: root.path,
          database: db,
          manager: () {
            touched = true;
            return manager;
          },
          onlineSourcesAvailable: true,
        ),
        isNull,
      );
      expect(touched, isFalse);
    });

    test('按需取章：占位页换成正文 + 插图落盘 + 字数回写；并发只取一次、顺手预取下一章', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String dir = loader.extractDir;
      final String second = lnReaderOnlineChapterFile(dir, 1).path;

      final List<OnlineNovelChapterLoaded?> results = await Future.wait(
        <Future<OnlineNovelChapterLoaded?>>[
          loader.ensureLoaded(second),
          loader.ensureLoaded(second),
        ],
      );
      expect(results, everyElement(isNotNull));
      expect(results.first!.index, 1);
      expect(runtime.calls.where((String c) => c == 'chapter:/2').length, 1);

      final String xhtml = File(second).readAsStringSync();
      expect(xhtml, isNot(contains(kLnReaderPendingChapterAttribute)));
      expect(xhtml, contains('本文です'));
      final String imageName = '${lnReaderOnlineImagePrefix('/2')}0.png';
      expect(xhtml, contains(imageName));
      expect(File(p.join(dir, 'OEBPS', imageName)).readAsBytesSync(), _png);

      final List<Object?> counts =
          jsonDecode((await db.getEpubBook(key))!.chaptersJson)
              as List<Object?>;
      expect(
        (counts[1]! as Map<String, Object?>)['characters'],
        greaterThan(0),
      );
      expect((counts[0]! as Map<String, Object?>)['characters'], 0);
      // 新字数同时交回调用方（阅读器据此换掉内存里那一章的字数，BUG-4809），
      // 与写进书行的是同一个数。
      expect(
        results.first!.characters,
        (counts[1]! as Map<String, Object?>)['characters'],
      );

      // 已取过的章不再取；不是正文文件的请求不管。
      expect(await loader.ensureLoaded(second), isNull);
      expect(
        await loader.ensureLoaded(p.join(dir, 'OEBPS', 'nav.xhtml')),
        isNull,
      );

      // 预取的下一章在后台落盘。
      await loader.whenIdle();
      final File third = lnReaderOnlineChapterFile(dir, 2);
      expect(third.readAsStringSync(), contains('第三章の本文'));
      // 第一章没人要，就不取。
      expect(runtime.calls, isNot(contains('chapter:/1')));
    });

    test('后台预取的章：翻到时仍报「刚换成正文」，阅读器据此丢掉预热进缓存的占位页', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String dir = loader.extractDir;
      expect(
        await loader.ensureLoaded(lnReaderOnlineChapterFile(dir, 1).path),
        isNotNull,
      );
      // 第三章在后台预取落盘——阅读器自己的相邻章预热可能在此之前已把它的占位
      // 页读进了缓存。
      await loader.whenIdle();
      final String third = lnReaderOnlineChapterFile(dir, 2).path;
      expect(File(third).readAsStringSync(), contains('第三章の本文'));

      final OnlineNovelChapterLoaded? acknowledged = await loader.ensureLoaded(
        third,
      );
      expect(acknowledged?.index, 2);
      // 预取时算好的字数留到确认这一刻才交出去：阅读器只能在翻到这一章（导航
      // 中）时换字数，预取落盘那会儿用户还在读上一章。
      expect(acknowledged?.characters, greaterThan(0));
      expect(runtime.calls.where((String c) => c == 'chapter:/3').length, 1);
      // 确认过一次就不再报。
      expect(await loader.ensureLoaded(third), isNull);
    });

    test('顺序连读：翻到已被预取的章照样接着预取再下一章（不是隔一章才预取一次）', () async {
      const List<LnReaderChapter> five = <LnReaderChapter>[
        LnReaderChapter(name: '一', path: '/1'),
        LnReaderChapter(name: '二', path: '/2'),
        LnReaderChapter(name: '三', path: '/3'),
        LnReaderChapter(name: '四', path: '/4'),
        LnReaderChapter(name: '五', path: '/5'),
      ];
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: const LnReaderNovel(
          name: 'テスト小説',
          path: '/novel',
          chapters: five,
          totalPages: 1,
        ),
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String dir = loader.extractDir;
      String chapter(int index) => lnReaderOnlineChapterFile(dir, index).path;
      List<String> fetched() =>
          runtime.calls.where((String c) => c.startsWith('chapter:')).toList();

      // 开第一章：亲手取它，预取第二章。
      expect(await loader.ensureLoaded(chapter(0)), isNotNull);
      await loader.whenIdle();
      expect(fetched(), <String>['chapter:/1', 'chapter:/2']);

      // 一章一章往后翻：每翻到一章（都已被预取，本次什么都不用取），再下一章
      // 就该已经在后台取好——前台从头到尾没等过网络。
      for (int index = 1; index < five.length; index++) {
        expect(
          File(chapter(index)).readAsStringSync(),
          isNot(contains(kLnReaderPendingChapterAttribute)),
          reason: '翻到第 ${index + 1} 章时它应已被预取',
        );
        expect(await loader.ensureLoaded(chapter(index)), isNotNull);
        await loader.whenIdle();
      }
      expect(fetched(), <String>[
        'chapter:/1',
        'chapter:/2',
        'chapter:/3',
        'chapter:/4',
        'chapter:/5',
      ]);

      // 回头重进已确认过的章：不再报、也不再触发预取。
      expect(await loader.ensureLoaded(chapter(2)), isNull);
      await loader.whenIdle();
      expect(fetched().length, 5);
    });

    test('前台请求排到排队中的后台预取前面（预取在真实加载器上确实按后台入队）', () async {
      const List<LnReaderChapter> five = <LnReaderChapter>[
        LnReaderChapter(name: '一', path: '/1'),
        LnReaderChapter(name: '二', path: '/2'),
        LnReaderChapter(name: '三', path: '/3'),
        LnReaderChapter(name: '四', path: '/4'),
        LnReaderChapter(name: '五', path: '/5'),
      ];
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: const LnReaderNovel(
          name: 'テスト小説',
          path: '/novel',
          chapters: five,
          totalPages: 1,
        ),
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      String chapter(int index) =>
          lnReaderOnlineChapterFile(loader.extractDir, index).path;

      // 第 1 章在取（卡住）时目录跳到第 4 章：前台排队。
      runtime
        ..gate('/1')
        ..gate('/4');
      final Future<OnlineNovelChapterLoaded?> first = loader.ensureLoaded(
        chapter(0),
      );
      final Future<OnlineNovelChapterLoaded?> fourth = loader.ensureLoaded(
        chapter(3),
      );
      await runtime.reached['/1']!.future;
      runtime.gates['/1']!.complete();
      // 第 1 章落定：它的预取（第 2 章）入队；此刻在取的是第 4 章（卡住）。
      expect(await first, isNotNull);
      await runtime.reached['/4']!.future;
      // 第 4 章还在取时又跳到第 3 章：这个前台请求入队晚于第 2 章的预取。
      final Future<OnlineNovelChapterLoaded?> third = loader.ensureLoaded(
        chapter(2),
      );
      runtime.gates['/4']!.complete();
      expect(await fourth, isNotNull);
      expect(await third, isNotNull);
      await loader.whenIdle();

      final List<String> order = runtime.calls
          .where((String c) => c.startsWith('chapter:'))
          .toList();
      expect(
        order.indexOf('chapter:/3'),
        lessThan(order.indexOf('chapter:/2')),
        reason: '前台要的第 3 章先于更早入队的第 2 章预取；实际顺序 $order',
      );
      expect(order.take(3), <String>['chapter:/1', 'chapter:/4', 'chapter:/3']);
    });

    test('预取之后解压树被就地重建：过期的字数不交给阅读器，缓存照样要丢', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String dir = loader.extractDir;
      expect(
        await loader.ensureLoaded(lnReaderOnlineChapterFile(dir, 1).path),
        isNotNull,
      );
      // 第 3 章已被后台预取、字数记在加载器里，阅读器还没翻到它。
      await loader.whenIdle();
      expect(
        lnReaderOnlineChapterFile(dir, 2).readAsStringSync(),
        contains('第三章の本文'),
      );

      // 作品页刷新：站点在最前面插了一章，书行里的描述符换了（第 3 个文件
      // 现在是「二」）。阅读器手里的加载器还是旧描述符。
      await db.updateEpubBookMihonState(
        key,
        sourceMetadata: const LnReaderOnlineBookDescriptor(
          pluginId: 'test.plugin',
          novelPath: '/novel',
          chapters: <LnReaderChapter>[
            LnReaderChapter(name: '零', path: '/0'),
            ...chapters,
          ],
        ).encode(),
        chapterCount: 4,
        chaptersJson: chaptersJson(4),
      );

      final OnlineNovelChapterLoaded? stale = await loader.ensureLoaded(
        lnReaderOnlineChapterFile(dir, 2).path,
      );
      expect(stale?.index, 2, reason: '文件变过，阅读器仍要丢这一章的缓存');
      expect(stale?.characters, isNull, reason: '预取时记下的字数已不是这一章的');
      expect(
        await loader.ensureLoaded(lnReaderOnlineChapterFile(dir, 2).path),
        isNull,
      );
    });

    test('关书（dispose）之后不再取章', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String first = lnReaderOnlineChapterFile(loader.extractDir, 0).path;
      loader.dispose();
      expect(await loader.ensureLoaded(first), isNull);
      await loader.whenIdle();
      expect(
        runtime.calls.where((String c) => c.startsWith('chapter:')),
        isEmpty,
      );
      expect(
        File(first).readAsStringSync(),
        contains(kLnReaderPendingChapterAttribute),
      );
    });

    test('在线源平台门没过（iOS 合规 / Linux）：不建加载器，也不碰 LNReader 管理器', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      bool touched = false;
      expect(
        lnReaderOnlineChapterLoaderFor(
          row: row,
          extractDir: row.extractDir,
          database: db,
          manager: () {
            touched = true;
            return manager;
          },
          onlineSourcesAvailable: false,
        ),
        isNull,
      );
      expect(touched, isFalse);
    });

    test('取章失败抛出且占位页保留（重进这一章会再取）；插件被删报清楚的错', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      final String first = lnReaderOnlineChapterFile(loader.extractDir, 0).path;

      runtime.failingChapters = <String>{'/1'};
      await expectLater(loader.ensureLoaded(first), throwsA(isA<StateError>()));
      expect(File(first).readAsStringSync(), contains('PENDING'));

      runtime.failingChapters = <String>{};
      expect(await loader.ensureLoaded(first), isNotNull);
      await loader.whenIdle();

      await manager.uninstall(manager.installed.single);
      final String third = lnReaderOnlineChapterFile(loader.extractDir, 2).path;
      await expectLater(
        loader.ensureLoaded(third),
        throwsA(isA<LnReaderOnlinePluginMissing>()),
      );
    });

    test('连载更新：章节列表变了就地重建，已取过的章按路径搬过去、新章是占位', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      expect(
        await loader.ensureLoaded(
          lnReaderOnlineChapterFile(loader.extractDir, 1).path,
        ),
        isNotNull,
      );
      await loader.whenIdle();

      // 站点在最前面插了一章「零」，末尾又更新了第四章。
      const LnReaderNovel updated = LnReaderNovel(
        name: 'テスト小説',
        path: '/novel',
        chapters: <LnReaderChapter>[
          LnReaderChapter(name: '零', path: '/0'),
          ...chapters,
          LnReaderChapter(name: '四', path: '/4'),
        ],
        totalPages: 1,
      );
      expect(
        await library().ensureBook(
          plugin: plugin,
          novel: updated,
          pendingText: 'PENDING',
        ),
        key,
      );
      expect(imports, 1);
      expect(rebuilds, 1);

      final EpubBookRow row = (await db.getEpubBook(key))!;
      expect(row.chapterCount, 5);
      expect(
        LnReaderOnlineBookDescriptor.tryParse(
          row.sourceMetadata,
        )!.chapters.map((LnReaderChapter c) => c.path),
        <String>['/0', '/1', '/2', '/3', '/4'],
      );
      // 「二」原来是第 2 章、现在是第 3 章：正文与插图跟着章节路径走。
      final String moved = lnReaderOnlineChapterFile(
        row.extractDir,
        2,
      ).readAsStringSync();
      expect(moved, contains('本文です'));
      final String imageName = '${lnReaderOnlineImagePrefix('/2')}0.png';
      expect(
        File(p.join(row.extractDir, 'OEBPS', imageName)).existsSync(),
        isTrue,
      );
      expect(
        lnReaderOnlineChapterFile(row.extractDir, 0).readAsStringSync(),
        contains(kLnReaderPendingChapterAttribute),
      );
      expect(
        lnReaderOnlineChapterFile(row.extractDir, 4).readAsStringSync(),
        contains(kLnReaderPendingChapterAttribute),
      );
    });

    test('取正文期间章节列表被重建（序号换了章）：放弃写入，不让正文错位', () async {
      final String key = await library().ensureBook(
        plugin: plugin,
        novel: novel,
        pendingText: 'PENDING',
      );
      // 加载器拿的是旧描述符；书行里的描述符已换成「零」插在最前的新列表。
      final LnReaderOnlineChapterLoader loader = await loaderFor(key);
      await db.updateEpubBookMihonState(
        key,
        sourceMetadata: const LnReaderOnlineBookDescriptor(
          pluginId: 'test.plugin',
          novelPath: '/novel',
          chapters: <LnReaderChapter>[
            LnReaderChapter(name: '零', path: '/0'),
            ...chapters,
          ],
        ).encode(),
        chapterCount: 4,
        chaptersJson: chaptersJson(4),
      );
      final File second = lnReaderOnlineChapterFile(loader.extractDir, 1);
      expect(await loader.ensureLoaded(second.path), isNull);
      expect(
        second.readAsStringSync(),
        contains(kLnReaderPendingChapterAttribute),
      );
    });
  });
}
