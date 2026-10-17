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

/// BUG-2810 / BUG-2811 真书探针：WebKit 注音拉力（`--fushi-ruby-pull`）在翻页 / 滚动 / VN
/// 三种 view mode 下是否量对、注音是否贴在基字外侧。
///
/// 用户报「iOS 分页一打开，振假名压进基字」。根因是注音度量脚本量到了分页页顶
/// 被切进上一栏的 `<rt>`（外接矩形是两页的并集），拉力被夹到上限 1.5。本探针走
/// 真 app 的生产导入与开书路径：
///
///  1. 导入 `FUSHI_PROBE_EPUB`（用户那本书），正文字体切到 `FUSHI_PROBE_FONT`
///     （Klee One 这类内容区大的字体才显形），竖排、行高 1.65、注音淡显、字号
///     `FUSHI_PROBE_FONT_SIZE`（缺省 42）；
///  2. 分页模式逐章开书（只挑有注音的章），记下每章写出的拉力——修复前页顶首颗
///     注音跨栏的章会是 1.500；
///  3. 在含 `FUSHI_PROBE_NEEDLE` 的那一章，翻页 / 滚动 / VN 三种模式各开一次，
///     把正文翻到该段、量全部注音（跨栏几颗、注音盒中心离基字中心几个 em），
///     并截 WebView 图（给了 `FUSHI_PROBE_OUT` 就复制到那里）。
///
/// 判据（全部量完、打印 SUMMARY 后才断言）：有排出来的注音时拉力必须已写入、且
/// 没被夹到 1.5；每颗完整排版的注音，其盒中心离基字中心在 (0.5, 0.8) em 之间——
/// 压进基字的注音（BUG-2810）量出来 ≈0.35em，没量成功、落回缺省拉力的注音
/// （BUG-2811，VN）≈0.98em，贴好的 ≈0.68em。偏好在 `finally` 还原。
///
/// Run on the iOS simulator（Mac，fushi/ 下）：
///   flutter test integration_test/reader_ruby_pull_view_modes_probe_itest.dart \
///     -d <udid> --no-pub \
///     --dart-define=FUSHI_PROBE_EPUB=/abs/book.epub \
///     --dart-define=FUSHI_PROBE_FONT=/abs/KleeOne-Regular.ttf \
///     --dart-define=FUSHI_PROBE_NEEDLE=冷蔵庫を開け \
///     --dart-define=FUSHI_PROBE_OUT=/tmp/rrub/out

const String _epubPath = String.fromEnvironment('FUSHI_PROBE_EPUB');
const String _fontPath = String.fromEnvironment('FUSHI_PROBE_FONT');
const String _needle = String.fromEnvironment('FUSHI_PROBE_NEEDLE');
const String _outDir = String.fromEnvironment('FUSHI_PROBE_OUT');
const String _fontSize =
    String.fromEnvironment('FUSHI_PROBE_FONT_SIZE', defaultValue: '42');

const String _kFontName = 'Probe Ruby Font';
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
  // 度量脚本在 rAF / 字体就绪后写变量；给它和版面几秒稳定下来。
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

/// 翻到含 needle 的段落：VN 逐屏找、分页按栏周期落页、滚动 scrollIntoView。
String _gotoNeedleJs(String needle) => '''
(function () {
  var needle = ${jsonEncode(needle)};
  var r = window.fushiReader;
  if (r && r.screens && r.screen && r.renderScreen) {
    for (var i = 0; i < r.screens.length; i++) {
      r.renderScreen(i, true);
      if ((r.screen.textContent || '').indexOf(needle) >= 0) {
        return JSON.stringify({ how: 'vn', screen: i });
      }
    }
    return JSON.stringify({ how: 'vn', screen: -1 });
  }
  var ps = document.body.querySelectorAll('p, div');
  for (var k = 0; k < ps.length; k++) {
    if ((ps[k].textContent || '').indexOf(needle) < 0 || ps[k].querySelector('p')) continue;
    var cs = getComputedStyle(document.body);
    var pitch = parseFloat(cs.columnWidth) + parseFloat(cs.columnGap);
    if (pitch > 0 && isFinite(pitch)) {
      var range = document.createRange();
      range.selectNodeContents(ps[k]);
      var first = range.getClientRects()[0];
      var vertical = cs.writingMode.indexOf('vertical') === 0;
      var el = document.scrollingElement && document.scrollingElement.scrollHeight > document.body.scrollHeight
          ? document.scrollingElement : document.body;
      if (vertical) {
        var top = first.top + el.scrollTop;
        el.scrollTop = Math.floor(top / pitch) * pitch;
      } else {
        var left = first.left + el.scrollLeft;
        el.scrollLeft = Math.floor(left / pitch) * pitch;
      }
      return JSON.stringify({ how: 'paged', pitch: pitch });
    }
    ps[k].scrollIntoView({ block: 'start', inline: 'start' });
    return JSON.stringify({ how: 'scroll' });
  }
  return JSON.stringify({ how: 'none' });
})()
''';

