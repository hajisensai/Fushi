// 官网 fushi.moe 首页的「App 全貌」截图与「实机录屏」由这一份测试驱动真 app 产出。
//
// 不是回归测试：它把每个版本的真界面拍下来交给官网。入口是
// tool/site_previews/record_site_previews.ps1（准备夹具、置顶停靠、跑 runner、
// 后期缩放 / 混音 / 拷进官网仓），一般不直接跑本文件。
//
// 输入全部经 --dart-define：
//   SITE_PREVIEW_OUT      原始产物目录（overview-*.png、<场景>.mp4 与 <场景>.timeline.json）
//   SITE_PREVIEW_DEMO     官网 demo 夹具目录（tool/site_previews/extract_demo_fixtures.dart）
//   SITE_PREVIEW_LIBRARY  公有领域库素材目录（tool/site_previews/fetch_library_fixtures.dart）
//   SITE_PREVIEW_ONLY     逗号分隔的场景名（overview,video,manga,gal,audiobook,selftest），空 = 除 selftest 外全部
//
// 场景里的「点击」都走与真实输入同一条查词 / 制卡链路（视频 debugLookupAt、阅读器与
// 漫画在 WebView 里派发真点击、制卡点弹窗里真的 + 按钮），指针是 SitePreviewCursor
// 画上去的（用户 2026-10-27 拍板：录制时不动真鼠标）。制卡打到测试内的假 AnkiConnect。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebView;
import 'package:fushi/src/lookup/sentence_extraction.dart'
    show lookupQueryFromIndex;
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show DictionaryPopupLayer;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebView, DictionaryPopupWebViewState;
import 'package:fushi/src/pages/implementations/home_page.dart' show HomePage;
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show HomeVideoPage;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'helpers/library_fixture.dart';
import 'support/fake_ankiconnect.dart';
import 'support/fake_ankiconnect_setup.dart';
import 'support/site_preview_library_seed.dart';
import 'support/site_preview_recorder.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kOut = String.fromEnvironment('SITE_PREVIEW_OUT');
const String _kDemo = String.fromEnvironment('SITE_PREVIEW_DEMO');
const String _kLibrary = String.fromEnvironment('SITE_PREVIEW_LIBRARY');
const String _kOnly = String.fromEnvironment('SITE_PREVIEW_ONLY');

/// 录屏场景的窗口客户区（逻辑像素）；官网成片就是这个比例。
const Size _kSceneSize = Size(1280, 720);

/// 漫画场景的客户区：单张竖版页（约 0.7 宽高比）加顶上一点余量，不留大黑边。
const Size _kMangaSceneSize = Size(760, 1000);

/// 「App 全貌」截图的客户区（逻辑像素），与官网 <img width/height> 一致。
const Size _kOverviewSize = Size(1440, 900);

bool _wants(String scene) {
  if (_kOnly.isEmpty) return scene != 'selftest';
  return _kOnly.split(',').map((String s) => s.trim()).contains(scene);
}

// ───────────────────────────── 窗口 / 抓图 ─────────────────────────────

/// 把客户区调成 [logical]。setSize 设的是外框，客户区更小，按实测差补一次。
Future<PhysicalRect> _resizeClient(WidgetTester tester, Size logical) async {
  Size target = logical;
  for (int attempt = 0; attempt < 3; attempt++) {
    await windowManager.setSize(target);
    await tester.pump(const Duration(milliseconds: 900));
    final double dpr = tester.view.devicePixelRatio;
    final Size client = tester.view.physicalSize / dpr;
    final Size delta = Size(
      logical.width - client.width,
      logical.height - client.height,
    );
    debugPrint(
      '[site-preview] resize try=$attempt target=$target client=$client',
    );
    if (delta.width.abs() < 1 && delta.height.abs() < 1) break;
    target = Size(target.width + delta.width, target.height + delta.height);
  }
  await tester.pump(const Duration(milliseconds: 600));
  final PhysicalRect? rect = findOwnMainWindowClientRect();
  debugPrint('[site-preview] client rect=$rect');
  expect(rect, isNotNull, reason: '找不到本进程的主窗口');
  return rect!;
}

