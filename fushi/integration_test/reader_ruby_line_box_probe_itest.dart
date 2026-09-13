import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
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
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 振假名行盒高度探针（跨引擎：Blink 基线 / WebKit 复现）。
///
/// 用户反馈：macOS / iOS 的 WKWebView（WebKit）上，带振假名的行比纯正文行更高，
/// 行距忽大忽小；Windows / Android（Blink）正常。本探针在**真阅读器**（真 CSS
/// 注入、真分页 shell、`furigana_mode=off`、`line_height=1.65`、分页，横排 / 竖排 ×
/// 字号 22 / 43 四轮，用户报的场景是竖排 + 43）里：
///
///  1. 开一本正文交替「纯文本段落」与「带 ruby 段落」（每段 3~4 行）的 EPUB；
///  2. JS 对每个段落逐字符 `Range.getClientRects()`，横排按 top 聚类得行盒，行距 =
///     相邻行 top 之差；竖排按 left 聚类得列，行距 = 前一列 left − 本列 left（跨栏的
///     负跳变丢弃），取段落中位数；再按段落种类取中位数；
///  3. 依次向 `<head>` 追加 `<style id="probe">`（每个候选换掉上一个）再量一遍：
///       * baseline —— 不注入；
///       * C1 `ruby, rt { line-height: 1 !important; }`
///       * C2 `html { -webkit-line-box-contain: block replaced !important; }`
///       * C3 `html { -webkit-line-box-contain: block glyphs replaced !important; }`
///       * C4 `rt { line-height: 1 !important; } ruby { line-height: 1 !important; }
///             body { line-height: 1.9 !important; }`
///  4. 每个 case 打一行
///     `[ruby-line-box] engine=<UA 摘要> pass=<h22|h43|v22|v43> case=<名> plain=<px> ruby=<px> delta=<px>`
///     并抓一张 WebView 截图（`observe-b-<pass>-<case>-webview.png`，Mac 抓不到时只记
///     saved=false、不判红）。
///
/// 断言只做「探针跑通、每个 case 都量到了数值、基线两类段落都至少 2 行」——**不断言
/// WebKit 结论**：本机（Windows/Blink）只能证明 Blink 基线 delta，WebKit 数值要在
/// Mac 上跑同一份文件读日志。改过的偏好在 `finally` 还原，`#probe` 样式在退出前移除。
///
/// Run on Windows (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_ruby_line_box_probe_itest.dart
///
/// Run on the Mac (PowerShell, from the repo root; the target must be COMMITTED
/// first —— run_mac_itest.ps1 把已提交历史同步到 Mac 并 ff 到 origin/develop，
/// 所以本文件所在提交要先能被 Mac 拿到）：
///   .\tool\run_mac_itest.ps1 integration_test/reader_ruby_line_box_probe_itest.dart
/// 然后在输出里 grep `[ruby-line-box]`。

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
          '[ruby-line-box] $label ready after ${i * step.inMilliseconds}ms');
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

// ── 素材：纯文本段 / ruby 段交替 ────────────────────────────────────────

const String _plainA = '桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。古い木の扉を押し開けると、'
    '埃の匂いと紙の香りが混ざり合った空気が流れ出てきた。窓から差し込む午後の光が、'
    '本棚の間を縫うように伸びていた。少年は息を殺して、その光の道を辿った。図書館の'
    '奥には、誰も近寄らない古びた書架があった。そこには、背表紙の文字も読めないほど'
    '古い本が並んでいた。少年が一冊の本を手に取ると、ページの間から小さな鍵が落ちた。';

