import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/text_leads_page_stop.dart';
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
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'helpers/media_fixtures.dart'
    show generateSilentAudio, kFixtureChapterHref;
import 'helpers/observe_capture.dart' show captureReaderWebView;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 文字领读（「跟随音频」领读方向 = 文字）在真 app 里的端到端行为，VN 模式。
///
/// 自造两章 EPUB（每章 6 段，每段一句），静音音频 + 每段一条 sasayaki cue（1.5 s），
/// VN「按句分屏」每屏 2 句 → 每章 3 屏。逐条验：
///   1. 开书后 VN 引擎上报了当前屏范围（首句 / 末句）；
///   2. 播放 → 播到本屏末句句末自动停，当前句没推进到下一屏，屏也没被音频翻走；
///   3. PageDown → 新屏上报、自动续播，当前句落在新屏；
///   4. 再停在屏末后 PageUp → 跳回上一屏首句并播放（重听）；
///   5. 播放中 PageDown → 音频跟到新屏；
///   6. 用户暂停后 PageDown → 只挪音频到新屏首句，不起播；
///   7. 停在屏末时按播放 → 自动翻到下一屏并续播；
///   8. 停在第 0 章最后一屏屏末后 PageDown → 进第 1 章首屏并从第 1 章首句续播；
///   9. 关掉跟随音频 → 文字领读撤销。
///
/// 焦点驱动：不点控件。开书走 [openBookViaProductionPath]，翻屏走键盘事件，
/// 播放 / 暂停走控制器 API。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_vn_text_leads_itest.dart
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kLabel = 'vn-text-leads';

const int _kParagraphs = 6;
const int _kCueMs = 1500;

const List<String> _kSentences = <String>[
  '桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。',
  '古い木の扉を押し開けると、埃の匂いと紙の香りが混ざり合った。',
  '窓から差し込む午後の光が、本棚の間を縫うように伸びていた。',
  '図書館の奥には、誰も近寄らない古びた書架があった。',
  '少年が一冊の本を手に取ると、ページの間から小さな鍵が落ちた。',
  '彼は鍵を握りしめ、図書館の中を探索し始めた。',
];

String _paragraph(int chapter, int i) =>
    '第$chapter章第${i + 1}段、${_kSentences[(i + chapter) % _kSentences.length]}';

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;
bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;
bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 250),
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

/// 像 [_waitFor]，但超时只返回 false（由调用方记失败，测试继续往下验）。
Future<bool> _poll(
  WidgetTester tester,
  bool Function() ready, {
  int maxPolls = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) return true;
  }
  return false;
}

String _xhtml(String title, String body) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head>
  <meta charset="UTF-8"/>
  <title>$title</title>
</head>
<body>
$body</body>
</html>''';

Uint8List _buildEpub(String uid) {
  String textChapter(int chapter) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < _kParagraphs; i++) {
      b.writeln('  <p>${_paragraph(chapter, i)}</p>');
    }
    return b.toString();
  }

  final String opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:$uid</dc:identifier>
    <dc:title>Text Leads</dc:title>
    <dc:language>ja</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c0"/>
    <itemref idref="c1"/>
  </spine>
</package>''';
  final String ncx =
      '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:$uid"/></head>
  <docTitle><text>Text Leads</text></docTitle>
  <navMap>
    <navPoint id="n0" playOrder="1"><navLabel><text>一</text></navLabel><content src="c0.xhtml"/></navPoint>
    <navPoint id="n1" playOrder="2"><navLabel><text>二</text></navLabel><content src="c1.xhtml"/></navPoint>
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
  addText('OEBPS/c0.xhtml', _xhtml('一', textChapter(0)));
  addText('OEBPS/c1.xhtml', _xhtml('二', textChapter(1)));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

