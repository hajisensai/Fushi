// 快捷键设置页 2026-10 重设计：单页浏览器。
//
// 「翻来翻去」的根因（重设计前）：十个作用域各一张卡竖排在一条长滚动里、没有搜索、
// 没有「这个键绑了什么」的反查；改一个键要「点行 → 弹窗 → 点『+ 键盘』→ 按键 →
// 撞键再弹一层确认 → 确定」；键盘 / 手柄 / 鼠标绑定混在同一行；恢复默认只有整组。
//
// 这里把它收成一页：顶部固定工具区（搜索 + 按键反查 / 输入设备分段 / 域筛选），
// 宽屏左栏是吸顶的域导航、右栏是带粘性分组标题的绑定列表；行内点一下就原地录制、
// 撞键原地给出「替换 / 交换 / 都保留」。写穿路径不变：registry.updateBinding →
// [ShortcutBindingsBrowser.onChanged]（页面接 saveShortcutRegistry），改完立即生效。
part of '../shortcut_settings_page.dart';

/// 浏览器当前展示 / 录制的输入设备。鼠标页同时收鼠标按键与「修饰键 + 滚轮」。
enum ShortcutInputDevice { keyboard, gamepad, mouse }

extension ShortcutInputDeviceChannels on ShortcutInputDevice {
  /// 这台设备覆盖的绑定通道。
  Set<ShortcutChannel> get channels => switch (this) {
        ShortcutInputDevice.keyboard => const <ShortcutChannel>{
            ShortcutChannel.keyboard,
          },
        ShortcutInputDevice.gamepad => const <ShortcutChannel>{
            ShortcutChannel.gamepad,
          },
        ShortcutInputDevice.mouse => const <ShortcutChannel>{
            ShortcutChannel.mouse,
            ShortcutChannel.wheel,
          },
      };

  IconData get icon => switch (this) {
        ShortcutInputDevice.keyboard => FushiIcons.keyboard,
        ShortcutInputDevice.gamepad => FushiIcons.games,
        ShortcutInputDevice.mouse => FushiIcons.mouse,
      };

  String get label => switch (this) {
        ShortcutInputDevice.keyboard => t.shortcut_keyboard,
        ShortcutInputDevice.gamepad => t.shortcut_gamepad,
        ShortcutInputDevice.mouse => t.shortcut_device_mouse,
      };
}

/// 一条绑定（[InputBinding] / [GamepadBinding] / [MouseBinding] / [WheelBinding]）
/// 落在哪条通道。
ShortcutChannel shortcutBindingChannel(Object binding) => switch (binding) {
      InputBinding() => ShortcutChannel.keyboard,
      GamepadBinding() => ShortcutChannel.gamepad,
      MouseBinding() => ShortcutChannel.mouse,
      WheelBinding() => ShortcutChannel.wheel,
      _ => throw ArgumentError.value(binding, 'binding', 'unknown binding'),
    };

/// [set] 在 [channel] 上的绑定（类型擦成 Object，便于通道无关的增删）。
List<Object> shortcutBindingsInChannel(
  ShortcutBindingSet set,
  ShortcutChannel channel,
) =>
    switch (channel) {
      ShortcutChannel.keyboard => List<Object>.of(set.keyboardBindings),
      ShortcutChannel.gamepad => List<Object>.of(set.gamepadBindings),
      ShortcutChannel.mouse => List<Object>.of(set.mouseBindings),
      ShortcutChannel.wheel => List<Object>.of(set.wheelBindings),
    };

/// [set] 在 [device] 覆盖的全部通道上的绑定。
List<Object> shortcutBindingsForDevice(
  ShortcutBindingSet set,
  ShortcutInputDevice device,
) =>
    <Object>[
      for (final ShortcutChannel channel in device.channels)
        ...shortcutBindingsInChannel(set, channel),
    ];

/// 把 [set] 的 [channel] 通道整体换成 [bindings]，其余通道原样保留。
ShortcutBindingSet shortcutBindingSetWithChannel(
  ShortcutBindingSet set,
  ShortcutChannel channel,
  List<Object> bindings,
) =>
    switch (channel) {
      ShortcutChannel.keyboard => set.copyWith(
          keyboardBindings: List<InputBinding>.unmodifiable(
            bindings.whereType<InputBinding>(),
          ),
        ),
      ShortcutChannel.gamepad => set.copyWith(
          gamepadBindings: List<GamepadBinding>.unmodifiable(
            bindings.whereType<GamepadBinding>(),
          ),
        ),
      ShortcutChannel.mouse => set.copyWith(
          mouseBindings: List<MouseBinding>.unmodifiable(
            bindings.whereType<MouseBinding>(),
          ),
        ),
      ShortcutChannel.wheel => set.copyWith(
          wheelBindings: List<WheelBinding>.unmodifiable(
            bindings.whereType<WheelBinding>(),
          ),
        ),
    };

/// 两组绑定是否等价（各通道按集合比，顺序无关）——「已自定义」标记的判据。
bool shortcutBindingSetsEquivalent(ShortcutBindingSet a, ShortcutBindingSet b) {
  bool same<T>(List<T> x, List<T> y) =>
      x.length == y.length && Set<T>.of(x).containsAll(y);
  return same(a.keyboardBindings, b.keyboardBindings) &&
      same(a.gamepadBindings, b.gamepadBindings) &&
      same(a.mouseBindings, b.mouseBindings) &&
      same(a.wheelBindings, b.wheelBindings);
}

/// [set] 是否含 [binding]（按键反查的判据）。
bool shortcutBindingSetContains(ShortcutBindingSet set, Object binding) =>
    shortcutBindingsInChannel(
      set,
      shortcutBindingChannel(binding),
    ).contains(binding);

/// 一条绑定的可读名（搜索与提示共用）。
String shortcutBindingLabel(Object binding, GamepadBrand brand) =>
    switch (binding) {
      final InputBinding b => b.displayLabel,
      final GamepadBinding b => GamepadGlyphs.glyphFor(b.button, brand).symbol,
      final MouseBinding b => b.label,
      final WheelBinding b => b.label,
      _ => '',
    };

/// 搜索框文本命中：动作名 / 作用域名 / 任一绑定的可读名（含手柄按钮的通用名）。
bool shortcutActionMatchesQuery(
  ShortcutAction action,
  ShortcutBindingSet bindings,
  String query,
) {
  return matchesMediaSearch(
    query: query,
    titles: <String>[
      action.label,
      action.scope.label,
      for (final InputBinding b in bindings.keyboardBindings) b.displayLabel,
      for (final GamepadBinding b in bindings.gamepadBindings) ...<String>[
        b.button.label,
        for (final GamepadBrand brand in GamepadBrand.values)
          GamepadGlyphs.glyphFor(b.button, brand).symbol,
      ],
      for (final MouseBinding b in bindings.mouseBindings) b.label,
      for (final WheelBinding b in bindings.wheelBindings) b.label,
    ],
  );
}

