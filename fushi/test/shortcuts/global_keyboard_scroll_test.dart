import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 全 app 键盘滚动（用户：「我一般用键盘滚动，fushi 里全部页面都不行」）。
///
/// 三件事各钉一条：
///   1. 默认绑定表：global scope 六件套的键盘位（PageUp/PageDown、↑/↓、Home/End），
///      手柄 LB/RB 原样保留；
///   2. 零登记页面也能被滚：一个没有任何可聚焦子件、没登记 PageScrollRegistry、
///      也没挂 PrimaryScrollController 的 ListView 页面（桌面端 ListView 默认不挂），
///      按键后 `controller.offset` 真变化——这是改造前完全不可达的那类页面；
///   3. 让位规则：焦点在列表中间的可聚焦项上时 ↓ 走焦点导航（焦点变、页面不被
///      单步滚动）；TextField 聚焦时 ↓/Home/End 一律不接管。
///
/// 宿主结构照生产：[wrapWithGlobalNavigation] 挂在 [MaterialApp.builder]（Navigator
/// 之上），页面经 `home:` 作为路由挂进 Navigator——这样兜底解析器走的是真实的
/// 「从 Navigator 当前路由子树里找 Scrollable」那条路，而不是被测试结构侥幸绕过。
void main() {
  FushiShortcutRegistry desktopRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  setUp(PageScrollRegistry.debugClear);

  Future<void> pumpApp(
    WidgetTester tester, {
    required Widget page,
    required FushiShortcutRegistry registry,
    bool focusNavigationEnabled = false,
    Map<ShortcutActivator, Intent>? appShortcuts,
    Map<Type, Action<Intent>>? appActions,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: page,
      shortcuts: appShortcuts,
      actions: appActions,
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(
        navigatorKey: navKey,
        registry: registry,
        focusNavigationEnabled: focusNavigationEnabled,
        // 生产结构：焦点导航开启时 FushiFocusRoot 在全局导航层之内、Navigator 之上
        // （main.dart）。关闭时不挂——`FushiFocusRoot.maybeControllerOf` 为 null
        // 就是「焦点导航关闭」的判据本身。
        child: focusNavigationEnabled
            ? FushiFocusRoot(enabled: true, child: child!)
            : child!,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 纯展示长列表本体：零可聚焦子件、`primary: false`（桌面端默认也是如此）。
  Widget bareDisplayList(ScrollController controller) => ListView.builder(
        controller: controller,
        primary: false,
        itemCount: 200,
        itemExtent: 40,
        itemBuilder: (BuildContext context, int i) => Text('row $i'),
      );

  /// 纯展示长列表页：零可聚焦子件、零登记。
  Widget displayOnlyList(ScrollController controller) =>
      Scaffold(body: bareDisplayList(controller));

  group('默认绑定表', () {
    test('global scope 六件套：桌面键盘位 PageUp/PageDown、↑/↓、Home/End', () {
      final Map<ShortcutAction, ShortcutBindingSet> win =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      LogicalKeyboardKey soleKey(ShortcutAction action) {
        final List<InputBinding> keys = win[action]!.keyboardBindings;
        expect(keys, hasLength(1), reason: '${action.key} 应恰有一个键盘默认位');
        expect(keys.single.modifiers, isEmpty,
            reason: '${action.key} 默认位不带修饰键');
        return keys.single.key;
      }

      expect(soleKey(ShortcutAction.globalScrollPageDown),
          LogicalKeyboardKey.pageDown);
      expect(soleKey(ShortcutAction.globalScrollPageUp),
          LogicalKeyboardKey.pageUp);
      expect(soleKey(ShortcutAction.globalScrollLineDown),
          LogicalKeyboardKey.arrowDown);
      expect(soleKey(ShortcutAction.globalScrollLineUp),
          LogicalKeyboardKey.arrowUp);
      expect(
          soleKey(ShortcutAction.globalScrollToTop), LogicalKeyboardKey.home);
      expect(
          soleKey(ShortcutAction.globalScrollToBottom), LogicalKeyboardKey.end);
    });

    test('手柄 LB/RB 整屏翻页原样保留；新增四个动作不占手柄键', () {
      final Map<ShortcutAction, ShortcutBindingSet> win =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        win[ShortcutAction.globalScrollPageDown]!
            .gamepadBindings
            .map((GamepadBinding b) => b.button),
        <GamepadButton>[GamepadButton.rb],
      );
      expect(
        win[ShortcutAction.globalScrollPageUp]!
            .gamepadBindings
            .map((GamepadBinding b) => b.button),
        <GamepadButton>[GamepadButton.lb],
      );
      for (final ShortcutAction action in <ShortcutAction>[
        ShortcutAction.globalScrollLineDown,
        ShortcutAction.globalScrollLineUp,
        ShortcutAction.globalScrollToTop,
        ShortcutAction.globalScrollToBottom,
      ]) {
        expect(action.scope, ShortcutScope.global);
        expect(win[action]!.gamepadBindings, isEmpty);
      }
    });

    test('六件套的键在 home+global co-active 组内互不撞键、也不撞 globalBack', () {
      final FushiShortcutRegistry registry = desktopRegistry();
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
      ]) {
        expect(
            registry.resolveKeyboard(key,
                modifiers: const <ModifierKey>{}, scope: ShortcutScope.home),
            isNull,
            reason: 'home scope 不得占用 ${key.keyLabel}');
        expect(
            registry.resolveKeyboard(key,
                modifiers: const <ModifierKey>{},
                scope: ShortcutScope.universal),
            isNull,
            reason: 'universal scope 不得占用 ${key.keyLabel}');
        expect(
            registry.resolveKeyboard(key,
                modifiers: const <ModifierKey>{}, scope: ShortcutScope.global),
            isNotNull,
            reason: 'global scope 应把 ${key.keyLabel} 解析到滚动动作');
      }
    });
  });

  group('零登记纯展示页：键盘真的能滚', () {
    testWidgets('PageDown / ArrowDown / End / Home 依次改变 controller.offset',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpApp(
        tester,
        page: displayOnlyList(controller),
        registry: desktopRegistry(),
      );
      expect(PageScrollRegistry.debugDepth, 0, reason: '本页刻意不登记');
      expect(controller.offset, 0);

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.pageDown), isTrue);
      await tester.pumpAndSettle();
      final double afterPageDown = controller.offset;
      expect(afterPageDown, greaterThan(0), reason: 'PageDown 应整屏下滚');
      expect(afterPageDown, lessThanOrEqualTo(600),
          reason: '整屏 = 0.9 × viewport（测试 viewport 600）');

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      final double afterArrowDown = controller.offset;
      expect(afterArrowDown, greaterThan(afterPageDown), reason: '↓ 应单步下滚');
      expect(afterArrowDown - afterPageDown, lessThan(afterPageDown),
          reason: '单步比整屏小');

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.end), isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent,
          reason: 'End 应滚到底');

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.home), isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, 0, reason: 'Home 应滚回顶');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(controller.offset, 0, reason: '已在顶端时 ↑ 不动、不抛');
    });

    testWidgets('按住方向键（OS 自动重复）持续滚动', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpApp(
        tester,
        page: displayOnlyList(controller),
        registry: desktopRegistry(),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final double afterDown = controller.offset;
      expect(afterDown, greaterThan(0));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(afterDown), reason: '重复沿也要滚');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    });

    testWidgets('实验性焦点导航开启时同样能滚（不受开关门控），且不把焦点踢出页面 sink',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      // 页面级键事件 sink（首页 `_keyboardFocusNode` / 阅读器同款）：skipTraversal、
      // 持焦。它是 `arrowKeyClaimedByFocus` 里 `hasFocusableTargets` 门的真实场景——
      // 树里有 FushiFocusRoot、本页零受管目标、焦点停在一个「不可用」节点上：没门时
      // `controller.move()` 走 ensureFocus 把焦点踢到 app 级兜底节点，页面照样滚，
      // 但挂在 sink 上的页面快捷键从此收不到键。变异实测：删门即红。
      final FocusNode sink =
          FocusNode(debugLabel: 'page-sink', skipTraversal: true);
      addTearDown(sink.dispose);
      await pumpApp(
        tester,
        page: Scaffold(
            body: Focus(focusNode: sink, child: bareDisplayList(controller))),
        registry: desktopRegistry(),
        focusNavigationEnabled: true,
      );
      sink.requestFocus();
      await tester.pump();
      expect(sink.hasPrimaryFocus, isTrue);
      final FushiFocusController focus = FushiFocusRoot.maybeControllerOf(
        tester.element(find.byType(Scaffold)),
        listen: false,
      )!;
      expect(focus.hasFocusableTargets, isFalse, reason: '前置：零受管目标');
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(sink.hasPrimaryFocus, isTrue, reason: '↓ 只滚页，不得把焦点踢到兜底节点');
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.end), isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
    });

    testWidgets('对话框压在页面上时，按键滚的不是被盖住的页面', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: displayOnlyList(controller),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          registry: desktopRegistry(),
          focusNavigationEnabled: false,
          child: child!,
        ),
      ));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.text('row 0')),
        builder: (BuildContext context) =>
            const AlertDialog(content: Text('blocking')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(controller.offset, 0, reason: '非当前路由的 Scrollable 不得被滚');
    });

    testWidgets('已登记 PageScrollRegistry 的页面：可见时经登记滚，被对话框盖住时不滚',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      final ScrollController decoy = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(decoy.dispose);
      PageScrollRegistry.push(controller);
      addTearDown(() => PageScrollRegistry.pop(controller));
      await pumpApp(
        tester,
        // 诱饵列表在树序上**先于**登记列表：第 4 级兜底按 element 树序取第一个
        // 纵向 Scrollable 会命中诱饵；只有第 2 级（登记）真在工作，滚的才是登记的
        // 那个。变异实测：删掉第 2 级即红（诱饵被滚、登记列表不动）。
        page: Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(child: bareDisplayList(decoy)),
              Expanded(child: bareDisplayList(controller)),
            ],
          ),
        ),
        registry: desktopRegistry(),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      final double visibleScrolled = controller.offset;
      expect(visibleScrolled, greaterThan(0), reason: '登记的列表被滚');
      expect(decoy.offset, 0, reason: '树序更前的未登记诱饵不得被滚');

      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (BuildContext context) =>
            const AlertDialog(content: Text('blocking')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(controller.offset, visibleScrolled,
          reason: '登记栈顶仍是被盖住页面的控制器，但它不在当前路由，不得被滚');
    });
  });

  group('审查返工：可见性判据', () {
    testWidgets('IndexedStack 停在 index≥1 的子区：滚可见子区，不滚隐藏子区',
        (WidgetTester tester) async {
      final ScrollController hidden = ScrollController();
      final ScrollController shown = ScrollController();
      addTearDown(hidden.dispose);
      addTearDown(shown.dispose);
      Widget list(ScrollController c, String tag) => ListView.builder(
            controller: c,
            primary: false,
            itemCount: 200,
            itemExtent: 40,
            itemBuilder: (BuildContext context, int i) => Text('$tag $i'),
          );
      await pumpApp(
        tester,
        page: Scaffold(
          body: IndexedStack(
            index: 1,
            children: <Widget>[list(hidden, 'hidden'), list(shown, 'shown')],
          ),
        ),
        registry: desktopRegistry(),
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.pageDown), isTrue);
      await tester.pumpAndSettle();
      expect(shown.offset, greaterThan(0), reason: '可见子区（index 1）被滚');
      expect(hidden.offset, 0, reason: 'Visibility 藏起来的子区不得被滚');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(shown.offset, shown.position.maxScrollExtent);
      expect(hidden.offset, 0);
    });

    testWidgets('已登记但被 Offstage 藏起的控制器不占栈顶语义：滚可见列表',
        (WidgetTester tester) async {
      final ScrollController offstage = ScrollController();
      final ScrollController visible = ScrollController();
      addTearDown(offstage.dispose);
      addTearDown(visible.dispose);
      // 模拟 MediaLibraryShell「惰性构建 + Offstage 保活」下 FushiPageScaffold
      // 已 push 的发现页控制器：栈顶是它，但它整棵在 Offstage 里。
      PageScrollRegistry.push(offstage);
      addTearDown(() => PageScrollRegistry.pop(offstage));
      await pumpApp(
        tester,
        page: Scaffold(
          body: Stack(
            children: <Widget>[
              Offstage(
                offstage: true,
                child: ListView.builder(
                  controller: offstage,
                  primary: false,
                  itemCount: 200,
                  itemExtent: 40,
                  itemBuilder: (BuildContext context, int i) => Text('off $i'),
                ),
              ),
              ListView.builder(
                controller: visible,
                primary: false,
                itemCount: 200,
                itemExtent: 40,
                itemBuilder: (BuildContext context, int i) => Text('on $i'),
              ),
            ],
          ),
        ),
        registry: desktopRegistry(),
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.pageDown), isTrue);
      await tester.pumpAndSettle();
      expect(visible.offset, greaterThan(0), reason: '可见列表经兜底被滚');
      expect(offstage.offset, 0, reason: '登记栈顶但 Offstage 的控制器不得被滚');
    });

    testWidgets('焦点导航开启、本页零受管目标、焦点在原生控件上：↓ 移焦不滚', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final FocusNode first = FocusNode(debugLabel: 'first');
      final FocusNode second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: ListView(
            controller: controller,
            primary: false,
            children: <Widget>[
              SizedBox(
                height: 60,
                child: TextButton(
                  focusNode: first,
                  onPressed: () {},
                  child: const Text('first'),
                ),
              ),
              SizedBox(
                height: 60,
                child: TextButton(
                  focusNode: second,
                  onPressed: () {},
                  child: const Text('second'),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          registry: desktopRegistry(),
          focusNavigationEnabled: true,
          // 生产结构：FushiFocusRoot 在全局导航层之内、Navigator 之上。
          child: FushiFocusRoot(enabled: true, child: child!),
        ),
      ));
      await tester.pumpAndSettle();
      first.requestFocus();
      await tester.pump();
      expect(first.hasPrimaryFocus, isTrue);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      expect(second.hasPrimaryFocus, isTrue,
          reason: '零受管目标不等于零焦点目标：原生控件之间照常移焦');
      expect(controller.offset, 0, reason: '目标在视口内，不该滚');
    });

    testWidgets('内容溢出的对话框：焦点停在路由 scope 时 ↓ 先进第一个按钮，再按才滚',
        (WidgetTester tester) async {
      final ScrollController page = ScrollController();
      final ScrollController dialogScroll = ScrollController();
      addTearDown(page.dispose);
      addTearDown(dialogScroll.dispose);
      final FocusNode ok = FocusNode(debugLabel: 'ok');
      addTearDown(ok.dispose);
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: displayOnlyList(page),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          registry: desktopRegistry(),
          focusNavigationEnabled: false,
          child: child!,
        ),
      ));
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (BuildContext context) => AlertDialog(
          content: SizedBox(
            width: 300,
            height: 300,
            child: ListView.builder(
              controller: dialogScroll,
              primary: false,
              itemCount: 100,
              itemExtent: 30,
              itemBuilder: (BuildContext context, int i) => Text('line $i'),
            ),
          ),
          actions: <Widget>[
            TextButton(
              focusNode: ok,
              onPressed: () {},
              child: const Text('OK'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(ok.hasPrimaryFocus, isFalse, reason: '前置：焦点还停在对话框 scope');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(ok.hasPrimaryFocus, isTrue,
          reason: '弹层里焦点未落到控件时，↓ 先由框架 bootstrap 进第一个按钮');
      expect(dialogScroll.offset, 0, reason: '第一下不滚');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(ok.hasPrimaryFocus, isTrue, reason: '按钮下方无目标，焦点不动');
      expect(dialogScroll.offset, greaterThan(0),
          reason: '焦点已在控件上、无目标 → 滚对话框内容');
      expect(page.offset, 0, reason: '被盖住的页面不动');
    });
  });

  group('让位规则', () {
    testWidgets('焦点在列表中间的可聚焦项上：↓ 移焦而不是单步滚动', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final List<FocusNode> nodes = List<FocusNode>.generate(
        6,
        (int i) => FocusNode(debugLabel: 'btn$i'),
      );
      addTearDown(() {
        for (final FocusNode n in nodes) {
          n.dispose();
        }
      });
      await pumpApp(
        tester,
        page: Scaffold(
          body: ListView(
            controller: controller,
            primary: false,
            children: <Widget>[
              for (int i = 0; i < nodes.length; i++)
                SizedBox(
                  height: 60,
                  child: TextButton(
                    focusNode: nodes[i],
                    onPressed: () {},
                    child: Text('btn $i'),
                  ),
                ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
        registry: desktopRegistry(),
      );
      nodes[2].requestFocus();
      await tester.pump();
      expect(nodes[2].hasPrimaryFocus, isTrue);

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      expect(nodes[3].hasPrimaryFocus, isTrue, reason: '方向上有几何焦点目标时归焦点导航');
      expect(controller.offset, 0,
          reason: '目标已在视口内，不该触发单步滚动（ensureVisible 也无需动）');
    });

    testWidgets('焦点在列表末尾的可聚焦项上：↓ 无目标 → 接管滚动', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      final ScrollController decoy = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(decoy.dispose);
      final FocusNode last = FocusNode(debugLabel: 'last');
      addTearDown(last.dispose);
      await pumpApp(
        tester,
        // 诱饵列表在树序上先于焦点所在列表：钉住阶梯第 1 级「焦点最近的纵向
        // Scrollable 优先」——没有它，第 4 级会去滚树序第一的诱饵。
        page: Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(child: bareDisplayList(decoy)),
              Expanded(
                child: ListView(
                  controller: controller,
                  primary: false,
                  children: <Widget>[
                    SizedBox(
                      height: 60,
                      child: TextButton(
                        focusNode: last,
                        onPressed: () {},
                        child: const Text('only'),
                      ),
                    ),
                    const SizedBox(height: 2000),
                  ],
                ),
              ),
            ],
          ),
        ),
        registry: desktopRegistry(),
      );
      last.requestFocus();
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      expect(last.hasPrimaryFocus, isTrue, reason: '没别的目标，焦点不动');
      expect(controller.offset, greaterThan(0), reason: '列表边缘接管滚动');
      expect(decoy.offset, 0, reason: '焦点所在列表优先于树序更前的诱饵');
    });

    testWidgets('焦点导航开启、焦点在最后一个受管控件上：↓ 无目标 → 滚动', (WidgetTester tester) async {
      // 走的是 [_handleGlobalArrowFocus]（受管目标门）→ `_moveFocusForArrow` 的
      // 尽头：受管控件用完之后还有非聚焦内容（长说明文字）时 ↓ 要把它们滚出来，
      // 而不是死在最后一个控件上。变异实测：拿掉那段滚动回退即红。
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final FocusNode last = FocusNode(debugLabel: 'last-managed');
      addTearDown(last.dispose);
      await pumpApp(
        tester,
        page: Scaffold(
          body: ListView(
            controller: controller,
            primary: false,
            children: <Widget>[
              SizedBox(
                height: 60,
                child: FushiFocusTarget(
                  id: const FushiFocusId('first'),
                  child: TextButton(onPressed: () {}, child: const Text('a')),
                ),
              ),
              SizedBox(
                height: 60,
                child: FushiFocusTarget(
                  id: const FushiFocusId('last'),
                  focusNode: last,
                  child: TextButton(onPressed: () {}, child: const Text('b')),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
        registry: desktopRegistry(),
        focusNavigationEnabled: true,
      );
      last.requestFocus();
      await tester.pump();
      expect(last.hasPrimaryFocus, isTrue);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
      await tester.pumpAndSettle();
      expect(last.hasPrimaryFocus, isTrue, reason: '下方无受管目标，焦点不动');
      expect(controller.offset, greaterThan(0), reason: '受管控件尽头落到滚动');
    });

    testWidgets('解析到了但当前页滚不动：返回 ignored，按键继续冒泡给框架',
        (WidgetTester tester) async {
      // 规则 4 的观测点：把 ↑ / ↓ 在 WidgetsApp 层绑到探针 intent——它在 app 根的
      // Focus.onKeyEvent **之后**才有机会跑。页面已在顶端时 ↑ 滚不动，根层必须放行
      // （探针触发）；↓ 能滚则根层认领（探针不触发）。变异实测：无条件 handled 即红。
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final List<LogicalKeyboardKey> probed = <LogicalKeyboardKey>[];
      await pumpApp(
        tester,
        page: displayOnlyList(controller),
        registry: desktopRegistry(),
        appShortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _ProbeIntent(LogicalKeyboardKey.arrowUp),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _ProbeIntent(LogicalKeyboardKey.arrowDown),
        },
        appActions: <Type, Action<Intent>>{
          _ProbeIntent: CallbackAction<_ProbeIntent>(
            onInvoke: (_ProbeIntent intent) => probed.add(intent.key),
          ),
        },
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(probed, <LogicalKeyboardKey>[LogicalKeyboardKey.arrowUp],
          reason: '顶端 ↑ 滚不动 → 根层放行，框架层收到');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(probed, <LogicalKeyboardKey>[LogicalKeyboardKey.arrowUp],
          reason: '↓ 滚成了 → 根层认领，框架层收不到');
    });

    for (final bool focusNav in <bool>[false, true]) {
      testWidgets('TextField 聚焦时 ↓ / Home / End 一律不接管（焦点导航开关=$focusNav）',
          (WidgetTester tester) async {
        final ScrollController controller = ScrollController();
        addTearDown(controller.dispose);
        final FocusNode field = FocusNode(debugLabel: 'field');
        addTearDown(field.dispose);
        await pumpApp(
          tester,
          page: Scaffold(
            body: ListView(
              controller: controller,
              primary: false,
              children: <Widget>[
                TextField(focusNode: field),
                const SizedBox(height: 2000),
              ],
            ),
          ),
          registry: desktopRegistry(),
          focusNavigationEnabled: focusNav,
        );
        field.requestFocus();
        await tester.pump();
        expect(field.hasPrimaryFocus, isTrue);
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.end,
          LogicalKeyboardKey.home,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          expect(controller.offset, 0, reason: '${key.keyLabel} 应归文本框');
        }
      });
    }
  });
}

class _ProbeIntent extends Intent {
  const _ProbeIntent(this.key);
  final LogicalKeyboardKey key;
}
