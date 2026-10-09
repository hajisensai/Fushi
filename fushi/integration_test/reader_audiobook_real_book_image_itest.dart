import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/storage/app_paths.dart' show AppPaths;
import 'package:fushi_audio/fushi_audio.dart'
    show
        AudioCue,
        AudioTextNormalizer,
        AudiobookRepository,
        EpubSection,
        SrtBookRepository,
        SubtitleRematchCodec,
        SubtitleRematchFragment;
import 'package:fushi_core/fushi_core.dart' show EpubBookRow, FushiDatabase;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show
        AudiobookAlignmentResult,
        alignAndPersistAudiobook,
        loadEpubSectionsInBackground;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真书版 BUG-2744：有声书跟读 × 正文中段懒加载插图 × 「迟到图片重锚」。
///
/// 合成书版见 `reader_audiobook_image_late_load_itest.dart`（机制说明也在那里）。本测试
/// 换成用户真实的书：
///   - EPUB 走 [EpubImporter.importFromPath]（书籍导入对话框同一入口）；
///   - m4b + srt 走 [alignAndPersistAudiobook]（书籍导入对话框「EPUB + 字幕 + 音频」
///     那条生产链：解析章节 → 解析 cue → 自动窗口探测 + 匹配 → 持久字幕/音频 → 落库），
///     **不手造 cue**；
///   - 自动在书里挑一张「正文中段、前后都有足量正文」的 block 插图（阅读器清洗器给它挂
///     `loading="lazy"`），取插图前 [_leadChars] 个归一化字处的那条对齐 cue 作开书起点
///     （BUG-2390 音频为主：有声书位置 = 该 cue → 开书落在该 cue 所在页，远在懒加载距离外）。
///
/// 变体（每个独立开书一次，开书前把有声书位置重置到起点 cue）：
///   A 横排分页 + 跟随（图片暂停关）
///   B 横排分页 + 图片暂停开
///   C 横排连续 + 跟随
///   D 竖排分页（vertical-rl）+ 跟随（对照）
///   E 横排连续「用户滚走」：音频暂停，经生产 JS wheel 监听（webview.part.dart
///     `document.addEventListener('wheel', …)` 连续分支）派发真实 `WheelEvent` 往前滚过
///     插图，懒图在用户滚动之后才 load——判断 load 后视口有没有被拽回开书位置。
///
/// 判据（沿用合成书版）：
///   ① 位置推进过 P0 之后，任一采样不得回退超过半页 / 半屏；
///   ② 插图 load 那一刻（产品 load 回调执行前后）视口不得被挪到更早位置；
///   ③ 图片暂停变体：暂停窗口内、插图 load 之后，插图保持在视口内。
/// 「插图没 load / 播放没推进过插图 / 开书时插图已加载」= 本轮不成立（几何或环境问题），
/// 同样记失败，但消息里标「不成立」。
///
/// 数据隔离（硬要求）：只能经 `tool/run_windows_itest.ps1` 跑（它注入
/// `FUSHI_TEST_ROOT=<evidence>/isolated-root` 并重定向 APPDATA / LOCALAPPDATA / TEMP /
/// USERPROFILE / WebView2 profile）。测试开头先断言 documents / support / temp 三个根与
/// 主库文件（`PRAGMA database_list`）全部落在 `FUSHI_TEST_ROOT` 之下，不满足立即失败、
/// 不导入任何东西。真书目录只读（导入只读取；m4b / srt 被复制进隔离根的有声书目录）。
///
/// 焦点驱动约束：不点击任何控件——开书走 [openBookViaProductionPath]，播放走控制器 API，
/// 观测走 [ReaderFushiPage.debugEvaluateJavascript]；E 的滚轮是正文 document 里的
/// `WheelEvent`，走生产 wheel 监听，不是坐标点击。
///
/// Run (PowerShell, from fushi/, interactive desktop session):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
///     integration_test/reader_audiobook_real_book_image_itest.dart `
///     -DartDefine @('FUSHI_ITEST_REAL_BOOK_DIR=<书目录>')
/// runner 的参数转义带不过含空格 / 方括号 / 非 ASCII 的路径（会被 flutter 当成测试文件
/// 路径报 Illegal character in path），这种目录先建一个纯 ASCII 的 junction 指过去。
/// 可选 dart-define：
///   FUSHI_ITEST_REAL_BOOK_VARIANTS  要跑的变体（默认 ABCDE）
///   FUSHI_ITEST_REAL_BOOK_SPEED     播放速率（默认 2.0）
///   FUSHI_ITEST_REAL_BOOK_LEAD      起点距插图的归一化字数（默认 3500）
///   FUSHI_ITEST_REAL_BOOK_IMAGE     指定插图文件名（如 p194.jpg；默认自动挑第一张合格的）
///   FUSHI_ITEST_REAL_BOOK_SUBTITLE  aligned|raw（默认有 `-aligned.srt` 就用它）

const String _kBookDir = String.fromEnvironment('FUSHI_ITEST_REAL_BOOK_DIR');
const String _kVariants = String.fromEnvironment(
  'FUSHI_ITEST_REAL_BOOK_VARIANTS',
  defaultValue: 'ABCDE',
);
const String _kSpeedRaw = String.fromEnvironment(
  'FUSHI_ITEST_REAL_BOOK_SPEED',
  defaultValue: '2.0',
);
const String _kLeadRaw = String.fromEnvironment(
  'FUSHI_ITEST_REAL_BOOK_LEAD',
  defaultValue: '3500',
);
const String _kImageOverride = String.fromEnvironment(
  'FUSHI_ITEST_REAL_BOOK_IMAGE',
);
const String _kSubtitleChoice = String.fromEnvironment(
  'FUSHI_ITEST_REAL_BOOK_SUBTITLE',
);
const String _kTestRoot = String.fromEnvironment('FUSHI_TEST_ROOT');

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kLabel = 'real-img';