/// 根 RenderView 抓一帧写 PNG（Flutter 自绘面；全貌页里没有 WebView）。
Future<void> _saveFrame(WidgetTester tester, File out) async {
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final ui.Image image = await layer.toImage(
    view.paintBounds,
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final ByteData png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    await out.writeAsBytes(png.buffer.asUint8List(), flush: true);
    debugPrint(
      '[site-preview] saved ${out.path} ${image.width}x${image.height}',
    );
  } finally {
    image.dispose();
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
  String what = '',
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) fail('等待超时：$what');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _hold(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// ───────────────────────────── 定位 ─────────────────────────────

/// 文本 [needle] 里第 [index] 个字在屏幕上的矩形（全局逻辑坐标）。
///
/// 字幕这类可点字的文本常拆成逐词 / 逐字的多个段落排版，所以按树序把所有已排版段落
/// 的文字拼起来找 [needle]，再落回命中那个字所在的段落取字形框。
Rect? _paragraphCharRect(WidgetTester tester, String needle, int index) {
  final List<RenderParagraph> paragraphs = <RenderParagraph>[];
  void visit(RenderObject o) {
    if (o is RenderParagraph && o.attached && o.hasSize) paragraphs.add(o);
    o.visitChildren(visit);
  }

  tester.binding.renderViews.first.visitChildren(visit);
  final List<String> texts = <String>[
    for (final RenderParagraph r in paragraphs) r.text.toPlainText(),
  ];
  final int at = texts.join().lastIndexOf(needle);
  if (at < 0) return null;
  int offset = at + index;
  for (int i = 0; i < paragraphs.length; i++) {
    if (offset < texts[i].length) {
      final List<TextBox> boxes = paragraphs[i].getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      );
      if (boxes.isEmpty) return null;
      return boxes.first.toRect().shift(
        paragraphs[i].localToGlobal(Offset.zero),
      );
    }
    offset -= texts[i].length;
  }
  return null;
}

/// 查词弹窗里已有词条的那一个 WebView。
Future<DictionaryPopupWebViewState?> _waitPopupWithEntries(
  WidgetTester tester,
) async {
  for (int i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    for (final Element e
        in find
            .byType(DictionaryPopupWebView, skipOffstage: false)
            .evaluate()) {
      final DictionaryPopupWebViewState s =
          (e as StatefulElement).state as DictionaryPopupWebViewState;
      final Object? n = await s.debugEval(
        "(window.__fushiRoot||document).querySelectorAll('.entry').length",
      );
      if ((int.tryParse('$n') ?? 0) > 0) return s;
    }
  }
  return null;
}

/// 录制前先把同一个词查一遍再关掉：查词缓存与弹窗 WebView 热槽都热好，录进去的那次
/// 点击一按就出词条——冷启动时弹窗要先建 WebView、跑首查，画面上会先空白一会儿。
Future<void> _prewarmLookup(
  WidgetTester tester,
  String what,
  Future<void> Function() lookup, {
  Future<void> Function()? close,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  await lookup();
  final DictionaryPopupWebViewState? popup = await _waitPopupWithEntries(
    tester,
  );
  expect(popup, isNotNull, reason: '$what 预热查词应出词条');
  debugPrint('[site-preview] $what prewarm lookup ${sw.elapsedMilliseconds}ms');
  await _hold(tester, const Duration(milliseconds: 600));
  if (close != null) {
    await close();
  } else {
    // 走弹窗右上角 × 的同一条关闭汇聚点（onPop(0) 清整栈）。Escape 在视频页上
    // 不稳定（实测一次没关掉，预热弹窗挂在成片开头）。
    for (final DictionaryPopupLayer layer
        in tester
            .widgetList<DictionaryPopupLayer>(
              find.byType(DictionaryPopupLayer, skipOffstage: false),
            )
            .toList()
            .reversed) {
      layer.onClose?.call();
    }
  }
  await _hold(tester, const Duration(milliseconds: 1200));
  debugPrint(
    '[site-preview] $what prewarm closed; layers='
    '${find.byType(DictionaryPopupLayer, skipOffstage: false).evaluate().length}',
  );
}

/// 录制中的那次查词：等词条出现，并把「点下 → 词条出现」这段等待记成剪辑点。
///
/// 所有者 2026-10-27：成片里弹窗要一点就出，可以剪辑——后期剪掉这段，画面上点下去
/// 下一帧就是词条（冷查时的空白卡 / 检索中 / 未找到这些过渡帧一并剪掉）。
Future<DictionaryPopupWebViewState?> _timedPopup(
  WidgetTester tester,
  String what,
  Stopwatch sinceClick,
  SitePreviewTimeline tl,
) async {
  final DictionaryPopupWebViewState? popup = await _waitPopupWithEntries(
    tester,
  );
  // DOM 里有词条不等于画完：后续词条还在往里排（实测游戏段剪辑点后仍有 0.4 秒
  // 在逐条长出来）。等内容高度与词条数连续稳定，再留一点淡入时间才接回画面。
  if (popup != null) {
    String last = '';
    int stable = 0;
    final Stopwatch settle = Stopwatch()..start();
    while (stable < 3 && settle.elapsed.inMilliseconds < 2500) {
      final String now =
          '${await popup.debugEval("(()=>{const r=window.__fushiRoot||document;"
          "const s=document.scrollingElement||document.documentElement;"
          "return r.querySelectorAll('.entry').length+':'+s.scrollHeight;})()")}';
      stable = now == last ? stable + 1 : 0;
      last = now;
      await _hold(tester, const Duration(milliseconds: 80));
    }
  }
  await _hold(tester, const Duration(milliseconds: 200));
  final int entriesAt = _sinceStart(tl.recording);
  final int clickAt = entriesAt - sinceClick.elapsedMilliseconds;
  tl.cut(clickAt + 120, entriesAt);
  debugPrint(
    '[site-preview] $what lookup->entries ${sinceClick.elapsedMilliseconds}ms '
    '(cut ${clickAt + 120}..$entriesAt)',
  );
  return popup;
}

