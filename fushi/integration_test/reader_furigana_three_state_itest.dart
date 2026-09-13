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

/// 振假名四态（`src:reader_fushi:furigana_mode` =
/// `off` / `toggle` / `hidden` / `dimmed`）真 app 证据（Windows 离屏 runner，
/// 真 WebView2 + 真分页 JS + 真 CSS 注入）。文件名保留 `three_state`（docs 里
/// 有引用），覆盖面已是四态。
///
/// 被测契约（`ReaderContentStyles._furiganaCss` + `fushiSelection.selectText`）：
///  1. `toggle`：未揭示 `<ruby>` 的 `rt` 是 `visibility:hidden`、ruby 带灰色虚线下划线
///     （`text-decoration-style: dotted`）、无 `furigana-revealed` class；
///  2. 点该 ruby（`selectText(x, y, 50, false)`）只揭示：class 加上、rt 变 `visible`，
///     **不查词**——判据是 JS 侧 `window.flutter_inappwebview.callHandler` 的探针
///     计数（`onTextSelected` / `onTapEmpty` 都为 0）加 `fushiSelection.selection`
///     仍为 null；Dart 侧 `_handleTextSelected` 是私有方法、查词弹窗也没有稳定 key，
///     而 `callHandler('onTextSelected')` 正是 JS→Dart 唯一的查词入口，探针计数是
///     最贴近真实路径的可观察点；
///  3. 再点同一点走正常查词：`onTextSelected` 计数 +1、`selection.text` 非空；
///  4. 热切到 `hidden`（`setReaderFuriganaMode` → `onSettingsChangedLive`，与设置页
///     `notifyReaderSettingsChanged` 同一条路）：rt `display:none`；再热切到 `off`：
///     rt `visibility:visible` 且 ruby 无虚线下划线；
///  5. 热切到 `dimmed`：rt 仍 `display:ruby-text`（结构与 `off` 一致，不是隐藏），
///     但 `opacity` 被淡到 0.45；`body.show-all-rt`（readerToggleFurigana 快捷键
///     在此态的语义 = 临时恢复全亮）把 opacity 拉回 1；切回 `off` opacity 回到 1；
///  6. 偏好在 `finally` 还原。
///
/// 素材是本文件现生成的一本**横排分页**单章 EPUB，正文前几段混有 `<ruby>…<rt>…</rt>
/// </ruby>`（首屏即可命中，不依赖任何章节导航）。全程不点控件：开书走
/// [openBookViaProductionPath]，其余经 debug 钩子 / JS。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_furigana_three_state_itest.dart

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
      debugPrint('[furigana3] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail('$label did not become ready within '
      '${maxPolls * step.inMilliseconds}ms');
}

/// 让 fire-and-forget 的偏好 setter 落地。
Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

// ── 素材：横排分页单章 EPUB，段首混 ruby ────────────────────────────────

const List<String> _rubyParagraphs = <String>[
  '「<ruby>漢字<rt>かんじ</rt></ruby>の<ruby>勉強<rt>べんきょう</rt></ruby>は'
      '<ruby>楽<rt>たの</rt></ruby>しい。」と<ruby>少年<rt>しょうねん</rt></ruby>は'
      '言った。桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。',
  '古い木の扉を押し開けると、<ruby>埃<rt>ほこり</rt></ruby>の匂いと'
      '<ruby>紙<rt>かみ</rt></ruby>の香りが混ざり合った空気が流れ出てきた。'
      '窓から差し込む午後の光が、本棚の間を縫うように伸びていた。',
  '<ruby>図書館<rt>としょかん</rt></ruby>の奥には、誰も近寄らない古びた書架が'
      'あった。そこには、<ruby>背表紙<rt>せびょうし</rt></ruby>の文字も読めない'
      'ほど古い本が並んでいた。',
  '少年が一冊の本を手に取ると、ページの間から小さな<ruby>鍵<rt>かぎ</rt></ruby>'
      'が落ちた。銀色に光るその鍵は、どこかの扉を開けるもののようだった。',
  '彼は鍵を握りしめ、図書館の中を探索し始めた。廊下の突き当たりに、見覚えの'
      'ない<ruby>扉<rt>とびら</rt></ruby>を見つけた。',
  '扉の向こうには、想像もしなかった世界が広がっていた。空は紫色で、二つの'
      '<ruby>月<rt>つき</rt></ruby>が浮かんでいた。',
];

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _buildFuriganaEpub() {
  final StringBuffer body = StringBuffer();
  for (int i = 0; i < _rubyParagraphs.length; i++) {
    body.writeln('  <p id="p${i + 1}">${_rubyParagraphs[i]}</p>');
  }
  const String title = '振り仮名三態テスト';
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
    <dc:identifier id="uid">urn:uuid:furigana-three-state-itest-001</dc:identifier>
    <dc:title>Furigana Three State Book</dc:title>
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
    <meta name="dtb:uid" content="urn:uuid:furigana-three-state-itest-001"/>
  </head>
  <docTitle><text>Furigana Three State Book</text></docTitle>
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

Future<String> _seedFuriganaBook(WidgetTester tester) async {
  final AppModel appModel = await readyAppModel(tester);
  await showBooksTab(tester);
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: _buildFuriganaEpub(),
    fileName: 'furigana_three_state.epub',
  );
  debugPrint('[furigana3] seeded book key=$bookKey');
  await tester.pump(const Duration(seconds: 1));
  return bookKey;
}

