// GENERATED-NOTE: extracted from shortcut_settings_page.dart (shortcut
// settings refactor). Behaviour-preserving: bodies verbatim except the
// label helpers now come from the public extensions in
// `shortcuts/shortcut_labels.dart` (`action.label`). The dialog-only
// helpers `_mouseBindingSupported` / `_domButtonFromPointerButtons`
// moved here with their sole call sites.
part of '../shortcut_settings_page.dart';

/// 撞键时用户的三种处置，替代原来的「换/不换」二选一。
///
/// 为什么必须有 [keepBoth]：撞键**不等于**其中一个必须让出。同一个按钮完全可以同时
/// 留在两个动作上——按下时由解析阶梯（页面 scope 先、global/universal 兜底）决定谁
/// 生效，这正是「右键既是某页面动作、又是上下文菜单默认键」这类配置的正常形态。旧流程
/// 只给「替换」一条路，等于强迫用户先去解绑另一个动作才能配自己想要的键。
enum _ConflictResolution {
  /// 把这个绑定从冲突动作上剥走，只留给当前动作（旧流程的唯一选项）。
  replace,

  /// 两个动作都保留该绑定，按下时按作用域先后仲裁。
  keepBoth,
}

/// TODO-1088: whether the running platform has a mouse whose non-primary buttons
/// can be bound. Desktop (Windows/Linux/macOS) yes; mobile (Android/iOS) has no
/// mouse, so the capture entry is hidden there and the mouse section stays a
/// read-only display of any inherited bindings.
bool _mouseBindingSupported(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// TODO-1088 的按钮折叠规则已提升为共享函数
/// （[domMouseButtonFromPointerButtons]，input_binding.dart）：录制绑定与运行时
/// 分发（查词弹窗表面的 [Listener]，BUG-1269 复诉）必须用同一份规则，否则会
/// 「录到侧键、运行时按另一个号解析」。此处保留同名薄封装，调用点不变。
int? _domButtonFromPointerButtons(int buttons) =>
    domMouseButtonFromPointerButtons(buttons);

// ---------------------------------------------------------------------------
// Edit binding dialog
// ---------------------------------------------------------------------------

class ShortcutBindingEditDialog extends StatefulWidget {
  const ShortcutBindingEditDialog({
    super.key,
    required this.action,
    required this.registry,
    required this.initial,
    this.prefillKey,
    this.prefillButton,
  });

  final ShortcutAction action;
  final FushiShortcutRegistry registry;
  final ShortcutBindingSet initial;

  /// TODO-1060②: 从可视化图上点空白键位进入时预填的逻辑键——打开即把它加进键盘草稿
  /// （不与已有绑定重复时），用户可删可再加，确认才写穿。null = 从列表/编辑图标进入。
  final LogicalKeyboardKey? prefillKey;

  /// 从可视化手柄图上点空白按钮进入时预填的手柄按钮（同上语义）。
  final GamepadButton? prefillButton;

  @override
  State<ShortcutBindingEditDialog> createState() =>
      _ShortcutBindingEditDialogState();
}

@immutable
class ShortcutBindingEditResult {
  const ShortcutBindingEditResult({
    required this.bindings,
    this.keyboardReassignments = const <InputBinding>[],
    this.gamepadReassignments = const <GamepadBinding>[],
    this.mouseReassignments = const <MouseBinding>[],
    this.wheelReassignments = const <WheelBinding>[],
  });

  final ShortcutBindingSet bindings;
  final List<InputBinding> keyboardReassignments;
  final List<GamepadBinding> gamepadReassignments;
  final List<MouseBinding> mouseReassignments;
  final List<WheelBinding> wheelReassignments;
}

class _ShortcutBindingEditDialogState extends State<ShortcutBindingEditDialog> {
  late List<InputBinding> _keyboard;
  late List<GamepadBinding> _gamepad;
  late List<MouseBinding> _mouse;
  late List<WheelBinding> _wheel;
  final List<InputBinding> _keyboardReassignments = <InputBinding>[];
  final List<GamepadBinding> _gamepadReassignments = <GamepadBinding>[];
  final List<MouseBinding> _mouseReassignments = <MouseBinding>[];
  final List<WheelBinding> _wheelReassignments = <WheelBinding>[];
  String? _conflictWarning;
  bool _capturing = false;
  // TODO-1088: distinct capture phase for mouse buttons — a bordered region that
  // records the next non-primary mouse press. Kept separate from [_capturing]
  // (keyboard) so pressing a key while mouse-capturing doesn't record a key, and
  // vice-versa.
  bool _mouseCapturing = false;
  // 滚轮录制：又一个独立捕获相（与键盘/鼠标/手柄互斥）。滚轮事件是 PointerSignal，
  // 不走 onPointerDown，故它有自己的捕获区。
  bool _wheelCapturing = false;
  // 手柄实时录键：与键盘/鼠标同一套「捕获区 + 显式停止」交互（此前手柄是下拉
  // 菜单选按钮，三通道交互割裂）。桌面轮询路径按 [GamepadButtonIntent] 分发到
  // 主焦点，Android 原生路径按 gameButton* KeyEvent 冒泡——捕获区两条都接。
  bool _gamepadCapturing = false;
  final FocusNode _captureFocusNode = FocusNode();
  final FocusNode _gamepadCaptureFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _keyboard = List<InputBinding>.of(widget.initial.keyboardBindings);
    _gamepad = List<GamepadBinding>.of(widget.initial.gamepadBindings);
    // TODO-1060②: seed the draft with the visual-figure-tapped slot so tapping an
    // empty keycap / gamepad button lands directly on this action already carrying
    // that key. Skip if it's already bound to this action (no duplicate chip).
    final LogicalKeyboardKey? pk = widget.prefillKey;
    if (pk != null) {
      final InputBinding seed = InputBinding(key: pk);
      if (!_keyboard.contains(seed)) _keyboard.add(seed);
    }
    final GamepadButton? pb = widget.prefillButton;
    if (pb != null) {
      final GamepadBinding seed = GamepadBinding(pb);
      if (!_gamepad.contains(seed)) _gamepad.add(seed);
    }
    // TODO-1088: mouse bindings are now editable, so seed the draft from the
    // current bindings (was passed straight through from widget.initial before).
    _mouse = List<MouseBinding>.of(widget.initial.mouseBindings);
    _wheel = List<WheelBinding>.of(widget.initial.wheelBindings);
  }

  @override
  void dispose() {
    _captureFocusNode.dispose();
    _gamepadCaptureFocusNode.dispose();
    super.dispose();
  }

  void _removeKeyboard(int index) {
    setState(() {
      final InputBinding removed = _keyboard.removeAt(index);
      _keyboardReassignments.removeWhere(
        (InputBinding binding) => binding == removed,
      );
      _conflictWarning = null;
    });
  }

  void _removeGamepad(int index) {
    setState(() {
      final GamepadBinding removed = _gamepad.removeAt(index);
      _gamepadReassignments.removeWhere(
        (GamepadBinding binding) => binding == removed,
      );
      _conflictWarning = null;
    });
  }

  void _removeMouse(int index) {
    setState(() {
      final MouseBinding removed = _mouse.removeAt(index);
      _mouseReassignments.removeWhere(
        (MouseBinding binding) => binding == removed,
      );
      _conflictWarning = null;
    });
  }

  void _removeWheel(int index) {
    setState(() {
      final WheelBinding removed = _wheel.removeAt(index);
      _wheelReassignments.removeWhere(
        (WheelBinding binding) => binding == removed,
      );
      _conflictWarning = null;
    });
  }

  void _clearAll() {
    setState(() {
      _keyboard.clear();
      _gamepad.clear();
      _mouse.clear();
      _wheel.clear();
      _keyboardReassignments.clear();
      _gamepadReassignments.clear();
      _mouseReassignments.clear();
      _wheelReassignments.clear();
      _conflictWarning = null;
    });
  }

  void _startWheelCapture() {
    setState(() {
      _wheelCapturing = true;
      _capturing = false;
      _mouseCapturing = false;
      _gamepadCapturing = false;
      _conflictWarning = null;
    });
  }

  void _cancelWheelCapture() {
    setState(() => _wheelCapturing = false);
  }

  /// 滚轮捕获区里的一次滚动。修饰键读 [HardwareKeyboard]（PointerScrollEvent 不带
  /// 修饰键位）；**裸滚轮不可绑定**——弹窗里裸滚轮永远是滚动内容，绑了也永不触发，
  /// 故此时保持捕获态并给出提示，而不是记录一条死绑定。
  void _onWheelCapturePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double dy = event.scrollDelta.dy;
    if (dy == 0) return;
    final Set<ModifierKey> modifiers = <ModifierKey>{};
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    if (hw.isControlPressed) modifiers.add(ModifierKey.ctrl);
    if (hw.isShiftPressed) modifiers.add(ModifierKey.shift);
    if (hw.isAltPressed) modifiers.add(ModifierKey.alt);
    if (hw.isMetaPressed) modifiers.add(ModifierKey.meta);
    if (modifiers.isEmpty) {
      setState(() => _conflictWarning = t.shortcut_wheel_needs_modifier);
      return;
    }
    unawaited(_addWheel(WheelBinding(
      dy > 0 ? WheelDirection.down : WheelDirection.up,
      modifiers: modifiers,
    )));
  }

  /// 与 [_addMouse] 同形的三段式：草稿内重复 → 同组冲突 → 确认后重分配。
  Future<void> _addWheel(WheelBinding binding) async {
    if (_wheel.contains(binding)) {
      setState(() {
        _wheelCapturing = false;
        _conflictWarning = t.shortcut_conflict(s: widget.action.label);
      });
      return;
    }

    final ShortcutAction? conflict = widget.registry.hasWheelConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      setState(() {
        _wheelCapturing = false;
        _conflictWarning = t.shortcut_conflict(s: conflict.label);
      });
      final _ConflictResolution? choice =
          await _showConflictReassignmentDialog(conflict);
      if (choice == null || !mounted) return;
      if (_wheel.contains(binding)) return;
      setState(() {
        _wheel.add(binding);
        // keepBoth 时不登记 reassignment（写回阶段才会真的剥走别的动作的绑定）。
        if (choice == _ConflictResolution.replace &&
            !_wheelReassignments.contains(binding)) {
          _wheelReassignments.add(binding);
        }
        _conflictWarning = null;
      });
      return;
    }

    setState(() {
      _wheel.add(binding);
      _wheelCapturing = false;
      _conflictWarning = null;
    });
  }

  void _startMouseCapture() {
    setState(() {
      _mouseCapturing = true;
      _capturing = false;
      _gamepadCapturing = false;
      _conflictWarning = null;
    });
  }

  void _cancelMouseCapture() {
    setState(() => _mouseCapturing = false);
  }

  /// TODO-1088: handle a raw pointer-down inside the mouse-capture region. Maps
  /// the pressed button to its DOM number; the excluded primary button and
  /// unknown bitmasks are ignored (capture stays armed). Delegates to [_addMouse]
  /// which runs the same duplicate/conflict/reassignment flow as gamepad adds.
  void _onMouseCapturePointerDown(PointerDownEvent event) {
    final int? button = _domButtonFromPointerButtons(event.buttons);
    if (button == null) return;
    unawaited(_addMouse(button));
  }

  Future<void> _addMouse(int button) async {
    // 按钮级白名单：通道 gating 只管到「有没有鼠标这条路」，管不到按钮号。不在这里
    // 拒收，`globalExternalLookup` 绑中键/右键就会一路录进去、保存、回显，而消费侧
    // 只认侧键 3/4——按下毫无反应，正是本仓反复警告的「设置里能配、按了没反应」，
    // 比压根没有这个选项更糟。真相源是 [ShortcutAction.allowedMouseButtons]。
    final Set<int>? allowed = widget.action.allowedMouseButtons;
    if (allowed != null && !allowed.contains(button)) {
      setState(() {
        _mouseCapturing = false;
        _conflictWarning = t.shortcut_mouse_button_not_supported;
      });
      return;
    }
    final MouseBinding binding = MouseBinding(button);
    if (_mouse.contains(binding)) {
      setState(() {
        _mouseCapturing = false;
        _conflictWarning = t.shortcut_conflict(s: widget.action.label);
      });
      return;
    }

    final ShortcutAction? conflict = widget.registry.hasMouseConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      setState(() {
        _mouseCapturing = false;
        _conflictWarning = t.shortcut_conflict(s: conflict.label);
      });
      final _ConflictResolution? choice =
          await _showConflictReassignmentDialog(conflict);
      if (choice == null || !mounted) return;
      if (_mouse.contains(binding)) return;
      setState(() {
        _mouse.add(binding);
        // keepBoth 时不登记 reassignment（写回阶段才会真的剥走别的动作的绑定）。
        if (choice == _ConflictResolution.replace &&
            !_mouseReassignments.contains(binding)) {
          _mouseReassignments.add(binding);
        }
        _conflictWarning = null;
      });
      return;
    }

    setState(() {
      _mouse.add(binding);
      _mouseCapturing = false;
      _conflictWarning = null;
    });
  }

  void _startCapture() {
    setState(() {
      _capturing = true;
      _mouseCapturing = false;
      _gamepadCapturing = false;
      _conflictWarning = null;
    });
    // TODO-838: the capture Focus lives in the `if (_capturing)` subtree, which
    // is only built on the NEXT frame after this setState. Requesting focus here
    // (synchronously) targets a not-yet-attached node and is a no-op, leaving
    // only `autofocus: true` to race the dialog/route's other focusables for
    // primary focus — intermittently the capture node loses, bare letter/digit
    // keys bubble to the global Shortcuts and get dropped ("按了没反应"). Defer
    // the request to a post-frame callback so the node is mounted first, making
    // focus acquisition deterministic.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_capturing) return;
      _captureFocusNode.requestFocus();
    });
  }

  void _cancelCapture() {
    setState(() => _capturing = false);
  }

  // While capturing, every key event is consumed (KeyEventResult.handled) so
  // keys such as Tab, Enter and Escape are recorded as bindings instead of
  // leaking to focus traversal, the dialog's default button or the dismiss
  // intent. Capture is aborted via the explicit cancel control, not a key.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    // BUG-1422：IME（Windows 微软输入法）激活时引擎把 logicalKey 改写成
    // LogicalKeyboardKey.process，物理键不受影响。运行时解析
    // (FushiShortcutRegistry.resolveKeyboard) 早有这条回退，录入侧必须用同一条
    // 契约，否则物理 Z 会被存成 `Process` —— 既显示成看不懂的键，运行时也永远
    // 匹配不上，用户看到的是「录不进去 / 录完没反应」。
    final LogicalKeyboardKey key = InputBinding.normalizeCapturedKey(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
    );

    // Wait for a non-modifier key; a bare modifier press keeps capturing.
    if (ModifierKey.fromKeyboardKey(key) != null) {
      return KeyEventResult.handled;
    }

    final Set<ModifierKey> modifiers = <ModifierKey>{};
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    if (hw.isControlPressed) modifiers.add(ModifierKey.ctrl);
    if (hw.isShiftPressed) modifiers.add(ModifierKey.shift);
    if (hw.isAltPressed) modifiers.add(ModifierKey.alt);
    if (hw.isMetaPressed) modifiers.add(ModifierKey.meta);

    final InputBinding binding = InputBinding(key: key, modifiers: modifiers);

    // Check for duplicates within the current draft.
    // HBK-AUDIT-155: explain the abort instead of silently stopping capture
    // (mirrors the cross-action conflict branch below). A duplicate here means
    // the binding is already assigned to THIS action, so surface that.
    if (_keyboard.contains(binding)) {
      setState(() {
        _capturing = false;
        _conflictWarning = t.shortcut_conflict(s: widget.action.label);
      });
      return KeyEventResult.handled;
    }

    // Check for conflicts in the same scope.
    final ShortcutAction? conflict = widget.registry.hasKeyboardConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      unawaited(_confirmKeyboardReassignment(binding, conflict));
      return KeyEventResult.handled;
    }

    setState(() {
      _keyboard.add(binding);
      _capturing = false;
      _conflictWarning = null;
    });
    return KeyEventResult.handled;
  }

  Future<void> _confirmKeyboardReassignment(
    InputBinding binding,
    ShortcutAction conflict,
  ) async {
    setState(() {
      _capturing = false;
      _conflictWarning = t.shortcut_conflict(s: conflict.label);
    });
    final _ConflictResolution? choice =
        await _showConflictReassignmentDialog(conflict);
    if (choice == null || !mounted) return;
    if (_keyboard.contains(binding)) return;
    setState(() {
      _keyboard.add(binding);
      // keepBoth 时**不**登记 reassignment：写回阶段的 removeKeyboardConflicts 才是
      // 「把这个键从别的动作上剥走」的执行体，不登记就等于两个动作都留着。
      if (choice == _ConflictResolution.replace &&
          !_keyboardReassignments.contains(binding)) {
        _keyboardReassignments.add(binding);
      }
      _conflictWarning = null;
    });
  }

  Future<_ConflictResolution?> _showConflictReassignmentDialog(
    ShortcutAction conflict,
  ) async {
    // 「两者都保留」只在**跨 scope** 撞键时是真选项。
    //
    // 同一个 scope 里撞键，解析（`ShortcutRegistry.resolveMouse`）按枚举声明序返回第一个
    // 命中，枚举序靠后的那个**永远解析不到**——而设置页两处都亮着同一个键，用户无从
    // 判断哪个是死的。仓库自己的守卫 `shortcut_defaults_test` 对这种状态的失败信息
    // 原文就是 `the later one is shadowed`。
    //
    // 注意 `video` / `manga` / `gamepad` / `universal` / `globalExternal` /
    // `dictionaryPopup` 六个 scope 的 coactiveScopes **就是它自己**，所以这些 scope 里
    // 任何撞键都是同 scope 撞键，全都落进这个分支。
    final bool keepBothResolvable = conflict.scope != widget.action.scope;
    return showAppDialog<_ConflictResolution>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: FushiModalSheetFrame(
            title: t.shortcut_conflict(s: conflict.label),
            leadingIcon: Icons.warning_amber_outlined,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.shortcut_conflict_replace_confirm(
                    s: conflict.label,
                  ),
                ),
                // 提示文案说的是「由作用域先后仲裁」——同 scope 时没有这回事，
                // 连提示带按钮一起收起来，别给用户一个造不出正确结果的选项。
                if (keepBothResolvable) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(
                    t.shortcut_conflict_keep_both_hint,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text(t.dialog_cancel),
                ),
                if (keepBothResolvable)
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () =>
                        Navigator.pop(ctx, _ConflictResolution.keepBoth),
                    child: Text(t.shortcut_conflict_keep_both),
                  ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () =>
                      Navigator.pop(ctx, _ConflictResolution.replace),
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _startGamepadCapture() {
    setState(() {
      _gamepadCapturing = true;
      _capturing = false;
      _mouseCapturing = false;
      _conflictWarning = null;
    });
    // Mirror TODO-838: the capture Focus subtree only exists on the NEXT frame,
    // so a synchronous requestFocus is a no-op; defer to a post-frame callback
    // so the gamepad's intent dispatch (which targets the primary focus
    // context) deterministically lands on the capture region.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_gamepadCapturing) return;
      _gamepadCaptureFocusNode.requestFocus();
    });
  }

  void _cancelGamepadCapture() {
    setState(() => _gamepadCapturing = false);
  }

  /// 捕获到一次手柄按键：结束捕获态并复用 [_addGamepad] 的
  /// 重复检测 → 冲突查询 → 重分配确认三段式（不造第二套写入逻辑）。
  void _recordCapturedGamepadButton(GamepadButton button) {
    if (!_gamepadCapturing) return;
    setState(() => _gamepadCapturing = false);
    unawaited(_addGamepad(button));
  }

  // While gamepad-capturing, every key event is consumed (mirrors the keyboard
  // capture contract) so controller presses that arrive as gameButton* key
  // events (Android's native path) are recorded here instead of leaking to
  // focus traversal / global navigation, and stray keyboard presses do nothing.
  // Capture is aborted via the explicit cancel control, not a key.
  KeyEventResult _onGamepadCaptureKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final GamepadButton? button = GamepadButton.fromKeyEvent(event);
    if (button != null) _recordCapturedGamepadButton(button);
    return KeyEventResult.handled;
  }

  Future<void> _addGamepad(GamepadButton button) async {
    final GamepadBinding binding = GamepadBinding(button);
    if (_gamepad.contains(binding)) return;

    final ShortcutAction? conflict = widget.registry.hasGamepadConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      setState(() {
        _conflictWarning = t.shortcut_conflict(s: conflict.label);
      });
      final _ConflictResolution? choice =
          await _showConflictReassignmentDialog(conflict);
      if (choice == null || !mounted) return;
      if (_gamepad.contains(binding)) return;
      setState(() {
        _gamepad.add(binding);
        // keepBoth 时不登记 reassignment（写回阶段才会真的剥走别的动作的绑定）。
        if (choice == _ConflictResolution.replace &&
            !_gamepadReassignments.contains(binding)) {
          _gamepadReassignments.add(binding);
        }
        _conflictWarning = null;
      });
      return;
    }

    setState(() {
      _gamepad.add(binding);
      _conflictWarning = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData themeData = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 只渲染这个 scope 真正会被消费的通道（见 [ShortcutScope.channels]）：查词弹窗
    // 的词条导航只由弹窗 WebView 的滚轮触发，给它键盘/手柄入口等于制造死绑定。
    // 已有绑定即使通道被关也照常显示（历史快照不隐身，可删）。
    // **按 action 而不是 scope 取通道**：通道能力是 scope 级声明，个别动作会继承到
    // 没有派发点的通道（globalContextMenu 的 keyboard/gamepad）。下面 show* 的
    // isNotEmpty 兜底保留——历史快照里已存在的绑定仍要可见可删。
    final Set<ShortcutChannel> channels = widget.action.channels;
    final bool showKeyboard =
        channels.contains(ShortcutChannel.keyboard) || _keyboard.isNotEmpty;
    final bool showGamepad =
        channels.contains(ShortcutChannel.gamepad) || _gamepad.isNotEmpty;
    final bool showWheel =
        channels.contains(ShortcutChannel.wheel) || _wheel.isNotEmpty;

    // 「显示」与「可新增」是两回事：上面的 show* 带上 `isNotEmpty`，让通道被摘掉的
    // scope 上历史快照里的绑定仍然可见、可删（Never break userspace——否则那条永不
    // 触发的死绑定反而永远删不掉）；但**新增入口只认通道是否开放**，否则用户还能
    // 继续往没有解析入口的通道里塞永不触发的绑定，正是
    // `shortcut_channel_wiring_guard_test` 要根除的那件事。
    final bool canAddKeyboard = channels.contains(ShortcutChannel.keyboard);
    final bool canAddGamepad = channels.contains(ShortcutChannel.gamepad);
    // 鼠标额外要求平台真有非主键鼠标（移动端只读不加，TODO-1088 既有契约）。
    final bool canAddMouse = channels.contains(ShortcutChannel.mouse) &&
        _mouseBindingSupported(defaultTargetPlatform);
    final bool canAddWheel = channels.contains(ShortcutChannel.wheel);

    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: widget.action.label,
        leadingIcon: Icons.keyboard_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Keyboard section
            if (showKeyboard) ...<Widget>[
              Text(
                t.shortcut_keyboard,
                style: themeData.textTheme.labelLarge,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Wrap(
                spacing: tokens.spacing.gap / 2,
                runSpacing: tokens.spacing.gap / 2,
                children: <Widget>[
                  for (int i = 0; i < _keyboard.length; i++)
                    FushiTagChip(
                      label: _keyboard[i].displayLabel,
                      tone: FushiTagChipTone.surface,
                      onDeleted: () => _removeKeyboard(i),
                    ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              if (_capturing)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Focus(
                      focusNode: _captureFocusNode,
                      autofocus: true,
                      onKeyEvent: _onKeyEvent,
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          vertical: tokens.spacing.gap + 4,
                          horizontal: tokens.spacing.gap,
                        ),
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: themeData.colorScheme.primary),
                          borderRadius: tokens.radii.controlRadius,
                        ),
                        child: Text(
                          t.shortcut_press_key,
                          textAlign: TextAlign.center,
                          style: themeData.textTheme.bodyMedium?.copyWith(
                            color: themeData.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('shortcut_stop_capture'),
                        onPressed: _cancelCapture,
                        child: Text(t.shortcut_stop_capture),
                      ),
                    ),
                  ],
                )
              else if (canAddKeyboard)
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(t.shortcut_keyboard),
                  onPressed: _startCapture,
                ),
            ],

            // Gamepad section
            if (showGamepad) ...<Widget>[
              if (showKeyboard) const Divider(height: 24),
              Text(
                t.shortcut_gamepad,
                style: themeData.textTheme.labelLarge,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Wrap(
                spacing: tokens.spacing.gap / 2,
                runSpacing: tokens.spacing.gap / 2,
                children: <Widget>[
                  for (int i = 0; i < _gamepad.length; i++)
                    FushiTagChip(
                      label: _gamepad[i].button.label,
                      tone: FushiTagChipTone.surface,
                      onDeleted: () => _removeGamepad(i),
                    ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              if (_gamepadCapturing)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // 桌面轮询路径：GamepadService 把按键作为 GamepadButtonIntent
                    // 分发到主焦点上下文；这里在捕获 Focus 之上挂 Actions 消费，
                    // 返回 true 即阻断 A→Activate / B→返回 / 十字键→移焦点等回退。
                    Actions(
                      actions: <Type, Action<Intent>>{
                        GamepadButtonIntent:
                            CallbackAction<GamepadButtonIntent>(
                          onInvoke: (GamepadButtonIntent intent) {
                            _recordCapturedGamepadButton(intent.button);
                            return true;
                          },
                        ),
                      },
                      child: Focus(
                        focusNode: _gamepadCaptureFocusNode,
                        autofocus: true,
                        onKeyEvent: _onGamepadCaptureKeyEvent,
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                            vertical: tokens.spacing.gap + 4,
                            horizontal: tokens.spacing.gap,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: themeData.colorScheme.primary,
                            ),
                            borderRadius: tokens.radii.controlRadius,
                          ),
                          child: Text(
                            t.shortcut_press_gamepad,
                            textAlign: TextAlign.center,
                            style: themeData.textTheme.bodyMedium?.copyWith(
                              color: themeData.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('shortcut_stop_gamepad_capture'),
                        onPressed: _cancelGamepadCapture,
                        child: Text(t.shortcut_stop_capture),
                      ),
                    ),
                  ],
                )
              else if (canAddGamepad)
                Wrap(
                  spacing: tokens.spacing.gap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    TextButton.icon(
                      key: const Key('shortcut_add_gamepad_capture'),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(t.shortcut_gamepad),
                      onPressed: _startGamepadCapture,
                    ),
                    // 无手柄在手/远程配置时的兜底：仍可从列表点选按钮。
                    FushiOverflowMenu<GamepadButton>(
                      onSelected: (GamepadButton button) {
                        unawaited(_addGamepad(button));
                      },
                      items: <PopupMenuEntry<GamepadButton>>[
                        for (final GamepadButton btn in GamepadButton.values)
                          FushiPopupMenuItem<GamepadButton>(
                            label: btn.label,
                            icon: Icons.gamepad_outlined,
                            value: btn,
                          ),
                      ],
                      padding: EdgeInsets.zero,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: tokens.spacing.gap / 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.list_outlined,
                              size: 18,
                              color: themeData.colorScheme.primary,
                            ),
                            SizedBox(width: tokens.spacing.gap / 2),
                            Text(
                              t.shortcut_gamepad_pick_list,
                              style: TextStyle(
                                color: themeData.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
            ],

            // Mouse section (TODO-1088): editable. Existing bindings render as
            // deletable chips; on desktop a capture region records the next
            // non-primary mouse press into a binding, reusing the same
            // duplicate/conflict/reassignment path as the keyboard/gamepad
            // channels. On mobile there is no mouse, so the capture entry is
            // hidden and only inherited bindings (if any) show read-only — Never
            // break userspace: nothing captured, nothing lost.
            if (_mouse.isNotEmpty || canAddMouse) ...<Widget>[
              if (showKeyboard || showGamepad) const Divider(height: 24),
              Text(
                t.shortcut_mouse_button,
                style: themeData.textTheme.labelLarge,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Wrap(
                spacing: tokens.spacing.gap / 2,
                runSpacing: tokens.spacing.gap / 2,
                children: <Widget>[
                  for (int i = 0; i < _mouse.length; i++)
                    _MouseChip(
                      binding: _mouse[i],
                      onDeleted: () => _removeMouse(i),
                    ),
                ],
              ),
              if (canAddMouse) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                if (_mouseCapturing)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Listener(
                        key: const Key('shortcut_mouse_capture_region'),
                        onPointerDown: _onMouseCapturePointerDown,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                            vertical: tokens.spacing.gap + 4,
                            horizontal: tokens.spacing.gap,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: themeData.colorScheme.primary,
                            ),
                            borderRadius: tokens.radii.controlRadius,
                          ),
                          child: Text(
                            t.shortcut_press_mouse_button,
                            textAlign: TextAlign.center,
                            style: themeData.textTheme.bodyMedium?.copyWith(
                              color: themeData.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const Key('shortcut_stop_mouse_capture'),
                          onPressed: _cancelMouseCapture,
                          child: Text(t.shortcut_stop_capture),
                        ),
                      ),
                    ],
                  )
                else
                  TextButton.icon(
                    key: const Key('shortcut_add_mouse'),
                    icon: const Icon(Icons.mouse_outlined, size: 18),
                    label: Text(t.shortcut_mouse_button),
                    onPressed: _startMouseCapture,
                  ),
              ],
            ],

            // 滚轮章节：修饰键 + 滚轮方向（查词弹窗的「上/下一个词条」）。捕获区吃
            // PointerSignal 而非 PointerDown，其余（重复/冲突/重分配/删除 chip）与
            // 键盘、手柄、鼠标三条完全同形。移动端没有滚轮，但 Android 可外接鼠标，
            // 故这里不按平台隐藏——按 scope 的通道能力隐藏（见上）。
            if (showWheel) ...<Widget>[
              if (showKeyboard ||
                  showGamepad ||
                  _mouse.isNotEmpty ||
                  channels.contains(ShortcutChannel.mouse))
                const Divider(height: 24),
              Text(
                t.shortcut_wheel,
                style: themeData.textTheme.labelLarge,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Wrap(
                spacing: tokens.spacing.gap / 2,
                runSpacing: tokens.spacing.gap / 2,
                children: <Widget>[
                  for (int i = 0; i < _wheel.length; i++)
                    _InputIconChip(
                      icon: _wheel[i].icon,
                      label: _wheel[i].label,
                      onDeleted: () => _removeWheel(i),
                    ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              if (_wheelCapturing)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Listener(
                      key: const Key('shortcut_wheel_capture_region'),
                      onPointerSignal: _onWheelCapturePointerSignal,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          vertical: tokens.spacing.gap + 4,
                          horizontal: tokens.spacing.gap,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: themeData.colorScheme.primary,
                          ),
                          borderRadius: tokens.radii.controlRadius,
                        ),
                        child: Text(
                          t.shortcut_press_wheel,
                          textAlign: TextAlign.center,
                          style: themeData.textTheme.bodyMedium?.copyWith(
                            color: themeData.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('shortcut_stop_wheel_capture'),
                        onPressed: _cancelWheelCapture,
                        child: Text(t.shortcut_stop_capture),
                      ),
                    ),
                  ],
                )
              else if (canAddWheel)
                TextButton.icon(
                  key: const Key('shortcut_add_wheel'),
                  icon: const Icon(Icons.mouse_outlined, size: 18),
                  label: Text(t.shortcut_wheel),
                  onPressed: _startWheelCapture,
                ),
            ],

            // Conflict warning
            if (_conflictWarning != null) ...[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _conflictWarning!,
                style: themeData.textTheme.bodySmall?.copyWith(
                  color: themeData.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            TextButton(
              onPressed: _clearAll,
              child: Text(t.shortcut_clear),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.pop(
                context,
                ShortcutBindingEditResult(
                  bindings: ShortcutBindingSet(
                    keyboardBindings:
                        List<InputBinding>.unmodifiable(_keyboard),
                    gamepadBindings:
                        List<GamepadBinding>.unmodifiable(_gamepad),
                    mouseBindings: List<MouseBinding>.unmodifiable(_mouse),
                    wheelBindings: List<WheelBinding>.unmodifiable(_wheel),
                  ),
                  keyboardReassignments:
                      List<InputBinding>.unmodifiable(_keyboardReassignments),
                  gamepadReassignments:
                      List<GamepadBinding>.unmodifiable(_gamepadReassignments),
                  mouseReassignments:
                      List<MouseBinding>.unmodifiable(_mouseReassignments),
                  wheelReassignments:
                      List<WheelBinding>.unmodifiable(_wheelReassignments),
                ),
              ),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
