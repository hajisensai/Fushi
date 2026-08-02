import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// ⚠️⚠️ 假绿警告（2026-08-02 定性）：**本文件断言的前提已被引擎源码证伪。** ⚠️⚠️
///
/// 这里的用例全部**手工构造 `LogicalKeyboardKey.process` 合成事件**，而引擎在本仓
/// 5 个出包平台（Android / iOS / macOS / Windows / Linux）上**永不产生该值**：
/// - `process` 是 **Flutter Web 专有**值。裸 keyId `0x0010000070f` 在整棵 engine 树
///   只出现 3 处——web 引擎 `lib/web_ui/lib/src/engine/key_map.g.dart:237`（唯一生产用）
///   + Android / embedder 两个 **test util**；原生端生产键表全无（框架侧同理，只在
///   `keyboard_maps.g.dart` 的 `kWebToLogicalKey`:2398）。
/// - Windows 上被 IME 消费的键由嵌入层
///   `shell/platform/windows/keyboard_key_embedder_handler.cc:177-183` 在 `VK_PROCESSKEY`
///   时直接 `callback(true); return;`（注释原文 "not sent to Flutter"），keyup 也在
///   `:255-260` 被丢弃 ⇒ Dart 侧既拿不到 down 也拿不到 up。
///
/// ⇒ 下面这些用例**绿灯不代表 BUG-430 被修好**，它们只描述「纯函数被喂进一个引擎
/// 不会产生的值时会怎样」，且**永远不会因真机失效而转红**（BUG-430 至今真机未验，
/// 同族 BUG-936 更是被用户真机证实无效）。**不要把它们当成回归保护。**
///
/// 保留原因：钉的是框架侧纯函数的分支行为，将来真定位到根因时可能还要复用。
/// 事实守卫见 `test/shortcuts/ime_process_key_reachability_guard_test.dart`（BUG-1432）；
/// 定性见 `docs/bugs/BUG-430-win-ime-shortcut-fallback.md` 的「根因证伪」栏。
///
/// 以下为原始说明（存档）：TODO-847: Windows 微软 IME 激活时，Flutter 引擎把
/// KeyDownEvent 的 logicalKey 改写成 LogicalKeyboardKey.process，导致 resolveKeyboard
/// 的精确相等永远失败、全表面快捷键失效。这些用例合成 IME 改写后的
/// (process, physicalKey) 组合，断言 resolveKeyboard 在传入 physicalKey 时按物理键
/// 回退，且回退严格门控。
void main() {
  // 注：本 group 内 'normal path unchanged: real pageDown still resolves' 一条是不含
  // process 的对照用例，仍是有效断言；其余 6 条均依赖已证伪的前提。
  group('[假绿·前提已证伪] resolveKeyboard IME physicalKey fallback (TODO-847)', () {
    late HibikiShortcutRegistry registry;

    setUp(() {
      registry = HibikiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
    });

    test('fallback resolves reader PageDown when logicalKey is process', () {
      // 修前：process 不等于任何 binding 的 logicalKey → null（红）。
      // 修后：physicalKey=pageDown 命中 readerPageForward（绿）。
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.process,
        modifiers: const {},
        scope: ShortcutScope.reader,
        physicalKey: PhysicalKeyboardKey.pageDown,
      );
      expect(result, ShortcutAction.readerPageForward);
    });

    test('no fallback when physicalKey is null (still process)', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.process,
        modifiers: const {},
        scope: ShortcutScope.reader,
        physicalKey: null,
      );
      expect(result, isNull);
    });

    test('does NOT use fallback when key != process even if physicalKey given',
        () {
      // 合取条件：physicalKey 单独不触发回退；只有 logicalKey==process 才启用。
      // 这里 logicalKey 是真实的 escape（不绑 readerPageForward），即便顺手传了
      // pageDown 物理键，也绝不能错误命中 readerPageForward。
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.escape,
        modifiers: const {},
        scope: ShortcutScope.reader,
        physicalKey: PhysicalKeyboardKey.pageDown,
      );
      expect(result, isNot(ShortcutAction.readerPageForward));
    });

    test('fallback respects modifiers exactly (Ctrl+Digit1 → homeTabBooks)',
        () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.process,
        modifiers: const {ModifierKey.ctrl},
        scope: ShortcutScope.home,
        physicalKey: PhysicalKeyboardKey.digit1,
      );
      expect(result, ShortcutAction.homeTabBooks);
    });

    test('fallback misses when modifiers differ from the binding', () {
      // Ctrl+Digit1 绑 homeTabBooks；裸 Digit1（无 Ctrl）不应命中。
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.process,
        modifiers: const {},
        scope: ShortcutScope.home,
        physicalKey: PhysicalKeyboardKey.digit1,
      );
      expect(result, isNot(ShortcutAction.homeTabBooks));
    });

    test('normal path unchanged: real pageDown still resolves', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.pageDown,
        modifiers: const {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerPageForward);
    });

    test('fallback scoped: process+pageDown does not leak across scope', () {
      // readerPageForward 在 reader scope；home scope 下物理回退也不应误命中它。
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.process,
        modifiers: const {},
        scope: ShortcutScope.home,
        physicalKey: PhysicalKeyboardKey.pageDown,
      );
      expect(result, isNot(ShortcutAction.readerPageForward));
    });
  });
}