/// 弹窗里第一个词条的「+」制卡钮中心（全局逻辑坐标）。
Future<Offset?> _mineButtonCenter(DictionaryPopupWebViewState popup) async {
  final Object? raw = await popup.debugEval('''JSON.stringify((() => {
    const b = (window.__fushiRoot||document).querySelector('.entry .mine-button');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return {x: r.left + r.width / 2, y: r.top + r.height / 2};
  })())''');
  if (raw == null || '$raw' == 'null') return null;
  final Map<String, Object?> m = jsonDecode('$raw') as Map<String, Object?>;
  final RenderBox box = popup.context.findRenderObject()! as RenderBox;
  return box.localToGlobal(
    Offset((m['x']! as num).toDouble(), (m['y']! as num).toDouble()),
  );
}

/// 指针移到弹窗「+」并点下（真点 DOM 里的按钮），等假 AnkiConnect 收到卡。
Future<void> _mineFromPopup(
  WidgetTester tester,
  SitePreviewCursor cursor,
  DictionaryPopupWebViewState popup,
  FakeAnkiConnect anki,
) async {
  final int before = anki.notes.length;
  final Offset? target = await _mineButtonCenter(popup);
  if (target != null) {
    await cursor.moveTo(tester, target);
    await cursor.click(
      tester,
      onDown: () async {
        await popup.debugEval(
          "(window.__fushiRoot||document).querySelector('.entry .mine-button').click()",
        );
      },
    );
  } else {
    debugPrint('[site-preview] 弹窗里没有 .mine-button，直接走 mineEntryByIndex');
    await popup.mineEntryByIndex(0, releaseWhenPayloadConsumed: true);
  }
  await _waitFor(
    tester,
    () => anki.notes.length > before,
    timeout: const Duration(seconds: 40),
    what: '假 AnkiConnect 收到 addNote',
  );
}

/// WebView（阅读器 / 漫画）视口里一个字的中心：返回 {x,y}（CSS px，视口坐标）。
String _textPointJs(String needle, int index) =>
    '''
JSON.stringify((() => {
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  let n;
  while ((n = w.nextNode())) {
    const t = n.nodeValue || '';
    let i = t.indexOf(${jsonEncode(needle)});
    while (i >= 0) {
      const r = document.createRange();
      r.setStart(n, i + $index); r.setEnd(n, i + $index + 1);
      for (const b of r.getClientRects()) {
        if (b.width > 1 && b.height > 1 && b.right > 0 && b.bottom > 0 &&
            b.left < innerWidth && b.top < innerHeight) {
          return {x: (b.left + b.right) / 2, y: (b.top + b.bottom) / 2};
        }
      }
      i = t.indexOf(${jsonEncode(needle)}, i + 1);
    }
  }
  return null;
})())''';

String _dispatchClickJs(double x, double y) =>
    '''
(() => {
  const t = document.elementFromPoint($x, $y) || document.body;
  const init = {bubbles: true, cancelable: true, view: window, clientX: $x, clientY: $y, button: 0};
  t.dispatchEvent(new PointerEvent('pointerdown', Object.assign({pointerType: 'mouse', pointerId: 7, isPrimary: true, buttons: 1}, init)));
  t.dispatchEvent(new PointerEvent('pointerup', Object.assign({pointerType: 'mouse', pointerId: 7, isPrimary: true, buttons: 0}, init)));
  t.dispatchEvent(new MouseEvent('click', Object.assign({detail: 1}, init)));
  return 'ok';
})()''';

Offset _webViewToGlobal(
  WidgetTester tester,
  Finder webView,
  Map<String, Object?> pt,
) {
  final RenderBox box = tester.renderObject<RenderBox>(webView);
  return box.localToGlobal(
    Offset((pt['x']! as num).toDouble(), (pt['y']! as num).toDouble()),
  );
}

// ───────────────────────────── 夹具 ─────────────────────────────

Map<String, Object?> _demoJson() =>
    jsonDecode(File(p.join(_kDemo, 'demo.json')).readAsStringSync())
        as Map<String, Object?>;

String _demoPath(String rel) => p.normalize(p.join(_kDemo, rel));

Future<void> _importDemoDictionaries(AppModel appModel) async {
  final Directory dir = Directory(p.join(_kDemo, 'dict'));
  final List<File> zips =
      dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.zip'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File zip in zips) {
    final ValueNotifier<String> progress = ValueNotifier<String>('');
    try {
      await appModel.importDictionary(
        file: zip,
        progressNotifier: progress,
        onImportSuccess: () {},
      );
    } finally {
      progress.dispose();
    }
  }
  debugPrint(
    '[site-preview] dictionaries=${appModel.dictionaries.length}'
    ' (zips=${zips.length})',
  );
}

Directory _scratch(String name) {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory d = Directory(
    p.join(
      testRoot.isEmpty ? Directory.systemTemp.path : testRoot,
      'site-preview',
      name,
    ),
  )..createSync(recursive: true);
  return d;
}

// ───────────────────────────── 场景 ─────────────────────────────

class _Ctx {
  _Ctx(this.tester, this.appModel, this.anki, this.out);

  final WidgetTester tester;
  final AppModel appModel;
  final FakeAnkiConnect anki;
  final Directory out;

