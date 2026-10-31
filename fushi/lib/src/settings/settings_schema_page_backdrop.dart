import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/gallery_image_picker.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

/// 「外观 › 页面背景」子页（2026-10-30）：预设缩略图选择器 + 按预设出现的调节行。
/// 选「自定义图片」时换成图片 / 竖屏图 / 模糊 / 遮罩浓度 / 从图片取色几行。
SettingsDestination buildPageBackdropDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.page_backdrop_title,
    summary: t.page_backdrop_hint,
    icon: FushiIcons.pageBackdrop,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'appearance.page_backdrop.section.style',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 预设 / 图片变化时行级可见性重新求值（图片行、强度行随预设出现）。
        liveListenable: (_) => pageBackdropSettings,
        title: t.page_backdrop_style,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.page_backdrop.preset',
            icon: FushiIcons.pageBackdrop,
            searchTitle: t.page_backdrop_style,
            builder: (SettingsContext settingsContext) =>
                _PageBackdropPresetPicker(settingsContext: settingsContext),
          ),
          SettingsSegmentedItem<PageBackdropStrength>(
            id: 'appearance.page_backdrop.strength',
            title: t.page_backdrop_strength,
            subtitle: t.page_backdrop_strength_hint,
            icon: FushiIcons.opacity,
            visible: (SettingsContext c) => _isShapePreset(_theme(c)),
            options: <SettingsSegmentOption<PageBackdropStrength>>[
              SettingsSegmentOption<PageBackdropStrength>(
                value: PageBackdropStrength.subtle,
                label: t.page_backdrop_strength_subtle,
              ),
              SettingsSegmentOption<PageBackdropStrength>(
                value: PageBackdropStrength.standard,
                label: t.page_backdrop_strength_standard,
              ),
              SettingsSegmentOption<PageBackdropStrength>(
                value: PageBackdropStrength.strong,
                label: t.page_backdrop_strength_strong,
              ),
            ],
            selected: (SettingsContext c) => _theme(c).pageBackdropStrength,
            onChanged: (SettingsContext c, PageBackdropStrength value) =>
                _theme(c).setPageBackdropStrength(value),
            defaultValue: PageBackdropStrength.standard,
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.page_backdrop.section.image',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 预设 / 图片变化时行级可见性重新求值（图片行、强度行随预设出现）。
        liveListenable: (_) => pageBackdropSettings,
        title: t.page_backdrop_preset_custom,
        visible: (SettingsContext c) =>
            _theme(c).pageBackdropPreset == PageBackdropPreset.custom,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.page_backdrop.image',
            title: t.page_backdrop_image,
            subtitleBuilder: (SettingsContext c) =>
                pageBackdropSettings.value.landscapeImagePath == null
                ? t.page_backdrop_image_empty
                : t.page_backdrop_image_set,
            icon: FushiIcons.image,
            onTap: (SettingsContext c) =>
                pickPageBackdropImage(c, portrait: false),
          ),
          SettingsNavigationItem(
            id: 'appearance.page_backdrop.portrait_image',
            title: t.page_backdrop_portrait_image,
            subtitleBuilder: (SettingsContext c) =>
                pageBackdropSettings.value.portraitImagePath == null
                ? t.page_backdrop_portrait_image_shared
                : t.page_backdrop_image_set,
            icon: FushiIcons.portraitImage,
            visible: (_) => pageBackdropSettings.value.hasCustomImage,
            onTap: (SettingsContext c) =>
                pickPageBackdropImage(c, portrait: true),
          ),
          SettingsNavigationItem(
            id: 'appearance.page_backdrop.portrait_image_clear',
            title: t.page_backdrop_portrait_image_clear,
            icon: FushiIcons.restart,
            visible: (_) =>
                pageBackdropSettings.value.hasCustomImage &&
                pageBackdropSettings.value.portraitImagePath != null,
            onTap: (SettingsContext c) async {
              await _theme(c).clearPageBackdropPortraitImage();
              c.refresh();
            },
          ),
          SettingsSegmentedItem<PageBackdropBlur>(
            id: 'appearance.page_backdrop.blur',
            title: t.page_backdrop_blur,
            icon: FushiIcons.blur,
            visible: (_) => pageBackdropSettings.value.hasCustomImage,
            options: <SettingsSegmentOption<PageBackdropBlur>>[
              SettingsSegmentOption<PageBackdropBlur>(
                value: PageBackdropBlur.none,
                label: t.page_backdrop_blur_none,
              ),
              SettingsSegmentOption<PageBackdropBlur>(
                value: PageBackdropBlur.light,
                label: t.page_backdrop_blur_light,
              ),
              SettingsSegmentOption<PageBackdropBlur>(
                value: PageBackdropBlur.heavy,
                label: t.page_backdrop_blur_heavy,
              ),
            ],
            selected: (SettingsContext c) => _theme(c).pageBackdropBlur,
            onChanged: (SettingsContext c, PageBackdropBlur value) =>
                _theme(c).setPageBackdropBlur(value),
            defaultValue: PageBackdropBlur.none,
          ),
          SettingsSliderItem(
            id: 'appearance.page_backdrop.scrim',
            title: t.page_backdrop_scrim,
            subtitle: t.page_backdrop_scrim_hint,
            icon: FushiIcons.scrim,
            visible: (_) => pageBackdropSettings.value.hasCustomImage,
            min: kPageBackdropScrimMin,
            max: kPageBackdropScrimMax,
            divisions: 17,
            label: (double value) => '${(value * 100).round()}%',
            titleReadout: true,
            commitOnRelease: true,
            value: (SettingsContext c) => _theme(c).pageBackdropScrim,
            onChanged: (SettingsContext c, double value) =>
                _theme(c).setPageBackdropScrim(value),
            defaultValue: kPageBackdropScrimDefault,
          ),
          SettingsSwitchItem(
            id: 'appearance.page_backdrop.follow_accent',
            title: t.page_backdrop_follow_accent,
            subtitle: t.page_backdrop_follow_accent_hint,
            icon: FushiIcons.appearance,
            visible: (_) => pageBackdropSettings.value.hasCustomImage,
            value: (SettingsContext c) => _theme(c).followPageBackdropAccent,
            onChanged: (SettingsContext c, bool value) async {
              await _theme(c).setFollowPageBackdropAccent(value);
              c.refresh();
            },
            defaultValue: true,
          ),
          SettingsCustomItem(
            id: 'appearance.page_backdrop.accent_candidates',
            icon: FushiIcons.appearance,
            searchTitle: t.page_backdrop_accent_candidates,
            visible: (SettingsContext c) =>
                pageBackdropSettings.value.hasCustomImage &&
                _theme(c).followPageBackdropAccent &&
                _theme(c).pageBackdropSeedCandidates.isNotEmpty,
            builder: (SettingsContext c) =>
                _PageBackdropAccentCandidates(settingsContext: c),
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.page_backdrop.section.motion',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 预设 / 图片变化时行级可见性重新求值（图片行、强度行随预设出现）。
        liveListenable: (_) => pageBackdropSettings,
        visible: (SettingsContext c) =>
            _theme(c).pageBackdropPreset != PageBackdropPreset.plain,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'appearance.page_backdrop.motion',
            title: t.page_backdrop_motion,
            subtitle: t.page_backdrop_motion_hint,
            icon: FushiIcons.ambientMotion,
            value: (SettingsContext c) => _theme(c).pageBackdropMotion,
            onChanged: (SettingsContext c, bool value) =>
                _theme(c).setPageBackdropMotion(value),
            defaultValue: false,
          ),
        ],
      ),
    ],
  );
}

