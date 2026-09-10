import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart';

void main() {
  Widget buildApp({
    required VoidCallback onDismiss,
    double sensitivity = 0.3,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SwipeDismissWrapper(
          sensitivity: sensitivity,
          onDismiss: onDismiss,
          child: const SizedBox(
            width: 300,
            height: 100,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
  }

  group('SwipeDismissWrapper', () {
    testWidgets('renders child', (tester) async {
      await tester.pumpWidget(buildApp(onDismiss: () {}));

      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.blue,
        ),
        findsOneWidget,
      );
    });

    testWidgets('horizontal swipe past threshold calls onDismiss',
        (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      // Default sensitivity 0.3 → threshold = 30 + 0.7*160 = 142
      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });

    testWidgets('small horizontal drag does not dismiss', (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isFalse);
    });

    testWidgets('vertical drag does not dismiss', (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, 200));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isFalse);
    });

    // 闪回回归守卫：松手命中阈值的那一帧，浮层必须保持「已滑走」状态
    // （位移不回弹到 0、opacity 已开始淡出但不回弹到满不透明），由上层负责移除——
    // 绝不能回弹到原位且满不透明（那一帧的回弹＝用户看到的「闪回一下再关闭」）。
    // TODO-890：退场帧 opacity 随位移淡出（对齐 _BodySwipeDismissDetector），松手当帧
    // 卡片仍在屏内（_dragX≈200 < 卡片宽300+边距24）故 opacity 介于 0 与 1，而非瞬灭到 0。
    testWidgets('dismiss frame does NOT snap back: faded, offset held',
        (tester) async {
      // onDismiss 不移除子树（模拟 reader 的 Visibility 保留 / 上层尚未移除的一帧），
      // 这样才能观察退场帧 wrapper 自身的视觉，而非被移除。
      await tester.pumpWidget(buildApp(onDismiss: () {}));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      // 默认灵敏度 0.3 → 阈值 142；拖 200px 命中。
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.up();
      // 松手当帧（不 settle）：观察退场态视觉。
      await tester.pump();

      final Opacity opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.byType(ColoredBox),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, lessThan(1.0),
          reason: '退场帧必须开始淡出（视觉正滑出），不得回弹到满不透明＝闪回');
      expect(opacity.opacity, greaterThan(0.0),
          reason: '退场帧卡片仍在屏内，opacity 不应瞬灭到 0（那等于不可见滑出）');

      final Transform transform = tester.widget<Transform>(
        find.ancestor(
          of: find.byType(Opacity),
          matching: find.byType(Transform),
        ),
      );
      final double dx = transform.transform.getTranslation().x;
      expect(dx, isNot(0.0), reason: '退场帧位移不得归零回弹（应停在滑走位置，由上层移除）');
    });

    // 复用守卫：reader 复用同一浮层位置（onDismiss 后换新 child 再次显示）时，
    // 退场态必须被清掉，否则复用后的浮层会被永久压到 opacity 0＝不可见。
    testWidgets('reused popup resets dismiss state (not stuck invisible)',
        (tester) async {
      Widget buildWith(Widget child) {
        return MaterialApp(
          home: Scaffold(
            body: SwipeDismissWrapper(onDismiss: () {}, child: child),
          ),
        );
      }

      const Widget first = SizedBox(
        width: 300,
        height: 100,
        child: ColoredBox(color: Colors.blue),
      );
      await tester.pumpWidget(buildWith(first));

      // 滑动关闭 → 进入退场态（opacity 0）。
      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pump();

      // 上层用新 child 复用同一 wrapper 位置（State 复用）。
      const Widget reused = SizedBox(
        width: 300,
        height: 100,
        child: ColoredBox(color: Colors.red),
      );
      await tester.pumpWidget(buildWith(reused));
      await tester.pump();

      final Opacity opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.byType(ColoredBox),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1.0, reason: '复用同一 wrapper 后退场态必须复位，浮层须重新完全可见');
    });
  });

  // TODO-890：过阈值松手后 onDismiss 不在松手当帧触发，而是等滑出补间动画跑完
  // （AnimationStatus.completed）才触发——避免 dismiss 与动画竞争。
  testWidgets(
      'TODO-890 dismiss fires only after the slide-out animation '
      'completes, not on release', (tester) async {
    int dismissed = 0;
    await tester.pumpWidget(buildApp(onDismiss: () => dismissed++));

    final center = tester.getCenter(find.byType(SizedBox).first);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(200, 0)); // clears the 142 threshold
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(dismissed, 0, reason: '松手当帧动画刚开始，dismiss 必须等滑出补间跑完');
    await tester.pumpAndSettle();
    expect(dismissed, 1, reason: '滑出补间完成后 onDismiss 触发一次');
  });

  // TODO-890：滑出补间把退场卡片朝拖动方向平移到「卡片宽 + 边距」之外（远超松手时
  // 的 _dragX），证明卡片是「滑走」而非停在松手位置定格。
  testWidgets('TODO-890 slide-out translates the card past its own width',
      (tester) async {
    await tester.pumpWidget(buildApp(onDismiss: () {}));

    final center = tester.getCenter(find.byType(SizedBox).first);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.up();
    // Drive the tween partway: translation should already be heading past the
    // 200px release toward (childWidth=300 + 24 margin) off-screen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    final Transform transform = tester.widget<Transform>(
      find.ancestor(
        of: find.byType(Opacity),
        matching: find.byType(Transform),
      ),
    );
    final double dx = transform.transform.getTranslation().x;
    expect(dx, greaterThan(200), reason: '滑出补间把卡片平移到松手位置之外（朝屏外滑走），而非定格');
    await tester.pumpAndSettle();
  });

  // TODO-890 复核盲区守卫：滑出补间「中段」卡片必须可见（opacity 严格介于 0 与 1）。
  // 旧 B 路径退场期 opacity 硬 =0.0，整段补间用一张完全透明的卡片平移→滑出动画不可见
  // ＝等于没做。本断言锁住：补间中段 opacity ∈ (0,1)，对齐 A 路径随位移淡出。
  testWidgets(
      'TODO-890 slide-out card stays visible mid-tween (opacity in 0..1)',
      (tester) async {
    await tester.pumpWidget(buildApp(onDismiss: () {}));

    final center = tester.getCenter(find.byType(SizedBox).first);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.up();
    // 推进到补间中段（200ms 时长的约一半）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Opacity opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byType(ColoredBox),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, greaterThan(0.0),
        reason: '滑出补间中段卡片必须可见，opacity 不得为 0（否则动画用透明卡片＝不可见）');
    expect(opacity.opacity, lessThan(1.0),
        reason: '滑出补间中段已部分淡出，opacity 应随位移降到满不透明以下');
    await tester.pumpAndSettle();
  });

  // TODO-890 顺修守卫：未过阈值的 spring-back 补间完成后，残留的决策/方向状态必须
  // 复位——否则下一次拖动会带着上一手的 _decided / _isHorizontal。通过「先一次未过
  // 阈值横滑（弹回），再一次小幅纵滑不触发关闭」间接验证状态已复位、无横滑残留。
  testWidgets('TODO-890 spring-back resets decision state after settle',
      (tester) async {
    int dismissed = 0;
    // 灵敏度 0.3 → 阈值 142；先拖 80px（< 142）不过阈值，松手 spring-back。
    await tester.pumpWidget(buildApp(onDismiss: () => dismissed++));

    final center = tester.getCenter(find.byType(SizedBox).first);
    final g1 = await tester.startGesture(center);
    await g1.moveBy(const Offset(80, 0));
    await g1.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0, reason: '未过阈值不应关闭');

    // 复位后再来一次纵向拖动：不得被上一手的横滑决策残留误判为横滑关闭。
    final g2 = await tester.startGesture(center);
    await g2.moveBy(const Offset(0, 200));
    await g2.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0, reason: 'spring-back 后状态已复位，纵向拖动不应触发关闭');
  });

  // BUG-051: SwipeDismissWrapper 基于 Listener（onPointerMove/Up），指针事件会
  // 派发到 hit-test 路径上的所有祖先 Listener。因此把一个嵌套层（自带 wrapper）
  // 套进一个外层 wrapper 时，横滑嵌套层会同时驱动外层 → 整张卡片连带平移/关闭。
  // 这两个测试锁住该机制（危害）与修复模式（祖先 wrapper 必须在嵌套时移除/不渲染）。
  group('SwipeDismissWrapper nesting hazard (BUG-051)', () {
    Widget buildNested({
      required VoidCallback onOuterDismiss,
      required VoidCallback onInnerDismiss,
      required bool includeOuter,
    }) {
      final Widget inner = SwipeDismissWrapper(
        sensitivity: 0.9, // 阈值 46，100px 横滑必触发
        onDismiss: onInnerDismiss,
        child: const SizedBox(
          key: ValueKey<String>('inner-child'),
          width: 200,
          height: 80,
          child: ColoredBox(color: Colors.red),
        ),
      );
      final Widget body = includeOuter
          ? SwipeDismissWrapper(
              sensitivity: 0.9,
              onDismiss: onOuterDismiss,
              child: inner,
            )
          : inner;
      return MaterialApp(home: Scaffold(body: Center(child: body)));
    }

    Future<void> dragInner(WidgetTester tester) async {
      final center =
          tester.getCenter(find.byKey(const ValueKey<String>('inner-child')));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(120, 0));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets(
        'with an ancestor wrapper present, a swipe on the nested layer fires '
        'BOTH dismiss callbacks (the bug mechanism)', (tester) async {
      bool outer = false;
      bool inner = false;
      await tester.pumpWidget(buildNested(
        onOuterDismiss: () => outer = true,
        onInnerDismiss: () => inner = true,
        includeOuter: true,
      ));

      await dragInner(tester);

      expect(inner, isTrue, reason: '嵌套层自身应被横滑');
      expect(outer, isTrue, reason: 'Listener 冒泡使外层也被驱动——这正是「滑动子弹窗连带整卡」的根因');
    });

    testWidgets(
        'gating out the ancestor wrapper makes the same swipe fire ONLY the '
        'nested dismiss (the fix pattern)', (tester) async {
      bool outer = false;
      bool inner = false;
      await tester.pumpWidget(buildNested(
        onOuterDismiss: () => outer = true,
        onInnerDismiss: () => inner = true,
        includeOuter: false, // 镜像 _buildCard: 栈深>1 时不渲染外层 wrapper
      ));

      await dragInner(tester);

      expect(inner, isTrue);
      expect(outer, isFalse, reason: '外层 wrapper 被移除后，横滑嵌套层不再连带平移/关闭整卡');
    });
  });

  group('SwipeDismissWrapper sensitivity changes dismiss threshold', () {
    Widget buildSingle({
      required Key childKey,
      required VoidCallback onDismiss,
      required double sensitivity,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SwipeDismissWrapper(
            sensitivity: sensitivity,
            onDismiss: onDismiss,
            child: SizedBox(
              key: childKey,
              width: 300,
              height: 100,
              child: const ColoredBox(color: Colors.green),
            ),
          ),
        ),
      );
    }

    // 纯水平拖动 100px：高灵敏 0.9 阈值 46 → 触发；低灵敏 0.1 阈值 174 → 不触发。
    const double dragDistance = 100;

    Future<bool> dragAndReportDismiss(
      WidgetTester tester, {
      required double sensitivity,
    }) async {
      bool dismissed = false;
      const childKey = ValueKey<String>('swipe-child');
      await tester.pumpWidget(
        buildSingle(
          childKey: childKey,
          onDismiss: () => dismissed = true,
          sensitivity: sensitivity,
        ),
      );

      final center = tester.getCenter(find.byKey(childKey));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(dragDistance, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      return dismissed;
    }

    testWidgets('high sensitivity (0.9) dismisses on a 100px horizontal drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.9);
      expect(dismissed, isTrue);
    });

    testWidgets('low sensitivity (0.1) does NOT dismiss on the same 100px drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(dismissed, isFalse);
    });

    testWidgets('same drag distance: high sensitivity fires, low does not',
        (tester) async {
      final highFired = await dragAndReportDismiss(tester, sensitivity: 0.9);
      final lowFired = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(highFired, isTrue);
      expect(lowFired, isFalse);
      expect(highFired, isNot(equals(lowFired)));
    });
  });
  // 墨水屏模式：松手后的滑出/弹回补间必须归零（慢刷新屏上 200ms 位移+淡出 = 灰阶残影，
  // 与弹窗正文 _BodySwipeDismissDetector 的既有 eink 处理同款）。判别力靠「只 pump 一帧」：
  // 补间还在时该帧不可能 dismiss，归零后当帧就 dismiss。
  group('SwipeDismissWrapper eink 取消滑关补间', () {
    Widget buildEinkApp({required bool eink, required VoidCallback onDismiss}) {
      return MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
        ),
        home: Scaffold(
          body: SwipeDismissWrapper(
            onDismiss: onDismiss,
            child: const SizedBox(
              width: 300,
              height: 100,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      );
    }

    /// 过阈值横拖后松手，只 pump **一帧**，回报此刻是否已 dismiss。
    Future<bool> dragAndPumpOneFrame(
      WidgetTester tester, {
      required bool eink,
    }) async {
      bool dismissed = false;
      await tester.pumpWidget(
        buildEinkApp(eink: eink, onDismiss: () => dismissed = true),
      );
      final Offset center = tester.getCenter(find.byType(SizedBox).first);
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pump();
      return dismissed;
    }

    testWidgets('非 eink：松手当帧仍在补间，尚未 onDismiss', (WidgetTester tester) async {
      expect(await dragAndPumpOneFrame(tester, eink: false), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('eink：补间归零，松手当帧即 onDismiss', (WidgetTester tester) async {
      expect(await dragAndPumpOneFrame(tester, eink: true), isTrue);
    });

    testWidgets('eink 未过阈值：弹回同样不留补间，且不误关', (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(
        buildEinkApp(eink: true, onDismiss: () => dismissed = true),
      );
      final Offset center = tester.getCenter(find.byType(SizedBox).first);
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(60, 0));
      await gesture.up();
      await tester.pump();

      expect(dismissed, isFalse);
      // 补间归零 ⇒ 已回到原位，没有任何待跑的帧（pumpAndSettle 不会再推进动画）。
      final Transform transform = tester.widget<Transform>(
        find.byType(Transform).first,
      );
      expect(transform.transform.getTranslation().x, 0);
    });
  });

  // BUG-2418：用户诉求是「滑动关闭那段动画能**单独**关掉」，此前唯一途径是开墨水屏
  // 模式顺带归零（想要瞬时关闭就得连带吃下纯黑白主题）。新开关 popup_dismiss_animation
  // 默认 true=保持既有手感，关掉则松手当帧就关。判别力同上：只 pump 一帧。
  group('SwipeDismissWrapper「弹窗关闭动画」开关', () {
    tearDown(() async {
      // 单例偏好：必须还原，否则泄漏到同进程后续用例。
      await ReaderFushiSource.instance.setPopupDismissAnimation(true);
    });

    // key：同一个用例里连跑两次时必须换 State。第一次滑关后 wrapper 停在退场态
    // （_dismissing=true，等宿主换 child），而这里的 child 是 const、跨 build 恒
    // identical，didUpdateWidget 的「换了 child 才复位」判不出来，第二次拖动会被
    // _beginDrag/_handleDragDelta 的 `if (_dismissing) return` 整个吃掉。
    Widget buildApp({
      required bool eink,
      required VoidCallback onDismiss,
      Key? key,
    }) {
      return MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
        ),
        home: Scaffold(
          body: SwipeDismissWrapper(
            key: key,
            onDismiss: onDismiss,
            child: const SizedBox(
              width: 300,
              height: 100,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      );
    }

    /// 过阈值横拖后松手，只 pump **一帧**，回报此刻是否已 dismiss。
    Future<bool> dragAndPumpOneFrame(
      WidgetTester tester, {
      required bool animation,
      bool eink = false,
      Key? key,
    }) async {
      await ReaderFushiSource.instance.setPopupDismissAnimation(animation);
      bool dismissed = false;
      await tester.pumpWidget(
        buildApp(eink: eink, onDismiss: () => dismissed = true, key: key),
      );
      final Offset center = tester.getCenter(find.byType(SizedBox).first);
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pump();
      return dismissed;
    }

    testWidgets('默认（开关开着、非 eink）：松手当帧仍在补间', (WidgetTester tester) async {
      expect(await dragAndPumpOneFrame(tester, animation: true), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('开关关掉：补间归零，松手当帧即 onDismiss', (WidgetTester tester) async {
      expect(await dragAndPumpOneFrame(tester, animation: false), isTrue);
    });

    testWidgets('同一条拖动：开着仍在补间、关掉当帧就关（开关真的改变行为）', (
      WidgetTester tester,
    ) async {
      final bool onStillTweening = await dragAndPumpOneFrame(
        tester,
        animation: true,
        key: const ValueKey<String>('animation-on'),
      );
      await tester.pumpAndSettle();
      final bool offDismissedNow = await dragAndPumpOneFrame(
        tester,
        animation: false,
        key: const ValueKey<String>('animation-off'),
      );
      expect(onStillTweening, isFalse);
      expect(offDismissedNow, isTrue);
      expect(onStillTweening, isNot(equals(offDismissedNow)));
    });

    testWidgets('eink 下即使开关开着也仍归零（eink 不被开关覆盖）', (WidgetTester tester) async {
      expect(
        await dragAndPumpOneFrame(tester, animation: true, eink: true),
        isTrue,
      );
    });

    testWidgets('开关关掉、未过阈值：弹回不留补间且不误关', (WidgetTester tester) async {
      await ReaderFushiSource.instance.setPopupDismissAnimation(false);
      bool dismissed = false;
      await tester.pumpWidget(
        buildApp(eink: false, onDismiss: () => dismissed = true),
      );
      final Offset center = tester.getCenter(find.byType(SizedBox).first);
      final Offset before = tester.getTopLeft(find.byType(SizedBox).first);
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(60, 0));
      await gesture.up();
      await tester.pump();

      expect(dismissed, isFalse);
      // 开关关掉后本 wrapper 一层 [Transform] 都不挂（BUG-2439），所以断言落在
      // 「卡片没挪过」这一用户可见事实上，而不是补间控制器的中间量。
      expect(
        find.descendant(
          of: find.byType(SwipeDismissWrapper),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(tester.getTopLeft(find.byType(SizedBox).first), before);
    });
  });

  /// BUG-2439：开关关掉后**跟手期**也不许有位移。
  ///
  /// BUG-2405 只归零了松手后的补间，`Transform.translate` 原样留着 —— 用户拖动时仍看
  /// 得见弹窗跟着手指滑一段才消失，与「关掉则瞬间关闭」的副标题不符。判别点必须落在
  /// **手指还没抬起**的那一帧：抬手后的行为两版一样（都当帧关），只看结果分不出来。
  group('SwipeDismissWrapper「弹窗关闭动画」关掉后跟手期零位移（BUG-2439）', () {
    tearDown(() async {
      await ReaderFushiSource.instance.setPopupDismissAnimation(true);
    });

    /// 过阈值横拖但**不抬手**，回报卡片左上角相对拖动前挪了多少 px。
    Future<double> dragWithoutReleasing(
      WidgetTester tester, {
      required bool animation,
      Key? key,
    }) async {
      await ReaderFushiSource.instance.setPopupDismissAnimation(animation);
      bool dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SwipeDismissWrapper(
              key: key,
              onDismiss: () => dismissed = true,
              child: const SizedBox(
                width: 300,
                height: 100,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      final Finder card = find.byType(SizedBox).first;
      final Offset before = tester.getTopLeft(card);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(card),
      );
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      final double moved = tester.getTopLeft(card).dx - before.dx;
      // 收尾：抬手 + settle，别把手势和补间漏给下一个用例。
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dismissed, isTrue, reason: '过阈值抬手后总该关，两版一致');
      return moved;
    }

    testWidgets('开关开着：跟手期卡片跟着手指走（既有手感不变）', (WidgetTester tester) async {
      expect(await dragWithoutReleasing(tester, animation: true), 200);
    });

    testWidgets('开关关掉：跟手期卡片一动不动', (WidgetTester tester) async {
      expect(await dragWithoutReleasing(tester, animation: false), 0);
    });

    testWidgets('同一条拖动：开着跟手位移 200、关掉恒 0（开关真的改变跟手期行为）', (
      WidgetTester tester,
    ) async {
      final double on = await dragWithoutReleasing(
        tester,
        animation: true,
        key: const ValueKey<String>('follow-on'),
      );
      final double off = await dragWithoutReleasing(
        tester,
        animation: false,
        key: const ValueKey<String>('follow-off'),
      );
      expect(on, 200);
      expect(off, 0);
      expect(on, isNot(equals(off)));
    });

    testWidgets('开关关掉：跟手期不挂 Transform/Opacity（不是靠 offset 0 假装不动）', (
      WidgetTester tester,
    ) async {
      await ReaderFushiSource.instance.setPopupDismissAnimation(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SwipeDismissWrapper(
              onDismiss: () {},
              child: const SizedBox(
                width: 300,
                height: 100,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      final Finder card = find.byType(SizedBox).first;
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(card),
      );
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(SwipeDismissWrapper),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SwipeDismissWrapper),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
