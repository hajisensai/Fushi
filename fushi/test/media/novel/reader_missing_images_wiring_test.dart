// 阅读器缺图接线（PR #4016）：LNReader 下载成的 EPUB 没有取章加载器，拦截层下发
// 正文时直接交给缺图状态机；本次导航的目标章出顶部提示；补到图后丢这一章的缓存，
// 正在读这一章就原地重载。状态机本身（自动补取次数、提示内容）见
// online_novel_missing_images_test.dart，下载书补取器见 lnreader_online_book_test.dart。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images_notice.dart';
import 'package:fushi/src/media/novel/online/reader_missing_images_wiring.dart';
import 'package:material_ui/material_ui.dart';

/// 下载书补取器替身：章节文件 `c<n>.xhtml` 对到第 n 章；每章缺几张 / 每轮补到几张
/// 由测试定。
class _FakeDownloadedImages implements OnlineNovelMissingImagesRetrier {
  final Map<int, int> missing = <int, int>{};
  int recoverNext = 0;
  final List<int> inspected = <int>[];
  final List<({int index, bool automatic})> retries =
      <({int index, bool automatic})>[];

  static String fileOf(int index) => '/books/dl/OEBPS/c$index.xhtml';

  @override
  int? chapterIndexForFile(String filePath) {
    final RegExpMatch? m = RegExp(r'/c(\d+)\.xhtml$').firstMatch(filePath);
    return m == null ? null : int.parse(m.group(1)!);
  }

  @override
  Future<OnlineNovelMissingImages> missingImages(int index) async {
    inspected.add(index);
    return OnlineNovelMissingImages(
      index: index,
      count: missing[index] ?? 0,
      autoRetryAvailable: true,
    );
  }

  @override
  Future<OnlineNovelMissingImagesRetry> retryMissingImages(
    int index, {
    required bool automatic,
  }) async {
    retries.add((index: index, automatic: automatic));
    final int before = missing[index] ?? 0;
    final int recovered = recoverNext.clamp(0, before);
    missing[index] = before - recovered;
    return OnlineNovelMissingImagesRetry(
      index: index,
      recovered: recovered,
      remaining: before - recovered,
    );
  }
}

/// 只当「有取章加载器」的标记用：接线不该碰它的任何方法。
class _OpaqueLoader implements OnlineNovelChapterLoader {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// 能补图的取章加载器（在线书 / 网页小说书）。
class _RetrierLoader extends _OpaqueLoader
    implements OnlineNovelMissingImagesRetrier {}

/// 阅读器页面替身：当前章、恢复中标记、下发缓存（文件路径 → 字节）与重载记录。
class _FakeReader {
  bool active = true;
  bool bookReady = true;
  int currentChapter = 0;
  bool restoreInFlight = false;
  final Map<String, int> sanitizedCache = <String, int>{};
  final List<int> discardedChapters = <int>[];
  int reloads = 0;

