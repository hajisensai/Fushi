import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真书版振假名行盒探针（跨引擎：Blink 基线 / WebKit 复现）。
///
/// 合成素材探针（`reader_ruby_line_box_probe_itest.dart`）在 macOS WebKit 上四轮
/// （横/竖 × 22/43）delta 全 0，复现不了用户报的「带振假名的行更高」。本探针改用
/// **用户的真书**（EPUB 路径经 `--dart-define=FUSHI_PROBE_EPUB=...` 传入）：
///
///  1. 用生产导入路径导入该 EPUB，解压树里逐章数 `<rt`，把阅读位置钉到注音最多的
///     那一章（`upsertReaderPosition`，阅读器开书按保存位置恢复章节）；
///  2. 竖排 / 横排 × 字号 22 / 46（用户 Mac 上的真实字号 46）四轮开书，JS 对正文
///     每个块级元素逐字符 `Range.getClientRects()` 聚类成行（横排按 top、竖排按
///     left），每行标记「是否含 ruby 字符」，相邻行行距按「两行都不含 ruby」/
///     「至少一行含 ruby」分桶取中位数，输出
///     `[ruby-realbook] engine=<UA> pass=<h22|h46|v22|v46> plain=<px> ruby=<px> delta=<px>`
///     以及每行的 hasRuby / pitch 明细（前 40 行）；
///  3. 每轮抓一张 WebView 截图 `observe-rb-<pass>-webview.png`。
///
/// 断言只做「探针跑通、量到数值」，不断言引擎结论。偏好在 `finally` 还原。
///
/// Run on Windows（fushi/ 下）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///     integration_test/reader_ruby_line_box_realbook_itest.dart \
///     -DartDefine FUSHI_PROBE_EPUB=D:/path/to/book.epub
/// Run on the Mac（ssh 到 Mac，fushi/ 下）：
///   FUSHI_TEST_HIDDEN=1 flutter test integration_test/reader_ruby_line_box_realbook_itest.dart \
///     -d macos --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root \
///     --dart-define=FUSHI_PROBE_EPUB=$HOME/dev/probe-books/book.epub

const String _epubPath = String.fromEnvironment('FUSHI_PROBE_EPUB');

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) {
      debugPrint(
          '[ruby-realbook] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail('$label did not become ready within '
      '${maxPolls * step.inMilliseconds}ms');
}

Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _openBook(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, 'reader WebView');
  await _waitFor(tester, _contentReady, 'reader content', maxPolls: 240);
  await _waitFor(tester, readerWebViewReady, 'reader debug hooks',
      maxPolls: 20);
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  final NavigatorState nav =
      Navigator.of(tester.element(find.byType(ReaderFushiPage)));
  nav.pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

/// 逐章数 `<rt`（解压树 + chaptersJson 的 href），返回注音最多的章下标。
Future<int> _sectionWithMostRuby(EpubBookRow book) async {
  final List<dynamic> chapters = jsonDecode(book.chaptersJson) as List<dynamic>;
  int best = 0;
  int bestCount = -1;
  for (int i = 0; i < chapters.length; i++) {
    final String href = (chapters[i] as Map<String, dynamic>)['href'] as String;
    final File f = File('${book.extractDir}${Platform.pathSeparator}$href');
    int count = 0;
    if (f.existsSync()) {
      final String html = f.readAsStringSync();
      count = '<rt'.allMatches(html).length;
    }
    debugPrint('[ruby-realbook] section $i href=$href rt=$count');
    if (count > bestCount) {
      bestCount = count;
      best = i;
    }
  }
  debugPrint('[ruby-realbook] pinned section=$best (rt=$bestCount)');
  return best;
}