const String _rubyA =
    '<ruby>桜<rt>さくら</rt></ruby>の<ruby>花<rt>はな</rt></ruby>が咲き始めた頃、'
    '<ruby>少年<rt>しょうねん</rt></ruby>は初めてその<ruby>図書館<rt>としょかん</rt>'
    '</ruby>を訪れた。古い<ruby>木<rt>き</rt></ruby>の<ruby>扉<rt>とびら</rt></ruby>'
    'を押し開けると、<ruby>埃<rt>ほこり</rt></ruby>の匂いと<ruby>紙<rt>かみ</rt>'
    '</ruby>の香りが混ざり合った<ruby>空気<rt>くうき</rt></ruby>が流れ出てきた。'
    '<ruby>窓<rt>まど</rt></ruby>から差し込む<ruby>午後<rt>ごご</rt></ruby>の'
    '<ruby>光<rt>ひかり</rt></ruby>が、<ruby>本棚<rt>ほんだな</rt></ruby>の間を'
    '縫うように伸びていた。<ruby>少年<rt>しょうねん</rt></ruby>は<ruby>息<rt>いき'
    '</rt></ruby>を殺して、その光の<ruby>道<rt>みち</rt></ruby>を辿った。'
    '<ruby>図書館<rt>としょかん</rt></ruby>の<ruby>奥<rt>おく</rt></ruby>には、'
    '誰も近寄らない古びた<ruby>書架<rt>しょか</rt></ruby>があった。そこには、'
    '<ruby>背表紙<rt>せびょうし</rt></ruby>の<ruby>文字<rt>もじ</rt></ruby>も'
    '読めないほど古い<ruby>本<rt>ほん</rt></ruby>が並んでいた。';

const String _plainB = '彼は鍵を握りしめ、図書館の中を探索し始めた。廊下の突き当たりに、見覚えのない'
    '扉を見つけた。扉の向こうには、想像もしなかった世界が広がっていた。空は紫色で、'
    '二つの月が浮かんでいた。風が吹くたびに、木々の葉が音楽を奏でた。まるで森全体が'
    '一つの楽器のようだった。小さな川のほとりに座って、少年は持ってきた本を開いた。'
    '物語の中の世界と、今いる世界が重なって見えた。日が暮れ始めると、森の中に小さな'
    '灯りが点り始めた。';

const String _rubyB =
    '<ruby>彼<rt>かれ</rt></ruby>は<ruby>鍵<rt>かぎ</rt></ruby>を握りしめ、'
    '<ruby>図書館<rt>としょかん</rt></ruby>の中を<ruby>探索<rt>たんさく</rt></ruby>'
    'し始めた。<ruby>廊下<rt>ろうか</rt></ruby>の突き当たりに、見覚えのない'
    '<ruby>扉<rt>とびら</rt></ruby>を見つけた。扉の向こうには、<ruby>想像<rt>そうぞう'
    '</rt></ruby>もしなかった<ruby>世界<rt>せかい</rt></ruby>が広がっていた。'
    '<ruby>空<rt>そら</rt></ruby>は<ruby>紫色<rt>むらさきいろ</rt></ruby>で、二つの'
    '<ruby>月<rt>つき</rt></ruby>が浮かんでいた。<ruby>風<rt>かぜ</rt></ruby>が吹く'
    'たびに、<ruby>木々<rt>きぎ</rt></ruby>の<ruby>葉<rt>は</rt></ruby>が'
    '<ruby>音楽<rt>おんがく</rt></ruby>を奏でた。まるで<ruby>森全体<rt>もりぜんたい'
    '</rt></ruby>が一つの<ruby>楽器<rt>がっき</rt></ruby>のようだった。小さな'
    '<ruby>川<rt>かわ</rt></ruby>のほとりに座って、<ruby>少年<rt>しょうねん</rt>'
    '</ruby>は持ってきた<ruby>本<rt>ほん</rt></ruby>を開いた。';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _buildProbeEpub() {
  const String title = '行盒高さ探針';
  final StringBuffer body = StringBuffer();
  // ruby 段放最前：每轮截图只抓首屏，首屏必须看得到注音（C2 等候选在竖排下
  // 是否把注音塌进基字列要靠截图判）。
  const List<List<String>> paragraphs = <List<String>>[
    <String>['ruby', _rubyA],
    <String>['plain', _plainA],
    <String>['ruby', _rubyB],
    <String>['plain', _plainB],
    <String>['ruby', _rubyA],
    <String>['plain', _plainA],
    <String>['ruby', _rubyB],
    <String>['plain', _plainB],
  ];
  for (int i = 0; i < paragraphs.length; i++) {
    body.writeln('  <p id="lb${i + 1}" data-kind="${paragraphs[i][0]}">'
        '${paragraphs[i][1]}</p>');
  }
  final String chapter = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head>
  <meta charset="UTF-8"/>
  <title>$title</title>
</head>
<body>
  <h1>$title</h1>
$body</body>
</html>''';
  const String opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:ruby-line-box-probe-itest-001</dc:identifier>
    <dc:title>Ruby Line Box Probe Book</dc:title>
    <dc:language>ja</dc:language>
    <dc:creator>Hibiki Test Suite</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="chapter_01.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>''';
  const String ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:ruby-line-box-probe-itest-001"/>
  </head>
  <docTitle><text>Ruby Line Box Probe Book</text></docTitle>
  <navMap>
    <navPoint id="nav1" playOrder="1">
      <navLabel><text>$title</text></navLabel>
      <content src="chapter_01.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
  const String container = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  final Archive archive = Archive();
  void add(String name, String content, {bool compress = true}) {
    final Uint8List bytes = _utf8(content);
    archive.addFile(
      ArchiveFile(name, bytes.length, bytes)..compress = compress,
    );
  }

  add('mimetype', 'application/epub+zip', compress: false);
  add('META-INF/container.xml', container);
  add('OEBPS/content.opf', opf);
  add('OEBPS/toc.ncx', ncx);
  add('OEBPS/chapter_01.xhtml', chapter);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<String> _seedProbeBook(WidgetTester tester) async {
  final AppModel appModel = await readyAppModel(tester);
  await showBooksTab(tester);
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: _buildProbeEpub(),
    fileName: 'ruby_line_box_probe.epub',
  );
  debugPrint('[ruby-line-box] seeded book key=$bookKey');
  await tester.pump(const Duration(seconds: 1));
  return bookKey;
}