ThemeNotifier _theme(SettingsContext c) => c.appModel.themeNotifier;

bool _isShapePreset(ThemeNotifier theme) => switch (theme.pageBackdropPreset) {
  PageBackdropPreset.plain || PageBackdropPreset.custom => false,
  _ => true,
};

/// 选一张图当背景（[portrait] = 竖屏单独的那张）。取消什么都不做。
///
/// 任何一步失败（选图器的平台异常 / 权限、复制、数据目录、偏好写入）都告诉用户
/// 并记应用日志——不只是复制时的 [FileSystemException]，否则别的失败会变成
/// 未处理的异步错误、用户点了没反应。
Future<void> pickPageBackdropImage(
  SettingsContext settingsContext, {
  required bool portrait,
}) async {
  try {
    final File? picked = await pickGalleryImageFile();
    if (picked == null) return;
    await _theme(
      settingsContext,
    ).importPageBackdropImage(picked, portrait: portrait);
  } catch (error, stack) {
    ErrorLogService.instance.log('page_backdrop.import_image', error, stack);
    final BuildContext ctx = settingsContext.context;
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        FushiSnackBar(content: Text(t.page_backdrop_image_import_failed)),
      );
    }
  }
  settingsContext.refresh();
}

String _presetLabel(PageBackdropPreset preset) => switch (preset) {
  PageBackdropPreset.corner => t.page_backdrop_preset_corner,
  PageBackdropPreset.plain => t.page_backdrop_preset_plain,
  PageBackdropPreset.confetti => t.page_backdrop_preset_confetti,
  PageBackdropPreset.mesh => t.page_backdrop_preset_mesh,
  PageBackdropPreset.arc => t.page_backdrop_preset_arc,
  PageBackdropPreset.wave => t.page_backdrop_preset_wave,
  PageBackdropPreset.sunny => t.page_backdrop_preset_sunny,
  PageBackdropPreset.custom => t.page_backdrop_preset_custom,
};

