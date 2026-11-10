import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:fushi/src/media/manga/reader/manga_page_thumbnail_prefetcher.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_page_grid.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

/// 反馈 3VwZimDVBE（#3110 遗留）：在线直读章「全部页面」对还没取到的页预取。
///
/// 断言的是契约：走阅读器同一个页会话（同一份缓存、同一个并发上限、排在阅读请求
/// 之后），可见优先、窗口外撤单不打源、关面板即停、失败有上限不死磕。
class _GatedFetcher {
  _GatedFetcher({this.autoComplete = false});

  /// true：取页立即（下一个微任务后）成功；false：等测试 [release]。
  final bool autoComplete;
  final List<int> calls = <int>[];
  final Map<int, Completer<Uint8List>> _gates = <int, Completer<Uint8List>>{};
  final Set<int> failing = <int>{};
  bool _open = false;
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
      if (autoComplete || _open) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      } else {
        await (_gates[index] = Completer<Uint8List>()).future;
      }
      if (failing.contains(index)) {
        throw StateError('network down for page $index');
      }
      return png;
    } finally {
      inFlight--;
    }
  }

  void release(int index) => _gates.remove(index)?.complete(png);

  /// 放行在等的与之后来的所有请求。
  void openAll() {
    _open = true;
    for (final int index in _gates.keys.toList()) {
      release(index);
    }
  }
}

/// 取页落盘有真实文件 IO，不能只靠微任务推进：按条件等（带上限），不赌墙钟。
Future<void> _waitFor(bool Function() condition, String what) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _RecordingPrefetcher extends ChangeNotifier
    implements MangaPageGridPrefetcher {
  final List<List<int>> requests = <List<int>>[];
  int stops = 0;

  @override
  void requestPages(List<int> orderedPages) => requests.add(orderedPages);

  @override
  void stop() => stops++;

  void ping() => notifyListeners();
}