// ── JS 量测 ─────────────────────────────────────────────────────────────

typedef _RunJs = Future<dynamic> Function(String source);

/// 逐段落逐字符量行盒：`p[data-kind]` 里跳过 rt/rp 的文本节点，每个字符一个
/// Range → `getClientRects()[0]`，按 top（±2px）聚类成行；行距 = 相邻行 top 之差，
/// 丢弃负跳变（分页跨栏）与超过 4×fontSize 的异常值；段落取中位数。
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
    if ((m = /AppleWebKit\/([\d.]+)/.exec(u))) {
      var v = /Version\/([\d.]+)/.exec(u);
      return 'WebKit AppleWebKit/' + m[1] + (v ? ' Version/' + v[1] : '');
    }
    return u.slice(0, 60);
  }
  var bodyCs = getComputedStyle(document.body);
  var fontSize = parseFloat(bodyCs.fontSize) || 16;
  // 竖排：一「行」是一列（同 left），行距沿 x 轴（vertical-rl 向左推进，取
  // 前一列 left − 本列 left 为正）；横排：一行同 top，行距沿 y 轴。
  var vertical = /^vertical/.test(bodyCs.writingMode || '');
  var out = { engine: ua(), ua: navigator.userAgent,
              bodyFontSize: bodyCs.fontSize, bodyLineHeight: bodyCs.lineHeight,
              bodyWritingMode: bodyCs.writingMode,
              probeCss: (document.getElementById('probe') || {}).textContent || '',
              paragraphs: [] };
  var firstRt = document.querySelector('rt');
  if (firstRt) {
    var rc = getComputedStyle(firstRt);
    out.rtCss = { display: rc.display, fontSize: rc.fontSize, lineHeight: rc.lineHeight };
    var ru = getComputedStyle(firstRt.parentNode);
    out.rubyCss = { display: ru.display, lineHeight: ru.lineHeight,
                    rubyPosition: ru.rubyPosition || ru.webkitRubyPosition || '' };
  }
  var ps = document.querySelectorAll('p[data-kind]');
  for (var i = 0; i < ps.length; i++) {
    var p = ps[i];
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
    var lines = []; // { top, bottom, left }
    var node;
    while ((node = walker.nextNode())) {
      var len = node.textContent.length;
      for (var k = 0; k < len; k++) {
        var r = document.createRange();
        r.setStart(node, k); r.setEnd(node, k + 1);
        var rects = r.getClientRects();
        if (!rects.length) continue;
        var cr = rects[0];
        if (cr.width <= 0 || cr.height <= 0) continue;
        var found = null;
        for (var L = 0; L < lines.length; L++) {
          var same = vertical
            ? (Math.abs(lines[L].left - cr.left) <= 2 && Math.abs(lines[L].top - cr.top) < 4000)
            : (Math.abs(lines[L].top - cr.top) <= 2 && Math.abs(lines[L].left - cr.left) < 4000);
          if (same) { found = lines[L]; break; }
        }
        if (found) {
          found.bottom = Math.max(found.bottom, cr.bottom);
          found.top = Math.min(found.top, cr.top);
          found.right = Math.max(found.right, cr.right);
          found.left = Math.min(found.left, cr.left);
          found.chars++;
        } else {
          lines.push({ top: cr.top, bottom: cr.bottom, left: cr.left, right: cr.right, chars: 1 });
        }
      }
    }
    // 文档序 = 出现序；相邻行 top 差为行距（同栏内为正）。
    var pitches = [];
    for (var L2 = 1; L2 < lines.length; L2++) {
      var d = vertical
        ? (lines[L2 - 1].left - lines[L2].left)
        : (lines[L2].top - lines[L2 - 1].top);
      if (d > 0 && d < fontSize * 4) pitches.push(d);
    }
    var glyphHeights = lines.map(function (l) {
      return vertical ? (l.right - l.left) : (l.bottom - l.top);
    });
    // 块轴尺寸（横排=高、竖排=宽）减去 行数×行距 = 段落里多出来的空间。WebKit 会把
    // 首行注音溢出的部分加在段落块首（首行变高），行距不变但段落更长——这就是
    // 「带振假名的段落更高」的落点；Blink 为 0。
    var pr = p.getBoundingClientRect();
    var blockSize = vertical ? pr.width : pr.height;
    var mp = median(pitches);
    var extra = mp > 0 ? (blockSize - lines.length * mp) : 0;
    out.paragraphs.push({
      id: p.id, kind: p.getAttribute('data-kind'),
      lineCount: lines.length,
      pitches: pitches.map(function (v) { return Math.round(v * 100) / 100; }),
      medianPitch: Math.round(median(pitches) * 100) / 100,
      medianGlyphHeight: Math.round(median(glyphHeights) * 100) / 100,
      pRectHeight: Math.round(pr.height * 100) / 100,
      blockSize: Math.round(blockSize * 100) / 100,
      extra: Math.round(extra * 100) / 100
    });
  }
  function kindMedian(kind) {
    var v = [];
    out.paragraphs.forEach(function (q) { if (q.kind === kind && q.medianPitch > 0) v.push(q.medianPitch); });
    return Math.round(median(v) * 100) / 100;
  }
  out.plain = kindMedian('plain');
  out.ruby = kindMedian('ruby');
  out.delta = Math.round((out.ruby - out.plain) * 100) / 100;
  function kindExtra(kind) {
    var v = [];
    out.paragraphs.forEach(function (q) { if (q.kind === kind && q.medianPitch > 0) v.push(q.extra); });
    return Math.round(median(v) * 100) / 100;
  }
  out.plainExtra = kindExtra('plain');
  out.rubyExtra = kindExtra('ruby');
  return JSON.stringify(out);
})()
''';

String _setProbeCssJs(String css) => '''
(function () {
  var el = document.getElementById('probe');
  if (!el) {
    el = document.createElement('style');
    el.id = 'probe';
    document.head.appendChild(el);
  }
  el.textContent = ${jsonEncode(css)};
  void document.body.offsetHeight;
  return el.textContent.length;
})()
''';

const String _removeProbeCssJs = r'''
(function () {
  var el = document.getElementById('probe');
  if (el) el.parentNode.removeChild(el);
  void document.body.offsetHeight;
  return !document.getElementById('probe');
})()
''';

class _LineBoxResult {
  const _LineBoxResult(this.raw);

  factory _LineBoxResult.fromRaw(Object? raw) {
    final Map<String, dynamic> m = raw is Map
        ? Map<String, dynamic>.from(raw)
        : jsonDecode(raw.toString()) as Map<String, dynamic>;
    return _LineBoxResult(m);
  }

  final Map<String, dynamic> raw;

  String get engine => raw['engine']?.toString() ?? '?';
  double get plain => (raw['plain'] as num?)?.toDouble() ?? 0;
  double get ruby => (raw['ruby'] as num?)?.toDouble() ?? 0;
  double get delta => (raw['delta'] as num?)?.toDouble() ?? 0;
  List<Map<String, dynamic>> get paragraphs => (raw['paragraphs'] as List)
      .map((dynamic e) => Map<String, dynamic>.from(e as Map))
      .toList();
  int minLines(String kind) => paragraphs
      .where((Map<String, dynamic> p) => p['kind'] == kind)
      .map((Map<String, dynamic> p) => (p['lineCount'] as num).toInt())
      .fold<int>(1 << 30, (int a, int b) => a < b ? a : b);
}

const List<MapEntry<String, String>> _cases = <MapEntry<String, String>>[
  MapEntry<String, String>('baseline', ''),
  MapEntry<String, String>('C1', 'ruby, rt { line-height: 1 !important; }'),
  MapEntry<String, String>(
      'C2', 'html { -webkit-line-box-contain: block replaced !important; }'),
  MapEntry<String, String>('C3',
      'html { -webkit-line-box-contain: block glyphs replaced !important; }'),
  MapEntry<String, String>(
      'C4',
      'rt { line-height: 1 !important; } '
          'ruby { line-height: 1 !important; } '
          'body { line-height: 1.9 !important; }'),
  MapEntry<String, String>('C5', 'rt { line-height: 1 !important; }'),
];

Future<void> _openSeededBook(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, 'reader WebView');
  await _waitFor(tester, _contentReady, 'reader content');
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ruby line-box probe: plain vs ruby line pitch under baseline and four '
    'candidate CSS overrides (engine-tagged, no WebKit assertion)',
    timeout: const Timeout(Duration(minutes: 25)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'ruby-line-box',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalMode = source.readerFuriganaMode;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final double originalLineHeight = source.readerLineHeight;
          final double originalFontSize = source.readerFontSize;
          debugPrint('[ruby-line-box] original prefs: furigana_mode='
              '$originalMode writing_mode=$originalWritingMode '
              'view_mode=$originalViewMode line_height=$originalLineHeight '
              'font_size=$originalFontSize');

          _RunJs? runJs;
          try {
            await source.setReaderViewMode('paginated');
            await source.setReaderFuriganaMode('off');
            await source.setReaderLineHeight(1.65);
            await _pumpForPref(tester);

            final String bookKey = await _seedProbeBook(tester);
            final List<String> summary = <String>[];
            // 双写向 × 双字号：用户报的场景是竖排 + 字号 43，横排 22 是 Blink 基线。
            for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
              for (final double fs in <double>[22, 43]) {
                final String pass =
                    '${wm == 'vertical-rl' ? 'v' : 'h'}${fs.round()}';
                await source.setReaderWritingMode(wm);
                await source.setReaderFontSize(fs);
                await _pumpForPref(tester);
                await _openSeededBook(tester, bookKey);
                await tester.pump(const Duration(seconds: 2));

                runJs = ReaderFushiPage.debugEvaluateJavascript;
                expect(runJs, isNotNull,
                    reason: 'reader must expose debugEvaluateJavascript');
                expect(ReaderFushiSource.readerSettings?.furiganaMode, 'off');
                expect(ReaderFushiSource.readerSettings?.lineHeight, 1.65);
                expect(ReaderFushiSource.readerSettings?.isContinuousMode,
                    isFalse);
                expect(ReaderFushiSource.readerSettings?.writingMode, wm);

                for (final MapEntry<String, String> c in _cases) {
                  if (c.value.isEmpty) {
                    await runJs!(_removeProbeCssJs);
                  } else {
                    final Object? len = await runJs!(_setProbeCssJs(c.value));
                    debugPrint('[ruby-line-box] case=${c.key} probe css set '
                        '(len=$len): ${c.value}');
                  }
                  await tester.pump(const Duration(milliseconds: 500));
                  final _LineBoxResult r =
                      _LineBoxResult.fromRaw(await runJs(_measureJs));
                  final String line = '[ruby-line-box] engine=${r.engine} '
                      'pass=$pass case=${c.key} plain=${r.plain} ruby=${r.ruby} '
                      'delta=${r.delta} blockExtra plain=${r.raw['plainExtra']} '
                      'ruby=${r.raw['rubyExtra']}';
                  debugPrint(line);
                  summary.add(line);
                  debugPrint(
                      '[ruby-line-box]   body font=${r.raw['bodyFontSize']} '
                      'lineHeight=${r.raw['bodyLineHeight']} '
                      'writingMode=${r.raw['bodyWritingMode']} '
                      'rt=${r.raw['rtCss']} ruby=${r.raw['rubyCss']}');
                  for (final Map<String, dynamic> p in r.paragraphs) {
                    debugPrint('[ruby-line-box]   ${p['id']} ${p['kind']} '
                        'lines=${p['lineCount']} medianPitch=${p['medianPitch']} '
                        'glyphH=${p['medianGlyphHeight']} '
                        'block=${p['blockSize']} extra=${p['extra']} '
                        'pitches=${p['pitches']}');
                  }
                  final ObserveShot web = await captureReaderWebView(
                      'observe-b-$pass-${c.key}-webview');
                  debugPrint(
                      '[ruby-line-box]   webview ${c.key} saved=${web.saved} '
                      'nonBlank=${web.nonBlank} path=${web.path}');

                  expect(r.plain, greaterThan(0),
                      reason:
                          'case ${c.key}: plain paragraphs must yield a pitch');
                  expect(r.ruby, greaterThan(0),
                      reason:
                          'case ${c.key}: ruby paragraphs must yield a pitch');
                  if (c.key == 'baseline') {
                    expect(r.minLines('plain'), greaterThanOrEqualTo(2),
                        reason: 'every plain paragraph must wrap to ≥2 lines '
                            '(pitch needs two line tops)');
                    expect(r.minLines('ruby'), greaterThanOrEqualTo(2),
                        reason: 'every ruby paragraph must wrap to ≥2 lines');
                  }
                }
                await runJs!(_removeProbeCssJs);
                debugPrint('[ruby-line-box] UA=${(await runJs(
                  'navigator.userAgent',
                ))}');
                await _closeReader(tester);
              }
            }
            debugPrint('[ruby-line-box] SUMMARY\n${summary.join('\n')}');
          } finally {
            try {
              await runJs?.call(_removeProbeCssJs);
            } catch (e) {
              debugPrint('[ruby-line-box] probe css removal skipped: $e');
            }
            await _closeReader(tester);
            await source.setReaderFuriganaMode(originalMode);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderLineHeight(originalLineHeight);
            await source.setReaderFontSize(originalFontSize);
            await _pumpForPref(tester);
            debugPrint('[ruby-line-box] restored prefs: furigana_mode='
                '${source.readerFuriganaMode} writing_mode='
                '${source.readerWritingMode} view_mode=${source.readerViewMode} '
                'line_height=${source.readerLineHeight} '
                'font_size=${source.readerFontSize}');
          }
        },
      );
    },
  );
}
