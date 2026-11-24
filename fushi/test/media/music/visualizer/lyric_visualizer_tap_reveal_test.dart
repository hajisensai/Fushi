// BUG-5367（反馈 0i-FWiMxFO）：全屏歌词动画单击任意位置就退出。
// 单击只唤出悬停控制条；退出只走 Esc、返回键和控制条上的退出按钮。

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/pages/implementations/music/music_lyric_visualizer_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;

import 'visualizer_test_helpers.dart';

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(milliseconds: 1200);

  @override
  Duration get duration => const Duration(minutes: 4);
}

Future<void> _pumpView(WidgetTester tester, VoidCallback onExit) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MusicLyricVisualizerView(
          mode: LyricVisualizerMode.still,
          timeline: sampleWordTimeline(),
          clock: _Clock(),
          offsetMs: 0,
          playing: false,
          trackUid: 't',
          tunings: const <String, Map<String, Object?>>{},
          fontScale: 1,
          onExit: onExit,
          onPickStyle: () {},
        ),
      ),
    ),
  );
  // initState 的帧后回调把焦点交给画面，Esc 才收得到。
  await tester.pump(const Duration(milliseconds: 50));
}

/// 悬停控制条（含退出按钮）当前的不透明度。
double _hoverBarOpacity(WidgetTester tester) {
  final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
    find
        .ancestor(
          of: find.byKey(const ValueKey<String>('music_visualizer_exit')),
          matching: find.byType(AnimatedOpacity),
        )
        .first,
  );
  return fade.opacity;
}

void main() {
  testWidgets('单击画面不退出，只唤出控制条；2 秒后控制条自动收起', (WidgetTester tester) async {
    int exits = 0;
    await _pumpView(tester, () => exits++);
    expect(_hoverBarOpacity(tester), 0, reason: '初始不显示控制条');

    await tester.tapAt(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 50));
    expect(exits, 0, reason: '单击画面不得退出动画');
    expect(_hoverBarOpacity(tester), 1, reason: '单击唤出控制条（触屏唯一唤出途径）');

    await tester.pump(const Duration(seconds: 3));
    expect(_hoverBarOpacity(tester), 0, reason: '控制条照常自动收起');
    expect(exits, 0);
  });

  testWidgets('单击唤出控制条后，点退出按钮才退出', (WidgetTester tester) async {
    int exits = 0;
    await _pumpView(tester, () => exits++);

    await tester.tapAt(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey<String>('music_visualizer_exit')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(exits, 1, reason: '退出按钮只触发一次退出');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('按 Esc 退出', (WidgetTester tester) async {
    int exits = 0;
    await _pumpView(tester, () => exits++);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(exits, 1);
  });
}
