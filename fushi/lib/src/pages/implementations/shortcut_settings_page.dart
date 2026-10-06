// 快捷键设置页（library 壳）。
//
// 结构（2026-10 单页重设计）：本文件只保留页面本体（把作用域 / 模块可见性 /
// 可视化键位图 / 手柄品牌 / GameInput 提示 / 确认弹窗装配进浏览器）；单页浏览器
// （搜索 + 按键反查 + 域筛选 + 输入设备切换 + 两栏 / 粘性分组 + 行内录制与冲突）
// 在 `shortcut_settings/shortcut_browser.part.dart`，单个动作行与鼠标 chip 在
// `shortcut_settings/action_tile.part.dart`，完整编辑对话框（多通道实时捕获
// + 手柄下拉 + 冲突重分配）在 `shortcut_settings/binding_edit_dialog.part.dart`，
// 动作/作用域/鼠标绑定的本地化标签在公开的
// `shortcuts/shortcut_labels.dart` 扩展（加动作时标签与数据层就近同步）。
// 写穿路径不变：registry.updateBinding* → saveShortcutRegistry，改完立即生效。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi/pages.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_layout_view.dart';
import 'package:fushi/src/shortcuts/visual/keyboard_layout_view.dart';

part 'shortcut_settings/action_tile.part.dart';
part 'shortcut_settings/binding_edit_dialog.part.dart';
part 'shortcut_settings/shortcut_browser.part.dart';

class ShortcutSettingsPage extends BasePage {
  const ShortcutSettingsPage({super.key});

  @override
  BasePageState<ShortcutSettingsPage> createState() =>
      _ShortcutSettingsPageState();
}

