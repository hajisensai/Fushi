import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart'
    show SettingsModifiedRow;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「游戏」一级设置分类（审计 K / Phase 3.12：游戏域此前没有任何 destination，
/// 游戏库 / 捕获工作台 / 兼容性诊断从设置主页既不可达也不可搜）。
///
/// 三条导航项直达 games 顶层 tab 的对应子区：不 push 第二份页面实例（捕获工作台
/// 持有 Hook 会话，[TexthookerPage] 由 [HomeGamePage] 的 IndexedStack 保态），
/// 而是复用既有跳转真相源——`homeShellTabNotifier` 切 tab + `gameSectionNotifier`
/// 选子区（与原生 Hook 浮窗 `openWorkbench` / 首页 dashboard 卡片同一条路径）。
///
/// 门控：与 games 顶层 tab 完全一致——同一个 `ModuleId.games`。Windows-only 的平台
/// 判据（galgame 引擎-hook 注入）已收进 `ModuleId.availableOn`，与用户在设置 → 外观
/// → 功能模块里的意愿一并合成为 `moduleVisibility`；此处不再另判平台，否则又是一份
/// 会漂移的抄件。非 Windows 平台、或用户关掉游戏模块时，整个分类不可见、不进搜索索引。
///
/// 浏览器扩展页不属于游戏域（它是查词域的桌面扩展安装助手），其搜索入口登记在
/// 「查词」分类（settings_schema_lookup 的 `lookup.browser_extension`），不在此处。
SettingsDestination buildGameDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.game,
    title: t.nav_game,
    summary: t.game_home_subtitle,
    // 图标与底栏 / 侧栏同一真值（homeNavItemFor），不在设置里另写一份。
    icon: homeNavItemFor(HomeTab.games).icon,
    // 本分类的三条导航项与全部配置都属于本机 galgame 库（hook / 捕获工作台 /
    // 兼容性诊断）；Android 的 games 模块是串流接收端，这里一条都用不上。
    visible: (SettingsContext c) =>
        c.appModel.gamesModuleForm == GamesModuleForm.localLibrary &&
        isSettingsDestinationVisible(
          SettingsDestinationId.game,
          c.appModel.moduleVisibility,
        ),
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'game.library',
            title: t.game_library,
            subtitle: t.game_home_subtitle,
            icon: FushiIcons.game,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.library;
            },
          ),
          SettingsNavigationItem(
            id: 'game.capture_workspace',
            title: t.game_capture_workbench,
            icon: FushiIcons.audio,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.monitor;
            },
          ),
          SettingsNavigationItem(
            id: 'game.diagnostics',
            title: t.game_diagnostics,
            icon: FushiIcons.hub,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.diagnostics;
            },
          ),
        ],
      ),
      // 游戏内查词属于**游戏**域，不是查词域：它改变的是「这一局游戏里点字会发生
      // 什么」，与阅读器/视频/剪贴板那几路查词共用引擎但不共用触发面。放在查词分类
      // 里，用户要在游戏跑着的时候去另一个分类翻开关，找不到是必然的。
      SettingsSection(
        items: <SettingsItem>[
          // 游戏内查词：命中的字直接在**游戏渲染树内部**弹出词典卡片
          // （不抢焦点、不 alt-tab、跟随全屏与窗口变换）。传感器按引擎逐个做，
          // 不是所有引擎都有——本局能不能用由 hook 报上来的准入状态说了算。
          SettingsSwitchItem(
            id: 'game.ingame_lookup',
            title: t.gal_hook_ingame_lookup,
            subtitle: t.gal_hook_ingame_lookup_hint,
            // 准入把本局挡住时副标题换成原因；其余状态（含 unknown）回落静态说明。
            //
            // 🔴 **不置灰**，哪怕本局明确用不了。这个开关是**全局偏好**（用户意图），
            // 准入是**当前这一局的能力**，两者正交。拿后者去禁用前者会造出一个很蠢的
            // 状态：默认值是 true，所以"引擎不支持"时用户看到的是一个被锁死在 ON 上、
            // 想关也关不掉的开关——而他此刻最可能想做的恰恰是把它关掉。能力信息属于
            // 副标题，不属于可交互性。
            subtitleBuilder: (_) => _ingameLookupBlockedReason(),
            icon: FushiIcons.lookup,
            defaultValue: PreferencesRepository.galIngameLookupEnabledDefault,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galIngameLookupEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalIngameLookupEnabled(value);
              // 与台词浮窗字号同款纪律：写完 pref 立刻推给编排器，否则开关只落了盘，
              // 本局游戏里不生效（要退出重进一局）。
              await GalHookTextOverlayController.instance
                  .applyIngameLookupEnabledFromPreferences();
              settingsContext.refresh();
            },
          ),
          // 被挡住时唯一能推进事情的信息：当前游戏 exe 的 SHA-256。用户把它报回来，
          // 我们才知道该给哪个版本加白名单。摘要优先取注入侧上报的；Leaf / SGRE 那
          // 类「probe 本身就是 hash 门」的 adapter 在不匹配时压根不参与汇总、没人填
          // 得了那个字段，此时由 runner 兜底自己算（见 voice_hook_reader.cpp）。
          SettingsActionItem(
            id: 'game.ingame_lookup_exe_hash',
            title: t.gal_hook_ingame_lookup_exe_hash_copy,
            subtitleBuilder: (_) =>
                _ingameLookupExeSha256() ??
                t.gal_hook_ingame_lookup_exe_hash_unavailable,
            icon: FushiIcons.fingerprint,
            // 只在真被挡住时出现——平时多一行"复制哈希"是纯噪音。设置页监听准入
            // notifier（settings_home_page / settings_detail_page），所以开着页面
            // 启动游戏也会把这一行刷出来。
            visible: (_) => Platform.isWindows && _isIngameLookupBlocked(),
            onTap: (SettingsContext settingsContext) async {
              final String? sha = _ingameLookupExeSha256();
              if (sha == null) return;
              await Clipboard.setData(ClipboardData(text: sha));
              _showGameSettingsSnackBar(
                settingsContext,
                t.gal_hook_ingame_lookup_exe_hash_copied,
              );
            },
          ),
          // 游戏内查词卡的尺寸三件套（独立尺寸开关 + 仅在开启时展示的宽/高滑杆）。
          // 关闭时跟随 app 内最大宽高（galCardLookupEffectiveSize 解析）。
          // 与覆盖查词窗（settings_schema_lookup 的 overlay_lookup_*）分开：卡片贴在
          // 游戏客户区里、要避开正文，浮窗浮在整块桌面上，两者合适尺寸本就不同；共用
          // 一组键时只能二选一（游戏内过小 / 浮窗过大）。
          //
          // 归属：与 #938 把整个 gal_hook_overlay section 从 settings_schema_lookup.dart
          // 移进本文件同一条理由——这三项只对 galgame 直连覆盖窗（Windows-only 的
          // 引擎 hook 注入）有意义，留在查词分类里会让 Android/iOS/macOS/Linux 用户在
          // 「查词 → 弹窗窗口」分区和设置搜索里都看到一个永远不生效的 galgame 设置项。
          // 这里是 destination 级 + item 级双重 Platform.isWindows 门。
          SettingsSwitchItem(
            id: 'game.gal_card_lookup_independent_size',
            title: t.gal_card_lookup_independent_size,
            subtitle: t.gal_card_lookup_independent_size_hint,
            icon: FushiIcons.dashboardCustomize,
            // 与 PreferencesRepository.galCardLookupIndependentSize 的读取默认一致。
            defaultValue: false,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galCardLookupIndependentSize,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalCardLookupIndependentSize(
                value,
              );
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'game.gal_card_lookup_max_width',
            titleReadout: true,
            title: t.gal_card_lookup_max_width,
            icon: FushiIcons.swap,
            // 读取默认 = PreferencesRepository.defaultPopupMaxWidth（实例字段，400）。
            defaultValue: 400.0,
            min: 250,
            max: 2000,
            divisions: 175,
            visible: (SettingsContext settingsContext) =>
                Platform.isWindows &&
                settingsContext.appModel.galCardLookupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galCardLookupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setGalCardLookupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'game.gal_card_lookup_max_height',
            titleReadout: true,
            title: t.gal_card_lookup_max_height,
            icon: Icons.height_outlined,
            // 读取默认 = PreferencesRepository.defaultPopupMaxHeight（实例字段，360）。
            defaultValue: 360.0,
            min: 200,
            max: 1600,
            divisions: 140,
            visible: (SettingsContext settingsContext) =>
                Platform.isWindows &&
                settingsContext.appModel.galCardLookupIndependentSize,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galCardLookupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setGalCardLookupMaxHeight(value);
              settingsContext.refresh();
            },
          ),
          // ── hook 台词浮窗的交互四件套 ───────────────────────────────────
          // 都走 live setter：设置页一改，正在开着的浮窗立刻跟上，不必退出这一局
          // 游戏再重开（与字号 applyFontSizeFromPreferences 同款纪律）。
          SettingsSwitchItem(
            id: 'game.gal_hook_click_lookup',
            title: t.gal_hook_click_lookup,
            subtitle: t.gal_hook_click_lookup_hint,
            icon: FushiIcons.touch,
            defaultValue: PreferencesRepository.galHookClickLookupDefault,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookClickLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalHookClickLookup(value);
              await GalHookTextOverlayChannel.setClickLookupEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsSegmentedItem<int>(
            id: 'game.gal_hook_lookup_trigger',
            title: t.gal_hook_lookup_trigger,
            subtitle: t.gal_hook_lookup_trigger_hint,
            icon: FushiIcons.mouse,
            defaultValue: PreferencesRepository.galHookLookupTriggerDefault,
            dropdown: true,
            visible: (_) => Platform.isWindows,
            options: <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(
                value: 0,
                label: t.gal_hook_lookup_trigger_left,
              ),
              SettingsSegmentOption<int>(
                value: 1,
                label: t.gal_hook_lookup_trigger_middle,
              ),
              SettingsSegmentOption<int>(
                value: 2,
                label: t.gal_hook_lookup_trigger_side,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookLookupTrigger,
            onChanged: (SettingsContext settingsContext, int value) async {
              await settingsContext.appModel.setGalHookLookupTrigger(value);
              await GalHookTextOverlayChannel.setLookupTrigger(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'game.gal_hook_toolbar_auto_hide',
            title: t.gal_hook_toolbar_auto_hide,
            subtitle: t.gal_hook_toolbar_auto_hide_hint,
            icon: FushiIcons.visibilityOff,
            defaultValue: PreferencesRepository.galHookToolbarAutoHideDefault,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookToolbarAutoHide,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalHookToolbarAutoHide(value);
              await GalHookTextOverlayChannel.setToolbarAutoHide(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'game.gal_hook_toolbar_labels',
            title: t.gal_hook_toolbar_labels,
            subtitle: t.gal_hook_toolbar_labels_hint,
            icon: FushiIcons.title,
            defaultValue: PreferencesRepository.galHookToolbarLabelsDefault,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookToolbarLabels,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalHookToolbarLabels(value);
              await GalHookTextOverlayChannel.setToolbarLabels(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'game.gal_hook_passthrough_blocks_mouse',
            title: t.gal_hook_passthrough_blocks_mouse,
            subtitle: t.gal_hook_passthrough_blocks_mouse_hint,
            icon: Icons.ads_click_outlined,
            defaultValue:
                PreferencesRepository.galHookPassThroughBlocksMouseDefault,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookPassThroughBlocksMouse,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setGalHookPassThroughBlocksMouse(value);
              await GalHookTextOverlayChannel.setPassThroughBlocksMouse(value);
              settingsContext.refresh();
            },
          ),
          // 一句台词被引擎分多次吐出来时折成一条（用户报的 Zato 症状：一段台词
          // 分多次点击显示，工作台里第二句出现两次、字数被重复统计）。这是文本
          // **采集**行为，跟浮窗样式无关，所以留在采集这一节。
          SettingsSwitchItem(
            id: 'game.fold_progressive_lines',
            title: t.gal_hook_fold_progressive_lines,
            subtitle: t.gal_hook_fold_progressive_lines_hint,
            icon: Icons.merge_type,
            defaultValue:
                PreferencesRepository.galHookFoldProgressiveLinesDefault,
            // 与兄弟项 game.ingame_lookup 同门：折叠只对引擎 hook 行生效，而
            // engineHook 行只由 Windows-only 的 GalHookSessionController 产出。
            // 在其他平台露出来只会让用户对着一个永远不生效的开关。
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookFoldProgressiveLines,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setGalHookFoldProgressiveLines(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_gal_hook_overlay,
        visible: (_) => Platform.isWindows,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'game.gal_hook_text_font',
            title: t.gal_hook_text_font,
            subtitle: t.gal_hook_text_font_hint,
            icon: FushiIcons.font,
            showIcon: true,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(target: FontTarget.gameLookup),
              );
              await GalHookTextOverlayController.instance
                  .applyFontFromSettings();
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'game.gal_hook_text_font_size',
            title: t.gal_hook_text_font_size,
            subtitle: t.gal_hook_text_font_size_hint,
            icon: FushiIcons.fontSize,
            defaultValue: PreferencesRepository.galHookTextFontSizeDefault,
            min: PreferencesRepository.galHookTextFontSizeMin,
            max: PreferencesRepository.galHookTextFontSizeMax,
            step: 1,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextFontSize,
            format: (double value) => '${value.round()} px',
            onChanged: (SettingsContext settingsContext, double value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () => settingsContext.appModel.setGalHookTextFontSize(value),
                ),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_letter_spacing',
            title: t.gal_hook_text_letter_spacing,
            subtitle: t.gal_hook_text_letter_spacing_hint,
            icon: Icons.space_bar,
            defaultValue: PreferencesRepository.galHookTextLetterSpacingDefault,
            min: PreferencesRepository.galHookTextLetterSpacingMin,
            max: PreferencesRepository.galHookTextLetterSpacingMax,
            divisions: 28,
            step: 0.5,
            titleReadout: true,
            label: (double value) => '${value.toStringAsFixed(1)} px',
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextLetterSpacing,
            onChanged: (SettingsContext settingsContext, double value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () => settingsContext.appModel.setGalHookTextLetterSpacing(
                    value,
                  ),
                ),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_line_height',
            title: t.gal_hook_text_line_height,
            subtitle: t.gal_hook_text_line_height_hint,
            icon: Icons.format_line_spacing,
            defaultValue: PreferencesRepository.galHookTextLineHeightDefault,
            min: PreferencesRepository.galHookTextLineHeightMin,
            max: PreferencesRepository.galHookTextLineHeightMax,
            divisions: 24,
            step: 0.05,
            titleReadout: true,
            label: (double value) => '${value.toStringAsFixed(2)}×',
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextLineHeight,
            onChanged: (SettingsContext settingsContext, double value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () =>
                      settingsContext.appModel.setGalHookTextLineHeight(value),
                ),
          ),
          SettingsSwitchItem(
            id: 'game.gal_hook_text_bold',
            title: t.gal_hook_text_bold,
            subtitle: t.gal_hook_text_bold_hint,
            icon: Icons.format_bold,
            // 与 PreferencesRepository.galHookTextBold 的读取默认一致。
            defaultValue: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextBold,
            onChanged: (SettingsContext settingsContext, bool value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () => settingsContext.appModel.setGalHookTextBold(value),
                ),
          ),
          SettingsSegmentedItem<String>(
            id: 'game.gal_hook_text_alignment',
            title: t.gal_hook_text_alignment,
            icon: Icons.format_align_center,
            defaultValue: 'center',
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'center',
                label: t.gal_hook_text_alignment_center,
              ),
              SettingsSegmentOption<String>(
                value: 'left',
                label: t.gal_hook_text_alignment_left,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextAlignment,
            onChanged: (SettingsContext settingsContext, String value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () => settingsContext.appModel.setGalHookTextAlignment(value),
                ),
          ),
          // BUG-1890：垂直对齐单列一项，不与水平对齐合成三选一——两者是正交的两个
          // 轴，合并会造出「选了顶部就没法同时左对齐」这种假互斥。
          SettingsSegmentedItem<String>(
            id: 'game.gal_hook_text_vertical_alignment',
            title: t.gal_hook_text_vertical_alignment,
            icon: Icons.vertical_align_center,
            defaultValue: 'center',
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'center',
                label: t.gal_hook_text_vertical_alignment_center,
              ),
              SettingsSegmentOption<String>(
                value: 'top',
                label: t.gal_hook_text_vertical_alignment_top,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.galHookTextVerticalAlignment,
            onChanged: (SettingsContext settingsContext, String value) =>
                _commitGalHookAppearance(
                  settingsContext,
                  () => settingsContext.appModel
                      .setGalHookTextVerticalAlignment(value),
                ),
          ),
          _galHookColorItem(
            id: 'game.gal_hook_text_color',
            title: t.gal_hook_text_color,
            icon: Icons.format_color_text,
            defaultColor: PreferencesRepository.galHookTextColorDefault,
            value: (SettingsContext context) =>
                context.appModel.galHookTextColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextColor(value),
            themedColor: (GalHookCaptionColors themed) => themed.text,
          ),
        ],
      ),
      SettingsSection(
        title: t.gal_hook_overlay_legibility_section,
        visible: (_) => Platform.isWindows,
        collapsedByDefault: true,
        items: <SettingsItem>[
          _galHookColorItem(
            id: 'game.gal_hook_text_background_color',
            title: t.gal_hook_text_background_color,
            icon: Icons.format_color_fill,
            defaultColor: PreferencesRepository.galHookTextBackgroundColorDefault,
            value: (SettingsContext context) =>
                context.appModel.galHookTextBackgroundColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextBackgroundColor(value),
            themedColor: (GalHookCaptionColors themed) => themed.background,
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_background_opacity',
            title: t.gal_hook_text_background_opacity,
            subtitle: t.gal_hook_text_background_opacity_hint,
            icon: Icons.opacity,
            defaultValue:
                PreferencesRepository.galHookTextBackgroundOpacityDefault,
            min: 0,
            max: 1,
            divisions: 20,
            step: 0.05,
            titleReadout: true,
            label: (double value) => '${(value * 100).round()}%',
            value: (SettingsContext context) =>
                context.appModel.galHookTextBackgroundOpacity,
            onChanged: (SettingsContext context, double value) =>
                _commitGalHookAppearance(
                  context,
                  () => context.appModel.setGalHookTextBackgroundOpacity(value),
                ),
          ),
          _galHookColorItem(
            id: 'game.gal_hook_text_outline_color',
            title: t.gal_hook_text_outline_color,
            icon: Icons.border_color_outlined,
            defaultColor: PreferencesRepository.galHookTextOutlineColorDefault,
            enableAlpha: true,
            value: (SettingsContext context) =>
                context.appModel.galHookTextOutlineColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextOutlineColor(value),
            themedColor: (GalHookCaptionColors themed) => themed.outline,
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_outline_width',
            title: t.gal_hook_text_outline_width,
            subtitle: t.gal_hook_text_outline_width_hint,
            icon: Icons.line_weight,
            defaultValue: PreferencesRepository.galHookTextOutlineWidthDefault,
            min: PreferencesRepository.galHookTextOutlineWidthMin,
            max: PreferencesRepository.galHookTextOutlineWidthMax,
            divisions: 24,
            step: 0.25,
            titleReadout: true,
            label: (double value) => '${value.toStringAsFixed(2)} px',
            value: (SettingsContext context) =>
                context.appModel.galHookTextOutlineWidth,
            onChanged: (SettingsContext context, double value) =>
                _commitGalHookAppearance(
                  context,
                  () => context.appModel.setGalHookTextOutlineWidth(value),
                ),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_padding',
            title: t.gal_hook_text_padding,
            subtitle: t.gal_hook_text_padding_hint,
            icon: Icons.padding,
            defaultValue: PreferencesRepository.galHookTextPaddingDefault,
            min: PreferencesRepository.galHookTextPaddingMin,
            max: PreferencesRepository.galHookTextPaddingMax,
            divisions: 40,
            step: 2,
            titleReadout: true,
            label: (double value) => '${value.round()} px',
            value: (SettingsContext context) =>
                context.appModel.galHookTextPadding,
            onChanged: (SettingsContext context, double value) =>
                _commitGalHookAppearance(
                  context,
                  () => context.appModel.setGalHookTextPadding(value),
                ),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_corner_radius',
            title: t.gal_hook_text_corner_radius,
            subtitle: t.gal_hook_text_corner_radius_hint,
            icon: Icons.rounded_corner,
            defaultValue: PreferencesRepository.galHookTextCornerRadiusDefault,
            min: PreferencesRepository.galHookTextCornerRadiusMin,
            max: PreferencesRepository.galHookTextCornerRadiusMax,
            divisions: 40,
            step: 1,
            titleReadout: true,
            label: (double value) => '${value.round()} px',
            value: (SettingsContext context) =>
                context.appModel.galHookTextCornerRadius,
            onChanged: (SettingsContext context, double value) =>
                _commitGalHookAppearance(
                  context,
                  () => context.appModel.setGalHookTextCornerRadius(value),
                ),
          ),
        ],
      ),
    ],
  );
}

