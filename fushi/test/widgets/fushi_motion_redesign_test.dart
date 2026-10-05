// 2026-10 UI / 动效重做的行为测试：按压反馈、错峰进场、导航药丸展开、
// 动效降级（墨水屏 / 系统减弱动态效果）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

Widget _wrap(Widget child, {bool eink = false, bool reduceMotion = false}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
    ),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: FushiFocusRoot(
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

double _scaleOf(WidgetTester tester) {
  final ScaleTransition transition = tester.widget<ScaleTransition>(
    find.descendant(
      of: find.byType(FushiPressScale),
      matching: find.byType(ScaleTransition),
    ),
  );
  return transition.scale.value;
}

double _opacityOf(WidgetTester tester, Key key) {
  return tester
      .widget<Opacity>(
        find
            .ancestor(of: find.byKey(key), matching: find.byType(Opacity))
            .first,
      )
      .opacity;
}

void main() {
  group('FushiPressScale', () {
    testWidgets('按下缩到 pressScale，松手回到 1，点击照常到达内层', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _wrap(
          FushiPressScale(
            child: GestureDetector(
              onTap: () => taps++,
              child: const ColoredBox(
                color: Colors.blue,
                child: SizedBox(width: 120, height: 160),
              ),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(FushiPressScale)),
      );
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), closeTo(FushiMotion.pressScale, 1e-6));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), closeTo(1, 1e-6));
      expect(taps, 1, reason: '只旁观指针事件，不得吞掉内层点击');
    });

    testWidgets('按下后拖过 touch slop 视为滚动起手，立即放回', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const FushiPressScale(
            child: ColoredBox(
              color: Colors.blue,
              child: SizedBox(width: 120, height: 160),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(FushiPressScale)),
      );
      await tester.pumpAndSettle();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), closeTo(1, 1e-6));
      await gesture.up();
    });

    for (final (String name, bool eink, bool reduce) in <(String, bool, bool)>[
      ('墨水屏', true, false),
      ('减弱动态效果', false, true),
    ]) {
      testWidgets('$name 下不包缩放层', (WidgetTester tester) async {
        await tester.pumpWidget(
          _wrap(
            const FushiPressScale(child: SizedBox(width: 10, height: 10)),
            eink: eink,
            reduceMotion: reduce,
          ),
        );
        expect(
          find.descendant(
            of: find.byType(FushiPressScale),
            matching: find.byType(ScaleTransition),
          ),
          findsNothing,
        );
      });
    }
  });

  group('FushiStaggeredEntrance', () {
    testWidgets('窗口内首挂载：从透明淡入，后面的项起播更晚', (WidgetTester tester) async {
      const Key first = ValueKey<String>('first');
      const Key late = ValueKey<String>('late');
      await tester.pumpWidget(
        _wrap(
          const FushiEntranceScope(
            child: Column(
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: SizedBox(key: first, width: 10, height: 10),
                ),
                FushiStaggeredEntrance(
                  index: 6,
                  child: SizedBox(key: late, width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );
      expect(_opacityOf(tester, first), 0);
      await tester.pump(const Duration(milliseconds: 120));
      expect(_opacityOf(tester, first), greaterThan(_opacityOf(tester, late)));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, first), 1);
      expect(_opacityOf(tester, late), 1);
    });

    testWidgets('窗口关闭后挂载的项（滚动带出）瞬间出现', (WidgetTester tester) async {
      const Key item = ValueKey<String>('item');
      final ValueNotifier<bool> show = ValueNotifier<bool>(false);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        _wrap(
          FushiEntranceScope(
            window: const Duration(milliseconds: 100),
            child: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (_, bool visible, __) => visible
                  ? const FushiStaggeredEntrance(
                      index: 0,
                      child: SizedBox(key: item, width: 10, height: 10),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      show.value = true;
      await tester.pump();
      expect(_opacityOf(tester, item), 1);
    });

    testWidgets('减弱动态效果下直接到位', (WidgetTester tester) async {
      const Key item = ValueKey<String>('item');
      await tester.pumpWidget(
        _wrap(
          const FushiStaggeredEntrance(
            index: 0,
            child: SizedBox(key: item, width: 10, height: 10),
          ),
          reduceMotion: true,
        ),
      );
      expect(_opacityOf(tester, item), 1);
    });
  });

  group('导航药丸', () {
    const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
      AdaptiveNavItem(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'A',
      ),
      AdaptiveNavItem(
        icon: Icons.book_outlined,
        selectedIcon: Icons.book,
        label: 'B',
      ),
    ];

    Widget bar(int index, {bool reduceMotion = false}) => _wrap(
      Builder(
        builder: (BuildContext context) => adaptiveBottomBar(
          context: context,
          currentIndex: index,
          onTap: (_) {},
          items: items,
        ),
      ),
      reduceMotion: reduceMotion,
    );

    double pillWidth(WidgetTester tester, IconData icon) {
      return tester
          .getSize(
            find
                .ancestor(
                  of: find.byIcon(icon),
                  matching: find.byWidgetPredicate(
                    (Widget w) =>
                        w is Container && w.decoration is BoxDecoration,
                  ),
                )
                .first,
          )
          .width;
    }

    // MD3 Expressive 刷新：完整药丸宽 = AdaptiveNavTileMetrics.fullPillWidth（56）。
    testWidgets('选中时从 32 横向展开到 56', (WidgetTester tester) async {
      await tester.pumpWidget(bar(0));
      await tester.pumpAndSettle();
      expect(
        pillWidth(tester, Icons.home),
        AdaptiveNavTileMetrics.fullPillWidth,
      );
      expect(pillWidth(tester, Icons.book_outlined), 32);
      await tester.pumpWidget(bar(1));
      await tester.pump(const Duration(milliseconds: 40));
      final double mid = pillWidth(tester, Icons.book);
      expect(mid, greaterThan(32));
      expect(mid, lessThan(AdaptiveNavTileMetrics.fullPillWidth));
      await tester.pumpAndSettle();
      expect(
        pillWidth(tester, Icons.book),
        AdaptiveNavTileMetrics.fullPillWidth,
      );
    });

    testWidgets('减弱动态效果下同帧到位', (WidgetTester tester) async {
      await tester.pumpWidget(bar(0, reduceMotion: true));
      await tester.pumpWidget(bar(1, reduceMotion: true));
      await tester.pump();
      expect(
        pillWidth(tester, Icons.book),
        AdaptiveNavTileMetrics.fullPillWidth,
      );
    });
  });

  group('桌面共享轴转场', () {
    test('进入 = spatial slow 落定时长 / 退出 = effects slow', () {
      const FushiSharedAxisPageTransitionsBuilder builder =
          FushiSharedAxisPageTransitionsBuilder();
      expect(builder.transitionDuration, FushiMotion.long);
      expect(builder.reverseTransitionDuration, FushiMotion.longReverse);
    });

    testWidgets('push 过程中新页从下方上滑到位，被盖住的旧页全程纹丝不动', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      const Key homeKey = ValueKey<String>('home');
      const Key pageKey = ValueKey<String>('page');
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(
            platform: TargetPlatform.windows,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: <TargetPlatform, PageTransitionsBuilder>{
                TargetPlatform.windows: FushiSharedAxisPageTransitionsBuilder(),
              },
            ),
          ),
          home: const SizedBox.expand(key: homeKey),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const SizedBox.expand(key: pageKey),
        ),
      );
      await tester.pump();
      // 转场进行中（450ms 内）逐帧检查；结束后旧页进幕后，finder 取不到。
      for (int ms = 0; ms <= 300; ms += 60) {
        // 用户反馈「进入页面时整个页面会往上一点」：被覆盖页曾随转场上移 6px。
        expect(tester.getTopLeft(find.byKey(homeKey)), Offset.zero);
        if (ms == 120) {
          expect(tester.getTopLeft(find.byKey(pageKey)).dy, greaterThan(0));
        }
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(pageKey)), Offset.zero);
    });

    testWidgets('进入页中途半透明（淡入确实在播）', (WidgetTester tester) async {
      const Key key = ValueKey<String>('child');
      await tester.pumpWidget(
        const MaterialApp(
          home: FushiSharedAxisTransition(
            animation: AlwaysStoppedAnimation<double>(0.5),
            secondaryAnimation: kAlwaysDismissedAnimation,
            child: SizedBox.expand(key: key),
          ),
        ),
      );
      final double opacity = tester
          .widget<Opacity>(
            find.ancestor(of: find.byKey(key), matching: find.byType(Opacity)),
          )
          .opacity;
      expect(opacity, greaterThan(0));
      expect(opacity, lessThan(1));
    });
  });

  test('release 曲线 = M3E spatial fast 弹簧形状：端点精确、带弹性过冲', () {
    expect(FushiMotion.release.transform(0), closeTo(0, 1e-9));
    expect(FushiMotion.release.transform(1), closeTo(1, 1e-9));
    double peak = 0;
    for (int i = 0; i <= 1000; i++) {
      final double v = FushiMotion.release.transform(i / 1000);
      if (v > peak) peak = v;
    }
    // ζ = 0.6 的欠阻尼弹簧过冲约 9.5%。
    expect(peak, greaterThan(1.05));
    expect(peak, lessThan(1.12));
  });
}
