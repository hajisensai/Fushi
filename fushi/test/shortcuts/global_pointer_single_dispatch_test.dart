import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';

/// BUG-2031 复盘：**一次鼠标按下，全 app 只准派发一个动作**。
///
/// ## 为什么必须是行为测试，源码守卫救不了
///
/// 本轮第一版给鼠标通道加了两层入口（页面根 [Listener] + app 根兜底 [Listener]），
/// 并用 [MouseBindingDispatch] 做「一次按下只派发一次」的仲裁。但仲裁只覆盖了两层
/// **Listener**，漏掉了第三条真实存在的通道：查词浮层可见时根 Overlay 里的
/// [LookupDismissBarrier]。它调 `onNonPrimaryButtonDown` 之后**不认领**（当时的注释
/// 还写着「纯附加——不 return」），于是：
///
///   侧键绑「返回上一级」 + 浮层可见 → barrier 关词典 **且** app 根 `maybePop()` 退书。
///
/// 而键盘 Esc 在同样状态下**只关词典**（弹窗层先消费、返回 handled 就不冒泡了）。
/// 键鼠语义分叉，一次按下退两级。
///
/// 当时的整批源码守卫**一条都没红**——把 app 根那条兜底整个删掉，695 条测试照样全绿。
/// 原因很直白：守卫查的是「某文件里有没有出现某个 token」，而这个 bug 是**两处各自
/// 正确的代码叠在同一条命中路径上**产生的，不存在任何一个「写错了的字符串」。
///
/// ## 载荷假设（本文件第一条用例把它钉死）
///
/// 修法的全部前提是：barrier 与 app 根同在一条命中路径上，且 **barrier 先收到**。
/// 直觉上容易以为 barrier 叶子的 `ColoredBox`（命中行为 opaque）会把外面的东西挡掉
/// ——那只对**兄弟**成立。app 根的 [Listener] 是 Overlay 的**祖先**，opaque 从不排除
/// 祖先。实测派发序列是 `[barrier, root]`（innermost → outermost），所以「内层认领、
/// 外层让路」恰好复刻键盘那条「近处先消费、返回 handled 就不冒泡」。
void main() {
  setUp(MouseBindingDispatch.resetForTest);
  tearDown(MouseBindingDispatch.resetForTest);

  FushiShortcutRegistry registryWith(Map<ShortcutAction, int> mouseByAction) {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    for (final MapEntry<ShortcutAction, int> e in mouseByAction.entries) {
      registry.updateBinding(
        e.key,
        ShortcutBindingSet(
          mouseBindings: <MouseBinding>[MouseBinding(e.value)],
        ),
      );
    }
    return registry;
  }

  /// 复刻真实层级：`wrapWithGlobalNavigation` 的兜底 [Listener]（祖先）
  /// → Overlay → [页面层, barrier 层]。
  ///
  /// barrier 用的是**真的** [LookupDismissBarrier]，所以它的回调签名与
  /// `_onPointerDown` 的分流逻辑都在被测面里。
  Future<void> pumpTree(
    WidgetTester tester, {
    required void Function(PointerDownEvent) onRootDown,
    void Function(PointerDownEvent)? onBarrierDown,
    void Function(PointerDownEvent)? onPageDown,
    bool barrierVisible = true,
  }) async {
    final OverlayEntry pageEntry = OverlayEntry(
      builder: (BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: onPageDown,
        child: const SizedBox.expand(),
      ),
    );
    final OverlayEntry barrierEntry = OverlayEntry(
      builder: (BuildContext context) => LookupDismissBarrier(
        onTapDismiss: (Offset _) {},
        onSwipeDismiss: () {},
        swipeEnabled: false,
        sensitivity: 0.5,
        onNonPrimaryButtonDown: onBarrierDown,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: onRootDown,
          child: Overlay(
            initialEntries: <OverlayEntry>[
              pageEntry,
              if (barrierVisible) barrierEntry,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pressBack(WidgetTester tester) async {
    final TestGesture gesture = await tester.startGesture(
      const Offset(400, 300),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await gesture.up();
    await tester.pump();
  }

  testWidgets('前提：barrier 与 app 根同在命中路径上，且 barrier 先收到', (
    WidgetTester tester,
  ) async {
    final List<String> order = <String>[];
    await pumpTree(
      tester,
      onRootDown: (PointerDownEvent _) => order.add('root'),
      onBarrierDown: (PointerDownEvent _) => order.add('barrier'),
      onPageDown: (PointerDownEvent _) => order.add('page'),
    );
    await pressBack(tester);

    // 这条一旦变成 ['barrier'] 或 ['root','barrier']，说明 Flutter 的命中/派发语义
    // 变了，下面两条用例的整个修法前提就没了——那时要改的是设计，不是把断言改掉。
    expect(
      order,
      <String>['barrier', 'root'],
      reason: 'app 根 Listener 是 Overlay 的祖先，不被 barrier 叶子的 opaque 排除；'
          '页面层才是被 opaque 兄弟挡住的那个（故不出现在序列里）',
    );
  });

  testWidgets('浮层可见：barrier 消费并认领后，app 根必须让路（一次按下只退一级）', (
    WidgetTester tester,
  ) async {
    final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
      ShortcutAction.globalBack: 3,
    });
    final List<String> fired = <String>[];

    // 与 `BaseSourcePageState.onDismissBarrierNonPrimaryButton` /
    // `DictionaryPageMixin` 同一套三步协议：探测 → 执行 → 认领。
    void barrierHost(PointerDownEvent event) {
      dispatchClaimedMouseAction(event, () {
        fired.add('dismissDict');
        return true;
      });
    }

    // 与 `_handleGlobalPointerDown` 同一套协议。
    void rootFallback(PointerDownEvent event) {
      final ShortcutAction? action = resolveMouseBindingAction(
        registry: registry,
        buttons: event.buttons,
        ladder: const <ShortcutScope>[
          ShortcutScope.universal,
          ShortcutScope.global,
        ],
      );
      if (action == null) return;
      dispatchClaimedMouseAction(event, () {
        fired.add('pop');
        return true;
      });
    }

    await pumpTree(
      tester,
      onRootDown: rootFallback,
      onBarrierDown: barrierHost,
    );
    await pressBack(tester);

    expect(
      fired,
      <String>['dismissDict'],
      reason: '修复前这里是 [dismissDict, pop]：一次侧键关词典 + 退书，'
          '而键盘 Esc 在同样状态下只关词典',
    );
  });

  testWidgets('barrier 没消费（该按钮不在弹窗输入表里）时，app 根照常兜底', (
    WidgetTester tester,
  ) async {
    final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
      ShortcutAction.globalBack: 3,
    });
    final List<String> fired = <String>[];

    // 折不出 token（真实宿主里 `dictionaryPopupPointerToken` 返回 null）⇒ 不执行、
    // **不认领**。这一步是「解析到但没执行的一层不得挡住外层」的镜像用例：少了它，
    // 绑在 universal / global 上的键在浮层可见时会莫名失灵。
    void barrierHost(PointerDownEvent event) {
      // 执行体返回 false ⇒ 不认领。
      dispatchClaimedMouseAction(event, () => false);
    }

    void rootFallback(PointerDownEvent event) {
      final ShortcutAction? action = resolveMouseBindingAction(
        registry: registry,
        buttons: event.buttons,
        ladder: const <ShortcutScope>[
          ShortcutScope.universal,
          ShortcutScope.global,
        ],
      );
      if (action == null) return;
      dispatchClaimedMouseAction(event, () {
        fired.add('pop');
        return true;
      });
    }

    await pumpTree(
      tester,
      onRootDown: rootFallback,
      onBarrierDown: barrierHost,
    );
    await pressBack(tester);

    expect(fired, <String>['pop']);
  });

  testWidgets('浮层不可见：页面层认领后 app 根让路', (WidgetTester tester) async {
    final FushiShortcutRegistry registry = registryWith(<ShortcutAction, int>{
      ShortcutAction.globalBack: 3,
    });
    final List<String> fired = <String>[];

    void pageHost(PointerDownEvent event) {
      // 页面阶梯现在**含** universal，故 globalBack 由页面自己的逐级退出执行体接手
      // （BUG-2031：第一版阶梯只有页面 scope，globalBack 只能落到 app 根的平
      // `maybePop()`，比键盘少一级）。
      final ShortcutAction? action = resolveMouseBindingAction(
        registry: registry,
        buttons: event.buttons,
        ladder: const <ShortcutScope>[
          ShortcutScope.video,
          ShortcutScope.universal,
        ],
      );
      if (action == null) return;
      dispatchClaimedMouseAction(event, () {
        fired.add('pageStagedExit');
        return true;
      });
    }

    void rootFallback(PointerDownEvent event) {
      dispatchClaimedMouseAction(event, () {
        fired.add('pop');
        return true;
      });
    }

    await pumpTree(
      tester,
      onRootDown: rootFallback,
      onPageDown: pageHost,
      barrierVisible: false,
    );
    await pressBack(tester);

    expect(
      fired,
      <String>['pageStagedExit'],
      reason: '页面的逐级退出赢，app 根的平 maybePop 让路',
    );
  });

  // ── 第二条腿：弹窗矩形**之内**（BUG-2031 收尾） ──────────────────────────────
  //
  // 上面四条用的是**模型**根兜底（测试自己写的 Listener）。它们钉不住两件事：
  //
  //   1. 生产的 `_handleGlobalPointerDown` 是否真的挂在那儿——把它整条删掉，上面四条
  //      照样全绿（这正是本轮审查最初的发现：把根兜底打死，695 条全绿）；
  //   2. `DictionaryPopupLayer` 那条腿。它与 barrier 是同一个几何问题的两半：barrier
  //      管弹窗矩形**之外**，它管矩形**之内**。上一轮只修了 barrier，本层仍旧「折完
  //      token 调 sink 就往下走」，于是症状只是从「浮窗外」挪到了「浮窗上」。
  //
  // 所以这两条用**真的** [wrapWithGlobalNavigation]（生产根兜底）+ **真的**
  // [DictionaryPopupLayer]（生产第二条腿）+ 真 Navigator 路由，判据是路由有没有被
  // 多 pop 一次。
  group('弹窗表面那条腿（真 wrapWithGlobalNavigation + 真 DictionaryPopupLayer）', () {
    /// 侧键（DOM 3）绑「返回上一级」——用户复诉的正是这个配置。
    FushiShortcutRegistry backOnMouse3() =>
        registryWith(<ShortcutAction, int>{ShortcutAction.globalBack: 3});

    const DictionaryPopupInputSpec spec =
        DictionaryPopupInputSpec(mouseButtons: <int>[3]);

    /// [popupSurface] 决定弹窗矩形之内那条腿怎么接：生产实现，还是「不认领」的对照组。
    Future<GlobalKey<NavigatorState>> pumpRealTree(
      WidgetTester tester, {
      required FushiShortcutRegistry registry,
      required Widget Function(Widget hitBox) popupSurface,
    }) async {
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          builder: (BuildContext context, Widget? child) =>
              wrapWithGlobalNavigation(
            navigatorKey: navigatorKey,
            registry: registry,
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      // 必须先推一条可 pop 的路由：根兜底的 globalBack 只在 canPop 时动作，栈底时
      // 它什么都不做 —— 那样「根兜底没再派发一次」会因为无路可退而恒真假绿。
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  height: 200,
                  child: popupSurface(const SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(navigatorKey.currentState!.canPop(), isTrue);
      return navigatorKey;
    }

    /// 结果无内容 + 非搜索态 ⇒ 走 Flutter 占位分支，不挂载平台视图（widget 测试里
    /// 没有 WebView）。指针通道包在整层最外面，与是否挂 WebView 无关
    /// （沿用 `test/pages/dictionary_popup_pointer_input_test.dart` 的既有范式）。
    Widget realPopupLayer(List<String> tokens) => DictionaryPopupLayer(
          result: null,
          webViewKey: GlobalKey(),
          onDismiss: () {},
          onTextSelected: (_, __) {},
          onLinkClick: (_, __) {},
          onMineEntry: (_) async => const MinePopupResult(),
          onDuplicateCheck: (_, __) async => false,
          inputSpec: spec,
          onHostInputToken: tokens.add,
          debugHostOwnsPointer: true,
        );

    Future<void> pressBackOn(WidgetTester tester, Finder target) async {
      final Offset at = tester.getCenter(target);
      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await gesture.downWithCustomEvent(
        at,
        PointerDownEvent(
          position: at,
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        ),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('指针压在浮窗上按侧键：弹窗表面消费并认领，app 根必须让路', (
      WidgetTester tester,
    ) async {
      final List<String> tokens = <String>[];
      final GlobalKey<NavigatorState> navigatorKey = await pumpRealTree(
        tester,
        registry: backOnMouse3(),
        popupSurface: (Widget _) => realPopupLayer(tokens),
      );

      await pressBackOn(tester, find.byType(DictionaryPopupLayer));

      expect(
        tokens,
        <String>['Mouse3'],
        reason: '弹窗表面必须真的接到这次按下（否则本条测错了对象）',
      );
      expect(
        navigatorKey.currentState!.canPop(),
        isTrue,
        reason: '修复前这里是「关词典 + 退书」：弹窗表面折完 token 就往下走、一个 '
            'claim 都没有，而 app 根兜底是它的祖先，opaque/deferToChild 都排除不掉祖先',
      );
    });

    testWidgets('对照组：同一棵树里换成不认领的腿，app 根确实会再派发一次', (
      WidgetTester tester,
    ) async {
      final List<String> tokens = <String>[];
      final GlobalKey<NavigatorState> navigatorKey = await pumpRealTree(
        tester,
        registry: backOnMouse3(),
        // 修复前那条腿的形态：折 token → 调 sink → 往下走，不认领。
        popupSurface: (Widget hitBox) => Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (PointerDownEvent event) {
            final String? token = dictionaryPopupPointerToken(
              buttons: event.buttons,
              spec: spec,
            );
            if (token == null) return;
            tokens.add(token);
          },
          child: hitBox,
        ),
      );

      await pressBackOn(tester, find.byType(Listener).first);

      expect(tokens, <String>['Mouse3']);
      expect(
        navigatorKey.currentState!.canPop(),
        isFalse,
        reason: '这条钉住「生产的 app 根兜底确实活着、且祖先照样收得到」。'
            '它一旦变绿，说明根兜底被打死了 —— 上一条也就跟着变成恒真的假绿',
      );
    });
  });
}
