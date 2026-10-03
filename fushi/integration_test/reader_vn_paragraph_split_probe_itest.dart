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

/// BUG-2905 真书探针：VN 模式同一段落被切成两屏。
///
/// 用户报 iOS 竖排 VN 下「そう思ったのは俺だけではないらしく」独占一屏、下一屏以
/// 「、庇護欲を…」开头。根因是 WebKit 的悬挂标点：行尾「、」悬出列底，VN 屏盒在那条
/// 边上裁切，切屏量尺判溢出，于是一屏装得下的段落被切在「、」前。本探针走真 app 的
/// 生产导入与开书路径：导入 `FUSHI_PROBE_EPUB`、竖排、字号 `FUSHI_PROBE_FONT_SIZE`
/// （缺省 40），在含 `FUSHI_PROBE_NEEDLE` 的章以 VN 模式开书，逐屏渲染并检查：
///   1. 没有任何一屏以行首禁则字（、。」！ゃー…）开头（同段被切在禁则处）；
///   2. 没有任何一屏有正文落在 `.fushi-vn-screen` 盒外（±4px）；
///   3. 逐屏拼回的文本与整章源文一致；
///   4. needle 所在段（`FUSHI_PROBE_NEEDLE_TAIL` 是该段末尾）落在同一屏。
/// 再以翻页 / 滚动模式开同一章，记录正文 `hanging-punctuation` 计算值（确认只在 VN
/// 关掉，其它两种模式不受影响）。给了 `FUSHI_PROBE_OUT` 就把 needle 屏截图复制到那里。
///
/// Run（Windows 离屏，fushi/ 下）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///     integration_test/reader_vn_paragraph_split_probe_itest.dart \
///     -DartDefine @('FUSHI_PROBE_EPUB=D:/book.epub','FUSHI_PROBE_NEEDLE=…')
/// Run（macOS，fushi/ 下）：
///   flutter test integration_test/reader_vn_paragraph_split_probe_itest.dart -d macos \
///     --dart-define=FUSHI_PROBE_EPUB=/abs/book.epub --dart-define=FUSHI_PROBE_NEEDLE=…

const String _epubPath = String.fromEnvironment('FUSHI_PROBE_EPUB');
const String _needle = String.fromEnvironment('FUSHI_PROBE_NEEDLE');
const String _needleTail = String.fromEnvironment('FUSHI_PROBE_NEEDLE_TAIL');
const String _outDir = String.fromEnvironment('FUSHI_PROBE_OUT');
const String _fontSize = String.fromEnvironment(
  'FUSHI_PROBE_FONT_SIZE',
  defaultValue: '40',
);

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
    if (ready()) return;
  }
  fail(
    '$label did not become ready within '
    '${maxPolls * step.inMilliseconds}ms',
  );
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
  await _waitFor(
    tester,
    readerWebViewReady,
    'reader debug hooks',
    maxPolls: 20,
  );
  // 度量脚本在 rAF / 字体就绪后写变量；给它和版面几秒稳定下来。
  await tester.pump(const Duration(seconds: 3));
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  final NavigatorState nav = Navigator.of(
    tester.element(find.byType(ReaderFushiPage)),
  );
  nav.pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

Future<Map<String, dynamic>> _eval(String js) async {
  final Future<dynamic> Function(String)? runJs =
      ReaderFushiPage.debugEvaluateJavascript;
  expect(runJs, isNotNull);
  final Object? raw = await runJs!(js);
  return raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
}

Future<void> _pinSection(AppModel appModel, String bookUid, int section) =>
    appModel.database.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value<String>(bookUid),
        sectionIndex: Value<int>(section),
        normCharOffset: const Value<int>(0),
        charOffset: const Value<int>(-1),
        updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );

const String _lineStartProhibited =
    '、。，．,.・：；:;？！?!‼⁇⁈⁉゛゜ヽヾゝゞ々〻ー－‐゠–〜～'
    '」』）〕］｝〉》】〙〗〟’”｠»)]}'
    'ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ…‥';

