import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 「游戏」一级设置分类（审计 K / Phase 3.12：游戏域此前没有任何 destination，
/// 游戏库 / 捕获工作台 / 兼容性诊断从设置主页既不可达也不可搜）。
///
/// 三条导航项直达 games 顶层 tab 的对应子区：不 push 第二份页面实例（捕获工作台
/// 持有 Hook 会话，[TexthookerPage] 由 [HomeGamePage] 的 IndexedStack 保态），
/// 而是复用既有跳转真相源——`homeShellTabNotifier` 切 tab + `gameSectionNotifier`
/// 选子区（与原生 Hook 浮窗 `openWorkbench` / 首页 dashboard 卡片同一条路径）。
///
/// 门控：与 games 顶层 tab 完全一致（`homeActiveTabs` 的
/// `gamesEnabled: Platform.isWindows`——galgame 引擎-hook 注入 Windows-only）。
/// 非 Windows 平台整个分类不可见、不进搜索索引。
///
/// 浏览器扩展页不属于游戏域（它是查词域的桌面扩展安装助手），其搜索入口登记在
/// 「查词」分类（settings_schema_lookup 的 `lookup.browser_extension`），不在此处。
SettingsDestination buildGameDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.game,
    group: SettingsDestinationGroup.content,
    title: t.nav_game,
    summary: t.game_home_subtitle,
    icon: Icons.sports_esports_outlined,
    visible: (SettingsContext settingsContext) => Platform.isWindows,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'game.library',
            title: t.game_library,
            subtitle: t.game_home_subtitle,
            icon: Icons.videogame_asset_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.library;
            },
          ),
          SettingsNavigationItem(
            id: 'game.capture_workspace',
            title: t.game_capture_workbench,
            icon: Icons.sensors_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.monitor;
            },
          ),
          SettingsNavigationItem(
            id: 'game.diagnostics',
            title: t.game_diagnostics,
            icon: Icons.monitor_heart_outlined,
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
          // KiriKiri 游戏内查词：命中的字直接在**游戏渲染树内部**弹出词典卡片
          // （不抢焦点、不 alt-tab、跟随全屏与窗口变换）。
          SettingsSwitchItem(
            id: 'game.ingame_lookup',
            title: t.gal_hook_ingame_lookup,
            subtitle: t.gal_hook_ingame_lookup_hint,
            icon: Icons.crop_free,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.galIngameLookupEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setGalIngameLookupEnabled(value);
              // 与台词浮窗字号同款纪律：写完 pref 立刻推给编排器，否则开关只落了盘，
              // 本局游戏里不生效（要退出重进一局）。
              await GalIngameLookupController.instance
                  .applyEnabledFromPreferences();
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
            icon: Icons.font_download_outlined,
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
            icon: Icons.format_size,
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
              () => settingsContext.appModel.setGalHookTextLetterSpacing(value),
            ),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_line_height',
            title: t.gal_hook_text_line_height,
            subtitle: t.gal_hook_text_line_height_hint,
            icon: Icons.format_line_spacing,
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
              () => settingsContext.appModel.setGalHookTextLineHeight(value),
            ),
          ),
          SettingsSwitchItem(
            id: 'game.gal_hook_text_bold',
            title: t.gal_hook_text_bold,
            subtitle: t.gal_hook_text_bold_hint,
            icon: Icons.format_bold,
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
          _galHookColorItem(
            id: 'game.gal_hook_text_color',
            title: t.gal_hook_text_color,
            icon: Icons.format_color_text,
            value: (SettingsContext context) =>
                context.appModel.galHookTextColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextColor(value),
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
            value: (SettingsContext context) =>
                context.appModel.galHookTextBackgroundColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextBackgroundColor(value),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_background_opacity',
            title: t.gal_hook_text_background_opacity,
            subtitle: t.gal_hook_text_background_opacity_hint,
            icon: Icons.opacity,
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
            enableAlpha: true,
            value: (SettingsContext context) =>
                context.appModel.galHookTextOutlineColor,
            onChanged: (SettingsContext context, int value) =>
                context.appModel.setGalHookTextOutlineColor(value),
          ),
          SettingsSliderItem(
            id: 'game.gal_hook_text_outline_width',
            title: t.gal_hook_text_outline_width,
            subtitle: t.gal_hook_text_outline_width_hint,
            icon: Icons.line_weight,
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
  required int Function(SettingsContext context) value,
  required Future<void> Function(SettingsContext context, int value) onChanged,
  bool enableAlpha = false,
}) {
  return SettingsCustomItem(
    id: id,
    icon: icon,
    searchTitle: title,
    builder: (SettingsContext settingsContext) {
      final Color current = Color(value(settingsContext));
      return AdaptiveSettingsRow(
        title: title,
        icon: icon,
        showIcon: true,
        trailing: FushiColorSwatch(
          color: current,
          size: 24,
          borderColor: Theme.of(settingsContext.context).dividerColor,
        ),
        onTap: () => unawaited(() async {
          final Color? selected = await _pickGalHookColor(
            settingsContext.context,
            title: title,
            initial: current,
            enableAlpha: enableAlpha,
          );
          if (selected == null || selected.toARGB32() == current.toARGB32()) {
            return;
          }
          await _commitGalHookAppearance(
            settingsContext,
            () => onChanged(settingsContext, selected.toARGB32()),
          );
        }()),
      );
    },
  );
}

Future<Color?> _pickGalHookColor(
  BuildContext context, {
  required String title,
  required Color initial,
  required bool enableAlpha,
}) async {
  Color picked = initial;
  bool confirmed = false;
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
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
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: () {
            confirmed = true;
            Navigator.of(dialogContext).pop();
          },
          child: Text(t.dialog_done),
        ),
      ],
    ),
  );
  return confirmed ? picked : null;
}
