import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
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

/// BUG-2819 真书探针：Mac / iOS 分页每章最后一页（翻回上一章落到的那一页）整体错开
/// 一个页边距、满行末字被切掉。
///
/// WebKit 的滚动范围不含多列 body 行内方向末端的 padding，末页对齐位置够不着，只能
/// 停在物理终点。本探针走真 app 的生产导入与开书路径：把阅读位置钉到章末
/// （`normCharOffset` 9999，开书按进度 ≥ 0.99 落到末页，与「往前翻进上一章」同一条
/// 恢复路径），翻页 / 连续 / VN × 横排 / 竖排各开一次，量：
///  - 分页：当前滚动位置对页步长的余数（对齐时为 0）、物理终点与末页对齐位置；
///  - 三种模式：当前视口里与正文内容框相交、却越出内容框行内方向的文字矩形数
///    （被 clip-path 切掉的行尾 / 列尾）。
///
/// 判据（全部量完、打印 SUMMARY 后才断言）：分页落点在页网格上（±1px），且三种模式
/// 都没有越出内容框的文字。偏好在 `finally` 还原。
///
/// Run（Mac，fushi/ 下）：
///   flutter test integration_test/reader_chapter_end_page_align_probe_itest.dart \
///     -d macos --no-pub --dart-define=FUSHI_TEST_ROOT=<隔离根> \
///     --dart-define=FUSHI_PROBE_EPUB=/abs/book.epub \
///     --dart-define=FUSHI_PROBE_NEEDLE=冷蔵庫を開け
/// iOS 模拟器把 `-d macos` 换成 `-d <udid>`（不带隔离根）。

const String _epubPath = String.fromEnvironment('FUSHI_PROBE_EPUB');
const String _needle = String.fromEnvironment('FUSHI_PROBE_NEEDLE');
const String _outDir = String.fromEnvironment('FUSHI_PROBE_OUT');
const String _fontSize =
    String.fromEnvironment('FUSHI_PROBE_FONT_SIZE', defaultValue: '42');
const String _margin =
    String.fromEnvironment('FUSHI_PROBE_MARGIN', defaultValue: '5');

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
  // 恢复落页、字体与度量在首帧之后还会动一两次；给版面几秒稳定下来。
  await tester.pump(const Duration(seconds: 3));
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  final NavigatorState nav =
      Navigator.of(tester.element(find.byType(ReaderFushiPage)));
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

Future<void> _pinChapterEnd(AppModel appModel, String bookUid, int section) =>
    appModel.database.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value<String>(bookUid),
        sectionIndex: Value<int>(section),
        normCharOffset: const Value<int>(9999),
        charOffset: const Value<int>(-1),
        updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );

/// 当前页 / 视口：文字是否越出正文内容框（行内方向），分页时还量页网格对齐。
String _measureJs({required bool paged}) => '(function (paged) {'
    r'''
  var r = window.fushiReader;
  var b = document.body;
  var vn = !!(r && r.screens && r.screen);
  var box = vn ? r.screen : b;
  var cs = getComputedStyle(box);
  var vertical = getComputedStyle(b).writingMode.indexOf('vertical') === 0;
  var rect = box.getBoundingClientRect();
  // 内容框按盒子的真实位置算，不夹到视口：竖排连续模式下文档在竖直方向会偏几 px
  // （body rect.top 为负），夹到 0 会把内容框起点算错、把整列误判成被切。
  var start = vertical ? rect.top + parseFloat(cs.paddingTop)
                       : rect.left + parseFloat(cs.paddingLeft);
  var extent = vertical ? Math.min(rect.bottom, innerHeight) : Math.min(rect.right, innerWidth);
  var end = extent - (vertical ? parseFloat(cs.paddingBottom) : parseFloat(cs.paddingRight));
  var out = { vertical: vertical, start: Math.round(start), end: Math.round(end), inView: 0, clipped: 0, samples: [] };
  var w = document.createTreeWalker(box, NodeFilter.SHOW_TEXT), n, rg = document.createRange();
  while ((n = w.nextNode())) {
    if (!n.nodeValue.trim()) continue;
    if (n.parentElement && n.parentElement.closest('rt, rp')) continue;
    rg.selectNodeContents(n);
    var rs = rg.getClientRects();
    for (var i = 0; i < rs.length; i++) {
      var q = rs[i];
      if (!(q.width > 0 && q.height > 0)) continue;
      // 块方向要在视口里（翻页时相邻页的列落在行内方向的边距带里，下面排除）。
      if (vertical ? (q.right <= 0 || q.left >= innerWidth) : (q.bottom <= 0 || q.top >= innerHeight)) continue;
      var a = vertical ? q.top : q.left, z = vertical ? q.bottom : q.right;
      if (z <= start || a >= end) continue;
      out.inView++;
      if (a < start - 1 || z > end + 1) {
        out.clipped++;
        if (out.samples.length < 3) out.samples.push(n.nodeValue.trim().slice(0, 8) + '@' + Math.round(a) + '-' + Math.round(z));
      }
    }
  }
  if (paged && r && r.getScrollContext && r.buildPaginationMetrics) {
    var ctx = r.getScrollContext();
    var m = r.paginationMetrics || r.buildPaginationMetrics();
    var pos = r.getPagePosition(ctx);
    var rem = pos % ctx.pageSize;
    out.pos = Math.round(pos * 100) / 100;
    out.pageSize = Math.round(ctx.pageSize * 100) / 100;
    out.offGrid = Math.round(Math.min(rem, ctx.pageSize - rem) * 100) / 100;
    out.maxScroll = Math.round(m.maxScroll * 100) / 100;
    out.physMax = Math.round(ctx.physicalMaxScroll * 100) / 100;
    out.totalSize = vertical ? b.scrollHeight : b.scrollWidth;
  }
  return JSON.stringify(out);
})'''
    '(${paged ? 'true' : 'false'})';

