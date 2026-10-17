import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 查词浮层（装平台视图的 FushiPopupSurface，borderOnForeground = false）在 Apple
// 设计系统下的契约：
// ① 玻璃画在子节点（WebView）**背后**——Stack 背景槽，不包住子节点，也不压在
//    它上面（BUG-1692：平台视图之上的 Flutter 绘制会吞掉 macOS 鼠标事件）；
// ② 描边仍走 Material 的「子节点之前」绘制（borderOnForeground 透传 false），
//    Material 本身透明，让玻璃透出来；
// ③ MD3 ↔ Apple 切换时子节点 Element 不被重挂（热槽 WebView 不能因为换设计
//    系统而被拆掉重建）；
// ④ popup.css 的透明文档宿主 / 强调色段与扩展生成物保持一致。
void main() {
  // 默认钉 Windows：flutter test 的 defaultTargetPlatform 是 Android，而 Android
  // 的查词面板背后是 Hybrid Composition WebView、采不到模糊（恒不透明，见下方
  // 专门的用例）；「真玻璃」契约只在 WebView 以纹理合成的 Windows / Linux 上成立。
  ThemeData theme({
    required bool glass,
    TargetPlatform platform = TargetPlatform.windows,
  }) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  ).copyWith(platform: platform);

  Widget host(ThemeData data, Widget child) => MaterialApp(
    theme: data,
    themeAnimationDuration: Duration.zero,
    home: FushiGlassScope(
      child: Scaffold(
        body: Center(child: SizedBox(width: 240, height: 180, child: child)),
      ),
    ),
  );

  testWidgets('Apple：玻璃在 WebView 背后，Material 透明且描边画在子节点之前', (
    WidgetTester tester,
  ) async {
    const Key childKey = ValueKey<String>('webview');
    await tester.pumpWidget(
      host(
        theme(glass: true),
        const FushiPopupSurface(
          borderOnForeground: false,
          child: SizedBox.expand(key: childKey),
        ),
      ),
    );

    // 玻璃层：液态档是 GlassContainer；着色器不可用（测试环境 / Skia）时
    // 液态档回落毛玻璃，走与 MD3 同一组的 BackdropFilter（共用
    // kFushiLookupPopupBackdropKey，嵌套查词层不会一层比一层实）。
    final Finder glass = find.descendant(
      of: find.byType(FushiPopupSurface),
      matching: find.byWidgetPredicate(
        (Widget w) => w is GlassContainer || w is BackdropFilter,
      ),
    );
    expect(glass, findsOneWidget);
    final Widget glassWidget = tester.widget(glass);
    if (glassWidget is BackdropFilter) {
      expect(glassWidget.backdropGroupKey, kFushiLookupPopupBackdropKey);
    }
    // 子节点不在玻璃里面（玻璃是兄弟层，不是父层）。
    expect(
      find.descendant(of: glass, matching: find.byKey(childKey)),
      findsNothing,
    );
    // 玻璃不拦指针。
    expect(
      find.ancestor(of: glass, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );

    final Material material = tester.widget<Material>(
      find
          .ancestor(of: find.byKey(childKey), matching: find.byType(Material))
          .first,
    );
    expect(material.borderOnForeground, isFalse);
    expect(material.color, Colors.transparent);

    // 背景槽排在子节点之前绘制：同一个 Stack 里玻璃所在的 Positioned 在前。
    final Stack stack = tester.widget<Stack>(
      find.ancestor(of: glass, matching: find.byType(Stack)).first,
    );
    expect(stack.children.first, isA<Positioned>());
  });

  testWidgets('MD3：查词浮层也是磨砂玻璃（BackdropFilter 在 WebView 背后，Material 透明）；'
      '独立窗保持不透明', (WidgetTester tester) async {
    const Key childKey = ValueKey<String>('webview');
    await tester.pumpWidget(
      host(
        theme(glass: false),
        const FushiPopupSurface(
          borderOnForeground: false,
          child: SizedBox.expand(key: childKey),
        ),
      ),
    );
    final Finder blur = find.descendant(
      of: find.byType(FushiPopupSurface),
      matching: find.byType(BackdropFilter),
    );
    expect(blur, findsOneWidget);
    expect(
      find.descendant(of: blur, matching: find.byKey(childKey)),
      findsNothing,
    );
    final Material material = tester.widget<Material>(
      find
          .ancestor(of: find.byKey(childKey), matching: find.byType(Material))
          .first,
    );
    expect(material.color, Colors.transparent);
    expect(material.borderOnForeground, isFalse);

    await tester.pumpWidget(
      host(
        theme(glass: false),
        const FushiPopupSurface(
          borderOnForeground: false,
          standaloneWindow: true,
          color: Colors.white,
          child: SizedBox.expand(key: childKey),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });

  testWidgets('MD3：同一 Stack 槽位、无玻璃组件；切换设计系统子节点不重挂', (
    WidgetTester tester,
  ) async {
    final GlobalKey childKey = GlobalKey();
    Widget surface() => FushiPopupSurface(
      borderOnForeground: false,
      child: SizedBox.expand(key: childKey),
    );

    await tester.pumpWidget(host(theme(glass: false), surface()));
    expect(
      find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(GlassContainer),
      ),
      findsNothing,
    );
    final Element before = childKey.currentContext! as Element;

    await tester.pumpWidget(host(theme(glass: true), surface()));
    await tester.pump();
    expect(
      identical(childKey.currentContext, before),
      isTrue,
      reason: '切到 Apple 时查词 WebView 被拆掉重挂（结构不恒定）',
    );

    await tester.pumpWidget(host(theme(glass: false), surface()));
    await tester.pump();
    expect(
      identical(childKey.currentContext, before),
      isTrue,
      reason: '切回 MD3 时查词 WebView 被拆掉重挂（结构不恒定）',
    );
  });

  testWidgets('Android（阅读器 WebView 是 Hybrid Composition 原生 View、采不到模糊）：'
      '两套设计系统都画不透明面板', (WidgetTester tester) async {
    for (final bool glass in <bool>[true, false]) {
      await tester.pumpWidget(
        host(
          theme(glass: glass, platform: TargetPlatform.android),
          const FushiPopupSurface(
            borderOnForeground: false,
            child: SizedBox.expand(),
          ),
        ),
      );
      Finder inSurface(Type t) => find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(t),
      );
      expect(
        inSurface(GlassContainer),
        findsNothing,
        reason: 'glass=$glass：HC 下着色器采不到 WebView，半透明只会透出未模糊的正文',
      );
      expect(
        inSurface(BackdropFilter),
        findsNothing,
        reason: 'glass=$glass：BackdropFilter 只采得到 overlay surface 自己画的东西',
      );
      final Iterable<ColoredBox> boxes = tester.widgetList<ColoredBox>(
        inSurface(ColoredBox),
      );
      expect(
        boxes.any((ColoredBox b) => b.color.a == 1.0),
        isTrue,
        reason: 'glass=$glass：面板必须不透明',
      );
    }
  });

  testWidgets('iOS / macOS（背后是原生平台视图、采不到模糊）：两套设计系统都画不透明面板', (
    WidgetTester tester,
  ) async {
    for (final bool glass in <bool>[true, false]) {
      await tester.pumpWidget(
        host(
          theme(glass: glass, platform: TargetPlatform.macOS),
          const FushiPopupSurface(
            borderOnForeground: false,
            child: SizedBox.expand(),
          ),
        ),
      );
      Finder inSurface(Type t) => find.descendant(
        of: find.byType(FushiPopupSurface),
        matching: find.byType(t),
      );
      expect(
        inSurface(GlassContainer),
        findsNothing,
        reason: 'glass=$glass：半透明玻璃会把下面一层的字原样透出来',
      );
      expect(inSurface(BackdropFilter), findsNothing);
      final Iterable<ColoredBox> boxes = tester.widgetList<ColoredBox>(
        inSurface(ColoredBox),
      );
      expect(
        boxes.any((ColoredBox b) => b.color.a == 1.0),
        isTrue,
        reason: 'glass=$glass：面板必须不透明',
      );
    }
  });

  group('popup.css 材质宿主 / 强调色段', () {
    final String popupCss = File('assets/popup/popup.css').readAsStringSync();

    test('app 内宿主文档透明（玻璃卡面由 Flutter 画）', () {
      expect(
        RegExp(
          r'html\.fushi-glass-host,\s*html\.fushi-glass-host body\s*\{\s*'
          r'background:\s*transparent;',
        ).hasMatch(popupCss),
        isTrue,
      );
    });

    test('强调色段同时覆盖 app 宿主与扩展 .fushi-glass', () {
      expect(
        popupCss.contains(
          ':where(html.fushi-glass-host, .fushi-glass) .frequency-dict-label',
        ),
        isTrue,
      );
    });

    for (final String root in const <String>[
      'assets/browser_extension',
      '../tools/browser-extension',
    ]) {
      test('[$root] content.css 丢弃 html.fushi-glass-host、保留强调色段', () {
        final String content = File(
          '$root/vendor/content.css',
        ).readAsStringSync();
        expect(
          content.contains('html.fushi-glass-host body'),
          isFalse,
          reason: '透明文档宿主只属于 app 内弹窗，不能进扩展（会被重根到容器上）',
        );
        expect(
          content.contains(
            ':where(html.fushi-glass-host, .fushi-glass) .frequency-dict-label',
          ),
          isTrue,
          reason: '扩展玻璃弹窗与 app 同一套强调色淡染',
        );
      });
    }
  });
}
