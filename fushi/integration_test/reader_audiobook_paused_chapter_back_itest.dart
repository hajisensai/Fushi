import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
        AudiobookPlayerController,
        AudiobookRepository,
        SubtitleRematchCodec;
import 'package:fushi_core/fushi_core.dart' show EpubBookRow;
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/generate_test_image.dart' show TestImageGenerator;
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'helpers/media_fixtures.dart'
    show generateSilentAudio, kFixtureChapterHref;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2779：有声书**暂停**时往回翻过章界，新章一载入就被拽回音频所在章。
///
/// 用户原始路径（iOS，VN 竖排）：音频停在正文章 ch2；ch1 是独立纯图片章。在插图章
/// 往回翻 → ch0 刚露一帧就被拉回 ch2；从 ch2 往回翻到插图章 → 又被拉回。插图位置永远
/// 翻不过去。根因见 `docs/bugs/BUG-2779-audio-paused-chapter-reload-yank.md`。
///
/// 本测试在真 app 里按生产路径复现：
///   - 自造三章 EPUB：ch0 正文 / ch1 纯图片章（`<img>` 独占一章）/ ch2 正文；
///   - 静音音频 + 每段一条 sasayaki cue（ch0 段 s=0、ch2 段 s=2），跟随音频开、图片等待关；
///     音频位置落在 ch2 第 2 段 → 开书起点 = ch2（BUG-2390 音频为主）；
///   - VN 模式；控制器 play 一下再 pause（本会话 hasPlayedOnce，与用户状态一致）；
///   - 按 PageUp（`_paginate` → `_handlePageTurnLimit` 跨章，与触屏滑动同一漏斗）往回翻，
///     每越过一个章界就停 4 秒，断言阅读器仍停在翻到的那一章。
///
/// 焦点驱动：不点击任何控件——开书走 [openBookViaProductionPath]，翻页走键盘事件，
/// 播放 / 暂停走控制器 API。
///
/// Run (PowerShell, from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_audiobook_paused_chapter_back_itest.dart
///   powershell -ExecutionPolicy Bypass -File tool/run_mac_itest.ps1 \
///       integration_test/reader_audiobook_paused_chapter_back_itest.dart -Ios

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kLabel = 'paused-back';

const int _kCh0Paragraphs = 6;
const int _kCh2Paragraphs = 4;
const int _kCueMs = 800;

const List<String> _kSentences = <String>[
  '桜の花が咲き始めた頃、少年は初めてその図書館を訪れた。',
  '古い木の扉を押し開けると、埃の匂いと紙の香りが混ざり合った。',
  '窓から差し込む午後の光が、本棚の間を縫うように伸びていた。',
  '図書館の奥には、誰も近寄らない古びた書架があった。',
  '少年が一冊の本を手に取ると、ページの間から小さな鍵が落ちた。',
  '彼は鍵を握りしめ、図書館の中を探索し始めた。',
];

String _paragraph(int chapter, int i) =>
    '第$chapter章第${i + 1}段。${_kSentences[(i + chapter) % _kSentences.length]}';

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

