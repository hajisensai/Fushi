import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
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
            icon: Icons.fingerprint_outlined,
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
          // BUG-1890：垂直对齐单列一项，不与水平对齐合成三选一——两者是正交的两个
          // 轴，合并会造出「选了顶部就没法同时左对齐」这种假互斥。
          SettingsSegmentedItem<String>(
            id: 'game.gal_hook_text_vertical_alignment',
            title: t.gal_hook_text_vertical_alignment,
            icon: Icons.vertical_align_center,
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

/// 本局游戏的查词准入快照。非 Windows 上恒为 [GalLookupAdmission.unknown]
/// （runner 只在 Windows 推这条事件），因此下面两个判据在别的平台恒为"没挡住"。
GalLookupAdmission _ingameLookupAdmission() =>
    GalIngameLookupController.instance.admission.value;

/// 准入是否把本局的游戏内查词整个挡在门外。判据的唯一真值在
/// [GalLookupAdmissionState.blocksLookup]——尤其 unknown（"还不知道"）不算挡住。
bool _isIngameLookupBlocked() =>
    _ingameLookupAdmission().state.blocksLookup;

/// 开关被灰掉的原因文案；没被挡住时返回 null（回落静态 hint）。
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
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(message)));
}
