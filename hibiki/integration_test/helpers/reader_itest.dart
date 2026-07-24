import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show hibikiBooksProvider;
import 'package:hibiki/src/models/app_model.dart' show AppModel, appProvider;

import '../test_helpers.dart';
import 'focus_driver.dart';
import 'generate_test_epub.dart' show EpubGenerator;
import 'library_fixture.dart' show readyAppModel, seedReaderBook;

/// reader 系列集成测试的共享启动/开书夹具。
///
/// 这些 helper 是从 `reader_*_itest.dart` 五件套（收藏/合集跳转、余白实时应用、
/// 竖排振假名）、两件 DOM-inset 验收（顶部进度 inset、悬浮 chrome）以及查词系列
/// （弹窗右键/连续查词/查词时延）里成套复制出来的样板，逐字上移，未改任何驱动
/// 方式：仍是焦点驱动（[FocusDriver] / `sendKeyEvent`），绝不 `tester.tap` 坐标点击。

/// reader WebView 是否挂载（`hoshi_webview` key 出现）。
bool readerWebViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

/// 内容就绪标记（`hoshiReader` 已注入、首章已铺好）。
bool readerContentReady() => find
    .byKey(const ValueKey<String>('hoshi_content_ready'))
    .evaluate()
    .isNotEmpty;

/// 每 500ms pump 一次直到 [ready] 为真，超时 [fail]。[logPrefix] 只进 debug 日志
/// （原各文件的 `[coll-jump]` / `[favjump]` / `[margin]` 等标签）。
Future<void> waitForReaderCondition(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  String logPrefix = 'reader',
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) {
      debugPrint('[$logPrefix] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

/// 启动 app、开实验性焦点导航、播种一本 reader EPUB、焦点驱动开到阅读器并等
/// WebView + hoshi content 就绪。返回 seed 的 bookKey。
///
/// 五个 reader itest 的成套开书样板（逐字同一路径）。必须在 `runHibikiItest`
/// 的 body 里调用（它内部会 `app.main()` + `waitForHome`）。
Future<String> openSeededReaderBook(
  WidgetTester tester, {
  required String fileName,
  String logPrefix = 'reader',
}) async {
  app.main();
  expect(await waitForHome(tester), isTrue,
      reason: 'home (nav bar) must render');
  await tester.pump(const Duration(seconds: 2));

  // 焦点驱动需要 HibikiFocusRoot（默认 OFF；开关后 main.dart 重建装上壳）。
  final AppModel appModel = await readyAppModel(tester);
  await appModel.setExperimentalFocusNavigationEnabled(true);
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }

  final String bookKey = await seedReaderBook(tester, fileName: fileName);
  final FocusDriver driver = FocusDriver(tester);

  // 焦点落到书架标签后打开第一本书。
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isNotEmpty) {
    await driver.focusWidget(navTargets.first);
    await driver.activate();
    await tester.pump(const Duration(seconds: 1));
  }

  final Finder bookEntries = findBookEntries();
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (bookEntries.evaluate().isNotEmpty) break;
  }
  expect(bookEntries, findsWidgets,
      reason: 'seeded book must appear on the shelf');
  expect(await driver.focusWidget(bookEntries.first), isTrue,
      reason: 'book card must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(seconds: 3));

  await waitForReaderCondition(tester, readerWebViewShown, 'reader WebView',
      logPrefix: logPrefix);
  await waitForReaderCondition(tester, readerContentReady, 'hoshi content',
      logPrefix: logPrefix);
  return bookKey;
}

/// 启动 app、等 home 就绪、等 [AppModel] 初始化完成，返回它。
///
/// 查词系列 itest（`dict_popup_*` / `reader_continuous_lookup_*` /
/// `lookup_latency_*`）的成套启动样板：`app.main()` + `waitForHome` +
/// 轮询 `isInitialised`。
Future<AppModel> launchAppAndReadyModel(
  WidgetTester tester, {
  String homeReason = 'Home must render',
}) async {
  app.main();
  expect(await waitForHome(tester), isTrue, reason: homeReason);
  await tester.pump(const Duration(seconds: 2));
  return readyAppModel(tester);
}

/// 在 WebView 里定位正文首个可见文本块并回传其 client rect（JSON）。抽成顶层常量，
/// 避免 Dart 多行字符串与脚本拼接相互混淆。
const String jsFirstTextLineProbe = r'''
(function(){
  function visible(el){
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    return (el.textContent || '').trim().length > 0;
  }
  var nodes = document.querySelectorAll('p,div,span,li,blockquote,h1,h2,h3');
  for (var i = 0; i < nodes.length; i++) {
    var el = nodes[i];
    var hasChildBlock = false;
    for (var j = 0; j < el.children.length; j++) {
      if (visible(el.children[j])) { hasChildBlock = true; break; }
    }
    if (hasChildBlock) continue;
    if (!visible(el)) continue;
    var r = el.getBoundingClientRect();
    return JSON.stringify({
      top: r.top,
      bottom: r.bottom,
      tag: el.tagName,
      text: (el.textContent || '').trim().substr(0, 12)
    });
  }
  return JSON.stringify(null);
})()
''';

/// Books 标签置前（home 可能默认别的 tab；书架列表也会懒加载）。焦点驱动。
Future<void> openBooksTabViaFocus(
  WidgetTester tester,
  FocusDriver driver,
) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 导入一本全新合成 EPUB（无有声书），返回其 book key。走 `pumpAndSettle`（调用方
/// 随后自行轮询书架条目可见）。[logPrefix] 只进 debug 日志。
Future<String> seedPaginatedTestBook(
  WidgetTester tester, {
  required String fileName,
  required String logPrefix,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AppModel appModel = container.read(appProvider);
  for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(appModel.isInitialised, isTrue,
      reason: 'AppModel must be initialised before importing a book');

  final Uint8List bytes = EpubGenerator().generate();
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: fileName,
  );
  debugPrint('[$logPrefix] Imported test EPUB as book key=$bookKey');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookKey;
}