/// 拉力、跨栏注音数、注音盒中心离基字中心的距离（以基字字号计，朝注音一侧为正）。
const String _measureJs = r'''
(function () {
  var root = document.documentElement;
  var body = document.body;
  var bcs = getComputedStyle(body);
  var vertical = bcs.writingMode.indexOf('vertical') === 0;
  var out = {
    pull: getComputedStyle(root).getPropertyValue('--fushi-ruby-pull').trim(),
    snap: getComputedStyle(root).getPropertyValue('--fushi-ruby-snap').trim(),
    writingMode: bcs.writingMode, fontFamily: bcs.fontFamily, fontSize: bcs.fontSize,
    columns: bcs.columnWidth, inner: innerWidth + 'x' + innerHeight,
    rubies: 0, laidOut: 0, split: 0, inside: 0, far: 0, offs: []
  };
  var list = body.getElementsByTagName('ruby');
  out.rubies = list.length;
  for (var i = 0; i < list.length; i++) {
    var ruby = list[i];
    var rt = ruby.querySelector('rt');
    if (!rt) continue;
    var rects = rt.getClientRects();
    if (!rects.length) continue;
    out.laidOut++;
    if (rects.length !== 1) { out.split++; continue; }
    var base = null;
    var w = document.createTreeWalker(ruby, NodeFilter.SHOW_TEXT);
    for (var t = w.nextNode(); t; t = w.nextNode()) {
      if (t.parentNode.closest && t.parentNode.closest('rt, rp')) continue;
      if (t.nodeValue.trim()) { base = t; break; }
    }
    if (!base) continue;
    var at = base.nodeValue.search(/\S/);
    var range = document.createRange();
    range.setStart(base, at);
    range.setEnd(base, at + 1);
    var br = range.getClientRects()[0];
    if (!br) continue;
    var tr = rects[0];
    var fs = parseFloat(getComputedStyle(ruby).fontSize);
    var off = vertical
      ? ((tr.left + tr.right) / 2 - (br.left + br.right) / 2) / fs
      : ((br.top + br.bottom) / 2 - (tr.top + tr.bottom) / 2) / fs;
    out.offs.push(Math.round(off * 1000) / 1000);
    if (off <= 0.5) out.inside++;
    if (off >= 0.8) out.far++;
  }
  var s = out.offs.slice().sort(function (a, b) { return a - b; });
  out.offMin = s.length ? s[0] : null;
  out.offMed = s.length ? s[s.length >> 1] : null;
  out.offMax = s.length ? s[s.length - 1] : null;
  out.offs = out.offs.slice(0, 12);
  return JSON.stringify(out);
})()
''';