String _vnScanJs(String needle, String tail) =>
    '''
(function () {
  var r = window.fushiReader;
  if (!r || !r.screens || !r.screen || !r.renderScreen) {
    return JSON.stringify({ vn: false });
  }
  var prohibited = ${jsonEncode(_lineStartProhibited)};
  var needle = ${jsonEncode(needle)};
  var tail = ${jsonEncode(tail)};
  var strip = function (s) { return String(s || '').replace(/\\s+/g, ''); };
  var textOf = function (root) {
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        return (n.parentElement && n.parentElement.closest('rt,rp'))
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    var s = ''; var n;
    while ((n = w.nextNode())) s += n.nodeValue;
    return strip(s);
  };
  var source = textOf(r.sourceRoot);
  // 段首偏移：同段被切开才算违例，新段落本来就可以以「……」「」」开头。
  var blockOf = function (n) {
    var el = n.parentElement;
    while (el && el !== r.sourceRoot) {
      if (/^(P|DIV|H[1-6]|LI|BLOCKQUOTE|DT|DD|FIGCAPTION|TD|TH)\$/.test(el.tagName)) return el;
      el = el.parentElement;
    }
    return null;
  };
  var paragraphStarts = {};
  var sw = document.createTreeWalker(r.sourceRoot, NodeFilter.SHOW_TEXT, {
    acceptNode: function (n) {
      return (n.parentElement && n.parentElement.closest('rt,rp'))
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
    }
  });
  var seen = 0; var lastBlock; var sn;
  while ((sn = sw.nextNode())) {
    var piece = strip(sn.nodeValue);
    if (!piece) continue;
    var blk = blockOf(sn);
    if (blk !== lastBlock) { paragraphStarts[seen] = true; lastBlock = blk; }
    seen += piece.length;
  }
  var cursor = 0;
  var discontiguous = [];
  var original = r.currentScreenIndex;
  var joined = '';
  var badStart = [];
  var overflow = [];
  var needleScreen = -1;
  var tailScreen = -1;
  var needleText = '';
  for (var i = 0; i < r.screens.length; i++) {
    r.renderScreen(i, true);
    var t = textOf(r.screen);
    joined += t;
    var at = t ? source.indexOf(t, cursor) : cursor;
    if (at < 0) {
      discontiguous.push(i + ':' + t.slice(0, 10));
    } else {
      if (i > 0 && t && !paragraphStarts[at] &&
          prohibited.indexOf(Array.from(t)[0]) >= 0) {
        badStart.push(i + ':' + t.slice(0, 10));
      }
      cursor = at + t.length;
    }
    var box = r.screen.getBoundingClientRect();
    var walker = document.createTreeWalker(r.screen, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var node;
    while ((node = walker.nextNode())) {
      if (!node.nodeValue.trim()) continue;
      if (node.parentElement && node.parentElement.closest('rt,rp')) continue;
      // 逐字判：行尾空白按规范悬挂出行盒，不可见，不算正文越界。
      var value = node.nodeValue;
      var out = '';
      for (var c = 0; c < value.length && !out; c++) {
        if (/\\s/.test(value[c])) continue;
        range.setStart(node, c);
        range.setEnd(node, c + 1);
        var rects = range.getClientRects();
        for (var k = 0; k < rects.length; k++) {
          var q = rects[k];
          if (!q.width && !q.height) continue;
          if (q.left < box.left - 4 || q.right > box.right + 4 ||
              q.top < box.top - 4 || q.bottom > box.bottom + 4) { out = value[c]; break; }
        }
      }
      if (out) { overflow.push(i + ':' + out + ':' + value.slice(0, 8)); break; }
    }
    if (needleScreen < 0 && t.indexOf(needle) >= 0) {
      needleScreen = i; needleText = t;
    }
    if (tailScreen < 0 && tail && t.indexOf(tail) >= 0) tailScreen = i;
  }
  var content = r.screen.querySelector('.fushi-vn-content') || r.screen;
  var hp = getComputedStyle(content).getPropertyValue('hanging-punctuation');
  r.renderScreen(needleScreen >= 0 ? needleScreen : original, true);
  var box2 = r.screen.getBoundingClientRect();
  return JSON.stringify({
    vn: true, screens: r.screens.length, badStart: badStart,
    overflow: overflow, discontiguous: discontiguous,
    joinedOk: joined === source,
    joinedLen: joined.length, sourceLen: source.length,
    needleScreen: needleScreen, tailScreen: tailScreen,
    needleText: needleText.slice(0, 80), hanging: hp,
    box: Math.round(box2.width) + 'x' + Math.round(box2.height),
    inner: innerWidth + 'x' + innerHeight
  });
})()
''';

String _flowHangingJs(String needle) =>
    '''
(function () {
  var needle = ${jsonEncode(needle)};
  var ps = document.body.querySelectorAll('p');
  for (var i = 0; i < ps.length; i++) {
    if ((ps[i].textContent || '').indexOf(needle) >= 0) {
      return JSON.stringify({ found: true,
        hanging: getComputedStyle(ps[i]).getPropertyValue('hanging-punctuation') });
    }
  }
  return JSON.stringify({ found: false,
    hanging: getComputedStyle(document.body).getPropertyValue('hanging-punctuation') });
})()
''';

