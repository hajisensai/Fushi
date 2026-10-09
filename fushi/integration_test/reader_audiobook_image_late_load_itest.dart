import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_audio/fushi_audio.dart'
    show
        AudioCue,
        AudioTextNormalizer,
        AudiobookRepository,
        SubtitleRematchCodec;
import 'package:fushi_core/fushi_core.dart' show EpubBookRow, FushiDatabase;
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/generate_test_image.dart' show TestImageGenerator;
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'helpers/media_fixtures.dart'
    show generateSilentAudio, kFixtureChapterHref;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 有声书跟读 × 懒加载插图 × 恢复锚（用户报：「看轻小说，横排的排版在有图片的位置
/// 播放不正常，图片会闪动，被跳过」，Windows）。
///
/// 机制：分页 shell 恢复落点（restoreToCharOffset / restoreProgress / jumpToFragment）
/// 会 `registerImageLateAnchor(...)` 登记一个「迟到图片重锚」锚；之后正文里
/// `loading="lazy"` 的 block 插图 load 时，`_sharedInitImages` 的 load 回调调
/// `reapplyImageLateAnchor()` 把视口按这个**恢复锚**重新对齐。这个锚只有用户手动翻页
/// （`paginate`）才作废；有声书「跟随音频」翻页走的是 `scrollToRange`
/// （`highlightSentenceAudioCue` → `revealElement` → `scrollToRange`；图片暂停跨图时
/// `__fushiRevealTarget` → `scrollToRange`），不作废锚。于是：
///   A. 开书落在插图前若干页 → 播放跟读逐页推进 → 前方懒图此刻才 load → 视口被拽回
///      打开本章时那页 → 下一句 cue 又翻回来 = 闪屏；
///   B. 开「图片暂停」时跨图滚到插图那页、插图恰在此后 load → 立刻被拽回恢复页，
///      暂停期间停在错页 = 「图片闪一下被跳过」。
///
/// 本测试在真实 Windows WebView2 阅读器里走生产路径复现：
///   - 自造一本单章 EPUB（纯日文正文 + 中段一张真实体量 PNG 插图，EPUB 内资源，
///     阅读器资源清洗器自动加 `loading="lazy"`），[EpubImporter.import] 导入；
///   - 静音 m4a + 每段一条 sasayaki 编码 cue（`fushi-cue://s=0&ns=…&ne=…`，text=该段
///     正文），跟随音频开；音频位置写在插图前若干页的那段 → 开书起点 = 音频 cue
///     （BUG-2390 音频为主）→ `restoreToCharOffset` 登记恢复锚；
///   - 横排（`writing_mode=horizontal-tb`）分页；
///   - 真播放（controller.play），每 ~100ms 经 [ReaderFushiPage.debugEvaluateJavascript]
///     采样页位置 / 插图是否已加载 / 是否在视口 / 当前 cue；另在 JS 里挂插图 load 的
///     「产品 load 回调之前 / 之后」两个探针，精确记录 load 那一刻视口有没有被拽走。
///
/// 判据（bug 即红）：
///   ① 跟读把页推过恢复页 P0 之后，任一采样的页位置都不得回退超过半页（音频单调前进，
///      视口只能前进；回退——尤其回到 P0——就是被恢复锚拽回）；
///   ② 插图 load 那一刻（产品 load 回调执行前后）视口不得被挪到更早的页；
///   ③ 图片暂停变体：暂停窗口内、插图 load 完成之后，插图必须保持在视口内（被拽回
///      恢复页 = 插图被跳过）。
/// 「插图始终没 load / 播放没推进过插图 / 开书时插图已加载」属于本轮不成立（几何或
/// 环境问题），同样让测试失败，但消息里标明「不成立」，与 bug 判据区分开。
///
/// 焦点驱动约束：全程不点击任何控件——开书走 [openBookViaProductionPath]（书卡 onTap
/// 同一调用），播放走有声书控制器 API，观测走 debug JS 钩子。
///
/// 运行环境：阅读器 WebView 在 Windows 上走 WebView2 CompositionController +
/// Windows.Graphics.Capture，**必须在交互桌面会话里跑**；从 ssh / session 0 进程拉起时
/// WebView2 建不出来（`Cannot create the HeadlessInAppWebView instance!`），测试会卡在
/// 「content did not become ready」。
///
/// Run (PowerShell, from fushi/, interactive desktop session):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_audiobook_image_late_load_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kLabel = 'img-late';