  ReaderMissingImagesWiring wire(OnlineNovelMissingImagesRetrier retrier) =>
      ReaderMissingImagesWiring(
        retrier: retrier,
        isActive: () => active,
        currentChapter: () => currentChapter,
        restoreInFlight: () => restoreInFlight,
        discardChapterCaches:
            (int index, bool Function(String filePath) inChapter) {
              if (!bookReady) return false;
              sanitizedCache.removeWhere(
                (String path, int _) => inChapter(path),
              );
              discardedChapters.add(index);
              return true;
            },
        reloadCurrentChapter: () async => reloads++,
      );
}

void main() {
  group('开书挑补取器', () {
    test('没有取章加载器（下载书）：用下载书补取器', () {
      final _FakeDownloadedImages downloaded = _FakeDownloadedImages();
      expect(
        readerMissingImagesRetrierFor(
          chapterLoader: null,
          downloadedBookImages: () => downloaded,
        ),
        same(downloaded),
      );
      // 合规门关着时下载书补取器给 null：不建接线。
      expect(
        readerMissingImagesRetrierFor(
          chapterLoader: null,
          downloadedBookImages: () => null,
        ),
        isNull,
      );
    });

    test('取章加载器能补图就用它本身，不问下载书补取器；不能补图就不建', () {
      final _RetrierLoader loader = _RetrierLoader();
      expect(
        readerMissingImagesRetrierFor(
          chapterLoader: loader,
          downloadedBookImages: () => fail('有加载器时不该建下载书补取器'),
        ),
        same(loader),
      );
      expect(
        readerMissingImagesRetrierFor(
          chapterLoader: _OpaqueLoader(),
          downloadedBookImages: () => fail('有加载器时不该建下载书补取器'),
        ),
        isNull,
      );
    });
  });

  group('拦截层下发正文', () {
    test('下载书（没有加载器）：正文文件直接交给缺图状态机，不经取章', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[2] = 1;
      final _FakeReader reader = _FakeReader();
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      await prepareReaderChapterFile(
        filePath: _FakeDownloadedImages.fileOf(2),
        chapterLoader: null,
        missingImages: wiring,
        ensureOnlineChapter: (OnlineNovelChapterLoader _) =>
            fail('下载书不该走取章加载器'),
      );
      await pumpEventQueue();
      expect(images.inspected, <int>[2]);
      expect(images.retries, <({int index, bool automatic})>[
        (index: 2, automatic: true),
      ]);

      // 不是正文文件（导航页 / 图片）：不查缺图。
      await prepareReaderChapterFile(
        filePath: '/books/dl/OEBPS/nav.xhtml',
        chapterLoader: null,
        missingImages: wiring,
        ensureOnlineChapter: (OnlineNovelChapterLoader _) =>
            fail('下载书不该走取章加载器'),
      );
      await pumpEventQueue();
      expect(images.inspected, <int>[2]);
    });

    test('有取章加载器：交给加载器（它取完正文自己报），这里不直接查缺图', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages();
      final ReaderMissingImagesWiring wiring = _FakeReader().wire(images);
      addTearDown(wiring.dispose);
      final _RetrierLoader loader = _RetrierLoader();
      final List<OnlineNovelChapterLoader> ensured =
          <OnlineNovelChapterLoader>[];

      await prepareReaderChapterFile(
        filePath: _FakeDownloadedImages.fileOf(0),
        chapterLoader: loader,
        missingImages: wiring,
        ensureOnlineChapter: (OnlineNovelChapterLoader l) async =>
            ensured.add(l),
      );
      await pumpEventQueue();
      expect(ensured, <OnlineNovelChapterLoader>[loader]);
      expect(images.inspected, isEmpty);
    });

    test('普通书（没有加载器、也没有补取器）：什么都不做', () async {
      await prepareReaderChapterFile(
        filePath: _FakeDownloadedImages.fileOf(0),
        chapterLoader: null,
        missingImages: null,
        ensureOnlineChapter: (OnlineNovelChapterLoader _) => fail('没有加载器不该取章'),
      );
    });
  });

  group('顶部提示', () {
    test('本次导航的目标章补不全才提示剩余张数；预热的邻章不抢提示', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[1] = 3
        ..missing[2] = 2;
      final _FakeReader reader = _FakeReader()
        ..currentChapter = 1
        ..restoreInFlight = true;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterFileServed(_FakeDownloadedImages.fileOf(2));
      await pumpEventQueue();
      expect(wiring.controller.notice, isNull);

      images.recoverNext = 1;
      wiring.chapterFileServed(_FakeDownloadedImages.fileOf(1));
      await pumpEventQueue();
      final OnlineNovelMissingImagesNotice? notice = wiring.controller.notice;
      expect(notice?.chapter, 1);
      expect(notice?.count, 2);
    });

    test('不在恢复导航中下发的章（连续模式挂邻章）：不改提示所跟的章', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[0] = 1;
      final _FakeReader reader = _FakeReader()..currentChapter = 0;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterServed(0);
      await pumpEventQueue();
      expect(wiring.controller.notice, isNull);
      // 导航落定 / 无缝换章由页面经 show 推过来。
      wiring.show(0);
      expect(wiring.controller.notice?.count, 1);
    });

    testWidgets('页面顶部提示条绑在接线的状态机上，显示下载书这一章缺的张数', (WidgetTester tester) async {
      LocaleSettings.setLocale(AppLocale.en);
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[0] = 2;
      final _FakeReader reader = _FakeReader()..restoreInFlight = true;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: OnlineNovelMissingImagesNoticeBar(
                controller: wiring.controller,
              ),
            ),
          ),
        ),
      );
      expect(find.text(t.novel_online_images_missing(n: 2)), findsNothing);

      await tester.runAsync(() async {
        await prepareReaderChapterFile(
          filePath: _FakeDownloadedImages.fileOf(0),
          chapterLoader: null,
          missingImages: wiring,
          ensureOnlineChapter: (OnlineNovelChapterLoader _) =>
              fail('下载书不该走取章加载器'),
        );
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(find.text(t.novel_online_images_missing(n: 2)), findsOneWidget);
    });
  });

  group('补到图后', () {
    test('正在读这一章：丢这一章的下发缓存（别章不动）并原地重载', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[1] = 1
        ..recoverNext = 1;
      final _FakeReader reader = _FakeReader()..currentChapter = 1;
      reader.sanitizedCache
        ..[_FakeDownloadedImages.fileOf(0)] = 0
        ..[_FakeDownloadedImages.fileOf(1)] = 1;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterFileServed(_FakeDownloadedImages.fileOf(1));
      await pumpEventQueue();
      expect(reader.discardedChapters, <int>[1]);
      expect(reader.sanitizedCache.keys, <String>[
        _FakeDownloadedImages.fileOf(0),
      ]);
      expect(reader.reloads, 1);
      expect(wiring.controller.notice, isNull);
    });

    test('补到的是预热的邻章：丢缓存，不重载当前页', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[2] = 1
        ..recoverNext = 1;
      final _FakeReader reader = _FakeReader()..currentChapter = 1;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterServed(2);
      await pumpEventQueue();
      expect(reader.discardedChapters, <int>[2]);
      expect(reader.reloads, 0);
    });

    test('恢复导航还在进行：丢缓存但不重载（导航本身会装这一章）', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[0] = 1
        ..recoverNext = 1;
      final _FakeReader reader = _FakeReader()..restoreInFlight = true;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterServed(0);
      await pumpEventQueue();
      expect(reader.discardedChapters, <int>[0]);
      expect(reader.reloads, 0);
    });

    test('书没就绪 / 页面已离开：不重载', () async {
      final _FakeDownloadedImages images = _FakeDownloadedImages()
        ..missing[0] = 1
        ..missing[1] = 1
        ..recoverNext = 1;
      final _FakeReader reader = _FakeReader()..bookReady = false;
      final ReaderMissingImagesWiring wiring = reader.wire(images);
      addTearDown(wiring.dispose);

      wiring.chapterServed(0);
      await pumpEventQueue();
      expect(reader.reloads, 0);

      reader
        ..bookReady = true
        ..active = false
        ..currentChapter = 1;
      wiring.chapterServed(1);
      await pumpEventQueue();
      expect(reader.discardedChapters, isEmpty);
      expect(reader.reloads, 0);
    });
  });
}
