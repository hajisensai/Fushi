import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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
import 'package:fushi_engine/epub/epub_book.dart' show EpubBook;
import 'package:fushi_engine/epub/epub_parser.dart' show EpubParser;
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedAudiobook,
        seedReaderBook;
import 'helpers/media_fixtures.dart'
    show buildAudiobookEpubBytes, buildSampleCues;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说阅读器「跳转回退」胶囊的真机门（Windows 离屏 runner）。
///
/// 1. 正文跳转 × 翻页 / 滚动 / VN 三种 view mode：开书无胶囊 → 长章翻几页记下
///    位置 A → 目录跳到短章 → 胶囊出现 → 「返回」落回长章 A 附近（VN 同屏）→
///    「前进」落回短章 → × 清空后胶囊消失。
/// 2. 有声书：正文态拖进度（[AudiobookPlayerController.seekGlobalMs]，≥15 s）→
///    顶部胶囊出现 → 返回回到原播放位置；歌词模式同样一遍，胶囊挂在歌词层上。
///
/// 按钮不走坐标点击：调用胶囊按钮 InkWell 的 onTap（即真 UI 的接线），并先用
/// `hitTestable` 确认胶囊此刻真的可见可点。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test/reader_jump_history_itest.dart

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');
const String _kBack = 'fushi_jump_back';
const String _kForward = 'fushi_jump_forward';
const String _kClear = 'fushi_jump_clear';

const List<String> _kViewModes = <String>['paginated', 'continuous', 'vn'];
const int _kShortChapter = 1; // chapter_02_short
const int _kLongChapter = 6; // chapter_07_long

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

bool _pillPresent(String key) =>
    find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

bool _pillClickable(String key) =>
    find.byKey(ValueKey<String>(key)).hitTestable().evaluate().isNotEmpty;

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  int polls = 120,
  Duration step = const Duration(milliseconds: 250),
}) async {
  for (int i = 0; i < polls; i++) {
    if (ready()) return true;
    await tester.pump(step);
  }
  return ready();
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final DateTime end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Map<String, dynamic>> _js(String source) async {
  final Future<dynamic> Function(String source)? run =
      ReaderFushiPage.debugEvaluateJavascript;
  if (run == null) return <String, dynamic>{'error': 'no JS hook'};
  try {
    final Object? raw = await run(source);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final Object? decoded = jsonDecode(raw?.toString() ?? 'null');
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{'value': decoded};
  } catch (e) {
    return <String, dynamic>{'error': '$e'};
  }
}

const String _positionJs = r'''
(function () {
  var r = window.fushiReader;
  return JSON.stringify({
    file: (document.baseURI || '').split('/').pop(),
    firstChar: (r && typeof r.getFirstVisibleCharOffset === 'function')
      ? r.getFirstVisibleCharOffset() : -1,
    vnIdx: (r && typeof r.currentScreenIndex === 'number') ? r.currentScreenIndex : -1
  });
})()
''';

int _int(Object? v) => (v as num?)?.toInt() ?? -1;

/// 「按」胶囊按钮：先确认可见可点，再调它 InkWell 的 onTap。
Future<bool> _press(WidgetTester tester, String key) async {
  if (!_pillClickable(key)) return false;
  final Finder ink = find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(InkWell),
  );
  if (ink.evaluate().isEmpty) return false;
  tester.widget<InkWell>(ink.first).onTap!();
  await tester.pump(const Duration(milliseconds: 100));
  return true;
}

Future<bool> _open(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  final bool webView = await _waitFor(
    tester,
    () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
  );
  final bool ready = await _waitFor(tester, _contentReady, polls: 240);
  final bool hooks = await _waitFor(
    tester,
    () => ReaderFushiPage.debugEvaluateJavascript != null,
    polls: 40,
  );
  await _pumpFor(tester, const Duration(seconds: 2));
  return webView && ready && hooks;
}

Future<void> _close(WidgetTester tester) async {
  if (_readerGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerGone, polls: 80);
  await _pumpFor(tester, const Duration(seconds: 1));
}

/// 等到 DOM 落在 [fileHint] 那一章并 settle。
Future<Map<String, dynamic>?> _waitForFile(
  WidgetTester tester,
  String fileHint,
) async {
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (!_contentReady()) continue;
    final Map<String, dynamic> pos = await _js(_positionJs);
    if ((pos['file'] as String? ?? '').contains(fileHint)) {
      await _pumpFor(tester, const Duration(milliseconds: 1500));
      return _js(_positionJs);
    }
  }
  return null;
}

Future<void> _pageDown(WidgetTester tester, int times) async {
  for (int i = 0; i < times; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _pumpFor(tester, const Duration(milliseconds: 600));
  }
}