final double _speed = double.tryParse(_kSpeedRaw) ?? 2.0;
final int _leadChars = int.tryParse(_kLeadRaw) ?? 3500;

/// 跟读推过插图后再播这么多归一化字才停（覆盖图片暂停 + 恢复后的续读）。
const int _kCharsPastImage = 700;

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

// ── 隔离断言 ────────────────────────────────────────────────────────────────

bool _isUnder(String path, String root) {
  final String a = p.canonicalize(path);
  final String b = p.canonicalize(root);
  return a == b || p.isWithin(b, a);
}

/// 运行期证明：documents / support / temp 三个根与主库文件全部在 FUSHI_TEST_ROOT 下。
Future<void> _assertIsolatedDataRoots(AppModel appModel) async {
  expect(
    _kTestRoot.trim(),
    isNotEmpty,
    reason: 'FUSHI_TEST_ROOT 未注入：必须经 tool/run_windows_itest.ps1 运行（隔离数据根）',
  );
  final String docs = (await AppPaths.documentsRootDirectory()).path;
  final String support = (await AppPaths.supportRootDirectory()).path;
  final String temp = (await AppPaths.tempRootDirectory()).path;
  final List<String> dbFiles = <String>[];
  final List<dynamic> rows = await appModel.database
      .customSelect('PRAGMA database_list')
      .get();
  for (final dynamic row in rows) {
    final String file = (row.data['file'] as String?) ?? '';
    if (file.isNotEmpty) dbFiles.add(file);
  }
  debugPrint(
    '[$_kLabel] ISOLATION testRoot=$_kTestRoot docs=$docs support=$support '
    'temp=$temp db=$dbFiles APPDATA=${Platform.environment['APPDATA']} '
    'LOCALAPPDATA=${Platform.environment['LOCALAPPDATA']}',
  );
  for (final String path in <String>[docs, support, temp, ...dbFiles]) {
    expect(
      _isUnder(path, _kTestRoot),
      isTrue,
      reason: '数据路径 $path 不在隔离根 $_kTestRoot 之下——拒绝继续（防污染真实数据）',
    );
  }
  expect(dbFiles, isNotEmpty, reason: 'PRAGMA database_list 应给出主库文件');
}

// ── 真书素材 ────────────────────────────────────────────────────────────────

class _BookFiles {
  _BookFiles({required this.epub, required this.audio, required this.subtitle});
  final File epub;
  final File audio;
  final File subtitle;
}

_BookFiles _locateBookFiles(String dirPath) {
  final Directory dir = Directory(dirPath);
  expect(dir.existsSync(), isTrue, reason: '书目录不存在：$dirPath');
  final List<File> files = dir.listSync().whereType<File>().toList();
  File? pick(bool Function(String lower) test) {
    for (final File f in files) {
      if (test(f.path.toLowerCase())) return f;
    }
    return null;
  }

  final File? epub = pick((String s) => s.endsWith('.epub'));
  final File? audio = pick(
    (String s) =>
        s.endsWith('.m4b') ||
        s.endsWith('.m4a') ||
        s.endsWith('.mp3') ||
        s.endsWith('.aac'),
  );
  final File? aligned = pick((String s) => s.endsWith('-aligned.srt'));
  final File? raw = pick(
    (String s) => s.endsWith('.srt') && !s.endsWith('-aligned.srt'),
  );
  final File? subtitle = switch (_kSubtitleChoice) {
    'raw' => raw,
    'aligned' => aligned,
    _ => aligned ?? raw,
  };
  expect(epub, isNotNull, reason: '书目录里没有 .epub：$dirPath');
  expect(audio, isNotNull, reason: '书目录里没有音频（m4b/m4a/mp3）：$dirPath');
  expect(subtitle, isNotNull, reason: '书目录里没有 .srt：$dirPath');
  return _BookFiles(epub: epub!, audio: audio!, subtitle: subtitle!);
}

String _decodeEntities(String s) {
  return s
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}

/// HTML 片段 → 纯文本（去 rt/rp 读音、去标签），再按匹配器同款规则归一化后的长度。
/// 与 cue 的 `ns/ne`（归一化字符坐标）同一量纲；是近似值，只用来选「插图前若干页」的起点。
int _normLen(String htmlFragment) {
  String s = htmlFragment
      .replaceAll(RegExp(r'<rt\b[^>]*>.*?</rt>', dotAll: true), '')
      .replaceAll(RegExp(r'<rp\b[^>]*>.*?</rp>', dotAll: true), '')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = _decodeEntities(s);
  return AudioTextNormalizer.normalize(s).length;
}

class _ImageTarget {
  _ImageTarget({
    required this.section,
    required this.chapterFile,
    required this.src,
    required this.basename,
    required this.normOffset,
    required this.sectionNormLen,
  });

  final EpubSection section;
  final String chapterFile;
  final String src;
  final String basename;

  /// 插图前正文的归一化字数（近似 cue ns 坐标）。
  final int normOffset;
  final int sectionNormLen;
}

String? _resolveChapterFile(String extractDir, String href) {
  final String clean = href.split('#').first.replaceAll('\\', '/');
  final File direct = File(p.join(extractDir, clean));
  if (direct.existsSync()) return direct.path;
  final String base = p.basename(clean);
  for (final FileSystemEntity e in Directory(
    extractDir,
  ).listSync(recursive: true)) {
    if (e is File && p.basename(e.path) == base) {
      final String norm = e.path.replaceAll('\\', '/');
      if (norm.endsWith(clean)) return e.path;
    }
  }
  return null;
}

