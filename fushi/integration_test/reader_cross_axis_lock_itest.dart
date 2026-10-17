import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/observe_capture.dart' show readerWebViewReady;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3482 真 app 回归：阅读器正文的交叉轴（竖排的上下 / 横排的左右）没有任何可
/// 滚动范围——即使正文里有东西沿交叉轴越出视口。
///
/// 用户在 iOS 滚动模式下手指上下拖动，整页跟着上下移了约 9pt（关了回弹，所以停在
/// 被拖到的位置）。根因：`html { overflow-y: hidden }` 锁不住 WKWebView 的
/// UIScrollView——它的内容尺寸取文档的可滚动溢出，正文里任何沿交叉轴越界的后代
/// （有声书句高亮窄条、注音、书自带的块）都会让它沿交叉轴可拖、可被程序化滚开。
///
/// 本测试在 6 种组合（竖排 / 横排 × 翻页 / 滚动 / VN）下开同一本书，往 body 里塞一个
/// 沿交叉轴越出视口 16px 的绝对定位块（模拟句高亮窄条），然后断言：
///  1. 根滚动器沿交叉轴的 scroll 尺寸 == client 尺寸（没有可滚范围）；
///  2. `window.scrollBy` 沿交叉轴推 50px 后偏移仍为 0；
///  3. 滚动模式下主轴照样能滚（锁轴没有误伤书写轴）。
///
/// 真触摸那一层（WebKit 是否让手指拖开交叉轴）由
/// `support/ios_webkit_pan_probe/` 在纯 WKWebView 里实测——Flutter 平台视图在模拟器上
/// 收不到 XCUITest 合成的触摸。带 `--dart-define=FUSHI_XAXIS_DUMP=1` 跑本测试时，
/// 两种书写方向的滚动模式会把**实际注入的阅读器 CSS** 连同正文导出成修复前 / 后
/// 两组实验页，写到宿主 `/tmp/fushi-xaxis/variants/`（仅 iOS 模拟器可写宿主路径）。
///
/// Run（fushi/）：flutter test integration_test/reader_cross_axis_lock_itest.dart -d <device>
const bool _kDump = bool.fromEnvironment('FUSHI_XAXIS_DUMP');

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

bool _contentReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) return;
  }
  fail('$label did not become ready');
}

const String _para =
    '吾輩は<ruby>猫<rt>ねこ</rt></ruby>である。名前はまだ無い。どこで<ruby>生<rt>うま</rt></ruby>れたかとんと<ruby>見当<rt>けんとう</rt></ruby>がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。';

String _chapter(String title) {
  final StringBuffer b = StringBuffer();
  for (int i = 1; i <= 80; i++) {
    b.writeln('<p>$i $_para</p>');
  }
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>'
      '<body>\n<h1>$title</h1>\n$b</body></html>';
}