Future<void> _commitGalHookAppearance(
  SettingsContext context,
  Future<void> Function() write,
) async {
  await write();
  await GalHookTextOverlayController.instance.applyAppearanceFromPreferences();
  context.refresh();
}

SettingsCustomItem _galHookColorItem({
  required String id,
  required String title,
  required IconData icon,
  required int defaultColor,
  required int Function(SettingsContext context) value,
  required Future<void> Function(SettingsContext context, int value) onChanged,
  required int Function(GalHookCaptionColors themed) themedColor,
  bool enableAlpha = false,
}) {
  return SettingsCustomItem(
    id: id,
    icon: icon,
    searchTitle: title,
    builder: (SettingsContext settingsContext) {
      final ThemeData theme = Theme.of(settingsContext.context);
      final int stored = value(settingsContext);
      // 没自定义过（未写 / 写的是历史默认）= 跟随主题：色样显示主题配对色，
      // 副标题标明正在跟随（判据与台词窗下发同一个函数）。
      final bool followsTheme =
          galHookCaptionColorFollowsTheme(stored, defaultColor);
      final Color current = Color(
        followsTheme ? themedColor(galHookThemeCaptionColors(theme)) : stored,
      );
      final ColorScheme colors = theme.colorScheme;
      // 自定义行不经渲染层的 settingsResetSpecFor，这里自己接 settings kit 的
      // 「已改过 → 恢复默认」：与开关 / 滑杆同一套行首圆点 + 行尾重置钮。
      return SettingsModifiedRow(
        // 「恢复默认」= 回到跟随主题。
        modified: !followsTheme,
        onReset: () => unawaited(
          _commitGalHookAppearance(
            settingsContext,
            () => onChanged(settingsContext, defaultColor),
          ),
        ),
        child: AdaptiveSettingsRow(
          title: title,
          subtitle: followsTheme ? t.theme_role_follows_theme : null,
          icon: icon,
          showIcon: true,
          // M3E 色样：28 圆点 + outlineVariant 描边（浅色 / 透明色在卡片底上也
          // 读得出边界）。
          trailing: FushiColorSwatch(
            color: current,
            size: 28,
            shape: FushiColorSwatchShape.dot,
            borderColor: colors.outlineVariant,
          ),
          onTap: () => unawaited(() async {
            final Color? selected = await _pickGalHookColor(
              settingsContext.context,
              title: title,
              initial: current,
              enableAlpha: enableAlpha,
              followsTheme: followsTheme,
              followThemeColor: Color(defaultColor),
            );
            // 跟随中直接按「完成」= 没改：不把此刻的主题色冻结成自定义值。
            if (selected == null ||
                selected.toARGB32() == stored ||
                selected.toARGB32() == current.toARGB32()) {
              return;
            }
            await _commitGalHookAppearance(
              settingsContext,
              () => onChanged(settingsContext, selected.toARGB32()),
            );
          }()),
        ),
      );
    },
  );
}

