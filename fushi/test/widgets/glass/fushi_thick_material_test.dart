import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 厚材质契约（用户 2026-11-24「视频栏太透了看不清」）：承载正文的内容面板
// （视频设置 / 选集 / 章节 / 字幕面板）用厚材质，填充不透明度保证正文在任何
// 画面下对比度 ≥ WCAG AA 4.5:1；实色档不透明；小控件仍是薄玻璃。

ThemeData _theme({
  required Brightness brightness,
  required FushiGlassMaterial material,
}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness),
  textTheme: Typography.material2021().black,
  glass: material,
  glassDesign: true,
);

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [fill] 压在 [backdrop] 上的合成色。
Color _over(Color fill, Color backdrop) =>
    Color.alphaBlend(fill, backdrop).withValues(alpha: 1);

Future<BuildContext> _context(WidgetTester tester, ThemeData theme) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (BuildContext context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('${brightness.name}：厚材质在纯白 / 纯黑画面上正文对比度 ≥ 4.5', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await _context(
        tester,
        _theme(brightness: brightness, material: FushiGlassMaterial.standard),
      );
      final Color fill = fushiThickMaterialFill(context);
      final Color text = brightness == Brightness.dark
          ? Colors.white
          : Colors.black;
      for (final Color backdrop in <Color>[Colors.white, Colors.black]) {
        expect(
          _contrast(text, _over(fill, backdrop)),
          greaterThanOrEqualTo(4.5),
          reason: 'backdrop $backdrop',
        );
      }
      expect(
        fill.a,
        brightness == Brightness.dark
            ? closeTo(kFushiThickMaterialDarkAlpha, 0.01)
            : closeTo(kFushiThickMaterialLightAlpha, 0.01),
      );
    });
  }

  testWidgets('实色档：厚材质不透明', (WidgetTester tester) async {
    final BuildContext context = await _context(
      tester,
      _theme(brightness: Brightness.dark, material: FushiGlassMaterial.off),
    );
    expect(fushiThickMaterialFill(context).a, 1.0);
    expect(fushiThickMaterialSettings(context).blur, 0);
  });

  testWidgets('视频浮层面板用厚材质，作用域外的悬浮面仍是薄玻璃', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(
          brightness: Brightness.dark,
          material: FushiGlassMaterial.standard,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: Column(
              children: const <Widget>[
                SizedBox(
                  width: 300,
                  height: 200,
                  child: VideoFloatingPanelSurface(
                    surfaceKey: ValueKey<String>('panel'),
                    child: SizedBox.expand(),
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FushiAppleFloatingSurface(
                    key: ValueKey<String>('thin'),
                    shape: CircleBorder(),
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FushiThickMaterialScope(
                    child: FushiAppleFloatingSurface(
                      key: ValueKey<String>('scoped'),
                      shape: CircleBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    double alphaOf(String key) => tester
        .widget<GlassContainer>(
          find.descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(GlassContainer),
          ),
        )
        .settings!
        .glassColor
        .a;
    expect(alphaOf('panel'), closeTo(kFushiThickMaterialDarkAlpha, 0.01));
    expect(alphaOf('scoped'), closeTo(kFushiThickMaterialDarkAlpha, 0.01));
    expect(alphaOf('thin'), lessThan(0.5));
  });
}