// ── JS 探针 ─────────────────────────────────────────────────────────────

typedef _RunJs = Future<dynamic> Function(String source);

/// 一次性包一层 `flutter_inappwebview.callHandler`，按 handler 名计数——
/// `onTextSelected` 是 JS→Dart 唯一的查词入口，`onTapEmpty` 是「点空白」入口。
const String _installSpyJs = r'''
(function () {
  if (window.__furiganaSpy) return 'already';
  var spy = { onTextSelected: 0, onTapEmpty: 0, other: 0 };
  window.__furiganaSpy = spy;
  var bridge = window.flutter_inappwebview;
  if (!bridge || typeof bridge.callHandler !== 'function') return 'no-bridge';
  var orig = bridge.callHandler;
  bridge.callHandler = function () {
    var name = arguments[0];
    if (name === 'onTextSelected' || name === 'onTapEmpty') spy[name]++;
    else spy.other++;
    return orig.apply(bridge, arguments);
  };
  return 'installed';
})()
''';

/// 采样第 [index] 个带 `<rt>` 的 ruby（DOM 顺序）：rt/ruby 计算样式、揭示 class、
/// 基字文本节点的视口矩形中心（点击坐标用基字而不是整个 ruby 盒的中心：ruby 盒
/// 含注音轨，其几何中心可能落在 rt 与基字的交界上）、探针计数与 JS 选区。
String _probeJs(int index) => '''
(function () {
  var rubies = Array.prototype.filter.call(
      document.querySelectorAll('ruby'),
      function (r) { return r.querySelector('rt') !== null; });
  var ruby = rubies[$index] || null;
  if (!ruby) return JSON.stringify({ found: false, rubyCount: rubies.length });
  var rt = ruby.querySelector('rt');
  var baseNode = null;
  for (var i = 0; i < ruby.childNodes.length; i++) {
    var n = ruby.childNodes[i];
    if (n.nodeType === 3 && n.textContent.trim()) { baseNode = n; break; }
  }
  var range = document.createRange();
  if (baseNode) range.selectNodeContents(baseNode); else range.selectNode(ruby);
  var br = range.getBoundingClientRect();
  var rr = ruby.getBoundingClientRect();
  var rtCs = getComputedStyle(rt);
  var rubyCs = getComputedStyle(ruby);
  var sel = window.fushiSelection ? window.fushiSelection.selection : undefined;
  return JSON.stringify({
    found: true,
    rubyCount: rubies.length,
    baseText: baseNode ? baseNode.textContent : ruby.textContent,
    rtText: rt.textContent,
    revealed: ruby.classList.contains('furigana-revealed'),
    rtVisibility: rtCs.visibility,
    rtDisplay: rtCs.display,
    rtOpacity: rtCs.opacity,
    rubyDecorationLine: rubyCs.textDecorationLine,
    rubyDecorationStyle: rubyCs.textDecorationStyle,
    baseCx: (br.left + br.right) / 2,
    baseCy: (br.top + br.bottom) / 2,
    baseRect: [br.left, br.top, br.width, br.height],
    rubyRect: [rr.left, rr.top, rr.width, rr.height],
    inViewport: br.width > 0 && br.height > 0 && br.left >= 0 && br.top >= 0 &&
        br.right <= window.innerWidth && br.bottom <= window.innerHeight,
    spy: window.__furiganaSpy || null,
    selectionText: sel ? sel.text : null,
    hasSelection: !!sel,
    styleHasToggleRule: (function () {
      var el = document.getElementById('fushi-reader-style');
      return !!(el && el.textContent.indexOf('furigana-revealed') >= 0);
    })()
  });
})()
''';