Uint8List _buildEpub() {
  const String opf =
      '<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">cross-axis-lock</dc:identifier>'
      '<dc:title>Cross axis lock</dc:title><dc:language>ja</dc:language></metadata>'
      '<manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>'
      '<spine><itemref idref="c1"/></spine></package>';
  const String nav =
      '<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">一</a></li></ol></nav></body></html>';
  const String container =
      '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>';
  final Archive a = Archive();
  void add(String name, String content, {bool store = false}) {
    final List<int> bytes = utf8.encode(content);
    final ArchiveFile f = ArchiveFile(name, bytes.length, bytes);
    if (store) f.compress = false;
    a.addFile(f);
  }

  add('mimetype', 'application/epub+zip', store: true);
  add('META-INF/container.xml', container);
  add('OEBPS/content.opf', opf);
  add('OEBPS/nav.xhtml', nav);
  add('OEBPS/ch1.xhtml', _chapter('第一章'));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

/// 往 body 里塞一个沿交叉轴越出视口 16px 的块，量交叉轴可滚范围，再沿交叉轴程序化
/// 滚 50px。iOS 上根滚动器（主轴 auto 的那种）的滚动由 UI 进程异步落定，同步读回的
/// 是未钳制的请求值，所以「滚完读位置」放在下一次求值（中间 pump 一段）。
const String _probeStartJs = r'''
(function(){
  var doc = document.documentElement, body = document.body;
  var root = document.scrollingElement || doc;
  var vertical = /^vertical/.test(getComputedStyle(body).writingMode);
  var lane = document.createElement('div');
  lane.setAttribute('data-xaxis-lane', '1');
  lane.style.cssText = vertical
    ? 'position:absolute;left:60px;top:calc(100% - 4px);width:30px;height:20px;'
    : 'position:absolute;top:120px;left:calc(100% - 4px);width:20px;height:30px;';
  body.appendChild(lane);
  var bcs = getComputedStyle(body), hcs = getComputedStyle(doc);
  var out = {vertical: vertical,
    crossScroll: vertical ? root.scrollHeight : root.scrollWidth,
    crossClient: vertical ? doc.clientHeight : doc.clientWidth,
    main0: vertical ? root.scrollLeft : root.scrollTop,
    bodyOv: bcs.overflowX + '/' + bcs.overflowY, htmlOv: hcs.overflowX + '/' + hcs.overflowY,
    touchAction: hcs.touchAction + '|' + bcs.touchAction};
  window.scrollBy(vertical ? {left: 0, top: 50, behavior: 'instant'}
                           : {left: 50, top: 0, behavior: 'instant'});
  return JSON.stringify(out);
})()
''';

/// 读交叉轴落定后的偏移（scrollTop / scrollLeft 与视觉视口偏移），再沿主轴滚 200px。
const String _probeMidJs = r'''
(function(){
  var root = document.scrollingElement || document.documentElement;
  var vertical = /^vertical/.test(getComputedStyle(document.body).writingMode);
  var vv = window.visualViewport;
  var out = {crossAfter: vertical ? root.scrollTop : root.scrollLeft,
    vvCross: vv ? (vertical ? vv.pageTop : vv.pageLeft) : 0};
  window.scrollBy(vertical ? {left: -200, top: 0, behavior: 'instant'}
                           : {left: 0, top: 200, behavior: 'instant'});
  return JSON.stringify(out);
})()
''';

/// 读主轴落定后的偏移，然后还原（拿掉越界块、滚回章首）。
const String _probeEndJs = r'''
(function(){
  var root = document.scrollingElement || document.documentElement;
  var vertical = /^vertical/.test(getComputedStyle(document.body).writingMode);
  var out = {main1: vertical ? root.scrollLeft : root.scrollTop};
  var lane = document.querySelector('[data-xaxis-lane]');
  if (lane) lane.remove();
  window.scrollTo(0, 0);
  return JSON.stringify(out);
})()
''';

/// 导出实验页：当前文档的全部 `<style>` + 正文（去脚本），修复前 / 后 × 有无越界块。
const String _dumpJs = r'''
(function(){
  var styles = Array.prototype.map.call(document.querySelectorAll('style'),
      function(s){ return s.textContent; }).join('\n');
  var clone = document.body.cloneNode(true);
  Array.prototype.forEach.call(clone.querySelectorAll('script'), function(s){ s.remove(); });
  return JSON.stringify({styles: styles, body: clone.innerHTML,
    htmlStyle: document.documentElement.getAttribute('style') || '',
    bodyClass: document.body.className || ''});
})()
''';

Future<Map<String, dynamic>> _eval(String js) async {
  final Object? raw = await ReaderFushiPage.debugEvaluateJavascript!(js);
  return raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
}

Future<void> _dumpVariants(String wm) async {
  final Map<String, dynamic> d = await _eval(_dumpJs);
  final bool v = wm.startsWith('vertical');
  final String lock =
      'html, body {\n  touch-action: ${v ? 'pan-x' : 'pan-y'} !important;\n}\n'
      'body {\n  ${v ? 'overflow-y' : 'overflow-x'}: clip !important;\n}\n';
  final String fixed = d['styles'] as String;
  expect(fixed, contains(lock), reason: 'live reader CSS lacks the lock rule');
  final String lane = v
      ? '<div style="position:absolute;left:60px;top:calc(100% - 4px);width:30px;height:20px;background:rgba(255,0,0,.4)"></div>'
      : '<div style="position:absolute;top:120px;left:calc(100% - 4px);width:20px;height:30px;background:rgba(255,0,0,.4)"></div>';
  final Directory out = Directory('/tmp/fushi-xaxis/variants')
    ..createSync(recursive: true);
  for (final MapEntry<String, String> css in <String, String>{
    'base': fixed.replaceFirst(lock, ''),
    'fix': fixed,
  }.entries) {
    for (final MapEntry<String, String> extra in <String, String>{
      'none': '',
      'lane': lane,
    }.entries) {
      File(
        '${out.path}/${v ? 'v' : 'h'}-${css.key}-${extra.key}.html',
      ).writeAsStringSync(
        '<!DOCTYPE html><html style="${d['htmlStyle']}"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">'
        '<style>${css.value}</style></head>'
        '<body class="${d['bodyClass']}">${d['body']}${extra.value}</body></html>',
      );
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader cross axis has no scroll range in any view mode', (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'xaxis',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);
        await showBooksTab(tester);
        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: _buildEpub(),
          fileName: 'cross_axis_lock.epub',
        );
        final ReaderFushiSource source = ReaderFushiSource.instance;
        final String originalWm = source.readerWritingMode;
        final String originalMode = source.readerViewMode;

        final List<String> summary = <String>[];
        final List<String> failures = <String>[];
        try {
          for (final (String wm, String mode) in <(String, String)>[
            ('vertical-rl', 'continuous'),
            ('horizontal-tb', 'continuous'),
            ('vertical-rl', 'paginated'),
            ('horizontal-tb', 'paginated'),
            ('vertical-rl', 'vn'),
            ('horizontal-tb', 'vn'),
          ]) {
            await source.setReaderWritingMode(wm);
            await source.setReaderViewMode(mode);
            for (int i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 150));
            }
            await openBookViaProductionPath(tester, bookKey);
            await _waitFor(tester, _webViewShown, 'reader WebView');
            await _waitFor(tester, _contentReady, 'content', maxPolls: 240);
            await _waitFor(tester, readerWebViewReady, 'debug hooks');
            await tester.pump(const Duration(seconds: 3));

            final String label = '$wm-$mode';
            final Map<String, dynamic> r = await _eval(_probeStartJs);
            await tester.pump(const Duration(milliseconds: 700));
            r.addAll(await _eval(_probeMidJs));
            await tester.pump(const Duration(milliseconds: 700));
            r.addAll(await _eval(_probeEndJs));
            r['mainMoved'] = r['main1'] != r['main0'];
            final String line = '[xaxis] $label ${jsonEncode(r)}';
            debugPrint(line);
            summary.add(line);
            if ((r['crossScroll'] as num) > (r['crossClient'] as num)) {
              failures.add(
                '$label: cross axis scrollable '
                '${r['crossScroll']} > ${r['crossClient']}',
              );
            }
            if ((r['crossAfter'] as num) != 0 || (r['vvCross'] as num) != 0) {
              failures.add(
                '$label: scrollBy moved cross axis to '
                '${r['crossAfter']} (visual viewport ${r['vvCross']})',
              );
            }
            if (mode == 'continuous' && r['mainMoved'] != true) {
              failures.add('$label: main axis no longer scrolls');
            }
            if (_kDump && mode == 'continuous') await _dumpVariants(wm);

            Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
            await _waitFor(tester, _readerPageGone, 'reader closed');
            await tester.pump(const Duration(seconds: 1));
          }
        } finally {
          await source.setReaderWritingMode(originalWm);
          await source.setReaderViewMode(originalMode);
        }
        debugPrint('[xaxis] SUMMARY\n${summary.join('\n')}');
        debugPrint(
          '[xaxis] FAILURES ${failures.length}\n${failures.join('\n')}',
        );
        expect(summary, hasLength(6));
        expect(failures, isEmpty);
      },
    );
  });
}