Future<Color?> _pickGalHookColor(
  BuildContext context, {
  required String title,
  required Color initial,
  required bool enableAlpha,
  bool followsTheme = false,
  Color? followThemeColor,
}) async {
  Color picked = initial;
  bool confirmed = false;
  bool follow = false;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: ColorPicker(
          pickerColor: initial,
          onColorChanged: (Color color) {
            picked = enableAlpha
                ? color
                : Color(0xFF000000 | (color.toARGB32() & 0x00FFFFFF));
          },
          portraitOnly: true,
          enableAlpha: enableAlpha,
          displayThumbColor: true,
          hexInputBar: true,
          labelTypes: const <ColorLabelType>[],
        ),
      ),
      actions: <Widget>[
        // 「跟随主题」= 写回历史默认值（台词窗把它解释成跟随主题配对色）。
        if (followThemeColor != null && !followsTheme)
          FushiTextButton(
            onPressed: () {
              follow = true;
              Navigator.of(dialogContext).pop();
            },
            child: Text(t.theme_role_follows_theme),
          ),
        FushiTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: () {
            confirmed = true;
            Navigator.of(dialogContext).pop();
          },
          child: Text(t.dialog_done),
        ),
      ],
    ),
  );
  if (follow) return followThemeColor;
  return confirmed ? picked : null;
}

