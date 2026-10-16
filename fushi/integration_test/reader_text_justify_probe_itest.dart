import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// BUG-3484 real-book probe: with「两端对齐」on, body paragraphs are really
/// justified (line ends flush with the column edge) in paginated / continuous /
/// VN, on a book whose own CSS never sets `text-align` on paragraphs (Standard
/// Ebooks), while elements the book explicitly aligns (centered headings) keep
/// their alignment; with the switch off nothing changes. A Japanese vertical
/// book is measured too (ruby still present, line ends flush when on).
///
/// Run (from fushi/, offscreen):
///   tool\run_windows_itest.ps1 integration_test/reader_text_justify_probe_itest.dart `
///     -DartDefine @('FUSHI_PROBE_EPUB_EN=<standardebooks epub>',
///                   'FUSHI_PROBE_NEEDLE_EN=universally',  // no spaces: the runner splits them
///                   'FUSHI_PROBE_EPUB_JA=<japanese epub>',
///                   'FUSHI_PROBE_NEEDLE_JA=<text in a body chapter>',
///                   'FUSHI_PROBE_OUT=<dir for screenshots>')
const String _epubEn = String.fromEnvironment('FUSHI_PROBE_EPUB_EN');
const String _needleEn = String.fromEnvironment('FUSHI_PROBE_NEEDLE_EN');
const String _epubJa = String.fromEnvironment('FUSHI_PROBE_EPUB_JA');
const String _needleJa = String.fromEnvironment('FUSHI_PROBE_NEEDLE_JA');
const String _outDir = String.fromEnvironment('FUSHI_PROBE_OUT');

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
  await tester.pump(const Duration(seconds: 3));
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
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

Future<void> _pinSection(
  AppModel appModel,
  String bookUid,
  int section,
  int normCharOffset,
) => appModel.database.upsertReaderPosition(
  ReaderPositionsCompanion(
    bookUid: Value<String>(bookUid),
    sectionIndex: Value<int>(section),
    normCharOffset: Value<int>(normCharOffset),
    charOffset: const Value<int>(-1),
    updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
  ),
);