/// 挑一张「正文中段」的 block 插图：前面至少 [_leadChars]+1500 个归一化字、后面至少
/// 1500 个字；排除 gaiji / 区切り小图（class 或文件名含 gaiji / kugiri、文件 < 30KB）。
_ImageTarget? _findMidChapterImage(
  String extractDir,
  List<EpubSection> sections,
) {
  final RegExp imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  final RegExp srcAttr = RegExp(r'''src\s*=\s*["']([^"']+)["']''');
  for (final EpubSection section in sections) {
    final String? file = _resolveChapterFile(extractDir, section.href);
    if (file == null) continue;
    final String html = File(file).readAsStringSync();
    final int bodyAt = html.indexOf('<body');
    final String body = bodyAt >= 0 ? html.substring(bodyAt) : html;
    final int total = _normLen(body);
    for (final Match m in imgTag.allMatches(body)) {
      final String tag = m.group(0)!;
      final String? src = srcAttr.firstMatch(tag)?.group(1);
      if (src == null) continue;
      final String lower = '${tag.toLowerCase()} ${src.toLowerCase()}';
      if (lower.contains('gaiji') || lower.contains('kugiri')) continue;
      final String basename = p.basename(src);
      if (_kImageOverride.isNotEmpty && basename != _kImageOverride) continue;
      final File imgFile = File(p.normalize(p.join(p.dirname(file), src)));
      if (imgFile.existsSync() && imgFile.lengthSync() < 30 * 1024) continue;
      final int before = _normLen(body.substring(0, m.start));
      if (_kImageOverride.isEmpty &&
          (before < _leadChars + 1500 || total - before < 1500)) {
        continue;
      }
      return _ImageTarget(
        section: section,
        chapterFile: file,
        src: src,
        basename: basename,
        normOffset: before,
        sectionNormLen: total,
      );
    }
  }
  return null;
}

SubtitleRematchFragment? _frag(AudioCue c) =>
    SubtitleRematchCodec.tryDecode(c.textFragmentId);

// ── 采样 / 探针 JS ──────────────────────────────────────────────────────────

/// 目标插图选择器（按文件名匹配 src；探针装好后改认 data 标记）。
String _imgFinderJs(String basename) {
  final String lit = jsonEncode(basename);
  return '''
function __itestFindImg() {
  var t = document.querySelector('img[data-itest-target]');
  if (t) return t;
  var name = $lit;
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    var s = imgs[i].getAttribute('src') || '';
    if (s.indexOf(name) >= 0) return imgs[i];
  }
  return null;
}
function __itestGeom() {
  var r = window.fushiReader;
  if (!r) return null;
  var cont = typeof r.scrollToChapterEnd === 'function';
  var vertical = !!(r.isVertical && r.isVertical());
  var pos, ps, useTop;
  if (!cont && typeof r.getScrollContext === 'function') {
    var c = r.getScrollContext();
    pos = r.getPagePosition(c);
    ps = c.pageSize;
    useTop = !!c.vertical;
    var ve = c.viewportExtent || (c.vertical ? window.innerHeight : window.innerWidth);
    return {cont: false, vertical: vertical, pos: pos, ps: ps, ve: ve, useTop: useTop};
  }
  var root = document.scrollingElement || document.documentElement;
  if (vertical) {
    return {cont: true, vertical: true, pos: Math.abs(window.scrollX), ps: window.innerWidth,
      ve: window.innerWidth, useTop: false};
  }
  return {cont: true, vertical: false, pos: root.scrollTop, ps: window.innerHeight,
    ve: window.innerHeight, useTop: true};
}
''';
}

String _sampleJs(String basename) =>
    '''
(function () {
${_imgFinderJs(basename)}
  var r = window.fushiReader;
  var g = __itestGeom();
  if (!g) return 'null';
  var img = __itestFindImg();
  var rect = img ? img.getBoundingClientRect() : null;
  var loaded = img ? (img.complete && img.naturalWidth > 0) : null;
  var vis = 0;
  var a0 = null;
  if (rect) a0 = g.useTop ? rect.top : rect.left;
  if (rect && rect.width > 0 && rect.height > 0) {
    var s0 = g.useTop ? rect.top : rect.left;
    var s1 = g.useTop ? rect.bottom : rect.right;
    var ov = Math.max(0, Math.min(s1, g.ve) - Math.max(s0, 0));
    vis = ov / Math.max(1, s1 - s0);
  }
  var anc = null;
  if (r.__imgReanchorTarget) anc = 'target';
  else if (typeof r.__imgReanchorCharOffset === 'number') anc = 'char:' + r.__imgReanchorCharOffset;
  else if (typeof r.__imgReanchorProgress === 'number') anc = 'progress:' + r.__imgReanchorProgress;
  else if (r.__imgReanchorFragment) anc = 'frag:' + r.__imgReanchorFragment;
  return JSON.stringify({
    pos: g.pos, ps: g.ps, cont: g.cont, vertical: g.vertical,
    loaded: loaded, vis: vis,
    il: a0 === null ? null : Math.round(a0),
    iw: rect ? Math.round(g.useTop ? rect.height : rect.width) : null,
    lazy: img ? img.getAttribute('loading') : null,
    anc: anc,
    probe: !!window.__imgLateProbe
  });
})()
''';