Future<void> _saveShot(String name) async {
  final ObserveShot shot = await captureReaderWebView(name);
  debugPrint('[ruby-pull] shot $name saved=${shot.saved} '
      'nonBlank=${shot.nonBlank} path=${shot.path}');
  if (_outDir.isEmpty || !shot.saved) return;
  try {
    Directory(_outDir).createSync(recursive: true);
    File(shot.path).copySync('$_outDir/$name.png');
  } on FileSystemException catch (e) {
    debugPrint('[ruby-pull] copy $name to $_outDir failed: $e');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2810 real-book probe: WebKit ruby pull stays measured and annotations '
    'stay outside their base across paginated / continuous / VN',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      expect(_epubPath, isNotEmpty,
          reason: 'pass --dart-define=FUSHI_PROBE_EPUB=<path to epub>');
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'ruby-pull',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalFurigana = source.readerFuriganaMode;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final double originalLineHeight = source.readerLineHeight;
          final double originalFontSize = source.readerFontSize;
          final List<Map<String, dynamic>> originalFonts =
              List<Map<String, dynamic>>.from(source.customFonts);

          final List<String> summary = <String>[];
          final List<String> failures = <String>[];
          void check(String label, Map<String, dynamic> r) {
            final double pull = double.tryParse('${r['pull']}') ?? 0.1;
            if (pull >= 1.5) {
              failures.add('$label pull clamped to ${r['pull']}');
            }
            if ((r['inside'] as num) > 0) {
              failures.add('$label ${r['inside']} annotations inside the base');
            }
            if ((r['far'] as num) > 0) {
              failures.add('$label ${r['far']} annotations far from the base');
            }
            if (r['snap'] == '1' &&
                (r['laidOut'] as num) > 0 &&
                '${r['pull']}'.isEmpty) {
              failures.add('$label pull never measured');
            }
          }

          try {
            if (_fontPath.isNotEmpty) {
              final Directory fontDir =
                  Directory('${appModel.appDirectory.path}/custom_fonts')
                    ..createSync(recursive: true);
              final File font = File(_fontPath)
                  .copySync('${fontDir.path}/probe-ruby-font.ttf');
              await source.setCustomFonts(<Map<String, dynamic>>[
                <String, dynamic>{
                  'name': _kFontName,
                  'path': font.path,
                  'enabled': true,
                },
              ]);
            }
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderLineHeight(1.65);
            await source.setReaderFontSize(double.parse(_fontSize));
            await source.setReaderFuriganaMode('dimmed');
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
            final List<int> rubySections = <int>[];
            int needleSection = -1;
            for (int i = 0; i < chapters.length; i++) {
              final String href =
                  (chapters[i] as Map<String, dynamic>)['href'] as String;
              final File f =
                  File('${row.extractDir}${Platform.pathSeparator}$href');
              if (!f.existsSync()) continue;
              final String html = f.readAsStringSync();
              if ('<rt'.allMatches(html).length >= 5) rubySections.add(i);
              if (_needle.isNotEmpty && html.contains(_needle)) {
                needleSection = i;
              }
            }
            debugPrint('[ruby-pull] ruby sections=$rubySections '
                'needle section=$needleSection');

            // 2. 分页逐章：每章写出的拉力。
            await source.setReaderViewMode('paginated');
            await _pumpForPref(tester);
            for (final int section in rubySections) {
              await _pinSection(appModel, row.uid, section);
              await _openBook(tester, bookKey);
              final Map<String, dynamic> r = await _eval(_measureJs);
              final String line = '[ruby-pull] sweep section=$section '
                  'pull=${r['pull']} laidOut=${r['laidOut']} '
                  'split=${r['split']} inside=${r['inside']} far=${r['far']} '
                  'off=${r['offMin']}/${r['offMed']}/${r['offMax']}';
              debugPrint(line);
              summary.add(line);
              check('sweep section=$section', r);
              await _closeReader(tester);
            }

            // 3. needle 那一章，三种模式。
            if (needleSection >= 0) {
              for (final String mode in <String>[
                'paginated',
                'continuous',
                'vn',
              ]) {
                await source.setReaderViewMode(mode);
                await _pumpForPref(tester);
                await _pinSection(appModel, row.uid, needleSection);
                await _openBook(tester, bookKey);
                final Map<String, dynamic> go =
                    await _eval(_gotoNeedleJs(_needle));
                await tester.pump(const Duration(seconds: 2));
                final Map<String, dynamic> r = await _eval(_measureJs);
                final String line = '[ruby-pull] mode=$mode goto=$go '
                    'pull=${r['pull']} snap=${r['snap']} '
                    'laidOut=${r['laidOut']} split=${r['split']} '
                    'inside=${r['inside']} far=${r['far']} '
                    'off=${r['offMin']}/${r['offMed']}/${r['offMax']} '
                    'font=${r['fontFamily']} ${r['fontSize']} '
                    'wm=${r['writingMode']} inner=${r['inner']} '
                    'sample=${r['offs']}';
                debugPrint(line);
                summary.add(line);
                check('mode=$mode', r);
                await _saveShot('ruby-pull-$mode');
                await _closeReader(tester);
              }
            }
            debugPrint('[ruby-pull] SUMMARY\n${summary.join('\n')}');
            debugPrint('[ruby-pull] FAILURES ${failures.length}\n'
                '${failures.join('\n')}');
            expect(summary, isNotEmpty, reason: 'probe measured nothing');
            expect(failures, isEmpty);
          } finally {
            await _closeReader(tester);
            await source.setCustomFonts(originalFonts);
            await source.setReaderFuriganaMode(originalFurigana);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderLineHeight(originalLineHeight);
            await source.setReaderFontSize(originalFontSize);
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
