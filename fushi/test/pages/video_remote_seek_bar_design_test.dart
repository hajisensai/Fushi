// 遥控卡进度条随设计系统分派：Apple 下是 iOS 滑块（FushiAppleSlider），不再显示
// M3E 的波浪进度条（FushiWavySeekBar）；MD3 保持波浪条。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_card.dart'
    show VideoRemoteSeekBar;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiAppleSlider;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial, FushiGlassTheme;
import 'package:material_ui/material_ui.dart';

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(minutes: 1);

  @override
  Duration get duration => const Duration(minutes: 4);
}

Widget _host(bool apple, List<Duration> seeks) => MaterialApp(
  theme: ThemeData(
    extensions: <ThemeExtension<dynamic>>[
      FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
    ],
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 320,
        child: VideoRemoteSeekBar(
          clock: _Clock(),
          isPlaying: false,
          onSeek: seeks.add,
          strokeWidth: 4,
          barHeight: 28,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('Apple：iOS 滑块 + 已播 / 剩余时间，没有波浪条', (WidgetTester tester) async {
    await tester.pumpWidget(_host(true, <Duration>[]));
    await tester.pump();
    expect(find.byType(FushiAppleSlider), findsOneWidget);
    expect(find.byType(FushiWavySeekBar), findsNothing);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('-3:00'), findsOneWidget);
    final FushiAppleSlider slider = tester.widget(
      find.byType(FushiAppleSlider),
    );
    expect(slider.value, closeTo(0.25, 1e-9));
  });

  testWidgets('Apple：点轨道松手才 seek，换算成总时长的比例', (WidgetTester tester) async {
    final List<Duration> seeks = <Duration>[];
    await tester.pumpWidget(_host(true, seeks));
    await tester.pump();
    final Rect rect = tester.getRect(find.byType(FushiAppleSlider));
    await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single.inSeconds, closeTo(120, 12));
  });

  testWidgets('MD3：保持 M3E 波浪进度条', (WidgetTester tester) async {
    await tester.pumpWidget(_host(false, <Duration>[]));
    await tester.pump();
    expect(find.byType(FushiWavySeekBar), findsOneWidget);
    expect(find.byType(FushiAppleSlider), findsNothing);
  });
}
