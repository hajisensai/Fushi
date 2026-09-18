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

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2578 真机探针（不进 CI）：竖排 + 连续滚动下滚动轴只能是横向。探针在真
/// app 里导入一本**无 DOCTYPE**（quirks，和多数日文 EPUB 一样）的书、切竖排连续 +
/// 上下页边距 + 大字号，打印 Flutter 侧 MediaQuery 与 WebView 的 html/body 滚动几何
/// （视口高 / body 高 / `--fushi-continuous-height` / 越出视口底的元素），然后开一个
/// 15 分钟观察窗每 10 秒打印 scrollTop / visualViewport，供宿主用
/// `adb shell input swipe` 真触摸上下滑动、`adb exec-out screencap` 截图、Chrome
/// DevTools（`adb forward tcp:9223 localabstract:webview_devtools_remote_<pid>`）
/// 读 DOM。真设备触摸要进 widget 树，必须打开
/// `shouldPropagateDevicePointerEvents`（默认被 live binding 吞掉）。
///
/// Run (from fushi/):
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/reader_vertical_continuous_axis_probe_itest.dart -d <serial>
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
      debugPrint('[vaxis] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

const String _para =
    '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。';

String _chapter(String title) {
  final StringBuffer b = StringBuffer();
  for (int i = 1; i <= 80; i++) {
    b.writeln('<p>$i $_para</p>');
  }
  // 刻意不写 DOCTYPE：多数日文 EPUB 的 XHTML 没有它，reader 又不补，页面落 quirks。
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>'
      '<body>\n<h1>$title</h1>\n$b</body></html>';
}

Uint8List _buildEpub() {
  const String opf =
      '<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">vaxis-probe-quirks</dc:identifier>'
      '<dc:title>VAXIS quirks</dc:title><dc:language>ja</dc:language></metadata>'
      '<manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>'
      '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>';
  const String nav =
      '<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">一</a></li><li><a href="ch2.xhtml">二</a></li></ol></nav></body></html>';
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
  add('OEBPS/ch2.xhtml', _chapter('第二章'));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

const String _geomJs = r'''
(function(){
  var doc = document.documentElement, body = document.body;
  var root = document.scrollingElement || doc;
  var dcs = getComputedStyle(doc), bcs = getComputedStyle(body);
  var over = [];
  var all = body.querySelectorAll('*');
  for (var i = 0; i < all.length && over.length < 6; i++) {
    var r = all[i].getBoundingClientRect();
    if (r.height > 0 && (r.bottom > window.innerHeight + 1 || r.top < -1)) {
      over.push({tag: all[i].tagName, top: Math.round(r.top), bottom: Math.round(r.bottom)});
    }
  }
  var vv = window.visualViewport;
  return JSON.stringify({
    compat: document.compatMode, scrollingEl: root.tagName,
    htmlOvX: dcs.overflowX, htmlOvY: dcs.overflowY, bodyOvX: bcs.overflowX, bodyOvY: bcs.overflowY,
    wm: bcs.writingMode, innerW: window.innerWidth, innerH: window.innerHeight,
    docClientW: doc.clientWidth, docClientH: doc.clientHeight, bodyClientH: body.clientHeight,
    scrollW: root.scrollWidth, scrollH: root.scrollHeight, docScrollH: doc.scrollHeight, bodyScrollH: body.scrollHeight,
    st: root.scrollTop, sl: root.scrollLeft,
    bodyOffH: body.offsetHeight, bodyOffW: body.offsetWidth, bodyCssH: bcs.height, pt: bcs.paddingTop, pb: bcs.paddingBottom,
    contVar: doc.style.getPropertyValue('--fushi-continuous-height'),
    chromeTop: doc.style.getPropertyValue('--chrome-top-inset'), chromeBottom: doc.style.getPropertyValue('--chrome-bottom-inset'),
    fontSize: bcs.fontSize,
    vv: vv ? {w: vv.width, h: vv.height, ot: vv.offsetTop, ol: vv.offsetLeft, scale: vv.scale, pt: vv.pageTop} : null,
    dpr: window.devicePixelRatio, screenH: window.screen.height, outerH: window.outerHeight,
    meta: (document.querySelector('meta[name=viewport]') || {}).content || null,
    over: over
  });
})()
''';

const String _tickJs = r'''
(function(){
  var doc = document.documentElement;
  var root = document.scrollingElement || doc;
  var vv = window.visualViewport;
  return JSON.stringify({st: root.scrollTop, sl: root.scrollLeft, dst: doc.scrollTop, bst: document.body.scrollTop,
    sy: window.scrollY, sx: window.scrollX, vvT: vv ? vv.offsetTop : null, vvPT: vv ? vv.pageTop : null, vvH: vv ? vv.height : null});
})()
''';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 让 adb 注入的真实触摸进 widget 树（默认 live binding 会吞掉设备指针事件）。
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets(
    'vertical-rl continuous: html must not be vertically scrollable',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'vaxis',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home (nav bar) must render',
          );
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await showBooksTab(tester);
          final String bookKey = await EpubImporter.import(
            db: appModel.database,
            bytes: _buildEpub(),
            fileName: 'vaxis_quirks.epub',
          );
          debugPrint('[vaxis] imported key=$bookKey');
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 界面缩放 ≠ 1 时阅读器路由经 FushiAppUiScaleNeutralizer 反缩放；
          // --dart-define=FUSHI_PROBE_UI_SCALE_PCT=120 可把它拨到 1.2 看 WebView 平台
          // 视图的尺寸是否仍与屏幕一致（默认 100 = 不改）。
          const double probeUiScale =
              int.fromEnvironment(
                'FUSHI_PROBE_UI_SCALE_PCT',
                defaultValue: 100,
              ) /
              100;
          debugPrint(
            '[vaxis] appUiScale before=${appModel.themeNotifier.appUiScale}',
          );
          await appModel.themeNotifier.setAppUiScale(probeUiScale);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          debugPrint(
            '[vaxis] appUiScale now=${appModel.themeNotifier.appUiScale}',
          );
          // 用户口径：竖排 + 连续 + 上下页边距 + 大字号。开书前先写好偏好。
          await ReaderFushiSource.instance.setReaderWritingMode('vertical-rl');
          await ReaderFushiSource.instance.setReaderViewMode('continuous');
          await ReaderFushiSource.instance.setReaderMarginTop(5);
          await ReaderFushiSource.instance.setReaderMarginBottom(5);
          await ReaderFushiSource.instance.setReaderFontSize(26);

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

          final MediaQueryData mq = MediaQuery.of(
            tester.element(find.byType(ReaderFushiPage)),
          );
          debugPrint(
            '[vaxis] mq size=${mq.size} dpr=${mq.devicePixelRatio} '
            'padding=${mq.padding} viewPadding=${mq.viewPadding} '
            'viewInsets=${mq.viewInsets}',
          );
          final Object? geomRaw = await runJs!(_geomJs);
          debugPrint('[vaxis] geom=$geomRaw');
          final Map<String, dynamic> geom =
              jsonDecode(geomRaw.toString()) as Map<String, dynamic>;

          await runJs(
            'window.scrollTo(0, 400); document.body.scrollTop = 400;',
          );
          await tester.pump(const Duration(milliseconds: 300));
          debugPrint('[vaxis] afterScrollTo=${await runJs(_tickJs)}');
          await runJs('window.scrollTo(0, 0); document.body.scrollTop = 0;');

          // Observation window: drive `adb shell input swipe` from the host
          // while this loop prints the scroll state every second.
          debugPrint('[vaxis] observation window start (900s)');
          for (int i = 0; i < 450; i++) {
            await tester.pump(const Duration(milliseconds: 2000));
            if (i % 5 == 0) {
              debugPrint('[vaxis] tick ${i * 2}s ${await runJs(_tickJs)}');
            }
          }
          debugPrint('[vaxis] observation window end');
          debugPrint('[vaxis] geomAfter=${await runJs(_geomJs)}');

          expect(
            geom['htmlOvY'],
            'hidden',
            reason: 'vertical-rl continuous must hide the vertical axis',
          );
        },
      );
    },
  );
}
