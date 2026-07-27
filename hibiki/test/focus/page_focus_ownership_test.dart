import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/page_focus_ownership.dart';

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
