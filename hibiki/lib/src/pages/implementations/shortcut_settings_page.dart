import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_preferences.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// Localised label for a [ShortcutAction].
String _actionLabel(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.readerPageForward:
      return t.shortcut_action_reader_page_forward;
    case ShortcutAction.readerPageBackward:
      return t.shortcut_action_reader_page_backward;
    case ShortcutAction.readerToggleChrome:
      return t.shortcut_action_reader_toggle_chrome;
    case ShortcutAction.readerDismissDict:
      return t.shortcut_action_reader_dismiss_dict;
    case ShortcutAction.readerToggleBookmark:
      return t.shortcut_action_reader_toggle_bookmark;
    case ShortcutAction.homeTabBooks:
      return t.shortcut_action_home_tab_books;
    case ShortcutAction.homeTabDict:
      return t.shortcut_action_home_tab_dict;
    case ShortcutAction.homeTabSettings:
      return t.shortcut_action_home_tab_settings;
    case ShortcutAction.homeFocusSearch:
      return t.shortcut_action_home_focus_search;
    case ShortcutAction.globalBack:
      return t.shortcut_action_global_back;
    case ShortcutAction.audiobookPlayPause:
      return t.shortcut_action_audiobook_play_pause;
    case ShortcutAction.audiobookNextSentence:
      return t.shortcut_action_audiobook_next_sentence;
    case ShortcutAction.audiobookPrevSentence:
      return t.shortcut_action_audiobook_prev_sentence;
  }
}

/// Localised label for a [ShortcutScope].
String _scopeLabel(ShortcutScope scope) {
  switch (scope) {
    case ShortcutScope.reader:
      return t.shortcut_scope_reader;
    case ShortcutScope.home:
      return t.shortcut_scope_home;
    case ShortcutScope.global:
      return t.shortcut_scope_global;
    case ShortcutScope.audiobook:
      return t.shortcut_scope_audiobook;
  }
}

class ShortcutSettingsPage extends BasePage {
  const ShortcutSettingsPage({super.key});

  @override
  BasePageState<ShortcutSettingsPage> createState() =>
      _ShortcutSettingsPageState();
}

class _ShortcutSettingsPageState extends BasePageState<ShortcutSettingsPage> {
  HibikiShortcutRegistry get _registry => appModel.shortcutRegistry;

  Future<void> _save() async {
    await saveShortcutRegistry(
      _registry,
      ReaderHibikiSource.instance,
    );
  }

