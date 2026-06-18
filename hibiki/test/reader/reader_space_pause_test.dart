import 'dart:ui' as ui;

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

void main() {
  KeyDownEvent keyDown(
    LogicalKeyboardKey key,
    ui.KeyEventDeviceType deviceType,
  ) =>
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: key,
        timeStamp: Duration.zero,
        deviceType: deviceType,
      );

  group('resolveReaderSpaceOverride', () {
    test('有声书激活 + 无修饰 Space → 播放/暂停', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        ShortcutAction.audiobookPlayPause,
      );
    });

    test('无有声书 + 无修饰 Space → 不覆写(走默认翻页)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: false,
        ),
        isNull,
      );
    });

    test('有声书激活 + Shift+Space → 不覆写(仍后退翻页)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{ModifierKey.shift},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });

    test('有声书激活 + Ctrl+Space → 不覆写(保留 Ctrl+Space 原义)', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.space,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });

    test('非 Space 键 → 不覆写', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
        ),
        isNull,
      );
    });
  });

  group('resolveReaderArrowPageTurn (BUG-099 翻页方向键跟随阅读方向)', () {
    test('LTR(横排) 右箭头 → 前进 / 左箭头 → 后退', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('RTL(竖排) 左箭头 → 前进 / 右箭头 → 后退（下一页在左）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('带修饰键(Ctrl+方向键=有声书句子导航) → 不覆写', () {
      for (final bool rtl in <bool>[true, false]) {
        expect(
          resolveReaderArrowPageTurn(
            key: LogicalKeyboardKey.arrowRight,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            rtl: rtl,
          ),
          isNull,
        );
        expect(
          resolveReaderArrowPageTurn(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            rtl: rtl,
          ),
          isNull,
        );
      }
    });

    test('上/下箭头与其它键 → 不覆写(交回默认解析)', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        expect(
          resolveReaderArrowPageTurn(
            key: key,
            modifiers: const <ModifierKey>{},
            rtl: true,
          ),
          isNull,
        );
      }
    });
  });

  group('resolveReaderArrowPageTurn (TODO-120 反转键盘方向键翻页方向开关)', () {
    test('开关关(reverse:false) → 保持现有方向（LTR 右进/左退）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
          reverse: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
          reverse: false,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('开关开(reverse:true) → 反转（LTR：左进/右退）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
          reverse: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
          reverse: true,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('开关关(reverse:false) → RTL 保持现有方向（左进/右退）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
          reverse: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
          reverse: false,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('开关开(reverse:true) → RTL 也整体反转（右进/左退）', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
          reverse: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
          reverse: true,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('reverse 默认值为 false（不传与传 false 等价）', () {
      for (final bool rtl in <bool>[true, false]) {
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          expect(
            resolveReaderArrowPageTurn(
              key: key,
              modifiers: const <ModifierKey>{},
              rtl: rtl,
            ),
            resolveReaderArrowPageTurn(
              key: key,
              modifiers: const <ModifierKey>{},
              rtl: rtl,
              reverse: false,
            ),
          );
        }
      }
    });

    test('带修饰键时 reverse 也不覆写(交回默认)', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          rtl: false,
          reverse: true,
        ),
        isNull,
      );
    });

    test('reverse 只服务键盘裸左右键，D-pad/gamepad 先识别为手柄', () {
      expect(
        GamepadButton.fromKeyEvent(
          keyDown(LogicalKeyboardKey.arrowLeft, ui.KeyEventDeviceType.keyboard),
        ),
        isNull,
      );
      expect(
        GamepadButton.fromKeyEvent(
          keyDown(
            LogicalKeyboardKey.arrowLeft,
            ui.KeyEventDeviceType.directionalPad,
          ),
        ),
        GamepadButton.dpadLeft,
      );
      expect(
        GamepadButton.fromKeyEvent(
          keyDown(LogicalKeyboardKey.arrowRight, ui.KeyEventDeviceType.gamepad),
        ),
        GamepadButton.dpadRight,
      );
      expect(
        GamepadButton.fromKeyEvent(
          keyDown(
            LogicalKeyboardKey.arrowRight,
            ui.KeyEventDeviceType.joystick,
          ),
        ),
        GamepadButton.dpadRight,
      );
    });

    test('PageUp/PageDown/Space/字母键不受 reverse arrow helper 影响', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyA,
      ]) {
        expect(
          resolveReaderArrowPageTurn(
            key: key,
            modifiers: const <ModifierKey>{},
            rtl: false,
            reverse: true,
          ),
          isNull,
        );
      }
    });
  });
}
