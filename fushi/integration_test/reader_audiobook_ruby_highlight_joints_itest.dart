import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
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
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'helpers/media_fixtures.dart'
    show generateSilentAudio, kFixtureChapterHref;
import 'helpers/observe_capture.dart' show ObserveShot, captureReaderWebView;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3279：有声书当前句高亮在振假名处断开（用户截图：竖排「闇」「橙」前后各被
/// 切出缺口，「橙（だいだい）」上下还多一条深色叠色带）。
///
/// 根因：一句被 ruby / 书的行内元素拆成多个 wrapper，每个 wrapper 都带 10-09 的圆角
/// （box-decoration-break: clone），同一列里相邻 wrapper 的接缝处两个圆角头对在一起；
/// Blink 下长注音把基字盒撑到注音长度、压进两侧邻字，两层半透明底色叠出深色带。
///
/// 本测试走生产路径：自造带振假名的竖排单章 EPUB 导入、挂静音音频 + 每句一条
/// sasayaki 编码 cue、开书，依次在翻页 / 滚动 / VN 三种 view mode 下用有声书控制器
/// [AudiobookPlayerController.skipToCueIndex] 逐句跳转（真实的跟读高亮路径），每句
/// 在 WebView 里量当前句高亮的几何：
///   - 同一列里相邻片段的接缝不得有圆角（notched）；
///   - 接缝处不得留缝（unfilled）也不得叠色（overlap）；
///   - 同一列各片段的横向范围一致（widthMismatch）；
///   - 每一列的首尾片段保持圆角（roundEndsBad）；
///   - 高亮文字 = 该句正文（防空转：wrapper 数为 0 也算失败）。
/// 每种模式抓一张带「幾重…橙…炸裂音」那句的 WebView 真像素截图。
///
/// 焦点驱动约束：全程不点击控件——开书走 [openBookViaProductionPath]，跳句走控制器
/// API，观测走 debug JS 钩子。
///
/// Run (PowerShell, from fushi/, interactive desktop session):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_audiobook_ruby_highlight_joints_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kLabel = 'ruby-hl';
const String _kChapterTitle = '第一章　花火';
const int _kCueMs = 1500;

/// 段落 HTML（带 ruby / 书自带 em）。句子按「。」「」」切，每句一条 cue。
const List<String> _kParagraphs = <String>[
  '花を咲かせる。音楽に乗せ、特大のスターマインが夜空に大輪の花を咲かせる。',
  '間断なく開いては<ruby>闇<rt>やみ</rt></ruby>を照らし続けた。'
      '<ruby>幾重<rt>いくえ</rt></ruby>にも重なる赤、黄、<ruby>橙<rt>だいだい</rt></ruby>の光は'
      '夜空に<ruby>炸裂音<rt>さくれつおん</rt></ruby>を響かせ、どこまでも<em>広がって</em>いった。',
  '「ほぉ……」',
  '<ruby>陽乃<rt>はるの</rt></ruby>さんからの攻撃を受け流していると、ちょうど誰だか偉い人の'
      '<ruby>挨拶<rt>あいさつ</rt></ruby>が終わり、ついに一発目の花火が打ち上がろうとしていた。',
  'どどんぱっと<ruby>轟<rt>ごう</rt></ruby>音がいくつもいくつも響く。'
      '<ruby>桃<rt>タオ</rt></ruby><ruby>白<rt>パイ</rt></ruby>かっつーくらいどどんぱ言ってんな。'
      '<ruby>炸裂音<rt>さくれつおん</rt></ruby>が響く中、ぎしっと椅子を<ruby>軋<rt>きし</rt></ruby>'
      'ませて陽乃さんが深く座り直した。',
  '花開く光輪は、ポートタワーのハーフミラーガラスにも見事に映り込み、その輝きを増す。'
      'これを皮切りに八〇〇〇発もの多彩な花火が続くのだそうだ。',
];

/// 截图那一句（幾重 / 橙 / 炸裂音 / em）在 [_sentences] 里的下标。
const int _kShotCue = 3;

String _plain(String html) => html
    .replaceAll(RegExp(r'<rt>.*?</rt>'), '')
    .replaceAll(RegExp(r'<[^>]+>'), '');

List<String> _sentences() => <String>[
  for (final String p in _kParagraphs)
    ...RegExp(r'[^。」]*[。」]').allMatches(_plain(p)).map((Match m) => m[0]!),
];

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