/// 章标题（h1 也是正文文本节点，参与 sasayaki 归一化坐标）。
const String _kChapterTitle = '第一章　挿絵のある夜';

/// 插图元素 id（探针按它找图）。
const String _kImageId = 'late-illust';

/// 几何参数：整章 [_kParagraphCount] 段；音频（= 开书起点）落在第 [_kRestoreIndex]
/// 段；插图插在第 [_kImageAfterIndex] 段之后（0 基）。两者相隔 120 段（每段约 60~80
/// 个可匹配字，≈ 8000+ 字、横排十页上下），即使 Chromium 懒加载距离取最大档
/// （offline/slow-2G 8000px）开书时插图也尚未 load。
const int _kParagraphCount = 220;
const int _kRestoreIndex = 60;
const int _kImageAfterIndex = 180;

/// 每条 cue 时长。控制器 200ms 轮询定位当前句，500ms 足够让每句都被看到。
const int _kCueMs = 500;

/// 跟读到插图后再播这么多句才停（覆盖图片暂停 + 恢复后的续读）。
const int _kCuesPastImage = 14;

/// 基础句（循环拼段；每段带唯一段号，保证 cue needle 在 JS 就近重定位时不撞车）。
const List<String> _kBaseSentences = <String>[
  '桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。',
  '古い木の扉を押し開けると、埃の匂いと紙の香りが混ざり合った空気が流れ出てきた。',
  '窓から差し込む午後の光が、本棚の間を縫うように伸びていた。',
  '図書館の奥には、誰も近寄らない古びた書架があった。',
  '少年が一冊の本を手に取ると、ページの間から小さな鍵が落ちた。',
  '彼は鍵を握りしめ、図書館の中を探索し始めた。',
  '扉の向こうには、想像もしなかった世界が広がっていた。',
  '風が吹くたびに、木々の葉が音楽を奏でた。',
  '日が暮れ始めると、森の中に小さな灯りが点り始めた。',
  '湖面に映る二つの月が、静かに揺れていた。',
  '彼女は長い間、窓の外を見つめていた。',
];

String _paragraphText(int i) {
  final int n = _kBaseSentences.length;
  return '第${i + 1}段。'
      '${_kBaseSentences[i % n]}'
      '${_kBaseSentences[(i * 3 + 1) % n]}';
}

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
      debugPrint('[$_kLabel] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail(
    '$label did not become ready within ${maxPolls * step.inMilliseconds}ms',
  );
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