Future<void> _runViewMode(
  WidgetTester tester,
  ReaderFushiSource source,
  String bookKey,
  String viewMode,
  List<String> failures,
  Map<String, Object?> evidence,
) async {
  void check(bool ok, String what) {
    if (!ok) failures.add('$viewMode: $what');
  }

  await source.setReaderViewMode(viewMode);
  await _pumpFor(tester, const Duration(milliseconds: 800));
  final bool ready = await _open(tester, bookKey);
  check(ready, 'content never ready on open');
  if (!ready) return;
  check(!_pillPresent(_kBack), 'pill shown before any jump');

  // 到长章翻几页：位置 A。
  await ReaderFushiPage.debugJumpSection!(_kLongChapter);
  final Map<String, dynamic>? onLong = await _waitForFile(
    tester,
    'chapter_07_long',
  );
  check(onLong != null, 'jump to long chapter did not land');
  if (onLong == null) return;
  await _pageDown(tester, 3);
  await _pumpFor(tester, const Duration(seconds: 2));
  final Map<String, dynamic> a = await _js(_positionJs);
  final int perPage = ((_int(a['firstChar']) - _int(onLong['firstChar'])) / 3)
      .round()
      .abs();

  // 目录跳到短章 → 胶囊出现。
  await ReaderFushiPage.debugJumpSection!(_kShortChapter);
  final Map<String, dynamic>? onShort = await _waitForFile(
    tester,
    'chapter_02_short',
  );
  check(onShort != null, 'jump to short chapter did not land');
  if (onShort == null) return;
  final bool shown = await _waitFor(tester, () => _pillClickable(_kBack));
  check(shown, 'back pill not visible after a chapter jump');
  try {
    final ObserveShot shot = await captureFlutterFrame(
      tester,
      'jump-history-$viewMode-after-jump',
    );
    evidence['$viewMode.shotAfterJump'] = shot.path;
  } catch (e) {
    evidence['$viewMode.shotAfterJump'] = 'capture failed: $e';
  }

  // 返回 → 长章 A。
  check(await _press(tester, _kBack), 'could not press back');
  final Map<String, dynamic>? back = await _waitForFile(
    tester,
    'chapter_07_long',
  );
  check(back != null, 'back did not return to the long chapter');
  evidence['$viewMode.a'] = a;
  evidence['$viewMode.back'] = back;
  if (back != null) {
    if (viewMode == 'vn') {
      check(
        _int(back['vnIdx']) == _int(a['vnIdx']),
        'back landed on VN screen ${back['vnIdx']} instead of ${a['vnIdx']}',
      );
    } else {
      final int drift = (_int(back['firstChar']) - _int(a['firstChar'])).abs();
      check(
        _int(a['firstChar']) <= 0 || drift <= perPage * 1.5 + 20,
        'back drifted $drift chars from A (one page ≈ $perPage)',
      );
    }
  }
  check(
    await _waitFor(tester, () => _pillClickable(_kForward)),
    'forward button not visible after going back',
  );

  // 前进 → 短章。
  check(await _press(tester, _kForward), 'could not press forward');
  final Map<String, dynamic>? fwd = await _waitForFile(
    tester,
    'chapter_02_short',
  );
  check(fwd != null, 'forward did not return to the short chapter');
  evidence['$viewMode.forward'] = fwd;

  // × 清空 → 胶囊消失。
  await _waitFor(tester, () => _pillClickable(_kClear));
  check(await _press(tester, _kClear), 'could not press clear');
  await _pumpFor(tester, const Duration(seconds: 1));
  check(!_pillPresent(_kBack), 'pill still present after clear');
  await _close(tester);
}