/// 宽屏两栏的断点（内容区宽度）。
const double kShortcutBrowserTwoPaneMinWidth = 840;

/// 宽屏左栏（域导航）宽度。
const double kShortcutBrowserNavWidth = 240;

/// 撞键时用户的处置（内联冲突条）。
enum _InlineConflictChoice { replace, swap, keepBoth }

@immutable
class _PendingConflict {
  const _PendingConflict({
    required this.action,
    required this.binding,
    required this.conflict,
    required this.replace,
  });

  final ShortcutAction action;
  final Object binding;
  final ShortcutAction conflict;

  /// 录制时是「替换本动作在该通道的绑定」还是「追加一条」。
  final bool replace;
}

/// 快捷键浏览器：搜索 + 域筛选 + 输入设备切换 + 行内录制 / 冲突处理。
///
/// 只依赖注册表与回调，不读 AppModel，因此能在 widget 测试里独立挂载（页面级
/// state 绑着 live AppModel，见 visual_settings_page_guard_test 的说明）。
class ShortcutBindingsBrowser extends StatefulWidget {
  const ShortcutBindingsBrowser({
    required this.registry,
    required this.scopes,
    required this.platform,
    required this.onChanged,
    super.key,
    this.gamepadBrand = GamepadBrand.xbox,
    this.initialDevice = ShortcutInputDevice.keyboard,
    this.onDeviceChanged,
    this.onOpenEditor,
    this.onResetScope,
    this.onResetAll,
    this.readOnlyScopes = const <ShortcutScope>{},
    this.scopeExtras,
    this.scopeBodyOverride,
    this.toolbarTrailing = const <Widget>[],
    this.deviceAccessory,
    this.banner,
  });

  final FushiShortcutRegistry registry;

  /// 要展示的作用域（页面已按模块可见性过滤，顺序即展示顺序）。
  final List<ShortcutScope> scopes;

  /// 决定默认表（「已自定义」判据 / 单项恢复默认）与鼠标能否录入。
  final TargetPlatform platform;

  /// 注册表被本组件改动后调用（页面在这里持久化）。
  final Future<void> Function() onChanged;

  final GamepadBrand gamepadBrand;
  final ShortcutInputDevice initialDevice;
  final ValueChanged<ShortcutInputDevice>? onDeviceChanged;

  /// 「完整编辑」：打开多通道编辑对话框（能录 Esc / Tab 这类行内录制让给取消 /
  /// 焦点的键，也能一次改多通道）。
  final Future<void> Function(ShortcutAction action)? onOpenEditor;

  /// 分组「恢复默认」（页面负责确认弹窗 + 写回）。
  final Future<void> Function(ShortcutScope scope)? onResetScope;

  /// 「全部恢复默认」（页面负责确认弹窗 + 写回）。
  final Future<void> Function()? onResetAll;

  /// 只读作用域：行照常列出，但不可点、不可录（移动端系统接管的 app 外查词）。
  final Set<ShortcutScope> readOnlyScopes;

  /// 分组卡顶部的说明行 / 开关（只在未搜索时显示，搜索结果保持干净）。
  final List<Widget> Function(ShortcutScope scope)? scopeExtras;

  /// 非 null 时用它替换该分组的行列表（键位图模式）。
  final Widget? Function(ShortcutScope scope, ShortcutInputDevice device)?
      scopeBodyOverride;

  /// 设备分段右侧的额外动作（键位图切换等）。
  final List<Widget> toolbarTrailing;

  /// 设备分段下方、按设备出现的附加控件（手柄按钮样式选择等）。
  final Widget? Function(ShortcutInputDevice device)? deviceAccessory;

  /// 工具区上方的提示条（GameInput 不可用等）。
  final Widget? banner;

  @override
  State<ShortcutBindingsBrowser> createState() =>
      _ShortcutBindingsBrowserState();
}