/// 插图 load 探针（同合成书版）：document 捕获阶段监听在产品 load 回调之前触发、img 上
/// 后注册的监听在产品回调之后触发，夹住 `_sharedInitImages` 的 load 回调。另记 window /
/// body scroll 轨迹（分页滚 body、连续滚 root）。
String _installProbeJs(String basename) =>
    '''
(function () {
${_imgFinderJs(basename)}
  var r = window.fushiReader;
  var img = __itestFindImg();
  if (!r || !img) return JSON.stringify({ok: false, hasReader: !!r, hasImg: !!img,
    imgCount: document.querySelectorAll('img').length});
  img.setAttribute('data-itest-target', '1');
  var P = window.__imgLateProbe = window.__imgLateProbe || {events: [], scrolls: [], wheels: 0};
  function pos() { var g = __itestGeom(); return g ? g.pos : -1; }
  if (!window.__imgLateProbeBound) {
    window.__imgLateProbeBound = true;
    document.addEventListener('load', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG' && t.getAttribute('data-itest-target')) {
        P.events.push({t: Date.now(), phase: 'before-product-handler', pos: pos(),
          nw: t.naturalWidth, nh: t.naturalHeight});
      }
    }, true);
    img.addEventListener('load', function () {
      P.events.push({t: Date.now(), phase: 'after-product-handler', pos: pos(),
        nw: img.naturalWidth, nh: img.naturalHeight,
        wrapped: !!(img.closest && img.closest('.block-img-wrapper'))});
    });
    var onScroll = function () {
      P.scrolls.push({t: Date.now(), pos: pos()});
      if (P.scrolls.length > 4000) P.scrolls.shift();
    };
    document.body.addEventListener('scroll', onScroll, {passive: true});
    window.addEventListener('scroll', onScroll, {passive: true});
  }
  var g = __itestGeom();
  var rect = img.getBoundingClientRect();
  return JSON.stringify({
    ok: true,
    src: img.getAttribute('src'),
    complete: img.complete,
    naturalWidth: img.naturalWidth,
    loading: img.getAttribute('loading'),
    imgLeft: rect.left, imgTop: rect.top,
    innerW: window.innerWidth, innerH: window.innerHeight,
    vertical: g.vertical, cont: g.cont,
    visibility: document.visibilityState
  });
})()
''';

const String _kReadProbeJs = r'''
JSON.stringify(window.__imgLateProbe || null)
''';

/// E：往正文 document 派发一拍真实 `WheelEvent`（生产 wheel 监听连续分支处理：
/// `e.preventDefault()` + `window.scrollBy`，到边界才回传跨章）。返回派发前后位置。
String _wheelJs(int deltaY) =>
    '''
(function () {
  var root = document.scrollingElement || document.documentElement;
  var before = root.scrollTop;
  var ev = new WheelEvent('wheel', {deltaY: $deltaY, deltaX: 0, deltaMode: 0,
    bubbles: true, cancelable: true});
  var target = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2) || document.body;
  target.dispatchEvent(ev);
  if (window.__imgLateProbe) window.__imgLateProbe.wheels++;
  return JSON.stringify({before: before, after: root.scrollTop, prevented: ev.defaultPrevented});
})()
''';

// ── 采样 ────────────────────────────────────────────────────────────────────

class _Sample {
  _Sample({
    required this.tMs,
    required this.cueNs,
    required this.playing,
    required this.imagePaused,
    required this.pos,
    required this.pageSize,
    required this.loaded,
    required this.visFrac,
    required this.imgLead,
    required this.imgExtent,
    required this.anchor,
    this.note = '',
  });

  final int tMs;
  final int cueNs;
  final bool playing;
  final bool imagePaused;
  final double pos;
  final double pageSize;
  final bool? loaded;
  final double visFrac;
  final int? imgLead;
  final int? imgExtent;
  final Object? anchor;
  final String note;

  bool get imageVisible => visFrac >= 0.5;

  String describe(double p0) {
    final String page = pageSize > 0
        ? ((pos - p0) / pageSize).toStringAsFixed(2)
        : '?';
    return 't=${tMs}ms cueNs=$cueNs play=$playing imgPause=$imagePaused '
        'pos=${pos.toStringAsFixed(1)} (P0${pos >= p0 ? '+' : ''}$page页) '
        'imgLoaded=$loaded imgVis=${visFrac.toStringAsFixed(2)} '
        'imgLead=$imgLead imgExt=$imgExtent anchor=$anchor'
        '${note.isEmpty ? '' : ' $note'}';
  }
}

class _PhaseResult {
  _PhaseResult(this.label);
  final String label;
  final List<String> failures = <String>[];
  final List<String> timeline = <String>[];
  String summary = '';
}

class _Variant {
  const _Variant({
    required this.id,
    required this.label,
    required this.writingMode,
    required this.viewMode,
    required this.imagePauseSec,
    this.userScroll = false,
  });

  final String id;
  final String label;
  final String writingMode;
  final String viewMode;
  final int imagePauseSec;
  final bool userScroll;

  bool get continuous => viewMode == 'continuous';
  bool get vertical => writingMode != 'horizontal-tb';
}

const List<_Variant> _kAllVariants = <_Variant>[
  _Variant(
    id: 'A',
    label: 'A-hPaged-follow',
    writingMode: 'horizontal-tb',
    viewMode: 'paginated',
    imagePauseSec: 0,
  ),
  _Variant(
    id: 'B',
    label: 'B-hPaged-imagePause',
    writingMode: 'horizontal-tb',
    viewMode: 'paginated',
    imagePauseSec: 5,
  ),
  _Variant(
    id: 'C',
    label: 'C-hContinuous-follow',
    writingMode: 'horizontal-tb',
    viewMode: 'continuous',
    imagePauseSec: 0,
  ),
  _Variant(
    id: 'D',
    label: 'D-vPaged-follow',
    writingMode: 'vertical-rl',
    viewMode: 'paginated',
    imagePauseSec: 0,
  ),
  _Variant(
    id: 'E',
    label: 'E-hContinuous-userWheel',
    writingMode: 'horizontal-tb',
    viewMode: 'continuous',
    imagePauseSec: 0,
    userScroll: true,
  ),
];

