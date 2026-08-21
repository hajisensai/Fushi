import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';

/// 持久化快照的 schema 版本。每当给某个**已存在**的 [ShortcutAction] 在默认表里
/// 新增（而非改写）一个键位时 +1，并在 [FushiShortcutRegistry._migratePersistedDefaults]
/// 里登记一条迁移。
///
/// 为什么需要它（BUG-318 / TODO-562 的根因）：持久化语义是「用户快照即真相，整体
/// 覆盖默认」（见 [FushiShortcutRegistry.loadFromJson]）。所以一旦给老 action 增加
/// 默认键（例：TODO-302 给 `videoToggleFullscreen` 加 F12），任何在该版本**之前**保存
/// 过快捷键设置的用户，其快照里该 action 仍是「旧版本的完整默认」（仅 F），覆盖后新键
/// （F12）永久丢失 —— 表现为「按 F12 没反应」。迁移只对「用户从未动过该 action（键集
/// 恰等于旧默认全集）」的快照补回新键，绝不碰用户主动改/删过的绑定。
const int kShortcutSchemaVersion = 9;

/// 持久化 JSON 里记录写入时 schema 版本的保留 key（不是某个 action 的绑定，故单独
/// 处理，不进 _unknownEntries，也不会被 [ShortcutAction.fromKey] 误解析）。
const String kShortcutSchemaVersionKey = '__schema_version__';

class FushiShortcutRegistry extends ChangeNotifier {
  final Map<ShortcutAction, ShortcutBindingSet> _bindings = {};
  final Map<String, dynamic> _unknownEntries = {};

  ShortcutBindingSet bindingsFor(ShortcutAction action) =>
      _bindings[action] ?? const ShortcutBindingSet();

