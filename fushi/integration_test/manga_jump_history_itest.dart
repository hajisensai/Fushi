/// 漫画阅读器「跳转回退」胶囊的真机门（Windows 离屏 runner）。
///
/// 翻页（spread，强制单页）与条漫（webtoon 竖滚）各跑一遍：
///
///  1. 开书（第 1 话）→ 没有胶囊；
///  2. 逐页往后翻 3 页（[ReaderSessionRemote.turnPage]，与翻页键 / 悬浮球同一个
///     `_executeReaderInputAction`）→ 胶囊仍不出现；
///  3. 跨章跳到第 2 话（[ReaderSessionRemote.goToChapter]，即 `fushi_cli reader`
///     的跳章入口，走生产入栈调用）→ 胶囊可点；
///  4. 「返回」→ 落回第 1 话第 4 页（Dart 快照 + WebView DOM：文档页数、页图宽度、
///     可见页都要对）；「前进」→ 回到第 2 话；
///  5. 章内跳页（[ReaderSessionRemote.goToPage]）→ 「返回」落回原页；
///  6. × 清空 → 胶囊消失。
///
/// 两话按下载服务的真实落盘形态播种（同 manga_cross_chapter_itest），用页数与页图
/// 尺寸区分：第 1 话 6 页 800×1200、第 2 话 5 页 600×1000。
///
/// 按钮不走坐标点击：先用 `hitTestable` 确认胶囊此刻可见可点，再调胶囊按钮
/// InkWell 的 onTap（即真 UI 的接线）。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test/manga_jump_history_itest.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kBack = 'fushi_jump_back';
const String _kForward = 'fushi_jump_forward';
const String _kClear = 'fushi_jump_clear';
const Key _kContentReadyKey = ValueKey<String>('manga_content_ready');

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

/// 源按新→旧：下标 0 = 第 2 话，下标 1 = 第 1 话。
const int _kChapter1Index = 1;
const int _kChapter2Index = 0;
const int _kChapter1Pages = 6;
const int _kChapter2Pages = 5;
const int _kChapter1Width = 800;
const int _kChapter2Width = 600;

bool _pillPresent(String key) =>
    find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

bool _pillClickable(String key) =>
    find.byKey(ValueKey<String>(key)).hitTestable().evaluate().isNotEmpty;

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  int polls = 80,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (int i = 0; i < polls; i++) {
    if (ready()) return true;
    await tester.pump(step);
  }
  return ready();
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 「按」胶囊按钮：先确认可见可点，再调它 InkWell 的 onTap。
Future<bool> _press(WidgetTester tester, String key) async {
  if (!_pillClickable(key)) return false;
  final Finder ink = find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(InkWell),
  );
  if (ink.evaluate().isEmpty) return false;
  tester.widget<InkWell>(ink.first).onTap!();
  await tester.pump(const Duration(milliseconds: 100));
  return true;
}

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

/// 播种一本两话的书架在线漫画，从第 1 话开始读；[mode] 是本书阅读模式覆盖。
Future<({String bookKey, String bookDir})> _seedBook(
  AppModel appModel,
  String mode,
) async {
  final String bookKey =
      'jump-history-$mode-${DateTime.now().microsecondsSinceEpoch}';
  final String bookDir = await MangaStorage.bookPath(bookKey);
  await Directory(bookDir).create(recursive: true);
  await File(
    p.join(bookDir, MangaStorage.kMangaJsonFileName),
  ).writeAsString('{"pages":[]}');
  await _writeChapter(
    bookDir,
    _chapter1.key,
    pages: _kChapter1Pages,
    width: _kChapter1Width,
    height: 1200,
    seed: 1,
  );
  await _writeChapter(
    bookDir,
    _chapter2.key,
    pages: _kChapter2Pages,
    width: _kChapter2Width,
    height: 1000,
    seed: 101,
  );
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.jumphistory',
    sourceId: '1',
    series: OnlineMangaSeries(
      key: '/series/jump-history-$mode',
      title: 'Jump history fixture ($mode)',
      raw: <String, Object?>{'url': '/series/jump-history-$mode'},
    ),
    chapters: const <OnlineMangaChapter>[_chapter2, _chapter1],
    currentChapterIndex: _kChapter1Index,
  );
  await appModel.database.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Jump history fixture ($mode)',
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
    'mode': mode,
    'autoMode': false,
    'downloadAhead': false,
    'skipRead': false,
  });
  return (bookKey: bookKey, bookDir: bookDir);
}

