import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_chapter_panel.dart';
import 'package:fushi/src/media/video/video_player_controller.dart'
    show VideoChapter;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 视频播放页「跳转回退」胶囊的真机门（Windows 离屏 runner）。
///
/// fixture：ffmpeg 现生成一段 90 秒、三章（0 / 30 / 60 秒）的 MKV。
///
/// 1. 开视频、程序化 seek 到 5 秒（debugSeekMs 走 controller.seekMs，不经入栈判定）
///    → 没有胶囊。
/// 2. 章节面板点第 3 章（调 [VideoChapterPanel.onTapChapter]，即真 UI 接线：
///    入栈判定 + seekToChapter）→ 落到 60 秒附近 → 关面板 → 胶囊出现且可点。
/// 3. 「返回」→ 回到 5 秒（±1.5 s）；「前进」→ 回到 60 秒（±1.5 s）。
/// 4. × → 胶囊消失。
/// 5. 键盘 → （videoSeekForward，seekRelative 步进）→ 位置前进但胶囊不出现。
///
/// 按钮不走坐标点击：先用 `hitTestable` 确认胶囊可见可点，再调按钮 InkWell 的
/// onTap（与 reader_jump_history_itest 同法）。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test/video_jump_history_itest.dart

const String _kBookUid = 'video/itest-jump-history';
const String _kBack = 'fushi_jump_back';
const String _kForward = 'fushi_jump_forward';
const String _kClear = 'fushi_jump_clear';
const int _kOriginMs = 5000;
const int _kJumpChapterIndex = 2;
const int _kJumpTargetMs = 60000;
const int _kToleranceMs = 1500;

Future<File> _generateChapteredMkv() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory root = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi-jump-history-itest-')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await root.create(recursive: true);

  final File metadata = File(
    '${root.path}${Platform.pathSeparator}jump_history_chapters.ffmetadata',
  );
  await metadata.writeAsString('''
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=30000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=30000
END=60000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=60000
END=90000
title=Ending
''');

  final File video = File(
    '${root.path}${Platform.pathSeparator}jump_history_90s.mkv',
  );
  final FfmpegRunResult result = await resolveFfmpegBackend().run(<String>[
    '-hide_banner',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=320x180:rate=10:duration=90',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=channel_layout=stereo:sample_rate=44100',
    '-i',
    metadata.path,
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-map_chapters',
    '2',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    // 关键帧密一点：seek 落点不被关键帧吸附拉偏出 ±1.5 s 容差。
    '-g',
    '10',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-shortest',
    '-t',
    '90',
    video.path,
  ], const Duration(seconds: 90));
  expect(
    result.isSuccess,
    isTrue,
    reason: 'ffmpeg must generate the 90 s MKV: ${result.failureSummary}',
  );
  expect(video.existsSync(), isTrue);
  return video;
}

VideoFushiTestHooks? _hooks(WidgetTester tester) {
  final Finder page = find.byType(VideoFushiPage);
  if (page.evaluate().isEmpty) return null;
  return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
}

bool _pillPresent(String key) =>
    find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

bool _pillClickable(String key) =>
    find.byKey(ValueKey<String>(key)).hitTestable().evaluate().isNotEmpty;

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  int polls = 80,
  Duration step = const Duration(milliseconds: 100),
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

bool _near(int? actual, int expected) =>
    actual != null && (actual - expected).abs() <= _kToleranceMs;

/// 等播放位置落到 [expected] 附近（暂停态 seek 落地要几帧）。
Future<bool> _waitPosition(WidgetTester tester, int expected) => _waitFor(
  tester,
  () => _near(_hooks(tester)?.debugPositionMs, expected),
  polls: 60,
);

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

