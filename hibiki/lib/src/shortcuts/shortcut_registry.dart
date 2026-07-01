import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

/// 持久化快照的 schema 版本。每当给某个**已存在**的 [ShortcutAction] 在默认表里
/// 新增（而非改写）一个键位时 +1，并在 [HibikiShortcutRegistry._migratePersistedDefaults]
/// 里登记一条迁移。
///
/// 为什么需要它（BUG-318 / TODO-562 的根因）：持久化语义是「用户快照即真相，整体
/// 覆盖默认」（见 [HibikiShortcutRegistry.loadFromJson]）。所以一旦给老 action 增加
/// 默认键（例：TODO-302 给 `videoToggleFullscreen` 加 F12），任何在该版本**之前**保存
/// 过快捷键设置的用户，其快照里该 action 仍是「旧版本的完整默认」（仅 F），覆盖后新键
/// （F12）永久丢失 —— 表现为「按 F12 没反应」。迁移只对「用户从未动过该 action（键集
/// 恰等于旧默认全集）」的快照补回新键，绝不碰用户主动改/删过的绑定。
const int kShortcutSchemaVersion = 4;

/// 持久化 JSON 里记录写入时 schema 版本的保留 key（不是某个 action 的绑定，故单独
/// 处理，不进 _unknownEntries，也不会被 [ShortcutAction.fromKey] 误解析）。
const String kShortcutSchemaVersionKey = '__schema_version__';

class HibikiShortcutRegistry extends ChangeNotifier {
  final Map<ShortcutAction, ShortcutBindingSet> _bindings = {};
  final Map<String, dynamic> _unknownEntries = {};

  ShortcutBindingSet bindingsFor(ShortcutAction action) =>
      _bindings[action] ?? const ShortcutBindingSet();

  void loadDefaults(TargetPlatform platform) {
    _bindings
      ..clear()
      ..addAll(ShortcutDefaults.forPlatform(platform));
    _unknownEntries.clear();
  }

  void loadFromJson(Map<String, dynamic> json) =>
      _loadFromJson(json, platform: null);

