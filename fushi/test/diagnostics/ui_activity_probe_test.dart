import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/fushi_binding.dart';
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
    expect(UiActivityProbe.probe(), startsWith('frames=3 '));
    expect(UiActivityProbe.probe(), startsWith('frames=0 '));
    UiActivityProbe.resetFrames();
  });

  test('重建调用点：跳过框架 / SDK / 探针自身的栈帧，取第一个应用栈帧', () {
    const String stack =
        '#0      UiActivityProbe.recordBuildScheduled (package:fushi/src/diagnostics/ui_activity_probe.dart:60:5)\n'
        '#1      BuildOwner.scheduleBuildFor (package:flutter/src/widgets/framework.dart:3000:7)\n'
        '#2      State.setState (package:flutter/src/widgets/framework.dart:1200:15)\n'
        '#3      _NowListeningMiniBarState._onSessionChanged (package:fushi/src/media/audiobook/now_listening_mini_bar.dart:48:7)\n'
        '#4      ChangeNotifier.notifyListeners (package:flutter/src/foundation/change_notifier.dart:437:24)\n';
    expect(
      buildSiteOf(stack),
      '_NowListeningMiniBarState._onSessionChanged@now_listening_mini_bar.dart:48',
    );
    expect(buildSiteOf('#0      _rootRun (dart:async/zone.dart:1:1)'), '?');
  });

  testWidgets('重建要帧：每次计数，调用点按间隔节流抓一次', (WidgetTester tester) async {
    UiActivityProbe.resetFrames();
    final StackTrace stack = StackTrace.fromString(
      '#0      _FooState._tick (package:fushi/src/foo.dart:12:3)\n',
    );
    UiActivityProbe.recordBuildScheduled(stack);
    UiActivityProbe.recordBuildScheduled(stack);
    UiActivityProbe.recordBuildScheduled(stack);
    final String out = UiActivityProbe.probe()!;
    expect(out, contains('build=3 who=[_FooState._tick@foo.dart:12]'));
    UiActivityProbe.resetFrames();
  });

  group('要帧归因', () {
    StackTrace st(String s) => StackTrace.fromString(s);
    final StackTrace started = st(
      '#0      FushiWidgetsFlutterBinding.scheduleFrameCallback (package:fushi/src/diagnostics/fushi_binding.dart:40:5)\n'
      '#1      Ticker.scheduleTick (package:flutter/src/scheduler/ticker.dart:300:7)\n'
      '#2      Ticker.start (package:flutter/src/scheduler/ticker.dart:180:7)\n'
      '#3      AnimationController.repeat (package:flutter/src/animation/animation_controller.dart:700:5)\n'
      '#4      _OrphanState._resume (package:fushi/src/foo/orphan.dart:77:9)\n',
    );
    final StackTrace frameworkOnly = st(
      '#0      Ticker.scheduleTick (package:flutter/src/scheduler/ticker.dart:300:7)\n'
      '#1      Ticker.muted= (package:flutter/src/scheduler/ticker.dart:120:7)\n'
      '#2      TickerMode._update (package:flutter/src/widgets/ticker_provider.dart:90:5)\n',
    );

    void tick() {}

    tearDown(UiActivityProbe.resetFrames);

    test('调用点：先取应用栈帧，整栈是框架时取第一个非调度框架栈帧并加 ~', () {
      expect(
        frameRequestSiteOf(started.toString()),
        '_OrphanState._resume@orphan.dart:77',
      );
      expect(
        frameRequestSiteOf(frameworkOnly.toString()),
        '~TickerMode._update@ticker_provider.dart:90',
      );
      expect(
        frameRequestSiteOf('#0      _rootRun (dart:async/zone.dart:1:1)'),
        '?',
      );
    });

    testWidgets('逐帧续排的要帧按首次注册（启动）的调用点精确归账', (WidgetTester tester) async {
      UiActivityProbe.resetFrames();
      UiActivityProbe.beginFrameCallbackRegistration(
        tick,
        rescheduling: false,
        stack: started,
      );
      UiActivityProbe.recordFrameRequest();
      UiActivityProbe.endFrameCallbackRegistration();
      for (int i = 0; i < 5; i++) {
        // 续排时栈里只有框架：不用它，按回调身份查到启动点。
        UiActivityProbe.beginFrameCallbackRegistration(
          tick,
          rescheduling: true,
          stack: frameworkOnly,
        );
        UiActivityProbe.recordFrameRequest();
        UiActivityProbe.endFrameCallbackRegistration();
      }
      // 后来的纯框架注册（解除静音）不把已知调用点覆盖掉。
      UiActivityProbe.beginFrameCallbackRegistration(
        tick,
        rescheduling: false,
        stack: frameworkOnly,
      );
      UiActivityProbe.recordFrameRequest();
      UiActivityProbe.endFrameCallbackRegistration();
      final String out = UiActivityProbe.probe()!;
      expect(
        out,
        contains('req=7 fcb=[_OrphanState._resume@orphan.dart:77×7]'),
      );
      expect(out, isNot(contains('fvis=')));
      expect(UiActivityProbe.probe(), isNot(contains('req=')));
    });

    testWidgets('帧回调之外的要帧：每次计数，调用点按间隔节流', (WidgetTester tester) async {
      UiActivityProbe.resetFrames();
      final StackTrace paint = st(
        '#0      SchedulerBinding.ensureVisualUpdate (package:flutter/src/scheduler/binding.dart:910:9)\n'
        '#1      RenderObject.markNeedsPaint (package:flutter/src/rendering/object.dart:3300:7)\n'
        '#2      _RenderLoop.paint (package:fushi/src/foo/loop.dart:42:5)\n',
      );
      UiActivityProbe.recordFrameRequest(stack: paint);
      UiActivityProbe.recordFrameRequest(stack: paint);
      UiActivityProbe.recordFrameRequest(stack: paint);
      final String out = UiActivityProbe.probe()!;
      expect(out, contains('req=3 fvis=[_RenderLoop.paint@loop.dart:42]'));
    });

    testWidgets('layer 普查：数出合成树里各类 layer', (WidgetTester tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.5,
            child: RepaintBoundary(child: ColoredBox(color: Color(0xFF00FF00))),
          ),
        ),
      );
      final Map<String, int> layers = countLayers(tester.binding.renderViews);
      expect(layers['OpacityLayer'], 1);
      expect(layers['PictureLayer'], greaterThanOrEqualTo(1));
      expect(layers['TransformLayer'], greaterThanOrEqualTo(1));
    });

    testWidgets('已有 binding（测试 / integration_test 先建）时原样返回、不另建', (
      WidgetTester tester,
    ) async {
      expect(
        identical(
          FushiWidgetsFlutterBinding.ensureInitialized(),
          tester.binding,
        ),
        isTrue,
      );
    });
  });
}
