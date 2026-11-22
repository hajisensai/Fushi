import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-4917：桌面 sidecar 一重启（装 / 更新 / 卸任何扩展都会重启），正在读的
/// 在线章剩下的页全部失败。页表里的图片 URL 是旧进程的端口与令牌，阅读会话却
/// 把开会话时解析的那份页引用攥到底。
///
/// 这里走真实的 MihonLibraryAdapter → OnlineMangaChapterPageRefs →
/// OnlineMangaReaderSession，只把运行时换成一个会「重启」的假实现：它照桌面
/// 运行时的契约，对旧进程发的页引用抛 [kMihonStalePageReferenceCode]。
void main() {
  const MihonSource source = MihonSource(
    extensionPackage: 'org.example.manga',
    id: '7',
    name: 'Example',
    language: 'ja',
    baseUrl: 'https://example.org',
  );
  const MihonExtensionRef extension = MihonExtensionRef(
    packageName: 'org.example.manga',
    apkPath: 'example.apk',
  );
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: source.extensionPackage,
    sourceId: source.id,
    series: const OnlineMangaSeries(
      key: '/series/1',
      title: 'Series',
      raw: <String, Object?>{'url': '/series/1', 'title': 'Series'},
    ),
    chapters: const <OnlineMangaChapter>[],
  );
  const OnlineMangaChapter chapter = OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    raw: <String, Object?>{'url': '/chapter/1', 'name': 'Chapter 1'},
  );

  late FushiDatabase database;
  late Directory root;
  late MihonManager manager;
  late _RestartingRuntime runtime;
  late MihonLibraryAdapter adapter;

  setUp(() async {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('fushi-page-refs-restart-');
    runtime = _RestartingRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    adapter = MihonLibraryAdapter(
      manager,
      presetContext: const MihonSourceContext(
        extension: extension,
        source: source,
        preferences: <MihonPreference>[],
      ),
    );
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    await root.delete(recursive: true);
  });

  Future<OnlineMangaChapterPageRefs> openRefs() async =>
      OnlineMangaChapterPageRefs(
        adapter: adapter,
        entry: entry,
        chapter: chapter,
        pages: await adapter.resolveChapterPages(
          entry: entry,
          chapter: chapter,
        ),
      );

  test('适配器把旧进程页引用的失败报成 OnlineMangaPageRefExpired', () async {
    final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
      entry: entry,
      chapter: chapter,
    );
    runtime.restart();
    await expectLater(
      adapter.fetchChapterPage(pages.first),
      throwsA(isA<OnlineMangaPageRefExpired>()),
    );
  });

  test('读到一半 sidecar 重启：剩下的页照常取到，页数与身份串不变', () async {
    final OnlineMangaChapterPageRefs refs = await openRefs();
    final OnlineMangaReaderSession session =
        await OnlineMangaReaderSession.open(
          cacheRoot: Directory('${root.path}/stream'),
          bookKey: 'book',
          chapterKey: chapter.key,
          pageIdentities: <String>[
            for (int i = 0; i < refs.length; i++) 'id-$i',
          ],
          fetchPage: refs.fetch,
          prefetchAhead: 0,
          prefetchBehind: 0,
        );
    addTearDown(session.close);

    final MangaPageBytes first = await session.page(0);
    expect(first.bytes, _bytesFor(process: 1, index: 0));

    runtime.restart();
    final MangaPageBytes second = await session.page(1);
    expect(
      second.bytes,
      _bytesFor(process: 2, index: 1),
      reason: '重启后必须用新进程重解析的页引用去取',
    );
    expect(runtime.getPagesCalls, 2, reason: '开会话一次 + 重启后重解析一次');
    expect(refs.length, 3);
    expect(session.cacheIdentity(1), 'id-1');
  });

  test('多页同时撞上失效只重解析一次', () async {
    final OnlineMangaChapterPageRefs refs = await openRefs();
    runtime.restart();
    final List<Uint8List> pages = await Future.wait(<Future<Uint8List>>[
      refs.fetch(0),
      refs.fetch(1),
      refs.fetch(2),
    ]);
    expect(pages, <Uint8List>[
      _bytesFor(process: 2, index: 0),
      _bytesFor(process: 2, index: 1),
      _bytesFor(process: 2, index: 2),
    ]);
    expect(runtime.getPagesCalls, 2);
  });

  test('重启后页数变了按失败，之后不再反复重解析', () async {
    final OnlineMangaChapterPageRefs refs = await openRefs();
    runtime
      ..pageCount = 5
      ..restart();
    await expectLater(
      refs.fetch(1),
      throwsA(
        isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable e) => e.stage,
          'stage',
          'pages',
        ),
      ),
    );
    await expectLater(refs.fetch(2), throwsA(isA<OnlineMangaUnavailable>()));
    expect(runtime.getPagesCalls, 2, reason: '页数不一致是确定结论，不再每页解析一次');
  });

  test('重启后页数相同但源端换了页（audit-035）：按失败，不把两版页图接着混取', () async {
    final OnlineMangaChapterPageRefs refs = await openRefs();
    expect(refs[0].pageKey, 'https://cdn.example/v1/0.jpg');
    expect(
      refs[0].sourceUrl,
      'https://cdn.example/v1/0.jpg',
      reason: 'OCR sidecar 按源站地址配页，不拿进程内代理地址',
    );
    runtime
      ..version = 2
      ..restart();
    await expectLater(refs.fetch(1), throwsA(isA<OnlineMangaUnavailable>()));
    expect(refs.pageTableChanged, isTrue);
    await expectLater(refs.fetch(2), throwsA(isA<OnlineMangaUnavailable>()));
    expect(runtime.getPagesCalls, 2);
  });

  test('一般取页失败原样抛出，不重解析页表', () async {
    final OnlineMangaChapterPageRefs refs = await openRefs();
    runtime.failWith = const MihonRuntimeException('IMAGE_HTTP_500', 'boom');
    await expectLater(
      refs.fetch(0),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'IMAGE_HTTP_500',
        ),
      ),
    );
    expect(runtime.getPagesCalls, 1);
  });
}

Uint8List _bytesFor({required int process, required int index}) =>
    Uint8List.fromList(<int>[process, index]);

/// 照桌面 sidecar 契约的假运行时：页 URL 带发它的进程号，进程重启后旧 URL 一律
/// 报 [kMihonStalePageReferenceCode]。
class _RestartingRuntime extends Fake implements MihonRuntime {
  int process = 1;
  int pageCount = 3;
  int getPagesCalls = 0;

  /// 源端这一章的版本：变了 = 同页数换了页图。
  int version = 1;
  MihonRuntimeException? failWith;

  void restart() => process++;

  @override
  Future<void> dispose() async {}

  @override
  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    getPagesCalls++;
    return <MihonPage>[
      for (int i = 0; i < pageCount; i++)
        MihonPage(
          index: i,
          url: '',
          imageUrl: 'http://127.0.0.1/image/$process/$i',
          // 扩展原样给的地址：不随进程变，只随源端换页变（audit-035）。
          sourceImageUrl: 'https://cdn.example/v$version/$i.jpg',
        ),
    ];
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final MihonRuntimeException? error = failWith;
    if (error != null) throw error;
    final List<String> segments = Uri.parse(page.resolvedUrl).pathSegments;
    final int issuer = int.parse(segments[1]);
    if (issuer != process) {
      throw const MihonRuntimeException(
        kMihonStalePageReferenceCode,
        'issued by a restarted process',
      );
    }
    return _bytesFor(process: process, index: int.parse(segments[2]));
  }
}
