// GENERATED-NOTE: extracted from shortcut_settings_page.dart (shortcut
// settings refactor). Behaviour-preserving: bodies verbatim except the
// label helpers now come from the public extensions in
// `shortcuts/shortcut_labels.dart` (`action.label`). The dialog-only
// helpers `_mouseBindingSupported` / `_domButtonFromPointerButtons`
// moved here with their sole call sites.
part of '../shortcut_settings_page.dart';

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

/// TODO-1088: maps a Flutter [PointerDownEvent.buttons] bitmask to the single DOM
/// `MouseEvent.button` number the runtime `onPointerSeek` dispatch shares with
/// [MouseBinding], or null for the excluded primary button / an unrecognised
/// bitmask. The primary (left) button is deliberately unbindable: the
/// reader/webview runtime handler bails on `e.button === 0` (left is the main
/// interaction key — binding it would swallow normal clicks / text selection),
/// so a left binding could never fire. Checked most-specific first; a chorded
/// press (multiple bits) resolves to the first non-primary button in this
/// precedence: middle(1)/right(2)/back(3)/forward(4).
int? _domButtonFromPointerButtons(int buttons) {
  if (buttons & kMiddleMouseButton != 0) return 1;
  if (buttons & kSecondaryMouseButton != 0) return 2;
  if (buttons & kBackMouseButton != 0) return 3;
  if (buttons & kForwardMouseButton != 0) return 4;
  return null; // primary (kPrimaryMouseButton) or unknown → not bindable
}

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
  final HibikiShortcutRegistry registry;
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
  });

  final ShortcutBindingSet bindings;
  final List<InputBinding> keyboardReassignments;
  final List<GamepadBinding> gamepadReassignments;
  final List<MouseBinding> mouseReassignments;
}

class _ShortcutBindingEditDialogState extends State<ShortcutBindingEditDialog> {
  late List<InputBinding> _keyboard;
  late List<GamepadBinding> _gamepad;
  late List<MouseBinding> _mouse;
  final List<InputBinding> _keyboardReassignments = <InputBinding>[];
  final List<GamepadBinding> _gamepadReassignments = <GamepadBinding>[];
  final List<MouseBinding> _mouseReassignments = <MouseBinding>[];
  String? _conflictWarning;
  bool _capturing = false;
  // TODO-1088: distinct capture phase for mouse buttons — a bordered region that
  // records the next non-primary mouse press. Kept separate from [_capturing]
  // (keyboard) so pressing a key while mouse-capturing doesn't record a key, and
  // vice-versa.
  bool _mouseCapturing = false;
  final FocusNode _captureFocusNode = FocusNode();

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
  }

  @override
  void dispose() {
    _captureFocusNode.dispose();
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

  void _clearAll() {
    setState(() {
      _keyboard.clear();
      _gamepad.clear();
      _mouse.clear();
      _keyboardReassignments.clear();
      _gamepadReassignments.clear();
      _mouseReassignments.clear();
      _conflictWarning = null;
    });
  }

  void _startMouseCapture() {
    setState(() {
      _mouseCapturing = true;
      _capturing = false;
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
      final bool confirmed = await _showConflictReassignmentDialog(conflict);
      if (!confirmed || !mounted) return;
      if (_mouse.contains(binding)) return;
      setState(() {
        _mouse.add(binding);
        if (!_mouseReassignments.contains(binding)) {
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

    final LogicalKeyboardKey key = event.logicalKey;

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
    final bool confirmed = await _showConflictReassignmentDialog(conflict);
    if (!confirmed || !mounted) return;
    if (_keyboard.contains(binding)) return;
    setState(() {
      _keyboard.add(binding);
      if (!_keyboardReassignments.contains(binding)) {
        _keyboardReassignments.add(binding);
      }
      _conflictWarning = null;
    });
  }

  Future<bool> _showConflictReassignmentDialog(
    ShortcutAction conflict,
  ) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: HibikiModalSheetFrame(
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
            body: Text(
              t.shortcut_conflict_replace_confirm(
                s: conflict.label,
              ),
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
                ),
              ],
            ),
          ),
        );
      },
    );
    return confirmed == true;
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
      final bool confirmed = await _showConflictReassignmentDialog(conflict);
      if (!confirmed || !mounted) return;
      if (_gamepad.contains(binding)) return;
      setState(() {
        _gamepad.add(binding);
        if (!_gamepadReassignments.contains(binding)) {
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
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
                  HibikiTagChip(
                    label: _keyboard[i].displayLabel,
                    tone: HibikiTagChipTone.surface,
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
            else
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(t.shortcut_keyboard),
                onPressed: _startCapture,
              ),

            const Divider(height: 24),

            // Gamepad section
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
                  HibikiTagChip(
                    label: _gamepad[i].button.label,
                    tone: HibikiTagChipTone.surface,
                    onDeleted: () => _removeGamepad(i),
                  ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            HibikiOverflowMenu<GamepadButton>(
              onSelected: (GamepadButton button) {
                unawaited(_addGamepad(button));
              },
              items: <PopupMenuEntry<GamepadButton>>[
                for (final GamepadButton btn in GamepadButton.values)
                  HibikiPopupMenuItem<GamepadButton>(
                    label: btn.label,
                    icon: Icons.gamepad_outlined,
                    value: btn,
                  ),
              ],
              padding: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.add,
                      size: 18,
                      color: themeData.colorScheme.primary,
                    ),
                    SizedBox(width: tokens.spacing.gap / 2),
                    Text(
                      t.shortcut_gamepad,
                      style: TextStyle(color: themeData.colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ),

            // Mouse section (TODO-1088): editable. Existing bindings render as
            // deletable chips; on desktop a capture region records the next
            // non-primary mouse press into a binding, reusing the same
            // duplicate/conflict/reassignment path as the keyboard/gamepad
            // channels. On mobile there is no mouse, so the capture entry is
            // hidden and only inherited bindings (if any) show read-only — Never
            // break userspace: nothing captured, nothing lost.
            if (_mouse.isNotEmpty ||
                _mouseBindingSupported(defaultTargetPlatform)) ...<Widget>[
              const Divider(height: 24),
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
              if (_mouseBindingSupported(defaultTargetPlatform)) ...<Widget>[
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
                  ),
                  keyboardReassignments:
                      List<InputBinding>.unmodifiable(_keyboardReassignments),
                  gamepadReassignments:
                      List<GamepadBinding>.unmodifiable(_gamepadReassignments),
                  mouseReassignments:
                      List<MouseBinding>.unmodifiable(_mouseReassignments),
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
