import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

// BUG-2959：MD3 主题曾在 appBarTheme 里钉 titleTextStyle = titleLarge，Flutter 的
// SliverAppBar.large 展开态取 `titleTextStyle ?? appBarTheme.titleTextStyle ??
// headlineMedium`，于是设置页的大标题顶栏只剩一行 22 号小字压在 152 高的空带
// 底部（Android「设置」上方大片空白）。展开态必须是 headlineMedium，普通顶栏
// 仍是 titleLarge。

void main() {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
  );

  // Typography.material2021().black 只带颜色不带字号：字号按 M3 默认字阶比。
  const TextTheme m3 = Typography.englishLike2021;

  double fontSizeOf(WidgetTester tester, String text) {
    final RenderParagraph p = tester.renderObject<RenderParagraph>(
      find.text(text).first,
    );
    return p.text.style!.fontSize!;
  }

  testWidgets('MD3 large app bar expands to the headlineMedium title', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              SliverAppBar.large(title: Text('Settings')),
              SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final double expanded = fontSizeOf(tester, 'Settings');
    expect(expanded, m3.headlineMedium!.fontSize);
    expect(expanded, greaterThan(m3.titleLarge!.fontSize!));
  });

  testWidgets('MD3 small app bar title stays titleLarge', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(appBar: AppBar(title: const Text('Small'))),
      ),
    );
    await tester.pump();
    expect(fontSizeOf(tester, 'Small'), m3.titleLarge!.fontSize);
  });
}