/// 本局游戏的查词准入快照。非 Windows 上恒为 [GalLookupAdmission.unknown]
/// （runner 只在 Windows 推这条事件），因此下面两个判据在别的平台恒为"没挡住"。
GalLookupAdmission _ingameLookupAdmission() =>
    GalIngameLookupController.instance.admission.value;

/// 准入是否把本局的游戏内查词整个挡在门外。判据的唯一真值在
/// [GalLookupAdmissionState.blocksLookup]——尤其 unknown（"还不知道"）不算挡住。
bool _isIngameLookupBlocked() =>
    _ingameLookupAdmission().state.blocksLookup;

/// 开关**副标题**上的原因文案；没被挡住时返回 null（回落静态 hint）。
/// 开关本身不置灰，理由见上面构造处。
String? _ingameLookupBlockedReason() {
  switch (_ingameLookupAdmission().state) {
    case GalLookupAdmissionState.engineUnsupported:
      return t.gal_hook_ingame_lookup_engine_unsupported;
    case GalLookupAdmissionState.identityRejected:
      return t.gal_hook_ingame_lookup_version_unsupported;
    case GalLookupAdmissionState.unknown:
    case GalLookupAdmissionState.identityAccepted:
    case GalLookupAdmissionState.sensorInstalled:
      return null;
  }
}

/// 当前游戏主 exe 的 SHA-256；算不出来（拿不到路径 / 权限不足）时为 null。
/// **绝不**在这里编一个占位串——用户会把它当真值报回来。
String? _ingameLookupExeSha256() {
  final String sha = _ingameLookupAdmission().executableSha256;
  return sha.isEmpty ? null : sha;
}

/// 轻量提示条（与 settings_schema_video.dart 的 `_showVideoSettingsSnackBar` 同款）。
void _showGameSettingsSnackBar(
    SettingsContext settingsContext, String message) {
  final BuildContext ctx = settingsContext.context;
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(FushiSnackBar(content: Text(message)));
}
