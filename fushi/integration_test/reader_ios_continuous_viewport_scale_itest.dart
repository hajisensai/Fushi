import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/reader_pagination_scripts.dart'
    show ReaderPaginationScripts;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2639 回归：用户在 iPhone 上从视觉小说模式切到竖排「滚动」后，整页停在
/// WKWebView 默认的 980 CSS px 布局里（scale 402/980≈0.41）：42px 字只剩约 17pt、
/// 每列只占屏幕上部四成、正文顶进状态栏。根因是章节文档交付时不带 viewport
/// meta，CSS 像素空间全靠 shell 的 initialize() 事后用 JS 补。模拟器上那段 JS
/// 总能及时生效、复现不出「卡住」，所以这条测试守两件事：
///  1. WKWebView 实际拿到的章节字节里已经带着阅读器的 viewport meta（真实交付路径，
///     不经过 initialize）；
///  2. VN → 滚动现切之后视觉视口不缩放、布局视口宽 = Flutter 侧设备宽。
///
/// Run (from repo root, iOS):
///   .\tool\run_mac_itest.ps1 integration_test/reader_ios_continuous_viewport_scale_itest.dart -Ios
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
    if (ready()) return;
  }
  fail('$label did not become ready');
}

const String _para =
    '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。';

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
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">ios-cont-scale</dc:identifier>'
      '<dc:title>iOS continuous scale</dc:title><dc:language>ja</dc:language></metadata>'
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

const String _geomJs = r'''
(function(){
  var doc = document.documentElement, body = document.body;
  var root = document.scrollingElement || doc;
  var vv = window.visualViewport;
  var br = body.getBoundingClientRect();
  return JSON.stringify({
    innerW: window.innerWidth, innerH: window.innerHeight,
    scrollW: root.scrollWidth, bodyH: Math.round(br.height),
    fontSize: getComputedStyle(body).fontSize,
    contVar: doc.style.getPropertyValue('--fushi-continuous-height'),
    vvScale: vv ? vv.scale : null, vvW: vv ? vv.width : null,
    meta: (document.querySelector('meta[name=viewport]') || {}).content || null
  });
})()
''';

// 取回 WKWebView 经自定义 scheme 实际拿到的本章字节（不经 initialize 的 JS）。
const String _kickServedFetchJs = r'''
(function(){
  window.__probeServed = null;
  fetch(location.href).then(function(r){ return r.text(); })
    .then(function(t){ window.__probeServed = t; })
    .catch(function(e){ window.__probeServed = 'ERR:' + e; });
  return 'kicked';
})()
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'vertical-rl continuous: WKWebView must not shrink the page to fit',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'ioscont',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await showBooksTab(tester);
          final String bookKey = await EpubImporter.import(
            db: appModel.database,
            bytes: _buildEpub(),
            fileName: 'ios_cont_scale.epub',
          );
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 用户原始路径：先在视觉小说模式里读，再从阅读设置现切到「滚动」。
          // 设置页的切换 = 先持久化 view mode、再调 onLayoutReloadLive 让
          // 同一个 WKWebView 重载章节（settings_schema_reading.dart）。
          await ReaderFushiSource.instance.setReaderWritingMode('vertical-rl');
          await ReaderFushiSource.instance.setReaderViewMode('vn');
          await ReaderFushiSource.instance.setReaderFontSize(42);

          await openBookViaProductionPath(tester, bookKey);
          await tester.pump(const Duration(seconds: 3));
          await _waitFor(tester, _webViewShown, 'reader WebView');
          await _waitFor(tester, _contentReady, 'content');
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          final Future<dynamic> Function(String source)? runJs =
              ReaderFushiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull);
          debugPrint('[ioscont] vn geom=${await runJs!(_geomJs)}');

          await ReaderFushiSource.instance.setReaderViewMode('continuous');
          ReaderFushiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 24; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _waitFor(tester, _contentReady, 'content after switch');
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final MediaQueryData mq = MediaQuery.of(
            tester.element(find.byType(ReaderFushiPage)),
          );
          final Object? raw = await runJs(_geomJs);
          debugPrint('[ioscont] mq=${mq.size} geom=$raw');
          final Map<String, dynamic> geom =
              jsonDecode(raw.toString()) as Map<String, dynamic>;

          await runJs(_kickServedFetchJs);
          String? served;
          for (int i = 0; i < 40 && served == null; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            final Object? v = await runJs('window.__probeServed');
            if (v != null && v.toString() != 'null') served = v.toString();
          }
          debugPrint(
            '[ioscont] served head=${served?.substring(0, served.length.clamp(0, 600))}',
          );
          expect(
            served,
            contains(ReaderPaginationScripts.readerViewportMetaTag),
            reason: 'the served chapter must carry the reader viewport meta',
          );

          // 前提：确实是横向超宽的竖排连续文档，否则这条测试证明不了任何东西。
          expect(
            (geom['scrollW'] as num) > (geom['innerW'] as num) * 2,
            isTrue,
            reason: 'fixture must overflow horizontally: $raw',
          );
          expect(
            (geom['vvScale'] as num?)?.toDouble(),
            closeTo(1.0, 0.01),
            reason: 'visual viewport must not be zoomed out: $raw',
          );
          expect(
            (geom['innerW'] as num).toDouble(),
            closeTo(mq.size.width, 2),
            reason: 'layout viewport must be device-width: $raw',
          );
        },
      );
    },
  );
}
