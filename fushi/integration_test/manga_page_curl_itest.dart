/// 漫画阅读器「卷页」翻页的真 app 回归：真 WebView + 真着色器叠层 + 真 Dart 翻页链路。
///
/// 左开（ltr）与右开（rtl，镜像卷页）各一遍，两章各 10 页：
///   1. 按键前进 / 后退：叠层出现且角点逐帧移动，结束后叠层撤掉、恰好走一页。
///   2. 连按 3 次：恰好前进 3 页。
///   3. 拖动跟手（页面自己的 pointer 监听收合成触摸 → `onPageCurlDrag` → 控制器）：
///      长拖翻页、短慢拖回卷不翻页、反向长拖翻回。
///   4. 跨章：按键一路翻过章末进下一章、首页落在第 0 页，叠层无残留。
///
/// 判据读 WebView DOM（中心可见页）+ 数据库里的当前章，不信 Dart 私有状态。
///
/// Windows：`powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 integration_test/manga_page_curl_itest.dart`
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
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/reader/page_curl/page_curl.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'helpers/page_curl_probe.dart';
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

const int _kPages = 10;

Future<void> _writeChapter(
  String bookDir,
  String chapterKey, {
  required int width,
  required int height,
  required int seed,
}) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  await images.create(recursive: true);
  const TestImageGenerator generator = TestImageGenerator();
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  for (int index = 0; index < _kPages; index++) {
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

PageCurlController? _curl() {
  final Finder f = find.byType(PageCurlOverlay);
  if (f.evaluate().isEmpty) return null;
  return (f.evaluate().first.widget as PageCurlOverlay).controller;
}

class _Report {
  final List<String> failures = <String>[];
  final Map<String, Object?> evidence = <String, Object?>{};

  void check(bool ok, String what) {
    if (!ok) failures.add(what);
    debugPrint('[manga-curl] ${ok ? 'ok  ' : 'FAIL'} $what');
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<Object?> _evalRaw(WidgetTester tester, String js) async {
  final dynamic reader = tester.state(find.byType(MangaFushiPage));
  return reader.debugEvaluateJavascript(js);
}

Future<Map<String, Object?>> _visible(WidgetTester tester) async {
  final Object? raw = await _evalRaw(tester, '''
    (function () {
      const hit = document.elementFromPoint(
        window.innerWidth / 2, window.innerHeight / 2);
      const page = hit && hit.closest ? hit.closest('.manga-page') : null;
      const img = page ? page.querySelector('img') : null;
      return JSON.stringify({
        pageCount: document.querySelectorAll('.manga-page').length,
        page: page ? Number(page.getAttribute('data-page')) : null,
        spread: (function () {
          if (page && page.hasAttribute('data-spread')) {
            return Number(page.getAttribute('data-spread'));
          }
          const sp = page && page.closest ? page.closest('[data-spread]') : null;
          return sp ? Number(sp.getAttribute('data-spread')) : null;
        })(),
        naturalWidth: img ? img.naturalWidth : null,
        w: window.innerWidth, h: window.innerHeight,
      });
    })();
  ''');
  return (jsonDecode(raw! as String) as Map).cast<String, Object?>();
}

/// 等控制器空闲后读可见页。
Future<Map<String, Object?>> _settled(WidgetTester tester) async {
  for (int i = 0; i < 150; i++) {
    final PageCurlController? c = _curl();
    if (c == null || !c.active) break;
    await tester.pump(const Duration(milliseconds: 20));
  }
  await _pumpFor(tester, const Duration(milliseconds: 600));
  final Map<String, Object?> v = await _visible(tester);
  final PageCurlController? c = _curl();
  v['ctlActive'] = c?.active;
  v['ctlVisible'] = c?.visible;
  return v;
}

bool _clean(Map<String, Object?> v) =>
    v['ctlActive'] != true && v['ctlVisible'] != true;

/// 当前跨页序号（翻页的单位；右开首个跨页是单页封面，按页号算不均匀）。
int _page(Map<String, Object?> v) => (v['spread'] as num?)?.toInt() ?? -99;

Future<Map<String, Object?>> _keyTurn(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  String? shot,
}) async {
  await tester.sendKeyEvent(key);
  bool sawVisible = false;
  final Set<int> xs = <int>{};
  String? shotPath;
  final DateTime end = DateTime.now().add(const Duration(milliseconds: 1500));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    final PageCurlController? c = _curl();
    if (c != null && c.visible) {
      sawVisible = true;
      xs.add(c.geometry.point.dx.round());
      if (shot != null && shotPath == null && xs.length >= 4) {
        shotPath = (await captureFlutterFrame(tester, shot)).path;
      }
    }
    if (sawVisible && c != null && !c.active) break;
  }
  return <String, Object?>{
    'sawVisible': sawVisible,
    'distinctX': xs.length,
    'shot': shotPath,
  };
}

/// 合成触摸拖动：分派到页面自己的 pointer 监听（与真触摸同一条 JS 手势路径）。
Future<Map<String, Object?>> _drag(
  WidgetTester tester, {
  required double x0,
  required double y,
  required double dx,
  double dy = 0,
  required int steps,
  required int stepMs,
  required int holdMs,
  String? probe,
  Uint8List? baseline,
  bool returnBeforeUp = false,
}) async {
  String ev(String type, double x, [double? atY]) {
    final double yy = atY ?? y;
    return '''
    (function () {
      var t = document.elementFromPoint($x, $yy) || document.body;
      t.dispatchEvent(new PointerEvent('$type', {
        bubbles: true, cancelable: true, composed: true, pointerId: 7,
        pointerType: 'touch', isPrimary: true, button: 0,
        buttons: ${type == 'pointerup' ? 0 : 1}, clientX: $x, clientY: $yy
      }));
      return 'ok';
    })();
  ''';
  }

  await _evalRaw(tester, ev('pointerdown', x0));
  await _pumpFor(tester, Duration(milliseconds: stepMs));
  bool sawVisible = false;
  for (int i = 1; i <= steps; i++) {
    await _evalRaw(
      tester,
      ev('pointermove', x0 + dx * i / steps, y + dy * i / steps),
    );
    await _pumpFor(tester, Duration(milliseconds: stepMs));
    final PageCurlController? c = _curl();
    if (c != null && c.visible) sawVisible = true;
  }
  await _pumpFor(tester, Duration(milliseconds: holdMs));
  final PageCurlController? c = _curl();
  final Map<String, Object?> held = <String, Object?>{
    'visible': c?.visible,
    'pointX': c?.geometry.point.dx.round(),
    'mirror': c?.geometry.mirror,
  };
  Map<String, Object?>? shading;
  if (probe != null && c != null && c.visible) {
    shading = await probePageCurlShading(tester, c, probe, baseline: baseline);
  }
  if (returnBeforeUp) {
    // 手指拖回起点再松手：回卷，页不变。
    await _evalRaw(tester, ev('pointermove', x0, y));
    await _pumpFor(tester, Duration(milliseconds: stepMs));
    await _evalRaw(tester, ev('pointerup', x0, y));
  } else {
    await _evalRaw(tester, ev('pointerup', x0 + dx, y + dy));
  }
  return <String, Object?>{
    'sawVisible': sawVisible,
    'held': held,
    'shading': ?shading,
  };
}

Future<void> _runDirection(
  WidgetTester tester,
  AppModel appModel,
  String direction,
  _Report r,
) async {
  final String bookKey =
      'manga-curl-$direction-${DateTime.now().microsecondsSinceEpoch}';
  final String bookDir = await MangaStorage.bookPath(bookKey);
  await Directory(bookDir).create(recursive: true);
  // iOS 按商店合规不提供在线漫画源宿主（[StoreRestrictedCapability.onlineMangaSource]），
  // 在线源夹具在那里打不开阅读器：改用本地导入卷（同一批页图），只跳过跨章段。
  final bool online = StoreRestrictedCapability.onlineMangaSource.isAvailable;
  if (online) {
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString('{"pages":[]}');
    await _writeChapter(
      bookDir,
      _chapter1.key,
      width: 800,
      height: 1200,
      seed: 1,
    );
    await _writeChapter(
      bookDir,
      _chapter2.key,
      width: 600,
      height: 1000,
      seed: 101,
    );
    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.mangacurl',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/manga-curl',
        title: 'Manga curl fixture',
        raw: <String, Object?>{'url': '/series/manga-curl'},
      ),
      chapters: <OnlineMangaChapter>[_chapter2, _chapter1],
      currentChapterIndex: 1,
    );
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Manga curl fixture $direction',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: bookDir,
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(entry.encode()),
      ),
    );
  } else {
    final Directory images = Directory(
      p.join(bookDir, MangaStorage.kImagesDirName),
    );
    await images.create(recursive: true);
    const TestImageGenerator generator = TestImageGenerator();
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int index = 0; index < _kPages; index++) {
      final String name = 'p${index.toString().padLeft(3, '0')}.png';
      await File(p.join(images.path, name)).writeAsBytes(
        generator.pngBytes(width: 800, height: 1200, seed: 1 + index),
      );
      pages.add(<String, Object?>{
        'url': name,
        'width': 800,
        'height': 1200,
        'blocks': <Object?>[],
      });
    }
    await File(
      p.join(bookDir, MangaStorage.kMangaJsonFileName),
    ).writeAsString(jsonEncode(<String, Object?>{'pages': pages}));
    await appModel.database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Manga curl fixture $direction',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: bookDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
  }
  final EpubBookRow book = (await appModel.database.getEpubBook(bookKey))!;
  await appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
    'ocrTrigger': 'manual',
    'direction': direction,
    'mode': 'spread',
    'autoMode': false,
    'downloadAhead': false,
    'skipRead': false,
  });

  Future<int?> chapterIndex() async {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    return OnlineMangaLibraryEntry.tryParse(
      row?.sourceMetadata,
    )?.currentChapterIndex;
  }

  final NavigatorState navigator = appModel.navigatorKey.currentState!;
  bool readerOpen = false;
  final LogicalKeyboardKey next = direction == 'rtl'
      ? LogicalKeyboardKey.arrowLeft
      : LogicalKeyboardKey.arrowRight;
  final LogicalKeyboardKey prev = direction == 'rtl'
      ? LogicalKeyboardKey.arrowRight
      : LogicalKeyboardKey.arrowLeft;
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
    for (int i = 0; i < 80 && content.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    r.check(content.evaluate().isNotEmpty, '$direction: reader ready');
    await _pumpFor(tester, const Duration(seconds: 2));
    r.check(_curl() != null, '$direction: curl overlay mounted');

    final Map<String, Object?> v0 = await _settled(tester);
    r.evidence['$direction/open'] = v0;

    // 1. 按键前进 / 后退。
    final Map<String, Object?> k1 = await _keyTurn(
      tester,
      next,
      shot: 'manga-curl-key-$direction',
    );
    final Map<String, Object?> v1 = await _settled(tester);
    r.check(k1['sawVisible'] == true, '$direction: key showed the curl ($k1)');
    r.check(
      ((k1['distinctX'] as int?) ?? 0) >= 4,
      '$direction: corner animated ($k1)',
    );
    // 一步 = 一个跨页（宽窗口下自动双页时是 2 页）。
    final int step = _page(v1) - _page(v0);
    r.check(step == 1, '$direction: key next = one spread ($v0 -> $v1)');
    r.check(_clean(v1), '$direction: no residue ($v1)');
    final Map<String, Object?> k2 = await _keyTurn(tester, prev);
    final Map<String, Object?> v2 = await _settled(tester);
    r.check(k2['sawVisible'] == true, '$direction: key back curled ($k2)');
    r.check(_page(v2) == _page(v0), '$direction: key back ($v1 -> $v2)');

    // 2. 连按。
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(next);
      await _pumpFor(tester, const Duration(milliseconds: 60));
    }
    final Map<String, Object?> v3 = await _settled(tester);
    r.check(
      _page(v3) == _page(v0) + 3 * step,
      '$direction: 3 rapid presses = 3 spreads ($v0 -> $v3)',
    );
    r.check(_clean(v3), '$direction: no residue after rapid ($v3)');
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(prev);
      await _pumpFor(tester, const Duration(milliseconds: 60));
    }
    final Map<String, Object?> v4 = await _settled(tester);
    r.check(_page(v4) == _page(v0), '$direction: rapid back ($v3 -> $v4)');

    // 3. 拖动跟手。左开往左拖 = 下一页；右开相反。
    final double w = (v4['w'] as num).toDouble();
    final double h = (v4['h'] as num).toDouble();
    final double fwd = direction == 'rtl' ? 1 : -1;
    final double fwdStart = direction == 'rtl' ? w * 0.1 : w * 0.9;
    final double backStart = direction == 'rtl' ? w * 0.9 : w * 0.1;

    // 3a. 斜拖停在半途：纸面只有页图（黑边不卷），纸背透出镜像正文。拖回起点
    // 松手回卷。先进到第二个跨页：宽窗口下第一个跨页是单张封面、下一个是双页，
    // 卷起露出的双页本来就比封面宽，「纸面外不变亮」只在前后跨页同宽时成立。
    await tester.sendKeyEvent(next);
    await _pumpFor(tester, const Duration(milliseconds: 60));
    final Map<String, Object?> vProbe = await _settled(tester);
    r.check(
      _page(vProbe) == _page(v1),
      '$direction: probe starts on the second spread ($vProbe)',
    );
    final Uint8List? before = await capturePageCurlBaseline(tester);
    final Map<String, Object?> diag = await _drag(
      tester,
      x0: fwdStart,
      // 起点在页图内（竖屏信箱时页图只占中间），拖得够长让翻起的纸背有面积可量。
      y: h * 0.6,
      // 横向为主（JS 手势按首段位移定轴，竖屏上纵向分量大了会判成纵向滑动）。
      dx: fwd * w * 0.75,
      dy: -h * 0.12,
      steps: 12,
      stepMs: 32,
      holdMs: 200,
      probe: 'manga-curl-shading-$direction',
      baseline: before,
      returnBeforeUp: true,
    );
    final Map<String, Object?> vDiag = await _settled(tester);
    r.evidence['$direction/shading'] = diag['shading'];
    final Map<String, Object?> shading =
        (diag['shading'] as Map<String, Object?>?) ?? <String, Object?>{};
    final List<Object?> paperBox =
        (shading['paper'] as List<Object?>?) ?? <Object?>[];
    final List<Object?> overlayBox =
        (shading['overlay'] as List<Object?>?) ?? <Object?>[];
    r.check(
      paperBox.length == 4 &&
          overlayBox.length == 4 &&
          ((paperBox[2]! as num) < (overlayBox[2]! as num) - 4 ||
              (paperBox[3]! as num) < (overlayBox[3]! as num) - 4),
      '$direction: paper narrowed to the page image ($shading)',
    );
    r.check(
      pageCurlBackShowsMirroredText(shading),
      '$direction: page back shows the mirrored page text ($shading)',
    );
    r.check(
      ((shading['outsideSamples'] as int?) ?? 0) >= 30 &&
          shading['outsideLight'] == 0,
      '$direction: nothing paper-coloured outside the page image ($shading)',
    );
    r.check(
      _page(vDiag) == _page(vProbe) && _clean(vDiag),
      '$direction: probe drag curled back ($vProbe -> $vDiag)',
    );
    await tester.sendKeyEvent(prev);
    await _pumpFor(tester, const Duration(milliseconds: 60));
    final Map<String, Object?> vBack = await _settled(tester);
    r.check(
      _page(vBack) == _page(v4),
      '$direction: back on the first spread after the probe ($vBack)',
    );
    final Map<String, Object?> long = await _drag(
      tester,
      x0: fwdStart,
      y: h * 0.6,
      dx: fwd * w * 0.55,
      steps: 12,
      stepMs: 32,
      holdMs: 150,
    );
    final Map<String, Object?> v5 = await _settled(tester);
    r.check(long['sawVisible'] == true, '$direction: long drag curled ($long)');
    r.check(
      (long['held'] as Map<String, Object?>)['mirror'] == (direction == 'rtl'),
      '$direction: mirror matches direction ($long)',
    );
    r.check(
      _page(v5) == _page(v4) + step,
      '$direction: long drag = next page ($v4 -> $v5)',
    );
    r.check(_clean(v5), '$direction: no residue after long drag ($v5)');
    final Map<String, Object?> short = await _drag(
      tester,
      x0: fwdStart,
      y: h * 0.5,
      dx: fwd * w * 0.1,
      steps: 6,
      stepMs: 100,
      holdMs: 300,
    );
    final Map<String, Object?> v6 = await _settled(tester);
    r.check(
      short['sawVisible'] == true,
      '$direction: short drag curled ($short)',
    );
    r.check(
      _page(v6) == _page(v5),
      '$direction: short drag curled back ($v5 -> $v6)',
    );
    r.check(_clean(v6), '$direction: no residue after spring-back ($v6)');
    final Map<String, Object?> back = await _drag(
      tester,
      x0: backStart,
      y: h * 0.4,
      dx: -fwd * w * 0.55,
      steps: 12,
      stepMs: 32,
      holdMs: 120,
    );
    final Map<String, Object?> v7 = await _settled(tester);
    r.check(back['sawVisible'] == true, '$direction: back drag curled ($back)');
    r.check(
      _page(v7) == _page(v6) - step,
      '$direction: back drag = previous page ($v6 -> $v7)',
    );
    r.check(_clean(v7), '$direction: no residue after back drag ($v7)');

    // 4. 跨章（只有在线源夹具有第二章）。
    if (!online) {
      r.evidence[direction] = <String, Object?>{
        'v0': v0,
        'k1': k1,
        'v1': v1,
        'v3': v3,
        'long': long,
        'v5': v5,
        'short': short,
        'v6': v6,
        'back': back,
        'v7': v7,
      };
      return;
    }
    int presses = 0;
    while (presses < 12 && await chapterIndex() != 0) {
      await tester.sendKeyEvent(next);
      presses++;
      await _pumpFor(tester, const Duration(milliseconds: 700));
      await _settled(tester);
    }
    r.check(
      await chapterIndex() == 0,
      '$direction: crossed into chapter 2 after $presses presses',
    );
    await _pumpFor(tester, const Duration(seconds: 2));
    final Map<String, Object?> v8 = await _settled(tester);
    r.check(
      v8['naturalWidth'] == 600 && _page(v8) == 0,
      '$direction: chapter 2 first page shown ($v8)',
    );
    r.check(_clean(v8), '$direction: no residue after chapter cross ($v8)');
    final Map<String, Object?> k9 = await _keyTurn(tester, next);
    final Map<String, Object?> v9 = await _settled(tester);
    r.check(
      k9['sawVisible'] == true && _page(v9) == step,
      '$direction: curl works in the new chapter ($k9, $v9)',
    );
    r.evidence[direction] = <String, Object?>{
      'v0': v0,
      'k1': k1,
      'v1': v1,
      'v3': v3,
      'long': long,
      'v5': v5,
      'short': short,
      'v6': v6,
      'back': back,
      'v7': v7,
      'presses': presses,
      'v8': v8,
      'v9': v9,
    };
  } catch (e, st) {
    r.check(false, '$direction threw $e\n$st');
  } finally {
    if (readerOpen) {
      navigator.pop();
      await _pumpFor(tester, const Duration(seconds: 1));
    }
    await appModel.database.deleteEpubBook(bookKey);
    try {
      await Directory(bookDir).delete(recursive: true);
    } on FileSystemException {
      // 阅读器刚关，Windows 上文件句柄可能还没放：隔离数据根随测试丢弃。
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'manga page curl: keys, rapid turns, follow drag, chapter cross',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await readyAppModel(tester);
      final String baseAnim = appModel.mangaPageAnimation;
      final String baseSpeed = appModel.mangaPageAnimationSpeed;
      final bool baseFollow = appModel.mangaPageTurnFollowDrag;
      final _Report r = _Report();
      try {
        await appModel.setMangaPageAnimation('curl');
        await appModel.setMangaPageAnimationSpeed('normal');
        await appModel.setMangaPageTurnFollowDrag(true);
        for (final String direction in <String>['ltr', 'rtl']) {
          await _runDirection(tester, appModel, direction, r);
        }
      } finally {
        await appModel.setMangaPageAnimation(baseAnim);
        await appModel.setMangaPageAnimationSpeed(baseSpeed);
        await appModel.setMangaPageTurnFollowDrag(baseFollow);
      }
      debugPrint('[manga-curl] evidence=${jsonEncode(r.evidence)}');
      debugPrint(
        '[manga-curl] summary: ${r.failures.length} failure(s)\n'
        '${r.failures.join('\n')}',
      );
      expect(r.failures, isEmpty, reason: r.failures.join('\n'));
    },
  );
}
