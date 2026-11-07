import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_popover_hover_dismiss.dart';

/// BUG-4226 续：音量 / 倍速浮层的 hover 收起必须认「按住」。
///
/// Flutter 在 PointerMoveEvent 时重做鼠标命中测试，按住拖滑条拖出浮层边界照样触发
/// 浮层 `MouseRegion.onExit`。修前收起计时只看悬停 → 180 ms 后浮层连同滑条被卸载。
void main() {
  const Duration delay = Duration(milliseconds: 180);
  const Duration afterDelay = Duration(milliseconds: 400);

  late int dismissCount;
  late VideoControlPopoverHoverDismiss gate;

  void openByHover() {
    gate.setAnchorHovered(true);
    gate.opened(kindChanged: true, pinned: false);
    // 指针从锚点挪进浮层。
    gate.setPanelHovered(true);
    gate.setAnchorHovered(false);
  }

  setUp(() {
    dismissCount = 0;
  });

  VideoControlPopoverHoverDismiss build() => VideoControlPopoverHoverDismiss(
    onDismiss: () {
      dismissCount++;
      gate.closed();
    },
    delay: delay,
  );

  test('hover-opened popover closes after pointer leaves (baseline)', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      async.elapse(afterDelay);
      expect(dismissCount, 0, reason: '指针还在浮层上，不收');
      gate.setPanelHovered(false);
      async.elapse(afterDelay);
      expect(dismissCount, 1);
    });
  });

  test('dragging out of the popover while pressed does not dismiss it', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      expect(gate.setPressed(true), isTrue);
      // 按住拖动越过浮层边界：move 事件重做命中测试 → 浮层 onExit。
      gate.setPanelHovered(false);
      async.elapse(afterDelay);
      expect(dismissCount, 0, reason: '按住拖滑条期间浮层不得被 hover 收起');
      expect(gate.hidePending, isFalse);
    });
  });

  test('releasing outside the popover schedules the hover close', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      gate.setPressed(true);
      gate.setPanelHovered(false);
      async.elapse(afterDelay);
      expect(gate.setPressed(false), isTrue);
      expect(gate.hidePending, isTrue, reason: '松手时已不在浮层 / 锚点上，按 hover 规则收');
      async.elapse(afterDelay);
      expect(dismissCount, 1);
    });
  });

  test('releasing inside the popover keeps it open', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      gate.setPressed(true);
      gate.setPanelHovered(false);
      gate.setPanelHovered(true); // 拖回浮层内再松手
      gate.setPressed(false);
      async.elapse(afterDelay);
      expect(dismissCount, 0);
    });
  });

  test('a hide scheduled just before the press is cancelled by it', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      gate.setPanelHovered(false);
      expect(gate.hidePending, isTrue);
      gate.setPressed(true);
      async.elapse(afterDelay);
      expect(dismissCount, 0);
    });
  });

  test('pinned popover never hover-closes; release does not schedule', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      gate.opened(kindChanged: true, pinned: true);
      gate.setPressed(true);
      gate.setPressed(false);
      gate.setAnchorHovered(false);
      gate.setPanelHovered(false);
      async.elapse(afterDelay);
      expect(dismissCount, 0);
      expect(gate.pinned, isTrue);
    });
  });

  test(
    're-opening the same kind upgrades hover to pinned, never downgrades',
    () {
      gate = build();
      gate.opened(kindChanged: true, pinned: false);
      expect(gate.pinned, isFalse);
      gate.opened(kindChanged: false, pinned: true);
      expect(gate.pinned, isTrue);
      gate.opened(kindChanged: false, pinned: false);
      expect(gate.pinned, isTrue);
      gate.opened(kindChanged: true, pinned: false);
      expect(gate.pinned, isFalse);
    },
  );

  test('closed() reports and clears a held press', () {
    fakeAsync((FakeAsync async) {
      gate = build();
      openByHover();
      gate.setPressed(true);
      expect(gate.closed(), isTrue);
      expect(gate.pressed, isFalse);
      expect(gate.pinned, isFalse);
      expect(gate.closed(), isFalse);
      expect(gate.setPressed(false), isFalse, reason: '已放开，重复松开不再上报');
      async.elapse(afterDelay);
      expect(dismissCount, 0);
    });
  });
}
