import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';

void main() {
  group('readerShouldHandleDesktopCopy (BUG-402)', () {
    test('Windows + 纯 Ctrl+C → 接管复制', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyC,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          isWindows: true,
        ),
        isTrue,
      );
    });

    test('非 Windows（移动/mac 原生 copy 本就 work）→ 不接管', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyC,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          isWindows: false,
        ),
        isFalse,
      );
    });

    test('Windows 但只按 C（无 Ctrl）→ 不接管', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyC,
          modifiers: const <ModifierKey>{},
          isWindows: true,
        ),
        isFalse,
      );
    });

    test('Windows + Ctrl+Shift+C（多修饰）→ 不接管', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyC,
          modifiers: const <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift},
          isWindows: true,
        ),
        isFalse,
      );
    });

    test('Windows + Ctrl+其它键（非 C）→ 不接管', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyV,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          isWindows: true,
        ),
        isFalse,
      );
    });

    test('Windows + Meta+C（mac 风格，非 Ctrl）→ 不接管', () {
      expect(
        readerShouldHandleDesktopCopy(
          key: LogicalKeyboardKey.keyC,
          modifiers: const <ModifierKey>{ModifierKey.meta},
          isWindows: true,
        ),
        isFalse,
      );
    });
  });
}