/// 把播种 cue 改写成 matcher 命中形态（同 reader_lyrics_settings_and_chapter_nav_itest）。
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
  final Directory tmp = await Directory.systemTemp.createTemp('jump_itest');
  try {
    final EpubBook book = await EpubParser.parse(bytes, tmp.path);
    final String matchable = AudioTextNormalizer.normalize(
      book.chapterPlainText(0),
    );
    int cursor = 0;
    for (final AudioCue cue in cues) {
      final String needle = AudioTextNormalizer.normalize(cue.text);
      final int start = matchable.indexOf(needle, cursor);
      expect(start, greaterThanOrEqualTo(0));
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

/// 音频跳 [targetMs] → 胶囊可点 → 返回回到 [originMs] 附近 → 清空。
Future<void> _audioRoundTrip(
  WidgetTester tester,
  AudiobookPlayerController controller,
  String label,
  int targetMs,
  List<String> failures,
  Map<String, Object?> evidence,
) async {
  void check(bool ok, String what) {
    if (!ok) failures.add('$label: $what');
  }

  final int originMs = controller.globalPosition.inMilliseconds;
  await controller.seekGlobalMs(targetMs);
  await _pumpFor(tester, const Duration(seconds: 1));
  final int landedMs = controller.globalPosition.inMilliseconds;
  evidence['$label.origin'] = originMs;
  evidence['$label.landed'] = landedMs;
  check((landedMs - targetMs).abs() < 1500, 'seek did not land ($landedMs)');
  check(
    await _waitFor(tester, () => _pillClickable(_kBack)),
    'back pill not visible after an audio scrub',
  );
  try {
    final ObserveShot shot = await captureFlutterFrame(
      tester,
      'jump-history-$label',
    );
    evidence['$label.shot'] = shot.path;
  } catch (e) {
    evidence['$label.shot'] = 'capture failed: $e';
  }
  check(await _press(tester, _kBack), 'could not press back');
  await _pumpFor(tester, const Duration(seconds: 2));
  final int backMs = controller.globalPosition.inMilliseconds;
  evidence['$label.back'] = backMs;
  check(
    (backMs - originMs).abs() < 1500,
    'back went to $backMs instead of $originMs',
  );
  await _waitFor(tester, () => _pillClickable(_kClear));
  check(await _press(tester, _kClear), 'could not press clear');
  await _pumpFor(tester, const Duration(seconds: 1));
  check(!_pillPresent(_kBack), 'pill still present after clear');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'jump history: text jumps back/forward in paginated / continuous / vn',
    timeout: const Timeout(Duration(minutes: 30)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'jump-history-text',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await _pumpFor(tester, const Duration(seconds: 2));
          await readyAppModel(tester);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String baseViewMode = source.readerViewMode;
          final List<String> failures = <String>[];
          final Map<String, Object?> evidence = <String, Object?>{};
          try {
            final String bookKey = await seedReaderBook(
              tester,
              fileName: 'jump_history.epub',
            );
            for (final String viewMode in _kViewModes) {
              try {
                await _runViewMode(
                  tester,
                  source,
                  bookKey,
                  viewMode,
                  failures,
                  evidence,
                );
              } catch (e, st) {
                failures.add('$viewMode: threw $e\n$st');
                await _close(tester);
              }
            }
          } finally {
            await _close(tester);
            await source.setReaderViewMode(baseViewMode);
          }
          debugPrint('[jump-history] text evidence=${jsonEncode(evidence)}');
          for (final String f in failures) {
            debugPrint('[jump-history]   ✗ $f');
          }
          expect(failures, isEmpty, reason: failures.join('\n'));
        },
      );
    },
  );

  testWidgets(
    'jump history: audiobook scrub back in reading mode and lyrics mode',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'jump-history-audio',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          final AppModel appModel = await readyAppModel(tester);
          final ReaderFushiSource src = ReaderFushiSource.instance;
          final bool originalLyricsMode = src.lyricsMode;
          addTearDown(() async {
            await src.setLyricsMode(originalLyricsMode);
          });
          await src.setLyricsMode(false);
          src.setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);

          const String title = 'Jump History Audio';
          // 单文件书的全书时间轴按 cue 估算时长（每句 2.5 s）：40 句 ≈ 100 s，
          // 才放得下 60 s / 90 s 的拖动落点。
          const int cueCount = 40;
          final String bookKey = await seedAudiobook(
            tester,
            title: title,
            audioDuration: const Duration(seconds: 120),
            cueCount: cueCount,
          );
          await AudiobookRepository(appModel.database).saveCues(
            bookKey: bookKey,
            cues: await _rematchedFixtureCues(
              bookKey: bookKey,
              title: title,
              cueCount: cueCount,
            ),
          );
          expect(await _open(tester, bookKey), isTrue);
          AudiobookPlayerController? controller;
          for (int i = 0; i < 80 && controller == null; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            final AudiobookPlayerController? c =
                appModel.audiobookSession.controller;
            if (c != null && c.chapterCueCount > 0) controller = c;
          }
          expect(controller, isNotNull, reason: 'audiobook must attach');
          // 播放器首次激活前没有时长、seek 会被守卫丢掉：先播一下再停（与用户
          // 拖进度前已经在听的真实状态一致）。起点附近的小步移动不算跳转。
          await controller!.play();
          await _pumpFor(tester, const Duration(seconds: 2));
          await controller.pause();
          await _pumpFor(tester, const Duration(seconds: 1));
          expect(_pillPresent(_kBack), isFalse);

          final List<String> failures = <String>[];
          final Map<String, Object?> evidence = <String, Object?>{};
          try {
            await _audioRoundTrip(
              tester,
              controller,
              'audio-reading',
              60000,
              failures,
              evidence,
            );
            await ReaderFushiPage.debugToggleLyricsMode!();
            final bool lyrics = await _waitFor(
              tester,
              () => find
                  .byKey(const ValueKey<String>('fushi_lyrics_ready'))
                  .evaluate()
                  .isNotEmpty,
              polls: 120,
            );
            if (!lyrics) failures.add('lyrics mode never became ready');
            await _pumpFor(tester, const Duration(seconds: 1));
            await _audioRoundTrip(
              tester,
              controller,
              'audio-lyrics',
              90000,
              failures,
              evidence,
            );
          } finally {
            await _close(tester);
          }
          debugPrint('[jump-history] audio evidence=${jsonEncode(evidence)}');
          for (final String f in failures) {
            debugPrint('[jump-history]   ✗ $f');
          }
          expect(failures, isEmpty, reason: failures.join('\n'));
        },
      );
    },
  );
}