  void _loadFromJson(Map<String, dynamic> json, {TargetPlatform? platform}) {
    // HBK-AUDIT-135: 先把整段 JSON 解析进本地 map，全部成功后再原子地提交到
    // _bindings/_unknownEntries。之前是逐条写入 _bindings，一旦
    // ShortcutBindingSet.fromJson 在中途抛错（如 cast<String>() 命中非字符串
    // 元素），就会留下 "defaults + 已解析的部分条目" 的混合状态，与
    // loadFromJsonString 中 "keep defaults" 的契约矛盾。
    final Map<ShortcutAction, ShortcutBindingSet> parsedBindings = {};
    final Map<String, dynamic> parsedUnknown = {};
    int persistedVersion = 0;
    for (final entry in json.entries) {
      if (entry.key == kShortcutSchemaVersionKey) {
        final dynamic raw = entry.value;
        persistedVersion = raw is int ? raw : (raw is num ? raw.toInt() : 0);
        continue;
      }
      final action = ShortcutAction.fromKey(entry.key);
      if (action == null) {
        parsedUnknown[entry.key] = entry.value;
        continue;
      }
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        parsedBindings[action] = ShortcutBindingSet.fromJson(value);
      }
    }
    // 解析全部成功，覆盖默认值中被显式声明的条目（保留未在 JSON 中出现的默认）。
    _bindings.addAll(parsedBindings);
    _unknownEntries.addAll(parsedUnknown);
    // 老快照（版本 < 当前）补回「用户没动过的 action」上新增的默认键（BUG-318）。
    // platform==null（直接 loadFromJson，无平台上下文）时跳过迁移，保持旧契约不变；
    // 真实加载路径 loadFromJsonString 永远带平台。
    if (platform != null && persistedVersion < kShortcutSchemaVersion) {
      _migratePersistedDefaults(persistedVersion, platform);
    }
    notifyListeners();
  }

  /// 把 [from]（含）之后、直到 [kShortcutSchemaVersion] 之间每一步「给老 action 新增
  /// 默认键」补回到当前 _bindings。仅当用户从未改过该 action（其键集恰等于该次迁移
  /// 记录的「旧默认全集」）才补，避免误伤用户主动改/删的绑定。
  void _migratePersistedDefaults(int from, TargetPlatform platform) {
    final Map<ShortcutAction, ShortcutBindingSet> defaults =
        ShortcutDefaults.forPlatform(platform);
    // v0 -> v1（TODO-302 / BUG-318）：`videoToggleFullscreen` 旧默认仅 F，新默认 F+F12。
    if (from < 1) {
      _restoreDefaultIfUntouched(
        ShortcutAction.videoToggleFullscreen,
        oldDefaultKeyboard: const <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyF),
        ],
        defaults: defaults,
      );
    }
    // v1 -> v2（TODO-700 T1/T2，焦点系统重设计）：手柄返回/句子导航默认重排。这些迁移
    // 全部只动 gamepad 绑定、不动键盘绑定，故「用户没动过」判据看键盘集即准确：
    //   * globalBack    旧默认键盘仅 Alt+Left（gamepad 空）→ 新默认补手柄 B。删硬绑 B
    //     后，老用户若键盘仍是 Alt+Left（没改过返回键）就把 B 补回，否则既退不了书又
    //     没返回键（必做回归闸门）。
    //   * audiobookPrevSentence 旧键盘 Ctrl+Left（gamepad 空）→ 新增手柄 B。
    //   * audiobookNextSentence 旧键盘 Ctrl+Right（gamepad 空）→ 新增手柄 X。
    //   * readerDismissDict 旧键盘 Esc（gamepad B）→ 去掉手柄 B（B 让位给上一句）。
    //   * readerToggleBookmark 旧键盘 Ctrl+D（gamepad X）→ 去掉手柄 X（X 让位给下一句）。
    if (from < 2) {
      // 全部「仅手柄改动」：键盘默认未变，用平台无关的 keyboard-untouched 判据。
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.globalBack, defaults);
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.audiobookPrevSentence, defaults);
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.audiobookNextSentence, defaults);
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.readerDismissDict, defaults);
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.readerToggleBookmark, defaults);
    }
    // v2 -> v3（TODO-700 T6/T7）：新增 dpadUp/Down/Left/Right（gamepad scope）+
    // readerEnterCaret（reader scope）。这些是**全新 action**，老快照里根本没有它们的
    // key —— [loadDefaults] 已为新 action 播种平台默认，[_loadFromJson] 只覆盖快照里
    // 显式出现的 key、保留缺席 key 的默认，故新 action 天然拿到默认绑定，无需逐个
    // restore。这里只需 bump 版本以保持「快照版本 < 当前 ⇒ 跑迁移」不变式诚实，并
    // 记录该判断（不动用户已改过的任何旧 action）。
    //
    // v3 -> v4（TODO-1066）：新增 globalExternalLookup（globalExternal scope）。
    // 同上——这是**全新 action**，老快照里根本没有它的 key。[loadDefaults] 已为它
    // 播种平台默认（桌面 Ctrl+Alt+D / macOS Meta+Alt+D / 移动端空），[_loadFromJson]
    // 只覆盖快照里显式出现的 key、保留缺席 key 的默认，故老用户升级后天然拿到默认
    // 热键，绝不误伤其已有的任何旧绑定。此处只需 bump 版本保持「快照版本 < 当前 ⇒
    // 跑迁移」不变式诚实。
  }

  /// 当 [action] 在快照里的键盘绑定**恰等于** [oldDefaultKeyboard]（无序集合相等，
  /// 证明用户没动过它）时，用 [defaults] 里的当前默认整体替换 —— 把后加的键补回。
  /// gamepad / mouse 绑定一并跟随当前默认（这些迁移只新增键盘键，不影响其它通道，
  /// 但「未动过」判据只看键盘集，故整组回到默认是无损的）。
  void _restoreDefaultIfUntouched(
    ShortcutAction action, {
    required List<InputBinding> oldDefaultKeyboard,
    required Map<ShortcutAction, ShortcutBindingSet> defaults,
  }) {
    final ShortcutBindingSet current = bindingsFor(action);
    final ShortcutBindingSet? currentDefault = defaults[action];
    if (currentDefault == null) return;
    final Set<InputBinding> currentKeys = current.keyboardBindings.toSet();
    final Set<InputBinding> oldKeys = oldDefaultKeyboard.toSet();
    if (currentKeys.length == oldKeys.length &&
        currentKeys.containsAll(oldKeys)) {
      _bindings[action] = currentDefault;
    }
  }

  /// TODO-700 T2 的「仅手柄改动」前向迁移：当某次迁移**只动 gamepad 默认、不动键盘
  /// 默认**时，用户「没动过该 action」的判据就是其键盘绑定**仍等于当前平台默认键盘**
  /// （键盘默认在该次迁移里没变，故当前默认键盘即旧默认键盘——平台无关，避免硬编码
  /// 跨平台修饰键，如 macOS 的 Ctrl→Meta）。命中即整组回到当前默认，把新增/删除的
  /// 手柄绑定补到位；用户改过键盘则保留其快照不动。
  void _restoreGamepadDefaultIfKeyboardUntouched(
    ShortcutAction action,
    Map<ShortcutAction, ShortcutBindingSet> defaults,
  ) {
    final ShortcutBindingSet? currentDefault = defaults[action];
    if (currentDefault == null) return;
    _restoreDefaultIfUntouched(
      action,
      oldDefaultKeyboard: currentDefault.keyboardBindings,
      defaults: defaults,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      kShortcutSchemaVersionKey: kShortcutSchemaVersion,
      for (final entry in _bindings.entries)
        entry.key.key: entry.value.toJson(),
      ..._unknownEntries,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  void loadFromJsonString(String jsonString, TargetPlatform platform) {
    loadDefaults(platform);
    try {
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      // 带平台上下文走内部加载，使老快照的「新增默认键」迁移生效（BUG-318）。
      _loadFromJson(decoded, platform: platform);
    } catch (_) {
      // Corrupted JSON — keep defaults.
    }
  }

  void updateBinding(ShortcutAction action, ShortcutBindingSet bindings) {
    _bindings[action] = bindings;
    notifyListeners();
  }

  void updateBindingWithReassignments(
    ShortcutAction action,
    ShortcutBindingSet bindings, {
    Iterable<InputBinding> removeKeyboardConflicts = const <InputBinding>[],
    Iterable<GamepadBinding> removeGamepadConflicts = const <GamepadBinding>[],
    Iterable<MouseBinding> removeMouseConflicts = const <MouseBinding>[],
  }) {
    final Set<InputBinding> keyboardToRemove =
        Set<InputBinding>.of(removeKeyboardConflicts);
    final Set<GamepadBinding> gamepadToRemove =
        Set<GamepadBinding>.of(removeGamepadConflicts);
    final Set<MouseBinding> mouseToRemove =
        Set<MouseBinding>.of(removeMouseConflicts);

    if (keyboardToRemove.isNotEmpty ||
        gamepadToRemove.isNotEmpty ||
        mouseToRemove.isNotEmpty) {
      for (final ShortcutScope scope in action.scope.coactiveScopes) {
        for (final ShortcutAction oldAction
            in ShortcutAction.actionsForScope(scope)) {
          if (oldAction == action) continue;
          final ShortcutBindingSet oldBindings = bindingsFor(oldAction);
          final List<InputBinding> keyboard = oldBindings.keyboardBindings
              .where((InputBinding b) => !keyboardToRemove.contains(b))
              .toList(growable: false);
          final List<GamepadBinding> gamepad = oldBindings.gamepadBindings
              .where((GamepadBinding b) => !gamepadToRemove.contains(b))
              .toList(growable: false);
          final List<MouseBinding> mouse = oldBindings.mouseBindings
              .where((MouseBinding b) => !mouseToRemove.contains(b))
              .toList(growable: false);
          if (keyboard.length != oldBindings.keyboardBindings.length ||
              gamepad.length != oldBindings.gamepadBindings.length ||
              mouse.length != oldBindings.mouseBindings.length) {
            _bindings[oldAction] = oldBindings.copyWith(
              keyboardBindings: keyboard,
              gamepadBindings: gamepad,
              mouseBindings: mouse,
            );
          }
        }
      }
    }

    _bindings[action] = bindings;
    notifyListeners();
  }

  void resetToDefaults(TargetPlatform platform) {
    loadDefaults(platform);
    notifyListeners();
  }

  void resetScopeToDefaults(ShortcutScope scope, TargetPlatform platform) {
    final defaults = ShortcutDefaults.forPlatform(platform);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      _bindings[action] = defaults[action] ?? const ShortcutBindingSet();
    }
    notifyListeners();
  }

  /// 解析按下的键到 scope 内绑定的动作。正常路径走 [InputBinding.==] 精确相等
  /// （logicalKey + modifiers）。
  ///
  /// TODO-847：Windows 微软 IME 激活时，Flutter 引擎把 KeyDownEvent 的 logicalKey
  /// 改写成 [LogicalKeyboardKey.process]，精确相等永远失败、全表面快捷键失效。
  /// physicalKey（USB HID 扫描码）不受 IME 改写，故仅当 `key == process &&
  /// physicalKey != null` 时启用物理键回退分支：在 modifiers 完全相同的前提下按
  /// binding 的 [InputBinding.physicalKey] 比对。调用方在文本框 composing 时应传
  /// `physicalKey: null` 关闭回退，避免 IME 打字误触快捷键。
  ///
  /// 已知限制：物理回退仅对 US-QWERTY 物理布局正确（见 [InputBinding._logicalToPhysical]）。
  ShortcutAction? resolveKeyboard(
    LogicalKeyboardKey key, {
    required Set<ModifierKey> modifiers,
    required ShortcutScope scope,
    PhysicalKeyboardKey? physicalKey,
  }) {
    final target = InputBinding(key: key, modifiers: modifiers);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final kb in bindings.keyboardBindings) {
        if (kb == target) return action;
      }
    }
    // TODO-847 物理键回退：仅在 IME 把 logicalKey 改写成 process 且调用方提供了
    // physicalKey 时启用，正常路径（上面精确相等）已先尝试且完全不受影响。
    if (key == LogicalKeyboardKey.process && physicalKey != null) {
      for (final action in ShortcutAction.actionsForScope(scope)) {
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final kb in bindings.keyboardBindings) {
          if (setEquals(kb.modifiers, modifiers) &&
              kb.physicalKey != null &&
              kb.physicalKey == physicalKey) {
            return action;
          }
        }
      }
    }
    return null;
  }

  ShortcutAction? resolveGamepad(
    GamepadButton button, {
    required ShortcutScope scope,
  }) {
    final target = GamepadBinding(button);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final gp in bindings.gamepadBindings) {
        if (gp == target) return action;
      }
    }
    return null;
  }

  ShortcutAction? resolveMouse(
    int button, {
    required ShortcutScope scope,
  }) {
    final target = MouseBinding(button);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final mb in bindings.mouseBindings) {
        if (mb == target) return action;
      }
    }
    return null;
  }

  ShortcutAction? hasKeyboardConflict(
    ShortcutScope scope,
    InputBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final kb in bindings.keyboardBindings) {
          if (kb == binding) return action;
        }
      }
    }
    return null;
  }

  ShortcutAction? hasGamepadConflict(
    ShortcutScope scope,
    GamepadBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final gp in bindings.gamepadBindings) {
          if (gp == binding) return action;
        }
      }
    }
    return null;
  }

  /// TODO-1088: mouse-button conflict detection, mirroring the keyboard/gamepad
  /// checks so binding a mouse button that's already owned by another action in a
  /// coactive scope can prompt the same reassignment flow.
  ShortcutAction? hasMouseConflict(
    ShortcutScope scope,
    MouseBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final mb in bindings.mouseBindings) {
          if (mb == binding) return action;
        }
      }
    }
    return null;
  }
}
