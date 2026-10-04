import 'dart:io';

import 'package:flutter/material.dart';
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
  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );

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

    final Finder glass = find.descendant(
      of: find.byType(FushiPopupSurface),
      matching: find.byType(GlassContainer),
    );
    expect(glass, findsOneWidget);
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

  group('popup.css 材质宿主 / 强调色段', () {
    final String popupCss = File('assets/popup/popup.css').readAsStringSync();

    test('app 内 Apple 宿主文档透明（玻璃卡面由 Flutter 画）', () {
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
