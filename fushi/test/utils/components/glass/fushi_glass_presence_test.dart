import 'package:flutter/rendering.dart' show RenderOpacity;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_presence.dart';

// 2026-11-24 录屏：Apple 阅读器顶栏 / 视频控制条显隐时，内容先淡掉、玻璃底剩
// 一团灰色空胶囊再消失。根因：chrome 显隐用 Opacity 包住整块，玻璃（BackdropFilter
// + 着色器）在 OpacityLayer 里采不到背景。这里逐帧咬住：玻璃 chrome 显隐全程，
// 内容与玻璃之间没有一层半透明 Opacity，玻璃的进度（FushiGlassPresence）与淡出
// 同步；M3E / 实色档仍是普通 Opacity。

const Key _probe = ValueKey<String>('probe');

Widget _app({
  required bool visible,
  required FushiGlassMaterial material,
  required bool apple,
}) => MaterialApp(
  theme: ThemeData(
    extensions: <ThemeExtension<dynamic>>[
      FushiGlassTheme(material, glassDesign: apple),
    ],
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: FushiChromeReveal(
        visible: visible,
        child: const SizedBox(key: _probe, width: 200, height: 40),
      ),
    ),
  ),
);

/// probe 与 [FushiChromeReveal] 之间所有不透明度 < 1 的 RenderOpacity。
List<double> _translucentOpacitiesAbove(WidgetTester tester) {
  final RenderObject probe = tester.renderObject(
    find.byKey(_probe, skipOffstage: false),
  );
  final RenderObject reveal = tester.renderObject(
    find.byType(FushiChromeReveal),
  );
  final List<double> out = <double>[];
  RenderObject? node = probe.parent;
  while (node != null && node != reveal.parent) {
    if (node is RenderOpacity && node.opacity < 1) out.add(node.opacity);
    node = node.parent;
  }
  return out;
}

double? _presence(WidgetTester tester) => FushiGlassPresence.maybeOf(
  tester.element(find.byKey(_probe, skipOffstage: false)),
);

void main() {
  testWidgets('玻璃 chrome 收起 / 展开逐帧：无半透明 Opacity 压在内容与玻璃上，'
      '玻璃进度单调跟随', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(visible: true, material: FushiGlassMaterial.standard, apple: true),
    );
    expect(_presence(tester), 1);

    await tester.pumpWidget(
      _app(visible: false, material: FushiGlassMaterial.standard, apple: true),
    );
    double last = 1;
    bool sawMidway = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));

      expect(_translucentOpacitiesAbove(tester), isEmpty, reason: 'frame $i');
      final double p = _presence(tester)!;
      expect(p, lessThanOrEqualTo(last + 1e-9), reason: 'frame $i');
      if (p > 0.05 && p < 0.95) sawMidway = true;
      last = p;
    }
    await tester.pumpAndSettle();
    expect(sawMidway, isTrue);
    expect(_presence(tester), 0);

    await tester.pumpWidget(
      _app(visible: true, material: FushiGlassMaterial.standard, apple: true),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(_translucentOpacitiesAbove(tester), isEmpty);
    expect(_presence(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_presence(tester), 1);
  });

  testWidgets('M3E 与 Apple 实色档：仍是普通 Opacity 淡出，没有玻璃进度', (
    WidgetTester tester,
  ) async {
    for (final bool apple in <bool>[false, true]) {
      final FushiGlassMaterial material = apple
          ? FushiGlassMaterial.off
          : FushiGlassMaterial.standard;
      await tester.pumpWidget(
        _app(visible: true, material: material, apple: apple),
      );
      await tester.pumpWidget(
        _app(visible: false, material: material, apple: apple),
      );
      await tester.pump(const Duration(milliseconds: 48));
      expect(_presence(tester), isNull);
      expect(_translucentOpacitiesAbove(tester), isNotEmpty);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('FushiGlassPresenceFade：动画中按进度淡，静止 / 不在动画里原样', (
    WidgetTester tester,
  ) async {
    Widget host(double? p) => MaterialApp(
      home: p == null
          ? const FushiGlassPresenceFade(child: SizedBox(key: _probe))
          : FushiGlassPresence(
              presence: p,
              child: const FushiGlassPresenceFade(child: SizedBox(key: _probe)),
            ),
    );
    await tester.pumpWidget(host(null));
    expect(
      find.ancestor(
        of: find.byKey(_probe, skipOffstage: false),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    await tester.pumpWidget(host(0.4));
    final RenderOpacity ro = tester.renderObject<RenderOpacity>(
      find
          .ancestor(
            of: find.byKey(_probe, skipOffstage: false),
            matching: find.byWidgetPredicate(
              (Widget w) => w.runtimeType.toString() == '_PresenceOpacity',
            ),
          )
          .first,
    );
    expect(ro.opacity, closeTo(0.4, 1e-9));
    expect(ro.alwaysNeedsCompositing, isTrue);
    await tester.pumpWidget(host(1));
    expect(ro.alwaysNeedsCompositing, isFalse);
  });
}
