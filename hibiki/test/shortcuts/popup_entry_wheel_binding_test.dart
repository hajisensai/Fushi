import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 查词弹窗「上/下一个词条」（Yomitan 式 Alt+滚轮）的绑定通道守卫。
///
/// 这条链路横跨三段，任何一段改名都会让功能静默失效（用户侧表现是「滚轮跳词条
/// 没反应」，且没有任何报错）：
///   注册表 wheelBindings → popup_settings_injection 注入 window.__fushiEntryWheelBindings
///   → popup.js 的 wheel 监听 → fushiFocusDictionaryEntryMove。
/// 故除了数据层往返，这里还钉住 Dart 注入的全局名与 popup.js 读取的全局名一致。
void main() {
  group('WheelBinding 序列化往返', () {
    test('修饰键 + 方向按固定顺序序列化，且能反序列化回等值对象', () {
      const WheelBinding binding = WheelBinding(
        WheelDirection.down,
        modifiers: <ModifierKey>{ModifierKey.alt},
      );
      expect(binding.serialize(), 'Alt+WheelDown');
      expect(WheelBinding.deserialize('Alt+WheelDown'), binding);
    });

    test('多修饰键按 ModifierKey 声明序排列（与 InputBinding 同规则）', () {
      const WheelBinding binding = WheelBinding(
        WheelDirection.up,
        modifiers: <ModifierKey>{ModifierKey.shift, ModifierKey.ctrl},
      );
      expect(binding.serialize(), 'Ctrl+Shift+WheelUp');
      expect(WheelBinding.deserialize(binding.serialize()), binding);
    });

    test('裸方向（无修饰键）也能往返；等值只看方向 + 修饰键集合', () {
      expect(
        WheelBinding.deserialize('WheelUp'),
        const WheelBinding(WheelDirection.up),
      );
      expect(
        const WheelBinding(WheelDirection.up,
            modifiers: <ModifierKey>{ModifierKey.alt}),
        isNot(const WheelBinding(WheelDirection.down,
            modifiers: <ModifierKey>{ModifierKey.alt})),
      );
    });

    test('无法识别的 token 返回 null（坏快照不炸，退化成没有该绑定）', () {
      expect(WheelBinding.deserialize(''), isNull);
      expect(WheelBinding.deserialize('Alt+MouseMiddle'), isNull);
    });
  });

  group('ShortcutBindingSet 的 wheel 通道向后兼容', () {
    test('toJson/fromJson 往返保留滚轮绑定', () {
      const ShortcutBindingSet set = ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyA),
        ],
        wheelBindings: <WheelBinding>[
          WheelBinding(WheelDirection.down,
              modifiers: <ModifierKey>{ModifierKey.alt}),
        ],
      );
      final ShortcutBindingSet round = ShortcutBindingSet.fromJson(
        jsonDecode(jsonEncode(set.toJson())) as Map<String, dynamic>,
      );
      expect(round.wheelBindings, set.wheelBindings);
      expect(round.keyboardBindings, set.keyboardBindings);
    });

    test('老快照没有 wheel key 时得到空表，其它通道原样保留', () {
      final ShortcutBindingSet set = ShortcutBindingSet.fromJson(
        const <String, dynamic>{
          'keyboard': <String>['Ctrl+KeyW'],
          'gamepad': <String>['B'],
          'mouse': <String>['MouseMiddle'],
        },
      );
      expect(set.wheelBindings, isEmpty);
      expect(
          set.keyboardBindings.single,
          const InputBinding(
              key: LogicalKeyboardKey.keyW,
              modifiers: <ModifierKey>{ModifierKey.ctrl}));
      expect(set.gamepadBindings.single, const GamepadBinding(GamepadButton.b));
      expect(set.mouseBindings.single, const MouseBinding(1));
    });
  });

  group('默认绑定', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      test('$platform 默认 Alt+滚轮下/上 = 下/上一个词条', () {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        expect(
          defaults[ShortcutAction.popupNextEntry]!.wheelBindings,
          const <WheelBinding>[
            WheelBinding(WheelDirection.down,
                modifiers: <ModifierKey>{ModifierKey.alt}),
          ],
        );
        expect(
          defaults[ShortcutAction.popupPrevEntry]!.wheelBindings,
          const <WheelBinding>[
            WheelBinding(WheelDirection.up,
                modifiers: <ModifierKey>{ModifierKey.alt}),
          ],
        );
      });
    }

    test('macOS 不把 Alt 换成 Meta（Ctrl→Meta 只作用于键盘通道）', () {
      final Map<ShortcutAction, ShortcutBindingSet> mac =
          ShortcutDefaults.forPlatform(TargetPlatform.macOS);
      expect(
        mac[ShortcutAction.popupNextEntry]!.wheelBindings.single.modifiers,
        <ModifierKey>{ModifierKey.alt},
      );
    });

    test('dictionaryPopup 是独立 co-active 组，开滚轮 + 键盘两个通道', () {
      expect(ShortcutScope.dictionaryPopup.coactiveScopes,
          <ShortcutScope>[ShortcutScope.dictionaryPopup]);
      // 契约变更（制卡快捷键）：本 scope 早先只开滚轮，因为唯一的动作是词条导航。加入
      // popupMineEntry（= 点弹窗里的「＋」）后键盘通道有了真实消费者——
      // popup_settings_injection 把 `bindingsFor(popupMineEntry).keyboardBindings`
      // 序列化注入给 popup.js（app 外裸 WebView2 表面），视频页另按同一绑定在 Dart 侧派发。
      // 故这里从「只开滚轮」放宽成两通道；但**不是**放开成三通道：手柄/鼠标仍无解析入口。
      expect(
        ShortcutScope.dictionaryPopup.channels,
        <ShortcutChannel>{ShortcutChannel.wheel, ShortcutChannel.keyboard},
      );
      expect(ShortcutScope.dictionaryPopup.channels,
          isNot(contains(ShortcutChannel.gamepad)));
      expect(ShortcutScope.dictionaryPopup.channels,
          isNot(contains(ShortcutChannel.mouse)));
      // 其它 scope 保持键盘/手柄/鼠标三通道（不因新通道枚举而改变既有行为）。
      expect(ShortcutScope.reader.channels.contains(ShortcutChannel.keyboard),
          isTrue);
      expect(ShortcutScope.reader.channels.contains(ShortcutChannel.wheel),
          isFalse);
    });
  });

  group('冲突检测', () {
    test('同一 scope 内同一「修饰键 + 方向」只能属于一个动作', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      const WheelBinding altDown = WheelBinding(
        WheelDirection.down,
        modifiers: <ModifierKey>{ModifierKey.alt},
      );
      expect(
        registry.hasWheelConflict(ShortcutScope.dictionaryPopup, altDown,
            exclude: ShortcutAction.popupPrevEntry),
        ShortcutAction.popupNextEntry,
      );
      // 排除自己时不算冲突（编辑自己的绑定不该报冲突）。
      expect(
        registry.hasWheelConflict(ShortcutScope.dictionaryPopup, altDown,
            exclude: ShortcutAction.popupNextEntry),
        isNull,
      );
      // 未被占用的组合无冲突。
      expect(
        registry.hasWheelConflict(
          ShortcutScope.dictionaryPopup,
          const WheelBinding(WheelDirection.down,
              modifiers: <ModifierKey>{ModifierKey.shift}),
          exclude: null,
        ),
        isNull,
      );
    });

    test('重分配会把绑定从旧动作上摘掉（与键盘/手柄/鼠标同形）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      const WheelBinding altDown = WheelBinding(
        WheelDirection.down,
        modifiers: <ModifierKey>{ModifierKey.alt},
      );
      registry.updateBindingWithReassignments(
        ShortcutAction.popupPrevEntry,
        ShortcutBindingSet(
          wheelBindings: <WheelBinding>[
            ...registry
                .bindingsFor(ShortcutAction.popupPrevEntry)
                .wheelBindings,
            altDown,
          ],
        ),
        removeWheelConflicts: const <WheelBinding>[altDown],
      );
      expect(
        registry.bindingsFor(ShortcutAction.popupNextEntry).wheelBindings,
        isEmpty,
      );
      expect(
        registry.bindingsFor(ShortcutAction.popupPrevEntry).wheelBindings,
        contains(altDown),
      );
    });
  });

  group('注入 → popup.js 契约', () {
    test('popupEntryWheelBindingsJson 输出 popup.js 能直接比对的形状', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final Map<String, dynamic> decoded = jsonDecode(
              popupEntryWheelBindingsJson(registry, TargetPlatform.windows))
          as Map<String, dynamic>;
      expect(decoded['next'], <Map<String, Object>>[
        <String, Object>{
          'dir': 'down',
          'mods': <String>['alt'],
        },
      ]);
      expect(decoded['prev'], <Map<String, Object>>[
        <String, Object>{
          'dir': 'up',
          'mods': <String>['alt'],
        },
      ]);
    });

    test('用户清空绑定 → 发空表（popup.js 据此关掉该方向，而不是回落默认）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(
            ShortcutAction.popupNextEntry, const ShortcutBindingSet());
      final Map<String, dynamic> decoded = jsonDecode(
              popupEntryWheelBindingsJson(registry, TargetPlatform.windows))
          as Map<String, dynamic>;
      expect(decoded['next'], isEmpty);
      expect(decoded['prev'], isNotEmpty);
    });

    test('注册表尚未装载时回落平台默认，绝不误发空表', () {
      // 弹窗进程（Android :popup）的精简初始化早于 loadShortcutRegistry；此时每个
      // action 都读到空绑定，与「用户清空」在数据上同形。若直接下发空表，popup.js
      // 会认为用户关掉了这个功能 → Alt+滚轮在独立弹窗窗口里静默失效。
      final Map<String, dynamic> decoded = jsonDecode(
              popupEntryWheelBindingsJson(
                  FushiShortcutRegistry(), TargetPlatform.windows))
          as Map<String, dynamic>;
      expect(decoded['next'], isNotEmpty);
      expect(decoded['prev'], isNotEmpty);
      expect(FushiShortcutRegistry().isLoaded, isFalse);
      expect(
        (FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows))
            .isLoaded,
        isTrue,
      );
    });

    test('弹窗进程的初始化会加载用户的快捷键绑定（否则改键在该进程不生效）', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final int popupInit = appModel.indexOf('initialiseForDictionaryPopup');
      expect(popupInit, greaterThan(0));
      final String popupInitBody = appModel.substring(
        popupInit,
        appModel.indexOf('Future<void> refreshPrefCache()', popupInit),
      );
      expect(popupInitBody.contains('loadShortcutRegistry'), isTrue,
          reason: '弹窗进程没加载快捷键快照：注入给 popup.js 的只会是默认绑定');
    });

    test('Dart 注入的全局名与 popup.js 读取的全局名一致，且三镜像都带这段', () {
      const String globalName = '__fushiEntryWheelBindings';
      final String injection =
          File('lib/src/pages/implementations/popup_settings_injection.dart')
              .readAsStringSync();
      expect(injection.contains('window.$globalName ='), isTrue,
          reason: '注入端改名了：popup.js 会读到 undefined 并退回默认绑定，用户改键静默失效');

      for (final String path in const <String>[
        'assets/popup/popup.js',
        'assets/browser_extension/vendor/popup.js',
        '../tools/browser-extension/vendor/popup.js',
      ]) {
        final String js = File(path).readAsStringSync();
        expect(js.contains('window.$globalName'), isTrue,
            reason: '$path 没读注入的绑定');
        expect(js.contains('popupEntryWheelAction'), isTrue,
            reason: '$path 缺少滚轮 → 词条导航的判定函数');
        expect(
            js.contains('fushiFocusDictionaryEntryMove(entryAction)'), isTrue,
            reason: '$path 没把命中的滚轮接到词条焦点移动上');
        // 未注入时（浏览器扩展）必须有 Alt+滚轮默认，否则扩展里这功能是死的。
        expect(js.contains('FUSHI_ENTRY_WHEEL_DEFAULT_BINDINGS'), isTrue,
            reason: '$path 丢了未注入时的默认绑定');
      }
    });

    test('裸滚轮永远不劫持（popup.js 无修饰键时早退）', () {
      final String js = File('assets/popup/popup.js').readAsStringSync();
      expect(js.contains('if (pressed.length === 0) return null;'), isTrue,
          reason: '裸滚轮必须留给内容滚动，否则弹窗滚不动了');
    });
  });
}
