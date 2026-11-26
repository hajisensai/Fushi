import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerDownEvent,
        PointerEvent,
        PointerMoveEvent,
        PointerUpEvent,
        kBackMouseButton,
        kForwardMouseButton,
        kPrimaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 鼠标键按住连发（[dispatchClaimedMouseAction] 的 `onHeldRepeat`）。
///
/// 起因：用户用 Logi Options+ 把侧键映射成键盘快捷键（`,` / `.` 逐帧），按住没有连发
/// ——映射软件按下瞬间就发完「按下 + 松开」，OS 自动重复无从产生。改为直接绑鼠标键后，
/// 连发由 Fushi 在拿得到松开沿的这一层补上。
void main() {
  int nextPointer = 100;
  late int pointer;

  setUp(() {
    MouseBindingDispatch.resetForTest();
    pointer = nextPointer++;
  });
  tearDown(MouseBindingDispatch.resetForTest);

  PointerDownEvent down(int buttons) => PointerDownEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );

  void route(PointerEvent event) =>
      GestureBinding.instance.pointerRouter.route(event);

  testWidgets('no onHeldRepeat: one press, one execution', (
    WidgetTester tester,
  ) async {
    int runs = 0;
    dispatchClaimedMouseAction(down(kBackMouseButton), () {
      runs++;
      return true;
    });
    await tester.pump(const Duration(seconds: 2));
    expect(runs, 1);
    expect(MouseHoldRepeater.isActive, isFalse);
  });

  testWidgets(
    'repeats after the keyboard-like delay at the repeat interval, stops on up',
    (WidgetTester tester) async {
      int presses = 0;
      int repeats = 0;
      dispatchClaimedMouseAction(
        down(kBackMouseButton),
        () {
          presses++;
          return true;
        },
        onHeldRepeat: () {
          repeats++;
          return true;
        },
      );
      expect(presses, 1);
      await tester.pump(
        kMouseHoldRepeatDelay - const Duration(milliseconds: 1),
      );
      expect(repeats, 0, reason: 'no repeat inside the initial delay');
      await tester.pump(const Duration(milliseconds: 1));
      expect(repeats, 1);
      await tester.pump(kMouseHoldRepeatInterval * 3);
      expect(repeats, 4);

      route(PointerUpEvent(pointer: pointer, kind: PointerDeviceKind.mouse));
      await tester.pump(const Duration(seconds: 2));
      expect(repeats, 4, reason: 'release stops the repeat');
      expect(MouseHoldRepeater.isActive, isFalse);
    },
  );

  testWidgets('releasing the held button while another stays down stops it', (
    WidgetTester tester,
  ) async {
    int repeats = 0;
    dispatchClaimedMouseAction(
      down(kForwardMouseButton | kPrimaryMouseButton),
      () => true,
      onHeldRepeat: () {
        repeats++;
        return true;
      },
    );
    await tester.pump(kMouseHoldRepeatDelay);
    expect(repeats, 1);
    // 别的指针的事件不影响。
    route(PointerUpEvent(pointer: pointer + 1000));
    await tester.pump(kMouseHoldRepeatInterval);
    expect(repeats, 2);
    // 左键还按着、前进键松开：同一 pointer 的 move，buttons 里那一位清零。
    route(
      PointerMoveEvent(
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(repeats, 2);
  });

  testWidgets('onHeldRepeat returning false ends the repeat', (
    WidgetTester tester,
  ) async {
    int repeats = 0;
    dispatchClaimedMouseAction(
      down(kBackMouseButton),
      () => true,
      onHeldRepeat: () {
        repeats++;
        return false;
      },
    );
    await tester.pump(kMouseHoldRepeatDelay);
    await tester.pump(const Duration(seconds: 1));
    expect(repeats, 1);
    expect(MouseHoldRepeater.isActive, isFalse);
  });

  testWidgets('an unclaimed press never starts repeating', (
    WidgetTester tester,
  ) async {
    int repeats = 0;
    dispatchClaimedMouseAction(
      down(kBackMouseButton),
      () => false,
      onHeldRepeat: () {
        repeats++;
        return true;
      },
    );
    await tester.pump(const Duration(seconds: 2));
    expect(repeats, 0);
  });

  testWidgets('an inner layer that claimed the press owns the repeat', (
    WidgetTester tester,
  ) async {
    final PointerDownEvent event = down(kBackMouseButton);
    int inner = 0;
    int outer = 0;
    dispatchClaimedMouseAction(
      event,
      () => true,
      onHeldRepeat: () {
        inner++;
        return true;
      },
    );
    dispatchClaimedMouseAction(
      event,
      () => true,
      onHeldRepeat: () {
        outer++;
        return true;
      },
    );
    await tester.pump(kMouseHoldRepeatDelay + kMouseHoldRepeatInterval);
    expect(inner, 2);
    expect(outer, 0);
    route(PointerUpEvent(pointer: pointer, kind: PointerDeviceKind.mouse));
    expect(MouseHoldRepeater.isActive, isFalse);
  });

  test('only stepping actions repeat while a mouse button is held', () {
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.videoPreviousFrame,
      ShortcutAction.videoNextFrame,
      ShortcutAction.videoSeekForward,
      ShortcutAction.videoVolumeDown,
      ShortcutAction.readerPageForward,
      ShortcutAction.audiobookNextSentence,
      ShortcutAction.globalScrollLineDown,
    ]) {
      expect(mouseBindingRepeatsWhileHeld(action), isTrue, reason: '$action');
    }
    for (final ShortcutAction action in <ShortcutAction>[
      ShortcutAction.globalBack,
      ShortcutAction.globalToggleFullscreen,
      ShortcutAction.videoTogglePlayPause,
      ShortcutAction.videoHoldSpeed,
      ShortcutAction.videoToggleFullscreen,
      ShortcutAction.videoDismissDict,
      ShortcutAction.popupMineEntry,
      ShortcutAction.readerToggleFurigana,
      ShortcutAction.globalScrollToTop,
    ]) {
      expect(mouseBindingRepeatsWhileHeld(action), isFalse, reason: '$action');
    }
  });
}