/// Per visible body line: inline-axis start/end of its base text (rt/rp
/// excluded). Lines are grouped per paragraph; a paragraph's last visible line
/// is skipped (the real last line is start-aligned by design). A line is
/// "ragged" when it ends > 1.5px short of the furthest line end in the same
/// column (lines whose start lies within 2em of each other).
const String _measureJs = r'''
(function () {
  var r = window.fushiReader;
  var b = document.body;
  var vn = !!(r && r.screens && r.screen);
  var box = vn ? r.screen : b;
  var vertical = getComputedStyle(b).writingMode.indexOf('vertical') === 0;
  var fs = parseFloat(getComputedStyle(b).fontSize) || 16;
  var paras = new Map();
  var w = document.createTreeWalker(box, NodeFilter.SHOW_TEXT), n, rg = document.createRange();
  var rtVisible = 0;
  var clippedKeys = [];
  while ((n = w.nextNode())) {
    if (!n.nodeValue.trim()) continue;
    var pe = n.parentElement;
    if (pe && pe.closest('rt, rp')) {
      var rr = pe.closest('rt, rp').getBoundingClientRect();
      if (rr.width > 0 && rr.left >= 0 && rr.right <= innerWidth && rr.top >= 0 && rr.bottom <= innerHeight) rtVisible++;
      continue;
    }
    var blk = pe && pe.closest('p, div, li, blockquote, h1, h2, h3, h4, h5, h6');
    if (!blk) continue;
    rg.selectNodeContents(n);
    var rs = rg.getClientRects();
    for (var i = 0; i < rs.length; i++) {
      var q = rs[i];
      if (!(q.width > 0 && q.height > 0)) continue;
      var key = vertical ? (q.left + q.right) / 2 : (q.top + q.bottom) / 2;
      if (q.left < 0 || q.right > innerWidth || q.top < 0 || q.bottom > innerHeight) {
        // A line cut by the viewport edge (next page / column) looks short
        // but is not ragged: drop the whole line.
        if (q.right > 0 && q.left < innerWidth && q.bottom > 0 && q.top < innerHeight) clippedKeys.push({ key: key, a: vertical ? q.top : q.left });
        continue;
      }
      var a = vertical ? q.top : q.left, z = vertical ? q.bottom : q.right;
      var lines = paras.get(blk);
      if (!lines) { lines = []; paras.set(blk, lines); }
      var hit = null;
      for (var k = 0; k < lines.length; k++) {
        if (Math.abs(lines[k].key - key) < fs * 0.5) { hit = lines[k]; break; }
      }
      if (!hit) { hit = { key: key, a: a, z: z }; lines.push(hit); }
      hit.a = Math.min(hit.a, a); hit.z = Math.max(hit.z, z);
    }
  }
  var all = [];
  paras.forEach(function (lines, blk) {
    lines.sort(function (x, y) { return vertical ? y.key - x.key : x.key - y.key; });
    for (var k = 0; k < lines.length - 1; k++) {
      var cut = false;
      for (var c = 0; c < clippedKeys.length; c++) {
        // Same line, and the cut piece continues this line (not a line of
        // the next column, which starts a column gap further on).
        var ck = clippedKeys[c];
        if (Math.abs(ck.key - lines[k].key) < fs * 0.5 && ck.a <= lines[k].z + 2) cut = true;
      }
      if (cut) continue;
      all.push({ a: lines[k].a, z: lines[k].z, align: getComputedStyle(blk).textAlign });
    }
  });
  var ragged = 0, maxGap = 0, aligns = {};
  for (var i = 0; i < all.length; i++) {
    var colEnd = all[i].z;
    for (var j = 0; j < all.length; j++) {
      if (Math.abs(all[j].a - all[i].a) < fs * 2) colEnd = Math.max(colEnd, all[j].z);
    }
    var gap = colEnd - all[i].z;
    if (gap > 1.5) ragged++;
    maxGap = Math.max(maxGap, gap);
    aligns[all[i].align] = (aligns[all[i].align] || 0) + 1;
  }
  var h = document.querySelector('h1, h2, h3');
  var bcs = getComputedStyle(b);
  return JSON.stringify({
    vertical: vertical, vn: vn,
    lines: all.length, ragged: ragged, maxGap: Math.round(maxGap * 10) / 10,
    paraAligns: aligns,
    bodyAlign: bcs.textAlign,
    bodyHanging: bcs.hangingPunctuation || bcs.webkitHangingPunctuation || '',
    bodyLineBreak: bcs.lineBreak,
    headingAlign: h ? getComputedStyle(h).textAlign : null,
    rtTotal: document.querySelectorAll('rt').length,
    rtVisible: rtVisible
  });
})()''';

Future<void> _saveShot(String name) async {
  final ObserveShot shot = await captureReaderWebView(name);
  debugPrint(
    '[justify] shot $name saved=${shot.saved} '
    'nonBlank=${shot.nonBlank} path=${shot.path}',
  );
  if (_outDir.isEmpty || !shot.saved) return;
  try {
    Directory(_outDir).createSync(recursive: true);
    File(shot.path).copySync('$_outDir/$name.png');
  } on FileSystemException catch (e) {
    debugPrint('[justify] copy $name to $_outDir failed: $e');
  }
}