/// WebView 里当前文档与视口上部那一页（data-page、页图宽度、文档页数）。
Future<Map<String, Object?>> _domPage(WidgetTester tester) async {
  final dynamic reader = tester.state(find.byType(MangaFushiPage));
  final Object? raw = await reader.debugEvaluateJavascript('''
    (function () {
      const pages = Array.from(document.querySelectorAll('.manga-page'));
      const hit = document.elementFromPoint(
        window.innerWidth / 2, window.innerHeight * 0.3);
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
  if (raw is! String) return <String, Object?>{'error': 'no JS result: $raw'};
  return (jsonDecode(raw) as Map).cast<String, Object?>();
}

/// 页图异步解码：等视口页图片解完再读。
Future<Map<String, Object?>> _settledDomPage(WidgetTester tester) async {
  Map<String, Object?> snap = await _domPage(tester);
  for (
    int i = 0;
    i < 40 && (snap['complete'] != true || snap['naturalWidth'] == 0);
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 250));
    snap = await _domPage(tester);
  }
  return snap;
}

ReaderSessionRemote? _remote() => readerSessionRemotes.current.value;

ReaderSessionSnapshot? _snapshot() => _remote()?.snapshot();

/// 等 Dart 侧位置落到（[chapterIndex], [pageIndex]）且换章已结束。
Future<bool> _waitForPosition(
  WidgetTester tester, {
  required int chapterIndex,
  required int pageIndex,
}) async {
  final bool landed = await _waitFor(tester, () {
    final ReaderSessionSnapshot? s = _snapshot();
    return s != null &&
        s.contentReady &&
        s.chapterIndex == chapterIndex &&
        s.pageIndex == pageIndex;
  }, polls: 120);
  if (landed) await _pumpFor(tester, const Duration(milliseconds: 800));
  return landed;
}

Future<void> _runMode(
  WidgetTester tester,
  AppModel appModel,
  String mode,
  List<String> failures,
  Map<String, Object?> evidence,
) async {
  void check(bool ok, String what) {
    if (!ok) failures.add('$mode: $what');
  }

  String describe() {
    final ReaderSessionSnapshot? s = _snapshot();
    return 'chapter=${s?.chapterIndex} page=${s?.pageIndex} '
        'ready=${s?.contentReady}';
  }

  /// DOM 侧核对：文档属于哪一话（页数 + 页图宽度）与视口页。
  Future<void> checkDom(
    String label, {
    required int pageCount,
    required int width,
    required int page,
  }) async {
    final Map<String, Object?> dom = await _settledDomPage(tester);
    evidence['$mode.$label.dom'] = dom;
    check(
      dom['pageCount'] == pageCount,
      '$label: DOM has ${dom['pageCount']} pages, expected $pageCount',
    );
    check(
      dom['naturalWidth'] == width,
      '$label: page image width ${dom['naturalWidth']}, expected $width',
    );
    check(
      dom['page'] == page,
      '$label: viewport shows page ${dom['page']}, expected $page',
    );
  }

  final ({String bookKey, String bookDir}) seeded = await _seedBook(
    appModel,
    mode,
  );
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
            child: MangaFushiPage(item: null, bookKey: seeded.bookKey),
          ),
        ),
      ),
    );
    readerOpen = true;
    final bool ready = await _waitFor(
      tester,
      () => find.byKey(_kContentReadyKey).evaluate().isNotEmpty,
    );
    check(ready, 'content never ready on open');
    if (!ready) return;
    await _pumpFor(tester, const Duration(seconds: 2));
    final ReaderSessionRemote? remote = _remote();
    check(remote != null, 'manga page did not register a session remote');
    if (remote == null) return;
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter1Index,
        pageIndex: 0,
      ),
      'did not open on chapter 1 page 1 (${describe()})',
    );

    // 1. 开书：没有胶囊。
    check(!_pillPresent(_kBack), 'pill shown before any jump');

    // 2. 逐页翻 3 页：不算跳转。
    for (int i = 0; i < 3; i++) {
      await remote.turnPage(forward: true);
      await _pumpFor(tester, const Duration(milliseconds: 700));
    }
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter1Index,
        pageIndex: 3,
      ),
      'page turns did not reach page 4 (${describe()})',
    );
    check(!_pillPresent(_kBack), 'pill shown after plain page turns');
    await checkDom(
      'origin',
      pageCount: _kChapter1Pages,
      width: _kChapter1Width,
      page: 3,
    );

    // 3. 跨章跳到第 2 话 → 胶囊可点。
    check(
      await remote.goToChapter(_kChapter2Index),
      'goToChapter(chapter 2) failed (${describe()})',
    );
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter2Index,
        pageIndex: 0,
      ),
      'chapter jump did not land on chapter 2 page 1 (${describe()})',
    );
    check(
      await _waitFor(tester, () => _pillClickable(_kBack)),
      'back pill not clickable after a chapter jump',
    );
    check(!_pillPresent(_kForward), 'forward button shown before going back');

    // 4. 返回 → 第 1 话第 4 页；前进 → 第 2 话。
    check(await _press(tester, _kBack), 'could not press back');
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter1Index,
        pageIndex: 3,
      ),
      'back did not return to chapter 1 page 4 (${describe()})',
    );
    await checkDom(
      'back',
      pageCount: _kChapter1Pages,
      width: _kChapter1Width,
      page: 3,
    );
    check(
      await _waitFor(tester, () => _pillClickable(_kForward)),
      'forward button not clickable after going back',
    );
    check(await _press(tester, _kForward), 'could not press forward');
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter2Index,
        pageIndex: 0,
      ),
      'forward did not return to chapter 2 (${describe()})',
    );
    await checkDom(
      'forward',
      pageCount: _kChapter2Pages,
      width: _kChapter2Width,
      page: 0,
    );

    // 5. 章内跳页 → 返回落回原页。
    check(await remote.goToPage(3), 'goToPage(4) failed (${describe()})');
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter2Index,
        pageIndex: 3,
      ),
      'page jump did not land on chapter 2 page 4 (${describe()})',
    );
    check(
      await _waitFor(tester, () => _pillClickable(_kBack)),
      'back pill not clickable after an in-chapter page jump',
    );
    check(await _press(tester, _kBack), 'could not press back (page jump)');
    check(
      await _waitForPosition(
        tester,
        chapterIndex: _kChapter2Index,
        pageIndex: 0,
      ),
      'back after page jump did not return to page 1 (${describe()})',
    );
    await checkDom(
      'pageJumpBack',
      pageCount: _kChapter2Pages,
      width: _kChapter2Width,
      page: 0,
    );

    // 6. × 清空 → 胶囊消失。
    check(
      await _waitFor(tester, () => _pillClickable(_kClear)),
      'clear button not clickable',
    );
    check(await _press(tester, _kClear), 'could not press clear');
    await _pumpFor(tester, const Duration(seconds: 1));
    check(!_pillPresent(_kBack), 'back button still present after clear');
    check(!_pillPresent(_kForward), 'forward button still present after clear');
    check(!_pillPresent(_kClear), 'pill still present after clear');
  } finally {
    if (readerOpen) {
      navigator.pop();
      await _pumpFor(tester, const Duration(seconds: 1));
    }
    await appModel.database.deleteEpubBook(seeded.bookKey);
    try {
      await Directory(seeded.bookDir).delete(recursive: true);
    } on FileSystemException {
      // 阅读器刚关，Windows 上文件句柄可能还没放：隔离数据根随测试丢弃。
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'manga jump history: back / forward / clear in spread and webtoon modes',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'manga-jump-history',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await _pumpFor(tester, const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          // 翻页模式强制单页：横屏 runner 下「自动」会拼双页，页号按 spread 跳 2。
          final String baseSpreadPreference = appModel.mangaSpreadPreference;
          final List<String> failures = <String>[];
          final Map<String, Object?> evidence = <String, Object?>{};
          try {
            await appModel.setMangaSpreadPreference('single');
            for (final String mode in <String>['spread', 'webtoon']) {
              try {
                await _runMode(tester, appModel, mode, failures, evidence);
              } catch (e, st) {
                failures.add('$mode: threw $e\n$st');
              }
            }
          } finally {
            await appModel.setMangaSpreadPreference(baseSpreadPreference);
          }
          debugPrint('[manga-jump-history] evidence=${jsonEncode(evidence)}');
          for (final String f in failures) {
            debugPrint('[manga-jump-history]   ✗ $f');
          }
          expect(failures, isEmpty, reason: failures.join('\n'));
        },
      );
    },
  );
}
