import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/media.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 顶栏标题槽「书名 · 章名」的真 app 探针（用户 2026-09-16 要求：阅读的标题后面
/// 加当前章名）。
///
/// 单测（`test/reader/reader_desktop_chrome_test.dart`）只钉住 [ReaderDesktopHeader]
/// 自己的排版契约——传进去的两段怎么画。这里量的是另外两件单测够不着的事：
///  1. 装配：阅读器真的把**当前章的 TOC 标签**喂进了标题槽（不是章号、不是空串）；
///  2. 时序：翻到下一章后标题槽跟着换（`_currentChapter` 改写与 `_rebuild` 同步
///     发生在 `_navigateToChapter` 里，这条量的是那个不变式真的成立）。
///
/// 种的测试书（[EpubGenerator]）带真 NCX 目录，逐章 navLabel 各不相同，所以
/// 「章名变了」不会被相同文案伪装成通过。
///
/// Run（Windows 离屏 harness）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_header_chapter_label_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const Key headerKey = ValueKey<String>('fushi_desktop_header');
  const Key titleKey = ValueKey<String>('fushi_desktop_header_title');
  const Key chapterKey = ValueKey<String>('fushi_desktop_header_chapter');

  testWidgets('顶栏标题槽画出「书名 · 当前章名」，翻章后章名跟着换',
      timeout: const Timeout(Duration(minutes: 8)),
      (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
    await tester.pump(const Duration(seconds: 2));

    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);
    await _openBooksTab(tester, driver);
    final String bookKey = await _seedTestBook(tester);
    await _activateBook(tester, bookKey);

    for (int i = 0;
        i < 40 && find.byType(ReaderFushiPage).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(ReaderFushiPage), findsOneWidget,
        reason: 'ReaderFushiPage must mount after openMedia');

    const Key contentReadyKey = ValueKey<String>('fushi_content_ready');
    bool contentReady = false;
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
        contentReady = true;
        break;
      }
    }
    expect(contentReady, isTrue, reason: 'Reader content ready within 90s');

    final eval = ReaderFushiPage.debugEvaluateJavascript;
    expect(eval, isNotNull, reason: 'Reader debug JS hook must be set');

    // 悬浮顶栏 3s 自动收起：每次读数前走真 JS 桥的 onTapEmpty 重新唤出（与用户
    // 点空白同一入口），否则读到的是「没画」而不是「画错」。
    Future<bool> revealHeader() async {
      for (int attempt = 0; attempt < 4; attempt++) {
        await eval!(
          'setTimeout(function(){window.flutter_inappwebview.callHandler('
          "'onTapEmpty');},0)",
        );
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byKey(headerKey).evaluate().isNotEmpty) return true;
        }
      }
      return false;
    }

    String? textOf(Key key) {
      final Iterable<Element> found = find.byKey(key).evaluate();
      if (found.isEmpty) return null;
      return (found.first.widget as Text).data;
    }

    expect(await revealHeader(), isTrue, reason: 'onTapEmpty 必须唤出顶栏');
    final String? bookTitle = textOf(titleKey);
    final String? firstChapter = textOf(chapterKey);
    debugPrint('[HDRCHP] 开书首屏 title=$bookTitle chapter=$firstChapter');
    expect(bookTitle, isNotNull, reason: '书名槽必须在场');
    expect(firstChapter, isNotNull, reason: '章名槽必须在场——没在场说明 chapter 根本没接上顶栏');
    expect(firstChapter!.trim(), isNotEmpty);
    expect(firstChapter, isNot(bookTitle));
    final ObserveShot before =
        await captureFlutterFrame(tester, 'header-chapter-01-first');
    expect(before.saved, isTrue);

    // 真用户路径翻页（PageDown = readerPageForward 默认绑定），翻到章尾自然跨章。
    String? nextChapter;
    for (int turn = 0; turn < 60; turn++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 400));
      final String? now = textOf(chapterKey);
      if (now != null && now != firstChapter) {
        nextChapter = now;
        debugPrint('[HDRCHP] 第 $turn 次翻页后换章 chapter=$now');
        break;
      }
    }
    if (nextChapter == null) {
      // 顶栏可能在翻页途中收起了：重新唤出再读一次，别把「没画」当成「没换章」。
      expect(await revealHeader(), isTrue, reason: '翻页后顶栏必须还能唤出');
      final String? now = textOf(chapterKey);
      if (now != null && now != firstChapter) nextChapter = now;
    }
    debugPrint('[HDRCHP] 翻章后 title=${textOf(titleKey)} chapter=$nextChapter');
    expect(nextChapter, isNotNull, reason: '跨章后标题槽的章名必须跟着换（60 次翻页内应已跨章）');
    expect(textOf(titleKey), bookTitle, reason: '书名不随章变');
    final ObserveShot after =
        await captureFlutterFrame(tester, 'header-chapter-02-next');
    expect(after.saved, isTrue);
  });
}

Future<void> _openBooksTab(WidgetTester tester, FocusDriver driver) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<String> _seedTestBook(WidgetTester tester) async {
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
    fileName: 'test_header_chapter_label.epub',
  );
  container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
  await tester.pumpAndSettle();
  return bookKey;
}

Future<void> _activateBook(WidgetTester tester, String bookKey) async {
  final BuildContext appContext =
      tester.element(find.byType(MaterialApp).first);
  final ProviderContainer container = ProviderScope.containerOf(appContext);
  final AppModel appModel = container.read(appProvider);
  final ConsumerStatefulElement appElement = tester
      .element(find.byType(app.FushiReaderApp)) as ConsumerStatefulElement;
  final WidgetRef ref = appElement;

  final MediaItem? item =
      await ReaderFushiSource.instance.mediaItemForBookKey(bookKey);
  expect(item, isNotNull,
      reason: 'Seeded book must resolve to a MediaItem (key=$bookKey)');

  unawaited(appModel.openMedia(
    ref: ref,
    mediaSource: ReaderFushiSource.instance,
    item: item!,
  ));
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