  /// 这个注册表是否已经装过绑定（[loadDefaults] / [loadFromJsonString]）。
  ///
  /// 未装载时 [bindingsFor] 对**每个** action 都返回空绑定集，这与「用户把某个动作
  /// 的绑定清空了」在数据上无法区分。绝大多数消费者跑在完成 initialise() 的主进程
  /// 里、不必关心；但把绑定**序列化下发**给别的运行时（如注入给弹窗 WebView 的
  /// popup.js）时必须区分：空表在那边的语义是「该动作已被用户关掉」，未装载时误发
  /// 空表会让功能静默失效。这类调用方用本标志回落到平台默认。
  bool get isLoaded => _bindings.isNotEmpty;

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
    //
    // v4 -> v5（TODO-1342，视频播放器手柄映射）：给一批**已存在**的 video 动作新增
    // 手柄默认绑定（A=播放/暂停、B=退出、LB/RB+dpad 左右=快退/快进、dpad 上下=音量、
    // X/Y=上/下一句字幕、LT=重听、RT=全屏、Start=字幕列表）。这些动作在老快照里已
    // 有键盘绑定但无手柄绑定，快照整体覆盖默认 ⇒ 新手柄键会被永久丢失（BUG-318 同型）。
    // 这些迁移**只新增手柄绑定、不改键盘默认**，故用「键盘未动过」判据（键盘集仍等于
    // 当前平台默认）即准确：命中即整组回到当前默认把新手柄键补回，用户改过键盘则不动。
    //
    // ⚠️ 原列表里的 `videoEscape` 已在 v8 删除（语义并入 universal 的 globalBack），
    // 故这一步不再给它补手柄 B。没有能力损失：B 现在由 globalBack 承担，而
    // globalBack 的手柄 B 早在 v1→v2 就补过（见上）。
    if (from < 5) {
      for (final ShortcutAction action in const <ShortcutAction>[
        ShortcutAction.videoTogglePlayPause,
        ShortcutAction.videoSeekBackward,
        ShortcutAction.videoSeekForward,
        ShortcutAction.videoVolumeUp,
        ShortcutAction.videoVolumeDown,
        ShortcutAction.videoPreviousSubtitle,
        ShortcutAction.videoNextSubtitle,
        ShortcutAction.videoReplayCurrentSubtitle,
        ShortcutAction.videoToggleFullscreen,
        ShortcutAction.videoToggleSubtitleList,
      ]) {
        _restoreGamepadDefaultIfKeyboardUntouched(action, defaults);
      }
    }
    // v5 -> v6（用户拍板：关词典与退书拆分）：新增 readerExitBook（reader scope，
    // 默认 Ctrl+W）。全新 action，老快照没有它的 key —— [loadDefaults] 已播种默认，
    // [_loadFromJson] 保留缺席 key 的默认，天然拿到 Ctrl+W，无需逐个 restore，只
    // bump 版本保持不变式诚实。⚠️ 行为面：readerDismissDict（Esc）不再在无弹窗时
    // 退书（执行体侧拆分，见 caret.part.dart），退书统一走 readerExitBook /
    // 返回手势 / 底栏。
    //
    // v6 -> v7（查词弹窗 Alt+滚轮词条导航）：新增 popupNextEntry / popupPrevEntry
    // （dictionaryPopup scope，纯滚轮通道，默认 Alt+滚轮下/上）。**全新 action**，
    // 老快照里没有它们的 key —— [loadDefaults] 已播种默认，[_loadFromJson] 只覆盖
    // 快照里显式出现的 key、保留缺席 key 的默认，故老用户升级后天然拿到 Alt+滚轮，
    // 无需逐个 restore。同时 [ShortcutBindingSet] 新增 `wheel` 序列化字段：老快照
    // 缺这个 key 时 fromJson 给空表，任何既有 action 的键盘/手柄/鼠标绑定都不受
    // 影响。这里只需 bump 版本保持「快照版本 < 当前 ⇒ 跑迁移」不变式诚实。
    //
    // v7 -> v8（用户拍板：「返回上一级」全 app 统一成**一个**配置项）。三件事：
    //   ① globalBack 挪到 universal scope、默认键盘新增 Esc（旧默认只有 Alt+←）。
    //      持久化 key `global_back` 不变，故老快照原样命中；没改过的用户补上 Esc。
    //   ② readerDismissDict / mangaDismissDict 的默认 Esc 收回（新默认空绑定）。
    //      不收回的话，reader/manga scope 先解析 ⇒ Esc 永远只关词典、退不出去，
    //      正是本次要消灭的双轨。只清**键盘**、保留鼠标绑定（BUG-1071 的侧键通道）。
    //   ③ 已删除的 readerExitBook / videoEscape：用户**改过**的键并入 globalBack，
    //      没改过的按默认丢弃（其默认语义已被 globalBack 的 Esc 完整覆盖）。
    // 三者都严格遵守「只动没被用户碰过的部分」，改过的绑定一律保留或搬运。
    if (from < 8) {
      _restoreDefaultIfUntouched(
        ShortcutAction.globalBack,
        oldDefaultKeyboard: const <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: <ModifierKey>{ModifierKey.alt},
          ),
        ],
        defaults: defaults,
      );
      for (final ShortcutAction action in const <ShortcutAction>[
        ShortcutAction.readerDismissDict,
        ShortcutAction.mangaDismissDict,
      ]) {
        _clearKeyboardIfUntouched(
          action,
          oldDefaultKeyboard: const <InputBinding>[
            InputBinding(key: LogicalKeyboardKey.escape),
          ],
        );
      }
      // macOS 的默认表把 Ctrl 换成 Meta（见 ShortcutDefaults._macOS），故退书键的
      // 「旧默认」随平台不同；判据必须用当时那台机器的默认，否则会把没改过的
      // Cmd+W 当成用户自定义搬进 globalBack。
      _absorbRemovedActionBindings(
        legacyKey: 'reader_exit_book',
        oldDefaultKeyboard: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyW,
            modifiers: <ModifierKey>{
              platform == TargetPlatform.macOS
                  ? ModifierKey.meta
                  : ModifierKey.ctrl,
            },
          ),
        ],
        oldDefaultGamepad: const <GamepadBinding>[],
      );
      _absorbRemovedActionBindings(
        legacyKey: 'video_escape',
        oldDefaultKeyboard: const <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.escape),
        ],
        oldDefaultGamepad: const <GamepadBinding>[
          GamepadBinding(GamepadButton.b),
        ],
      );
    }
    // v8 -> v9（手柄全功能重设计 P1，漫画页接手柄）：给两个**已存在**的 manga 翻页
    // 动作新增手柄默认（RB/dpad右=前进、LB/dpad左=后退）。老快照里它们已有键盘绑定
    // 但手柄为空，快照整体覆盖默认 ⇒ 不迁移则新手柄键永久丢失（BUG-318 同型，与
    // v4→v5 的 video 手柄批完全同构）。只新增手柄、不改键盘默认，故用「键盘未动过」
    // 判据。B 不在此列——退出/关弹窗归 universal globalBack 的手柄 B（v1→v2 已补）。
    if (from < 9) {
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.mangaPageForward, defaults);
      _restoreGamepadDefaultIfKeyboardUntouched(
          ShortcutAction.mangaPageBackward, defaults);
    }
  }

  /// v8：把 [action] 的**键盘**绑定清空，仅当它恰等于 [oldDefaultKeyboard]（证明
  /// 用户没动过）。其余通道（鼠标/手柄/滚轮）原样保留 —— 这正是与
  /// [_restoreDefaultIfUntouched] 的区别：那个整组换成当前默认，会连用户绑在
  /// readerDismissDict 上的**鼠标侧键**一起抹掉（BUG-1071 的唯一鼠标通道）。
  void _clearKeyboardIfUntouched(
    ShortcutAction action, {
    required List<InputBinding> oldDefaultKeyboard,
  }) {
    final ShortcutBindingSet current = bindingsFor(action);
    final Set<InputBinding> currentKeys = current.keyboardBindings.toSet();
    final Set<InputBinding> oldKeys = oldDefaultKeyboard.toSet();
    if (currentKeys.length != oldKeys.length ||
        !currentKeys.containsAll(oldKeys)) {
      return;
    }
    _bindings[action] = current.copyWith(
      keyboardBindings: const <InputBinding>[],
    );
  }

  /// v8：把一个**已从代码里删除**的 action（其 key 现在落在 [_unknownEntries]）上
  /// 用户自定义过的键盘/手柄绑定并入 [ShortcutAction.globalBack]。
  ///
  /// 判据与其它迁移同源：绑定恰等于该 action 的旧默认 ⇒ 用户没动过 ⇒ 直接丢弃
  /// （旧默认的语义已由 globalBack 的新默认完整覆盖，搬过去只会多出一个重复键位）；
  /// 不等 ⇒ 用户特意改过 ⇒ 搬进 globalBack，去重后追加在既有绑定之后（既有绑定
  /// 优先，顺序稳定）。搬完把 legacy key 从 [_unknownEntries] 移除，避免它随
  /// [toJson] 永久回写、下次启动又搬一次。
  void _absorbRemovedActionBindings({
    required String legacyKey,
    required List<InputBinding> oldDefaultKeyboard,
    required List<GamepadBinding> oldDefaultGamepad,
  }) {
    final dynamic raw = _unknownEntries[legacyKey];
    if (raw is! Map<String, dynamic>) return;
    _unknownEntries.remove(legacyKey);
    final ShortcutBindingSet legacy;
    try {
      legacy = ShortcutBindingSet.fromJson(raw);
    } catch (_) {
      return; // 损坏的条目：丢弃即可，绝不因此打断整段迁移。
    }
    final bool keyboardUntouched = _sameBindings<InputBinding>(
        legacy.keyboardBindings, oldDefaultKeyboard);
    final bool gamepadUntouched = _sameBindings<GamepadBinding>(
        legacy.gamepadBindings, oldDefaultGamepad);
    if (keyboardUntouched && gamepadUntouched) return;

    final ShortcutBindingSet back = bindingsFor(ShortcutAction.globalBack);
    final List<InputBinding> keyboard =
        List<InputBinding>.of(back.keyboardBindings);
    final List<GamepadBinding> gamepad =
        List<GamepadBinding>.of(back.gamepadBindings);
    if (!keyboardUntouched) {
      for (final InputBinding b in legacy.keyboardBindings) {
        if (!keyboard.contains(b)) keyboard.add(b);
      }
    }
    if (!gamepadUntouched) {
      for (final GamepadBinding b in legacy.gamepadBindings) {
        if (!gamepad.contains(b)) gamepad.add(b);
      }
    }
    _bindings[ShortcutAction.globalBack] = back.copyWith(
      keyboardBindings: keyboard,
      gamepadBindings: gamepad,
    );
  }

  static bool _sameBindings<T>(List<T> a, List<T> b) {
    final Set<T> left = a.toSet();
    final Set<T> right = b.toSet();
    return left.length == right.length && left.containsAll(right);
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
    Iterable<WheelBinding> removeWheelConflicts = const <WheelBinding>[],
  }) {
    final Set<InputBinding> keyboardToRemove =
        Set<InputBinding>.of(removeKeyboardConflicts);
    final Set<GamepadBinding> gamepadToRemove =
        Set<GamepadBinding>.of(removeGamepadConflicts);
    final Set<MouseBinding> mouseToRemove =
        Set<MouseBinding>.of(removeMouseConflicts);
    final Set<WheelBinding> wheelToRemove =
        Set<WheelBinding>.of(removeWheelConflicts);

    if (keyboardToRemove.isNotEmpty ||
        gamepadToRemove.isNotEmpty ||
        mouseToRemove.isNotEmpty ||
        wheelToRemove.isNotEmpty) {
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
          final List<WheelBinding> wheel = oldBindings.wheelBindings
              .where((WheelBinding b) => !wheelToRemove.contains(b))
              .toList(growable: false);
          if (keyboard.length != oldBindings.keyboardBindings.length ||
              gamepad.length != oldBindings.gamepadBindings.length ||
              mouse.length != oldBindings.mouseBindings.length ||
              wheel.length != oldBindings.wheelBindings.length) {
            _bindings[oldAction] = oldBindings.copyWith(
              keyboardBindings: keyboard,
              gamepadBindings: gamepad,
              mouseBindings: mouse,
              wheelBindings: wheel,
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

  /// 滚轮绑定的冲突检测，与键盘/手柄/鼠标三条同形：同一 co-active 组里同一
  /// 「修饰键 + 方向」组合只能属于一个动作，否则后者永远不触发。
  ShortcutAction? hasWheelConflict(
    ShortcutScope scope,
    WheelBinding binding, {
    required ShortcutAction? exclude,
  }) {
    for (final coactive in scope.coactiveScopes) {
      for (final action in ShortcutAction.actionsForScope(coactive)) {
        if (action == exclude) continue;
        final bindings = _bindings[action];
        if (bindings == null) continue;
        for (final wb in bindings.wheelBindings) {
          if (wb == binding) return action;
        }
      }
    }
    return null;
  }
}
