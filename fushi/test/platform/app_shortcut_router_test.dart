import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/app_shortcut_router.dart';
import 'package:fushi/src/platform/app_shortcuts.dart';

/// 长按图标快捷方式的落地行为（main.dart `_runAppShortcut` 委托的
/// [runAppShortcut] / [AppShortcutQueue]）。纯 Navigator 装置，不挂 AppModel /
/// ProviderScope：路由层只依赖显式传入的模块开关、引导状态与 navigator。
void main() {
  const ModuleVisibility allModules = ModuleVisibility(<ModuleId>{
    ModuleId.books,
    ModuleId.manga,
    ModuleId.video,
    ModuleId.lookup,
  });

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  late List<HomeTab> selectedTabs;
  late int lookupOpens;

  setUp(() {
    selectedTabs = <HomeTab>[];
    lookupOpens = 0;
  });

  // 实例要在用例体（FakeAsync zone）里建：setUp 跑在真实 zone，那里建的
  // 队列尾 future 在 pump 期间等不到微任务。
  Future<void> pumpHome(WidgetTester tester) {
    _media = ExternalMediaNavigation.forTesting();
    return tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
  }

  NavigatorState nav() => navigatorKey.currentState!;

  void push(Widget page, String name) {
    nav().push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => page,
      ),
    );
  }

  Future<void> run(
    WidgetTester tester,
    AppShortcut shortcut, {
    ModuleVisibility visibility = allModules,
    bool onboardingCompleted = true,
  }) async {
    bool done = false;
    runAppShortcut(
      shortcut,
      visibility: visibility,
      onboardingCompleted: onboardingCompleted,
      navigator: nav(),
      selectHomeTab: selectedTabs.add,
      openLookup: () => lookupOpens++,
      media: _media,
    ).whenComplete(() => done = true);
    await tester.pumpAndSettle();
    expect(done, isTrue, reason: 'runAppShortcut must finish, not hang');
  }

  group('AppShortcutQueue (cold start)', () {
    testWidgets('holds the shortcut until home is ready, then runs the last '
        'one once on the next frame', (WidgetTester tester) async {
      await pumpHome(tester);
      final List<AppShortcut> ran = <AppShortcut>[];
      final AppShortcutQueue queue = AppShortcutQueue(
        isActive: () => true,
        run: (AppShortcut s) async => ran.add(s),
      );

      queue.enqueue(AppShortcut.books, ready: false);
      queue.enqueue(AppShortcut.video, ready: false);
      await tester.pump();
      expect(ran, isEmpty, reason: 'not initialised yet: must wait');

      // 初始化完成后的根 build 调 schedule()；连续 build 只落一次。
      queue.schedule();
      queue.schedule();
      await tester.pump();
      expect(ran, <AppShortcut>[AppShortcut.video]);
      expect(queue.pending, isNull);

      await tester.pump();
      expect(ran, hasLength(1));
    });

    testWidgets('a hot-start shortcut runs on the next frame', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      final List<AppShortcut> ran = <AppShortcut>[];
      AppShortcutQueue(
        isActive: () => true,
        run: (AppShortcut s) async => ran.add(s),
      ).enqueue(AppShortcut.manga, ready: true);
      expect(ran, isEmpty);
      await tester.pump();
      expect(ran, <AppShortcut>[AppShortcut.manga]);
    });

    testWidgets('dropped when the host is gone by the time the frame runs', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      final List<AppShortcut> ran = <AppShortcut>[];
      AppShortcutQueue(
        isActive: () => false,
        run: (AppShortcut s) async => ran.add(s),
      ).enqueue(AppShortcut.manga, ready: true);
      await tester.pump();
      expect(ran, isEmpty);
    });
  });

  group('onboarding gate', () {
    testWidgets('library shortcut switches the tab under onboarding and '
        'leaves the onboarding route alone', (WidgetTester tester) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('onboarding')), 'onboarding');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.books, onboardingCompleted: false);

      expect(selectedTabs, <HomeTab>[HomeTab.books]);
      expect(find.text('onboarding'), findsOneWidget);
    });

    testWidgets('lookup shortcut behaves the same: no standalone lookup page '
        'on top of onboarding', (WidgetTester tester) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('onboarding')), 'onboarding');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.lookup, onboardingCompleted: false);

      expect(lookupOpens, 0);
      expect(selectedTabs, <HomeTab>[HomeTab.dictionaries]);
      expect(find.text('onboarding'), findsOneWidget);
    });
  });

  group('module turned off (pinned Android shortcut)', () {
    testWidgets('library shortcut neither switches tab nor unwinds the stack', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('reading')), 'reader');
      await tester.pumpAndSettle();

      await run(
        tester,
        AppShortcut.video,
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );

      expect(selectedTabs, isEmpty);
      expect(find.text('reading'), findsOneWidget);
    });

    testWidgets('lookup shortcut does not force the lookup page open', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        AppShortcut.lookup,
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(lookupOpens, 0);
      expect(selectedTabs, isEmpty);
    });
  });

  group('unwinding to the home route', () {
    tearDown(() {
      _FakeMediaPageState.last = null;
      _ConfirmOnBackPage.prompts = 0;
      _AsyncBackMediaPage.persists = 0;
      _AsyncBackMediaPage.pops = 0;
    });

    testWidgets('lookup opens the lookup landing without popping anything', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('reading')), 'reader');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.lookup);

      expect(lookupOpens, 1);
      expect(find.text('reading'), findsOneWidget);
    });

    testWidgets('a canPop:false media page whose back only dismisses a '
        'foreground layer is closed through ExternalMediaNavigation', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('series detail')), 'detail');
      await tester.pumpAndSettle();
      push(const _FakeMediaPage(layerOpen: true), 'video');
      await tester.pumpAndSettle();
      expect(find.text('media'), findsOneWidget);

      await run(tester, AppShortcut.books);

      expect(selectedTabs, <HomeTab>[HomeTab.books]);
      expect(find.text('media'), findsNothing);
      expect(
        find.text('series detail'),
        findsNothing,
        reason: 'the detail page under the video must not hide the tab',
      );
      expect(find.text('home'), findsOneWidget);
      expect(nav().canPop(), isFalse);
      expect(_FakeMediaPageState.last!.closedForExternal, isTrue);
    });

    // 漫画页的返回回调是 async（先 await 退出窗口全屏），maybePop 不等它。旧实现
    // 先 maybePop、看路由还在就当成「返回被吸收」再 closeActive，于是页面自己的
    // 退出与外部收页各跑一遍：落盘 / closeMedia / 自动同步都执行两次。
    testWidgets('a media page with an async back handler exits exactly once', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('series detail')), 'detail');
      await tester.pumpAndSettle();
      push(const _AsyncBackMediaPage(), 'manga');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.books);

      expect(_AsyncBackMediaPage.persists, 1);
      expect(_AsyncBackMediaPage.pops, 1);
      expect(find.text('async media'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(nav().canPop(), isFalse);
    });

    testWidgets('a media page that refuses to close (persist failed) stays', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      push(const _FakeMediaPage(layerOpen: true, refuseClose: true), 'video');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.books);

      expect(find.text('media'), findsOneWidget);
    });

    testWidgets('a page asking "discard changes?" is left to the user, not '
        'cancelled and retried forever', (WidgetTester tester) async {
      await pumpHome(tester);
      push(const _ConfirmOnBackPage(), 'editor');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.books);

      expect(find.text('editor'), findsOneWidget);
      expect(find.text('discard?'), findsOneWidget);
      expect(_ConfirmOnBackPage.prompts, 1);
    });

    testWidgets('plain routes are all popped', (WidgetTester tester) async {
      await pumpHome(tester);
      push(const Scaffold(body: Text('a')), 'a');
      push(const Scaffold(body: Text('b')), 'b');
      await tester.pumpAndSettle();

      await run(tester, AppShortcut.manga);

      expect(find.text('home'), findsOneWidget);
      expect(nav().canPop(), isFalse);
    });
  });
}