  NavigatorState get nav => appModel.navigatorKey.currentState!;

  Future<(SitePreviewRecording, SitePreviewTimeline, SitePreviewCursor)> begin(
    String scene,
    PhysicalRect rect,
    Offset cursorAt,
  ) async {
    final SitePreviewCursor cursor = SitePreviewCursor.attach(tester);
    cursor.show(cursorAt);
    await tester.pump(const Duration(milliseconds: 100));
    final SitePreviewRecording rec = await SitePreviewRecording.start(
      rect: rect,
      output: File(p.join(out.path, '$scene.mp4')),
    );
    return (rec, SitePreviewTimeline(rec), cursor);
  }

  Future<void> end(
    String scene,
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor, {
    required int posterMs,
    Size outSize = _kSceneSize,
  }) async {
    final int code = await rec.stop();
    cursor.dispose();
    expect(code, 0, reason: '$scene 录屏 ffmpeg 应正常收尾');
    tl.extra['posterMs'] = posterMs;
    tl.extra['trimStartMs'] = 300;
    tl.extra['outWidth'] = outSize.width.round();
    tl.extra['outHeight'] = outSize.height.round();
    await tl.write(File(p.join(out.path, '$scene.timeline.json')));
  }
}

int _sinceStart(SitePreviewRecording rec) =>
    DateTime.now().difference(rec.startedAt).inMilliseconds;

/// 视频：字幕上点「大好き」→ 弹窗 → + 制卡。
Future<void> _sceneVideo(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final Map<String, Object?> demo = _demoJson();
  final Map<String, Object?> preset =
      (demo['presetLookups']! as List<Object?>).first! as Map<String, Object?>;
  final String sentence = preset['sentence']! as String;
  final int charIndex = preset['charIndex']! as int;
  final int length = preset['length']! as int;
  final int cueStart = preset['cueStartMs']! as int;
  final String title = (preset['miscInfo'] as String?) ?? 'Fushi demo';

  // sidecar 字幕与视频同名同目录。
  final Directory dir = _scratch('video');
  final File video = File(
    _demoPath('video/demo.mp4'),
  ).copySync(p.join(dir.path, 'clip.mp4'));
  File(_demoPath('video/demo.srt')).copySync(p.join(dir.path, 'clip.srt'));
  final VideoBookRepository repo = VideoBookRepository(c.appModel.database);
  final String uid = singleVideoBookUid(video.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(title),
      videoPath: Value(video.absolute.path),
    ),
  );

  unawaited(
    c.nav.push(
      MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
      ),
    ),
  );
  VideoFushiTestHooks hooks() =>
      tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
          as VideoFushiTestHooks;
  await _waitFor(
    tester,
    () =>
        find.byType(VideoFushiPage).evaluate().isNotEmpty &&
        hooks().debugPositionMs != null &&
        hooks().debugCueCount > 0,
    what: '视频页就绪',
  );
  final PhysicalRect rect = await _resizeClient(tester, _kSceneSize);
  await hooks().debugPause();
  await _prewarmLookup(
    tester,
    'video',
    () => hooks().debugLookupAt(sentence, charIndex),
  );
  await hooks().debugPause();
  final int playFrom = (cueStart - 3200).clamp(0, 1 << 30);
  await hooks().debugSeekMs(playFrom);
  await _hold(tester, const Duration(milliseconds: 1500));

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'video',
    rect,
    const Offset(1060, 560),
  );
  await _hold(tester, const Duration(milliseconds: 500));
  tl.playAudio(video.path, fromMs: playFrom);
  await hooks().debugPlay();
  // 播到目标句出现后再多播 0.9 秒，暂停。
  await _waitFor(
    tester,
    () => (hooks().debugPositionMs ?? 0) > cueStart + 900,
    what: '播到目标字幕',
  );
  await hooks().debugPause();
  tl.stopAudio();
  await _hold(tester, const Duration(milliseconds: 500));

  final String word = sentence.substring(charIndex, charIndex + length);
  final Rect? wordRect = _paragraphCharRect(tester, word, 0);
  debugPrint('[site-preview] video word=$word rect=$wordRect');
  expect(wordRect, isNotNull, reason: '字幕上应能定位到「$word」');
  // 弹窗按被点字的真实字形框定位（钩子默认锚点是固定占位矩形）。
  final Rect anchor = _paragraphCharRect(tester, word, 0)!;
  await cursor.moveTo(tester, anchor.center + const Offset(4, 6));
  final Stopwatch clickAt = Stopwatch();
  await cursor.click(
    tester,
    onDown: () {
      clickAt.start();
      return hooks().debugLookupAt(sentence, charIndex, anchor: anchor);
    },
  );
  final DictionaryPopupWebViewState? popup = await _timedPopup(
    tester,
    'video',
    clickAt,
    tl,
  );
  expect(popup, isNotNull, reason: '视频查词弹窗应出词条');
  final int posterMs = _sinceStart(rec) + 1200;
  await _hold(tester, const Duration(milliseconds: 2600));
  await _mineFromPopup(tester, cursor, popup!, c.anki);
  await _hold(tester, const Duration(milliseconds: 2400));
  await c.end('video', rec, tl, cursor, posterMs: posterMs);
  c.nav.pop();
  await _hold(tester, const Duration(seconds: 1));
}

