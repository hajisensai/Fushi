import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 2026-10-14 用户拍板：库页搜索归入快捷键体系（[ShortcutAction.librarySearch]，
/// 默认 Ctrl+F / ⌘F + `/`），首页「跳到查词搜索」（homeFocusSearch）让出 Ctrl+F
/// 改为 Ctrl+K / ⌘K。v13 → v14 迁移只换「用户没动过」的那份键盘绑定，手柄与自定义
/// 键原样保留。
void main() {
  InputBinding key(LogicalKeyboardKey k, [Set<ModifierKey> mods = const {}]) =>
      InputBinding(key: k, modifiers: mods);

  String v13Snapshot(ShortcutBindingSet homeFocusSearch) {
    return jsonEncode(<String, dynamic>{
      kShortcutSchemaVersionKey: 13,
      ShortcutAction.homeFocusSearch.key: homeFocusSearch.toJson(),
    });
  }

  test('schema 版本至少是 14', () {
    expect(kShortcutSchemaVersion, greaterThanOrEqualTo(14));
  });

  test('桌面默认：librarySearch = Ctrl+F + `/`，homeFocusSearch = Ctrl+K + 手柄 Y', () {
    final Map<ShortcutAction, ShortcutBindingSet> defaults =
        ShortcutDefaults.forPlatform(TargetPlatform.windows);
    expect(
      defaults[ShortcutAction.librarySearch]!.keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
        key(LogicalKeyboardKey.slash),
      ],
    );
    final ShortcutBindingSet home = defaults[ShortcutAction.homeFocusSearch]!;
    expect(home.keyboardBindings, <InputBinding>[
      key(LogicalKeyboardKey.keyK, {ModifierKey.ctrl}),
    ]);
    expect(
      home.gamepadBindings.map((GamepadBinding b) => b.button),
      contains(GamepadButton.y),
    );
  });

  test('macOS 默认：librarySearch = ⌘F + `/`，homeFocusSearch = ⌘K', () {
    final Map<ShortcutAction, ShortcutBindingSet> defaults =
        ShortcutDefaults.forPlatform(TargetPlatform.macOS);
    expect(
      defaults[ShortcutAction.librarySearch]!.keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyF, {ModifierKey.meta}),
        key(LogicalKeyboardKey.slash),
      ],
    );
    expect(
      defaults[ShortcutAction.homeFocusSearch]!.keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyK, {ModifierKey.meta}),
      ],
    );
  });

  test('移动端只为 librarySearch 保留键盘绑定（Android Ctrl+F / iOS ⌘F）', () {
    final Map<ShortcutAction, ShortcutBindingSet> android =
        ShortcutDefaults.forPlatform(TargetPlatform.android);
    final Map<ShortcutAction, ShortcutBindingSet> ios =
        ShortcutDefaults.forPlatform(TargetPlatform.iOS);
    expect(
      android[ShortcutAction.librarySearch]!.keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
        key(LogicalKeyboardKey.slash),
      ],
    );
    expect(ios[ShortcutAction.librarySearch]!.keyboardBindings, <InputBinding>[
      key(LogicalKeyboardKey.keyF, {ModifierKey.meta}),
      key(LogicalKeyboardKey.slash),
    ]);
    // home 组其余动作在移动端仍无键盘绑定。
    for (final Map<ShortcutAction, ShortcutBindingSet> map
        in <Map<ShortcutAction, ShortcutBindingSet>>[android, ios]) {
      expect(map[ShortcutAction.homeFocusSearch]!.keyboardBindings, isEmpty);
      expect(map[ShortcutAction.homeTabBooks]!.keyboardBindings, isEmpty);
    }
    // 除 librarySearch 外，iOS 与 Android 默认逐项相同。
    for (final ShortcutAction action in ShortcutAction.values) {
      if (action == ShortcutAction.librarySearch) continue;
      expect(
        ios[action]!.toJson(),
        android[action]!.toJson(),
        reason: '$action',
      );
    }
  });

  test('v13 快照里没改过的 Ctrl+F 迁到 Ctrl+K，手柄 Y 保留', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        v13Snapshot(
          ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
            ],
            gamepadBindings: const <GamepadBinding>[
              GamepadBinding(GamepadButton.y),
            ],
          ),
        ),
        TargetPlatform.windows,
      );
    final ShortcutBindingSet home = registry.bindingsFor(
      ShortcutAction.homeFocusSearch,
    );
    expect(home.keyboardBindings, <InputBinding>[
      key(LogicalKeyboardKey.keyK, {ModifierKey.ctrl}),
    ]);
    expect(home.gamepadBindings, const <GamepadBinding>[
      GamepadBinding(GamepadButton.y),
    ]);
    // 新 action 由 loadDefaults 播种。
    expect(
      registry.bindingsFor(ShortcutAction.librarySearch).keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
        key(LogicalKeyboardKey.slash),
      ],
    );
  });

  test('v13 快照：手柄改过、键盘没改 → 只换键盘，用户手柄键不动', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        v13Snapshot(
          ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
            ],
            gamepadBindings: const <GamepadBinding>[
              GamepadBinding(GamepadButton.x),
            ],
          ),
        ),
        TargetPlatform.windows,
      );
    final ShortcutBindingSet home = registry.bindingsFor(
      ShortcutAction.homeFocusSearch,
    );
    expect(home.keyboardBindings, <InputBinding>[
      key(LogicalKeyboardKey.keyK, {ModifierKey.ctrl}),
    ]);
    expect(home.gamepadBindings, const <GamepadBinding>[
      GamepadBinding(GamepadButton.x),
    ]);
  });

  test('macOS v13 快照里没改过的 ⌘F 迁到 ⌘K', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        v13Snapshot(
          ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              key(LogicalKeyboardKey.keyF, {ModifierKey.meta}),
            ],
          ),
        ),
        TargetPlatform.macOS,
      );
    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).keyboardBindings,
      <InputBinding>[
        key(LogicalKeyboardKey.keyK, {ModifierKey.meta}),
      ],
    );
  });

  test('用户自定义过的 homeFocusSearch 键盘绑定不动', () {
    final List<InputBinding> custom = <InputBinding>[
      key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl, ModifierKey.shift}),
    ];
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        v13Snapshot(ShortcutBindingSet(keyboardBindings: custom)),
        TargetPlatform.windows,
      );
    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).keyboardBindings,
      custom,
    );
  });

  test('用户把 Ctrl+F 加进了额外键（不是恰等于旧默认）→ 不动', () {
    final List<InputBinding> custom = <InputBinding>[
      key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
      key(LogicalKeyboardKey.keyS, {ModifierKey.ctrl, ModifierKey.alt}),
    ];
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        v13Snapshot(ShortcutBindingSet(keyboardBindings: custom)),
        TargetPlatform.windows,
      );
    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).keyboardBindings,
      custom,
    );
  });

  test('v14 快照不再迁移：用户在新版里把 homeFocusSearch 改回 Ctrl+F 保持原样', () {
    final List<InputBinding> chosen = <InputBinding>[
      key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
    ];
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadFromJsonString(
        jsonEncode(<String, dynamic>{
          kShortcutSchemaVersionKey: 14,
          ShortcutAction.homeFocusSearch.key: ShortcutBindingSet(
            keyboardBindings: chosen,
          ).toJson(),
        }),
        TargetPlatform.windows,
      );
    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).keyboardBindings,
      chosen,
    );
  });

  test('两者被用户绑成同一个键时，home 作用域解析按声明序先命中 homeFocusSearch', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows)
      ..updateBinding(
        ShortcutAction.homeFocusSearch,
        ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
          ],
        ),
      );
    expect(
      registry.resolveKeyboard(
        LogicalKeyboardKey.keyF,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
        scope: ShortcutScope.home,
      ),
      ShortcutAction.homeFocusSearch,
      reason: '库页之外 Ctrl+F 仍跳查词；库页内由库页外壳先拦下',
    );
    // 默认绑定下 Ctrl+F 在 home 作用域解析到 librarySearch（库页之外由 home
    // 页返回 ignored 冒泡），Ctrl+K 解析到 homeFocusSearch。
    final FushiShortcutRegistry defaults = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    expect(
      defaults.resolveKeyboard(
        LogicalKeyboardKey.keyF,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
        scope: ShortcutScope.home,
      ),
      ShortcutAction.librarySearch,
    );
    expect(
      defaults.resolveKeyboard(
        LogicalKeyboardKey.keyK,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
        scope: ShortcutScope.home,
      ),
      ShortcutAction.homeFocusSearch,
    );
  });
}