/// 自造单章 EPUB：h1 + [paragraphs]，第 [imageAfterIndex] 段之后插一张 EPUB 内
/// PNG 插图（`<img src="images/late.png">`，由资源清洗器加 `loading="lazy"`）。
Uint8List _buildEpub({
  required String bookTitle,
  required String uid,
  required List<String> paragraphs,
  required int imageAfterIndex,
  required Uint8List png,
}) {
  final StringBuffer body = StringBuffer();
  body.writeln('  <h1>$_kChapterTitle</h1>');
  for (int i = 0; i < paragraphs.length; i++) {
    body.writeln('  <p id="p${i + 1}">${paragraphs[i]}</p>');
    if (i == imageAfterIndex) {
      body.writeln(
        '  <div class="illust"><img id="$_kImageId" '
        'src="images/late.png" alt="挿絵"/></div>',
      );
    }
  }
  final String chapter =
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head>
  <meta charset="UTF-8"/>
  <title>$_kChapterTitle</title>
  <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
</head>
<body>
$body</body>
</html>''';
  final String opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:$uid</dc:identifier>
    <dc:title>$bookTitle</dc:title>
    <dc:language>ja</dc:language>
    <dc:creator>Hibiki Test Suite</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
    <item id="chapter_01" href="chapter_01.xhtml" media-type="application/xhtml+xml"/>
    <item id="late_png" href="images/late.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter_01"/>
  </spine>
</package>''';
  final String ncx =
      '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:$uid"/>
  </head>
  <docTitle><text>$bookTitle</text></docTitle>
  <navMap>
    <navPoint id="nav1" playOrder="1">
      <navLabel><text>$_kChapterTitle</text></navLabel>
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
  const String css = '''
body { font-family: serif; margin: 0; padding: 0; }
h1 { font-size: 1.5em; margin-bottom: 1em; }
p { margin: 0.5em 0; }
''';

  final Archive archive = Archive();
  final List<int> mimetype = utf8.encode('application/epub+zip');
  archive.addFile(
    ArchiveFile.noCompress('mimetype', mimetype.length, mimetype),
  );
  void addText(String name, String text) {
    final List<int> bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText('META-INF/container.xml', container);
  addText('OEBPS/content.opf', opf);
  addText('OEBPS/toc.ncx', ncx);
  addText('OEBPS/stylesheet.css', css);
  addText('OEBPS/chapter_01.xhtml', chapter);
  archive.addFile(
    ArchiveFile.noCompress('OEBPS/images/late.png', png.length, png),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 与 library_fixture 同款约定：素材落 `FUSHI_TEST_ROOT/fixtures`（隔离测试根）。
Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 一次采样。
class _Sample {
  _Sample({
    required this.tMs,
    required this.cueIdx,
    required this.playing,
    required this.imagePaused,
    required this.pos,
    required this.pageSize,
    required this.loaded,
    required this.visFrac,
    required this.imgLeft,
    required this.imgWidth,
    required this.lazy,
    required this.anchor,
    required this.probeAlive,
  });

  final int tMs;
  final int cueIdx;
  final bool playing;
  final bool imagePaused;
  final double pos;
  final double pageSize;
  final bool? loaded;
  final double visFrac;
  final int? imgLeft;
  final int? imgWidth;
  final String? lazy;
  final Object? anchor;
  final bool probeAlive;

  bool get imageVisible => visFrac >= 0.5;

  String describe(double p0) {
    final String page = pageSize > 0
        ? ((pos - p0) / pageSize).toStringAsFixed(2)
        : '?';
    return 't=${tMs}ms cue=$cueIdx play=$playing imgPause=$imagePaused '
        'pos=${pos.toStringAsFixed(1)} (P0${pos >= p0 ? '+' : ''}$page页) '
        'imgLoaded=$loaded imgVis=${visFrac.toStringAsFixed(2)} '
        'imgLeft=$imgLeft imgW=$imgWidth lazy=$lazy anchor=$anchor '
        'probe=$probeAlive';
  }
}

/// 读页位置 + 插图状态。插图可见度 = 插图盒在视口（翻页轴 [0, viewportExtent)）内的
/// 面积占比；0×0（未 load 的懒图）恒为 0。`anchor` 仅作取证（读内部锚字段，缺失即 null）。
const String _kSampleJs = r'''
(function () {
  var r = window.fushiReader;
  if (!r || typeof r.getScrollContext !== 'function') return 'null';
  var c = r.getScrollContext();
  var img = document.getElementById('late-illust') || document.querySelector('img');
  var rect = img ? img.getBoundingClientRect() : null;
  var loaded = img ? (img.complete && img.naturalWidth > 0) : null;
  var ve = c.viewportExtent || (c.vertical ? window.innerHeight : window.innerWidth);
  var vis = 0;
  if (rect && rect.width > 0 && rect.height > 0) {
    var a0 = c.vertical ? rect.top : rect.left;
    var a1 = c.vertical ? rect.bottom : rect.right;
    var ov = Math.max(0, Math.min(a1, ve) - Math.max(a0, 0));
    vis = ov / Math.max(1, a1 - a0);
  }
  var anc = null;
  if (typeof r.__imgReanchorCharOffset === 'number') anc = 'char:' + r.__imgReanchorCharOffset;
  else if (typeof r.__imgReanchorProgress === 'number') anc = 'progress:' + r.__imgReanchorProgress;
  else if (r.__imgReanchorFragment) anc = 'frag:' + r.__imgReanchorFragment;
  return JSON.stringify({
    pos: r.getPagePosition(c),
    ps: c.pageSize,
    vertical: !!c.vertical,
    loaded: loaded,
    vis: vis,
    il: rect ? Math.round(c.vertical ? rect.top : rect.left) : null,
    iw: rect ? Math.round(c.vertical ? rect.height : rect.width) : null,
    lazy: img ? img.getAttribute('loading') : null,
    anc: anc,
    probe: !!window.__imgLateProbe
  });
})()
''';

/// 插图 load 探针：document 捕获阶段监听在**产品 load 回调之前**触发、img 上后注册的
/// 监听在**产品回调之后**触发——两者夹住产品的 `_sharedInitImages` load 回调，精确记录
/// load 那一刻视口是否被挪走。另记 body scroll 事件轨迹作旁证。
const String _kInstallProbeJs = r'''
(function () {
  var r = window.fushiReader;
  var img = document.getElementById('late-illust') || document.querySelector('img');
  if (!r || !img) return JSON.stringify({ok: false, hasReader: !!r, hasImg: !!img});
  var P = window.__imgLateProbe = window.__imgLateProbe || {events: [], scrolls: []};
  function pos() {
    try { return r.getPagePosition(r.getScrollContext()); } catch (e) { return -1; }
  }
  if (!window.__imgLateProbeBound) {
    window.__imgLateProbeBound = true;
    document.addEventListener('load', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') {
        P.events.push({t: Date.now(), phase: 'before-product-handler', pos: pos(),
          nw: t.naturalWidth, nh: t.naturalHeight, id: t.id || ''});
      }
    }, true);
    img.addEventListener('load', function () {
      P.events.push({t: Date.now(), phase: 'after-product-handler', pos: pos(),
        nw: img.naturalWidth, nh: img.naturalHeight, id: img.id || '',
        wrapped: !!(img.closest && img.closest('.block-img-wrapper'))});
    });
    document.body.addEventListener('scroll', function () {
      P.scrolls.push({t: Date.now(), pos: pos()});
      if (P.scrolls.length > 4000) P.scrolls.shift();
    }, {passive: true});
  }
  var rect = img.getBoundingClientRect();
  return JSON.stringify({
    ok: true,
    complete: img.complete,
    naturalWidth: img.naturalWidth,
    loading: img.getAttribute('loading'),
    imgLeft: rect.left,
    imgTop: rect.top,
    innerW: window.innerWidth,
    innerH: window.innerHeight,
    vertical: r.isVertical(),
    visibility: document.visibilityState
  });
})()
''';

const String _kReadProbeJs = r'''
JSON.stringify(window.__imgLateProbe || null)
''';

/// 一轮（一本书）的结果。
class _PhaseResult {
  _PhaseResult(this.label);

  final String label;
  final List<String> failures = <String>[];
  final List<String> timeline = <String>[];
}

Future<_PhaseResult> _runPhase(
  WidgetTester tester,
  AppModel appModel, {
  required String label,
  required int imagePauseSec,
  required int imageSeed,
}) async {
  final _PhaseResult result = _PhaseResult(label);
  final FushiDatabase db = appModel.database;
  final String tag = '[$_kLabel/$label]';

  // ── 造书 ──────────────────────────────────────────────────────────────
  final List<String> paragraphs = <String>[
    for (int i = 0; i < _kParagraphCount; i++) _paragraphText(i),
  ];
  final Uint8List png = const TestImageGenerator().pngBytes(
    width: 800,
    height: 1200,
    seed: imageSeed,
  );
  final String bookTitle = 'Image Late Anchor $label';
  final Uint8List epub = _buildEpub(
    bookTitle: bookTitle,
    uid: 'itest-image-late-anchor-$label',
    paragraphs: paragraphs,
    imageAfterIndex: _kImageAfterIndex,
    png: png,
  );
  final String bookKey = await EpubImporter.import(
    db: db,
    bytes: epub,
    fileName: 'image_late_anchor_$label.epub',
  );
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  expect(row, isNotNull, reason: '$tag imported book row must exist');
  debugPrint(
    '$tag book=$bookKey chapters=${row!.chapterCount} png=${png.length}B',
  );
  expect(
    row.chapterCount,
    1,
    reason: '$tag fixture must be a single-chapter book (spine index 0)',
  );

  // ── 音频 + cue（每段一条 sasayaki 编码 cue，text=该段正文）─────────────────
  final Directory dir = await _fixturesDir();
  final String audioPath = '${dir.path}${Platform.pathSeparator}$bookKey.m4a';
  final File audioFile = await generateSilentAudio(
    outPath: audioPath,
    duration: Duration(milliseconds: _kParagraphCount * _kCueMs + 5000),
  );
  int running = AudioTextNormalizer.normalize(_kChapterTitle).length;
  final List<AudioCue> cues = <AudioCue>[];
  for (int i = 0; i < paragraphs.length; i++) {
    final int len = AudioTextNormalizer.normalize(paragraphs[i]).length;
    cues.add(
      AudioCue()
        ..bookKey = bookKey
        ..chapterHref = kFixtureChapterHref
        ..sentenceIndex = i
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: 0,
          normCharStart: running,
          normCharEnd: running + len,
        )
        ..text = paragraphs[i]
        ..startMs = i * _kCueMs
        ..endMs = (i + 1) * _kCueMs
        ..audioFileIndex = 0,
    );
    running += len;
  }
  final AudiobookRepository audio = AudiobookRepository(db);
  await audio.replaceAlignment(
    bookKey: bookKey,
    format: 'srt',
    path: audioPath,
  );
  await audio.replaceAudio(
    bookKey: bookKey,
    audioPaths: <String>[audioFile.path],
  );
  await audio.saveCues(bookKey: bookKey, cues: cues);
  await audio.updateFollowAudio(bookKey: bookKey, value: true);
  await audio.updateImagePauseSec(bookKey: bookKey, sec: imagePauseSec);
  // 音频位置 = 开书起点（BUG-2390 音频为主）：落在插图前 60 段那一段。
  await audio.updatePositionMs(
    bookKey: bookKey,
    positionMs: cues[_kRestoreIndex].startMs + 100,
  );

  // ── 开书 ──────────────────────────────────────────────────────────────
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, '$label WebView');
  await _waitFor(tester, _contentReady, '$label content');
  AudiobookPlayerController? ctrl;
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final AudiobookPlayerController? c = appModel.audiobookSession.controller;
    if (c != null && c.chapterCueCount > 0) {
      ctrl = c;
      break;
    }
  }
  expect(ctrl, isNotNull, reason: '$tag audiobook controller must attach');
  final AudiobookPlayerController controller = ctrl!;
  debugPrint(
    '$tag controller attached cueCount=${controller.chapterCueCount} '
    'idx=${controller.currentCueIdx} follow=${controller.followAudio.value} '
    'imagePauseSec=${controller.imagePauseSec.value}',
  );
  // 恢复落定 + 首轮 chrome inset 重锚跑完。
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }

  final Future<dynamic> Function(String)? runJs =
      ReaderFushiPage.debugEvaluateJavascript;
  expect(runJs, isNotNull, reason: '$tag debugEvaluateJavascript hook');

  Future<Map<String, dynamic>?> sampleJs() async {
    final dynamic raw = await ReaderFushiPage.debugEvaluateJavascript!(
      _kSampleJs,
    );
    if (raw is! String || raw == 'null') return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  final Object? probeSetupRaw = await runJs!(_kInstallProbeJs);
  debugPrint('$tag probe install: $probeSetupRaw');
  final Map<String, dynamic> probeSetup =
      jsonDecode(probeSetupRaw as String) as Map<String, dynamic>;
  expect(probeSetup['ok'], isTrue, reason: '$tag probe must find reader+img');
  expect(
    probeSetup['vertical'],
    isFalse,
    reason: '$tag reader must render horizontal-tb for this repro',
  );
  expect(
    ReaderFushiSource.readerSettings?.isContinuousMode ?? false,
    isFalse,
    reason: '$tag reader must be in paginated mode',
  );

  final Map<String, dynamic>? s0 = await sampleJs();
  expect(s0, isNotNull, reason: '$tag initial sample');
  final double p0 = (s0!['pos'] as num).toDouble();
  final double pageSize = (s0['ps'] as num).toDouble();
  debugPrint(
    '$tag RESTORE P0=$p0 pageSize=$pageSize (page≈${(p0 / pageSize).toStringAsFixed(2)}) '
    'imgLoaded=${s0['loaded']} imgLeft=${s0['il']} lazy=${s0['lazy']} '
    'anchor=${s0['anc']} cueIdx=${controller.currentCueIdx}',
  );
  if (p0 <= 0) {
    result.failures.add(
      '$tag setup: 开书没有落在音频 cue（第 $_kRestoreIndex 段）所在页，P0=$p0',
    );
    return result;
  }
  if (s0['loaded'] == true) {
    result.failures.add(
      '$tag setup: 开书时插图已加载（imgLeft=${s0['il']}，pageSize=$pageSize），'
      '懒加载距离覆盖到了插图，无法复现「迟到 load」——需把插图放得更远',
    );
    return result;
  }

  // ── 播放 + 采样 ───────────────────────────────────────────────────────
  const int targetCue = _kImageAfterIndex + _kCuesPastImage;
  final Duration budget = Duration(
    milliseconds:
        (targetCue - _kRestoreIndex) * _kCueMs + imagePauseSec * 1000 + 25000,
  );
  final List<_Sample> samples = <_Sample>[];
  final Stopwatch sw = Stopwatch()..start();
  final int startEpochMs = DateTime.now().millisecondsSinceEpoch;
  unawaited(controller.play());
  String? lastKey;
  while (sw.elapsed < budget) {
    await tester.pump(const Duration(milliseconds: 100));
    final Map<String, dynamic>? m = await sampleJs();
    if (m == null) continue;
    final _Sample s = _Sample(
      tMs: sw.elapsedMilliseconds,
      cueIdx: controller.currentCueIdx,
      playing: controller.isPlaying,
      imagePaused: controller.isImagePaused,
      pos: (m['pos'] as num).toDouble(),
      pageSize: (m['ps'] as num).toDouble(),
      loaded: m['loaded'] as bool?,
      visFrac: (m['vis'] as num?)?.toDouble() ?? 0,
      imgLeft: (m['il'] as num?)?.toInt(),
      imgWidth: (m['iw'] as num?)?.toInt(),
      lazy: m['lazy'] as String?,
      anchor: m['anc'],
      probeAlive: m['probe'] == true,
    );
    samples.add(s);
    final String key =
        '${s.pos.round()}|${s.loaded}|${s.imageVisible}|${s.cueIdx}|'
        '${s.imagePaused}|${s.playing}';
    if (key != lastKey) {
      lastKey = key;
      final String line = s.describe(p0);
      result.timeline.add(line);
      debugPrint('$tag $line');
    }
    if (s.cueIdx >= targetCue && !s.imagePaused) break;
  }
  await controller.pause();
  await tester.pump(const Duration(milliseconds: 300));

  // ── 探针事件 ──────────────────────────────────────────────────────────
  final Object? probeRaw = await runJs(_kReadProbeJs);
  final Map<String, dynamic>? probe = probeRaw is String && probeRaw != 'null'
      ? jsonDecode(probeRaw) as Map<String, dynamic>
      : null;
  final List<dynamic> events =
      (probe?['events'] as List<dynamic>?) ?? <dynamic>[];
  final List<dynamic> scrolls =
      (probe?['scrolls'] as List<dynamic>?) ?? <dynamic>[];
  for (final dynamic e in events) {
    final Map<String, dynamic> ev = e as Map<String, dynamic>;
    final int rel = (ev['t'] as num).toInt() - startEpochMs;
    final String line =
        'IMG-LOAD t=${rel}ms phase=${ev['phase']} pos=${ev['pos']} '
        'natural=${ev['nw']}x${ev['nh']} id=${ev['id']} '
        'wrapped=${ev['wrapped']}';
    result.timeline.add(line);
    debugPrint('$tag $line');
  }
  final StringBuffer scrollTrail = StringBuffer();
  for (final dynamic e in scrolls) {
    final Map<String, dynamic> sc = e as Map<String, dynamic>;
    scrollTrail.write(
      '${(sc['t'] as num).toInt() - startEpochMs}:${sc['pos']} ',
    );
  }
  debugPrint('$tag body scroll trail (t:pos) = $scrollTrail');

  // ── 判据 ──────────────────────────────────────────────────────────────
  expect(
    samples.length,
    greaterThan(20),
    reason: '$tag sampling must actually run',
  );
  final int maxCue = samples.fold<int>(
    -1,
    (int a, _Sample s) => s.cueIdx > a ? s.cueIdx : a,
  );
  if (maxCue <= _kImageAfterIndex) {
    result.failures.add(
      '$tag 播放没有推进过插图（最大 cue=$maxCue，插图在第 $_kImageAfterIndex 段后）'
      '——音频未真正播放，本轮不成立',
    );
  }

  // ① 跟读推过 P0 之后页位置不得回退。
  double maxPos = p0;
  _Sample? maxAt;
  for (final _Sample s in samples) {
    if (s.pos > maxPos + 1) {
      maxPos = s.pos;
      maxAt = s;
      continue;
    }
    if (maxPos > p0 + 1 && s.pos < maxPos - s.pageSize * 0.5) {
      final bool atP0 = (s.pos - p0).abs() <= 2;
      result.failures.add(
        '$tag ① 跟读推进后页位置回退：已到 pos=${maxPos.toStringAsFixed(1)}'
        '（${maxAt?.describe(p0)}）后回到 pos=${s.pos.toStringAsFixed(1)}'
        '${atP0 ? '＝恢复页 P0（被恢复锚拽回）' : ''}；'
        '回退那一帧：${s.describe(p0)}',
      );
      break;
    }
  }

  // ② 插图 load 那一刻视口不得被挪到更早的页。
  final List<Map<String, dynamic>> loadEvents = events
      .cast<Map<String, dynamic>>()
      .where((Map<String, dynamic> e) => e['id'] == _kImageId)
      .toList();
  final Map<String, dynamic>? before = loadEvents
      .where((Map<String, dynamic> e) => e['phase'] == 'before-product-handler')
      .firstOrNull;
  final Map<String, dynamic>? after = loadEvents
      .where((Map<String, dynamic> e) => e['phase'] == 'after-product-handler')
      .firstOrNull;
  if (before == null || after == null) {
    result.failures.add(
      '$tag 本轮不成立：插图 load 探针未触发（before=$before after=$after），'
      '插图在本轮始终没有 load 或探针失效',
    );
  } else {
    final double pb = (before['pos'] as num).toDouble();
    final double pa = (after['pos'] as num).toDouble();
    debugPrint(
      '$tag ② load moment: pos before product handler=$pb, after=$pa, P0=$p0',
    );
    if (pa < pb - pageSize * 0.5) {
      result.failures.add(
        '$tag ② 插图 load 回调把视口从 pos=$pb 拽到 pos=$pa'
        '${(pa - p0).abs() <= 2 ? '＝恢复页 P0' : ''}（迟到图片重锚仍按开书恢复锚生效）',
      );
    }
  }

  // ③ 图片暂停变体：暂停窗口内、插图 load 完成之后，插图保持可见。插图经 Dart 拦截层
  // 回传、解码需要时间，load 之前的 0 尺寸占位帧不计；load 后留 300ms 给重排 / 重锚落定。
  if (imagePauseSec > 0) {
    final List<_Sample> paused = samples
        .where((_Sample s) => s.imagePaused)
        .toList();
    if (paused.isEmpty) {
      result.failures.add('$tag 本轮不成立：③ 图片暂停从未触发（跨图检测未命中）');
    } else {
      final _Sample? firstLoaded = paused
          .where((_Sample s) => s.loaded == true)
          .firstOrNull;
      if (firstLoaded == null) {
        result.failures.add(
          '$tag 本轮不成立：③ 图片暂停窗口内插图始终没 load（${paused.length} 帧）',
        );
      } else {
        final List<_Sample> settled = paused
            .where((_Sample s) => s.tMs >= firstLoaded.tMs + 300)
            .toList();
        final List<_Sample> hidden = settled
            .where((_Sample s) => !s.imageVisible)
            .toList();
        debugPrint(
          '$tag ③ image pause window: ${paused.length} samples, '
          'image loaded at t=${firstLoaded.tMs}ms, ${settled.length} settled, '
          '${hidden.length} with image off-screen',
        );
        if (settled.isNotEmpty && hidden.isNotEmpty) {
          result.failures.add(
            '$tag ③ 图片暂停窗口内插图 load 后不在视口'
            '（${hidden.length}/${settled.length} 帧不可见，插图被跳过）；'
            '首个不可见帧：${hidden.first.describe(p0)}',
          );
        }
      }
    }
  }

  final _Sample? firstLoadedSample = samples
      .where((_Sample s) => s.loaded == true)
      .firstOrNull;
  debugPrint(
    '$tag SUMMARY P0=$p0 pageSize=$pageSize maxPos=$maxPos '
    'maxCue=$maxCue imageFirstSeenLoaded='
    '${firstLoadedSample?.describe(p0) ?? 'never'} '
    'loadEvents=${loadEvents.length} failures=${result.failures.length}',
  );

  await _closeReader(tester);
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'audiobook follow + lazy illustration: a late image load must not yank '
    'the page back to the restore anchor (horizontal paginated)',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: _kLabel,
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          // 横排分页（默认 vertical-rl / paginated）。开书前写偏好，开书即按横排排版。
          await appModel.database.setPref(
            'src:reader_fushi:writing_mode',
            'horizontal-tb',
          );
          await appModel.database.setPref(
            'src:reader_fushi:view_mode',
            'paginated',
          );
          await ReaderFushiSource.readerSettings?.refreshFromDb();

          final List<_PhaseResult> results = <_PhaseResult>[];
          try {
            // A：图片暂停关 —— 跟读逐页推进，前方懒图迟到 load。
            results.add(
              await _runPhase(
                tester,
                appModel,
                label: 'follow',
                imagePauseSec: 0,
                imageSeed: 7,
              ),
            );
            // B：图片暂停开 —— 跨图滚到插图、插图此后才 load。
            results.add(
              await _runPhase(
                tester,
                appModel,
                label: 'imagePause',
                imagePauseSec: 5,
                imageSeed: 11,
              ),
            );
          } finally {
            await _closeReader(tester);
          }

          final List<String> failures = <String>[
            for (final _PhaseResult r in results) ...r.failures,
          ];
          debugPrint('[$_kLabel] ===== VERDICT =====');
          for (final _PhaseResult r in results) {
            debugPrint('[$_kLabel/${r.label}] failures=${r.failures.length}');
            for (final String f in r.failures) {
              debugPrint('[$_kLabel/${r.label}] FAIL $f');
            }
          }
          expect(
            failures,
            isEmpty,
            reason:
                '有声书跟读中迟到加载的插图把视口拽回了开书恢复锚（闪屏 / 插图被跳过）：\n'
                '${failures.join('\n')}',
          );
        },
      );
    },
  );
}
