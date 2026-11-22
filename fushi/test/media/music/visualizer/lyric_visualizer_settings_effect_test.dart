// 设置 › 音乐 › 歌词动画几行的生效证据（settings_schema_coverage_test 的 kCoveredElsewhere 指到这里）：
// 歌词页把偏好原样交给宿主（music_lyrics_page `_buildVisualizer`），这里咬住宿主 → 样式 context。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/still/still_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_visualizer.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  required LyricVisualizerMode mode,
  LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
  double fontScale = 1,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MusicLyricVisualizerView(
          mode: mode,
          timeline: sampleWordTimeline(),
          clock: _Clock(),
          offsetMs: 0,
          playing: false,
          trackUid: 't',
          tunings: const <String, Map<String, Object?>>{},
          fontScale: fontScale,
          intensity: intensity,
          onExit: () {},
          onPickStyle: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('样式偏好：宿主画的就是选中的样式', (WidgetTester tester) async {
    await _pump(tester, mode: LyricVisualizerMode.still);
    expect(find.byType(StillVisualizer), findsOneWidget);
    expect(find.byType(LuminousVisualizer), findsNothing);
    await _pump(tester, mode: LyricVisualizerMode.luminous);
    expect(find.byType(LuminousVisualizer), findsOneWidget);
    expect(find.byType(StillVisualizer), findsNothing);
  });

  testWidgets('强度与字号偏好进样式 context', (WidgetTester tester) async {
    await _pump(
      tester,
      mode: LyricVisualizerMode.still,
      intensity: LyricVisualizerIntensity.chaotic,
      fontScale: 1.5,
    );
    final StillVisualizer w = tester.widget(find.byType(StillVisualizer));
    expect(w.context.intensity, LyricVisualizerIntensity.chaotic);
    expect(w.context.fontScale, 1.5);

    await _pump(
      tester,
      mode: LyricVisualizerMode.still,
      intensity: LyricVisualizerIntensity.calm,
      fontScale: 0.8,
    );
    final StillVisualizer w2 = tester.widget(find.byType(StillVisualizer));
    expect(w2.context.intensity, LyricVisualizerIntensity.calm);
    expect(w2.context.fontScale, 0.8);
  });

  test('每首随机：按曲目确定、不同曲目能抽到不同样式', () {
    expect(
      lyricVisualizerRandomModeFor('track-a'),
      lyricVisualizerRandomModeFor('track-a'),
    );
    final Set<LyricVisualizerMode> seen = <LyricVisualizerMode>{
      for (int i = 0; i < 64; i++) lyricVisualizerRandomModeFor('track-$i'),
    };
    expect(seen.length, greaterThan(4));
  });
}