void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('manga_thumb_prefetch_');
  });

  tearDown(() async {
    if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
  });

  Future<OnlineMangaReaderSession> open(
    _GatedFetcher fetcher, {
    int pages = 40,
    int concurrency = 2,
    int prefetchAhead = 0,
    int prefetchBehind = 0,
  }) => OnlineMangaReaderSession.open(
    cacheRoot: cacheRoot,
    bookKey: 'book',
    chapterKey: '/chapter/1',
    pageIdentities: <String>[for (int i = 0; i < pages; i++) 'id-$i'],
    fetchPage: fetcher.call,
    maxConcurrentRequests: concurrency,
    prefetchAhead: prefetchAhead,
    prefetchBehind: prefetchBehind,
  );

  group('mangaPageGridPrefetchOrder', () {
    test('可见行从上到下，再往下预读，最后往上一行；越界行裁掉', () {
      expect(
        mangaPageGridPrefetchOrder(
          pageCount: 20,
          columns: 3,
          firstVisibleRow: 2,
          lastVisibleRow: 3,
          aheadRows: 1,
        ),
        <int>[6, 7, 8, 9, 10, 11, 12, 13, 14, 3, 4, 5],
      );
      // 末行不满、预读越过末行：只给存在的页。
      expect(
        mangaPageGridPrefetchOrder(
          pageCount: 8,
          columns: 3,
          firstVisibleRow: 2,
          lastVisibleRow: 5,
          aheadRows: 3,
          behindRows: 0,
        ),
        <int>[6, 7],
      );
      expect(
        mangaPageGridPrefetchOrder(
          pageCount: 0,
          columns: 3,
          firstVisibleRow: 0,
          lastVisibleRow: 0,
          aheadRows: 1,
        ),
        isEmpty,
      );
    });
  });

  group('OnlineMangaReaderSession 后台请求', () {
    test('排在前台请求之后，共用并发上限；落盘后阅读直接命中缓存不再打源', () async {
      final _GatedFetcher fetcher = _GatedFetcher();
      final OnlineMangaReaderSession session = await open(fetcher);
      final Object owner = Object();
      final List<Future<File>> background = <Future<File>>[
        for (final int i in <int>[10, 11, 12])
          session.backgroundPage(i, owner: owner),
      ];
      final Future<void> foreground = session.page(20);
      await _waitFor(() => fetcher.calls.length >= 2, 'two calls');
      // 并发 2：10、11 在飞，前台 20 插到 12 前面。
      expect(fetcher.calls, <int>[10, 11]);
      fetcher.release(10);
      await _waitFor(() => fetcher.calls.length >= 3, 'third call');
      expect(fetcher.calls, <int>[10, 11, 20]);
      fetcher.openAll();
      await foreground;
      await Future.wait(background);
      await session.debugWaitForIdle();
      expect(fetcher.calls, <int>[10, 11, 20, 12]);
      expect(fetcher.maxInFlight, 2);

      await session.page(12);
      expect(fetcher.calls, <int>[10, 11, 20, 12], reason: '缩略图取的页就是阅读缓存');
      expect(session.cachedFilePath(12), isNotNull);
      await session.close();
    });

    test('阅读翻页丢过期预取时不误伤后台请求', () async {
      final _GatedFetcher fetcher = _GatedFetcher(autoComplete: true);
      final OnlineMangaReaderSession session = await open(
        fetcher,
        concurrency: 1,
        prefetchAhead: 1,
      );
      final Object owner = Object();
      // 0 在飞，阅读预取 1 排队；缩略图要的 30 排在它后面。
      final Future<void> first = session.page(0);
      final Future<File> far = session.backgroundPage(30, owner: owner);
      // 跳到第 5 页：窗口外的阅读预取 1 被丢，30 归缩略图管、不动。
      final Future<void> jumped = session.page(5);
      await first;
      await jumped;
      await far;
      await session.debugWaitForIdle();
      expect(fetcher.calls, contains(30));
      expect(fetcher.calls, isNot(contains(1)));
      await session.close();
    });

    test('retainBackgroundPages 按新顺序重排，撤掉的不打源', () async {
      final _GatedFetcher fetcher = _GatedFetcher();
      final OnlineMangaReaderSession session = await open(
        fetcher,
        concurrency: 1,
      );
      final Object owner = Object();
      final Map<int, Future<File>> futures = <int, Future<File>>{
        for (final int i in <int>[0, 1, 2, 3, 4])
          i: session.backgroundPage(i, owner: owner),
      };
      final List<Object> cancelled = <Object>[];
      for (final MapEntry<int, Future<File>> entry in futures.entries) {
        unawaited(
          entry.value.then<void>(
            (_) {},
            onError: (Object error) => cancelled.add(entry.key),
          ),
        );
      }
      await _waitFor(() => fetcher.calls.isNotEmpty, 'first call');
      expect(fetcher.calls, <int>[0]);
      session.retainBackgroundPages(owner, <int>[4, 2]);
      await _waitFor(() => cancelled.length >= 2, 'cancellations');
      expect(cancelled, unorderedEquals(<int>[1, 3]));
      fetcher.openAll();
      await Future.wait(<Future<File>>[futures[0]!, futures[4]!, futures[2]!]);
      await session.debugWaitForIdle();
      expect(fetcher.calls, <int>[0, 4, 2]);
      await session.close();
    });
  });

  group('OnlineMangaThumbnailPrefetcher', () {
    test('按可见优先取页、并发不超会话上限，页到了通知网格', () async {
      final _GatedFetcher fetcher = _GatedFetcher(autoComplete: true);
      final OnlineMangaReaderSession session = await open(fetcher);
      final OnlineMangaThumbnailPrefetcher prefetcher =
          OnlineMangaThumbnailPrefetcher(session);
      int notifications = 0;
      prefetcher.addListener(() => notifications++);
      prefetcher.requestPages(<int>[6, 7, 8, 3, 4, 5]);
      await session.debugWaitForIdle();
      await _settle();
      expect(fetcher.calls, <int>[6, 7, 8, 3, 4, 5]);
      expect(fetcher.maxInFlight, lessThanOrEqualTo(2));
      expect(notifications, 6);
      for (final int i in <int>[3, 4, 5, 6, 7, 8]) {
        expect(session.cachedFilePath(i), isNotNull);
      }
      // 已缓存的页再要不打源。
      prefetcher.requestPages(<int>[6, 7, 8]);
      await session.debugWaitForIdle();
      expect(fetcher.calls, hasLength(6));
      prefetcher.dispose();
      await session.close();
    });

    test('滚走后窗口外还在排队的撤掉不打源；stop 后不再发请求', () async {
      final _GatedFetcher fetcher = _GatedFetcher();
      final OnlineMangaReaderSession session = await open(fetcher);
      final OnlineMangaThumbnailPrefetcher prefetcher =
          OnlineMangaThumbnailPrefetcher(session);
      prefetcher.requestPages(<int>[0, 1, 2, 3, 4, 5]);
      await _waitFor(() => fetcher.calls.length >= 2, 'two calls');
      expect(fetcher.calls, <int>[0, 1]);
      // 滚到底：0、1 已在飞（不撤，落盘照样给阅读用），2–5 撤单。
      prefetcher.requestPages(<int>[30, 31, 32]);
      fetcher
        ..release(0)
        ..release(1);
      await _waitFor(() => fetcher.calls.length >= 4, 'four calls');
      expect(fetcher.calls, <int>[0, 1, 30, 31]);
      prefetcher.stop();
      fetcher.openAll();
      await session.debugWaitForIdle();
      await _settle();
      expect(fetcher.calls, <int>[0, 1, 30, 31], reason: '32 在 stop 时撤掉');
      expect(session.cachedFilePath(0), isNotNull, reason: '在飞的不撤，落盘给阅读用');
      prefetcher.requestPages(<int>[10, 11]);
      await session.debugWaitForIdle();
      expect(fetcher.calls, hasLength(4), reason: 'stop 之后不再发请求');
      await session.close();
    });

    test('同一页最多试两次；连续失败三次本次面板停手', () async {
      final _GatedFetcher fetcher = _GatedFetcher(autoComplete: true)
        ..failing.addAll(<int>[0]);
      final OnlineMangaReaderSession session = await open(
        fetcher,
        concurrency: 1,
      );
      final OnlineMangaThumbnailPrefetcher prefetcher =
          OnlineMangaThumbnailPrefetcher(session);
      for (int round = 0; round < 4; round++) {
        prefetcher.requestPages(<int>[0]);
        await session.debugWaitForIdle();
        await _settle();
      }
      expect(fetcher.calls, <int>[0, 0], reason: '失败页滚回来再试，最多两次');
      expect(prefetcher.halted, isFalse);

      fetcher.failing.addAll(<int>[1, 2, 3, 4, 5]);
      prefetcher.requestPages(<int>[1, 2, 3, 4, 5, 6]);
      await session.debugWaitForIdle();
      await _settle();
      // 0 连败两次 + 1 再败一次 = 连败 3 次：停手，排队的 3–6 撤单。
      expect(prefetcher.halted, isTrue);
      final int before = fetcher.calls.length;
      prefetcher.requestPages(<int>[10, 11]);
      await session.debugWaitForIdle();
      expect(fetcher.calls.length, before, reason: '停手后不再打源');
      expect(fetcher.calls, isNot(contains(4)));
      expect(fetcher.calls, isNot(contains(6)));
      await session.close();
    });

    test('换章（会话关闭）后排队的随之失败，不再发请求', () async {
      final _GatedFetcher fetcher = _GatedFetcher();
      final OnlineMangaReaderSession session = await open(fetcher);
      final OnlineMangaThumbnailPrefetcher prefetcher =
          OnlineMangaThumbnailPrefetcher(session);
      prefetcher.requestPages(<int>[0, 1, 2, 3]);
      await _waitFor(() => fetcher.calls.length >= 2, 'two calls');
      await session.close();
      fetcher.openAll();
      await session.debugWaitForIdle();
      await _settle();
      expect(fetcher.calls, <int>[0, 1]);
      expect(prefetcher.halted, isTrue);
      expect(() => prefetcher.requestPages(<int>[5]), returnsNormally);
      prefetcher.dispose();
    });
  });

  group('MangaPageGridSheet 接预取', () {
    testWidgets('打开即按可见区请求（当前页所在行在前），滚动换区重发，关掉 stop', (
      WidgetTester tester,
    ) async {
      final _RecordingPrefetcher prefetcher = _RecordingPrefetcher();
      final Set<int> landed = <int>{};
      await tester.binding.setSurfaceSize(const Size(500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaPageGridSheet(
              pageCount: 120,
              currentPages: const <int>{60},
              thumbnail: (int index) => landed.contains(index)
                  ? MemoryImage(_GatedFetcher.png)
                  : null,
              prefetcher: prefetcher,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(prefetcher.requests, hasLength(1));
      final List<int> first = prefetcher.requests.single;
      expect(first, contains(60), reason: '当前页附近的可见行在请求里');
      expect(first.indexOf(60), lessThan(first.length ~/ 2));
      expect(first, isNot(contains(0)));
      expect(first, isNot(contains(119)));

      // 页到了：通知后格子换成页图。
      final int target = first.first;
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('manga_page_grid_item_$target')),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
      landed.add(target);
      prefetcher.ping();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('manga_page_grid_item_$target')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );

      await tester.drag(
        find.byKey(const ValueKey<String>('manga_page_grid')),
        const Offset(0, 20000),
      );
      await tester.pumpAndSettle();
      expect(prefetcher.requests.length, greaterThan(1));
      expect(prefetcher.requests.last.first, 0, reason: '滚到顶后第一页最先要');

      await tester.pumpWidget(const SizedBox());
      expect(prefetcher.stops, 1);
    });
  });
}