Future<void> _saveShot(String name) async {
  final ObserveShot shot = await captureReaderWebView(name);
  debugPrint('[end-page] shot $name saved=${shot.saved} '
      'nonBlank=${shot.nonBlank} path=${shot.path}');
  if (_outDir.isEmpty || !shot.saved) return;
  try {
    Directory(_outDir).createSync(recursive: true);
    File(shot.path).copySync('$_outDir/$name.png');
  } on FileSystemException catch (e) {
    debugPrint('[end-page] copy $name to $_outDir failed: $e');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2819 real-book probe: the last page of a chapter lands on the page '
    'grid and no text is clipped, across paginated / continuous / VN',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      expect(_epubPath, isNotEmpty,
          reason: 'pass --dart-define=FUSHI_PROBE_EPUB=<path to epub>');
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'end-page',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final double originalFontSize = source.readerFontSize;
          final double originalMarginTop = source.readerMarginTop;
          final double originalMarginBottom = source.readerMarginBottom;
          final double originalMarginLeft = source.readerMarginLeft;
          final double originalMarginRight = source.readerMarginRight;

          final List<String> summary = <String>[];
          final List<String> failures = <String>[];
          try {
            final double margin = double.parse(_margin);
            await source.setReaderFontSize(double.parse(_fontSize));
            await source.setReaderMarginTop(margin);
            await source.setReaderMarginBottom(margin);
            await source.setReaderMarginLeft(margin);
            await source.setReaderMarginRight(margin);
            await _pumpForPref(tester);

            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            final EpubBookRow? row =
                await appModel.database.getEpubBook(bookKey);
            expect(row, isNotNull);
            final List<dynamic> chapters =
                jsonDecode(row!.chaptersJson) as List<dynamic>;
            int section = -1;
            for (int i = 0; i < chapters.length && section < 0; i++) {
              final String href =
                  (chapters[i] as Map<String, dynamic>)['href'] as String;
              final File f =
                  File('${row.extractDir}${Platform.pathSeparator}$href');
              if (f.existsSync() &&
                  _needle.isNotEmpty &&
                  f.readAsStringSync().contains(_needle)) {
                section = i;
              }
            }
            expect(section, greaterThanOrEqualTo(0),
                reason: 'no section contains FUSHI_PROBE_NEEDLE');
            debugPrint('[end-page] section=$section');

            for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
              for (final String mode in <String>[
                'paginated',
                'continuous',
                'vn',
              ]) {
                await source.setReaderWritingMode(wm);
                await source.setReaderViewMode(mode);
                await _pumpForPref(tester);
                await _pinChapterEnd(appModel, row.uid, section);
                await _openBook(tester, bookKey);
                final Map<String, dynamic> r =
                    await _eval(_measureJs(paged: mode == 'paginated'));
                final String label = '${wm == 'vertical-rl' ? 'v' : 'h'}-$mode';
                final String line = '[end-page] $label ${jsonEncode(r)}';
                debugPrint(line);
                summary.add(line);
                if ((r['inView'] as num) == 0) {
                  failures.add('$label measured no text in view');
                }
                if ((r['clipped'] as num) > 0) {
                  failures.add('$label ${r['clipped']} text runs clipped');
                }
                if (mode == 'paginated' && (r['offGrid'] as num) > 1) {
                  failures.add('$label last page off the grid by '
                      '${r['offGrid']}px');
                }
                await _saveShot('end-page-$label');
                await _closeReader(tester);
              }
            }
            debugPrint('[end-page] SUMMARY\n${summary.join('\n')}');
            debugPrint('[end-page] FAILURES ${failures.length}\n'
                '${failures.join('\n')}');
            expect(summary, isNotEmpty, reason: 'probe measured nothing');
            expect(failures, isEmpty);
          } finally {
            await _closeReader(tester);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderFontSize(originalFontSize);
            await source.setReaderMarginTop(originalMarginTop);
            await source.setReaderMarginBottom(originalMarginBottom);
            await source.setReaderMarginLeft(originalMarginLeft);
            await source.setReaderMarginRight(originalMarginRight);
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