Uint8List _buildEpub(Uint8List png) {
  const String uid = 'itest-paused-chapter-back';
  String textChapter(int chapter, int count) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < count; i++) {
      b.writeln('  <p>${_paragraph(chapter, i)}</p>');
    }
    return b.toString();
  }

  const String opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:$uid</dc:identifier>
    <dc:title>Paused Chapter Back</dc:title>
    <dc:language>ja</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c0" href="c0.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
    <item id="illust" href="images/illust.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c0"/>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''';
  const String ncx =
      '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:$uid"/></head>
  <docTitle><text>Paused Chapter Back</text></docTitle>
  <navMap>
    <navPoint id="n0" playOrder="1"><navLabel><text>一</text></navLabel><content src="c0.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>二</text></navLabel><content src="c2.xhtml"/></navPoint>
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
  addText('OEBPS/c0.xhtml', _xhtml('一', textChapter(0, _kCh0Paragraphs)));
  addText(
    'OEBPS/c1.xhtml',
    _xhtml(
      '挿絵',
      '  <div class="center"><img alt="" src="images/illust.png"/></div>\n',
    ),
  );
  addText('OEBPS/c2.xhtml', _xhtml('二', textChapter(2, _kCh2Paragraphs)));
  archive.addFile(
    ArchiveFile.noCompress('OEBPS/images/illust.png', png.length, png),
  );
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

List<AudioCue> _buildCues(String bookKey) {
  final List<AudioCue> cues = <AudioCue>[];
  int ms = 0;
  void addChapter(int chapter, int count) {
    int running = 0;
    for (int i = 0; i < count; i++) {
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
          ..endMs = ms + _kCueMs
          ..audioFileIndex = 0,
      );
      running += len;
      ms += _kCueMs;
    }
  }

  addChapter(0, _kCh0Paragraphs);
  addChapter(2, _kCh2Paragraphs);
  return cues;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'paused audiobook: paging back across chapters must not be yanked back to '
    'the audio chapter (VN, image-only chapter in between)',
    timeout: const Timeout(Duration(minutes: 10)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: _kLabel,
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final db = appModel.database;

          await db.setPref('src:reader_fushi:view_mode', 'vn');
          await ReaderFushiSource.readerSettings?.refreshFromDb();

          final Uint8List png = const TestImageGenerator().pngBytes(
            width: 800,
            height: 1200,
            seed: 5,
          );
          final String bookKey = await EpubImporter.import(
            db: db,
            bytes: _buildEpub(png),
            fileName: 'paused_chapter_back.epub',
          );
          final EpubBookRow? row = await db.getEpubBook(bookKey);
          expect(row?.chapterCount, 3, reason: 'fixture must have 3 chapters');

          final List<AudioCue> cues = _buildCues(bookKey);
          final Directory dir = await _fixturesDir();
          final File audioFile = await generateSilentAudio(
            outPath: '${dir.path}${Platform.pathSeparator}$bookKey.m4a',
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
          // 音频停在 ch2 第 2 段（开书起点 = ch2）。
          final AudioCue anchorCue = cues[_kCh0Paragraphs + 1];
          await audio.updatePositionMs(
            bookKey: bookKey,
            positionMs: anchorCue.startMs + 100,
          );

          try {
            await openBookViaProductionPath(tester, bookKey);
            await _waitFor(tester, _webViewShown, 'WebView');
            await _waitFor(tester, _contentReady, 'content');
            AudiobookPlayerController? ctrl;
            for (int i = 0; i < 80; i++) {
              await tester.pump(const Duration(milliseconds: 500));
              final AudiobookPlayerController? c =
                  appModel.audiobookSession.controller;
              if (c != null && c.chapterCueCount > 0) {
                ctrl = c;
                break;
              }
            }
            expect(ctrl, isNotNull, reason: 'audiobook controller attaches');
            final AudiobookPlayerController controller = ctrl!;
            int readerSection() =>
                controller.getCurrentReaderSection?.call() ?? -1;
            for (int i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 500));
            }
            expect(
              ReaderFushiSource.readerSettings?.isVnMode,
              isTrue,
              reason: 'reader must run in VN mode',
            );
            expect(
              readerSection(),
              2,
              reason: 'open lands on the audio chapter',
            );

            // 与用户状态一致：本会话按过播放，随后暂停。
            await controller.seekMs(anchorCue.startMs + 100);
            await controller.play();
            await tester.pump(const Duration(milliseconds: 300));
            await controller.pause();
            for (int i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 500));
            }
            debugPrint(
              '[$_kLabel] paused cue=${controller.currentCue?.textFragmentId} '
              'section=${readerSection()} playing=${controller.isPlaying}',
            );
            expect(readerSection(), 2);

            final List<String> timeline = <String>[];
            Future<void> pageBackUntilBelow(int section) async {
              for (int press = 0; press < 40; press++) {
                if (readerSection() < section) return;
                await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
                for (int i = 0; i < 3; i++) {
                  await tester.pump(const Duration(milliseconds: 300));
                }
                timeline.add('press#$press section=${readerSection()}');
              }
              fail('PageUp never crossed below chapter $section: $timeline');
            }

            Future<void> holdAndExpect(int expected, String what) async {
              final List<int> seen = <int>[];
              for (int i = 0; i < 16; i++) {
                await tester.pump(const Duration(milliseconds: 250));
                seen.add(readerSection());
              }
              debugPrint('[$_kLabel] $what samples=$seen');
              expect(
                seen.every((int s) => s == expected),
                isTrue,
                reason:
                    '$what: reader must stay on chapter $expected while audio '
                    'is paused, but was pulled: $seen (timeline $timeline)',
              );
            }

            // ch2 → 插图章 ch1。
            await pageBackUntilBelow(2);
            await _waitFor(tester, _contentReady, 'image chapter content');
            await holdAndExpect(1, 'after paging back onto the image chapter');

            // 插图章 ch1 → ch0（用户原始失败点）。
            await pageBackUntilBelow(1);
            await _waitFor(tester, _contentReady, 'ch0 content');
            await holdAndExpect(0, 'after paging back past the image chapter');
            expect(controller.isPlaying, isFalse);
          } finally {
            await _closeReader(tester);
          }
        },
      );
    },
  );
}
