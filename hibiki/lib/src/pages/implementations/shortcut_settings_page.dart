import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

/// Localised label for a [ShortcutAction].
String _actionLabel(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.readerPageForward:
      return t.shortcut_action_reader_page_forward;
    case ShortcutAction.readerPageBackward:
      return t.shortcut_action_reader_page_backward;
    case ShortcutAction.readerToggleChrome:
      return t.shortcut_action_reader_toggle_chrome;
    case ShortcutAction.readerOpenMenu:
      return t.shortcut_action_reader_open_menu;
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
    case ShortcutAction.readerEnterCaret:
      return t.shortcut_action_reader_enter_caret;
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
    case ShortcutAction.globalToggleFullscreen:
      return t.shortcut_action_global_toggle_fullscreen;
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
    case ShortcutAction.videoCycleSubtitleObscure:
      return t.shortcut_action_video_cycle_subtitle_obscure;
    case ShortcutAction.videoToggleSubtitleHide:
      return t.shortcut_action_video_toggle_subtitle_hide;
    case ShortcutAction.videoToggleFavoriteSentence:
      return t.shortcut_action_video_toggle_favorite_sentence;
    case ShortcutAction.videoReplayCurrentSubtitle:
      return t.shortcut_action_video_replay_current_subtitle;
    case ShortcutAction.videoReplayPreviousSubtitle:
      return t.shortcut_action_video_replay_previous_subtitle;
    case ShortcutAction.videoPreviousChapter:
      return t.shortcut_action_video_previous_chapter;
    case ShortcutAction.videoNextChapter:
      return t.shortcut_action_video_next_chapter;
    case ShortcutAction.videoEscape:
      return t.shortcut_action_video_escape;
    case ShortcutAction.dpadUp:
      return t.shortcut_action_dpad_up;
    case ShortcutAction.dpadDown:
      return t.shortcut_action_dpad_down;
    case ShortcutAction.dpadLeft:
      return t.shortcut_action_dpad_left;
    case ShortcutAction.dpadRight:
      return t.shortcut_action_dpad_right;
    case ShortcutAction.globalExternalLookup:
      return t.shortcut_action_global_external_lookup;
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
    case ShortcutScope.gamepad:
      return t.shortcut_scope_gamepad;
    case ShortcutScope.globalExternal:
      return t.shortcut_scope_global_external;
  }
}

/// TODO-1050b: 鼠标绑定的本地化显示名。DOM MouseEvent.button：1=中键/滚轮、2=右键、
/// 3=后退侧键、4=前进侧键（与 [MouseBinding._knownButtons] 对齐）；0=左键与其它未知值兜底。
String _mouseLabel(MouseBinding binding) {
  switch (binding.button) {
    case 0:
      return t.shortcut_mouse_left;
    case 1:
      return t.shortcut_mouse_middle;
    case 2:
      return t.shortcut_mouse_right;
    case 3:
      return t.shortcut_mouse_back;
    case 4:
      return t.shortcut_mouse_forward;
    default:
      return t.shortcut_mouse_button;
  }
}

