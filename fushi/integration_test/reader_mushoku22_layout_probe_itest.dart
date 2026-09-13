import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真书布局探针：用户报的「目录列贴在一起 / 图片穿过不同章节 / 悬浮栏顶部空带」。
///
/// 对指定 EPUB（`--dart-define=FUSHI_PROBE_EPUB`）的每个目标章（按 href 尾名匹配）
/// 钉阅读位置、竖排分页开书，抓 WebView 截图并 dump DOM 几何（段落矩形 / 图片矩形 /
/// chrome 顶部 inset / body padding），每章抓两次：开书即刻（悬浮 chrome 唤出态）与
/// 5s 后（自动收起态）。
const String _epubPath = String.fromEnvironment('FUSHI_PROBE_EPUB');

typedef _Pass = ({
  String target,
  String wm,
  double fs,
  double lh,
  String label,
});

const List<_Pass> _passes = <_Pass>[
  (
    target: 'p-toc-002.xhtml',
    wm: 'vertical-rl',
    fs: 22,
    lh: 1.65,
    label: 'toc-v22',
  ),
  (
    target: 'p-002.xhtml',
    wm: 'vertical-rl',
    fs: 22,
    lh: 1.65,
    label: 'ruby-v22',
  ),
  (
    target: 'p-002.xhtml',
    wm: 'vertical-rl',
    fs: 22,
    lh: 1.0,
    label: 'ruby-v22-lh1',
  ),
  (
    target: 'p-002.xhtml',
    wm: 'horizontal-tb',
    fs: 22,
    lh: 1.65,
    label: 'ruby-h22',
  ),
  (
    target: 'p-002.xhtml',
    wm: 'vertical-rl',
    fs: 46,
    lh: 1.65,
    label: 'ruby-v46',
  ),
];

