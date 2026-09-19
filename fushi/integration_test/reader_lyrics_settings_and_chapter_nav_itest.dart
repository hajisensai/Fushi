import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/utils.dart' show AdaptiveSettingsStepperRow, t;
import 'package:fushi_audio/fushi_audio.dart'
    show
        AudioCue,
        AudioTextNormalizer,
        AudiobookPlayerController,
        AudiobookRepository,
        SubtitleRematchCodec;
import 'package:fushi_core/fushi_core.dart'
    show StudySegmentRow, kActivityMediaBook;
import 'package:fushi_engine/epub/epub_book.dart' show EpubBook;
import 'package:fushi_engine/epub/epub_parser.dart' show EpubParser;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedAudiobook;
import 'helpers/media_fixtures.dart'
    show buildAudiobookEpubBytes, buildSampleCues;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// 歌词模式两条用户反馈的真机门（Windows 离屏 runner）：
///
/// 1. 「阅读设置调节按钮不生效」——歌词模式下打开设置抽屉，用方向键推歌词字号
///    stepper，WebView 里 `--cue-font-size` 必须跟着变（走的是
///    `_applyStylesLive → _updateLyricsStyleLive → __lyricsUpdateStyle` 这条真链路）。
/// 2. 「歌词模式没有跳章节按钮」——歌词模式顶栏必须仍有「章节导航」键；从章节列表
///    跳章在歌词模式下把音频定位到该章首句，而不是把歌词文档换成 EPUB 章。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test/reader_lyrics_settings_and_chapter_nav_itest.dart

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

bool _readerContentReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

bool _lyricsReady() => find
    .byKey(const ValueKey<String>('fushi_lyrics_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (condition()) return;
  }
  fail(reason);
}

Future<AudiobookPlayerController> _waitForActiveAudiobook(
  WidgetTester tester,
  AppModel appModel,
) async {
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final AudiobookPlayerController? controller =
        appModel.audiobookSession.controller;
    if (controller != null && controller.chapterCueCount > 0) {
      return controller;
    }
  }
  fail('audiobook controller must attach with chapter cues before lyrics mode');
}

Future<double> _cueFontSizePx() async {
  final dynamic raw = await ReaderFushiPage.debugEvaluateJavascript?.call(
    'parseFloat(getComputedStyle(document.documentElement)'
    ".getPropertyValue('--cue-font-size'))",
  );
  if (raw is num) return raw.toDouble();
  return double.parse(raw.toString());
}

/// 把播种的 `[data-cue-id]` cue 改写成生产里 matcher 命中后的 `fushi-cue://`
/// 形态：EPUB 有声书导入一定经过 `_matchCuesToTtu`，命中的 cue 带
/// `s=<章>&ns=<matchable 起>&ne=<matchable 止>`；章号反查（跳章）与学习单位映射
/// （统计）都只认这种坐标。matchable 文本 = 章纯文本按 [AudioTextNormalizer]
/// 折叠（与 `ReaderAudioPositionIndex` 同一折叠），句子按序在里面找起点。
Future<List<AudioCue>> _rematchedFixtureCues({
  required String bookKey,
  required String title,
  required int cueCount,
}) async {
  final List<AudioCue> cues = buildSampleCues(
    bookKey: bookKey,
    count: cueCount,
  );
  final Uint8List bytes = await buildAudiobookEpubBytes(
    title: title,
    cues: cues,
  );
  final Directory tmp = await Directory.systemTemp.createTemp('lyrics_itest');
  try {
    final EpubBook book = await EpubParser.parse(bytes, tmp.path);
    expect(book.chapters.length, 1, reason: 'fixture 书只有一章');
    final String matchable = AudioTextNormalizer.normalize(
      book.chapterPlainText(0),
    );
    int cursor = 0;
    for (final AudioCue cue in cues) {
      final String needle = AudioTextNormalizer.normalize(cue.text);
      final int start = matchable.indexOf(needle, cursor);
      expect(start, greaterThanOrEqualTo(0),
          reason: 'fixture 句子必须能在合成章正文里按序找到：${cue.text}');
      cue.textFragmentId = SubtitleRematchCodec.encodeHit(
        sectionIndex: 0,
        normCharStart: start,
        normCharEnd: start + needle.length,
      );
      cursor = start + needle.length;
    }
  } finally {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }
  return cues;
}

Future<int> _studyCharsForBook(AppModel appModel, String bookKey) async {
  final List<StudySegmentRow> rows =
      await appModel.database.getStudySegmentsForMedia(
    mediaKind: kActivityMediaBook,
    mediaKey: bookKey,
  );
  int chars = 0;
  for (final StudySegmentRow row in rows) {
    chars += row.chars;
  }
  return chars;
}