List<AudioCue> _buildCues(String bookKey) {
  final List<AudioCue> cues = <AudioCue>[];
  int ms = 0;
  for (int chapter = 0; chapter < 2; chapter++) {
    int running = 0;
    for (int i = 0; i < _kParagraphs; i++) {
      final String text = _paragraph(chapter, i);
      final int len = AudioTextNormalizer.normalize(text).length;
      cues.add(
        AudioCue()
          ..bookKey = bookKey
          ..chapterHref = kFixtureChapterHref
          ..sentenceIndex = cues.length
          ..textFragmentId = SubtitleRematchCodec.encodeHit(
            sectionIndex: chapter,
            normCharStart: running,
            normCharEnd: running + len,
          )
          ..text = text
          ..startMs = ms
          // 句间留 100 ms 静音，与真实朗读一致。
          ..endMs = ms + _kCueMs - 100
          ..audioFileIndex = 0,
      );
      running += len;
      ms += _kCueMs;
    }
  }
  return cues;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'VN text leads: audio stops at the end of each screen and follows page '
    'turns',
    timeout: const Timeout(Duration(minutes: 10)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: _kLabel,
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final ReaderFushiSource src = ReaderFushiSource.instance;
          await src.setReaderViewMode('vn');
          await src.setReaderVisualNovelScreenMode('sentences');
          await src.setReaderVisualNovelSentencesPerScreen(2);
          await src.setReaderVisualNovelRevealSpeed(0);
          await src.setReaderVisualNovelMergeSpokenSentence(true);
          await src.setAudiobookLinkDirection(kAudiobookLinkDirectionText);
          await ReaderFushiSource.readerSettings?.refreshFromDb();

          final db = appModel.database;
          final String bookKey = await EpubImporter.import(
            db: db,
            bytes: _buildEpub('itest-vn-text-leads'),
            fileName: 'vn_text_leads.epub',
          );
          final List<AudioCue> cues = _buildCues(bookKey);
          final Directory dir = await _fixturesDir();
          final File audioFile = await generateSilentAudio(
            outPath: '${dir.path}${Platform.pathSeparator}text-leads.m4a',
            duration: Duration(milliseconds: cues.last.endMs + 5000),
          );
          final AudiobookRepository audio = AudiobookRepository(db);
          await audio.replaceAlignment(
            bookKey: bookKey,
            format: 'srt',
            path: audioFile.path,
          );
          await audio.replaceAudio(
            bookKey: bookKey,
            audioPaths: <String>[audioFile.path],
          );
          await audio.saveCues(bookKey: bookKey, cues: cues);
          await audio.updateFollowAudio(bookKey: bookKey, value: true);
          await audio.updateImagePauseSec(bookKey: bookKey, sec: 0);
          await audio.updatePositionMs(bookKey: bookKey, positionMs: 0);

          final List<String> failures = <String>[];
          void check(bool ok, String what) {
            debugPrint('[$_kLabel] ${ok ? 'PASS' : 'FAIL'} $what');
            if (!ok) failures.add(what);
          }

          await openBookViaProductionPath(tester, bookKey);
          await _waitFor(tester, _webViewShown, 'WebView');
          await _waitFor(tester, _contentReady, 'content');
          AudiobookPlayerController? found;
          for (int i = 0; i < 80; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            final AudiobookPlayerController? c =
                appModel.audiobookSession.controller;
            if (c != null && c.chapterCueCount > 0) {
              found = c;
              break;
            }
          }
          expect(found, isNotNull, reason: 'audiobook controller attaches');
          final AudiobookPlayerController c = found!;
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 500));
          }

          int idx(AudioCue? cue) => cue == null
              ? -1
              : cues.indexWhere(
                  (AudioCue x) => x.textFragmentId == cue.textFragmentId,
                );
          String describe() {
            final TextLeadsPageBounds? b = c.pageBoundsForTesting;
            return 'bounds=${b == null ? 'null' : '${idx(b.first)}..${idx(b.last)}'} '
                'cue=${idx(c.currentCue)} playing=${c.isPlaying} '
                'pausedAtEnd=${c.pausedAtPageEnd} '
                'pos=${c.position.inMilliseconds} '
                'section=${c.getCurrentReaderSection?.call()}';
          }

          int boundsFirst() => idx(c.pageBoundsForTesting?.first);
          int boundsLast() => idx(c.pageBoundsForTesting?.last);

          /// 等音频停在屏末（最长一屏两句 ≈ 3 s，留足余量）。
          Future<bool> waitStopAtEnd() => _poll(
            tester,
            () => c.pausedAtPageEnd && !c.isPlaying,
            maxPolls: 120,
          );

          Future<void> pageKey(LogicalKeyboardKey key) async {
            await tester.sendKeyEvent(key);
            for (int i = 0; i < 3; i++) {
              await tester.pump(const Duration(milliseconds: 200));
            }
            await _waitFor(tester, _contentReady, 'content after key');
          }

          // ── 1. 开书：文字领读生效，首屏范围已上报 ──
          check(
            ReaderFushiSource.readerSettings?.isVnMode ?? false,
            '1a reader runs in VN mode',
          );
          check(c.textLeads, '1b text leads active (${describe()})');
          await _poll(tester, () => c.pageBoundsForTesting != null);
          debugPrint('[$_kLabel] after open: ${describe()}');
          check(
            boundsFirst() == 0 && boundsLast() == 1,
            '1c first screen reports cues 0..1 (${describe()})',
          );
          await captureReaderWebView('01-open');

          // ── 2. 播放 → 停在本屏末句句末 ──
          await c.play();
          final bool stopped1 = await waitStopAtEnd();
          debugPrint('[$_kLabel] after play: ${describe()}');
          check(stopped1, '2a audio paused itself at end of screen');
          check(
            idx(c.currentCue) == 1,
            '2b current cue stayed on the last cue of the screen (${describe()})',
          );
          final int overshoot = c.position.inMilliseconds - cues[1].endMs;
          check(
            overshoot >= -150 && overshoot <= 250,
            '2c stopped within the gap after the last cue (overshoot ${overshoot}ms)',
          );
          check(
            boundsFirst() == 0,
            '2d audio did not turn the screen (${describe()})',
          );
          await captureReaderWebView('02-stopped-at-end');

          // ── 3. PageDown → 自动续播，从新屏开始 ──
          await pageKey(LogicalKeyboardKey.pageDown);
          final bool resumed = await _poll(
            tester,
            () => boundsFirst() == 2 && c.isPlaying,
          );
          debugPrint('[$_kLabel] after PageDown: ${describe()}');
          check(resumed, '3a next screen (cues 2..3) resumed playback');
          await _poll(tester, () => idx(c.currentCue) == 2);
          check(
            idx(c.currentCue) == 2,
            '3b current cue is the new screen\'s first cue (${describe()})',
          );

          // ── 4. 再停在屏末，PageUp → 回上一屏首句并播放 ──
          final bool stopped2 = await waitStopAtEnd();
          check(
            stopped2 && idx(c.currentCue) == 3,
            '4a stopped at end of screen 2 (${describe()})',
          );
          await pageKey(LogicalKeyboardKey.pageUp);
          final bool replay = await _poll(
            tester,
            () => boundsFirst() == 0 && c.isPlaying && idx(c.currentCue) == 0,
          );
          debugPrint('[$_kLabel] after PageUp: ${describe()}');
          check(
            replay,
            '4b paging back replays the previous screen from cue 0',
          );

          // ── 5. 播放中 PageDown → 音频跟到新屏 ──
          await tester.pump(const Duration(milliseconds: 400));
          await pageKey(LogicalKeyboardKey.pageDown);
          final bool followed = await _poll(
            tester,
            () => boundsFirst() == 2 && idx(c.currentCue) == 2 && c.isPlaying,
          );
          debugPrint('[$_kLabel] after PageDown while playing: ${describe()}');
          check(
            followed,
            '5 page turn while playing moves audio to new screen',
          );

          // ── 6. 用户暂停后 PageDown → 只挪位置不起播 ──
          await c.pause();
          await tester.pump(const Duration(milliseconds: 300));
          await pageKey(LogicalKeyboardKey.pageDown);
          final bool moved = await _poll(
            tester,
            () => boundsFirst() == 4 && idx(c.currentCue) == 4,
          );
          await tester.pump(const Duration(milliseconds: 500));
          debugPrint('[$_kLabel] after pause + PageDown: ${describe()}');
          check(
            moved && !c.isPlaying,
            '6 paused + page turn moves audio to cue 4 without playing (${describe()})',
          );

          // ── 7/8. 播到第 0 章末屏屏末；按播放 → 翻进第 1 章并续播 ──
          await c.play();
          final bool stopped3 = await waitStopAtEnd();
          debugPrint('[$_kLabel] end of chapter 0: ${describe()}');
          check(
            stopped3 && idx(c.currentCue) == 5,
            '7a stopped at end of chapter 0 last screen (${describe()})',
          );
          await c.play(); // 停在屏末按播放 = 翻下一屏
          final bool crossed = await _poll(
            tester,
            () =>
                c.getCurrentReaderSection?.call() == 1 &&
                boundsFirst() == 6 &&
                c.isPlaying,
            maxPolls: 200,
          );
          await _poll(tester, () => idx(c.currentCue) == 6);
          debugPrint('[$_kLabel] after play at chapter end: ${describe()}');
          check(
            crossed && idx(c.currentCue) == 6,
            '8 play at page end turned into chapter 1 and resumed from cue 6 '
            '(${describe()})',
          );
          await captureReaderWebView('03-chapter-1');

          // ── 9. 关掉跟随音频 → 文字领读撤销 ──
          c.setFollowAudio(false);
          check(!c.textLeads, '9a follow off disables text leads');
          c.setFollowAudio(true);
          check(c.textLeads, '9b follow on re-enables text leads');
          await c.pause();

          debugPrint('[$_kLabel] VERDICT failures=${failures.length}');
          for (final String f in failures) {
            debugPrint('[$_kLabel] FAIL $f');
          }
          Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
          await _waitFor(tester, _readerPageGone, 'reader closed');
          expect(failures, isEmpty, reason: failures.join('\n'));
        },
      );
    },
  );
}