/// 阅读 + 有声书：朗读几句、句子高亮，点「わたしたち」→ 弹窗 → + 制卡。
Future<void> _sceneAudiobook(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final Map<String, Object?> book =
      _demoJson()['book']! as Map<String, Object?>;
  final List<Map<String, Object?>> cues = <Map<String, Object?>>[
    for (final Object? e
        in jsonDecode(
              File(_demoPath(book['cues']! as String)).readAsStringSync(),
            )
            as List<Object?>)
      e! as Map<String, Object?>,
  ];
  const String target = 'わたしたち';
  final int targetCue = cues.indexWhere(
    (Map<String, Object?> q) => (q['text']! as String).contains(target),
  );
  expect(targetCue, greaterThanOrEqualTo(0), reason: '正文应含「$target」');

  // 正文：两句一段，便于竖排翻页里成段落。
  final StringBuffer body = StringBuffer();
  for (int i = 0; i < cues.length; i += 2) {
    body.write('<p>');
    for (int j = i; j < cues.length && j < i + 2; j++) {
      body.write(const HtmlEscape().convert(cues[j]['text']! as String));
    }
    body.write('</p>');
  }
  final Uint8List epub = EpubBuilder.assemble(
    title: '安達としまむら',
    uidPrefix: 'site-preview-abook-',
    chapterXhtmls: <String>[
      '<?xml version="1.0" encoding="utf-8"?>'
          '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">'
          '<head><title>安達としまむら</title></head><body>$body</body></html>',
    ],
  );
  await showBooksTab(tester);
  final String bookKey = await EpubImporter.import(
    db: c.appModel.database,
    bytes: epub,
    fileName: 'site_preview_abook.epub',
  );
  final File audio = File(_demoPath(book['audio']! as String));
  int norm = 0;
  final List<AudioCue> audioCues = <AudioCue>[];
  for (int i = 0; i < cues.length; i++) {
    final String text = cues[i]['text']! as String;
    final int len = AudioTextNormalizer.normalize(text).length;
    audioCues.add(
      AudioCue()
        ..bookKey = bookKey
        ..chapterHref = 'chapter-1.xhtml'
        ..sentenceIndex = i
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: 0,
          normCharStart: norm,
          normCharEnd: norm + len,
        )
        ..text = text
        ..startMs = cues[i]['startMs']! as int
        ..endMs = cues[i]['endMs']! as int
        ..audioFileIndex = 0,
    );
    norm += len;
  }
  final AudiobookRepository repo = AudiobookRepository(c.appModel.database);
  await repo.replaceAlignment(
    bookKey: bookKey,
    format: 'srt',
    path: audio.path,
  );
  await repo.replaceAudio(bookKey: bookKey, audioPaths: <String>[audio.path]);
  await repo.saveCues(bookKey: bookKey, cues: audioCues);
  await repo.updateFollowAudio(bookKey: bookKey, value: true);
  await ReaderFushiSource.instance.setReaderWritingMode('vertical-rl');

  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('fushi_content_ready'))
        .evaluate()
        .isNotEmpty,
    timeout: const Duration(seconds: 60),
    what: '阅读器正文就绪',
  );
  AudiobookPlayerController? ctrl() => c.appModel.audiobookSession.controller;
  await _waitFor(
    tester,
    () => (ctrl()?.chapterCueCount ?? 0) > 0,
    timeout: const Duration(seconds: 40),
    what: '有声书控制器挂上',
  );
  final PhysicalRect rect = await _resizeClient(tester, _kSceneSize);
  await _hold(tester, const Duration(milliseconds: 1500));
  final Finder webView = find.byKey(const ValueKey<String>('fushi_webview'));
  final Future<dynamic> Function(String)? eval =
      ReaderFushiPage.debugEvaluateJavascript;
  Future<Map<String, Object?>> targetPoint() async {
    final Object? raw = await eval!(_textPointJs(target, 0));
    expect(raw, isNotNull, reason: '正文里应能定位到「$target」');
    return jsonDecode('$raw') as Map<String, Object?>;
  }

  Future<void> clickTarget(Map<String, Object?> pt) async => eval!(
    _dispatchClickJs(
      (pt['x']! as num).toDouble(),
      (pt['y']! as num).toDouble(),
    ),
  );
  await _prewarmLookup(
    tester,
    'audiobook',
    () async => clickTarget(await targetPoint()),
  );
  await ctrl()!.pause();
  await ctrl()!.skipToCueIndex(0);
  await _hold(tester, const Duration(milliseconds: 1500));

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'audiobook',
    rect,
    const Offset(1100, 600),
  );
  await _hold(tester, const Duration(milliseconds: 500));
  tl.playAudio(audio.path, fromMs: cues.first['startMs']! as int);
  unawaited(ctrl()!.play());
  await _waitFor(
    tester,
    () => (ctrl()?.currentCueIdx ?? 0) > targetCue,
    timeout: const Duration(seconds: 30),
    what: '朗读过目标句',
  );
  await _hold(tester, const Duration(milliseconds: 600));
  await ctrl()!.pause();
  tl.stopAudio();
  await _hold(tester, const Duration(milliseconds: 500));

  final Map<String, Object?> pt = await targetPoint();
  await cursor.moveTo(
    tester,
    _webViewToGlobal(tester, webView, pt) + const Offset(4, 6),
  );
  final Stopwatch clickAt = Stopwatch();
  await cursor.click(
    tester,
    onDown: () async {
      clickAt.start();
      await clickTarget(pt);
    },
  );
  final DictionaryPopupWebViewState? popup = await _timedPopup(
    tester,
    'audiobook',
    clickAt,
    tl,
  );
  expect(popup, isNotNull, reason: '阅读器查词弹窗应出词条');
  final int posterMs = _sinceStart(rec) + 1200;
  await _hold(tester, const Duration(milliseconds: 2600));
  await _mineFromPopup(tester, cursor, popup!, c.anki);
  await _hold(tester, const Duration(milliseconds: 2400));
  await c.end('audiobook', rec, tl, cursor, posterMs: posterMs);
  c.nav.pop();
  await _hold(tester, const Duration(seconds: 1));
}

