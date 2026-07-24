import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;

import 'helpers/reader_itest.dart';
import 'support/itest_startup_guard.dart';

/// TODO-1308 problem 2 (BUG-696) user-DOM-shape regression: favorite/nav jump
/// must land at the favorite sentence char position on a JIS mono-ruby chapter
/// (base chars in rb, furigana in rtc/rt), not the chapter start.
///
/// The user's book is rb/rtc group ruby. Synthetic chapter 8
/// (generate_test_epub.dart chapter_08_monoruby) mirrors that DOM. The existing
/// reader_favorite_jump_itest.dart only covers plain paragraphs (chapter 0) in
/// continuous mode; this test covers the rb/rtc chapter in BOTH the default
/// PAGINATED mode and continuous, vertical-rl. Same-chapter goes straight to
/// restoreToCharOffset; cross-chapter bakes charOffset into the restore chain
/// landing inside rb/rtc DOM.
///
/// Run (from hibiki/):
///   tool\run_windows_itest.ps1 integration_test\reader_favorite_jump_rtc_itest.dart
Future<int> _firstVisibleCharOffset(
  Future<dynamic> Function(String source) runJs,
) async {
  final Object? raw = await runJs(
      'window.hoshiReader ? window.hoshiReader.getFirstVisibleCharOffset() : -999;');
  final num? n = raw is num ? raw : num.tryParse(raw.toString());
  expect(n, isNotNull,
      reason: 'getFirstVisibleCharOffset must return a number');
  return n!.toInt();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

const int _kMonoRubyChapter = 7; // chapter_08_monoruby, spine index 7.

/// Verifies same-chapter + true cross-chapter favorite jumps land near the deep
/// sentence (not the chapter start) in the CURRENT view mode. The reader must
/// already be on the rb/rtc chapter when called.
Future<void> _verifyJumpInMode(
  WidgetTester tester,
  Future<dynamic> Function(String source) runJs,
  Future<void> Function(FavoriteSentence) jump,
  String bookKey,
  String mode,
) async {
  // Confirm the loaded chapter is the rb/rtc DOM shape.
  final Object? rbCountRaw =
      await runJs('document.querySelectorAll("ruby rb").length;');
  final int rbCount =
      (rbCountRaw is num ? rbCountRaw : num.tryParse('$rbCountRaw') ?? 0)
          .toInt();
  debugPrint('[favjump-rtc] [$mode] rb element count=$rbCount');
  expect(rbCount, greaterThan(50),
      reason: '[$mode] must be on the rb/rtc mono-ruby chapter '
          '(found $rbCount rb elements)');

  // Pick a deep char offset (target char is a text node inside rb). A /10000 or
  // out-of-range misread collapses to ~0 = chapter start.
  final int targetOffset = await _pickDeepCharOffset(runJs);
  expect(targetOffset, greaterThan(200),
      reason: '[$mode] need a deep sentence so a misread != target '
          '(got $targetOffset)');

  // Same-chapter jump to the deep rb/rtc offset.
  await jump(FavoriteSentence(
    text: 'x',
    bookTitle: 'todo1308',
    createdAt: DateTime.now(),
    bookKey: bookKey,
    sectionIndex: _kMonoRubyChapter,
    normCharOffset: targetOffset,
    normCharLength: 6,
  ));
  await _settle(tester);
  final int landedSame = await _firstVisibleCharOffset(runJs);
  debugPrint('[favjump-rtc] [$mode] same-chapter target=$targetOffset '
      'landed=$landedSame');
  expect(landedSame, greaterThan(targetOffset ~/ 2),
      reason: '[$mode] same-chapter favorite jump on rb/rtc must land near the '
          'sentence ($targetOffset), not the chapter start (got $landedSame)');

  // Reset the rb/rtc chapter to the top.
  await runJs('window.hoshiReader.restoreProgress(0);');
  await tester.pump(const Duration(milliseconds: 600));
  final int atTop = await _firstVisibleCharOffset(runJs);
  expect(atTop, lessThan(targetOffset ~/ 2),
      reason:
          '[$mode] reset rb/rtc chapter to top before the cross-chapter jump');

  // True cross-chapter transport: go to chapter 0 top, then jump back into the
  // rb/rtc chapter at the deep offset (exercises _navigateToChapterAndWait
  // charOffset transport into rb/rtc DOM).
  await jump(FavoriteSentence(
    text: 'x',
    bookTitle: 'todo1308',
    createdAt: DateTime.now(),
    bookKey: bookKey,
    sectionIndex: 0,
    normCharOffset: 0,
    normCharLength: 0,
  ));
  await _settle(tester);

  await jump(FavoriteSentence(
    text: 'x',
    bookTitle: 'todo1308',
    createdAt: DateTime.now(),
    bookKey: bookKey,
    sectionIndex: _kMonoRubyChapter,
    normCharOffset: targetOffset,
    normCharLength: 6,
  ));
  await _settle(tester);
  final int landedCross = await _firstVisibleCharOffset(runJs);
  debugPrint('[favjump-rtc] [$mode] cross-chapter target=$targetOffset '
      'landed=$landedCross');
  expect(landedCross, greaterThan(targetOffset ~/ 2),
      reason:
          '[$mode] cross-chapter favorite jump into the rb/rtc chapter must '
          'land near the sentence (got $landedCross), not bounce back to the '
          'chapter start');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1308 favorite jump lands at the sentence char position on a rb/rtc '
    'mono-ruby chapter (not the chapter start), vertical-rl paginated + continuous',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'favjump-rtc',
        body: () async {
          final String bookKey = await openSeededReaderBook(tester,
              fileName: 'todo1308_favjump_rtc.epub', logPrefix: 'favjump-rtc');

          final Future<dynamic> Function(String source)? runJs =
              ReaderHibikiPage.debugEvaluateJavascript;
          final Future<void> Function(FavoriteSentence)? jump =
              ReaderHibikiPage.debugJumpToFavorite;
          expect(runJs, isNotNull,
              reason: 'reader must expose debugEvaluateJavascript');
          expect(jump, isNotNull,
              reason: 'reader must expose debugJumpToFavorite');

          // Phase A: DEFAULT paginated mode (vertical-rl). The user's app default
          // is paginated, so this is the most likely real path.
          await ReaderHibikiSource.instance.setTtuWritingMode('vertical-rl');
          await ReaderHibikiSource.instance.setTtuViewMode('paginated');
          ReaderHibikiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await waitForReaderCondition(
              tester, readerContentReady, 'paginated content',
              logPrefix: 'favjump-rtc');

          // Navigate into the rb/rtc chapter (offset 0 = top).
          await jump!(FavoriteSentence(
            text: 'x',
            bookTitle: 'todo1308',
            createdAt: DateTime.now(),
            bookKey: bookKey,
            sectionIndex: _kMonoRubyChapter,
            normCharOffset: 0,
            normCharLength: 0,
          ));
          await _settle(tester);
          await waitForReaderCondition(
              tester, readerContentReady, 'paginated mono-ruby chapter',
              logPrefix: 'favjump-rtc');
          await _verifyJumpInMode(tester, runJs!, jump, bookKey, 'paginated');

          // Phase B: continuous mode (the BUG-696-documented user scenario).
          await ReaderHibikiSource.instance.setTtuViewMode('continuous');
          ReaderHibikiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await waitForReaderCondition(
              tester, readerContentReady, 'continuous content',
              logPrefix: 'favjump-rtc');

          await jump(FavoriteSentence(
            text: 'x',
            bookTitle: 'todo1308',
            createdAt: DateTime.now(),
            bookKey: bookKey,
            sectionIndex: _kMonoRubyChapter,
            normCharOffset: 0,
            normCharLength: 0,
          ));
          await _settle(tester);
          await waitForReaderCondition(
              tester, readerContentReady, 'continuous mono-ruby chapter',
              logPrefix: 'favjump-rtc');
          await _verifyJumpInMode(tester, runJs, jump, bookKey, 'continuous');
        },
      );
    },
  );
}

/// Reads the char offset of a text node roughly 65% through the current chapter
/// (using the real reader walker, which rejects furigana in rt/rp) so the target
/// is a deep, real base-char position inside an rb.
Future<int> _pickDeepCharOffset(
  Future<dynamic> Function(String source) runJs,
) async {
  const String js = r'''
(function () {
  var self = window.hoshiReader;
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
  var want = Math.floor(total * 0.65);
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
