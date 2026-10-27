// Ix4j5SKUth：视频「循环当前句」开关（默认不绑键）。
//
// 控制器层钉死状态机：开着时**自然播放**越过武装句句尾才回到它的句首（落点 = 跳句
// 同款 preRoll 落点）；显式 seek（±秒 / 拖进度条 / 跳句）撤武装，不会把人拽回原句；
// 回绕之后滞后的旧位置 tick 不连发；暂停中不回绕；一次性「播完就停」优先；关掉即恢复
// 正常往下播。UI 层：常驻标记随开关显隐、点它关闭；页面接线源码守卫。
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_loop_cue_badge.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

/// cue1 = 2000–3000，前一句起点 0 → 跳句落点 = 2000 - preRoll。
const int _cue1Landing = 2000 - VideoPlayerController.kCueSeekPreRollMs;

({VideoPlayerController c, List<String> actions}) _setUp({
  bool playing = true,
}) {
  final List<String> actions = <String>[];
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[
    _cue(0, 0, 1000),
    _cue(1, 2000, 3000),
    _cue(2, 3000, 4000),
    _cue(3, 6000, 7000),
  ]);
  c.debugSetSubtitleEndHoldHooksForTesting(
    isPlaying: () => playing,
    onPause: () async => actions.add('pause'),
    onPlay: () async => actions.add('play'),
  );
  return (c: c, actions: actions);
}

void main() {
  group('VideoPlayerController 循环当前句', () {
    test('开着：自然播过句尾回到句首（相邻下一句与 gap 两条路径）', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(2500); // 进入 cue1 → 武装
      c.debugUpdateCueForPosition(3100); // 越过句尾进入首尾相接的 cue2
      expect(c.seekGeneration, gen0 + 1, reason: '回绕一次');
      expect(c.resumePositionMs, _cue1Landing);

      // 滞后的旧位置 tick（seek 还没落地）不连发回绕。
      c.debugUpdateCueForPosition(3200);
      expect(c.seekGeneration, gen0 + 1);

      // 落回句首、重新进入句内 → 再次武装；这次句尾后是 gap（cue2 → cue3 之间）。
      c.debugUpdateCueForPosition(2100);
      c.debugUpdateCueForPosition(2900);
      c.debugUpdateCueForPosition(3050);
      expect(c.seekGeneration, gen0 + 2);
    });

    test('句尾后落进 gap 也回绕', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(3500); // cue2 3000–4000
      c.debugUpdateCueForPosition(4300); // gap
      expect(c.seekGeneration, gen0 + 1);
    });

    test('关着：照常往下播，不回绕', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100);
      expect(c.seekGeneration, gen0);
    });

    test('显式 seek 离开武装句（±秒 / 跳句）不被拽回', () async {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      c.debugUpdateCueForPosition(2500); // 武装 cue1
      final int gen0 = c.seekGeneration;
      await c.seekMs(5000); // 用户 seek 到 gap（seek 内的权威同步就会读到 5000）
      c.debugUpdateCueForPosition(5100);
      expect(c.seekGeneration, gen0 + 1, reason: '只有用户那一次 seek，没有回绕');
    });

    test('进度条拖走（fork 内部直发 seek，只有 clearSeekTargetSnap 信号）不被拽回', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      c.debugUpdateCueForPosition(2500); // 武装 cue1
      c.clearSeekTargetSnap(); // 进度条开始拖动
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(6500); // 拖到 cue3
      expect(c.seekGeneration, gen0);
    });

    test('跳到别的句：循环的是新进入的那句', () async {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      c.debugUpdateCueForPosition(2500);
      await c.skipToCue(c.cues[3]);
      c.debugUpdateCueForPosition(6500); // 进入 cue3 → 武装
      final int gen = c.seekGeneration;
      c.debugUpdateCueForPosition(7200);
      expect(c.seekGeneration, gen + 1);
    });

    test('暂停中不回绕（逐帧步进越过句尾不算播完）', () {
      final (:VideoPlayerController c, actions: _) = _setUp(playing: false);
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      final int gen0 = c.seekGeneration;
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100);
      expect(c.seekGeneration, gen0);
    });

    test('一次性「播完这句就停」优先于循环', () async {
      final (:VideoPlayerController c, :List<String> actions) = _setUp();
      addTearDown(c.dispose);
      c.setLoopCurrentCue(true);
      await c.replayCue(c.cues[1]);
      actions.clear();
      c.debugUpdateCueForPosition(2500);
      c.debugUpdateCueForPosition(3100);
      await Future<void>.delayed(Duration.zero);
      expect(actions, contains('pause'), reason: '句尾停下');
    });

    test('开关只在翻转时通知 loopCurrentCueListenable', () {
      final (:VideoPlayerController c, actions: _) = _setUp();
      addTearDown(c.dispose);
      final ValueListenable<bool> l = c.loopCurrentCueListenable;
      int notified = 0;
      l.addListener(() => notified++);
      c.setLoopCurrentCue(true);
      c.setLoopCurrentCue(true);
      c.setLoopCurrentCue(false);
      expect(notified, 2);
      expect(c.loopCurrentCue, isFalse);
    });
  });

  group('VideoLoopCueBadge', () {
    testWidgets('随开关显隐，点它回调（关闭循环）', (WidgetTester tester) async {
      int taps = 0;
      Widget build(bool active) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: VideoLoopCueBadge(
              active: active,
              label: '循环当前句',
              tooltip: '点击停止循环',
              onTap: () => taps++,
              surfaceColor: Colors.black,
              textColor: Colors.white,
            ),
          ),
        ),
      );
      await tester.pumpWidget(build(false));
      expect(find.text('循环当前句'), findsNothing);
      await tester.pumpWidget(build(true));
      await tester.pumpAndSettle();
      expect(find.text('循环当前句'), findsOneWidget);
      await tester.tap(find.text('循环当前句'));
      expect(taps, 1);
      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      expect(find.text('循环当前句'), findsNothing);
    });
  });

  test('默认空绑定（不抢 R / Ctrl+R）', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        platform,
      )[ShortcutAction.videoToggleLoopCurrentSubtitle]!;
      expect(set.keyboardBindings, isEmpty, reason: '$platform');
      expect(set.gamepadBindings, isEmpty, reason: '$platform');
    }
  });

  test('视频页接线：动作切换控制器循环态，画面挂常驻标记', () {
    final String src = readVideoFushiSource();
    expect(
      src.contains('_runWhenImmersiveAllowsShortcuts(_toggleLoopCurrentCue)'),
      isTrue,
    );
    final String toggle = methodBody(src, 'void _toggleLoopCurrentCue()');
    expect(toggle, contains('controller.setLoopCurrentCue(next)'));
    expect(src.contains('_buildLoopCueBadgeOverlay(controller),'), isTrue);
    final String overlay = methodBody(src, 'Widget _buildLoopCueBadgeOverlay(');
    expect(overlay, contains('controller.loopCurrentCueListenable'));
    expect(overlay, contains('VideoLoopCueBadge('));
  });
}