/// 漫画：点 OCR 气泡里的「お正月」→ 弹窗 → + 制卡。
Future<void> _sceneManga(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final Object? ocr = jsonDecode(
    File(_demoPath('manga/ocr.json')).readAsStringSync(),
  );
  final List<Map<String, Object?>> pages = <Map<String, Object?>>[
    for (final Object? e
        in (ocr is Map<String, Object?>
            ? ocr['pages']! as List<Object?>
            : ocr! as List<Object?>))
      e! as Map<String, Object?>,
  ];
  final Directory dir = _scratch('manga');
  final Directory images = Directory(p.join(dir.path, 'images'))..createSync();
  final List<Map<String, Object?>> payloadPages = <Map<String, Object?>>[];
  for (final Map<String, Object?> page in pages) {
    final String name = page['image']! as String;
    File(_demoPath('manga/$name')).copySync(p.join(images.path, name));
    payloadPages.add(<String, Object?>{
      'url': name,
      'width': page['width'],
      'height': page['height'],
      'blocks': <Object?>[
        for (final Object? b in page['blocks']! as List<Object?>)
          () {
            final Map<String, Object?> block = b! as Map<String, Object?>;
            final List<Object?> box = block['box']! as List<Object?>;
            final List<String> lines = <String>[
              for (final Object? l in block['lines']! as List<Object?>) '$l',
            ];
            final bool vertical = block['vertical'] == true;
            final double extent =
                (vertical
                        ? (box[2]! as num) - (box[0]! as num)
                        : (box[3]! as num) - (box[1]! as num))
                    .toDouble();
            return <String, Object?>{
              'box': box,
              'vertical': vertical,
              'font_size': (extent / lines.length).round(),
              'z_index': 0,
              'lines': lines,
            };
          }(),
      ],
    });
  }
  File(
    p.join(dir.path, 'manga.json'),
  ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': payloadPages}));
  const String bookKey = 'site-preview-manga';
  await c.appModel.database.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'ドラえもん',
      epubPath: 'manga.json',
      extractDir: dir.path,
      chapterCount: payloadPages.length,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      format: const Value<String>('manga'),
    ),
  );
  final EpubBookRow book = (await c.appModel.database.getEpubBook(bookKey))!;
  await c.appModel.database.setMangaReaderOverride(book.uid, <String, Object?>{
    'mode': 'single',
    'autoMode': false,
    'direction': 'rtl',
    'ocrTrigger': 'manual',
  });

  final BuildContext navContext = c.nav.context;
  unawaited(
    c.nav.push(
      adaptivePageRoute<void>(
        context: navContext,
        builder: (BuildContext context) => const FushiAppUiScaleNeutralizer(
          child: MangaFushiPage(item: null, bookKey: bookKey),
        ),
      ),
    ),
  );
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('manga_content_ready'))
        .evaluate()
        .isNotEmpty,
    what: '漫画阅读页就绪',
  );
  // 竖版单页：窗口按页面比例开，16:9 会在页两侧留出大片黑边。
  final PhysicalRect rect = await _resizeClient(tester, _kMangaSceneSize);
  await _hold(tester, const Duration(milliseconds: 2500));
  final dynamic reader = tester.state(find.byType(MangaFushiPage));
  final Finder webView = find.descendant(
    of: find.byType(MangaFushiPage),
    matching: find.byType(InAppWebView),
  );
  // 「お正月」在 .ocr-char 拼出的文字里的第一个字。
  Future<Map<String, Object?>> targetPoint() async {
    final Object? raw =
        await reader.debugEvaluateJavascript('''JSON.stringify((() => {
    const cs = Array.from(document.querySelectorAll('.ocr-char'));
    const s = cs.map(e => e.textContent).join('');
    const i = s.indexOf('お正月');
    if (i < 0) return null;
    const r = cs[i].getBoundingClientRect();
    return {x: r.left + r.width / 2, y: r.top + r.height / 2};
  })())''')
            as Object?;
    expect(raw, isNotNull, reason: 'OCR 字格里应能定位到「お正月」');
    return jsonDecode('$raw') as Map<String, Object?>;
  }

  Future<void> tapTarget(Map<String, Object?> pt) async =>
      reader.debugEvaluateJavascript(
        'window.__mangaBarrierTapAt(${pt['x']}, ${pt['y']})',
      );
  await _prewarmLookup(
    tester,
    'manga',
    () async => tapTarget(await targetPoint()),
  );

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'manga',
    rect,
    Offset(_kMangaSceneSize.width - 90, _kMangaSceneSize.height - 140),
  );
  await _hold(tester, const Duration(milliseconds: 900));
  final Map<String, Object?> pt = await targetPoint();
  await cursor.moveTo(
    tester,
    _webViewToGlobal(tester, webView.first, pt) + const Offset(4, 6),
    duration: const Duration(milliseconds: 900),
  );
  final Stopwatch clickAt = Stopwatch();
  await cursor.click(
    tester,
    onDown: () async {
      clickAt.start();
      await tapTarget(pt);
    },
  );
  final DictionaryPopupWebViewState? popup = await _timedPopup(
    tester,
    'manga',
    clickAt,
    tl,
  );
  expect(popup, isNotNull, reason: '漫画查词弹窗应出词条');
  final int posterMs = _sinceStart(rec) + 1200;
  await _hold(tester, const Duration(milliseconds: 2600));
  await _mineFromPopup(tester, cursor, popup!, c.anki);
  await _hold(tester, const Duration(milliseconds: 2400));
  await c.end(
    'manga',
    rec,
    tl,
    cursor,
    posterMs: posterMs,
    outSize: _kMangaSceneSize,
  );
  c.nav.pop();
  await _hold(tester, const Duration(seconds: 1));
}