Future<int> _sectionContaining(
  AppModel appModel,
  String bookKey,
  String needle,
) async {
  final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
  expect(row, isNotNull);
  final List<dynamic> chapters = jsonDecode(row!.chaptersJson) as List<dynamic>;
  for (int i = 0; i < chapters.length; i++) {
    final String href = (chapters[i] as Map<String, dynamic>)['href'] as String;
    final File f = File('${row.extractDir}${Platform.pathSeparator}$href');
    if (f.existsSync() && f.readAsStringSync().contains(needle)) return i;
  }
  return -1;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-3484 real-book probe: text_justify really justifies body paragraphs '
    'across paginated / continuous / VN without touching explicit alignment',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      expect(
        _epubEn,
        isNotEmpty,
        reason: 'pass --dart-define=FUSHI_PROBE_EPUB_EN=<standardebooks epub>',
      );
      expect(File(_epubEn).existsSync(), isTrue, reason: _epubEn);

      await runFushiItest(
        label: 'justify',
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
          final bool originalJustify = source.readerEnableTextJustification;

          final List<String> summary = <String>[];
          final List<String> failures = <String>[];
          try {
            await showBooksTab(tester);
            final List<(String, String, String, String, int)> books =
                <(String, String, String, String, int)>[
                  ('en', _epubEn, _needleEn, 'horizontal-tb', 0),
                  if (_epubJa.isNotEmpty)
                    ('ja', _epubJa, _needleJa, 'vertical-rl', 0),
                ];
            for (final (
                  String lang,
                  String path,
                  String needle,
                  String wm,
                  int offset,
                )
                in books) {
              final String bookKey = await EpubImporter.import(
                db: appModel.database,
                bytes: File(path).readAsBytesSync(),
                fileName: File(path).uri.pathSegments.last,
              );
              final EpubBookRow? row = await appModel.database.getEpubBook(
                bookKey,
              );
              final int section = needle.isEmpty
                  ? 0
                  : await _sectionContaining(appModel, bookKey, needle);
              expect(section, greaterThanOrEqualTo(0), reason: needle);
              debugPrint('[justify] $lang section=$section');

              for (final String mode in <String>[
                'paginated',
                'continuous',
                'vn',
              ]) {
                for (final bool justify in <bool>[false, true]) {
                  await source.setReaderWritingMode(wm);
                  await source.setReaderViewMode(mode);
                  await source.setReaderEnableTextJustification(justify);
                  await _pumpForPref(tester);
                  await _pinSection(appModel, row!.uid, section, offset);
                  await _openBook(tester, bookKey);
                  final Map<String, dynamic> r = await _eval(_measureJs);
                  // VN shows one screen at a time (the chapter may open on an
                  // illustration or the heading): advance screens and add up
                  // the lines until enough body text was measured.
                  for (
                    int step = 0;
                    mode == 'vn' && step < 30 && (r['lines'] as num) < 6;
                    step++
                  ) {
                    await _eval(
                      "(function(){window.fushiReader.paginate('forward');"
                      "return '{}';})()",
                    );
                    await tester.pump(const Duration(milliseconds: 700));
                    final Map<String, dynamic> next = await _eval(_measureJs);
                    for (final String k in <String>['lines', 'ragged']) {
                      r[k] = (r[k] as num) + (next[k] as num);
                    }
                    r['maxGap'] = math.max(
                      (r['maxGap'] as num).toDouble(),
                      (next['maxGap'] as num).toDouble(),
                    );
                    r['rtTotal'] =
                        (r['rtTotal'] as num) + (next['rtTotal'] as num);
                    r['vnScreens'] = step + 2;
                  }
                  final String label = '$lang-$mode-${justify ? 'on' : 'off'}';
                  final String line = '[justify] $label ${jsonEncode(r)}';
                  debugPrint(line);
                  summary.add(line);
                  await _saveShot('justify-$label');
                  await _closeReader(tester);

                  final int lines = (r['lines'] as num).toInt();
                  final int ragged = (r['ragged'] as num).toInt();
                  if (lines < 3) {
                    failures.add('$label measured only $lines lines');
                    continue;
                  }
                  if (justify) {
                    if (r['bodyAlign'] != 'justify') {
                      failures.add('$label body text-align=${r['bodyAlign']}');
                    }
                    if (ragged * 10 > lines) {
                      failures.add('$label $ragged/$lines lines ragged');
                    }
                  } else if (lang == 'en' && ragged == 0) {
                    // Control: the SE book itself never justifies paragraphs, so
                    // with the switch off ragged lines must show up — proves
                    // the probe can see raggedness at all.
                    failures.add('$label control: only $ragged/$lines ragged');
                  }
                  if (lang == 'en' && r['headingAlign'] != 'center') {
                    failures.add('$label heading align=${r['headingAlign']}');
                  }
                  if (lang == 'ja' && (r['rtTotal'] as num) == 0) {
                    failures.add('$label no ruby in chapter');
                  }
                }
              }
            }
            debugPrint('[justify] SUMMARY\n${summary.join('\n')}');
            debugPrint(
              '[justify] FAILURES ${failures.length}\n'
              '${failures.join('\n')}',
            );
            expect(summary, isNotEmpty, reason: 'probe measured nothing');
            expect(failures, isEmpty);
          } finally {
            await _closeReader(tester);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderEnableTextJustification(originalJustify);
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
