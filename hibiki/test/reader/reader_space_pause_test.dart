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
          boundAction: ShortcutAction.readerPageForward,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
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
            boundAction: ShortcutAction.readerPageForward,
          ),
          isNull,
        );
        expect(
          resolveReaderArrowPageTurn(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            rtl: rtl,
            boundAction: ShortcutAction.readerPageForward,
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
            boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
          reverse: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
          reverse: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
          reverse: false,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
          reverse: true,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
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
              boundAction: ShortcutAction.readerPageForward,
            ),
            resolveReaderArrowPageTurn(
              key: key,
              modifiers: const <ModifierKey>{},
              rtl: rtl,
              boundAction: ShortcutAction.readerPageForward,
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
          boundAction: ShortcutAction.readerPageForward,
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
            boundAction: ShortcutAction.readerPageForward,
            reverse: true,
          ),
          isNull,
        );
      }
    });
  });
  group('TODO-847 IME 改写 logicalKey=process 时的物理键回退', () {
    test('Space override: process + physical Space → 播放/暂停', () {
      // 修前：key=process != space → null（红）。修后：physical Space 命中（绿）。
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
          physicalKey: PhysicalKeyboardKey.space,
        ),
        ShortcutAction.audiobookPlayPause,
      );
    });

    test('Space override: process 但 physicalKey null → 不覆写', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
          physicalKey: null,
        ),
        isNull,
      );
    });

    test('Space override: process + 非 Space 物理键 → 不覆写', () {
      expect(
        resolveReaderSpaceOverride(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          hasActiveAudiobook: true,
          physicalKey: PhysicalKeyboardKey.keyA,
        ),
        isNull,
      );
    });

    test('Arrow override: RTL + process + physical Left → 前进（方向不反转）', () {
      // 修前：key=process 落空 → 注册表 Right=前进 写死，RTL 方向反转（红行为）。
      // 修后：physical Left 还原 RTL 前进语义（绿）。
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
          physicalKey: PhysicalKeyboardKey.arrowLeft,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
          physicalKey: PhysicalKeyboardKey.arrowRight,
        ),
        ShortcutAction.readerPageBackward,
      );
    });

    test('Arrow override: LTR + process + physical Right → 前进', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: ShortcutAction.readerPageForward,
          physicalKey: PhysicalKeyboardKey.arrowRight,
        ),
        ShortcutAction.readerPageForward,
      );
    });

    test('Arrow override: process 但 physicalKey null → 不覆写', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
          physicalKey: null,
        ),
        isNull,
      );
    });

    test('Arrow override: 带修饰时即便 process+physical 也不覆写', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          rtl: true,
          boundAction: ShortcutAction.readerPageForward,
          physicalKey: PhysicalKeyboardKey.arrowLeft,
        ),
        isNull,
      );
    });
  });
  group('resolveReaderArrowPageTurn (TODO-992 改键后让出，尊重用户绑定)', () {
    test('用户把裸左/右键改绑成有声书上/下句 → 覆写让出(null)，两模式都不再翻页', () {
      // boundAction 是该裸键在 reader+audiobook co-active 组解析出的真实绑定。
      // 用户从翻页解绑、改绑有声书句子后，覆写必须让出，交回注册表执行真实绑定。
      for (final bool rtl in <bool>[true, false]) {
        for (final bool reverse in <bool>[true, false]) {
          expect(
            resolveReaderArrowPageTurn(
              key: LogicalKeyboardKey.arrowRight,
              modifiers: const <ModifierKey>{},
              rtl: rtl,
              boundAction: ShortcutAction.audiobookNextSentence,
              reverse: reverse,
            ),
            isNull,
            reason: 'rtl=$rtl reverse=$reverse 右键改绑有声书下句应让出',
          );
          expect(
            resolveReaderArrowPageTurn(
              key: LogicalKeyboardKey.arrowLeft,
              modifiers: const <ModifierKey>{},
              rtl: rtl,
              boundAction: ShortcutAction.audiobookPrevSentence,
              reverse: reverse,
            ),
            isNull,
            reason: 'rtl=$rtl reverse=$reverse 左键改绑有声书上句应让出',
          );
        }
      }
    });

    test('裸左/右键被显式解绑(boundAction=null) → 覆写让出(null)', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: null,
        ),
        isNull,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: null,
        ),
        isNull,
      );
    });

    test('仍绑定翻页(默认) → 覆写照常做阅读方向校正', () {
      // 默认用户行为不变（Never break userspace）：boundAction 仍是翻页动作时，
      // 覆写按阅读方向重定向，与改键前完全一致。
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowRight,
          modifiers: const <ModifierKey>{},
          rtl: false,
          boundAction: ShortcutAction.readerPageForward,
        ),
        ShortcutAction.readerPageForward,
      );
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.arrowLeft,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.readerPageBackward,
        ),
        ShortcutAction.readerPageForward,
      );
    });

    test('IME process + 物理键但已改绑非翻页 → 仍让出(null)', () {
      expect(
        resolveReaderArrowPageTurn(
          key: LogicalKeyboardKey.process,
          modifiers: const <ModifierKey>{},
          rtl: true,
          boundAction: ShortcutAction.audiobookNextSentence,
          physicalKey: PhysicalKeyboardKey.arrowRight,
        ),
        isNull,
      );
    });
  });
}
