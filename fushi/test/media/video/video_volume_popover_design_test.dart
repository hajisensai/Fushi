import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_apple_chrome.dart';
import 'package:fushi/src/media/video/video_volume_overlays.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';

// 反馈 DYSX-jy-6K「音量控制仍为 MD2 样式，未跟随新界面设计」：视频音量浮层的
// 滑条曾用 RoundSliderThumbShape + 3px 细轨覆写主题（2023 版圆钮细轨），外框也
// 不分设计系统。这里按两套设计系统真实渲染断言：
// - MD3E：主题的 2024 版滑块（year2023 false、非圆钮、粗轨道），外框是调用方
//   给的 M3E 中性面；
// - Apple：外框是深色液态玻璃 HUD，滑条是 iOS 滑块（没有 Material Slider）。

const Color _kM3eSurface = Color(0xFF223344);

Future<void> _pump(
  WidgetTester tester, {
  required bool apple,
  double uiScale = 1,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    ),
    textTheme: Typography.material2021().white,
    glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: apple,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(
            child: Builder(
              builder: (BuildContext context) => VideoVolumePopoverCard(
                width: 240 * uiScale,
                value: 42,
                uiScale: uiScale,
                colorScheme: Theme.of(context).colorScheme,
                m3eSurfaceColor: _kM3eSurface,
                icon: Icons.volume_up,
                tooltip: 'Mute',
                onToggleMute: () {},
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final double uiScale in <double>[1, 1.5]) {
    testWidgets('MD3E volume popover uses the 2024 slider, not the MD2 round '
        'thumb (scale $uiScale)', (WidgetTester tester) async {
      await _pump(tester, apple: false, uiScale: uiScale);
      expect(find.byType(Slider), findsOneWidget);
      final SliderThemeData slider = SliderTheme.of(
        tester.element(find.byType(Slider)),
      );
      // ignore: deprecated_member_use
      expect(slider.year2023, isFalse);
      expect(slider.thumbShape, isNot(isA<RoundSliderThumbShape>()));
      expect(slider.trackHeight, closeTo(16 * uiScale, 0.01));
      final Size? handle = slider.thumbSize?.resolve(<WidgetState>{});
      expect(handle, isNotNull);
      expect(handle!.width, 4);
      expect(handle.height, closeTo(40 * uiScale, 0.01));

      final DecoratedBox frame = tester.widget<DecoratedBox>(
        find.byKey(videoVolumePopoverFrameKey),
      );
      expect((frame.decoration as BoxDecoration).color, _kM3eSurface);
      expect(
        tester.getSize(find.byKey(videoVolumePopoverFrameKey)).height,
        closeTo(56 * uiScale, 0.1),
      );
      expect(find.byType(VideoGlassHud), findsNothing);
    });
  }

  testWidgets('Apple volume popover is a glass HUD with the iOS slider', (
    WidgetTester tester,
  ) async {
    await _pump(tester, apple: true);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(FushiAppleSlider), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(videoVolumePopoverFrameKey),
        matching: find.byType(VideoGlassHud),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(videoVolumePopoverFrameKey)).width,
      closeTo(240, 0.1),
    );
    final Text percent = tester.widget<Text>(find.text('42%'));
    expect(percent.style?.color, Colors.white);
  });
}