  Future<void> _confirmResetScope(ShortcutScope scope) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.shortcut_reset_defaults),
        content: Text(t.shortcut_reset_confirm),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDefaultAction: true,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.shortcut_reset_defaults),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _registry.resetScopeToDefaults(scope, defaultTargetPlatform);
    await _save();
    setState(() {});
  }

  Future<void> _editBinding(ShortcutAction action) async {
    final ShortcutBindingSet? result = await showAppDialog<ShortcutBindingSet>(
      context: context,
      builder: (BuildContext ctx) => _EditBindingDialog(
        action: action,
        registry: _registry,
        initial: _registry.bindingsFor(action),
      ),
    );
    if (result == null || !mounted) return;
    _registry.updateBinding(action, result);
    await _save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.shortcut_settings_title)),
      body: ListView(
        children: <Widget>[
          for (final ShortcutScope scope in ShortcutScope.values) ...[
            _ScopeSectionHeader(
              scope: scope,
              onReset: () => _confirmResetScope(scope),
            ),
            for (final ShortcutAction action
                in ShortcutAction.actionsForScope(scope))
              _ActionTile(
                action: action,
                bindings: _registry.bindingsFor(action),
                onEdit: () => _editBinding(action),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header with scope name + reset button
// ---------------------------------------------------------------------------

class _ScopeSectionHeader extends StatelessWidget {
  const _ScopeSectionHeader({
    required this.scope,
    required this.onReset,
  });

  final ShortcutScope scope;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _scopeLabel(scope),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.primary,
                  ),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.restore, size: 18),
            label: Text(t.shortcut_reset_defaults),
            onPressed: onReset,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row for a single action
// ---------------------------------------------------------------------------

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.action,
    required this.bindings,
    required this.onEdit,
  });

  final ShortcutAction action;
  final ShortcutBindingSet bindings;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final List<String> labels = <String>[
      ...bindings.keyboardBindings.map((InputBinding b) => b.displayLabel),
      ...bindings.gamepadBindings.map((GamepadBinding b) => b.button.label),
    ];

    return ListTile(
      title: Text(_actionLabel(action)),
      subtitle: labels.isEmpty
          ? Text(
              t.shortcut_none,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              children: labels
                  .map((String label) => Chip(
                        label: Text(label),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                      ))
                  .toList(growable: false),
            ),
      trailing: IconButton(
        icon: const Icon(Icons.edit_outlined),
        onPressed: onEdit,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit binding dialog
// ---------------------------------------------------------------------------

class _EditBindingDialog extends StatefulWidget {
  const _EditBindingDialog({
    required this.action,
    required this.registry,
    required this.initial,
  });

  final ShortcutAction action;
  final HibikiShortcutRegistry registry;
  final ShortcutBindingSet initial;

  @override
  State<_EditBindingDialog> createState() => _EditBindingDialogState();
}

class _EditBindingDialogState extends State<_EditBindingDialog> {
  late List<InputBinding> _keyboard;
  late List<GamepadBinding> _gamepad;
  String? _conflictWarning;
  bool _capturing = false;
  final FocusNode _captureFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _keyboard = List<InputBinding>.of(widget.initial.keyboardBindings);
    _gamepad = List<GamepadBinding>.of(widget.initial.gamepadBindings);
  }

  @override
  void dispose() {
    _captureFocusNode.dispose();
    super.dispose();
  }

  void _removeKeyboard(int index) {
    setState(() {
      _keyboard.removeAt(index);
      _conflictWarning = null;
    });
  }

  void _removeGamepad(int index) {
    setState(() {
      _gamepad.removeAt(index);
      _conflictWarning = null;
    });
  }

  void _clearAll() {
    setState(() {
      _keyboard.clear();
      _gamepad.clear();
      _conflictWarning = null;
    });
  }

  void _startCapture() {
    setState(() {
      _capturing = true;
      _conflictWarning = null;
    });
    _captureFocusNode.requestFocus();
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    final LogicalKeyboardKey key = event.logicalKey;

    // Ignore bare modifier presses.
    if (ModifierKey.fromKeyboardKey(key) != null) return;

    final Set<ModifierKey> modifiers = <ModifierKey>{};
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    if (hw.isControlPressed) modifiers.add(ModifierKey.ctrl);
    if (hw.isShiftPressed) modifiers.add(ModifierKey.shift);
    if (hw.isAltPressed) modifiers.add(ModifierKey.alt);
    if (hw.isMetaPressed) modifiers.add(ModifierKey.meta);

    final InputBinding binding = InputBinding(key: key, modifiers: modifiers);

    // Check for duplicates within the current draft.
    if (_keyboard.contains(binding)) {
      setState(() => _capturing = false);
      return;
    }

    // Check for conflicts in the same scope.
    final ShortcutAction? conflict = widget.registry.hasKeyboardConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      setState(() {
        _capturing = false;
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(conflict));
      });
      return;
    }

    setState(() {
      _keyboard.add(binding);
      _capturing = false;
      _conflictWarning = null;
    });
  }

  void _addGamepad(GamepadButton button) {
    final GamepadBinding binding = GamepadBinding(button);
    if (_gamepad.contains(binding)) return;

    final ShortcutAction? conflict = widget.registry.hasGamepadConflict(
      widget.action.scope,
      binding,
      exclude: widget.action,
    );

    if (conflict != null) {
      setState(() {
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(conflict));
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

    return adaptiveAlertDialog(
      context: context,
      title: Text(_actionLabel(widget.action)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Keyboard section
            Text(
              t.shortcut_keyboard,
              style: themeData.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (int i = 0; i < _keyboard.length; i++)
                  Chip(
                    label: Text(_keyboard[i].displayLabel),
                    onDeleted: () => _removeKeyboard(i),
                    deleteIconColor: themeData.colorScheme.error,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_capturing)
              KeyboardListener(
                focusNode: _captureFocusNode,
                autofocus: true,
                onKeyEvent: _onKeyEvent,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: themeData.colorScheme.primary),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    t.shortcut_press_key,
                    textAlign: TextAlign.center,
                    style: themeData.textTheme.bodyMedium?.copyWith(
                      color: themeData.colorScheme.primary,
                    ),
                  ),
                ),
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
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (int i = 0; i < _gamepad.length; i++)
                  Chip(
                    label: Text(_gamepad[i].button.label),
                    onDeleted: () => _removeGamepad(i),
                    deleteIconColor: themeData.colorScheme.error,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            PopupMenuButton<GamepadButton>(
              onSelected: _addGamepad,
              itemBuilder: (_) => <PopupMenuEntry<GamepadButton>>[
                for (final GamepadButton btn in GamepadButton.values)
                  PopupMenuItem<GamepadButton>(
                    value: btn,
                    child: Text(btn.label),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.add,
                      size: 18,
                      color: themeData.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      t.shortcut_gamepad,
                      style: TextStyle(color: themeData.colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ),

            // Conflict warning
            if (_conflictWarning != null) ...[
              const SizedBox(height: 8),
              Text(
                _conflictWarning!,
                style: themeData.textTheme.bodySmall?.copyWith(
                  color: themeData.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
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
            ShortcutBindingSet(
              keyboardBindings: List<InputBinding>.unmodifiable(_keyboard),
              gamepadBindings: List<GamepadBinding>.unmodifiable(_gamepad),
            ),
          ),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