/// TODO-1050b: 鼠标绑定的小图标。中键落在滚轮上用滚轮图标，其余用通用鼠标图标
/// （Material 无左右键专属图标）。
IconData _mouseIcon(MouseBinding binding) {
  switch (binding.button) {
    case 1:
      return Icons.mouse_outlined;
    default:
      return Icons.mouse;
  }
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

class ShortcutSettingsPage extends BasePage {
  const ShortcutSettingsPage({super.key});

  @override
  BasePageState<ShortcutSettingsPage> createState() =>
      _ShortcutSettingsPageState();
}

class _ShortcutSettingsPageState extends BasePageState<ShortcutSettingsPage> {
  HibikiShortcutRegistry get _registry => appModel.shortcutRegistry;

  // TODO-612: list vs keyboard-visual view toggle. The figure is a new
  // read+remap surface over the SAME registry write-through path; the list
  // view stays the fallback (off-figure keys like BracketLeft remain editable
  // there). Icon-only segments avoid new i18n in this batch.
  bool _visualMode = false;

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

  Future<void> _editBinding(
    ShortcutAction action, {
    LogicalKeyboardKey? prefillKey,
    GamepadButton? prefillButton,
  }) async {
    final ShortcutBindingEditResult? result =
        await showAppDialog<ShortcutBindingEditResult>(
      context: context,
      builder: (BuildContext ctx) => ShortcutBindingEditDialog(
        action: action,
        registry: _registry,
        initial: _registry.bindingsFor(action),
        prefillKey: prefillKey,
        prefillButton: prefillButton,
      ),
    );
    if (result == null || !mounted) return;
    _registry.updateBindingWithReassignments(
      action,
      result.bindings,
      removeKeyboardConflicts: result.keyboardReassignments,
      removeGamepadConflicts: result.gamepadReassignments,
      removeMouseConflicts: result.mouseReassignments,
    );
    await _save();
    setState(() {});
  }

  /// 点击键盘图上某个**已绑**键位。该键位上绑了哪些 action 由 [ReverseBindingIndex]
  /// 反查得到并传入；直接编辑其上第一个 action，复用现成 [_editBinding] →
  /// updateBindingWithReassignments → saveShortcutRegistry 写穿路径。**空键位**改走
  /// [_onEmptyKeyboardKeyTap]（TODO-1060② un-defer：key-first 选 action 后分配）。
  /// 多绑键位的逐 action 选择留待后续增量。
  Future<void> _onKeyboardKeyTap(
    LogicalKeyboardKey key,
    List<ShortcutAction> boundActions,
  ) async {
    if (boundActions.isEmpty) return;
    await _editBinding(boundActions.first);
  }

  /// TODO-1060②: 点击可视化键盘上的**空白/未分配**键位。key-first：先让用户从该
  /// scope 的 action 列表里选一个 action，再打开标准编辑对话框并把该键预填进草稿，
  /// 复用现成 [_editBinding] → updateBindingWithReassignments → saveShortcutRegistry
  /// 写穿路径（不造第二套分配逻辑）。用户可在对话框里删掉预填或加更多键后确认。
  Future<void> _onEmptyKeyboardKeyTap(
    ShortcutScope scope,
    LogicalKeyboardKey key,
  ) async {
    final ShortcutAction? action = await _pickActionForScope(scope);
    if (action == null || !mounted) return;
    await _editBinding(action, prefillKey: key);
  }

  /// 点击可视化手柄图上某**已绑**按钮：编辑其首个 action（对齐键盘已绑口径）。
  Future<void> _onGamepadButtonTap(
    GamepadButton button,
    List<ShortcutAction> boundActions,
  ) async {
    if (boundActions.isEmpty) return;
    await _editBinding(boundActions.first);
  }

  /// 点击可视化手柄图上某**未绑**按钮：key-first 选 action 后预填该按钮分配。
  Future<void> _onEmptyGamepadButtonTap(
    ShortcutScope scope,
    GamepadButton button,
  ) async {
    final ShortcutAction? action = await _pickActionForScope(scope);
    if (action == null || !mounted) return;
    await _editBinding(action, prefillButton: button);
  }

  /// 弹出「为此键位选择要分配的动作」选择器：列出该 scope 的全部 action（复用
  /// [ShortcutAction.actionsForScope] + [_actionLabel]），选中返回该 action，取消返回
  /// null。纯 UI 选择器，不写任何注册表（写穿仍由后续 [_editBinding] 完成）。
  Future<ShortcutAction?> _pickActionForScope(ShortcutScope scope) {
    final List<ShortcutAction> actions =
        ShortcutAction.actionsForScope(scope).toList(growable: false);
    return showAppDialog<ShortcutAction>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 480,
          maxHeightFactor: 0.82,
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.shortcut_assign_pick_action,
            leadingIcon: Icons.add_link_outlined,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final ShortcutAction action in actions)
                  HibikiListItem(
                    key: Key('pick_action_${action.name}'),
                    onTap: () => Navigator.pop(ctx, action),
                    title: Text(_actionLabel(action)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 把每个 scope 投影成一张统一的 [AdaptiveSettingsSection] 卡片（标题用共享的
  /// section header 样式，不再是孤立的 primary 色标题），卡片内首行是「恢复默认」
  /// 动作行，其后是各 action 行。返回裸内容（无脚手架），由统一详情壳承载滚动与
  /// 内边距，使从统一设置详情面板点进来不再有风格跳变。
  Widget _buildScopeSections(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              key: const Key('shortcut_view_toggle'),
              showSelectedIcon: false,
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.list_outlined),
                ),
                ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.keyboard_outlined),
                ),
              ],
              selected: <bool>{_visualMode},
              onSelectionChanged: (Set<bool> selection) {
                setState(() => _visualMode = selection.first);
              },
            ),
          ),
        ),
        for (final ShortcutScope scope in ShortcutScope.values)
          _buildScopeSection(scope),
      ],
    );
  }

  /// Builds one scope's card. TODO-1066: on mobile the `globalExternal` scope
  /// (app-external lookup) is triggered by the OS (text-selection menu / share /
  /// floating ball) and the OS forbids apps from remapping that hotkey, so it
  /// renders a read-only explanatory note instead of an editable binding row —
  /// keeping the app honest ("为什么这里改不了键") without a dead, non-functional
  /// remap row. On desktop the same scope is a real, editable Ctrl+Alt+D binding
  /// and renders like every other scope.
  Widget _buildScopeSection(ShortcutScope scope) {
    final bool isMobilePlatform =
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS;
    if (scope == ShortcutScope.globalExternal && isMobilePlatform) {
      return AdaptiveSettingsSection(
        title: _scopeLabel(scope),
        children: <Widget>[
          AdaptiveSettingsRow(
            title: _actionLabel(ShortcutAction.globalExternalLookup),
            subtitle: t.shortcut_scope_global_external_mobile_note,
            icon: Icons.info_outline,
            showIcon: true,
          ),
        ],
      );
    }
    return AdaptiveSettingsSection(
      title: _scopeLabel(scope),
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.shortcut_reset_defaults,
          icon: Icons.restore_outlined,
          showIcon: true,
          onTap: () => _confirmResetScope(scope),
        ),
        if (_visualMode)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: KeyboardLayoutView(
              registry: _registry,
              scope: scope,
              onKeyTap: _onKeyboardKeyTap,
              onEmptyKeyTap: (LogicalKeyboardKey key) =>
                  _onEmptyKeyboardKeyTap(scope, key),
              onGamepadTap: _onGamepadButtonTap,
              onEmptyGamepadTap: (GamepadButton button) =>
                  _onEmptyGamepadButtonTap(scope, button),
            ),
          )
        else
          for (final ShortcutAction action
              in ShortcutAction.actionsForScope(scope))
            _ActionTile(
              action: action,
              bindings: _registry.bindingsFor(action),
              onEdit: () => _editBinding(action),
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
    // Keyboard + gamepad render as plain text chips; TODO-1050b: mouse bindings
    // render as icon chips (middle/right/back/forward small glyph) so the mouse
    // channel is no longer invisible in the list view (was data-only pass-through).
    final List<Widget> chips = <Widget>[
      for (final InputBinding b in bindings.keyboardBindings)
        HibikiTagChip(
          label: b.displayLabel,
          tone: HibikiTagChipTone.surface,
        ),
      for (final GamepadBinding b in bindings.gamepadBindings)
        HibikiTagChip(
          label: b.button.label,
          tone: HibikiTagChipTone.surface,
        ),
      for (final MouseBinding b in bindings.mouseBindings)
        _MouseChip(binding: b),
    ];

    // TODO-944: the whole row taps into the SAME assign/edit flow, so unmapped
    // rows (no chips, only the dim "tap to assign" hint) are reachable instead
    // of relying on the tiny trailing edit icon. Routing `onTap` through
    // [HibikiListItem] also registers a focus target, making every row — mapped
    // or not — keyboard/gamepad navigable.
    return HibikiListItem(
      onTap: onEdit,
      title: Text(_actionLabel(action)),
      subtitle: chips.isEmpty
          ? Text(
              t.shortcut_tap_to_assign,
            )
          : Wrap(
              spacing: tokens.spacing.gap / 2,
              runSpacing: tokens.spacing.gap / 2,
              children: chips,
            ),
      trailing: HibikiIconButton(
        icon: Icons.edit_outlined,
        tooltip: t.options_edit,
        onTap: onEdit,
      ),
    );
  }
}

/// TODO-1050b: 鼠标绑定的小图标 chip（HibikiTagChip 无 leading icon 位，这里用同款
/// surface 观感自绘一个「图标 + 名称」的小 chip，与文字 chip 并排展示，不改公共组件）。
class _MouseChip extends StatelessWidget {
  const _MouseChip({required this.binding, this.onDeleted});

  final MouseBinding binding;

  /// TODO-1088: when non-null a trailing delete affordance is shown (edit
  /// dialog); null keeps it a plain read-only chip (list-view display).
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fg = theme.colorScheme.onSurface;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap * 0.75,
        vertical: tokens.spacing.gap * 0.375,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaces.overlay,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_mouseIcon(binding), size: 14, color: fg),
          SizedBox(width: tokens.spacing.gap * 0.375),
          Text(
            _mouseLabel(binding),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onDeleted != null) ...<Widget>[
            SizedBox(width: tokens.spacing.gap * 0.375),
            InkWell(
              onTap: onDeleted,
              customBorder: const CircleBorder(),
              child: Icon(Icons.close, size: 14, color: fg),
            ),
          ],
        ],
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
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(widget.action));
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
        _conflictWarning = t.shortcut_conflict(s: _actionLabel(conflict));
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