class _RubyProbe {
  const _RubyProbe(this.raw);

  factory _RubyProbe.fromRaw(Object? raw) {
    final Map<String, dynamic> m = raw is Map
        ? Map<String, dynamic>.from(raw)
        : jsonDecode(raw.toString()) as Map<String, dynamic>;
    return _RubyProbe(m);
  }

  final Map<String, dynamic> raw;

  bool get found => raw['found'] == true;
  int get rubyCount => (raw['rubyCount'] as num?)?.toInt() ?? 0;
  String get baseText => raw['baseText']?.toString() ?? '';
  String get rtText => raw['rtText']?.toString() ?? '';
  bool get revealed => raw['revealed'] == true;
  String get rtVisibility => raw['rtVisibility']?.toString() ?? '';
  String get rtDisplay => raw['rtDisplay']?.toString() ?? '';
  double get rtOpacity =>
      double.tryParse(raw['rtOpacity']?.toString() ?? '') ?? -1;
  String get rubyDecorationLine => raw['rubyDecorationLine']?.toString() ?? '';
  String get rubyDecorationStyle =>
      raw['rubyDecorationStyle']?.toString() ?? '';
  double get baseCx => (raw['baseCx'] as num?)?.toDouble() ?? 0;
  double get baseCy => (raw['baseCy'] as num?)?.toDouble() ?? 0;
  bool get inViewport => raw['inViewport'] == true;
  int get spyTextSelected =>
      ((raw['spy'] as Map?)?['onTextSelected'] as num?)?.toInt() ?? -1;
  int get spyTapEmpty =>
      ((raw['spy'] as Map?)?['onTapEmpty'] as num?)?.toInt() ?? -1;
  bool get hasSelection => raw['hasSelection'] == true;
  String? get selectionText => raw['selectionText']?.toString();
  bool get styleHasToggleRule => raw['styleHasToggleRule'] == true;

  @override
  String toString() => 'base="$baseText" rt="$rtText" revealed=$revealed '
      'rtVisibility=$rtVisibility rtDisplay=$rtDisplay '
      'rtOpacity=$rtOpacity '
      'rubyDecoration=$rubyDecorationLine/$rubyDecorationStyle '
      'baseCenter=(${_f(baseCx)},${_f(baseCy)}) inViewport=$inViewport '
      'baseRect=${raw['baseRect']} rubyRect=${raw['rubyRect']} '
      'spy(onTextSelected=$spyTextSelected onTapEmpty=$spyTapEmpty) '
      'selection=${hasSelection ? '"$selectionText"' : 'null'} '
      'toggleCssPresent=$styleHasToggleRule rubyCount=$rubyCount';
}

Future<_RubyProbe> _probe(_RunJs runJs, int index) async =>
    _RubyProbe.fromRaw(await runJs(_probeJs(index)));