/// 关章节侧栏：调面板背后那层全屏 barrier 的 onTap（真 UI 的「点面板外关闭」）。
Future<bool> _closeSidePanel(WidgetTester tester) async {
  final Finder panel = find.byType(VideoChapterPanel);
  if (panel.evaluate().isEmpty) return true;
  final Finder barrier = find.byWidgetPredicate(
    (Widget w) =>
        w is GestureDetector &&
        w.behavior == HitTestBehavior.opaque &&
        w.child == null &&
        w.onTap != null,
  );
  final Finder stack = find.ancestor(of: panel, matching: find.byType(Stack));
  final Finder scoped = find.descendant(of: stack.first, matching: barrier);
  if (scoped.evaluate().isEmpty) return false;
  tester.widget<GestureDetector>(scoped.first).onTap!();
  return _waitFor(
    tester,
    () => find.byType(VideoChapterPanel).evaluate().isEmpty,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'video jump history: chapter jump back / forward / clear, step never shows pill',
    timeout: const Timeout(Duration(minutes: 10)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'video-jump-history',
        body: () async {
          final File video = await _generateChapteredMkv();
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          final AppModel appModel = await readyAppModel(tester);
          final VideoBookRepository repo = VideoBookRepository(
            appModel.database,
          );
          await repo.saveVideoBook(
            VideoBooksCompanion(
              bookUid: const Value(_kBookUid),
              title: const Value('itest jump history'),
              videoPath: Value(video.absolute.path),
            ),
          );

          final NavigatorState navigator = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => VideoFushiPage(bookUid: _kBookUid, repo: repo),
              ),
            ),
          );

          final List<String> failures = <String>[];
          void check(bool ok, String what) {
            debugPrint('[video-jump-history] ${ok ? '✓' : '✗'} $what');
            if (!ok) failures.add(what);
          }

          try {
            final bool ready = await _waitFor(
              tester,
              () =>
                  (_hooks(tester)?.debugDurationMs ?? 0) >= 80000 &&
                  (_hooks(tester)?.debugChapterCount ?? 0) >= 3,
              polls: 120,
              step: const Duration(milliseconds: 250),
            );
            expect(ready, isTrue, reason: 'video + chapters should load');
            final VideoFushiTestHooks hooks = _hooks(tester)!;

            // ── ① 出发点：程序化 seek 不入栈，开视频后没有胶囊 ──────────────
            await hooks.debugPause();
            await hooks.debugSeekMs(_kOriginMs);
            check(
              await _waitPosition(tester, _kOriginMs),
              'programmatic seek lands at ${_kOriginMs}ms '
              '(pos=${_hooks(tester)?.debugPositionMs})',
            );
            await _pumpFor(tester, const Duration(milliseconds: 500));
            check(!_pillPresent(_kBack), 'no pill before any user jump');

            // ── ② 章节跳转（真 UI 接线）→ 胶囊出现且可点 ───────────────────
            hooks.debugShowChapterPanel();
            check(
              await _waitFor(
                tester,
                () => find.byType(VideoChapterPanel).evaluate().isNotEmpty,
              ),
              'chapter panel opened',
            );
            final VideoChapterPanel panel = tester.widget<VideoChapterPanel>(
              find.byType(VideoChapterPanel),
            );
            final VideoChapter target =
                panel.controller.chapters[_kJumpChapterIndex];
            panel.onTapChapter(target);
            check(
              await _waitPosition(tester, _kJumpTargetMs),
              'chapter jump lands at ${_kJumpTargetMs}ms '
              '(pos=${_hooks(tester)?.debugPositionMs})',
            );
            check(await _closeSidePanel(tester), 'chapter panel closed');
            check(
              await _waitFor(tester, () => _pillClickable(_kBack)),
              'pill back button visible + hit-testable after jump',
            );
            check(
              !_pillPresent(_kForward),
              'no forward button before going back',
            );

            // ── ③ 返回 / 前进 ─────────────────────────────────────────────
            check(await _press(tester, _kBack), 'pressed back');
            check(
              await _waitPosition(tester, _kOriginMs),
              'back returns to ${_kOriginMs}ms '
              '(pos=${_hooks(tester)?.debugPositionMs})',
            );
            check(
              await _waitFor(tester, () => _pillClickable(_kForward)),
              'forward button visible + hit-testable after back',
            );
            check(await _press(tester, _kForward), 'pressed forward');
            check(
              await _waitPosition(tester, _kJumpTargetMs),
              'forward returns to ${_kJumpTargetMs}ms '
              '(pos=${_hooks(tester)?.debugPositionMs})',
            );

            // ── ④ × 清空 ──────────────────────────────────────────────────
            check(
              await _waitFor(tester, () => _pillClickable(_kClear)),
              'clear button visible + hit-testable',
            );
            check(await _press(tester, _kClear), 'pressed clear');
            await _pumpFor(tester, const Duration(seconds: 1));
            check(
              !_pillPresent(_kBack) && !_pillPresent(_kClear),
              'pill gone after clear',
            );

            // ── ⑤ 步进（键盘 → = seekRelative）不让胶囊出现 ────────────────
            final FocusNode videoNode = tester
                .widget<Video>(find.byType(Video))
                .focusNode!;
            for (int i = 0; i < 20 && !videoNode.hasFocus; i++) {
              videoNode.requestFocus();
              await tester.pump(const Duration(milliseconds: 150));
            }
            final int before = _hooks(tester)?.debugPositionMs ?? -1;
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            final bool stepped = await _waitFor(
              tester,
              () => (_hooks(tester)?.debugPositionMs ?? -1) > before + 1000,
              polls: 40,
            );
            final int after = _hooks(tester)?.debugPositionMs ?? -1;
            check(
              stepped && after - before < 15000,
              'arrow-right steps forward by < 15 s '
              '(before=$before after=$after)',
            );
            await _pumpFor(tester, const Duration(milliseconds: 500));
            check(!_pillPresent(_kBack), 'step seek does not show the pill');
          } finally {
            await navigator.maybePop();
            await _waitFor(
              tester,
              () => find.byType(VideoFushiPage).evaluate().isEmpty,
              polls: 40,
            );
          }
          for (final String f in failures) {
            debugPrint('[video-jump-history]   ✗ $f');
          }
          expect(failures, isEmpty, reason: failures.join('\n'));
        },
      );
    },
  );
}