/// 游戏：替身游戏画面（官网 demo 截图 + 台词框）上点「意味不明」→ 标准查词弹窗 → + 制卡。
///
/// 真游戏里的卡片是贴在游戏窗口上的原生 WebView2 窗口，测试复现不了；所有者
/// 2026-10-27 说过游戏段「只需要换一下弹窗」——画面用 demo 截图，弹窗是真的。
Future<void> _sceneGal(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final Map<String, Object?> gal = _demoJson()['gal']! as Map<String, Object?>;
  final Map<String, Object?> line =
      (gal['lineDetails']! as List<Object?>).first! as Map<String, Object?>;
  final String text = line['text']! as String;
  final Map<String, Object?> geo =
      gal['textCellGeometryPercent']! as Map<String, Object?>;
  const String word = '意味不明';
  final int index = text.indexOf(word);
  final SrsCardLookupController lookup = SrsCardLookupController();
  unawaited(
    c.nav.push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => _StandInGamePage(
          background: File(_demoPath(gal['background']! as String)),
          controller: lookup,
        ),
        transitionDuration: Duration.zero,
      ),
    ),
  );
  final PhysicalRect rect = await _resizeClient(tester, _kSceneSize);
  await _hold(tester, const Duration(milliseconds: 1500));
  final Rect charRect = _StandInGamePage.charRect(geo, index, _kSceneSize);
  void lookupWord() => lookup.lookup(
    SrsCardLookupRequest(
      term: lookupQueryFromIndex(text, index),
      anchor: charRect,
      sentence: text,
    ),
  );
  // 卡面查词宿主的弹窗热槽要两轮才热透（实测只预热一轮时，录制中那次仍先空白、
  // 再出「检索中」、最后才出词条）。
  for (int round = 0; round < 2; round++) {
    await _prewarmLookup(
      tester,
      'gal#$round',
      () async => lookupWord(),
      close: () async => lookup.closeTop(),
    );
  }

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'gal',
    rect,
    const Offset(1050, 300),
  );
  await _hold(tester, const Duration(milliseconds: 600));
  tl.playAudio(_demoPath(line['voice']! as String));
  // 等这句语音念完一大半再点词。
  await _hold(tester, const Duration(milliseconds: 2600));
  await cursor.moveTo(tester, charRect.center + const Offset(4, 6));
  final Stopwatch clickAt = Stopwatch();
  await cursor.click(
    tester,
    onDown: () async {
      clickAt.start();
      lookupWord();
    },
  );
  final DictionaryPopupWebViewState? popup = await _timedPopup(
    tester,
    'gal',
    clickAt,
    tl,
  );
  expect(popup, isNotNull, reason: '游戏查词弹窗应出词条');
  final int posterMs = _sinceStart(rec) + 1200;
  await _hold(tester, const Duration(milliseconds: 2600));
  await _mineFromPopup(tester, cursor, popup!, c.anki);
  await _hold(tester, const Duration(milliseconds: 2400));
  await c.end('gal', rec, tl, cursor, posterMs: posterMs);
  lookup.closeAll();
  c.nav.pop();
  await _hold(tester, const Duration(seconds: 1));
}

/// 替身游戏画面：demo 截图铺满窗口。截图里本来就印着台词（官网 demo 也是在它上面
/// 叠可点字格），所以这里不再画字，只按同一套百分比字格几何算被点字的位置。
class _StandInGamePage extends StatelessWidget {
  const _StandInGamePage({required this.background, required this.controller});