Uint8List _buildEpub({required String bookTitle, required String uid}) {
  final StringBuffer body = StringBuffer()
    ..writeln('  <h1>$_kChapterTitle</h1>');
  for (int i = 0; i < _kParagraphs.length; i++) {
    body.writeln('  <p id="p${i + 1}">${_kParagraphs[i]}</p>');
  }
  final String chapter =
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head>
  <meta charset="UTF-8"/>
  <title>$_kChapterTitle</title>
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
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter_01" href="chapter_01.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter_01"/>
  </spine>
</package>''';
  final String ncx =
      '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:$uid"/></head>
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
  addText('OEBPS/chapter_01.xhtml', chapter);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 当前句高亮的几何度量（与本机 Chromium / Mac WKWebView 探针同一套判据）。
const String _kMeasureJs = r'''
(function () {
  var els = Array.from(document.querySelectorAll('.fushi-sentence-audio-active'));
  if (!els.length) return JSON.stringify({ wrappers: 0, text: '' });
  var vertical = getComputedStyle(els[0]).writingMode.indexOf('vertical') === 0;
  var px = function (v) { return parseFloat(v) || 0; };
  var lineRects = function (el) {
    return Array.from(el.getClientRects()).filter(function (x) { return x.width > 0.5 && x.height > 0.5; });
  };
  var sameLine = function (a, b) {
    return vertical ? (a.left < b.right && b.left < a.right) : (a.top < b.bottom && b.top < a.bottom);
  };
  var trimOf = function (el) {
    var bi = el.style.backgroundImage || '';
    var m1 = /transparent ([0-9.]+)px/.exec(bi), m2 = /100% - ([0-9.]+)px/.exec(bi);
    return { s: m1 ? parseFloat(m1[1]) : 0, e: m2 ? parseFloat(m2[1]) : 0 };
  };
  var frags = [];
  var text = '';
  els.forEach(function (el) {
    var cs = getComputedStyle(el);
    var tr = trimOf(el);
    var tw = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    var t;
    while ((t = tw.nextNode())) if (!t.parentElement.closest('rt,rp')) text += t.nodeValue;
    lineRects(el).forEach(function (r) {
      frags.push({ r: r, sr: px(cs.borderStartStartRadius) + px(cs.borderEndStartRadius),
        er: px(cs.borderStartEndRadius) + px(cs.borderEndEndRadius), shadow: el.style.boxShadow,
        ts: tr.s, te: tr.e });
    });
  });
  var out = { wrappers: els.length, frags: frags.length, joints: 0, notched: 0, unfilled: 0,
    overlap: 0, widthMismatch: 0, roundEndsBad: 0, text: text, details: [] };
  for (var f = 0; f < frags.length; f++) {
    var a = frags[f], b = frags[f + 1];
    var prevSame = f > 0 && sameLine(frags[f - 1].r, a.r);
    var nextSame = b && sameLine(a.r, b.r);
    if (!prevSame && a.sr < 0.5) { out.roundEndsBad++; out.details.push('run-start square @' + f); }
    if (!nextSame && a.er < 0.5) { out.roundEndsBad++; out.details.push('run-end square @' + f); }
    if (!nextSame) continue;
    out.joints++;
    var gap = (vertical ? b.r.top - a.r.bottom : b.r.left - a.r.right) + a.te + b.ts;
    if (a.er > 0.5 || b.sr > 0.5) { out.notched++; out.details.push('notch @' + f); }
    if (gap > 0.5 && !a.shadow && !b.shadow) { out.unfilled++; out.details.push('gap ' + gap.toFixed(1)); }
    if (gap < -0.5) { out.overlap++; out.details.push('overlap ' + gap.toFixed(1)); }
    if (vertical
        ? (Math.abs(a.r.left - b.r.left) > 0.5 || Math.abs(a.r.right - b.r.right) > 0.5)
        : (Math.abs(a.r.top - b.r.top) > 0.5 || Math.abs(a.r.bottom - b.r.bottom) > 0.5)) {
      out.widthMismatch++;
      out.details.push('width @' + f);
    }
  }
  out.vertical = vertical;
  return JSON.stringify(out);
})()
''';

Future<List<String>> _runMode(
  WidgetTester tester,
  AppModel appModel,
  String bookKey,
  List<String> sentences,
  String mode,
) async {
  final String tag = '[$_kLabel/$mode]';
  final List<String> failures = <String>[];
  await appModel.database.setPref('src:reader_fushi:view_mode', mode);
  await ReaderFushiSource.readerSettings?.refreshFromDb();

  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, '$mode WebView');
  await _waitFor(tester, _contentReady, '$mode content');
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
  expect(
    controller.chapterCueCount,
    sentences.length,
    reason: '$tag every sentence must be a cue',
  );
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  int measured = 0;
  int splitJoints = 0;
  for (int i = 0; i < sentences.length; i++) {
    await controller.skipToCueIndex(i);
    Map<String, dynamic>? m;
    Map<String, dynamic>? last;
    final String want = sentences[i];
    for (int k = 0; k < 20; k++) {
      await tester.pump(const Duration(milliseconds: 250));
      final dynamic raw = await ReaderFushiPage.debugEvaluateJavascript!(
        _kMeasureJs,
      );
      if (raw is! String) continue;
      final Map<String, dynamic> got = jsonDecode(raw) as Map<String, dynamic>;
      last = got;
      if ((got['text'] as String) == want) {
        // 跳转后的重排 / 跟随翻页落定：再量一次取稳定值。
        await tester.pump(const Duration(milliseconds: 400));
        m =
            jsonDecode(
                  await ReaderFushiPage.debugEvaluateJavascript!(_kMeasureJs)
                      as String,
                )
                as Map<String, dynamic>;
        break;
      }
    }
    if (m == null) {
      failures.add(
        '$tag cue $i: highlight never showed 「$want」 '
        '(last: wrappers=${last?['wrappers']} text=「${last?['text']}」 '
        'controllerCue=${controller.currentCueIdx})',
      );
      continue;
    }
    measured++;
    splitJoints += (m['joints'] as num).toInt();
    debugPrint(
      '$tag cue $i wrappers=${m['wrappers']} frags=${m['frags']} '
      'joints=${m['joints']} notched=${m['notched']} unfilled=${m['unfilled']} '
      'overlap=${m['overlap']} widthMismatch=${m['widthMismatch']} '
      'roundEndsBad=${m['roundEndsBad']} vertical=${m['vertical']} '
      'details=${m['details']}',
    );
    for (final String k in <String>[
      'notched',
      'unfilled',
      'overlap',
      'widthMismatch',
      'roundEndsBad',
    ]) {
      if ((m[k] as num) != 0) {
        failures.add('$tag cue $i 「$want」 $k=${m[k]} ${m['details']}');
      }
    }
    if (i == _kShotCue) {
      await tester.pump(const Duration(milliseconds: 600));
      final ObserveShot shot = await captureReaderWebView('ruby-hl-$mode');
      debugPrint('$tag screenshot saved=${shot.saved} ${shot.path}');
    }
  }
  debugPrint(
    '$tag SUMMARY measured=$measured/${sentences.length} joints=$splitJoints '
    'failures=${failures.length}',
  );
  if (splitJoints == 0) {
    failures.add('$tag 本轮不成立：没有任何一句在同一列里出现接缝（测试空转）');
  }
  await controller.pause();
  await _closeReader(tester);
  return failures;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-3279: audiobook sentence highlight is one continuous bar across ruby '
    'in paginated, continuous and VN modes',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: _kLabel,
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final FushiDatabase db = appModel.database;

          await db.setPref('src:reader_fushi:writing_mode', 'vertical-rl');
          final List<String> sentences = _sentences();
          final String bookKey = await EpubImporter.import(
            db: db,
            bytes: _buildEpub(
              bookTitle: 'Ruby Highlight Joints',
              uid: 'itest-ruby-highlight-joints',
            ),
            fileName: 'ruby_highlight_joints.epub',
          );
          final EpubBookRow? row = await db.getEpubBook(bookKey);
          expect(row?.chapterCount, 1, reason: 'single-chapter fixture');

          final Directory dir = await _fixturesDir();
          final String audioPath =
              '${dir.path}${Platform.pathSeparator}$bookKey.m4a';
          final File audioFile = await generateSilentAudio(
            outPath: audioPath,
            duration: Duration(milliseconds: sentences.length * _kCueMs + 5000),
          );
          int running = AudioTextNormalizer.normalize(_kChapterTitle).length;
          final List<AudioCue> cues = <AudioCue>[];
          for (int i = 0; i < sentences.length; i++) {
            final int len = AudioTextNormalizer.normalize(sentences[i]).length;
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
                ..text = sentences[i]
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

          final List<String> failures = <String>[];
          try {
            const String only = String.fromEnvironment('RUBY_HL_MODES');
            for (final String mode in <String>[
              'paginated',
              'continuous',
              'vn',
            ]) {
              if (only.isNotEmpty && !only.split(',').contains(mode)) {
                continue;
              }
              failures.addAll(
                await _runMode(tester, appModel, bookKey, sentences, mode),
              );
            }
          } finally {
            await _closeReader(tester);
            await db.setPref('src:reader_fushi:view_mode', 'paginated');
            await ReaderFushiSource.readerSettings?.refreshFromDb();
          }
          debugPrint('[$_kLabel] ===== VERDICT failures=${failures.length}');
          for (final String f in failures) {
            debugPrint('[$_kLabel] FAIL $f');
          }
          expect(
            failures,
            isEmpty,
            reason: '当前句高亮在振假名处断开 / 叠色：\n${failures.join('\n')}',
          );
        },
      );
    },
  );
}
