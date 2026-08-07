import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// TODO-1308 问题②（BUG-696）真实路径验证：书内收藏面板跳转必须落在收藏句的
/// 字符位置，而不是章节开头。
///
/// 走的就是产品路径：`ReaderHibikiPage.debugJumpToFavorite` 直连
/// `_jumpToFavoriteSentence`（quick settings sheet 的 onJumpToFavorite 同一方法）。
/// 修复前该方法把绝对字符索引 /10000 当分数 → 恒落章节开头（fvco==0）。
///
/// 场景取用户口径：竖排 vertical-rl + 连续滚动。跨章与同章两条分支都断言，且落点
/// 在 settle 之后复测一次（防重锚把落点冲回章首——BUG-696 根因③的症状面）。
///
/// Run (from hibiki/):
///   tool\run_windows_itest.ps1 integration_test\reader_favorite_jump_itest.dart
bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

bool _contentReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) {
      debugPrint('[favjump] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

Future<int> _firstVisibleCharOffset(
  Future<dynamic> Function(String source) runJs,
) async {
  final Object? raw = await runJs(
      'window.fushiReader ? window.fushiReader.getFirstVisibleCharOffset() : -999;');
  final num? n = raw is num ? raw : num.tryParse(raw.toString());
  expect(n, isNotNull,
      reason: 'getFirstVisibleCharOffset must return a number');
  return n!.toInt();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1308 in-book favorite jump lands at the sentence char position '
    '(not the chapter start), vertical-rl continuous',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'favjump',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          final String bookKey =
              await seedReaderBook(tester, fileName: 'todo1308_favjump.epub');
          final FocusDriver driver = FocusDriver(tester);

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

          await _waitFor(tester, _webViewShown, 'reader WebView');
          await _waitFor(tester, _contentReady, 'hoshi content');

          await ReaderHibikiSource.instance.setReaderWritingMode('vertical-rl');
          await ReaderHibikiSource.instance.setReaderViewMode('continuous');
          ReaderHibikiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _waitFor(tester, _contentReady, 'continuous content');

          final Future<dynamic> Function(String source)? runJs =
              ReaderHibikiPage.debugEvaluateJavascript;
          final Future<void> Function(FavoriteSentence)? jump =
              ReaderHibikiPage.debugJumpToFavorite;
          expect(runJs, isNotNull,
              reason: 'reader must expose debugEvaluateJavascript');
          expect(jump, isNotNull,
              reason: 'reader must expose debugJumpToFavorite');

          // The target: a deep sentence in chapter 0 (large char offset so a
          // /10000 misread collapses to ~0 = chapter start, making the bug
          // unmistakable). We read the real char offset of a late text node so
          // the assertion is anchored to actual content, not a guess.
          final int targetOffset = await _pickDeepCharOffset(runJs!);
          expect(targetOffset, greaterThan(200),
              reason: 'need a deep sentence so /10000 misread != target');

          // 1) Same-chapter jump: reader is on chapter 0; jump to the deep
          //    offset in chapter 0.
          await jump!(FavoriteSentence(
            text: 'x',
            bookTitle: 'todo1308',
            createdAt: DateTime.now(),
            bookKey: bookKey,
            sectionIndex: 0,
            normCharOffset: targetOffset,
            normCharLength: 6,
          ));
          await tester.pump(const Duration(milliseconds: 600));
          // Re-pump past settle to catch a reanchor that could bounce us back.
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final int landedSame = await _firstVisibleCharOffset(runJs);
          debugPrint('[favjump] same-chapter target=$targetOffset '
              'landed=$landedSame');
          expect(landedSame, greaterThan(targetOffset ~/ 2),
              reason: 'same-chapter favorite jump must land near the sentence '
                  '($targetOffset), not the chapter start (got $landedSame)');

          // 2) Navigate away to chapter 0 start, then cross-chapter-style jump
          //    back to the deep offset (exercises the _navigateToChapterAndWait
          //    charOffset transport). We first scroll to the top so the landing
          //    delta is meaningful.
          await runJs('window.fushiReader.restoreProgress(0);');
          await tester.pump(const Duration(milliseconds: 600));
          final int atTop = await _firstVisibleCharOffset(runJs);
          expect(atTop, lessThan(targetOffset ~/ 2),
              reason: 'reset to chapter top before the second jump');

          await jump(FavoriteSentence(
            text: 'x',
            bookTitle: 'todo1308',
            createdAt: DateTime.now(),
            bookKey: bookKey,
            sectionIndex: 0,
            normCharOffset: targetOffset,
            normCharLength: 6,
          ));
          await tester.pump(const Duration(milliseconds: 600));
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final int landedAgain = await _firstVisibleCharOffset(runJs);
          debugPrint('[favjump] re-jump target=$targetOffset '
              'landed=$landedAgain');
          expect(landedAgain, greaterThan(targetOffset ~/ 2),
              reason:
                  'favorite jump after reset must re-land near the sentence '
                  '(got $landedAgain), not bounce back to the chapter start');
        },
      );
    },
  );
}

/// Reads the char offset of a text node roughly 70% through chapter 0 so the
/// target is a real, deep position (a /10000 misread collapses to ~0).
Future<int> _pickDeepCharOffset(
  Future<dynamic> Function(String source) runJs,
) async {
  const String js = r'''
(function () {
  var self = window.fushiReader;
  if (!self || !self.createWalker) return -1;
  var walker = self.createWalker();
  var total = 0;
  var node;
  var nodes = [];
  while ((node = walker.nextNode()) != null) {
    nodes.push({ start: total, n: node });
    total += self.countChars(node.textContent);
  }
  if (!total) return -1;
  var want = Math.floor(total * 0.7);
  for (var i = 0; i < nodes.length; i++) {
    var end = (i + 1 < nodes.length) ? nodes[i + 1].start : total;
    if (want < end) return nodes[i].start;
  }
  return nodes.length ? nodes[nodes.length - 1].start : -1;
})();
''';
  final Object? raw = await runJs(js);
  final num? n = raw is num ? raw : num.tryParse(raw.toString());
  return (n ?? -1).toInt();
}