class _ShortcutSettingsPageState extends BasePageState<ShortcutSettingsPage> {
  FushiShortcutRegistry get _registry => appModel.shortcutRegistry;

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
    _gamepadBrand = ReaderFushiSource.instance.gamepadGlyphBrand;
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
    await ReaderFushiSource.instance.setGamepadGlyphBrand(brand);
  }

  Future<void> _save() async {
    await saveShortcutRegistry(_registry, ReaderFushiSource.instance);
  }

  Future<void> _confirmResetScope(ShortcutScope scope) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: FushiModalSheetFrame(
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

  /// 「全部恢复默认」：与分组恢复同一套确认弹窗，写回整张默认表。
  Future<void> _confirmResetAll() async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.78,
          scrollable: false,
          child: FushiModalSheetFrame(
            title: t.shortcut_reset_all,
            leadingIcon: Icons.restart_alt_rounded,
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
            body: Text(t.shortcut_reset_all_confirm),
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
                  child: Text(t.shortcut_reset_all),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    _registry.resetToDefaults(defaultTargetPlatform);
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
    final List<ShortcutAction> actions = ShortcutAction.actionsForScope(
      scope,
    ).toList(growable: false);
    return showAppDialog<ShortcutAction>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 480,
          maxHeightFactor: 0.82,
          scrollable: false,
          child: FushiModalSheetFrame(
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
                  FushiListItem(
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

  /// 被关掉的功能模块不出现自己的快捷键分区（见 `module_registry.dart`）。
  /// 这不只是文案泄露：`globalExternal` 分区一旦可编辑，用户改一次绑定就会
  /// 让 `GlobalLookupController._onRegistryChanged` **当场**装上 OS 热键与
  /// native RawInput 鼠标钩子——查词模块关着时装系统级钩子是实打实的越权。
  List<ShortcutScope> _visibleScopes() => <ShortcutScope>[
        for (final ShortcutScope scope in ShortcutScope.values)
          if (isShortcutScopeVisible(scope, appModel.moduleVisibility)) scope,
      ];

  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 单页浏览器：搜索 / 按键反查 / 域筛选 / 输入设备切换都在它的固定工具区里，
  /// 本页只把作用域、确认弹窗、键位图与手柄品牌这些页面级装配接进去。
  Widget _buildBrowser(BuildContext context) {
    return ShortcutBindingsBrowser(
      registry: _registry,
      scopes: _visibleScopes(),
      platform: defaultTargetPlatform,
      gamepadBrand: _gamepadBrand,
      onChanged: () async {
        await _save();
        if (mounted) setState(() {});
      },
      onOpenEditor: (ShortcutAction action) => _editBinding(action),
      onResetScope: _confirmResetScope,
      onResetAll: _confirmResetAll,
      // TODO-1066: 移动端 app 外查词由系统触发（文本选择菜单 / 分享 / 悬浮球），
      // 系统不许应用改这个热键——只读展示 + 说明，不给一条点了没用的改键行。
      readOnlyScopes: _isMobilePlatform
          ? const <ShortcutScope>{ShortcutScope.globalExternal}
          : const <ShortcutScope>{},
      scopeExtras: _scopeExtras,
      scopeBodyOverride: _buildFigure,
      // TODO-1223: hint shown only when the platform's controller backend is
      // unavailable (Windows without GameInput.dll). Rendered here — on the
      // gamepad-related settings surface — rather than as a startup popup, so
      // it never interrupts a user who does not touch controller settings.
      banner: _gameInputUnavailable ? _buildGameInputHint(context) : null,
      toolbarTrailing: <Widget>[_buildViewToggle()],
      // 手柄按钮样式只换显示（键帽 / 键位图），切到手柄设备时才出现。
      deviceAccessory: (ShortcutInputDevice device) =>
          device == ShortcutInputDevice.gamepad
              ? _buildGamepadBrandSelector()
              : null,
    );
  }

  /// 列表 / 键位图切换。Wrap the segmented toggle in a FushiAdjustableSegmented
  /// so it becomes a single gamepad/keyboard focus stop with D-pad / arrow
  /// Left-Right flipping between the two views (TODO-942 residual: a bare
  /// SegmentedButton is a cluster of native buttons the directional
  /// FushiFocusController skips entirely). The inner SegmentedButton keeps its
  /// Key so it stays mouse/touch-tappable and test-addressable.
  Widget _buildViewToggle() {
    return FushiAdjustableSegmented<bool>(
      focusIdPrefix: 'shortcut-view-toggle',
      values: const <bool>[false, true],
      selected: _visualMode,
      onChanged: (bool value) {
        setState(() => _visualMode = value);
      },
      child: FushiSegmentedButton<bool>(
        key: const Key('shortcut_view_toggle'),
        showSelectedIcon: false,
        segments: <ButtonSegment<bool>>[
          ButtonSegment<bool>(
            value: false,
            icon: const FushiIcon(Icons.list_outlined),
            tooltip: t.shortcut_view_list,
          ),
          ButtonSegment<bool>(
            value: true,
            // TODO-942 discoverability: a controller glyph tells the user at a
            // glance that this segment shows the visual layout figure.
            icon: const FushiIcon(Icons.sports_esports_outlined),
            tooltip: t.shortcut_view_visual,
          ),
        ],
        selected: <bool>{_visualMode},
        onSelectionChanged: (Set<bool> selection) {
          setState(() => _visualMode = selection.first);
        },
      ),
    );
  }

  /// TODO-1223: one-line notice that the platform's controller backend is
  /// unavailable (Windows without GameInput.dll → gamepad input silently does
  /// nothing after the +488 delay-load crash fix). Tells the user why the
  /// controller is dead and how to enable it. A styled inline banner (not a
  /// blocking dialog) so it informs without interrupting.
  Widget _buildGameInputHint(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiInlineNotice(message: t.shortcut_gamepad_unavailable_hint),
    );
  }

  /// TODO-1113: gamepad button-style (brand) selector. Display-only — switches
  /// how face buttons render in the visual figure (Xbox A/B/X/Y, PlayStation
  /// ✕○□△, Nintendo Switch B/A/Y/X). Only visible in the visual figure mode.
  /// Wrapped in FushiAdjustableSegmented so it is a single directional focus
  /// stop reachable by pure-gamepad users (same pattern as the view toggle).
  Widget _buildGamepadBrandSelector() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
            child: FushiAdjustableSegmented<GamepadBrand>(
              focusIdPrefix: 'gamepad-brand-select',
              values: GamepadBrand.values,
              selected: _gamepadBrand,
              onChanged: _onGamepadBrandChanged,
              child: FushiSegmentedButton<GamepadBrand>(
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

  /// 分组卡顶部的说明行 / 开关（浏览器只在未搜索时显示它们）。
  List<Widget> _scopeExtras(ShortcutScope scope) {
    return <Widget>[
      // TODO-1066 — 移动端：系统接管，解释为什么这里改不了键。
      if (scope == ShortcutScope.globalExternal && _isMobilePlatform)
        AdaptiveSettingsRow(
          title: ShortcutAction.globalExternalLookup.label,
          subtitle: t.shortcut_scope_global_external_mobile_note,
          icon: Icons.info_outline,
          showIcon: true,
        ),
      // 纯弹窗内滚轮触发，用户看不到「在哪儿按」时会以为没生效，故给一行说明。
      if (scope == ShortcutScope.dictionaryPopup)
        AdaptiveSettingsRow(
          title: t.shortcut_scope_dictionary_popup_note,
          icon: Icons.info_outline,
          showIcon: true,
        ),
      // TODO-1066 — 桌面 app 外查词开了鼠标通道，但**只有侧键**能当全局触发：
      // 这条触发不拦截原事件（native 走 RawInput，见 global_mouse_trigger.h），
      // 右键/中键有全系统级默认语义（上下文菜单 / 自动滚动），绑上去等于两件事
      // 同时发生。
      if (scope == ShortcutScope.globalExternal && !_isMobilePlatform)
        AdaptiveSettingsRow(
          title: t.shortcut_scope_global_external_desktop_note,
          icon: Icons.info_outline,
          showIcon: true,
        ),
      // 用户请求（Flow Launcher 式用法）：「置顶并打开查词页」热键的另一半——查完
      // 在查词页按「返回上一级」（默认 Esc）把主窗最小化，回到之前的程序。放在
      // 这张卡里而不是词典设置：它只在配合本 scope 的置顶热键时才有意义。执行体在
      // HomeDictionaryPage（只在桌面生效）。
      if (scope == ShortcutScope.globalExternal && !_isMobilePlatform)
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('shortcut-lookup-page-escape-minimize'),
          title: t.shortcut_lookup_page_escape_minimize,
          subtitle: t.shortcut_lookup_page_escape_minimize_hint,
          icon: Icons.minimize_outlined,
          showIcon: true,
          value: appModel.lookupPageEscapeMinimizesWindow,
          onChanged: (bool value) async {
            await appModel.setLookupPageEscapeMinimizesWindow(value);
            if (mounted) setState(() {});
          },
        ),
    ];
  }

  /// 键位图模式下替换分组的行列表：键盘设备画键盘图、手柄设备画手柄图（TODO-942
  /// P1：两张图各自独立）。只对真的会消费该通道的 scope 画——查词弹窗的词条导航
  /// 是纯滚轮通道，给它画键盘图不但是空图，点空键位还会写出一条永不触发的死绑定，
  /// 这类 scope 与鼠标设备一律回落到列表行（off-figure 键也在列表里可改）。
  Widget? _buildFigure(ShortcutScope scope, ShortcutInputDevice device) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_visualMode) {
      final EdgeInsets padding = EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap,
      );
      if (device == ShortcutInputDevice.keyboard &&
          scope.channels.contains(ShortcutChannel.keyboard)) {
        return Padding(
          padding: padding,
          child: KeyboardLayoutView(
            registry: _registry,
            scope: scope,
            onKeyTap: _onKeyboardKeyTap,
            onEmptyKeyTap: (LogicalKeyboardKey key) =>
                _onEmptyKeyboardKeyTap(scope, key),
          ),
        );
      }
      if (device == ShortcutInputDevice.gamepad &&
          scope.channels.contains(ShortcutChannel.gamepad)) {
        return Padding(
          padding: padding,
          child: GamepadLayoutView(
            registry: _registry,
            scope: scope,
            gamepadBrand: _gamepadBrand,
            onGamepadTap: _onGamepadButtonTap,
            onEmptyGamepadTap: (GamepadButton button) =>
                _onEmptyGamepadButtonTap(scope, button),
          ),
        );
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderFushiSource.instance,
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
      // 浏览器自己管滚动：吸顶工具区、宽屏左栏导航、粘性分组标题都要占满视口。
      bodyFillsViewport: true,
      body: (_) => _buildBrowser(context),
    );

    return buildSettingsDetailShell(
      context: context,
      settingsContext: settingsContext,
      destination: destination,
    );
  }
}
