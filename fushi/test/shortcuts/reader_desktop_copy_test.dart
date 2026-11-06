import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart';

/// 桌面复制手势谓词真值表（BUG-402 Windows Ctrl+C / macOS ⌘C）。
///
/// [platform] 只取三种：`win` / `mac` / `other`（Linux 与移动端都不接管）。
bool _hit(
  LogicalKeyboardKey key,
  Set<ModifierKey> modifiers, {
  required String platform,
}) => desktopShouldHandleCopyGesture(
  key: key,
  modifiers: modifiers,
  isWindows: platform == 'win',
  isMacOS: platform == 'mac',
);

void main() {
  group('desktopShouldHandleCopyGesture · Windows (BUG-402)', () {
    test('Windows + 纯 Ctrl+C → 接管复制', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'win'),
        isTrue,
      );
    });

    test('Windows 但只按 C（无 Ctrl）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{}, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Ctrl+Shift+C（多修饰）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
          ModifierKey.shift,
        }, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Ctrl+其它键（非 C）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyV, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'win'),
        isFalse,
      );
    });

    test('Windows + Meta+C（mac 风格，非 Ctrl）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'win'),
        isFalse,
      );
    });
  });

  group('desktopShouldHandleCopyGesture · macOS ⌘C', () {
    test('macOS + 纯 Meta+C（⌘C）→ 接管复制', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'mac'),
        isTrue,
      );
    });

    test('macOS + Ctrl+C（不是 Mac 的复制键）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
        }, platform: 'mac'),
        isFalse,
      );
    });

    test('macOS + Meta+Shift+C / Meta+Alt+C（多修饰）→ 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
          ModifierKey.shift,
        }, platform: 'mac'),
        isFalse,
      );
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.meta,
          ModifierKey.alt,
        }, platform: 'mac'),
        isFalse,
      );
    });

    test('macOS + 裸 C / Meta+其它键 → 不接管', () {
      expect(
        _hit(LogicalKeyboardKey.keyC, <ModifierKey>{}, platform: 'mac'),
        isFalse,
      );
      expect(
        _hit(LogicalKeyboardKey.keyV, <ModifierKey>{
          ModifierKey.meta,
        }, platform: 'mac'),
        isFalse,
      );
    });
  });

  group('desktopShouldHandleCopyGesture · 其它平台', () {
    test('Linux / 移动端：Ctrl+C 与 Meta+C 一律不接管', () {
      for (final ModifierKey mod in <ModifierKey>[
        ModifierKey.ctrl,
        ModifierKey.meta,
      ]) {
        expect(
          _hit(LogicalKeyboardKey.keyC, <ModifierKey>{mod}, platform: 'other'),
          isFalse,
          reason: '$mod+C 在非 Windows / macOS 平台不得接管',
        );
      }
    });
  });
}