const String _measureJs = r'''
(function () {
  function median(a) {
    if (!a.length) return 0;
    var s = a.slice().sort(function (x, y) { return x - y; });
    var m = s.length >> 1;
    return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
  }
  function ua() {
    var u = navigator.userAgent || '';
    var m;
    if ((m = /Chrome\/([\d.]+)/.exec(u))) return 'Blink Chrome/' + m[1];
    if ((m = /AppleWebKit\/([\d.]+)/.exec(u))) return 'WebKit AppleWebKit/' + m[1];
    return u.slice(0, 60);
  }
  var bodyCs = getComputedStyle(document.body);
  var fontSize = parseFloat(bodyCs.fontSize) || 16;
  var vertical = /^vertical/.test(bodyCs.writingMode || '');
  var out = { engine: ua(), bodyFontSize: bodyCs.fontSize, bodyLineHeight: bodyCs.lineHeight,
              bodyWritingMode: bodyCs.writingMode, blocks: 0, lines: [] };
  var firstRt = document.querySelector('rt');
  if (firstRt) {
    var rc = getComputedStyle(firstRt);
    out.rtCss = { display: rc.display, fontSize: rc.fontSize, lineHeight: rc.lineHeight };
    var ru = getComputedStyle(firstRt.parentNode);
    out.rubyCss = { display: ru.display, lineHeight: ru.lineHeight,
                    rubyPosition: ru.rubyPosition || ru.webkitRubyPosition || '' };
  }
  out.rubyCount = document.querySelectorAll('ruby').length;
  var blocks = document.querySelectorAll('p, div, li, h1, h2, h3');
  var plainPitches = [], rubyPitches = [];
  var plainExtras = [], rubyExtras = [], firstRubyExtras = [];
  var detail = [];
  for (var i = 0; i < blocks.length; i++) {
    var p = blocks[i];
    // 只取叶子块（不含子块级元素），避免同一文本被父块重复量。
    if (p.querySelector('p, div, li, h1, h2, h3')) continue;
    var walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var e = n.parentNode;
        while (e && e !== p) {
          var t = e.tagName;
          if (t === 'RT' || t === 'RP' || t === 'RTC') return NodeFilter.FILTER_REJECT;
          e = e.parentNode;
        }
        return n.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    var lines = [];
    var node;
    while ((node = walker.nextNode())) {
      var inRuby = !!(node.parentNode && node.parentNode.closest && node.parentNode.closest('ruby'));
      var len = node.textContent.length;
      for (var k = 0; k < len; k++) {
        if (!node.textContent[k].trim()) continue;
        var r = document.createRange();
        r.setStart(node, k); r.setEnd(node, k + 1);
        var rects = r.getClientRects();
        if (!rects.length) continue;
        var cr = rects[0];
        if (cr.width <= 0 || cr.height <= 0) continue;
        var found = null;
        for (var L = 0; L < lines.length; L++) {
          var same = vertical
            ? (Math.abs(lines[L].left - cr.left) <= 2)
            : (Math.abs(lines[L].top - cr.top) <= 2);
          if (same) { found = lines[L]; break; }
        }
        if (found) {
          found.top = Math.min(found.top, cr.top); found.bottom = Math.max(found.bottom, cr.bottom);
          found.left = Math.min(found.left, cr.left); found.right = Math.max(found.right, cr.right);
          found.chars++; if (inRuby) found.ruby++;
        } else {
          lines.push({ top: cr.top, bottom: cr.bottom, left: cr.left, right: cr.right, chars: 1, ruby: inRuby ? 1 : 0 });
        }
      }
    }
    if (lines.length < 2) continue;
    out.blocks++;
    // 段落块轴尺寸 − 行数×本段行距中位数 = 段落多出的空间（首行被注音撑高会落在这里）。
    (function () {
      var ps = [];
      for (var q = 1; q < lines.length; q++) {
        var dq = vertical ? (lines[q - 1].left - lines[q].left) : (lines[q].top - lines[q - 1].top);
        if (dq > 0 && dq < fontSize * 4) ps.push(dq);
      }
      if (!ps.length) return;
      var pr = p.getBoundingClientRect();
      var blockSize = vertical ? pr.width : pr.height;
      var extra = blockSize - lines.length * median(ps);
      var hasRuby = lines.some(function (l) { return l.ruby > 0; });
      var firstRuby = lines[0].ruby > 0;
      (hasRuby ? rubyExtras : plainExtras).push(extra);
      if (firstRuby) firstRubyExtras.push(extra);
    })();
    for (var L2 = 1; L2 < lines.length; L2++) {
      var a = lines[L2 - 1], b = lines[L2];
      var d = vertical ? (a.left - b.left) : (b.top - a.top);
      if (!(d > 0 && d < fontSize * 4)) continue;
      var anyRuby = a.ruby > 0 || b.ruby > 0;
      (anyRuby ? rubyPitches : plainPitches).push(d);
      if (detail.length < 40) {
        detail.push({ block: i, pitch: Math.round(d * 100) / 100, aRuby: a.ruby, bRuby: b.ruby,
                      aChars: a.chars, bChars: b.chars });
      }
    }
  }
  out.plain = Math.round(median(plainPitches) * 100) / 100;
  out.ruby = Math.round(median(rubyPitches) * 100) / 100;
  out.plainN = plainPitches.length; out.rubyN = rubyPitches.length;
  out.plainMax = Math.round(Math.max.apply(null, plainPitches.concat([0])) * 100) / 100;
  out.rubyMax = Math.round(Math.max.apply(null, rubyPitches.concat([0])) * 100) / 100;
  out.delta = Math.round((out.ruby - out.plain) * 100) / 100;
  out.plainExtra = Math.round(median(plainExtras) * 100) / 100;
  out.rubyExtra = Math.round(median(rubyExtras) * 100) / 100;
  out.firstRubyExtra = Math.round(median(firstRubyExtras) * 100) / 100;
  out.plainExtraN = plainExtras.length; out.rubyExtraN = rubyExtras.length;
  out.firstRubyExtraN = firstRubyExtras.length;
  out.lines = detail;
  return JSON.stringify(out);
})()
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real-book ruby line-box probe: plain vs ruby-adjacent line pitch on the '
    'user\'s EPUB across writing modes and font sizes (engine-tagged)',
    timeout: const Timeout(Duration(minutes: 25)),
    (WidgetTester tester) async {
      expect(_epubPath, isNotEmpty,
          reason: 'pass --dart-define=FUSHI_PROBE_EPUB=<path to epub>');
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'ruby-realbook',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalMode = source.readerFuriganaMode;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final double originalLineHeight = source.readerLineHeight;
          final double originalFontSize = source.readerFontSize;
          debugPrint('[ruby-realbook] original prefs: furigana_mode='
              '$originalMode writing_mode=$originalWritingMode '
              'view_mode=$originalViewMode line_height=$originalLineHeight '
              'font_size=$originalFontSize');

          try {
            await source.setReaderViewMode('paginated');
            await source.setReaderFuriganaMode('off');
            await source.setReaderLineHeight(1.65);
            await _pumpForPref(tester);

            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            debugPrint('[ruby-realbook] imported key=$bookKey');
            final EpubBookRow? row =
                await appModel.database.getEpubBook(bookKey);
            expect(row, isNotNull);
            final int section = await _sectionWithMostRuby(row!);
            await appModel.database.upsertReaderPosition(
              ReaderPositionsCompanion(
                bookUid: Value<String>(row.uid),
                sectionIndex: Value<int>(section),
                normCharOffset: const Value<int>(0),
                charOffset: const Value<int>(-1),
                updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
              ),
            );
            await tester.pump(const Duration(seconds: 1));

            final List<String> summary = <String>[];
            for (final String wm in <String>['vertical-rl', 'horizontal-tb']) {
              for (final double fs in <double>[46, 22]) {
                final String pass =
                    '${wm == 'vertical-rl' ? 'v' : 'h'}${fs.round()}';
                await source.setReaderWritingMode(wm);
                await source.setReaderFontSize(fs);
                await _pumpForPref(tester);
                await _openBook(tester, bookKey);
                await tester.pump(const Duration(seconds: 3));

                final Future<dynamic> Function(String)? runJs =
                    ReaderFushiPage.debugEvaluateJavascript;
                expect(runJs, isNotNull);
                final Map<String, dynamic> r =
                    jsonDecode((await runJs!(_measureJs)) as String)
                        as Map<String, dynamic>;
                final String line = '[ruby-realbook] engine=${r['engine']} '
                    'pass=$pass plain=${r['plain']} (n=${r['plainN']}, '
                    'max=${r['plainMax']}) ruby=${r['ruby']} (n=${r['rubyN']}, '
                    'max=${r['rubyMax']}) delta=${r['delta']} '
                    'blocks=${r['blocks']} rubies=${r['rubyCount']} '
                    'blockExtra plain=${r['plainExtra']} (n=${r['plainExtraN']}) '
                    'ruby=${r['rubyExtra']} (n=${r['rubyExtraN']}) '
                    'firstLineRuby=${r['firstRubyExtra']} '
                    '(n=${r['firstRubyExtraN']})';
                debugPrint(line);
                summary.add(line);
                debugPrint('[ruby-realbook]   body font=${r['bodyFontSize']} '
                    'lineHeight=${r['bodyLineHeight']} '
                    'writingMode=${r['bodyWritingMode']} rt=${r['rtCss']} '
                    'ruby=${r['rubyCss']}');
                for (final dynamic d in r['lines'] as List<dynamic>) {
                  debugPrint('[ruby-realbook]   $d');
                }
                final ObserveShot web =
                    await captureReaderWebView('observe-rb-$pass-webview');
                debugPrint('[ruby-realbook]   webview $pass saved=${web.saved} '
                    'nonBlank=${web.nonBlank} path=${web.path}');
                expect(
                    (r['plainN'] as num) + (r['rubyN'] as num), greaterThan(0),
                    reason: 'pass $pass must measure some line pitches');
                await _closeReader(tester);
              }
            }
            debugPrint('[ruby-realbook] SUMMARY\n${summary.join('\n')}');
          } finally {
            await _closeReader(tester);
            await source.setReaderFuriganaMode(originalMode);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderLineHeight(originalLineHeight);
            await source.setReaderFontSize(originalFontSize);
            await _pumpForPref(tester);
            debugPrint('[ruby-realbook] restored prefs');
          }
        },
      );
    },
  );
}