/// 预设横排的高度：[_PresetTile] 的缩略图 70 + 间距 6 + 两行 `labelMedium`
/// （按系统字号缩放后的行高）+ 余量，不低于默认字号下的 112。
double _presetRowHeight(BuildContext context, ThemeData theme) {
  final TextStyle? style = theme.textTheme.labelMedium;
  final double line =
      MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 12) *
      (style?.height ?? 1.4);
  final double needed = 70 + 6 + 2 * line + 4;
  return needed > 112 ? needed : 112;
}

/// 横向预设缩略图：每张都是真实的背景层按当前配色缩小画出来；选中项圆角变大 +
/// 描边 + 勾（M3E 形变）。选「自定义图片」还没有图时直接弹选图。
class _PageBackdropPresetPicker extends StatelessWidget {
  const _PageBackdropPresetPicker({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PageBackdropSettings>(
      valueListenable: pageBackdropSettings,
      builder:
          (BuildContext context, PageBackdropSettings settings, Widget? _) {
            final ThemeData theme = Theme.of(context);
            final bool apple = isGlassDesign(context);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    // 缩略图 70 + 间距 6 + 两行标签：标签行高随系统字号放大，
                    // 写死 112 在大字号下两行标签会把格子撑出这一行。
                    height: _presetRowHeight(context, theme),
                    // 桌面鼠标按住横拖也要能滚（默认 dragDevices 不含鼠标）。
                    child: HorizontalDragScrollable(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: PageBackdropPreset.values.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (BuildContext context, int index) {
                          final PageBackdropPreset preset =
                              PageBackdropPreset.values[index];
                          return _PresetTile(
                            preset: preset,
                            settings: settings,
                            selected: settings.preset == preset,
                            onTap: () => _select(preset, settings),
                          );
                        },
                      ),
                    ),
                  ),
                  if (apple)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Text(
                        t.page_backdrop_apple_hint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
    );
  }

  Future<void> _select(
    PageBackdropPreset preset,
    PageBackdropSettings settings,
  ) async {
    if (preset == PageBackdropPreset.custom &&
        settings.landscapeImagePath == null) {
      await pickPageBackdropImage(settingsContext, portrait: false);
      return;
    }
    await settingsContext.appModel.themeNotifier.setPageBackdropPreset(preset);
    settingsContext.refresh();
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.settings,
    required this.selected,
    required this.onTap,
  });

  final PageBackdropPreset preset;
  final PageBackdropSettings settings;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    final bool needsImage =
        preset == PageBackdropPreset.custom &&
        settings.landscapeImagePath == null;
    final String label = _presetLabel(preset);
    // M3E 选中形变：小件圆角 → 卡片圆角（取形状分级 token，不手写数字）。
    final BorderRadius radius = selected
        ? FushiM3eShape.cardRadius
        : FushiM3eShape.smallRadius;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: FushiPressScale(
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: SizedBox(
            width: 112,
            child: Column(
              children: <Widget>[
                AnimatedContainer(
                  duration: duration,
                  curve: FushiMotion.standard,
                  width: 112,
                  height: 70,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: radius,
                    border: Border.all(
                      color: selected ? cs.primary : cs.outlineVariant,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (needsImage)
                        Icon(FushiIcons.addImage, color: cs.onSurfaceVariant)
                      else
                        PageBackdropLayer(
                          settings: settings.copyWith(preset: preset),
                          animate: false,
                        ),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: AnimatedScale(
                          duration: duration,
                          curve: FushiMotion.standard,
                          scale: selected ? 1 : 0,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              FushiIcons.check,
                              size: 14,
                              color: cs.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 从图片取出的候选种子色：一排圆点，点哪个用哪个当应用配色种子。
class _PageBackdropAccentCandidates extends StatelessWidget {
  const _PageBackdropAccentCandidates({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  Widget build(BuildContext context) {
    final ThemeNotifier theme = settingsContext.appModel.themeNotifier;
    final ThemeData themeData = Theme.of(context);
    final ColorScheme cs = themeData.colorScheme;
    final List<Color> candidates = theme.pageBackdropSeedCandidates;
    final int selected = candidates.isEmpty
        ? 0
        : theme.pageBackdropAccentIndex.clamp(0, candidates.length - 1);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.page_backdrop_accent_candidates,
                  style: themeData.textTheme.bodyLarge,
                ),
                Text(
                  t.page_backdrop_accent_candidates_hint,
                  style: themeData.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < candidates.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Semantics(
                button: true,
                selected: i == selected,
                label: '${t.page_backdrop_accent_candidates} ${i + 1}',
                child: FushiPressScale(
                  child: InkResponse(
                    radius: 24,
                    onTap: () async {
                      await theme.setPageBackdropAccentIndex(i);
                      settingsContext.refresh();
                    },
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: AnimatedContainer(
                          duration: duration,
                          curve: FushiMotion.standard,
                          width: i == selected ? 34 : 28,
                          height: i == selected ? 34 : 28,
                          decoration: BoxDecoration(
                            color: candidates[i],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: i == selected
                                  ? cs.onSurface
                                  : cs.outlineVariant,
                              width: i == selected ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
