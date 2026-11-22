// 玻璃设计（UI 名「Cupertino」）+ 自定义壁纸下滚设置宽屏左栏，内容区顶部整宽
// 冒出一条黑线（2026-11-21 用户截图）。两处根因：
// 1. 外壳的 FushiAppleScrollChrome 把任何竖向滚动都当正文，左栏（导航侧窗格）
//    一滚就亮出顶部 scroll edge 带；
// 2. FushiAppleScrollEdge 把 scaffoldBackgroundColor 直接不透明化，壁纸下它是
//    Colors.transparent（RGB 黑），带就成了黑色。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('side pane scrolls do not drive page chrome', () {
    late FushiAppleScrollChrome chrome;
    final ScrollController side = ScrollController();
    final ScrollController main = ScrollController();

    Future<void> pumpShell(WidgetTester tester) async {
      chrome = FushiAppleScrollChrome();
      addTearDown(chrome.dispose);
      Widget list(ScrollController controller) => ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder: (BuildContext context, int i) =>
            SizedBox(height: 40, child: Text('$i')),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          // 与 home_page.dart `_withAppleScrollChrome` 同一接法。
          child: NotificationListener<Notification>(
            onNotification: (Notification n) {
              if (!fushiNotificationDrivesPageChrome(n)) return false;
              chrome.handleNotification(n);
              return false;
            },
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 200,
                  child: FushiSidePaneScrollScope(child: list(side)),
                ),
                Expanded(child: list(main)),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('scrolling the side pane leaves contentUnderTop off', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester);
      side.jumpTo(400);
      await tester.pump();
      expect(side.offset, 400);
      expect(chrome.contentUnderTop, isFalse);
    });

    testWidgets('scrolling the main content still turns it on', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester);
      main.jumpTo(400);
      await tester.pump();
      expect(chrome.contentUnderTop, isTrue);
      // 之后再滚侧窗格回顶也不能把正文的状态冲掉。
      side.jumpTo(200);
      side.jumpTo(0);
      await tester.pump();
      expect(chrome.contentUnderTop, isTrue);
    });
  });

  group('scroll edge colour', () {
    Future<Color> resolve(WidgetTester tester, Color scaffold) async {
      late Color color;
      await tester.pumpWidget(
        Theme(
          data: ThemeData(scaffoldBackgroundColor: scaffold),
          child: Builder(
            builder: (BuildContext context) {
              color = fushiAppleScrollEdgeColor(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return color;
    }

    testWidgets('transparent scaffold (wallpaper) falls back to page colour', (
      WidgetTester tester,
    ) async {
      final Color color = await resolve(tester, Colors.transparent);
      expect(color.a, 1);
      expect(color, isNot(const Color(0xFF000000)));
      final BuildContext context = tester.element(find.byType(SizedBox));
      expect(
        color,
        FushiDesignTokens.of(context).surfaces.page.withValues(alpha: 1),
      );
    });

    testWidgets('translucent scaffold keeps its own hue, made opaque', (
      WidgetTester tester,
    ) async {
      const Color tint = Color(0x80E0E4F0);
      final Color color = await resolve(tester, tint);
      expect(color, tint.withValues(alpha: 1));
    });
  });

  test('every settings home side pane is marked as a side pane', () {
    final String src = File(
      'lib/src/settings/settings_home_page.dart',
    ).readAsStringSync();
    final int panes = RegExp(r'supporting: ').allMatches(src).length;
    final int marked = RegExp(
      r'supporting: FushiSidePaneScrollScope\(',
    ).allMatches(src).length;
    expect(panes, greaterThan(0));
    expect(marked, panes);
  });
}
