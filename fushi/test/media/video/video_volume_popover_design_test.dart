import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_apple_chrome.dart';
import 'package:fushi/src/media/video/video_volume_overlays.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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

  // 审查 major：倍速浮层读数写死页面 cs.onSurface，Apple 浅色主题下黑字压在恒
  // 深色的玻璃 HUD 上看不清。外框现在向内容提供匹配底色的主题与前景。
  testWidgets('Apple light theme: speed + volume popovers use the dark-tier '
      'foreground on the always-dark glass HUD', (WidgetTester tester) async {
    final ThemeData theme = _theme(apple: true, brightness: Brightness.light);
    // 前提：页面浅色主题的 onSurface 近黑——正是旧实现写死的颜色。
    expect(_contrast(theme.colorScheme.onSurface, _kGlassDark), lessThan(2));

    await _pumpPopovers(tester, theme);
    expect(
      find.descendant(
        of: find.byKey(videoSpeedPopoverFrameKey),
        matching: find.byType(VideoGlassHud),
      ),
      findsOneWidget,
    );

    final Text readout = tester.widget<Text>(
      find.byKey(videoSpeedPopoverReadoutKey),
    );
    final Text percent = tester.widget<Text>(find.text('42%'));
    for (final Text text in <Text>[readout, percent]) {
      expect(text.style?.color, const Color(0xFFFFFFFF));
      expect(
        _contrast(text.style!.color!, _kGlassDark),
        greaterThanOrEqualTo(4.5),
      );
    }
    final FushiIcon speedIcon = tester.widget<FushiIcon>(
      find.descendant(
        of: find.byKey(videoSpeedPopoverFrameKey),
        matching: find.byType(FushiIcon),
      ),
    );
    expect(speedIcon.color, const Color(0xFFFFFFFF));

    // 文字按钮 / 滑条读外框提供的深色档主题，而不是页面浅色主题。
    final ThemeData inner = Theme.of(tester.element(find.text('1.0x')));
    expect(inner.colorScheme.brightness, Brightness.dark);
    expect(
      VideoControlPopoverFrame.foregroundOf(
        tester.element(find.byKey(videoSpeedPopoverReadoutKey)),
      ),
      const Color(0xFFFFFFFF),
    );
  });

  for (final Brightness brightness in Brightness.values) {
    testWidgets('MD3E ${brightness.name}: speed + volume popovers read the '
        'frame color scheme', (WidgetTester tester) async {
      final ThemeData theme = _theme(apple: false, brightness: brightness);
      await _pumpPopovers(tester, theme);
      expect(find.byType(VideoGlassHud), findsNothing);
      expect(find.byType(FushiAppleDarkTier), findsNothing);

      final Text readout = tester.widget<Text>(
        find.byKey(videoSpeedPopoverReadoutKey),
      );
      final Text percent = tester.widget<Text>(find.text('42%'));
      expect(readout.style?.color, _kPopoverScheme.onSurface);
      expect(percent.style?.color, _kPopoverScheme.onSurface);
      final FushiIcon speedIcon = tester.widget<FushiIcon>(
        find.descendant(
          of: find.byKey(videoSpeedPopoverFrameKey),
          matching: find.byType(FushiIcon),
        ),
      );
      expect(speedIcon.color, _kPopoverScheme.primary);
      // 文字按钮 / 滑条读调用方给外框的配色（M3E 中性方案），不读页面主题。
      final ThemeData inner = Theme.of(tester.element(find.text('1.0x')));
      expect(inner.colorScheme, _kPopoverScheme);
      final DecoratedBox frame = tester.widget<DecoratedBox>(
        find.byKey(videoSpeedPopoverFrameKey),
      );
      expect((frame.decoration as BoxDecoration).color, _kM3eSurface);
    });
  }
}

/// 视频玻璃 HUD 的底色量级（恒深色，近黑）——只用于对比度断言。
const Color _kGlassDark = Color(0xFF1C1C1E);

/// 调用方传给外框的配色（与页面主题不同，用来证明内容读的是外框配色）。
final ColorScheme _kPopoverScheme = ColorScheme.fromSeed(
  seedColor: Colors.deepOrange,
  brightness: Brightness.dark,
);

ThemeData _theme({required bool apple, required Brightness brightness}) {
  return buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
    textTheme: brightness == Brightness.dark
        ? Typography.material2021().white
        : Typography.material2021().black,
    glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: apple,
  );
}

Future<void> _pumpPopovers(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(
            child: Builder(
              builder: (BuildContext context) {
                final ColorScheme cs = videoAppleChrome(context)
                    ? Theme.of(context).colorScheme
                    : _kPopoverScheme;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    VideoSpeedPopoverCard(
                      width: 240,
                      speed: 1.5,
                      uiScale: 1,
                      colorScheme: cs,
                      m3eSurfaceColor: _kM3eSurface,
                      icon: Icons.speed,
                      divisions: 6,
                      onReset: () {},
                      onChanged: (_) {},
                    ),
                    const SizedBox(height: 8),
                    VideoVolumePopoverCard(
                      width: 240,
                      value: 42,
                      uiScale: 1,
                      colorScheme: cs,
                      m3eSurfaceColor: _kM3eSurface,
                      icon: Icons.volume_up,
                      tooltip: 'Mute',
                      onToggleMute: () {},
                      onChanged: (_) {},
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// WCAG 对比度。
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