/// 候选 CSS（追加到 head 末尾，压过阅读器样式）：A/B WebKit 行盒规则。
const Map<String, String> _candidates = <String, String>{
  'current': '',
  'lbc-default':
      'html{-webkit-line-box-contain: block inline replaced !important}',
  'rt-mbs-05':
      'html{-webkit-line-box-contain: block inline replaced !important} rt{margin-block-start:-0.5em !important}',
  'rt-mbs-15':
      'html{-webkit-line-box-contain: block inline replaced !important} rt{margin-block-start:-1.5em !important}',
  'rt-mbs-3':
      'html{-webkit-line-box-contain: block inline replaced !important} rt{margin-block-start:-3em !important}',
};

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
      debugPrint('[m22] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
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

const String _probeJs = r'''
(function () {
  function rect(el) {
    var r = el.getBoundingClientRect();
    return { l: Math.round(r.left), t: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  }
  var doc = document.documentElement;
  var bcs = getComputedStyle(document.body);
  var out = {
    url: location.pathname,
    inner: { w: window.innerWidth, h: window.innerHeight },
    scroll: { x: window.scrollX, y: window.scrollY, sw: document.body.scrollWidth, sh: document.body.scrollHeight },
    chromeTop: getComputedStyle(doc).getPropertyValue('--chrome-top-inset'),
    body: { wm: bcs.writingMode, fs: bcs.fontSize, lh: bcs.lineHeight,
            pt: bcs.paddingTop, pb: bcs.paddingBottom, pl: bcs.paddingLeft, pr: bcs.paddingRight,
            mt: bcs.marginTop, h: bcs.height, w: bcs.width,
            colW: bcs.columnWidth, colGap: bcs.columnGap, colCount: bcs.columnCount },
    imgMax: { w: getComputedStyle(doc).getPropertyValue('--fushi-image-max-width'),
              h: getComputedStyle(doc).getPropertyValue('--fushi-image-max-height') },
    html: { cls: doc.className, wm: getComputedStyle(doc).writingMode, fs: getComputedStyle(doc).fontSize,
            lbc: getComputedStyle(doc).getPropertyValue('-webkit-line-box-contain') },
    client: { bcw: document.body.clientWidth, bch: document.body.clientHeight,
              dcw: doc.clientWidth, dch: doc.clientHeight,
              bsw: document.body.scrollWidth, bsh: document.body.scrollHeight,
              brect: rect(document.body),
              ratio: window.fushiReader && window.fushiReader._imageWidthRatio,
              csize: window.fushiReader && window.fushiReader._contentSize && window.fushiReader._contentSize(),
              ibox: window.fushiReader && window.fushiReader._imageMaxBox && window.fushiReader._imageMaxBox() },
    ps: [], imgs: [], mains: [], zeroP: 0, totalP: 0,
    compat: document.compatMode, synth: []
  };
  (function () {
    var host = document.getElementById('fushi-synth');
    if (!host) {
      host = document.createElement('div');
      host.id = 'fushi-synth';
      host.innerHTML = '<p data-k="bare">漢字テキスト</p>'
        + '<p data-k="span1"><span>漢字テキスト</span></p>'
        + '<p data-k="span2"><span><span>漢字テキスト</span></span></p>'
        + '<p data-k="a1"><a href="#x">漢字テキスト</a></p>'
        + '<p data-k="a-span"><a href="#x"><span>漢字テキスト</span></a></p>'
        + '<p data-k="br"><br/></p>'
        + '<p data-k="mixed">前<a href="#x"><span>漢字</span></a>後</p>'
        + '<p data-k="ruby"><ruby>漢字<rt>かんじ</rt></ruby>テキスト</p>'
        + '<p data-k="span-ruby"><span><ruby>漢字<rt>かんじ</rt></ruby>テキスト</span></p>'
        + '<p data-k="em-span"><em><span>漢字テキスト</span></em></p>'
        + '<p data-k="nbsp">&nbsp;</p>'
        + '<p data-k="empty"></p>';
      document.body.appendChild(host);
      void document.body.offsetWidth;
    }
    var vertical = /^vertical/.test(bcs.writingMode || '');
    var list = host.querySelectorAll('p');
    for (var q = 0; q < list.length; q++) {
      var rr = list[q].getBoundingClientRect();
      out.synth.push({ k: list[q].getAttribute('data-k'), size: Math.round((vertical ? rr.width : rr.height) * 10) / 10 });
    }
  })();
  (function () {
    var all = document.querySelectorAll('p');
    var vertical = /^vertical/.test(bcs.writingMode || '');
    for (var q = 0; q < all.length; q++) {
      var rr = all[q].getBoundingClientRect();
      out.totalP++;
      if ((vertical ? rr.width : rr.height) < 1) out.zeroP++;
    }
  })();
  var ps = document.querySelectorAll('p');
  for (var i = 0; i < ps.length && i < 30; i++) {
    var p = ps[i];
    var cs = getComputedStyle(p);
    out.ps.push({ i: i, txt: (p.textContent || '').trim().slice(0, 14), r: rect(p),
                  d: cs.display, pos: cs.position, fs: cs.fontSize, lh: cs.lineHeight, wm: cs.writingMode,
                  mt: cs.marginTop, mb: cs.marginBottom, ml: cs.marginLeft, mr: cs.marginRight,
                  cls: p.className, parent: p.parentNode.className });
  }
  var imgs = document.querySelectorAll('img, svg, .fushi-merged-image');
  for (var j = 0; j < imgs.length && j < 12; j++) {
    var im = imgs[j];
    var ics = getComputedStyle(im);
    out.imgs.push({ tag: im.tagName, cls: im.className && im.className.baseVal !== undefined ? im.className.baseVal : im.className,
                    r: rect(im), d: ics.display, w: ics.width, h: ics.height, maxW: ics.maxWidth, maxH: ics.maxHeight,
                    nat: im.naturalWidth ? [im.naturalWidth, im.naturalHeight] : null,
                    src: (im.getAttribute('src') || '').slice(-28) });
  }
  var mains = document.querySelectorAll('.main, body > div');
  for (var k = 0; k < mains.length && k < 6; k++) {
    var m = mains[k];
    var mcs = getComputedStyle(m);
    out.mains.push({ cls: m.className, r: rect(m), d: mcs.display, pt: mcs.paddingTop, pl: mcs.paddingLeft,
                     maxW: mcs.maxWidth, w: mcs.width, h: mcs.height, mt: mcs.marginTop, ml: mcs.marginLeft });
  }
  return JSON.stringify(out);
})()
''';

const String _rubyJs = r'''
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
  (function () {
    var rubies = document.querySelectorAll('ruby');
    var gaps = [], centers = [], rtSizes = [];
    for (var i = 0; i < rubies.length && gaps.length < 40; i++) {
      var rb = rubies[i];
      var rt = rb.querySelector('rt');
      if (!rt) continue;
      var baseNode = null;
      for (var c = 0; c < rb.childNodes.length; c++) {
        var n = rb.childNodes[c];
        if (n.nodeType === Node.TEXT_NODE && n.textContent.trim()) { baseNode = n; break; }
      }
      if (!baseNode) continue;
      var r = document.createRange(); r.selectNodeContents(baseNode);
      var br = r.getBoundingClientRect(); var tr = rt.getBoundingClientRect();
      if (!br.width || !tr.width) continue;
      if (vertical) { gaps.push(tr.left - br.right); centers.push((tr.top + tr.bottom) / 2 - (br.top + br.bottom) / 2); rtSizes.push(tr.width); }
      else { gaps.push(br.top - tr.bottom); centers.push((tr.left + tr.right) / 2 - (br.left + br.right) / 2); rtSizes.push(tr.height); }
    }
    out.rtGap = Math.round(median(gaps) * 100) / 100;
    out.rtCenter = Math.round(median(centers) * 100) / 100;
    out.rtSize = Math.round(median(rtSizes) * 100) / 100;
    out.rtN = gaps.length;
  })();
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

String _describeInsets(BuildContext c, ReaderFushiSource source) =>
    '[m22] flutter viewPadding=${MediaQuery.viewPaddingOf(c)} '
    'padding=${MediaQuery.paddingOf(c)} size=${MediaQuery.sizeOf(c)} '
    'dpr=${MediaQuery.devicePixelRatioOf(c)} '
    'marginTop=${source.readerMarginTop} '
    'marginBottom=${source.readerMarginBottom} '
    'topProgress=${source.showTopProgressBar} '
    'topProgressFloating=${source.topProgressFloating}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mushoku22 layout probe: toc overlap / merged image / floating top gap',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      expect(
        _epubPath,
        isNotEmpty,
        reason: 'pass --dart-define=FUSHI_PROBE_EPUB=<path to epub>',
      );
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'm22',
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
          final bool originalFloating = source.tapEmptyToHideChrome;
          final double originalFontSize = source.readerFontSize;
          final double originalLineHeight = source.readerLineHeight;
          debugPrint(
            '[m22] original prefs: writing_mode=$originalWritingMode '
            'view_mode=$originalViewMode floating=$originalFloating '
            'font_size=$originalFontSize merge=${source.readerMergeImagePages}',
          );

          try {
            await source.setReaderViewMode('paginated');
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderFontSize(22);
            if (!originalFloating) source.toggleTapEmptyToHideChrome();
            await _pumpForPref(tester);

            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            debugPrint('[m22] imported key=$bookKey');
            final EpubBookRow? row = await appModel.database.getEpubBook(
              bookKey,
            );
            expect(row, isNotNull);
            final List<dynamic> chapters =
                jsonDecode(row!.chaptersJson) as List<dynamic>;
            for (int i = 0; i < chapters.length; i++) {
              final Map<String, dynamic> c =
                  chapters[i] as Map<String, dynamic>;
              debugPrint('[m22] chapter $i href=${c['href']}');
            }

            for (final _Pass pass in _passes) {
              final String target = pass.target;
              await source.setReaderWritingMode(pass.wm);
              await source.setReaderFontSize(pass.fs);
              await source.setReaderLineHeight(pass.lh);
              await _pumpForPref(tester);
              int section = -1;
              for (int i = 0; i < chapters.length; i++) {
                final String href =
                    (chapters[i] as Map<String, dynamic>)['href'] as String;
                if (href.endsWith(target)) section = i;
              }
              expect(
                section,
                greaterThanOrEqualTo(0),
                reason: 'target $target not in spine',
              );
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
              await _openBook(tester, bookKey);
              await tester.pump(const Duration(seconds: 2));
              debugPrint(
                _describeInsets(
                  tester.element(find.byType(ReaderFushiPage)),
                  source,
                ),
              );
              expect(ReaderFushiPage.debugEvaluateJavascript, isNotNull);
              final Future<dynamic> Function(String) runJs =
                  ReaderFushiPage.debugEvaluateJavascript!;
              // Mac hidden runner：initialize 时 WKWebView 尚未有尺寸，图片盒被钉成
              // 1px；强制按当前几何重算一次，让插图按真实列高铺开再取证。
              await runJs('window.fushiReader._resetImageMaxVars()');
              await tester.pump(const Duration(seconds: 2));

              final String tag = pass.label;
              final List<String> phases = <String>[
                'open',
                ..._candidates.keys.where((String k) => k != 'current'),
                'restore',
                if (target == 'p-titlepage.xhtml') ...<String>[
                  'page2',
                  'page3',
                ],
              ];
              for (final String phase in phases) {
                if (_candidates.containsKey(phase) || phase == 'restore') {
                  final String css = _candidates[phase] ?? '';
                  await runJs(
                    "(function(){var s=document.getElementById('fushi-probe-css');"
                    "if(!s){s=document.createElement('style');s.id='fushi-probe-css';document.head.appendChild(s);}"
                    's.textContent=${jsonEncode(css)};void document.body.offsetWidth;})()',
                  );
                  await tester.pump(const Duration(seconds: 1));
                } else if (phase.startsWith('page')) {
                  await runJs('window.fushiReader.paginate("forward")');
                  await tester.pump(const Duration(seconds: 2));
                }
                final String raw = (await runJs(_probeJs)) as String;
                final Map<String, dynamic> r =
                    jsonDecode(raw) as Map<String, dynamic>;
                String rubyLine = '';
                if (target == 'p-002.xhtml') {
                  final Map<String, dynamic> rb =
                      jsonDecode((await runJs(_rubyJs)) as String)
                          as Map<String, dynamic>;
                  rubyLine = ' plain=${rb['plain']}(n=${rb['plainN']}) '
                      'ruby=${rb['ruby']}(n=${rb['rubyN']}) delta=${rb['delta']} '
                      'plainExtra=${rb['plainExtra']} rubyExtra=${rb['rubyExtra']} '
                      'firstRubyExtra=${rb['firstRubyExtra']}'
                      '(n=${rb['firstRubyExtraN']}) rtGap=${rb['rtGap']} '
                      'rtCenter=${rb['rtCenter']} rtSize=${rb['rtSize']} '
                      '(n=${rb['rtN']}) rtCss=${jsonEncode(rb['rtCss'])}';
                }
                debugPrint(
                  '[m22] SUMMARY $tag $phase zeroP=${r['zeroP']}/'
                  '${r['totalP']} lbc=${(r['html'] as Map)['lbc']} '
                  'imgMax=${jsonEncode(r['imgMax'])} '
                  'client=${jsonEncode(r['client'])}$rubyLine',
                );
                for (final String key in r.keys) {
                  final dynamic v = r[key];
                  if (v is List) {
                    for (final dynamic e in v) {
                      debugPrint('[m22] $tag $phase $key ${jsonEncode(e)}');
                    }
                  } else {
                    debugPrint('[m22] $tag $phase $key ${jsonEncode(v)}');
                  }
                }
                if (phase == 'open' || phase == 'rt-mbs-15') {
                  final ObserveShot web = await captureReaderWebView(
                    'm22-$tag-$phase-webview',
                  );
                  debugPrint('[m22] $tag $phase shot web=${web.path}');
                }
              }
              await _closeReader(tester);
            }
          } finally {
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderFontSize(originalFontSize);
            await source.setReaderLineHeight(originalLineHeight);
            if (source.tapEmptyToHideChrome != originalFloating) {
              source.toggleTapEmptyToHideChrome();
            }
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