/// 一本书的共享上下文（导入一次，五个变体复用）。
class _BookCtx {
  _BookCtx({
    required this.bookKey,
    required this.image,
    required this.startCue,
    required this.targetCue,
    required this.imageCueNs,
  });

  final String bookKey;
  final _ImageTarget image;
  final AudioCue startCue;

  /// 跟读停在这条 cue（插图后 [_kCharsPastImage] 字）。
  final AudioCue targetCue;

  /// 插图之后第一条 cue 的 ns（「播放推进过插图」的判据）。
  final int imageCueNs;
}

Future<_BookCtx> _importRealBook(AppModel appModel, _BookFiles files) async {
  final FushiDatabase db = appModel.database;
  final Stopwatch sw = Stopwatch()..start();
  final String bookKey = await EpubImporter.importFromPath(
    db: db,
    filePath: files.epub.path,
    fileName: p.basename(files.epub.path),
  );
  final int epubMs = sw.elapsedMilliseconds;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  expect(row, isNotNull, reason: 'imported book row must exist');
  debugPrint(
    '[$_kLabel] EPUB imported key=$bookKey chapters=${row!.chapterCount} '
    'extractDir=${row.extractDir} in ${epubMs}ms',
  );
  expect(
    _isUnder(row.extractDir, _kTestRoot),
    isTrue,
    reason: 'EPUB 解压目录 ${row.extractDir} 必须在隔离根内',
  );

  final AudiobookRepository audio = AudiobookRepository(db);
  sw.reset();
  final AudiobookAlignmentResult aligned = await alignAndPersistAudiobook(
    db: db,
    repo: SrtBookRepository(db),
    audiobookRepo: audio,
    bookKey: bookKey,
    title: p.basenameWithoutExtension(files.epub.path),
    subtitlePath: files.subtitle.path,
    audioPaths: <String>[files.audio.path],
    onProgress: (double f, String m) {
      if (f == 0.55 || f == 0.8 || f == 1) {
        debugPrint(
          '[$_kLabel] align progress ${(f * 100).round()}% '
          'at ${sw.elapsedMilliseconds}ms',
        );
      }
    },
  );
  final int alignMs = sw.elapsedMilliseconds;
  debugPrint(
    '[$_kLabel] ALIGN done in ${alignMs}ms cues=${aligned.cueCount} '
    'health=${aligned.health.kind} ${aligned.health.ratePct}% (${aligned.health.reason}) '
    'audio=${aligned.persistedAudioPaths}',
  );
  for (final String a in aligned.persistedAudioPaths) {
    expect(_isUnder(a, _kTestRoot), isTrue, reason: '有声书音频落盘路径 $a 必须在隔离根内');
  }

  final List<EpubSection> sections = await loadEpubSectionsInBackground(
    row.extractDir,
  );
  final _ImageTarget? image = _findMidChapterImage(row.extractDir, sections);
  expect(
    image,
    isNotNull,
    reason:
        '书里找不到「正文中段 block 插图」（前 >= ${_leadChars + 1500} 字、后 >= 1500 字）'
        '——换一卷（如 20~26 卷）或调小 FUSHI_ITEST_REAL_BOOK_LEAD',
  );
  final _ImageTarget img = image!;
  final int sectionTextNorm = AudioTextNormalizer.normalize(
    img.section.text,
  ).length;
  debugPrint(
    '[$_kLabel] IMAGE section=${img.section.index} href=${img.section.href} '
    'src=${img.src} normOffset≈${img.normOffset}/${img.sectionNormLen} '
    '(matcher section norm len=$sectionTextNorm)',
  );

  final List<AudioCue> all = await audio.cuesForBook(bookKey);
  final List<AudioCue> inSection =
      all.where((AudioCue c) {
        final SubtitleRematchFragment? f = _frag(c);
        return f != null && f.sectionIndex == img.section.index;
      }).toList()..sort(
        (AudioCue a, AudioCue b) =>
            _frag(a)!.normCharStart.compareTo(_frag(b)!.normCharStart),
      );
  debugPrint(
    '[$_kLabel] section ${img.section.index} matched cues=${inSection.length} '
    '(book total ${all.length})',
  );
  expect(inSection, isNotEmpty, reason: '插图所在章没有命中的 cue');

  AudioCue? start;
  AudioCue? afterImage;
  AudioCue? target;
  for (final AudioCue c in inSection) {
    final int ns = _frag(c)!.normCharStart;
    if (ns <= img.normOffset - _leadChars) start = c;
    if (afterImage == null && ns >= img.normOffset) afterImage = c;
    if (target == null && ns >= img.normOffset + _kCharsPastImage) target = c;
  }
  expect(start, isNotNull, reason: '插图前 $_leadChars 字处没有命中的 cue');
  expect(afterImage, isNotNull, reason: '插图之后没有命中的 cue');
  target ??= inSection.last;
  debugPrint(
    '[$_kLabel] START cue sentenceIndex=${start!.sentenceIndex} '
    'startMs=${start.startMs} ns=${_frag(start)!.normCharStart} '
    'text=${start.text}',
  );
  debugPrint(
    '[$_kLabel] IMAGE-NEXT cue sentenceIndex=${afterImage!.sentenceIndex} '
    'startMs=${afterImage.startMs} ns=${_frag(afterImage)!.normCharStart} '
    'text=${afterImage.text}',
  );
  debugPrint(
    '[$_kLabel] TARGET cue sentenceIndex=${target.sentenceIndex} '
    'startMs=${target.startMs} ns=${_frag(target)!.normCharStart} '
    '(audio span start→target '
    '${((target.startMs - start.startMs) / 1000).toStringAsFixed(1)}s @1x)',
  );
  return _BookCtx(
    bookKey: bookKey,
    image: img,
    startCue: start,
    targetCue: target,
    imageCueNs: _frag(afterImage)!.normCharStart,
  );
}