Future<void> _saveShot(String name) async {
  final ObserveShot shot = await captureReaderWebView(name);
  debugPrint(
    '[vn-split] shot $name saved=${shot.saved} '
    'nonBlank=${shot.nonBlank} path=${shot.path}',
  );
  if (_outDir.isEmpty || !shot.saved) return;
  try {
    Directory(_outDir).createSync(recursive: true);
    File(shot.path).copySync('$_outDir/$name.png');
  } on FileSystemException catch (e) {
    debugPrint('[vn-split] copy $name to $_outDir failed: $e');
  }
}

List<dynamic> _list(Object? value) =>
    value is List<dynamic> ? value : <dynamic>[];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2905 real-book probe: VN never splits a paragraph before a '
    'line-start-prohibited char and keeps a fitting paragraph on one screen',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      expect(
        _epubPath,
        isNotEmpty,
        reason: 'pass --dart-define=FUSHI_PROBE_EPUB=<path to epub>',
      );
      expect(
        _needle,
        isNotEmpty,
        reason: 'pass --dart-define=FUSHI_PROBE_NEEDLE=<text>',
      );
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'vn-split',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home (nav bar) must render',
          );
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final double originalFontSize = source.readerFontSize;
          final List<String> failures = <String>[];
          try {
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderFontSize(double.parse(_fontSize));
            await _pumpForPref(tester);

            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            final EpubBookRow? row = await appModel.database.getEpubBook(
              bookKey,
            );
            expect(row, isNotNull);
            final List<dynamic> chapters =
                jsonDecode(row!.chaptersJson) as List<dynamic>;
            int needleSection = -1;
            for (int i = 0; i < chapters.length; i++) {
              final String href =
                  (chapters[i] as Map<String, dynamic>)['href'] as String;
              final File f = File(
                '${row.extractDir}${Platform.pathSeparator}$href',
              );
              if (f.existsSync() && f.readAsStringSync().contains(_needle)) {
                needleSection = i;
                break;
              }
            }
            expect(
              needleSection,
              greaterThanOrEqualTo(0),
              reason: 'needle not found in any chapter',
            );

            await source.setReaderViewMode('vn');
            await _pumpForPref(tester);
            await _pinSection(appModel, row.uid, needleSection);
            await _openBook(tester, bookKey);
            final Map<String, dynamic> vn = await _eval(
              _vnScanJs(_needle, _needleTail),
            );
            debugPrint('[vn-split] vn=${jsonEncode(vn)}');
            await tester.pump(const Duration(seconds: 1));
            await _saveShot('vn-split-needle');
            await _closeReader(tester);
            if (vn['vn'] != true) failures.add('VN stage not built');
            if (_list(vn['badStart']).isNotEmpty) {
              failures.add(
                'screens start with a prohibited char: ${vn['badStart']}',
              );
            }
            if (_list(vn['overflow']).isNotEmpty) {
              failures.add('text outside the screen box: ${vn['overflow']}');
            }
            // 拼接全等只记录不判：章里不进屏的节点（标题图片的替代文字等）
            // 会让它在修复前后都不等；逐屏「按序出现在源文里」才是切屏不错序丢字的判据。
            if (_list(vn['discontiguous']).isNotEmpty) {
              failures.add(
                'screens out of order / not in the chapter text: '
                '${vn['discontiguous']}',
              );
            }
            if (((vn['needleScreen'] as num?) ?? -1) < 0) {
              failures.add('needle screen not found');
            }
            if (_needleTail.isNotEmpty &&
                vn['tailScreen'] != vn['needleScreen']) {
              failures.add(
                'needle paragraph split across screens '
                '${vn['needleScreen']} / ${vn['tailScreen']}',
              );
            }

            for (final String mode in <String>['paginated', 'continuous']) {
              await source.setReaderViewMode(mode);
              await _pumpForPref(tester);
              await _pinSection(appModel, row.uid, needleSection);
              await _openBook(tester, bookKey);
              final Map<String, dynamic> flow = await _eval(
                _flowHangingJs(_needle),
              );
              debugPrint('[vn-split] mode=$mode ${jsonEncode(flow)}');
              await _closeReader(tester);
            }
            debugPrint(
              '[vn-split] FAILURES ${failures.length}\n${failures.join('\n')}',
            );
            expect(failures, isEmpty);
          } finally {
            await _closeReader(tester);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderFontSize(originalFontSize);
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