class _ShortcutBindingsBrowserState extends State<ShortcutBindingsBrowser> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'shortcut-search');
  final FocusNode _keySearchFocus = FocusNode(
    debugLabel: 'shortcut-key-search',
  );
  final ScrollController _resultsController = ScrollController();

  String _query = '';
  Object? _keyFilter;
  bool _keySearchArmed = false;
  ShortcutScope? _domain;
  late ShortcutInputDevice _device = widget.initialDevice;

  ShortcutAction? _recording;
  bool _recordReplace = true;

  /// 录制中 / 刚结束的一条说明（滚轮缺修饰键、按钮不支持、追加了重复键），
  /// 只挂在 [_warningAction] 那一行。
  String? _recordWarning;
  ShortcutAction? _warningAction;
  _PendingConflict? _pending;

  late Map<ShortcutAction, ShortcutBindingSet> _defaults =
      ShortcutDefaults.forPlatform(widget.platform);

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_onRegistryChanged);
  }

  @override
  void didUpdateWidget(ShortcutBindingsBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.registry, widget.registry)) {
      oldWidget.registry.removeListener(_onRegistryChanged);
      widget.registry.addListener(_onRegistryChanged);
    }
    if (oldWidget.platform != widget.platform) {
      _defaults = ShortcutDefaults.forPlatform(widget.platform);
    }
  }

  @override
  void dispose() {
    widget.registry.removeListener(_onRegistryChanged);
    _queryController.dispose();
    _queryFocus.dispose();
    _keySearchFocus.dispose();
    _resultsController.dispose();
    super.dispose();
  }

  void _onRegistryChanged() {
    if (mounted) setState(() {});
  }

  FushiShortcutRegistry get _registry => widget.registry;

  bool get _mouseCapturable => _mouseBindingSupported(widget.platform);

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  bool _deviceApplies(ShortcutAction action, ShortcutBindingSet bindings) {
    if (widget.readOnlyScopes.contains(action.scope)) return true;
    if (action.channels.any(_device.channels.contains)) return true;
    return shortcutBindingsForDevice(bindings, _device).isNotEmpty;
  }

  bool _rowVisible(ShortcutAction action) {
    final ShortcutBindingSet bindings = _registry.bindingsFor(action);
    final Object? keyFilter = _keyFilter;
    if (keyFilter != null) {
      return shortcutBindingSetContains(bindings, keyFilter);
    }
    if (!_deviceApplies(action, bindings)) return false;
    return shortcutActionMatchesQuery(action, bindings, _query);
  }

  List<ShortcutAction> _visibleActions(ShortcutScope scope) =>
      ShortcutAction.actionsForScope(
        scope,
      ).where(_rowVisible).toList(growable: false);

  bool _isModified(ShortcutAction action) => !shortcutBindingSetsEquivalent(
        _registry.bindingsFor(action),
        _defaults[action] ?? const ShortcutBindingSet(),
      );

  bool get _filtering => _keyFilter != null || _query.trim().isNotEmpty;

  // ---------------------------------------------------------------------------
  // Search / filters
  // ---------------------------------------------------------------------------

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _keyFilter = null;
    });
  }

  void _clearQuery() {
    _queryController.clear();
    _setQuery('');
  }

  void _armKeySearch() {
    setState(() {
      _keySearchArmed = true;
      _cancelRecordingState();
    });
    _requestFocusNextFrame(_keySearchFocus);
  }

  void _disarmKeySearch() {
    setState(() => _keySearchArmed = false);
    _requestFocusNextFrame(_queryFocus);
  }

  void _applyKeyFilter(Object binding) {
    final ShortcutChannel channel = shortcutBindingChannel(binding);
    setState(() {
      _keyFilter = binding;
      _keySearchArmed = false;
      _queryController.clear();
      _query = '';
      _device = ShortcutInputDevice.values.firstWhere(
        (ShortcutInputDevice d) => d.channels.contains(channel),
      );
    });
    widget.onDeviceChanged?.call(_device);
  }

  void _clearKeyFilter() {
    setState(() => _keyFilter = null);
    _requestFocusNextFrame(_queryFocus);
  }

  void _selectDomain(ShortcutScope? scope) {
    if (scope == _domain) return;
    setState(() => _domain = scope);
    if (_resultsController.hasClients) _resultsController.jumpTo(0);
  }

  void _selectDevice(ShortcutInputDevice device) {
    if (device == _device) return;
    setState(() {
      _device = device;
      _cancelRecordingState();
    });
    widget.onDeviceChanged?.call(device);
  }

  /// 捕获区在 setState 的**下一帧**才挂上（TODO-838 同一个坑）：同步
  /// requestFocus 打到还没 attach 的节点上是空操作。setState 本身会排一帧，
  /// 所以帧后回调一定会跑。
  void _requestFocusNextFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || node.context == null) return;
      node.requestFocus();
    });
  }

  KeyEventResult _onKeySearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final GamepadButton? pad = GamepadButton.fromKeyEvent(event);
    if (pad != null) {
      _applyKeyFilter(GamepadBinding(pad));
      return KeyEventResult.handled;
    }
    final LogicalKeyboardKey key = InputBinding.normalizeCapturedKey(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
    );
    if (ModifierKey.fromKeyboardKey(key) != null) return KeyEventResult.handled;
    _applyKeyFilter(InputBinding(key: key, modifiers: _pressedModifiers()));
    return KeyEventResult.handled;
  }

  Set<ModifierKey> _pressedModifiers() {
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    return <ModifierKey>{
      if (hw.isControlPressed) ModifierKey.ctrl,
      if (hw.isShiftPressed) ModifierKey.shift,
      if (hw.isAltPressed) ModifierKey.alt,
      if (hw.isMetaPressed) ModifierKey.meta,
    };
  }

  // ---------------------------------------------------------------------------
  // Inline recording
  // ---------------------------------------------------------------------------

  bool _canRecord(ShortcutAction action) {
    if (widget.readOnlyScopes.contains(action.scope)) return false;
    final Set<ShortcutChannel> open = action.channels.intersection(
      _device.channels,
    );
    if (open.isEmpty) return false;
    if (_device == ShortcutInputDevice.mouse && !_mouseCapturable) {
      return open.contains(ShortcutChannel.wheel);
    }
    return true;
  }

  void _startRecording(ShortcutAction action, {required bool replace}) {
    if (!_canRecord(action)) {
      // 当前设备录不了（通道没开 / 平台没有鼠标）：交给完整编辑器，那里按通道
      // 能力显示能加的入口与已有绑定。
      final Future<void> Function(ShortcutAction)? editor = widget.onOpenEditor;
      if (editor != null) unawaited(editor(action));
      return;
    }
    setState(() {
      _recording = action;
      _recordReplace = replace;
      _recordWarning = null;
      _warningAction = null;
      _pending = null;
      _keySearchArmed = false;
    });
  }

  void _cancelRecordingState() {
    _recording = null;
    _recordWarning = null;
    _warningAction = null;
    _pending = null;
  }

  void _warn(ShortcutAction action, String message) {
    setState(() {
      _recordWarning = message;
      _warningAction = action;
    });
  }

  void _cancelRecording() {
    final ShortcutAction? action = _recording ?? _pending?.action;
    setState(_cancelRecordingState);
    if (action != null) _refocusRow(action);
  }

  void _refocusRow(ShortcutAction action) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      FushiFocusRoot.maybeControllerOf(
        context,
      )?.requestById(_rowFocusId(action));
    });
  }

  KeyEventResult _onRecordKey(FocusNode node, KeyEvent event) {
    final ShortcutAction? action = _recording;
    if (action == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final LogicalKeyboardKey key = InputBinding.normalizeCapturedKey(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
    );
    final Set<ModifierKey> modifiers = _pressedModifiers();
    // 裸 Esc = 取消录制（行内录制没有别的出口；要把 Esc 本身绑成快捷键，走
    // 「完整编辑」——那里的捕获区按旧契约把所有键都录下来）。
    if (key == LogicalKeyboardKey.escape && modifiers.isEmpty) {
      _cancelRecording();
      return KeyEventResult.handled;
    }
    if (_device == ShortcutInputDevice.gamepad) {
      // Android 原生手柄按键以 gameButton* KeyEvent 冒泡到这里。
      final GamepadButton? pad = GamepadButton.fromKeyEvent(event);
      if (pad != null) _captured(GamepadBinding(pad));
      return KeyEventResult.handled;
    }
    if (_device != ShortcutInputDevice.keyboard) return KeyEventResult.handled;
    if (ModifierKey.fromKeyboardKey(key) != null) return KeyEventResult.handled;
    _captured(InputBinding(key: key, modifiers: modifiers));
    return KeyEventResult.handled;
  }

  void _onRecordPointerDown(PointerDownEvent event) {
    final ShortcutAction? action = _recording;
    if (action == null || _device != ShortcutInputDevice.mouse) return;
    if (!action.channels.contains(ShortcutChannel.mouse) || !_mouseCapturable) {
      return;
    }
    final int? button = _domButtonFromPointerButtons(event.buttons);
    if (button == null) return;
    final Set<int>? allowed = action.allowedMouseButtons;
    if (allowed != null && !allowed.contains(button)) {
      _warn(action, t.shortcut_mouse_button_not_supported);
      return;
    }
    _captured(MouseBinding(button));
  }

  void _onRecordPointerSignal(PointerSignalEvent event) {
    final ShortcutAction? action = _recording;
    if (action == null || _device != ShortcutInputDevice.mouse) return;
    if (event is! PointerScrollEvent) return;
    if (!action.channels.contains(ShortcutChannel.wheel)) return;
    final double dy = event.scrollDelta.dy;
    if (dy == 0) return;
    final Set<ModifierKey> modifiers = _pressedModifiers();
    if (modifiers.isEmpty) {
      // 裸滚轮永远是滚动内容，绑上去也永不触发。
      _warn(action, t.shortcut_wheel_needs_modifier);
      return;
    }
    _captured(
      WheelBinding(
        dy > 0 ? WheelDirection.down : WheelDirection.up,
        modifiers: modifiers,
      ),
    );
  }

  ShortcutAction? _conflictFor(ShortcutAction action, Object binding) {
    return switch (binding) {
      final InputBinding b => _registry.hasKeyboardConflict(
          action.scope,
          b,
          exclude: action,
        ),
      final GamepadBinding b => _registry.hasGamepadConflict(
          action.scope,
          b,
          exclude: action,
        ),
      final MouseBinding b => _registry.hasMouseConflict(
          action.scope,
          b,
          exclude: action,
        ),
      final WheelBinding b => _registry.hasWheelConflict(
          action.scope,
          b,
          exclude: action,
        ),
      _ => null,
    };
  }

  /// 录到一条绑定：草稿内重复 → 撞键 → 直接写回，三段与编辑对话框同口径。
  void _captured(Object binding) {
    final ShortcutAction? action = _recording;
    if (action == null) return;
    final ShortcutChannel channel = shortcutBindingChannel(binding);
    final List<Object> current = shortcutBindingsInChannel(
      _registry.bindingsFor(action),
      channel,
    );
    if (current.contains(binding) && (!_recordReplace || current.length == 1)) {
      // 已经是它了：替换模式下等于没改，追加模式下给出说明而不是静默。
      setState(() {
        _recording = null;
        _recordWarning =
            _recordReplace ? null : t.shortcut_conflict(s: action.label);
        _warningAction = _recordWarning == null ? null : action;
      });
      _refocusRow(action);
      return;
    }
    final ShortcutAction? conflict = _conflictFor(action, binding);
    if (conflict != null) {
      setState(() {
        _recording = null;
        _recordWarning = null;
        _warningAction = null;
        _pending = _PendingConflict(
          action: action,
          binding: binding,
          conflict: conflict,
          replace: _recordReplace,
        );
      });
      return;
    }
    final bool replace = _recordReplace;
    setState(() {
      _recording = null;
      _recordWarning = null;
      _warningAction = null;
    });
    unawaited(_commit(action, binding, replace: replace));
    _refocusRow(action);
  }

  Future<void> _resolvePending(_InlineConflictChoice choice) async {
    final _PendingConflict? pending = _pending;
    if (pending == null) return;
    setState(() => _pending = null);
    await _commit(
      pending.action,
      pending.binding,
      replace: pending.replace,
      conflict: pending.conflict,
      choice: choice,
    );
    _refocusRow(pending.action);
  }

  /// 写回：本动作该通道换成 / 追加 [binding]；撞键时按 [choice] 处置冲突动作。
  ///
  /// 「替换」直接从冲突动作上剥走这条绑定——不只靠
  /// `updateBindingWithReassignments` 的 co-active 扫描，因为冲突检测还会额外扫
  /// `globalExternal`（OS 级热键抢占），那一侧不在任何 co-active 组里。
  Future<void> _commit(
    ShortcutAction action,
    Object binding, {
    required bool replace,
    ShortcutAction? conflict,
    _InlineConflictChoice choice = _InlineConflictChoice.replace,
  }) async {
    final ShortcutChannel channel = shortcutBindingChannel(binding);
    final ShortcutBindingSet before = _registry.bindingsFor(action);
    final List<Object> previous = shortcutBindingsInChannel(before, channel);
    final List<Object> next = replace
        ? <Object>[binding]
        : <Object>[...previous.where((Object b) => b != binding), binding];
    if (conflict != null && choice != _InlineConflictChoice.keepBoth) {
      final ShortcutBindingSet theirs = _registry.bindingsFor(conflict);
      final List<Object> theirList = shortcutBindingsInChannel(
        theirs,
        channel,
      ).where((Object b) => b != binding).toList();
      if (choice == _InlineConflictChoice.swap &&
          previous.length == 1 &&
          !theirList.contains(previous.single)) {
        theirList.add(previous.single);
      }
      _registry.updateBinding(
        conflict,
        shortcutBindingSetWithChannel(theirs, channel, theirList),
      );
    }
    _registry.updateBinding(
      action,
      shortcutBindingSetWithChannel(before, channel, next),
    );
    await widget.onChanged();
  }

  Future<void> _removeBinding(ShortcutAction action, Object binding) async {
    final ShortcutChannel channel = shortcutBindingChannel(binding);
    final ShortcutBindingSet before = _registry.bindingsFor(action);
    _registry.updateBinding(
      action,
      shortcutBindingSetWithChannel(
        before,
        channel,
        shortcutBindingsInChannel(
          before,
          channel,
        ).where((Object b) => b != binding).toList(),
      ),
    );
    await widget.onChanged();
  }

  Future<void> _resetAction(ShortcutAction action) async {
    _registry.updateBinding(
      action,
      _defaults[action] ?? const ShortcutBindingSet(),
    );
    await widget.onChanged();
    _refocusRow(action);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kShortcutBrowserTwoPaneMinWidth;
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final Map<ShortcutScope, List<ShortcutAction>> rows =
            <ShortcutScope, List<ShortcutAction>>{
          for (final ShortcutScope scope in widget.scopes)
            scope: _visibleActions(scope),
        };
        final Widget header = _buildHeader(context, wide: wide, rows: rows);
        final Widget results = _buildResults(context, rows: rows);
        if (!wide) {
          return Column(
            key: const ValueKey<String>('shortcut-browser-narrow'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header,
              SizedBox(height: tokens.spacing.gap / 2),
              Expanded(child: results),
            ],
          );
        }
        return Column(
          key: const ValueKey<String>('shortcut-browser-wide'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            header,
            SizedBox(height: tokens.spacing.gap),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: kShortcutBrowserNavWidth,
                    child: _buildDomainNav(context, rows: rows),
                  ),
                  SizedBox(width: tokens.spacing.card),
                  Expanded(child: results),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context, {
    required bool wide,
    required Map<ShortcutScope, List<ShortcutAction>> rows,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? accessory = widget.deviceAccessory?.call(_device);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.banner != null) widget.banner!,
        _buildSearchArea(context),
        SizedBox(height: tokens.spacing.gap),
        Row(
          children: <Widget>[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _buildDeviceSelector(context, compact: !wide),
                  ),
                ),
              ),
            ),
            ...widget.toolbarTrailing,
            if (widget.onResetAll != null)
              FushiOverflowMenu<String>(
                key: const ValueKey<String>('shortcut-overflow'),
                onSelected: (String value) {
                  if (value == 'reset-all') unawaited(widget.onResetAll!());
                },
                items: <PopupMenuEntry<String>>[
                  FushiPopupMenuItem<String>(
                    value: 'reset-all',
                    label: t.shortcut_reset_all,
                    icon: FushiIcons.restart,
                  ),
                ],
              ),
          ],
        ),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: accessory == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  child: accessory,
                ),
        ),
        if (!wide) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          _buildDomainChips(context, rows: rows),
        ],
      ],
    );
  }

  Widget _buildSearchArea(BuildContext context) {
    final Widget child;
    if (_keySearchArmed) {
      child = _KeySearchCapture(
        key: const ValueKey<String>('shortcut-key-search-capture'),
        focusNode: _keySearchFocus,
        onKeyEvent: _onKeySearchKey,
        onGamepadButton: (GamepadButton button) =>
            _applyKeyFilter(GamepadBinding(button)),
        onMouseButton: (int button) => _applyKeyFilter(MouseBinding(button)),
        onCancel: _disarmKeySearch,
      );
    } else if (_keyFilter != null) {
      child = _KeyFilterBar(
        key: const ValueKey<String>('shortcut-key-filter'),
        binding: _keyFilter!,
        brand: widget.gamepadBrand,
        onClear: _clearKeyFilter,
        onRearm: _armKeySearch,
      );
    } else {
      child = FushiSearchField(
        key: const ValueKey<String>('shortcut-search'),
        fieldKey: const Key('shortcut_search_field'),
        controller: _queryController,
        focusNode: _queryFocus,
        hintText: t.shortcut_search_hint,
        onChanged: _setQuery,
        onSubmitted: _setQuery,
        onClear: _clearQuery,
        trailing: <Widget>[
          FushiIconButton(
            key: const Key('shortcut_key_search_button'),
            icon: FushiIcons.commandKey,
            tooltip: t.shortcut_search_by_key,
            onTap: _armKeySearch,
          ),
        ],
      );
    }
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// 输入设备分段（M3E 连接式按钮组 / Apple 分段）。窄屏只留图标 + 提示，
  /// 免得与键位图切换、溢出菜单挤成一行放不下。
  Widget _buildDeviceSelector(BuildContext context, {required bool compact}) {
    return FushiAdjustableSegmented<ShortcutInputDevice>(
      key: const Key('shortcut_device_toggle'),
      focusIdPrefix: 'shortcut-device',
      values: ShortcutInputDevice.values,
      selected: _device,
      onChanged: _selectDevice,
      child: adaptiveSegmentedButton<ShortcutInputDevice>(
        context: context,
        segments: <ButtonSegment<ShortcutInputDevice>>[
          for (final ShortcutInputDevice device in ShortcutInputDevice.values)
            ButtonSegment<ShortcutInputDevice>(
              value: device,
              icon: FushiIcon(device.icon, size: 18),
              label: compact ? null : Text(device.label),
              tooltip: device.label,
            ),
        ],
        selected: <ShortcutInputDevice>{_device},
        onSelectionChanged: (Set<ShortcutInputDevice> selection) {
          if (selection.isEmpty) return;
          _selectDevice(selection.first);
        },
        style: kSettingsSegmentedStyle,
      ),
    );
  }

  Widget _buildDomainChips(
    BuildContext context, {
    required Map<ShortcutScope, List<ShortcutAction>> rows,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int total = rows.values.fold<int>(
      0,
      (int s, List<ShortcutAction> l) => s + l.length,
    );
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        key: const ValueKey<String>('shortcut-domain-chips'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            FushiChoiceChip(
              key: const ValueKey<String>('shortcut-domain-all'),
              label: Text('${t.shortcut_domain_all} $total'),
              selected: _domain == null,
              onSelected: (_) => _selectDomain(null),
            ),
            for (final ShortcutScope scope in widget.scopes)
              Padding(
                padding: EdgeInsets.only(left: tokens.spacing.gap / 2),
                child: FushiChoiceChip(
                  key: ValueKey<String>('shortcut-domain-${scope.name}'),
                  label: Text('${scope.label} ${rows[scope]!.length}'),
                  selected: _domain == scope,
                  onSelected: (_) => _selectDomain(scope),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDomainNav(
    BuildContext context, {
    required Map<ShortcutScope, List<ShortcutAction>> rows,
  }) {
    final int total = rows.values.fold<int>(
      0,
      (int s, List<ShortcutAction> l) => s + l.length,
    );
    Widget entry({
      required ShortcutScope? scope,
      required String label,
      required IconData icon,
      required int count,
      required bool modified,
    }) {
      return _DomainNavItem(
        key: ValueKey<String>('shortcut-nav-${scope?.name ?? 'all'}'),
        label: label,
        icon: icon,
        count: count,
        modified: modified,
        selected: _domain == scope,
        onTap: () => _selectDomain(scope),
      );
    }

    return ListView(
      key: const ValueKey<String>('shortcut-domain-nav'),
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom +
            FushiDesignTokens.of(context).spacing.page,
      ),
      children: <Widget>[
        entry(
          scope: null,
          label: t.shortcut_domain_all,
          icon: FushiIcons.apps,
          count: total,
          modified: false,
        ),
        for (final ShortcutScope scope in widget.scopes)
          entry(
            scope: scope,
            label: scope.label,
            icon: _scopeIcon(scope),
            count: rows[scope]!.length,
            modified: ShortcutAction.actionsForScope(scope).any(_isModified),
          ),
      ],
    );
  }

  Widget _buildResults(
    BuildContext context, {
    required Map<ShortcutScope, List<ShortcutAction>> rows,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<ShortcutScope> scopes =
        _domain == null ? widget.scopes : <ShortcutScope>[_domain!];
    final List<Widget> slivers = <Widget>[];
    int rowIndex = 0;
    for (final ShortcutScope scope in scopes) {
      final List<ShortcutAction> actions = rows[scope]!;
      final Widget? override =
          _filtering ? null : widget.scopeBodyOverride?.call(scope, _device);
      if (actions.isEmpty && override == null) continue;
      final List<Widget> extras = _filtering
          ? const <Widget>[]
          : widget.scopeExtras?.call(scope) ?? const <Widget>[];
      final bool readOnly = widget.readOnlyScopes.contains(scope);
      slivers.add(
        SliverMainAxisGroup(
          key: ValueKey<String>('shortcut-group-${scope.name}'),
          slivers: <Widget>[
            PinnedHeaderSliver(
              child: _GroupHeader(
                key: ValueKey<String>('shortcut-group-header-${scope.name}'),
                scope: scope,
                count: actions.length,
                modified: ShortcutAction.actionsForScope(
                  scope,
                ).any(_isModified),
                onReset: readOnly || widget.onResetScope == null
                    ? null
                    : () => widget.onResetScope!(scope),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.card),
                child: AdaptiveSettingsSection(
                  children: <Widget>[
                    ...extras,
                    if (override != null)
                      override
                    else
                      for (final ShortcutAction action in actions)
                        FushiStaggeredEntrance(
                          key: ValueKey<String>('row-${action.name}'),
                          index: rowIndex++,
                          child: _buildRow(context, action, readOnly: readOnly),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (slivers.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyResults(
            key: const ValueKey<String>('shortcut-empty'),
            onClear: _filtering
                ? () {
                    _clearQuery();
                    setState(() => _keyFilter = null);
                  }
                : null,
          ),
        ),
      );
    }
    slivers.add(
      SliverToBoxAdapter(
        child: SizedBox(
          height: MediaQuery.paddingOf(context).bottom + tokens.spacing.page,
        ),
      ),
    );
    return FushiEntranceScope(
      replayKey:
          '${_domain?.name}|${_device.name}|$_keyFilter|${_query.trim()}',
      child: CustomScrollView(
        key: const ValueKey<String>('shortcut-results'),
        controller: _resultsController,
        slivers: slivers,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    ShortcutAction action, {
    required bool readOnly,
  }) {
    final ShortcutBindingSet bindings = _registry.bindingsFor(action);
    final _PendingConflict? pending =
        _pending?.action == action ? _pending : null;
    return _ActionTile(
      key: ValueKey<String>('shortcut-row-${action.name}'),
      action: action,
      bindings: bindings,
      device: _device,
      brand: widget.gamepadBrand,
      readOnly: readOnly,
      modified: _isModified(action),
      recording: _recording == action,
      warning: _recording != action && _warningAction == action
          ? _recordWarning
          : null,
      pending: pending,
      conflictFor: (Object binding) => _conflictFor(action, binding),
      // 点整行 = 改键：该设备只有 0 / 1 条绑定时替换它；已有多条时改为追加，
      // 免得一按就把其余几条一起冲掉（删单条走键帽上的 ×）。
      onEdit: () => _startRecording(
        action,
        replace: shortcutBindingsForDevice(bindings, _device).length <= 1,
      ),
      onAdd: () => _startRecording(action, replace: false),
      onRemove: (Object binding) => unawaited(_removeBinding(action, binding)),
      onReset: () => unawaited(_resetAction(action)),
      onOpenEditor: widget.onOpenEditor == null
          ? null
          : () => unawaited(widget.onOpenEditor!(action)),
      recorder: _recording == action ? _buildRecorder(context) : null,
      onResolve: (_InlineConflictChoice choice) =>
          unawaited(_resolvePending(choice)),
      onCancel: _cancelRecording,
    );
  }

  Widget _buildRecorder(BuildContext context) {
    final String prompt = switch (_device) {
      ShortcutInputDevice.keyboard => t.shortcut_record_prompt,
      ShortcutInputDevice.gamepad => t.shortcut_record_gamepad_prompt,
      ShortcutInputDevice.mouse => t.shortcut_record_mouse_prompt,
    };
    return _InlineRecorder(
      key: const ValueKey<String>('shortcut-recorder'),
      prompt: prompt,
      warning: _warningAction == _recording ? _recordWarning : null,
      onKeyEvent: _onRecordKey,
      onGamepadButton: (GamepadButton button) {
        if (_device == ShortcutInputDevice.gamepad) {
          _captured(GamepadBinding(button));
        }
      },
      onPointerDown: _onRecordPointerDown,
      onPointerSignal: _onRecordPointerSignal,
      onCancel: _cancelRecording,
    );
  }
}

FushiFocusId _rowFocusId(ShortcutAction action) =>
    FushiFocusId('shortcut-row-${action.name}');

IconData _scopeIcon(ShortcutScope scope) => switch (scope) {
      ShortcutScope.global => FushiIcons.globe,
      ShortcutScope.universal => FushiIcons.undo,
      ShortcutScope.globalExternal => FushiIcons.openInNew,
      ShortcutScope.home => FushiIcons.home,
      ShortcutScope.reader => FushiIcons.books,
      ShortcutScope.audiobook => FushiIcons.audiobook,
      ShortcutScope.manga => FushiIcons.readingMode,
      ShortcutScope.video => FushiIcons.video,
      ShortcutScope.gamepad => FushiIcons.games,
      ShortcutScope.dictionaryPopup => FushiIcons.language,
    };

// ---------------------------------------------------------------------------
// Header pieces
// ---------------------------------------------------------------------------

/// 吸顶的分组标题：作用域名 + 条数 + 「恢复默认」。底色与页面一致，滚动时盖住
/// 下面的行。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.scope,
    required this.count,
    required this.modified,
    required this.onReset,
    super.key,
  });

  final ShortcutScope scope;
  final int count;
  final bool modified;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    // 与页面底色一致才能「盖住」滚到它下面的行；页面底是半透明（玻璃）时退回
    // 不透明的分组底色，免得标题下面透出行文字。
    final Color scaffold = theme.scaffoldBackgroundColor;
    final Color background = scaffold.a >= 1
        ? scaffold
        : (glass ? apple.groupedBackground : theme.colorScheme.surface);
    final Color muted =
        glass ? apple.secondaryLabel : tokens.surfaces.onVariant;
    return ColoredBox(
      color: background,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.gap / 2,
          tokens.spacing.gap,
          0,
          tokens.spacing.gap / 2,
        ),
        child: Row(
          children: <Widget>[
            FushiIcon(_scopeIcon(scope), size: 18, color: muted),
            SizedBox(width: tokens.spacing.gap),
            Flexible(
              child: Text(
                scope.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.sectionLabel,
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              child: Text(
                '$count',
                key: ValueKey<int>(count),
                style: tokens.type.metadata.copyWith(color: muted),
              ),
            ),
            if (modified) ...<Widget>[
              SizedBox(width: tokens.spacing.gap / 2),
              const _ModifiedDot(),
            ],
            const Spacer(),
            if (onReset != null)
              FushiTextButton(
                key: ValueKey<String>('shortcut-reset-scope-${scope.name}'),
                onPressed: onReset,
                child: Text(t.shortcut_reset_defaults),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModifiedDot extends StatelessWidget {
  const _ModifiedDot();

  @override
  Widget build(BuildContext context) {
    final Color color = isGlassDesign(context)
        ? appleColorsOf(context).accent
        : Theme.of(context).colorScheme.primary;
    return FushiTooltip(
      message: t.shortcut_modified,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 宽屏左栏的一项：图标 + 名称 + 计数。选中态 M3E = secondaryContainer 全圆角
/// 药丸（形状随选中 morph），Apple = 强调色淡底圆角块。
class _DomainNavItem extends StatelessWidget {
  const _DomainNavItem({
    required this.label,
    required this.icon,
    required this.count,
    required this.modified,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final int count;
  final bool modified;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color muted =
        glass ? apple.secondaryLabel : tokens.surfaces.onVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap / 4),
      child: FushiListItem(
        selected: selected,
        selectedShape: FushiListItemSelectedShape.pill,
        onTap: onTap,
        density: FushiListDensity.compact,
        leading: FushiIcon(
          icon,
          size: 20,
          color: selected
              ? (glass ? apple.accent : theme.colorScheme.onSecondaryContainer)
              : muted,
        ),
        title: Text(label),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (modified) ...<Widget>[
              const _ModifiedDot(),
              SizedBox(width: tokens.spacing.gap / 2),
            ],
            AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              child: Text(
                '$count',
                key: ValueKey<int>(count),
                style: tokens.type.metadata.copyWith(
                  color: count == 0 ? muted.withValues(alpha: 0.5) : muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按键反查的捕获态：占住搜索框的位置，下一次按键 / 手柄按钮 / 鼠标非主键即
/// 成为筛选条件。
class _KeySearchCapture extends StatelessWidget {
  const _KeySearchCapture({
    required this.focusNode,
    required this.onKeyEvent,
    required this.onGamepadButton,
    required this.onMouseButton,
    required this.onCancel,
    super.key,
  });

  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<GamepadButton> onGamepadButton;
  final ValueChanged<int> onMouseButton;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            onGamepadButton(intent.button);
            return true;
          },
        ),
      },
      child: Focus(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: onKeyEvent,
        child: Listener(
          onPointerDown: (PointerDownEvent event) {
            final int? button = _domButtonFromPointerButtons(event.buttons);
            if (button != null) onMouseButton(button);
          },
          child: _CaptureSurface(
            prompt: t.shortcut_search_by_key_prompt,
            onCancel: onCancel,
          ),
        ),
      ),
    );
  }
}

/// 反查结果条：「绑定了这个键的动作」+ 键帽 + 重新按 / 清除。
class _KeyFilterBar extends StatelessWidget {
  const _KeyFilterBar({
    required this.binding,
    required this.brand,
    required this.onClear,
    required this.onRearm,
    super.key,
  });

  final Object binding;
  final GamepadBrand brand;
  final VoidCallback onClear;
  final VoidCallback onRearm;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      decoration: BoxDecoration(
        color:
            glass ? apple.tertiaryFill : theme.colorScheme.secondaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
      ),
      child: Row(
        children: <Widget>[
          FushiIcon(
            FushiIcons.commandKey,
            size: 20,
            color: glass
                ? apple.secondaryLabel
                : theme.colorScheme.onSecondaryContainer,
          ),
          SizedBox(width: tokens.spacing.gap),
          Flexible(
            child: Text(
              t.shortcut_search_by_key_result,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: glass
                    ? apple.label
                    : theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          _BindingKeycap(binding: binding, brand: brand),
          const Spacer(),
          FushiIconButton(
            key: const Key('shortcut_key_search_rearm'),
            icon: FushiIcons.commandKey,
            tooltip: t.shortcut_search_by_key,
            onTap: onRearm,
          ),
          FushiIconButton(
            key: const Key('shortcut_key_filter_clear'),
            icon: FushiIcons.close,
            tooltip: t.clear,
            onTap: onClear,
          ),
        ],
      ),
    );
  }
}

/// 录制 / 反查共用的「请按键」外观：M3E 是 primaryContainer 全圆角胶囊 + 呼吸
/// 圆点，Apple 是 macOS「录制快捷键」的灰底 + 强调色 2px 环。
class _CaptureSurface extends StatelessWidget {
  const _CaptureSurface({
    required this.prompt,
    required this.onCancel,
    this.warning,
  });

  final String prompt;
  final String? warning;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fg = glass ? apple.label : theme.colorScheme.onPrimaryContainer;
    final Color accent = glass ? apple.accent : theme.colorScheme.primary;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.only(
        left: tokens.spacing.card,
        right: tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        color: glass ? apple.tertiaryFill : theme.colorScheme.primaryContainer,
        border: Border.all(color: accent, width: 2),
        borderRadius: BorderRadius.all(Radius.circular(glass ? 10 : 28)),
      ),
      child: Row(
        children: <Widget>[
          _RecordingPulse(color: accent),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  prompt,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
                if (warning != null)
                  Text(
                    warning!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          glass ? apple.destructive : theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          FushiTextButton(
            key: const Key('shortcut_record_cancel'),
            onPressed: onCancel,
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
  }
}

/// 录制中的呼吸圆点；减弱动态效果 / 墨水屏下静止。
class _RecordingPulse extends StatefulWidget {
  const _RecordingPulse({required this.color});

  final Color color;

  @override
  State<_RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<_RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FushiMotion.long * 2,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (fushiMotionEnabled(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: FushiMotion.standard),
      ),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.8, end: 1).animate(
          CurvedAnimation(parent: _controller, curve: FushiMotion.standard),
        ),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 行内录制区：拿焦点吃键盘 / 手柄，Listener 吃鼠标按键与滚轮。每个录制区自带
/// 焦点节点——录制从一行挪到另一行时新旧两个 Focus 同帧共存，共用节点会被
/// 同时 attach 两次。
class _InlineRecorder extends StatefulWidget {
  const _InlineRecorder({
    required this.prompt,
    required this.onKeyEvent,
    required this.onGamepadButton,
    required this.onPointerDown,
    required this.onPointerSignal,
    required this.onCancel,
    super.key,
    this.warning,
  });

  final String prompt;
  final String? warning;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<GamepadButton> onGamepadButton;
  final PointerDownEventListener onPointerDown;
  final void Function(PointerSignalEvent event) onPointerSignal;
  final VoidCallback onCancel;

  @override
  State<_InlineRecorder> createState() => _InlineRecorderState();
}

class _InlineRecorderState extends State<_InlineRecorder> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'shortcut-record');

  @override
  void initState() {
    super.initState();
    // TODO-838 同一个坑：autofocus 要和对话框 / 路由里其它可聚焦物抢主焦点，
    // 输了就会让裸字母键冒泡到全局 Shortcuts 被吞掉。挂载后的这一帧显式要焦点。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 桌面轮询路径：GamepadService 把按键作为 GamepadButtonIntent 分发到主焦点
    // 上下文；返回 true 即阻断 A→Activate / B→返回 / 十字键移焦点等回退。
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            widget.onGamepadButton(intent.button);
            return true;
          },
        ),
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: widget.onKeyEvent,
        child: Listener(
          key: const Key('shortcut_record_region'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: widget.onPointerDown,
          onPointerSignal: widget.onPointerSignal,
          child: _CaptureSurface(
            prompt: widget.prompt,
            warning: widget.warning,
            onCancel: widget.onCancel,
          ),
        ),
      ),
    );
  }
}

/// 内联冲突条：「已被 X 占用」+ 替换 / 交换 / 都保留 / 取消。Esc = 取消。
class _ConflictStrip extends StatelessWidget {
  const _ConflictStrip({
    required this.pending,
    required this.brand,
    required this.canSwap,
    required this.onResolve,
    required this.onCancel,
  });

  final _PendingConflict pending;
  final GamepadBrand brand;
  final bool canSwap;
  final ValueChanged<_InlineConflictChoice> onResolve;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fg = glass ? apple.label : theme.colorScheme.onErrorContainer;
    // 「两者都保留」只在跨 scope 撞键时是真选项（同 scope 时枚举序靠后的那个永远
    // 解析不到），与编辑对话框同一判据。
    final bool keepBoth = pending.conflict.scope != pending.action.scope;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onCancel,
      },
      child: Container(
        key: const ValueKey<String>('shortcut-conflict-strip'),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.gap / 2,
          tokens.spacing.gap / 2,
        ),
        decoration: BoxDecoration(
          color: glass
              ? apple.destructive.withValues(alpha: 0.12)
              : theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.all(Radius.circular(glass ? 10 : 20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiIcon(
                  FushiIcons.warning,
                  size: 18,
                  color: glass ? apple.destructive : theme.colorScheme.error,
                ),
                SizedBox(width: tokens.spacing.gap),
                _BindingKeycap(binding: pending.binding, brand: brand),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Text(
                    t.shortcut_conflict(s: pending.conflict.label),
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap / 2,
              children: <Widget>[
                FushiTextButton(
                  key: const Key('shortcut_conflict_cancel'),
                  onPressed: onCancel,
                  child: Text(t.dialog_cancel),
                ),
                if (keepBoth)
                  FushiTextButton(
                    key: const Key('shortcut_conflict_keep_both'),
                    onPressed: () => onResolve(_InlineConflictChoice.keepBoth),
                    child: Text(t.shortcut_conflict_keep_both),
                  ),
                if (canSwap)
                  FushiTextButton(
                    key: const Key('shortcut_conflict_swap'),
                    onPressed: () => onResolve(_InlineConflictChoice.swap),
                    child: Text(t.shortcut_conflict_swap),
                  ),
                FushiTextButton(
                  key: const Key('shortcut_conflict_replace'),
                  autofocus: true,
                  onPressed: () => onResolve(_InlineConflictChoice.replace),
                  child: Text(t.shortcut_conflict_replace),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({super.key, this.onClear});

  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              FushiIcons.searchOff,
              size: 40,
              color: tokens.surfaces.onVariant,
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.shortcut_no_results,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: tokens.surfaces.onVariant,
              ),
            ),
            if (onClear != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              FushiTextButton(onPressed: onClear, child: Text(t.clear)),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Keycaps
// ---------------------------------------------------------------------------

/// 一条绑定的键帽胶囊：键盘按键拆成一枚枚键帽（Ctrl · Shift · F），手柄用品牌
/// 按钮图标，鼠标 / 滚轮用图标 chip。[conflictWith] 非空时描冲突色边并带提示；
/// [onRemove] 非空时尾部带一个小 ×。
class _BindingKeycap extends StatelessWidget {
  const _BindingKeycap({
    required this.binding,
    super.key,
    required this.brand,
    this.conflictWith,
    this.onRemove,
  });

  final Object binding;
  final GamepadBrand brand;
  final ShortcutAction? conflictWith;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color conflictColor =
        glass ? apple.destructive : theme.colorScheme.error;
    final Widget face = switch (binding) {
      final InputBinding b => _keyboardFaces(context, b),
      final GamepadBinding b => _gamepadFace(b),
      final MouseBinding b => _InputIconChip(icon: b.icon, label: b.label),
      final WheelBinding b => _InputIconChip(icon: b.icon, label: b.label),
      _ => const SizedBox.shrink(),
    };
    Widget result = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        face,
        if (onRemove != null)
          Padding(
            padding: EdgeInsets.only(left: tokens.spacing.gap / 4),
            child: Semantics(
              button: true,
              label: t.shortcut_remove_binding,
              child: InkWell(
                customBorder: const CircleBorder(),
                canRequestFocus: false,
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: FushiIcon(
                    FushiIcons.close,
                    size: 14,
                    color: glass
                        ? apple.secondaryLabel
                        : tokens.surfaces.onVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final ShortcutAction? conflict = conflictWith;
    if (conflict != null) {
      result = FushiTooltip(
        message: t.shortcut_conflict(s: conflict.label),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: conflictColor, width: 1.5),
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: Padding(padding: const EdgeInsets.all(2), child: result),
        ),
      );
    }
    return result;
  }

  Widget _gamepadFace(GamepadBinding binding) {
    final GamepadButton button = binding.button;
    final bool pill = switch (button) {
      GamepadButton.lb ||
      GamepadButton.rb ||
      GamepadButton.lt ||
      GamepadButton.rt ||
      GamepadButton.start ||
      GamepadButton.select =>
        true,
      _ => false,
    };
    return GamepadButtonWidget(
      key: ValueKey<String>('shortcut-pad-${button.label}'),
      button: button,
      brand: brand,
      bound: true,
      diameter: 26,
      shape: pill ? GamepadPadShape.pill : GamepadPadShape.circle,
    );
  }

  Widget _keyboardFaces(BuildContext context, InputBinding binding) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> parts = _keyParts(binding.displayLabel);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < parts.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: tokens.spacing.gap / 4),
          _KeyFace(label: parts[i]),
        ],
      ],
    );
  }
}

/// 把 `Ctrl+Shift+F` 拆成键帽；`Ctrl++`（键本身是加号）末尾的空段还原成 `+`。
List<String> _keyParts(String label) {
  final List<String> raw = label.split('+');
  final List<String> parts = <String>[];
  for (int i = 0; i < raw.length; i++) {
    if (raw[i].isEmpty) {
      if (parts.isEmpty || parts.last != '+') parts.add('+');
      continue;
    }
    parts.add(raw[i]);
  }
  return parts;
}

/// 单枚键帽：M3E 是 secondaryContainer 实底 + 底部 2px 加深台阶，Apple 是
/// tertiaryFill 平顶 + 发丝描边。
class _KeyFace extends StatelessWidget {
  const _KeyFace({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color face = glass ? apple.tertiaryFill : scheme.secondaryContainer;
    final Color fg = glass ? apple.label : scheme.onSecondaryContainer;
    final Color step = glass
        ? apple.separator
        : Color.alphaBlend(
            scheme.shadow.withValues(alpha: 0.18),
            scheme.secondaryContainer,
          );
    return Container(
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap * 0.75),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: face,
        borderRadius: BorderRadius.all(Radius.circular(glass ? 6 : 8)),
        border: glass
            ? Border.all(color: apple.separator, width: 0.8)
            : Border(bottom: BorderSide(color: step, width: 2)),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: tokens.type.metadata.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
