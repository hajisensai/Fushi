import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// TODO-847: Windows 微软 IME 激活时，Flutter 引擎把 KeyDownEvent 的 logicalKey
/// 改写成 LogicalKeyboardKey.process，导致 resolveKeyboard 的精确相等永远失败、
/// 全表面快捷键失效。这些用例合成 IME 改写后的 (process, physicalKey) 组合，断言
/// resolveKeyboard 在传入 physicalKey 时按物理键回退，且回退严格门控。
void main() {
  group('resolveKeyboard IME physicalKey fallback (TODO-847)', () {
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
