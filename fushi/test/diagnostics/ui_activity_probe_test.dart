import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/ui_activity_probe.dart';
import 'package:material_ui/material_ui.dart';

class _HomePage extends StatelessWidget {
  const _HomePage({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

class _StatsPage extends StatelessWidget {
  const _StatsPage();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _HiddenTabPage extends StatelessWidget {
  const _HiddenTabPage();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _GenericPage<T> extends StatelessWidget {
  const _GenericPage();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('可见页面：先序收集 *Page，跳过 TickerMode 关掉的子树，泛型去掉类型参数', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: _HomePage(
          child: Column(
            children: <Widget>[
              TickerMode(enabled: false, child: _HiddenTabPage()),
              _GenericPage<int>(),
              _StatsPage(),
            ],
          ),
        ),
      ),
    );
    final Element root = tester.binding.rootElement!;
    expect(visiblePageNames(root), <String>[
      '_HomePage',
      '_GenericPage',
      '_StatsPage',
    ]);
    expect(visiblePageNames(root, maxPages: 2), <String>[
      '_GenericPage',
      '_StatsPage',
    ]);
    expect(visiblePageNames(null), isEmpty);
  });

  testWidgets('被不透明路由盖住的页面不算可见', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const _HomePage(child: SizedBox()),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const _StatsPage()),
    );
    await tester.pumpAndSettle();
    expect(visiblePageNames(tester.binding.rootElement), <String>[
      '_StatsPage',
    ]);
  });

  testWidgets('帧数：install 后每帧计一次，probe 取走后清零', (WidgetTester tester) async {
    UiActivityProbe.install();
    await tester.pumpWidget(const SizedBox());
    UiActivityProbe.probe();
    // 测试绑定的 pump 只在有排程的帧时才真画一帧。
    for (int i = 0; i < 3; i++) {
      tester.binding.scheduleFrame();
      await tester.pump();
    }
    await tester.pump(); // 没排程：不出帧，不计。
    expect(UiActivityProbe.probe(), 'frames=3');
    expect(UiActivityProbe.probe(), 'frames=0');
    UiActivityProbe.resetFrames();
  });
}