Future<void> _applyReaderLayout(AppModel appModel, _Variant v) async {
  await appModel.database.setPref(
    'src:reader_fushi:writing_mode',
    v.writingMode,
  );
  await appModel.database.setPref('src:reader_fushi:view_mode', v.viewMode);
  await ReaderFushiSource.readerSettings?.refreshFromDb();
}

Future<Map<String, dynamic>?> _evalJson(String js) async {
  final dynamic raw = await ReaderFushiPage.debugEvaluateJavascript!(js);
  if (raw is! String || raw == 'null') return null;
  return jsonDecode(raw) as Map<String, dynamic>;
}

_Sample _toSample(
  Map<String, dynamic> m,
  int tMs,
  AudiobookPlayerController? c, {
  String note = '',
}) {
  final AudioCue? cue = c?.currentCue;
  final SubtitleRematchFragment? f = cue == null ? null : _frag(cue);
  return _Sample(
    tMs: tMs,
    cueNs: f?.normCharStart ?? -1,
    playing: c?.isPlaying ?? false,
    imagePaused: c?.isImagePaused ?? false,
    pos: (m['pos'] as num).toDouble(),
    pageSize: (m['ps'] as num).toDouble(),
    loaded: m['loaded'] as bool?,
    visFrac: (m['vis'] as num?)?.toDouble() ?? 0,
    imgLead: (m['il'] as num?)?.toInt(),
    imgExtent: (m['iw'] as num?)?.toInt(),
    anchor: m['anc'],
    note: note,
  );
}

/// 位置单调判据 ①：推进过 P0 之后，任一采样不得回退超过半页。
void _checkNoRegression(
  _PhaseResult result,
  String tag,
  List<_Sample> samples,
  double p0,
) {
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
        '$tag ① 推进后位置回退：已到 pos=${maxPos.toStringAsFixed(1)}'
        '（${maxAt?.describe(p0)}）后回到 pos=${s.pos.toStringAsFixed(1)}'
        '${atP0 ? '＝开书位置 P0（被恢复锚拽回）' : ''}；回退那一帧：${s.describe(p0)}',
      );
      return;
    }
  }
}

/// 判据 ②：插图 load 那一刻视口不得被挪到更早位置。返回 (before, after) 位置。
void _checkLoadMoment(
  _PhaseResult result,
  String tag,
  List<dynamic> events,
  double p0,
  double pageSize,
) {
  final List<Map<String, dynamic>> evs = events.cast<Map<String, dynamic>>();
  final Map<String, dynamic>? before = evs
      .where((Map<String, dynamic> e) => e['phase'] == 'before-product-handler')
      .firstOrNull;
  final Map<String, dynamic>? after = evs
      .where((Map<String, dynamic> e) => e['phase'] == 'after-product-handler')
      .firstOrNull;
  if (before == null || after == null) {
    result.failures.add(
      '$tag 本轮不成立：插图 load 探针未触发（before=$before after=$after），'
      '插图在本轮始终没有 load 或探针失效',
    );
    return;
  }
  final double pb = (before['pos'] as num).toDouble();
  final double pa = (after['pos'] as num).toDouble();
  debugPrint(
    '$tag ② load moment: pos before product handler=$pb, after=$pa, P0=$p0 '
    'natural=${after['nw']}x${after['nh']} wrapped=${after['wrapped']}',
  );
  if (pa < pb - pageSize * 0.5) {
    result.failures.add(
      '$tag ② 插图 load 回调把视口从 pos=$pb 拽到 pos=$pa'
      '${(pa - p0).abs() <= 2 ? '＝开书位置 P0' : ''}（迟到图片重锚按旧锚生效）',
    );
  }
}

