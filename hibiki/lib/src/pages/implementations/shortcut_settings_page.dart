import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
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
    case ShortcutAction.readerToggleFurigana:
      return t.shortcut_action_reader_toggle_furigana;
    case ShortcutAction.readerLookupAtCursor:
      return t.shortcut_action_reader_lookup_at_cursor;
    case ShortcutAction.readerShiftLookup:
      return t.shortcut_action_reader_shift_lookup;
    case ShortcutAction.readerCreateCardFromPopup:
      return t.shortcut_action_reader_create_card_from_popup;
    case ShortcutAction.homeTabBooks:
      return t.shortcut_action_home_tab_books;
    case ShortcutAction.homeTabDict:
      return t.shortcut_action_home_tab_dict;
    case ShortcutAction.homeTabSettings:
      return t.shortcut_action_home_tab_settings;
    case ShortcutAction.homeTabPrev:
      return t.shortcut_action_home_tab_prev;
    case ShortcutAction.homeTabNext:
      return t.shortcut_action_home_tab_next;
    case ShortcutAction.homeFocusSearch:
      return t.shortcut_action_home_focus_search;
    case ShortcutAction.globalBack:
      return t.shortcut_action_global_back;
    case ShortcutAction.globalScrollPageDown:
      return t.shortcut_action_global_scroll_page_down;
    case ShortcutAction.globalScrollPageUp:
      return t.shortcut_action_global_scroll_page_up;
    case ShortcutAction.audiobookPlayPause:
      return t.shortcut_action_audiobook_play_pause;
    case ShortcutAction.audiobookNextSentence:
      return t.shortcut_action_audiobook_next_sentence;
    case ShortcutAction.audiobookPrevSentence:
      return t.shortcut_action_audiobook_prev_sentence;
    case ShortcutAction.audiobookSeekToClickedSentence:
      return t.shortcut_action_audiobook_seek_clicked;
    case ShortcutAction.videoTogglePlayPause:
      return t.shortcut_action_video_toggle_play_pause;
    case ShortcutAction.videoPlay:
      return t.shortcut_action_video_play;
    case ShortcutAction.videoPause:
      return t.shortcut_action_video_pause;
    case ShortcutAction.videoPreviousSubtitle:
      return t.shortcut_action_video_previous_subtitle;
    case ShortcutAction.videoNextSubtitle:
      return t.shortcut_action_video_next_subtitle;
    case ShortcutAction.videoSeekBackward:
      return t.shortcut_action_video_seek_backward;
    case ShortcutAction.videoSeekForward:
      return t.shortcut_action_video_seek_forward;
    case ShortcutAction.videoToggleShaderCompare:
      return t.shortcut_action_video_toggle_shader_compare;
    case ShortcutAction.videoVolumeUp:
      return t.shortcut_action_video_volume_up;
    case ShortcutAction.videoVolumeDown:
      return t.shortcut_action_video_volume_down;
    case ShortcutAction.videoToggleMute:
      return t.shortcut_action_video_toggle_mute;
    case ShortcutAction.videoSpeedUp:
      return t.shortcut_action_video_speed_up;
    case ShortcutAction.videoSpeedDown:
      return t.shortcut_action_video_speed_down;
    case ShortcutAction.videoResetSpeed:
      return t.shortcut_action_video_reset_speed;
    case ShortcutAction.videoPreviousFrame:
      return t.shortcut_action_video_previous_frame;
    case ShortcutAction.videoNextFrame:
      return t.shortcut_action_video_next_frame;
    case ShortcutAction.videoScreenshot:
      return t.shortcut_action_video_screenshot;
    case ShortcutAction.videoToggleFullscreen:
      return t.shortcut_action_video_toggle_fullscreen;
    case ShortcutAction.videoToggleSubtitleList:
      return t.shortcut_action_video_toggle_subtitle_list;
    case ShortcutAction.videoToggleImmersiveLock:
      return t.shortcut_action_video_toggle_immersive_lock;
    case ShortcutAction.videoToggleSubtitleBlur:
      return t.shortcut_action_video_toggle_subtitle_blur;
    case ShortcutAction.videoToggleFavoriteSentence:
      return t.shortcut_action_video_toggle_favorite_sentence;
    case ShortcutAction.videoReplayCurrentSubtitle:
      return t.shortcut_action_video_replay_current_subtitle;
    case ShortcutAction.videoReplayPreviousSubtitle:
      return t.shortcut_action_video_replay_previous_subtitle;
    case ShortcutAction.videoShowFavoriteSentences:
      return t.shortcut_action_video_show_favorite_sentences;
    case ShortcutAction.videoPreviousChapter:
      return t.shortcut_action_video_previous_chapter;
    case ShortcutAction.videoNextChapter:
      return t.shortcut_action_video_next_chapter;
    case ShortcutAction.videoEscape:
      return t.shortcut_action_video_escape;
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
    case ShortcutScope.video:
      return t.shortcut_scope_video;
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
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.shortcut_reset_defaults,
            leadingIcon: Icons.restore_outlined,
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
            body: Text(t.shortcut_reset_confirm),
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
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.shortcut_reset_defaults),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    _registry.resetScopeToDefaults(scope, defaultTargetPlatform);
    await _save();
    setState(() {});
  }

  Future<void> _editBinding(ShortcutAction action) async {
    final ShortcutBindingEditResult? result =
        await showAppDialog<ShortcutBindingEditResult>(
      context: context,
      builder: (BuildContext ctx) => ShortcutBindingEditDialog(
        action: action,
        registry: _registry,
        initial: _registry.bindingsFor(action),
      ),
    );
    if (result == null || !mounted) return;
    _registry.updateBindingWithReassignments(
      action,
      result.bindings,
      removeKeyboardConflicts: result.keyboardReassignments,
      removeGamepadConflicts: result.gamepadReassignments,
    );
    await _save();
    setState(() {});
  }

  /// 把每个 scope 投影成一张统一的 [AdaptiveSettingsSection] 卡片（标题用共享的
  /// section header 样式，不再是孤立的 primary 色标题），卡片内首行是「恢复默认」
  /// 动作行，其后是各 action 行。返回裸内容（无脚手架），由统一详情壳承载滚动与
  /// 内边距，使从统一设置详情面板点进来不再有风格跳变。
  Widget _buildScopeSections(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ShortcutScope scope in ShortcutScope.values)
          AdaptiveSettingsSection(
            title: _scopeLabel(scope),
            children: <Widget>[
              AdaptiveSettingsRow(
                title: t.shortcut_reset_defaults,
                icon: Icons.restore_outlined,
                showIcon: true,
                onTap: () => _confirmResetScope(scope),
              ),
              for (final ShortcutAction action
                  in ShortcutAction.actionsForScope(scope))
                _ActionTile(
                  action: action,
                  bindings: _registry.bindingsFor(action),
                  onEdit: () => _editBinding(action),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );

    // Synthesise a settings destination that projects the scoped binding cards
    // through the SAME detail shell the unified settings renderer uses, so a
    // push into shortcuts is visually identical to a real schema destination
    // (TODO-317). The content is custom/stateful, so it rides the `body` escape
    // hatch instead of schema items.
    final SettingsDestination destination = SettingsDestination(
      id: SettingsDestinationId.system,
      title: t.shortcut_settings_title,
      icon: Icons.keyboard_outlined,
      sections: const <SettingsSection>[],
      body: (_) => _buildScopeSections(context),
    );

    return buildSettingsDetailShell(
      context: context,
      settingsContext: settingsContext,
      destination: destination,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<String> labels = <String>[
      ...bindings.keyboardBindings.map((InputBinding b) => b.displayLabel),
      ...bindings.gamepadBindings.map((GamepadBinding b) => b.button.label),
    ];

    return HibikiListItem(
      title: Text(_actionLabel(action)),
      subtitle: labels.isEmpty
          ? Text(
              t.shortcut_none,
            )
          : Wrap(
              spacing: tokens.spacing.gap / 2,
              runSpacing: tokens.spacing.gap / 2,
              children: labels
                  .map((String label) => HibikiTagChip(
                        label: label,
                        tone: HibikiTagChipTone.surface,
                      ))
                  .toList(growable: false),
            ),
      trailing: HibikiIconButton(
        icon: Icons.edit_outlined,
        tooltip: t.options_edit,
        onTap: onEdit,
      ),
    );
  }
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
  });

  final ShortcutAction action;
  final HibikiShortcutRegistry registry;
  final ShortcutBindingSet initial;

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
  });

  final ShortcutBindingSet bindings;
  final List<InputBinding> keyboardReassignments;
  final List<GamepadBinding> gamepadReassignments;
}

class _ShortcutBindingEditDialogState extends State<ShortcutBindingEditDialog> {
  late List<InputBinding> _keyboard;
  late List<GamepadBinding> _gamepad;
  final List<InputBinding> _keyboardReassignments = <InputBinding>[];
  final List<GamepadBinding> _gamepadReassignments = <GamepadBinding>[];
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

  void _clearAll() {
    setState(() {
      _keyboard.clear();
      _gamepad.clear();
      _keyboardReassignments.clear();
      _gamepadReassignments.clear();
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
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(widget.action));
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
      _conflictWarning = t.shortcut_conflict(s: _actionLabel(conflict));
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
            title: t.shortcut_conflict(s: _actionLabel(conflict)),
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
                s: _actionLabel(conflict),
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
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(conflict));
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
        title: _actionLabel(widget.action),
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
                    mouseBindings: widget.initial.mouseBindings,
                  ),
                  keyboardReassignments:
                      List<InputBinding>.unmodifiable(_keyboardReassignments),
                  gamepadReassignments:
                      List<GamepadBinding>.unmodifiable(_gamepadReassignments),
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