/// 每个用例一份（见 [ExternalMediaNavigation.forTesting]）。
late ExternalMediaNavigation _media;

/// 仿 `VideoFushiPage`：`canPop: false`，返回键先关一层前台浮层（BUG-1862 的逐级
/// 退出），没有浮层才出栈；外部导航走 [ExternalMediaNavigation] 一次收掉。
class _FakeMediaPage extends StatefulWidget {
  const _FakeMediaPage({this.layerOpen = false, this.refuseClose = false});

  final bool layerOpen;
  final bool refuseClose;

  @override
  State<_FakeMediaPage> createState() => _FakeMediaPageState();
}

class _FakeMediaPageState extends State<_FakeMediaPage> {
  static _FakeMediaPageState? last;

  late bool _layerOpen = widget.layerOpen;
  bool closedForExternal = false;

  @override
  void initState() {
    super.initState();
    last = this;
    _media.register(
      this,
      _closeForExternal,
      ownsRoute: (Route<dynamic> route) =>
          mounted && identical(ModalRoute.of(context), route),
    );
  }

  @override
  void dispose() {
    _media.unregister(this);
    super.dispose();
  }

  Future<bool> _closeForExternal() async {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    if (widget.refuseClose) return false;
    setState(() => _layerOpen = false);
    closedForExternal = true;
    Navigator.of(context).pop();
    await route.completed;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (_layerOpen) {
          setState(() => _layerOpen = false);
          return;
        }
        Navigator.of(context).pop();
      },
      child: Scaffold(
        body: Column(
          children: <Widget>[
            const Text('media'),
            if (_layerOpen) const Text('layer'),
          ],
        ),
      ),
    );
  }
}

/// 拒绝出栈并弹确认框的编辑页。
class _ConfirmOnBackPage extends StatelessWidget {
  const _ConfirmOnBackPage();

  static int prompts = 0;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        prompts++;
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('discard?')),
        );
      },
      child: const Scaffold(body: Text('editor')),
    );
  }
}

/// 仿漫画页（`BaseSourcePageState` 子类）：返回回调先 await 一次（漫画页是
/// `_exitOwnedFullscreenBeforePop` 里的平台通道），再「落库 + 出栈」；外部收页走
/// 与 `_closeForSourceReturn` 同形的 close。故意**不带**单飞门，只验路由层不会
/// 触发两条退出。
class _AsyncBackMediaPage extends StatefulWidget {
  const _AsyncBackMediaPage();

  static int persists = 0;
  static int pops = 0;

  @override
  State<_AsyncBackMediaPage> createState() => _AsyncBackMediaPageState();
}

class _AsyncBackMediaPageState extends State<_AsyncBackMediaPage> {
  @override
  void initState() {
    super.initState();
    _media.register(
      this,
      _close,
      ownsRoute: (Route<dynamic> route) =>
          mounted && identical(ModalRoute.of(context), route),
    );
  }

  @override
  void dispose() {
    _media.unregister(this);
    super.dispose();
  }

  void _exit(NavigatorState navigator) {
    _AsyncBackMediaPage.persists++;
    _AsyncBackMediaPage.pops++;
    navigator.pop();
  }

  Future<bool> _close() async {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    _exit(Navigator.of(context));
    await route.completed;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        final NavigatorState navigator = Navigator.of(context);
        await Future<void>(() {});
        if (!mounted) return;
        _exit(navigator);
      },
      child: const Scaffold(body: Text('async media')),
    );
  }
}
