import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 在线直读页会话（2026-09-26 用户撤回「先下载再读」）：懒取、同页合并、限流 +
/// 前台插队、预取、落临时缓存、失败不缓存、close 删目录、残目录清理。
class _FakeFetcher {
  static const Duration delay = Duration(milliseconds: 5);

  final List<int> calls = <int>[];
  final Set<int> failOnce = <int>{};
  int inFlight = 0;
  int maxInFlight = 0;

  static final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 30, height: 40)),
  );

  Future<Uint8List> call(int index) async {
    calls.add(index);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      if (failOnce.remove(index)) {
        throw StateError('network down for page $index');
      }
      return png;
    } finally {
      inFlight--;
    }
  }
}

Future<void> _settle() => Future<void>.delayed(
      const Duration(milliseconds: 80),
    );

void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('manga_stream_cache_');
  });

  tearDown(() async {
    if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
  });

  Future<OnlineMangaReaderSession> open(
    _FakeFetcher fetcher, {
    int pages = 10,
    int concurrency = 3,
    int prefetchRadius = 2,
    String chapterKey = '/chapter/1',
    OnlineMangaPageMeasured? onPageMeasured,
  }) =>
      OnlineMangaReaderSession.open(
        cacheRoot: cacheRoot,
        bookKey: 'book-1',
        chapterKey: chapterKey,
        pageIdentities: <String>[
          for (int i = 0; i < pages; i++) 'id-$i',
        ],
        fetchPage: fetcher.call,
        maxConcurrentRequests: concurrency,
        prefetchRadius: prefetchRadius,
        onPageMeasured: onPageMeasured,
      );

  test('同页并发请求只取一次；字节、类型、真实尺寸都对，尺寸回调只报一次', () async {
    final _FakeFetcher fetcher = _FakeFetcher();
    final List<String> measured = <String>[];
    final OnlineMangaReaderSession session = await open(
      fetcher,
      prefetchRadius: 0,
      onPageMeasured: (int index, int width, int height) =>
          measured.add('$index:${width}x$height'),
    );
    addTearDown(session.close);

    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      session.page(0),
      session.page(0),
      session.localFile(0),
    ]);
    expect(fetcher.calls, <int>[0]);
    final MangaPageBytes page = results[0]! as MangaPageBytes;
    expect(page.contentType, 'image/png');
    expect(page.width, 30);
    expect(page.height, 40);
    expect(page.bytes, _FakeFetcher.png);
    final File file = results[2]! as File;
    expect(p.basename(file.path), 'page-000001.png');
    expect(p.isWithin(session.directory.path, file.path), isTrue);
    expect(session.cachedFilePath(0), file.path);

    // 再要一次：走缓存，不再打源。
    await session.page(0);
    expect(fetcher.calls, <int>[0]);
    expect(measured, <String>['0:30x40']);
    expect(session.cacheIdentity(3), 'id-3');
  });

  test('取页顺带预取前后各两页；并发不超过上限，前台请求排在预取前面', () async {
    final _FakeFetcher fetcher = _FakeFetcher();
    final OnlineMangaReaderSession session = await open(
      fetcher,
      concurrency: 2,
    );
    addTearDown(session.close);

    await session.page(5);
    await _settle();
    expect(fetcher.calls.first, 5, reason: '前台页先取');
    expect(fetcher.calls.toSet(), <int>{3, 4, 5, 6, 7});
    expect(fetcher.maxInFlight, lessThanOrEqualTo(2));
    expect(session.cachedFilePath(7), isNotNull);
    expect(session.cachedFilePath(8), isNull, reason: '预取半径之外不取');

    // 已预取的页再要：不重取。
    await session.page(6);
    await _settle();
    expect(fetcher.calls.where((int i) => i == 6), hasLength(1));
    // 6 的预取半径带出 8。
    expect(fetcher.calls, contains(8));
  });

  test('失败不进缓存：下一次请求重新取', () async {
    final _FakeFetcher fetcher = _FakeFetcher()..failOnce.add(2);
    final OnlineMangaReaderSession session = await open(
      fetcher,
      prefetchRadius: 0,
    );
    addTearDown(session.close);

    await expectLater(session.page(2), throwsStateError);
    expect(session.cachedFilePath(2), isNull);
    final MangaPageBytes retry = await session.page(2);
    expect(retry.width, 30);
    expect(fetcher.calls, <int>[2, 2]);
  });

  test('close 删会话目录，之后的请求报 SESSION_CLOSED', () async {
    final _FakeFetcher fetcher = _FakeFetcher();
    final OnlineMangaReaderSession session = await open(fetcher);
    await session.page(0);
    await _settle();
    expect(await session.directory.exists(), isTrue);

    await session.close();
    expect(await session.directory.exists(), isFalse);
    await expectLater(
      session.page(0),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'SESSION_CLOSED',
        ),
      ),
    );
  });

  test('打开时清掉崩溃残留的目录，但不动另一个活会话', () async {
    final Directory stale = Directory(
      p.join(cacheRoot.path, 'deadbeef', 'chapter-0'),
    );
    await stale.create(recursive: true);
    await File(p.join(stale.path, 'page-000001.jpg')).writeAsBytes(<int>[1]);

    final OnlineMangaReaderSession first = await open(_FakeFetcher());
    addTearDown(first.close);
    expect(await stale.exists(), isFalse);
    expect(
        await Directory(p.join(cacheRoot.path, 'deadbeef')).exists(), isFalse);

    final OnlineMangaReaderSession second = await open(
      _FakeFetcher(),
      chapterKey: '/chapter/2',
    );
    addTearDown(second.close);
    expect(await first.directory.exists(), isTrue, reason: '活会话目录不能被清');
    expect(await second.directory.exists(), isTrue);
  });

  test('越界页号抛 RangeError，不打源', () async {
    final _FakeFetcher fetcher = _FakeFetcher();
    final OnlineMangaReaderSession session = await open(fetcher, pages: 2);
    addTearDown(session.close);
    expect(() => session.page(2), throwsRangeError);
    expect(() => session.cacheIdentity(-1), throwsRangeError);
    expect(fetcher.calls, isEmpty);
  });
}
