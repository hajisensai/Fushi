import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';

/// BUG-1419：WebView2 鼠标键状态粘滞。
///
/// WebView2 侧的 `VirtualKeyState`（windows/in_app_webview/in_app_webview.h）是纯
/// 增量位集：只有 `setPointerButton` 的 down/up 会翻转它，没有任何自愈。旧实现把
/// `ev.buttons`（位掩码）用 `_getButton` 映射成**单个** `PointerButton` 存进
/// `_downButtons[ev.pointer]`，多键并按时掩码是复合值（左|右 = 3）→ 落进 default →
/// `none`，覆盖掉已记的按钮 → 抬起时发不出 button-up → `MK_*` 位永久卡死。之后每个
/// MOVE 都带着「某键仍按住」进 Blink，鼠标一动就把正文刷成原生蓝色选区，click 不
/// 成立、查词 tap 链永久失效。
///
/// [diffMouseButtonMasks] 是修复后的真值来源：逐位补差，保证 down/up 严格配对。
void main() {
  group('diffMouseButtonMasks', () {
    test('掩码未变时不产生任何下发', () {
      expect(diffMouseButtonMasks(0, 0), isEmpty);
      expect(diffMouseButtonMasks(kPrimaryMouseButton, kPrimaryMouseButton),
          isEmpty,
          reason: '按住不动的每一个 move 都重发 down 会污染 Blink 的拖拽判定');
    });

    test('单键按下与抬起各产生一次配对翻转', () {
      final down = diffMouseButtonMasks(0, kPrimaryMouseButton);
      expect(down, hasLength(1));
      expect(down.single.button, PointerButton.primary);
      expect(down.single.isDown, isTrue);

      final up = diffMouseButtonMasks(kPrimaryMouseButton, 0);
      expect(up, hasLength(1));
      expect(up.single.button, PointerButton.primary);
      expect(up.single.isDown, isFalse);
    });

    test('右键同样成对，不会被当成 none 丢掉', () {
      final down = diffMouseButtonMasks(0, kSecondaryMouseButton);
      expect(down.single.button, PointerButton.secondary);
      expect(down.single.isDown, isTrue);
      final up = diffMouseButtonMasks(kSecondaryMouseButton, 0);
      expect(up.single.button, PointerButton.secondary);
      expect(up.single.isDown, isFalse);
    });

    test('BUG-1419 根因：多键并按不再退化成 none，两个键各自成对', () {
      // 左键按住时再按右键：ev.buttons = 3。旧实现 _getButton(3) → none，
      // 覆盖掉已记的 primary，之后无论怎么抬手都发不出 primary 的 up。
      const int both = kPrimaryMouseButton | kSecondaryMouseButton;
      final add = diffMouseButtonMasks(kPrimaryMouseButton, both);
      expect(add, hasLength(1), reason: '只有新增的右键需要下发，左键不重发');
      expect(add.single.button, PointerButton.secondary);
      expect(add.single.isDown, isTrue);

      // 先松右键：只清右键，左键仍按住。
      final releaseRight = diffMouseButtonMasks(both, kPrimaryMouseButton);
      expect(releaseRight, hasLength(1));
      expect(releaseRight.single.button, PointerButton.secondary);
      expect(releaseRight.single.isDown, isFalse);

      // 从两键直接回到 0（例如指针在 WebView 外抬起后收到 hover）：两个键都补 up。
      final releaseBoth = diffMouseButtonMasks(both, 0);
      expect(releaseBoth, hasLength(2));
      expect(releaseBoth.every((t) => !t.isDown), isTrue);
      expect(
        releaseBoth.map((t) => t.button).toSet(),
        <PointerButton>{PointerButton.primary, PointerButton.secondary},
      );
    });

    test('掩码为 0 的事件（hover）能自愈任何残留位', () {
      // hover 的语义就是「没有任何键按下」，是漏掉的 up 唯一可靠的补发点。
      const int stuck =
          kPrimaryMouseButton | kSecondaryMouseButton | kTertiaryButton;
      final healed = diffMouseButtonMasks(stuck, 0);
      expect(healed, hasLength(3), reason: '三个卡住的键都要补 up');
      expect(healed.every((t) => !t.isDown), isTrue);
    });

    test('中键与其它键互不干扰', () {
      final t = diffMouseButtonMasks(
          kPrimaryMouseButton, kPrimaryMouseButton | kTertiaryButton);
      expect(t, hasLength(1));
      expect(t.single.button, PointerButton.tertiary);
      expect(t.single.isDown, isTrue);
    });

    test('掩码表只覆盖三个真实鼠标键，顺序稳定', () {
      expect(kMouseButtonMasks, <int>[
        kPrimaryMouseButton,
        kSecondaryMouseButton,
        kTertiaryButton,
      ]);
    });
  });
}
