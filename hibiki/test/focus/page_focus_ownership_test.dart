import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';

void main() {
  /// 建一个真挂在焦点树上的 [PageFocusOwnership]，这样 `requestFocus` 有可观测
  /// 效果；并登记卸载/dispose，避免 pending 的 post-frame 回调漏到下一个测试。
  Future<(PageFocusOwnership, List<FocusReclaimCause>)> mount(
    WidgetTester tester, {
    required bool Function(FocusReclaimCause cause) canOwn,
  }) async {
    final FocusNode node = FocusNode(debugLabel: 'body');
    final List<FocusReclaimCause> asked = <FocusReclaimCause>[];
    final PageFocusOwnership ownership = PageFocusOwnership(
      node: node,
      canOwn: (FocusReclaimCause cause) {
        asked.add(cause);
        return canOwn(cause);
      },
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Focus(focusNode: node, child: const SizedBox()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      node.dispose();
    });
    return (ownership, asked);
  }

  testWidgets('reclaim honours the page predicate',
      (WidgetTester tester) async {
    final (PageFocusOwnership ownership, _) = await mount(
      tester,
      canOwn: (FocusReclaimCause c) => c == FocusReclaimCause.gesture,
    );

    expect(ownership.reclaim(FocusReclaimCause.appResumed), isFalse);
    await tester.pump();
    expect(ownership.node.hasFocus, isFalse);

    expect(ownership.reclaim(FocusReclaimCause.gesture), isTrue);
    await tester.pump();
    expect(ownership.node.hasFocus, isTrue);
  });

  testWidgets('the cause is passed through to the predicate',
      (WidgetTester tester) async {
    final (PageFocusOwnership ownership, List<FocusReclaimCause> asked) =
        await mount(tester, canOwn: (FocusReclaimCause _) => false);

    for (final FocusReclaimCause cause in FocusReclaimCause.values) {
      ownership.reclaim(cause);
    }

    expect(asked, FocusReclaimCause.values);
  });

  testWidgets('reclaimAfterFrame defers to the next frame',
      (WidgetTester tester) async {
    final (PageFocusOwnership ownership, List<FocusReclaimCause> asked) =
        await mount(tester, canOwn: (FocusReclaimCause _) => true);

    ownership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    expect(asked, isEmpty, reason: 'must not run synchronously');

    await tester.pumpAndSettle();
    expect(asked, <FocusReclaimCause>[FocusReclaimCause.contentReady]);
    expect(ownership.node.hasFocus, isTrue);
  });

  // ── TODO-2617：高频 reclaim 的代价 ─────────────────────────────────────
  //
  // 阅读器的 `onWheelPaginate` 在翻页 in-flight 期间对**每个** wheel tick 都调一次
  // `reclaim(FocusReclaimCause.gesture)`（BUG-1380 之后；纵向滚轮更是从 TODO-737 起
  // 就一直如此）。这被判定为**可接受**，前提是下面两条不变量成立——它们不是 Flutter
  // 的实现细节，而是 [PageFocusOwnership] 对所有高频调用方的承诺：
  //
  // ① 节点已持焦时再 reclaim 是**静默 no-op**：不发通知、不换 primaryFocus。
  //    （`FocusNode._doRequestFocus` 在 `hasPrimaryFocus` 上快返；
  //     `FocusManager._markNeedsUpdate` 还用 `_haveScheduledUpdate` 合并同帧请求。）
  // ② reclaim **不做 reveal**：绝不把节点滚进视口。历史上「触屏快速滚动被拉回居中
  //    某控件」的根因正是被动焦点修复带的 `HibikiFocusScroll.ensureVisible(alignment:
  //    0.5)`（`focus_repair_touch_no_scroll_test.dart`）。那是 `HibikiFocusController`
  //    的路径；一旦有人把同样的 reveal 搬进本类，高频 wheel tick 就会当场重演它。
  //
  // 任一条被破坏，高频调用方就必须改成去抖——所以这两条测试红了不要放宽，
  // 要么改回来，要么同时收敛 `onWheelPaginate` 的频次。
  group('TODO-2617 high-frequency reclaim stays cheap', () {
    testWidgets('reclaiming again while already focused notifies nobody',
        (WidgetTester tester) async {
      final (PageFocusOwnership ownership, _) =
          await mount(tester, canOwn: (FocusReclaimCause _) => true);

      expect(ownership.reclaim(FocusReclaimCause.gesture), isTrue);
      await tester.pumpAndSettle();
      expect(ownership.node.hasPrimaryFocus, isTrue);

      int nodeNotifications = 0;
      void onNode() => nodeNotifications++;
      ownership.node.addListener(onNode);
      addTearDown(() => ownership.node.removeListener(onNode));

      int managerNotifications = 0;
      void onManager() => managerNotifications++;
      FocusManager.instance.addListener(onManager);
      addTearDown(() => FocusManager.instance.removeListener(onManager));

      // **必须逐帧驱动**：真实 wheel tick 相隔 ~60ms（好几帧），不是同一帧内连打。
      // 同帧内连打是测不出东西的——FocusManager 的 `_haveScheduledUpdate` 会把同批
      // 请求合并掉，连「reclaim 改成先 unfocus 再 requestFocus」这种写法都测不红。
      // 只有跨帧调用才让「每次都真的动一下焦点」暴露成可数的通知。
      for (int i = 0; i < 20; i++) {
        expect(ownership.reclaim(FocusReclaimCause.gesture), isTrue,
            reason: '判据通过时 reclaim 仍然「发起了请求」，返回值不因幂等而改变');
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(nodeNotifications, 0,
          reason: '已持焦的节点被反复 reclaim 不得产生任何焦点变更通知——'
              '有通知就意味着每个 wheel tick 都在真的动焦点树（Focus widget 逐 tick rebuild）');
      expect(managerNotifications, 0, reason: 'FocusManager 不得因重复请求而广播焦点变更');
      expect(ownership.node.hasPrimaryFocus, isTrue,
          reason: '50 次之后焦点仍稳稳在正文，不存在抖动/让位');
    });

    testWidgets('repeated reclaim never scrolls the surrounding viewport',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      final FocusNode node = FocusNode(debugLabel: 'body');
      final PageFocusOwnership ownership = PageFocusOwnership(
        node: node,
        canOwn: (FocusReclaimCause _) => true,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 600)),
            child: SingleChildScrollView(
              controller: controller,
              child: Column(
                children: <Widget>[
                  const SizedBox(height: 2000),
                  Focus(
                    focusNode: node,
                    child: const SizedBox(height: 50, width: 800),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        node.dispose();
        controller.dispose();
      });

      // 节点的 box 落在 [2000, 2050]；视口 [1900, 2500] 里它可见但**远离中心**，
      // 所以任何 `alignment: 0.5` 的 reveal 都会立刻表现为 offset 变化。
      controller.jumpTo(1900);
      await tester.pump();
      final double offsetBefore = controller.offset;

      for (int i = 0; i < 20; i++) {
        expect(ownership.reclaim(FocusReclaimCause.gesture), isTrue);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(controller.offset, offsetBefore,
          reason: '焦点回收不得把视口滚动到节点上——用户正在滑动时这就是「滚一半被拉回去」，'
              '与 HibikiFocusController 那次触屏回归同一形态');
      expect(node.hasPrimaryFocus, isTrue);
    });
  });

  group('guardOverlay', () {
    testWidgets('returns focus after the overlay resolves normally',
        (WidgetTester tester) async {
      final (PageFocusOwnership ownership, List<FocusReclaimCause> asked) =
          await mount(tester, canOwn: (FocusReclaimCause _) => true);

      final String result =
          await ownership.guardOverlay(() async => 'picked-file');

      expect(result, 'picked-file');
      expect(asked, <FocusReclaimCause>[FocusReclaimCause.overlayClosed]);
      await tester.pump();
      expect(ownership.node.hasFocus, isTrue);
    });

    testWidgets('returns focus even when the overlay throws',
        (WidgetTester tester) async {
      final (PageFocusOwnership ownership, List<FocusReclaimCause> asked) =
          await mount(tester, canOwn: (FocusReclaimCause _) => true);

      await expectLater(
        ownership.guardOverlay<void>(() async => throw StateError('cancelled')),
        throwsStateError,
      );

      expect(
        asked,
        <FocusReclaimCause>[FocusReclaimCause.overlayClosed],
        reason: 'a failed picker/dialog must not strand the keyboard',
      );
      await tester.pump();
      expect(ownership.node.hasFocus, isTrue);
    });

    testWidgets(
        'still consults the predicate, so it cannot steal focus '
        'from a dialog that is still up', (WidgetTester tester) async {
      final (PageFocusOwnership ownership, List<FocusReclaimCause> asked) =
          await mount(tester, canOwn: (FocusReclaimCause _) => false);

      await ownership.guardOverlay(() async => 0);

      expect(asked, <FocusReclaimCause>[FocusReclaimCause.overlayClosed]);
      await tester.pump();
      expect(ownership.node.hasFocus, isFalse);
    });
  });
}