Future<_PhaseResult> _runVariant(
  WidgetTester tester,
  AppModel appModel,
  _BookCtx book,
  _Variant v,
) async {
  final _PhaseResult result = _PhaseResult(v.label);
  final String tag = '[$_kLabel/${v.label}]';
  final AudiobookRepository audio = AudiobookRepository(appModel.database);
  final String bookKey = book.bookKey;
  final String basename = book.image.basename;

  // ── 开书前：排版 + 有声书设置 + 位置重置到起点 cue ──────────────────────────
  await _applyReaderLayout(appModel, v);
  await audio.updateFollowAudio(bookKey: bookKey, value: true);
  await audio.updateImagePauseSec(bookKey: bookKey, sec: v.imagePauseSec);
  await audio.updateSpeed(bookKey: bookKey, speed: _speed);
  await audio.updatePositionMs(
    bookKey: bookKey,
    positionMs: book.startCue.startMs + 100,
  );

  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, '${v.label} WebView');
  await _waitFor(tester, _contentReady, '${v.label} content');
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
  // 恢复落定 + 首轮 chrome inset 重锚跑完。
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  debugPrint(
    '$tag controller attached cueCount=${controller.chapterCueCount} '
    'idx=${controller.currentCueIdx} '
    'cueNs=${controller.currentCue == null ? null : _frag(controller.currentCue!)?.normCharStart} '
    'follow=${controller.followAudio.value} '
    'imagePauseSec=${controller.imagePauseSec.value} speed=$_speed '
    'continuous=${ReaderFushiSource.readerSettings?.isContinuousMode}',
  );

  final Map<String, dynamic>? setup = await _evalJson(
    _installProbeJs(basename),
  );
  debugPrint('$tag probe install: $setup');
  if (setup == null || setup['ok'] != true) {
    result.failures.add(
      '$tag setup: 探针没找到阅读器或目标插图 $basename（$setup）——开书没落在插图所在章？',
    );
    await _closeReader(tester);
    await appModel.audiobookSession.stop();
    return result;
  }
  expect(
    setup['vertical'],
    v.vertical,
    reason: '$tag writing mode must be ${v.writingMode}',
  );
  expect(
    setup['cont'],
    v.continuous,
    reason: '$tag view mode must be ${v.viewMode}',
  );

  final Map<String, dynamic>? m0 = await _evalJson(_sampleJs(basename));
  expect(m0, isNotNull, reason: '$tag initial sample');
  final _Sample s0 = _toSample(m0!, 0, controller);
  final double p0 = s0.pos;
  final double pageSize = s0.pageSize;
  debugPrint(
    '$tag OPEN P0=$p0 pageSize=$pageSize (page≈${pageSize > 0 ? (p0 / pageSize).toStringAsFixed(2) : '?'}) '
    'imgLoaded=${s0.loaded} imgLead=${s0.imgLead} '
    '(≈${pageSize > 0 && s0.imgLead != null ? (s0.imgLead! / pageSize).toStringAsFixed(2) : '?'} 页/屏之后) '
    'lazy=${m0['lazy']} anchor=${s0.anchor} cueNs=${s0.cueNs}',
  );
  if (p0 <= 0) {
    result.failures.add('$tag 本轮不成立：开书没有落在起点 cue 所在页（P0=$p0）');
  }
  if (s0.loaded == true) {
    result.failures.add(
      '$tag 本轮不成立：开书时插图已加载（imgLead=${s0.imgLead}，pageSize=$pageSize），'
      '懒加载距离覆盖到了插图——调大 FUSHI_ITEST_REAL_BOOK_LEAD',
    );
  }
  if (result.failures.isNotEmpty) {
    await _closeReader(tester);
    await appModel.audiobookSession.stop();
    return result;
  }

  final List<_Sample> samples = <_Sample>[];
  final Stopwatch sw = Stopwatch()..start();
  final int startEpochMs = DateTime.now().millisecondsSinceEpoch;
  String? lastKey;
  void record(_Sample s) {
    samples.add(s);
    final String key =
        '${s.pos.round()}|${s.loaded}|${s.imageVisible}|${s.cueNs}|'
        '${s.imagePaused}|${s.playing}|${s.anchor}';
    if (key != lastKey) {
      lastKey = key;
      final String line = s.describe(p0);
      result.timeline.add(line);
      debugPrint('$tag $line');
    }
  }

  if (!v.userScroll) {
    // ── 跟读：真播放 + 采样 ─────────────────────────────────────────────────
    final int spanMs = book.targetCue.startMs - book.startCue.startMs;
    final Duration budget = Duration(
      milliseconds: (spanMs / _speed).round() + v.imagePauseSec * 1000 + 45000,
    );
    debugPrint('$tag play budget=${budget.inSeconds}s');
    unawaited(controller.play());
    while (sw.elapsed < budget) {
      await tester.pump(const Duration(milliseconds: 100));
      final Map<String, dynamic>? m = await _evalJson(_sampleJs(basename));
      if (m == null) continue;
      final _Sample s = _toSample(m, sw.elapsedMilliseconds, controller);
      record(s);
      if (s.cueNs >= _frag(book.targetCue)!.normCharStart && !s.imagePaused) {
        break;
      }
    }
    await controller.pause();
  } else {
    // ── E：音频暂停，用户滚轮往前滚过插图 ──────────────────────────────────
    await controller.pause();
    const int deltaY = 120;
    int ticks = 0;
    int ticksAfterPass = 0;
    int stuck = 0;
    while (ticks < 400 && sw.elapsed < const Duration(minutes: 3)) {
      final Map<String, dynamic>? w = await _evalJson(_wheelJs(deltaY));
      ticks++;
      await tester.pump(const Duration(milliseconds: 60));
      final Map<String, dynamic>? m = await _evalJson(_sampleJs(basename));
      if (m == null) continue;
      final _Sample s = _toSample(
        m,
        sw.elapsedMilliseconds,
        controller,
        note:
            'wheel#$ticks ${w?['before']}→${w?['after']} '
            'prevented=${w?['prevented']}',
      );
      record(s);
      if (w != null && (w['before'] as num?) == (w['after'] as num?)) {
        stuck++;
        if (stuck >= 5) {
          debugPrint('$tag wheel no longer moves (boundary?) — stop scrolling');
          break;
        }
      } else {
        stuck = 0;
      }
      // 插图已滚到视口上方（整张越过）后再滚 15 拍，覆盖「越过插图」情形。
      final bool passed =
          s.loaded == true &&
          s.imgLead != null &&
          s.imgExtent != null &&
          s.imgLead! + s.imgExtent! < 0;
      if (passed) ticksAfterPass++;
      if (ticksAfterPass >= 15) break;
    }
    debugPrint('$tag wheel ticks=$ticks passedTicks=$ticksAfterPass');
    // 用户停手后再观察 4 秒（懒图 decode / 重锚落定）。
    final Stopwatch settle = Stopwatch()..start();
    while (settle.elapsed < const Duration(seconds: 4)) {
      await tester.pump(const Duration(milliseconds: 100));
      final Map<String, dynamic>? m = await _evalJson(_sampleJs(basename));
      if (m == null) continue;
      record(_toSample(m, sw.elapsedMilliseconds, controller, note: 'settle'));
    }
  }
  await tester.pump(const Duration(milliseconds: 300));

  // ── 探针事件 ──────────────────────────────────────────────────────────────
  final Map<String, dynamic>? probe = await _evalJson(_kReadProbeJs);
  final List<dynamic> events =
      (probe?['events'] as List<dynamic>?) ?? <dynamic>[];
  final List<dynamic> scrolls =
      (probe?['scrolls'] as List<dynamic>?) ?? <dynamic>[];
  for (final dynamic e in events) {
    final Map<String, dynamic> ev = e as Map<String, dynamic>;
    final int rel = (ev['t'] as num).toInt() - startEpochMs;
    final String line =
        'IMG-LOAD t=${rel}ms phase=${ev['phase']} pos=${ev['pos']} '
        'natural=${ev['nw']}x${ev['nh']} wrapped=${ev['wrapped']}';
    result.timeline.add(line);
    debugPrint('$tag $line');
  }
  final StringBuffer trail = StringBuffer();
  int lastPos = -99999;
  for (final dynamic e in scrolls) {
    final Map<String, dynamic> sc = e as Map<String, dynamic>;
    final int pos = (sc['pos'] as num).round();
    if ((pos - lastPos).abs() < 2) continue;
    lastPos = pos;
    trail.write('${(sc['t'] as num).toInt() - startEpochMs}:$pos ');
  }
  debugPrint('$tag scroll trail (t:pos, deduped) = $trail');

  // ── 判据 ──────────────────────────────────────────────────────────────────
  expect(samples.length, greaterThan(10), reason: '$tag sampling must run');
  if (!v.userScroll) {
    final int maxNs = samples.fold<int>(
      -1,
      (int a, _Sample s) => s.cueNs > a ? s.cueNs : a,
    );
    if (maxNs < book.imageCueNs) {
      result.failures.add(
        '$tag 本轮不成立：播放没有推进过插图（最大 cueNs=$maxNs，插图后首句 ns='
        '${book.imageCueNs}）',
      );
    }
  } else {
    final bool reachedImage = samples.any(
      (_Sample s) =>
          s.imgLead != null && s.pageSize > 0 && s.imgLead! < s.pageSize,
    );
    if (!reachedImage) {
      result.failures.add('$tag 本轮不成立：用户滚轮始终没把插图滚进视口附近');
    }
  }
  _checkNoRegression(result, tag, samples, p0);
  _checkLoadMoment(result, tag, events, p0, pageSize);

  // ③ 图片暂停变体。
  if (v.imagePauseSec > 0) {
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

  final double maxPos = samples.fold<double>(
    p0,
    (double a, _Sample s) => s.pos > a ? s.pos : a,
  );
  final _Sample? firstLoadedSample = samples
      .where((_Sample s) => s.loaded == true)
      .firstOrNull;
  result.summary =
      '$tag SUMMARY P0=$p0 pageSize=$pageSize maxPos=$maxPos '
      'final=${samples.last.describe(p0)} '
      'imageFirstSeenLoaded=${firstLoadedSample?.describe(p0) ?? 'never'} '
      'loadEvents=${events.length} elapsed=${sw.elapsedMilliseconds}ms '
      'failures=${result.failures.length}';
  debugPrint(result.summary);

  await _closeReader(tester);
  // 显式停掉常驻有声书会话（否则下一变体复用同一控制器与其当前位置）。
  await appModel.audiobookSession.stop();
  await tester.pump(const Duration(milliseconds: 500));
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (_kBookDir.isEmpty) {
    debugPrint(
      '[$_kLabel] SKIP: 未传 --dart-define=FUSHI_ITEST_REAL_BOOK_DIR=<书目录>'
      '（目录内需有 .epub + .m4b + .srt，且书中有正文中段插图，如無職転生 20~26 卷）',
    );
  }

  testWidgets(
    'real book: audiobook follow / user wheel across a mid-chapter lazy '
    'illustration must not be yanked back by the late-image reanchor',
    skip: _kBookDir.isEmpty,
    timeout: const Timeout(Duration(minutes: 120)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: _kLabel,
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          await _assertIsolatedDataRoots(appModel);

          final _BookFiles files = _locateBookFiles(_kBookDir);
          debugPrint(
            '[$_kLabel] BOOK epub=${files.epub.path} audio=${files.audio.path} '
            'subtitle=${files.subtitle.path} speed=$_speed lead=$_leadChars '
            'variants=$_kVariants',
          );
          final _BookCtx book = await _importRealBook(appModel, files);

          final List<_PhaseResult> results = <_PhaseResult>[];
          try {
            for (final _Variant v in _kAllVariants) {
              if (!_kVariants.toUpperCase().contains(v.id)) continue;
              results.add(await _runVariant(tester, appModel, book, v));
            }
          } finally {
            await _closeReader(tester);
            await appModel.audiobookSession.stop();
          }

          debugPrint('[$_kLabel] ===== VERDICT =====');
          for (final _PhaseResult r in results) {
            debugPrint(r.summary);
            debugPrint('[$_kLabel/${r.label}] failures=${r.failures.length}');
            for (final String f in r.failures) {
              debugPrint('[$_kLabel/${r.label}] FAIL $f');
            }
          }
          final List<String> failures = <String>[
            for (final _PhaseResult r in results) ...r.failures,
          ];
          expect(
            failures,
            isEmpty,
            reason:
                '真书插图处迟到图片重锚把视口拽回（闪屏 / 插图被跳过 / 用户滚走被拽回）：\n'
                '${failures.join('\n')}',
          );
        },
      );
    },
  );
}