  final File background;
  final SrsCardLookupController controller;

  static double _g(Map<String, Object?> geo, String k) =>
      (geo[k]! as num).toDouble();

  /// 第 [i] 个字格（以 1280×720 画面为准的百分比几何）。
  static Rect charRect(Map<String, Object?> geo, int i, Size size) {
    final double left =
        (_g(geo, 'firstCharLeft') + i * _g(geo, 'charPitch')) / 100;
    final double pitch = _g(geo, 'charPitch') / 100;
    final double top = _g(geo, 'top') / 100;
    final double h = _g(geo, 'height') / 100;
    return Rect.fromLTWH(
      left * size.width,
      top * size.height,
      pitch * size.width,
      h * size.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SrsCardLookupHost(
      controller: controller,
      child: ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: Image.file(background, fit: BoxFit.fill)),
      ),
    );
  }
}

/// 「App 全貌」：播种公有领域库，按官网那 7 个页签逐个抓图。
Future<void> _sceneOverview(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await seedSitePreviewLibrary(c.appModel, Directory(_kLibrary));
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  // 播种前首页已经建好，各库页的列表要重查一次。
  for (final HomeTab tab in <HomeTab>[
    HomeTab.books,
    HomeTab.video,
    HomeTab.manga,
    HomeTab.games,
  ]) {
    HomePage.debugSelectTab!(tab);
    await _hold(tester, const Duration(milliseconds: 800));
  }
  container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
  HomeVideoPage.debugRefreshVideos?.call();
  await _resizeClient(tester, _kOverviewSize);
  for (final (String name, HomeTab tab) in <(String, HomeTab)>[
    ('home', HomeTab.home),
    ('books', HomeTab.books),
    ('video', HomeTab.video),
    ('manga', HomeTab.manga),
    ('games', HomeTab.games),
    ('browse', HomeTab.browse),
    ('settings', HomeTab.settings),
  ]) {
    HomePage.debugSelectTab!(tab);
    // 封面解码 + 错峰进场动效走完。
    await _hold(tester, const Duration(milliseconds: 3500));
    await _saveFrame(tester, File(p.join(c.out.path, 'overview-$name.png')));
  }
  HomePage.debugSelectTab!(HomeTab.home);
  await _hold(tester, const Duration(milliseconds: 800));
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('官网预览：全貌截图 + 实机录屏', (WidgetTester tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    expect(_kOut, isNotEmpty, reason: '需要 --dart-define=SITE_PREVIEW_OUT');
    final Directory out = Directory(_kOut)..createSync(recursive: true);
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      errors.add(d);
      debugPrint('[site-preview] FlutterError: ${d.exceptionAsString()}');
    };
    FakeAnkiConnect? anki;
    try {
      UpdateChecker.disableAutoCheckForTesting = true;
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      final AppModel appModel = await readyAppModel(tester);
      await appModel.setAppThemeKey('m3-baseline');
      await appModel.setBrightnessMode('light');
      await appModel.setOnboardingFinished(value: true);
      await appModel.setOnboardingHomeCardDismissed(value: true);
      // 视频库顶上「配置可选在线服务」横幅（缺 API key 的提示）不进官网截图。
      await appModel.prefsRepo.dismissVideoOnlineServicesSetup();
      await _hold(tester, const Duration(seconds: 2));

      anki = await FakeAnkiConnect.start();
      final _Ctx c = _Ctx(tester, appModel, anki, out);

      if (_wants('selftest')) {
        final PhysicalRect rect = await _resizeClient(tester, _kSceneSize);
        final (
          SitePreviewRecording rec,
          SitePreviewTimeline tl,
          SitePreviewCursor cursor,
        ) = await c.begin(
          'selftest',
          rect,
          const Offset(900, 600),
        );
        await cursor.moveTo(tester, const Offset(200, 150));
        await cursor.click(tester);
        await cursor.moveTo(tester, const Offset(640, 360));
        await _hold(tester, const Duration(seconds: 1));
        await c.end('selftest', rec, tl, cursor, posterMs: 500);
      }
      if (_wants('overview')) {
        expect(_kLibrary, isNotEmpty, reason: '全貌需要 SITE_PREVIEW_LIBRARY');
        await _sceneOverview(c);
      }
      final bool anyScene = <String>[
        'video',
        'audiobook',
        'manga',
        'gal',
      ].any(_wants);
      if (anyScene) {
        expect(_kDemo, isNotEmpty, reason: '录屏需要 SITE_PREVIEW_DEMO');
        await _importDemoDictionaries(appModel);
        await configureFakeAnkiConnect(tester, anki);
        if (_wants('video')) await _sceneVideo(c);
        if (_wants('manga')) await _sceneManga(c);
        if (_wants('gal')) await _sceneGal(c);
        if (_wants('audiobook')) await _sceneAudiobook(c);
      }
      debugPrint(
        '[site-preview] done notes=${anki.notes.length} errors=${errors.length}',
      );
    } finally {
      FlutterError.onError = oldHandler;
      await anki?.close();
    }
  });
}
