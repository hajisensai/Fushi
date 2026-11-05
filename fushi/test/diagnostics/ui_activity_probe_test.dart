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

class _Spinner extends StatefulWidget {
  const _Spinner({this.running = true});
  final bool running;
  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    if (widget.running) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _TwinSpinner extends StatefulWidget {
  const _TwinSpinner();
  @override
  State<_TwinSpinner> createState() => _TwinSpinnerState();
}

class _TwinSpinnerState extends State<_TwinSpinner>
    with TickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  late final AnimationController _b = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void initState() {
    super.initState();
    // late final 带初始化器是惰性的：不读就不建，ticker 也不会跑。
    _a;
    _b;
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('活跃 ticker：按持有者计数，停着的与 TickerMode 静音的不算', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: <Widget>[
            _Spinner(),
            _Spinner(),
            _Spinner(running: false),
            TickerMode(enabled: false, child: _Spinner()),
            _TwinSpinner(),
          ],
        ),
      ),
    );
    final Map<String, int> tickers = scanUiActivity(
      tester.binding.rootElement,
    ).tickers;
    expect(tickers, <String, int>{'_Spinner': 2, '_TwinSpinner': 2});
    expect(describeTickerOwners(tickers), '_Spinner×2 _TwinSpinner×2');
    expect(
      describeTickerOwners(<String, int>{'A': 1, 'B': 5, 'C': 2}, max: 2),
      'B×5 C×2 +1',
    );
    await tester.pumpWidget(const SizedBox());
  });

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
    expect(scanUiActivity(root).pages, <String>[
      '_HomePage',
      '_GenericPage',
      '_StatsPage',
    ]);
    expect(scanUiActivity(root, maxPages: 2).pages, <String>[
      '_GenericPage',
      '_StatsPage',
    ]);
    expect(scanUiActivity(null).pages, isEmpty);
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
    expect(scanUiActivity(tester.binding.rootElement).pages, <String>[
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