Future<bool> _isLyricsDocument() async {
  final dynamic sentinel = await ReaderFushiPage.debugEvaluateJavascript?.call(
    "Boolean(window.__lyricsSetCue && document.getElementById('lc'))",
  );
  return sentinel == true || sentinel == 'true' || sentinel == 1;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'lyrics mode: font-size stepper restyles live and chapter navigation stays',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'lyrics-settings-chapter-nav',
        body: () async {
          await launchFushiTestApp();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home must render before seeding an audiobook',
          );

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          final ReaderFushiSource src = ReaderFushiSource.instance;
          final bool originalLyricsMode = src.lyricsMode;
          final double originalFontSize = src.lyricsFontSize;
          addTearDown(() async {
            await src.setLyricsMode(originalLyricsMode);
            await src.setLyricsFontSize(originalFontSize);
          });
          await src.setLyricsMode(false);
          src.setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);
          // 从一个确定的中间值起步，stepper 往上推两步一定不撞上限。
          await src.setLyricsFontSize(24);

          const String title = 'Lyrics Settings Automation';
          const int cueCount = 5;
          final String bookKey = await seedAudiobook(
            tester,
            title: title,
            // 默认 3s 静音会把第 4 句（7.5s 起）的 seek 钳回音频末尾。
            audioDuration: const Duration(seconds: 15),
            cueCount: cueCount,
          );
          // 开书前把 cue 换成 matcher 命中形态（见 _rematchedFixtureCues）。
          await AudiobookRepository(appModel.database).saveCues(
            bookKey: bookKey,
            cues: await _rematchedFixtureCues(
              bookKey: bookKey,
              title: title,
              cueCount: cueCount,
            ),
          );
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(findNavTargetForTab(HomeTab.books));
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          Finder bookEntry = find.byKey(
            ValueKey<String>(
              'srt_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
            ),
          );
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntry.evaluate().isNotEmpty) break;
            final Finder fallback = find.byKey(
              ValueKey<String>(
                'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
              ),
            );
            if (fallback.evaluate().isNotEmpty) {
              bookEntry = fallback;
              break;
            }
          }
          if (bookEntry.evaluate().isEmpty) {
            await openBookViaProductionPath(tester, bookKey);
          } else {
            expect(
              await driver.focusWidget(bookEntry),
              isTrue,
              reason: 'seeded audiobook card must be focus reachable',
            );
            await driver.activate();
          }
          await _pumpUntil(
            tester,
            _webViewShown,
            reason: 'reader WebView must mount after opening audiobook',
          );
          await _pumpUntil(
            tester,
            _readerContentReady,
            reason: 'reader content must become ready before lyrics mode',
          );

          final AudiobookPlayerController controller =
              await _waitForActiveAudiobook(tester, appModel);
          expect(controller.chapterCueCount, greaterThan(0));

          expect(ReaderFushiPage.debugToggleLyricsMode, isNotNull);
          await ReaderFushiPage.debugToggleLyricsMode!();
          await _pumpUntil(
            tester,
            _lyricsReady,
            reason: 'lyrics page must report ready after enabling lyrics mode',
          );
          expect(
            await _isLyricsDocument(),
            isTrue,
            reason: 'the live WebView document must be LyricsModeHtml',
          );

          // ── ① 设置抽屉里的歌词字号 stepper 必须实时改到 WebView ──
          final double before = await _cueFontSizePx();
          expect(before, closeTo(24, 0.5), reason: '歌词文档初始字号必须是刚设的 24px');

          expect(ReaderFushiPage.debugOpenQuickSettings, isNotNull);
          await ReaderFushiPage.debugOpenQuickSettings!();
          await tester.pump(const Duration(seconds: 1));

          final Finder fontStepper = find.ancestor(
            of: find.text(t.lyrics_font_size),
            matching: find.byType(AdaptiveSettingsStepperRow),
          );
          await _pumpUntil(
            tester,
            () => fontStepper.evaluate().isNotEmpty,
            reason: '歌词模式的「布局显示」页必须渲染歌词字号 stepper',
            polls: 10,
          );
          expect(
            await driver.focusWidget(fontStepper, maxSteps: 60),
            isTrue,
            reason: '歌词字号 stepper 必须是可 Tab 到的焦点停靠点',
          );
          await driver.adjust(steps: 2);
          await tester.pump(const Duration(seconds: 1));

          expect(
            src.lyricsFontSize,
            closeTo(26, 0.5),
            reason: '方向键两步必须把偏好推到 26',
          );
          double after = before;
          for (int i = 0; i < 10 && (after - before).abs() < 0.5; i++) {
            await tester.pump(const Duration(milliseconds: 300));
            after = await _cueFontSizePx();
          }
          await takeScreenshot(binding, 'reader_lyrics_font_stepper');
          expect(
            after,
            closeTo(26, 0.5),
            reason: '歌词字号 stepper 推两步后 WebView 的 --cue-font-size 必须跟到 26px'
                '（before=$before after=$after）',
          );

          await driver.back();
          await tester.pump(const Duration(milliseconds: 500));

          // ── ② 歌词模式顶栏必须仍有章节导航键，跳章走音频定位而不换文档 ──
          await ReaderFushiPage.debugEvaluateJavascript?.call(
            "window.flutter_inappwebview.callHandler('onLyricsTapEmpty');true",
          );
          final Finder header = find.byKey(
            const ValueKey<String>('fushi_desktop_header'),
          );
          await _pumpUntil(
            tester,
            () => header.evaluate().isNotEmpty,
            reason: '歌词模式必须有顶栏',
            polls: 20,
          );
          final Finder navButton = find.byKey(
            const ValueKey<String>('fushi_reader_navigation_button'),
          );
          expect(
            navButton,
            findsOneWidget,
            reason: '歌词模式顶栏必须保留「章节导航」键（用户反馈：没有跳章节按钮）',
          );
          await takeScreenshot(binding, 'reader_lyrics_header_navigation');

          final AudioCue? firstCue = controller.sectionFirstCue(0);
          expect(firstCue, isNotNull, reason: 'fixture 第一章必须有 cue，否则跳章无法定位音频');
          final int firstMs = controller.globalMsOfCue(firstCue!);
          // 先离开章首（跳到第 4 句），跳章后回到首句才是真定位、不是原地不动。
          await controller.skipToCueIndex(3);
          await tester.pump(const Duration(seconds: 1));
          expect(
            controller.globalPosition.inMilliseconds - firstMs,
            greaterThan(500),
            reason: '前置：跳到第 4 句后位置必须离开章首',
          );
          expect(ReaderFushiPage.debugJumpSection, isNotNull);
          await ReaderFushiPage.debugJumpSection!(0);
          await tester.pump(const Duration(seconds: 1));
          expect(src.lyricsMode, isTrue, reason: '歌词模式下跳章不能把歌词模式关掉');
          expect(
            await _isLyricsDocument(),
            isTrue,
            reason: '歌词模式下跳章不能把歌词文档换成 EPUB 章',
          );
          final int posMs = controller.globalPosition.inMilliseconds;
          expect(
            (posMs - firstMs).abs(),
            lessThan(500),
            reason: '歌词模式跳章必须把音频定位到该章首句（pos=$posMs '
                'first=$firstMs）',
          );

          // ── ③ 歌词模式听书要把听过的句子记进字数（BUG-2597）──
          // 站在首句、从头播：cue 0 → 1 → 2 推进两次。账本口径「翻走即计 ∩
          // [0, 当前位置)」：到第 3 句时前两句各 7 个学习单位（标点不计）入账，第 3
          // 句自己还没翻走不计。进歌词前整页 [0,81) 已入账，回到首句那一刻按
          // 「回翻撤回」扣到首句之前——首句前只有章标题「Lyrics Settings
          // Automation」= 3 个拉丁词单位仍算读过。故精确值 = 3 + 7 + 7 = 17。
          // 时钟 60 s 才 tick 落库，用测试钩子直接 flushNow。
          const int expectedChars = 17;
          await controller.play();
          for (int i = 0; i < 40 && controller.allBookCueIdx < 2; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(controller.allBookCueIdx, greaterThanOrEqualTo(2),
              reason: '前置：播放要真的推进到第 3 句');
          await controller.pause();
          await tester.pump(const Duration(milliseconds: 500));
          expect(ReaderFushiPage.debugFlushReadingStats, isNotNull);
          await ReaderFushiPage.debugFlushReadingStats!();
          int chars = -1;
          for (int i = 0; i < 20 && chars != expectedChars; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            chars = await _studyCharsForBook(appModel, bookKey);
          }
          expect(chars, expectedChars,
              reason: '歌词模式听过前两句后 study_segments 里这本书的字数必须是 '
                  '$expectedChars（章标题 3 + 两句各 7）');
        },
      );
    },
  );
}
