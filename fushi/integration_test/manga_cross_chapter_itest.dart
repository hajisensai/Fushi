/// 书架在线漫画跨章翻页：翻过上一章末页后，WebView 里必须真的换成下一章的
/// 文档与页图（用户报：跨章后只有第一页 / 页码更新，正文仍是旧章）。
///
/// 两章都按下载服务的真实落盘形态播种（章目录 + `images/page-00000N.png`，两章
/// 页名相同），用页图尺寸区分章：第 1 章 800×1200、第 2 章 600×1000。判据只读
/// WebView DOM（可见页的 `naturalWidth` / 文档页数），不信 Dart 侧状态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const OnlineMangaChapter _chapter1 = OnlineMangaChapter(
  key: '/chapter/1',
  name: 'Chapter 1',
  raw: <String, Object?>{'url': '/chapter/1'},
  number: 1,
);
const OnlineMangaChapter _chapter2 = OnlineMangaChapter(
  key: '/chapter/2',
  name: 'Chapter 2',
  raw: <String, Object?>{'url': '/chapter/2'},
  number: 2,
);

Future<void> _writeChapter(
  String bookDir,
  String chapterKey, {
  required int pages,
  required int width,
  required int height,
  required int seed,
}) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  await images.create(recursive: true);
  const TestImageGenerator generator = TestImageGenerator();
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  for (int index = 0; index < pages; index++) {
    final String name = 'page-${(index + 1).toString().padLeft(6, '0')}.png';
    await File(p.join(images.path, name)).writeAsBytes(
      generator.pngBytes(width: width, height: height, seed: seed + index),
    );
    entries.add(<String, Object?>{
      'url': '${MangaStorage.kImagesDirName}/$name',
      'width': width,
      'height': height,
      'blocks': <Object?>[],
    });
  }
  await mangaChapterJsonFile(
    chapterDir,
  ).writeAsString(jsonEncode(<String, Object?>{'pages': entries}));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('翻过章末页后 WebView 换成下一章的文档与页图', (WidgetTester tester) async {
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);

    final String bookKey =
        'cross-chapter-${DateTime.now().microsecondsSinceEpoch}';
    final String bookDir = await MangaStorage.bookPath(bookKey);
    await Directory(bookDir).create(recursive: true);
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString('{"pages":[]}');
    await _writeChapter(
      bookDir,
      _chapter1.key,
      pages: 4,
      width: 800,
      height: 1200,
      seed: 1,
    );
    await _writeChapter(
      bookDir,
      _chapter2.key,
      pages: 3,
      width: 600,
      height: 1000,
      seed: 101,
    );
    // 源按新→旧：下一章 = 下标 -1。从第 1 章（末尾）开始读。
    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.crosschapter',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/cross-chapter',
        title: 'Cross chapter fixture',
        raw: <String, Object?>{'url': '/series/cross-chapter'},
      ),
      chapters: <OnlineMangaChapter>[_chapter2, _chapter1],
      currentChapterIndex: 1,
    );
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Cross chapter fixture',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: bookDir,
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(entry.encode()),
      ),
    );
    final EpubBookRow book = (await appModel.database.getEpubBook(bookKey))!;
    await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
      'ocrTrigger': 'manual',
      'direction': 'ltr',
      'mode': 'spread',
      'autoMode': false,
      'downloadAhead': false,
      'skipRead': false,
    });

    Future<int?> currentChapterIndex() async {
      final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
      return OnlineMangaLibraryEntry.tryParse(
        row?.sourceMetadata,
      )?.currentChapterIndex;
    }

    Future<Map<String, Object?>> visiblePage() async {
      final dynamic reader = tester.state(find.byType(MangaFushiPage));
      final Object? raw = await reader.debugEvaluateJavascript('''
        (function () {
          const pages = Array.from(document.querySelectorAll('.manga-page'));
          const hit = document.elementFromPoint(
            window.innerWidth / 2, window.innerHeight / 2);
          const page = hit && hit.closest ? hit.closest('.manga-page') : null;
          const img = page ? page.querySelector('img') : null;
          return JSON.stringify({
            pageCount: pages.length,
            page: page ? Number(page.getAttribute('data-page')) : null,
            complete: img ? img.complete : null,
            naturalWidth: img ? img.naturalWidth : null,
          });
        })();
      ''');
      expect(raw, isA<String>());
      return (jsonDecode(raw! as String) as Map).cast<String, Object?>();
    }

    // 页图异步解码：等可见页图片解完再读尺寸。
    Future<Map<String, Object?>> settledVisiblePage() async {
      Map<String, Object?> snapshot = await visiblePage();
      for (
        int attempt = 0;
        attempt < 40 &&
            (snapshot['complete'] != true || snapshot['naturalWidth'] == 0);
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
        snapshot = await visiblePage();
      }
      debugPrint('[cross-chapter] visible=$snapshot');
      return snapshot;
    }

    final NavigatorState navigator = appModel.navigatorKey.currentState!;
    bool readerOpen = false;
    try {
      final BuildContext navContext = navigator.context;
      if (!navContext.mounted) fail('navigator context unmounted');
      unawaited(
        navigator.push(
          adaptivePageRoute<void>(
            context: navContext,
            builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
              child: MangaFushiPage(item: null, bookKey: bookKey),
            ),
          ),
        ),
      );
      readerOpen = true;
      final Finder content = find.byKey(
        const ValueKey<String>('manga_content_ready'),
      );
      for (
        int attempt = 0;
        attempt < 80 && content.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(content, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      final Map<String, Object?> opened = await settledVisiblePage();
      expect(opened['pageCount'], 4, reason: 'chapter 1 document');
      expect(opened['naturalWidth'], 800, reason: 'chapter 1 page image');

      // 逐页往后翻，直到跨进第 2 章（每步等串行翻页队列落地）。
      for (int press = 0; press < 12; press++) {
        if (await currentChapterIndex() == 0) break;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 700));
      }
      expect(await currentChapterIndex(), 0, reason: 'switched to chapter 2');
      await tester.pump(const Duration(seconds: 2));

      final Map<String, Object?> crossed = await settledVisiblePage();
      expect(crossed['pageCount'], 3, reason: 'chapter 2 document');
      expect(crossed['page'], 0, reason: 'lands on chapter 2 first page');
      expect(crossed['naturalWidth'], 600, reason: 'chapter 2 page image');

      // 新章里继续往后翻：第 2 页也必须是第 2 章的图，不是旧章同名页。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(seconds: 2));
      final Map<String, Object?> next = await settledVisiblePage();
      expect(next['page'], 1, reason: 'second page of chapter 2');
      expect(next['naturalWidth'], 600, reason: 'chapter 2 second page image');
    } finally {
      if (readerOpen) {
        navigator.pop();
        await tester.pump(const Duration(seconds: 1));
      }
      await appModel.database.deleteEpubBook(bookKey);
      try {
        await Directory(bookDir).delete(recursive: true);
      } on FileSystemException {
        // 阅读器刚关，Windows 上文件句柄可能还没放：隔离数据根随测试丢弃。
      }
    }
  });
}
