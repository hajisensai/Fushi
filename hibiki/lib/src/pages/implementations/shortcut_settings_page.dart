// 快捷键设置页（library 壳）。
//
// 结构（快捷键设置重构）：本文件只保留页面本体（scope 卡片投影 + 可视化/列表
// 切换 + 手柄品牌选择 + GameInput 提示）；单个动作行与鼠标 chip 在
// `shortcut_settings/action_tile.part.dart`，绑定编辑对话框（键盘/鼠标实时捕获
// + 手柄下拉 + 冲突重分配）在 `shortcut_settings/binding_edit_dialog.part.dart`，
// 动作/作用域/鼠标绑定的本地化标签在公开的
// `shortcuts/shortcut_labels.dart` 扩展（加动作时标签与数据层就近同步）。
// 写穿路径不变：updateBindingWithReassignments → saveShortcutRegistry。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_layout_view.dart';
import 'package:fushi/src/shortcuts/visual/keyboard_layout_view.dart';

part 'shortcut_settings/action_tile.part.dart';
part 'shortcut_settings/binding_edit_dialog.part.dart';

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

  // TODO-1113: gamepad glyph brand (display-only). Loaded from the reader source
  // preference on init; persisted on change. Only re-skins the visual keyboard
  // figure's gamepad panel + list-view gamepad chips — never touches binding
  // serialization (GamepadButton.serialize stays A/B/X/Y regardless of brand).
  GamepadBrand _gamepadBrand = GamepadBrand.xbox;

  /// TODO-1223: true once the async probe confirms the platform's controller
  /// backend is unavailable (Windows without GameInput.dll — the +488 delay-load
  /// fix degrades silently to no gamepad support). When set, a one-line hint
  /// renders at the top of this (gamepad-related) page telling the user why the
  /// controller is dead and how to enable it, instead of leaving them guessing.
  /// Only ever flipped to true on a definitive `false` from the native probe, so
  /// machines with a working backend (and every non-Windows platform) show
  /// nothing.
  bool _gameInputUnavailable = false;

  @override
  void initState() {
    super.initState();
    _gamepadBrand = ReaderHibikiSource.instance.gamepadGlyphBrand;
    // Surface the hint only on a gamepad-related surface (this settings page),
    // never as a startup popup — a mouse/keyboard-only user is not nagged.
    unawaited(_checkGameInputAvailability());
  }

  /// TODO-1223: asks the platform whether the controller backend is available
  /// and, only on a definitive unavailable result, flips [_gameInputUnavailable]
  /// so the hint appears. Non-Windows / transient-failure cases resolve to
  /// available and render nothing.
  Future<void> _checkGameInputAvailability() async {
    final bool available = await GamepadService.gameInputBackendAvailable();
    if (!mounted || available) return;
    setState(() => _gameInputUnavailable = true);
  }

  Future<void> _onGamepadBrandChanged(GamepadBrand brand) async {
    if (brand == _gamepadBrand) return;
    setState(() => _gamepadBrand = brand);
    await ReaderHibikiSource.instance.setGamepadGlyphBrand(brand);
  }

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
      removeWheelConflicts: result.wheelReassignments,
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
  /// [ShortcutAction.actionsForScope] + [ShortcutActionLabel]），选中返回该 action，
  /// 取消返回 null。纯 UI 选择器，不写任何注册表（写穿仍由后续 [_editBinding] 完成）。
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
                    title: Text(action.label),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // TODO-1223: hint shown only when the platform's controller backend is
        // unavailable (Windows without GameInput.dll). Rendered here — on the
        // gamepad-related settings surface — rather than as a startup popup, so
        // it never interrupts a user who does not touch controller settings.
        if (_gameInputUnavailable) _buildGameInputHint(context),
        Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          child: Align(
            alignment: Alignment.centerLeft,
            // Wrap the list/keyboard segmented toggle in a
            // HibikiAdjustableSegmented so it becomes a single gamepad/keyboard
            // focus stop with D-pad / arrow Left-Right flipping between the two
            // views (TODO-942 residual: a bare SegmentedButton is a cluster of
            // native buttons the directional HibikiFocusController skips
            // entirely, leaving pure-gamepad users unable to reach the
            // keyboard-skin view at all). The inner SegmentedButton keeps its
            // Key so it stays mouse/touch-tappable and test-addressable.
            child: HibikiAdjustableSegmented<bool>(
              focusIdPrefix: 'shortcut-view-toggle',
              values: const <bool>[false, true],
              selected: _visualMode,
              onChanged: (bool value) {
                setState(() => _visualMode = value);
              },
              child: SegmentedButton<bool>(
                key: const Key('shortcut_view_toggle'),
                showSelectedIcon: false,
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    icon: const Icon(Icons.list_outlined),
                    tooltip: t.shortcut_view_list,
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    // TODO-942 discoverability: the visual segment opens the
                    // gamepad/keyboard skin overview (GamepadLayoutView). Its
                    // icon used to be a plain keyboard glyph, which read as a
                    // mere keyboard view and hid the controller layout — users
                    // asked "where is the controller diagram?". A controller
                    // glyph tells the user at a glance that this segment shows
                    // the gamepad visual layout.
                    icon: const Icon(Icons.sports_esports_outlined),
                    tooltip: t.shortcut_view_visual,
                  ),
                ],
                selected: <bool>{_visualMode},
                onSelectionChanged: (Set<bool> selection) {
                  setState(() => _visualMode = selection.first);
                },
              ),
            ),
          ),
        ),
        if (_visualMode) _buildGamepadBrandSelector(),
        for (final ShortcutScope scope in ShortcutScope.values)
          _buildScopeSection(scope),
      ],
    );
  }

  /// TODO-1223: one-line notice that the platform's controller backend is
  /// unavailable (Windows without GameInput.dll → gamepad input silently does
  /// nothing after the +488 delay-load crash fix). Tells the user why the
  /// controller is dead and how to enable it. A styled inline banner (not a
  /// blocking dialog) so it informs without interrupting.
  Widget _buildGameInputHint(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fg = theme.colorScheme.onSecondaryContainer;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Container(
        padding: EdgeInsets.all(tokens.spacing.gap),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: tokens.radii.cardRadius,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline, size: 20, color: fg),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Text(
                t.shortcut_gamepad_unavailable_hint,
                style: theme.textTheme.bodyMedium?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// TODO-1113: gamepad button-style (brand) selector. Display-only — switches
  /// how face buttons render in the visual figure (Xbox A/B/X/Y, PlayStation
  /// ✕○□△, Nintendo Switch B/A/Y/X). Only visible in the visual figure mode.
  /// Wrapped in HibikiAdjustableSegmented so it is a single directional focus
  /// stop reachable by pure-gamepad users (same pattern as the view toggle).
  Widget _buildGamepadBrandSelector() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
            child: Text(
              t.shortcut_gamepad_brand_label,
              // 小节标题统一走 sectionLabel token（不再裸用 labelMedium）。
              style: tokens.type.sectionLabel,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: HibikiAdjustableSegmented<GamepadBrand>(
              focusIdPrefix: 'gamepad-brand-select',
              values: GamepadBrand.values,
              selected: _gamepadBrand,
              onChanged: _onGamepadBrandChanged,
              child: SegmentedButton<GamepadBrand>(
                key: const Key('gamepad_brand_select'),
                showSelectedIcon: false,
                segments: <ButtonSegment<GamepadBrand>>[
                  ButtonSegment<GamepadBrand>(
                    value: GamepadBrand.xbox,
                    label: Text(t.shortcut_gamepad_brand_xbox),
                  ),
                  ButtonSegment<GamepadBrand>(
                    value: GamepadBrand.playstation,
                    label: Text(t.shortcut_gamepad_brand_playstation),
                  ),
                  ButtonSegment<GamepadBrand>(
                    value: GamepadBrand.nintendoSwitch,
                    label: Text(t.shortcut_gamepad_brand_switch),
                  ),
                ],
                selected: <GamepadBrand>{_gamepadBrand},
                onSelectionChanged: (Set<GamepadBrand> selection) =>
                    _onGamepadBrandChanged(selection.first),
              ),
            ),
          ),
        ],
      ),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool isMobilePlatform =
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS;
    if (scope == ShortcutScope.globalExternal && isMobilePlatform) {
      return AdaptiveSettingsSection(
        title: scope.label,
        children: <Widget>[
          AdaptiveSettingsRow(
            title: ShortcutAction.globalExternalLookup.label,
            subtitle: t.shortcut_scope_global_external_mobile_note,
            icon: Icons.info_outline,
            showIcon: true,
          ),
        ],
      );
    }
    // 可视化模式只对真的会消费键盘 / 手柄的 scope 有意义。查词弹窗的词条导航是纯
    // 滚轮通道（[ShortcutScope.channels]），给它画键盘图/手柄图不但是空图，点空键位
    // 还会写出一条永不触发的死绑定——这类 scope 在可视化模式下也回落到列表行。
    final bool hasVisualChannels =
        scope.channels.contains(ShortcutChannel.keyboard) ||
            scope.channels.contains(ShortcutChannel.gamepad);
    return AdaptiveSettingsSection(
      title: scope.label,
      children: <Widget>[
        // 纯弹窗内滚轮触发，用户看不到「在哪儿按」时会以为没生效，故给一行说明。
        if (scope == ShortcutScope.dictionaryPopup)
          AdaptiveSettingsRow(
            title: t.shortcut_scope_dictionary_popup_note,
            icon: Icons.info_outline,
            showIcon: true,
          ),
        AdaptiveSettingsRow(
          title: t.shortcut_reset_defaults,
          icon: Icons.restore_outlined,
          showIcon: true,
          onTap: () => _confirmResetScope(scope),
        ),
        if (_visualMode && hasVisualChannels)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.gap,
            ),
            // TODO-942 P1: keyboard / gamepad are two separately titled
            // blocks — the gamepad is a full real-layout figure, no longer
            // stacked below the keyboard inside one widget.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
                  child: Text(
                    t.shortcut_keyboard,
                    // 小节标题统一走 sectionLabel token（不再裸用 labelMedium）。
                    style: tokens.type.sectionLabel,
                  ),
                ),
                KeyboardLayoutView(
                  registry: _registry,
                  scope: scope,
                  onKeyTap: _onKeyboardKeyTap,
                  onEmptyKeyTap: (LogicalKeyboardKey key) =>
                      _onEmptyKeyboardKeyTap(scope, key),
                ),
                SizedBox(height: tokens.spacing.rowVertical),
                Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
                  child: Text(
                    t.shortcut_gamepad,
                    style: tokens.type.sectionLabel,
                  ),
                ),
                GamepadLayoutView(
                  registry: _registry,
                  scope: scope,
                  gamepadBrand: _gamepadBrand,
                  onGamepadTap: _onGamepadButtonTap,
                  onEmptyGamepadTap: (GamepadButton button) =>
                      _onEmptyGamepadButtonTap(scope, button),
                ),
              ],
            ),
          )
        else
          for (final ShortcutAction action
              in ShortcutAction.actionsForScope(scope))
            _ActionTile(
              action: action,
              bindings: _registry.bindingsFor(action),
              brand: _gamepadBrand,
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
      // Synthetic own id（对照 appIcon/videoQuickSettings 先例）：不再借
      // `system`——壳的身份不该冒充真正的系统分类。
      id: SettingsDestinationId.shortcuts,
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