/// 轮询到 [accept] 成立（设置热切换 → CSS 换入 → 重锚是异步链，采样过渡态会把真值
/// 误判成红）。超时返回最后一次采样，由调用方断言给出真实读数。
Future<_RubyProbe> _probeUntil(
  WidgetTester tester,
  _RunJs runJs,
  int index,
  bool Function(_RubyProbe p) accept,
  String label, {
  int maxPolls = 40,
}) async {
  _RubyProbe? last;
  for (int i = 0; i < maxPolls; i++) {
    last = await _probe(runJs, index);
    if (accept(last)) {
      debugPrint('[furigana3] $label (after ${i * 250}ms): $last');
      return last;
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  debugPrint('[furigana3] $label (NOT settled after ${maxPolls * 250}ms): '
      '$last');
  return last!;
}

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

Future<void> _captureWeb(String name) async {
  final ObserveShot web = await captureReaderWebView(name);
  debugPrint('[furigana3] webview $name saved=${web.saved} '
      'nonBlank=${web.nonBlank} path=${web.path}');
  expect(web.saved, isTrue, reason: 'WebView capture $name must be saved');
}

Future<void> _captureFrame(WidgetTester tester, String name) async {
  final ObserveShot frame = await captureFlutterFrame(tester, name);
  debugPrint('[furigana3] frame $name saved=${frame.saved} '
      'nonBlank=${frame.nonBlank} path=${frame.path}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'furigana_mode four-state: toggle hides rt + dotted underline, first tap '
    'reveals without lookup, second tap looks up; hidden/off/dimmed hot-switch',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'furigana3',
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
          debugPrint('[furigana3] original prefs: furigana_mode=$originalMode '
              'writing_mode=$originalWritingMode view_mode=$originalViewMode');

          try {
            // 前置：横排分页 + toggle 态，都在开书前写好。
            await source.setReaderWritingMode('horizontal-tb');
            await source.setReaderViewMode('paginated');
            await source.setReaderFuriganaMode('toggle');
            await _pumpForPref(tester);
            expect(source.readerFuriganaMode, 'toggle');

            final String bookKey = await _seedFuriganaBook(tester);
            await _openSeededBook(tester, bookKey);
            await tester.pump(const Duration(seconds: 2));

            final _RunJs? runJs = ReaderFushiPage.debugEvaluateJavascript;
            expect(runJs, isNotNull,
                reason: 'reader must expose debugEvaluateJavascript');
            expect(ReaderFushiSource.readerSettings?.furiganaMode, 'toggle',
                reason: 'live ReaderSettings must carry the toggle mode');
            expect(ReaderFushiSource.readerSettings?.isContinuousMode, isFalse,
                reason: 'must run paginated');
            final Object? wm =
                await runJs!('getComputedStyle(document.body).writingMode');
            debugPrint('[furigana3] body writingMode=$wm');
            expect(wm.toString(), 'horizontal-tb');

            final Object? spy = await runJs(_installSpyJs);
            debugPrint('[furigana3] callHandler spy: $spy');
            expect(spy.toString(), 'installed');

            // ── 1. toggle 态基线 ────────────────────────────────────────
            final _RubyProbe s1 = await _probeUntil(
                tester, runJs, 0, (p) => p.found && p.inViewport, '1 toggle');
            expect(s1.found, isTrue,
                reason: 'book must contain <ruby> with <rt>');
            expect(s1.inViewport, isTrue,
                reason: 'first ruby must be on the first page (needed for '
                    'elementFromPoint): ${s1.raw['baseRect']}');
            expect(s1.styleHasToggleRule, isTrue,
                reason: 'injected #fushi-reader-style must carry the toggle '
                    'CSS');
            expect(s1.rtVisibility, 'hidden',
                reason: '1. toggle: unrevealed rt must be visibility:hidden');
            expect(s1.rtDisplay, 'ruby-text',
                reason:
                    '1. toggle keeps the annotation lane (not display:none)');
            expect(s1.rubyDecorationStyle, 'dotted',
                reason: '1. toggle: unrevealed ruby gets a dotted underline');
            expect(s1.rubyDecorationLine, contains('underline'));
            expect(s1.revealed, isFalse,
                reason: '1. no furigana-revealed class before tapping');
            await _captureWeb('observe-a1-toggle-hidden-webview');
            await _captureFrame(tester, 'observe-a1-toggle-hidden');

            // ── 2. 点该 ruby：只揭示、不查词 ──────────────────────────
            final double cx = s1.baseCx;
            final double cy = s1.baseCy;
            final Object? hit = await runJs(
                "(document.elementFromPoint($cx, $cy) || {}).tagName || 'none'");
            debugPrint('[furigana3] 2. elementFromPoint($cx,$cy) → $hit');
            final Object? r2 = await runJs(
                'String(window.fushiSelection.selectText($cx, $cy, 50, false))');
            debugPrint('[furigana3] 2. selectText returned $r2');
            final _RubyProbe s2 = await _probeUntil(tester, runJs, 0,
                (p) => p.revealed && p.rtVisibility == 'visible', '2 revealed');
            expect(s2.revealed, isTrue,
                reason: '2. tapping a hidden-furigana ruby must add '
                    'furigana-revealed');
            expect(s2.rtVisibility, 'visible',
                reason: '2. revealed rt must become visible');
            expect(s2.rubyDecorationLine, isNot(contains('underline')),
                reason: '2. revealed ruby drops the dotted underline');
            expect(s2.spyTextSelected, 0,
                reason: '2. reveal tap must NOT fire onTextSelected (lookup)');
            expect(s2.spyTapEmpty, 0,
                reason: '2. reveal tap must NOT fire onTapEmpty either');
            expect(s2.hasSelection, isFalse,
                reason: '2. fushiSelection.selection stays null after reveal');
            await _captureWeb('observe-a2-revealed-webview');

            // ── 3. 再点同一点：正常查词 ──────────────────────────────
            final Object? r3 = await runJs(
                'String(window.fushiSelection.selectText($cx, $cy, 50, false))');
            debugPrint('[furigana3] 3. selectText returned $r3');
            final _RubyProbe s3 = await _probeUntil(tester, runJs, 0,
                (p) => p.spyTextSelected >= 1 && p.hasSelection, '3 lookup');
            expect(s3.spyTextSelected, 1,
                reason: '3. second tap on the revealed ruby must go through '
                    'the normal lookup path (onTextSelected fired once)');
            expect(s3.hasSelection, isTrue,
                reason: '3. fushiSelection.selection must be populated');
            expect(s3.selectionText, isNotEmpty);
            expect(s3.spyTapEmpty, 0);
            expect(s3.revealed, isTrue, reason: '3. reveal state persists');
            await tester.pump(const Duration(seconds: 1));
            await _captureWeb('observe-a3-lookup-webview');
            await _captureFrame(tester, 'observe-a3-lookup');

            // ── 4a. 热切 hidden：rt display:none ───────────────────────
            await source.setReaderFuriganaMode('hidden');
            await _pumpForPref(tester);
            expect(ReaderFushiSource.readerSettings?.furiganaMode, 'hidden');
            // 第 1 个 ruby 已揭示（class 仍在）；第 2 个从未揭示——两者在 hidden
            // 态都必须 display:none（hidden 的 CSS 不看 furigana-revealed）。
            final _RubyProbe s4a0 = await _probeUntil(
                tester, runJs, 0, (p) => p.rtDisplay == 'none', '4a hidden #0');
            final _RubyProbe s4a1 = await _probeUntil(
                tester, runJs, 1, (p) => p.rtDisplay == 'none', '4a hidden #1');
            expect(s4a0.rtDisplay, 'none',
                reason: '4a. hidden: rt must be display:none (revealed ruby)');
            expect(s4a1.rtDisplay, 'none',
                reason:
                    '4a. hidden: rt must be display:none (unrevealed ruby)');
            expect(s4a1.styleHasToggleRule, isFalse,
                reason: '4a. hidden CSS must not carry the toggle rules');
            await _captureWeb('observe-a4-hidden-webview');

            // ── 4b. 热切 off：rt visible、无虚线 ─────────────────────
            await source.setReaderFuriganaMode('off');
            await _pumpForPref(tester);
            expect(ReaderFushiSource.readerSettings?.furiganaMode, 'off');
            final _RubyProbe s4b1 = await _probeUntil(
                tester,
                runJs,
                1,
                (p) =>
                    p.rtDisplay == 'ruby-text' && p.rtVisibility == 'visible',
                '4b off #1');
            final _RubyProbe s4b0 = await _probe(runJs, 0);
            debugPrint('[furigana3] 4b off #0: $s4b0');
            expect(s4b1.rtVisibility, 'visible',
                reason: '4b. off: unrevealed ruby rt must be visible');
            expect(s4b1.rtDisplay, 'ruby-text');
            expect(s4b1.rubyDecorationStyle, isNot('dotted'),
                reason: '4b. off: no dotted underline on ruby');
            expect(s4b1.rubyDecorationLine, isNot(contains('underline')));
            expect(s4b1.revealed, isFalse, reason: 'ruby #1 was never tapped');
            expect(s4b0.rtVisibility, 'visible');
            expect(s4b0.rtDisplay, 'ruby-text');
            expect(s4b1.rtOpacity, closeTo(1.0, 0.001),
                reason: '4b. off: rt 不淡显（opacity 1）');
            await _captureWeb('observe-a5-off-webview');

            // ── 4c. 热切 dimmed：结构同 off，但 opacity 淡到 0.45 ──────
            await source.setReaderFuriganaMode('dimmed');
            await _pumpForPref(tester);
            expect(ReaderFushiSource.readerSettings?.furiganaMode, 'dimmed');
            final _RubyProbe s4c1 = await _probeUntil(
                tester,
                runJs,
                1,
                (p) => p.rtDisplay == 'ruby-text' && p.rtOpacity < 0.9,
                '4c dimmed #1');
            expect(s4c1.rtDisplay, 'ruby-text',
                reason: '4c. dimmed 是「显示但淡」，注音结构必须与 off 一致，'
                    '不得退化成 display:none / visibility:hidden');
            expect(s4c1.rtVisibility, 'visible',
                reason: '4c. dimmed: rt 仍 visible');
            expect(s4c1.rtOpacity, closeTo(0.45, 0.01),
                reason: '4c. dimmed: rt 淡显到 opacity 0.45（实测 '
                    '${s4c1.rtOpacity}）');
            expect(s4c1.rubyDecorationLine, isNot(contains('underline')),
                reason: '4c. dimmed 不画 toggle 的虚线下划线');
            await _captureWeb('observe-a6-dimmed-webview');
            await _captureFrame(tester, 'observe-a6-dimmed');

            // ── 4d. dimmed 下 show-all-rt（readerToggleFurigana 快捷键的
            //        CSS 落点）= 临时恢复全亮 ─────────────────────────
            await runJs("document.body.classList.add('show-all-rt');");
            final _RubyProbe s4d = await _probeUntil(tester, runJs, 1,
                (p) => p.rtOpacity > 0.9, '4d dimmed + show-all-rt');
            expect(s4d.rtOpacity, closeTo(1.0, 0.001),
                reason: '4d. dimmed + show-all-rt 必须把 opacity 拉回 1（'
                    'readerToggleFurigana 在此态 = 临时恢复全亮），实测 '
                    '${s4d.rtOpacity}');
            expect(s4d.rtDisplay, 'ruby-text');
            await _captureWeb('observe-a7-dimmed-show-all-webview');
            await runJs("document.body.classList.remove('show-all-rt');");

            // ── 4e. 切回 off：opacity 回到 1 ─────────────────────────
            await source.setReaderFuriganaMode('off');
            await _pumpForPref(tester);
            expect(ReaderFushiSource.readerSettings?.furiganaMode, 'off');
            final _RubyProbe s4e = await _probeUntil(
                tester,
                runJs,
                1,
                (p) => p.rtDisplay == 'ruby-text' && p.rtOpacity > 0.9,
                '4e back to off');
            expect(s4e.rtOpacity, closeTo(1.0, 0.001),
                reason: '4e. 切回 off 后淡显必须完全撤掉（opacity 1），实测 '
                    '${s4e.rtOpacity}');
            expect(s4e.rtDisplay, 'ruby-text');
            expect(s4e.rtVisibility, 'visible');
            await _captureWeb('observe-a8-off-again-webview');

            debugPrint('[furigana3] PASS: toggle(hidden rt, dotted) → tap '
                'reveals w/o lookup → tap looks up → hidden(display:none) → '
                'off(visible, no underline) → dimmed(opacity 0.45) → '
                'show-all-rt(opacity 1) → off(opacity 1)');
          } finally {
            await _closeReader(tester);
            await source.setReaderFuriganaMode(originalMode);
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await _pumpForPref(tester);
            debugPrint('[furigana3] restored prefs: furigana_mode='
                '${source.readerFuriganaMode} writing_mode='
                '${source.readerWritingMode} view_mode=${source.readerViewMode}');
          }
        },
      );
    },
  );
}

String _f(dynamic v) {
  if (v is num) return v.toStringAsFixed(2);
  return v.toString();
}
