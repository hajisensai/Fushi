import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/module_registry.dart' show isHomeTabVisible;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/crop_image_dialog_page.dart'
    show showCropImageDialog;
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomeTab, homeNavItemFor;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
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
      // 按模块单独设置（反馈 DYI1IOZxSM）：每个主导航模块一行，点进去选这个模块
      // 自己的预设 / 图片；没设的模块跟随上面的全局背景。
      SettingsSection(
        id: 'appearance.page_backdrop.section.modules',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        liveListenable: (_) => pageBackdropModuleOverrides,
        title: t.page_backdrop_module_section,
        footer: t.page_backdrop_module_hint,
        items: <SettingsItem>[
          for (final HomeTab tab in HomeTab.values) _moduleEntry(tab),
        ],
      ),
    ],
  );
}

/// 「按模块设置」里一个模块的入口行。设置 tab 恒在，保证本分组至少一行可见。
SettingsNavigationItem _moduleEntry(HomeTab tab) {
  final String wire = pageBackdropModuleWire(tab);
  return SettingsNavigationItem(
    id: 'appearance.page_backdrop.module.$wire',
    title: homeNavItemFor(tab).label,
    icon: homeNavItemFor(tab).icon,
    subtitleBuilder: (SettingsContext c) => _moduleSummary(tab),
    visible: (SettingsContext c) =>
        isHomeTabVisible(tab, c.appModel.moduleVisibility),
    child: () => buildPageBackdropModuleDestination(tab),
  );
}

String _moduleSummary(HomeTab tab) => PageBackdropModuleTier(tab).summary();

/// 能单独设背景的一层（反馈 DYI1IOZxSM 的模块层、拍板台 xxbbL0j15l 的页面层）：
/// 子页、预设选择器与选图链路按它统一处理。
sealed class PageBackdropTier {
  const PageBackdropTier();

  /// 偏好里这一层的 wire，也是设置项 id 的一段。
  String get wire;

  /// 设置项 id 前缀（模块与页面不同命名空间，id 全局唯一）。
  String get idPrefix;

  String get title;
  IconData get icon;

  /// 本层没单独设时的那一格：模块是「跟随全局」，页面是「跟随模块」。
  String get followLabel;

  /// 子页页脚的说明。
  String get hint;

  /// 本层单独的设置；null = 继承上一层。
  PageBackdropModuleOverride? get own;

  /// 本层单独的设置变了时通知（[own] 的来源）。
  Listenable get overrides;

  /// 本层不单独设时实际生效的设置：模块继承全局，页面继承所属模块。
  PageBackdropSettings get inherited;

  /// 写本层的预设；null = 恢复继承（连同本层的图片一起删）。
  Future<void> setPreset(ThemeNotifier theme, PageBackdropPreset? preset);

  Future<void> clearPortraitImage(ThemeNotifier theme);

  /// 入口行的副标题：继承时写继承谁，否则是本层的预设名。
  String summary() => switch (own) {
    null => followLabel,
    final PageBackdropModuleOverride o => _presetLabel(o.preset),
  };
}

/// 主导航模块这一层：没设就跟随全局。
final class PageBackdropModuleTier extends PageBackdropTier {
  const PageBackdropModuleTier(this.module);

  final HomeTab module;

  @override
  String get wire => pageBackdropModuleWire(module);

  @override
  String get idPrefix => 'appearance.page_backdrop.module.$wire';

  @override
  String get title => homeNavItemFor(module).label;

  @override
  IconData get icon => homeNavItemFor(module).icon;

  @override
  String get followLabel => t.page_backdrop_module_follow_global;

  @override
  String get hint => t.page_backdrop_module_hint;

  @override
  PageBackdropModuleOverride? get own =>
      pageBackdropModuleOverrides.value[module];

  @override
  Listenable get overrides => pageBackdropModuleOverrides;

  @override
  PageBackdropSettings get inherited => pageBackdropSettings.value;

  @override
  Future<void> setPreset(ThemeNotifier theme, PageBackdropPreset? preset) =>
      theme.setPageBackdropModulePreset(module, preset);

  @override
  Future<void> clearPortraitImage(ThemeNotifier theme) =>
      theme.clearPageBackdropModulePortraitImage(module);
}

/// 模块里单独可设的页面这一层：没设就继承所属模块（模块也没设就是全局）。
final class PageBackdropPageTier extends PageBackdropTier {
  const PageBackdropPageTier(this.page);

  final PageBackdropPage page;

  @override
  String get wire => page.wire;

  @override
  String get idPrefix => 'appearance.page_backdrop.page.$wire';

  @override
  String get title => pageBackdropPageLabel(page);

  @override
  IconData get icon => switch (page) {
    PageBackdropPage.srsReview => FushiIcons.ankiCard,
  };

  @override
  String get followLabel => t.page_backdrop_page_follow_module;

  @override
  String get hint => t.page_backdrop_page_hint;

  @override
  PageBackdropModuleOverride? get own => pageBackdropPageOverrides.value[page];

  @override
  Listenable get overrides => pageBackdropPageOverrides;

  @override
  PageBackdropSettings get inherited => pageBackdropSettingsFor(page.module);

  @override
  Future<void> setPreset(ThemeNotifier theme, PageBackdropPreset? preset) =>
      theme.setPageBackdropPagePreset(page, preset);

  @override
  Future<void> clearPortraitImage(ThemeNotifier theme) =>
      theme.clearPageBackdropPagePortraitImage(page);
}

/// 页面的显示名。
String pageBackdropPageLabel(PageBackdropPage page) => switch (page) {
  PageBackdropPage.srsReview => t.page_backdrop_page_srs_review,
};

/// 一个模块自己的背景子页：预设（多一个「跟随全局」）+ 选了自定义图片时的图片行；
/// 模块里有单独可设的页面时再多一组页面入口（拍板台 xxbbL0j15l）。
/// 强度 / 模糊 / 遮罩 / 动效与配色沿用全局，不在这里重复。
SettingsDestination buildPageBackdropModuleDestination(HomeTab tab) {
  final List<PageBackdropPage> pages = <PageBackdropPage>[
    for (final PageBackdropPage page in PageBackdropPage.values)
      if (page.module == tab) page,
  ];
  final PageBackdropModuleTier layer = PageBackdropModuleTier(tab);
  return _layerDestination(
    layer,
    extra: <SettingsSection>[
      if (pages.isNotEmpty)
        SettingsSection(
          id: '${layer.idPrefix}.section.pages',
          presentation: SettingsSectionPresentation.alwaysExpanded,
          // 模块改了也要刷新：页面继承时预览的是模块的背景。
          liveListenable: (_) => Listenable.merge(<Listenable>[
            pageBackdropModuleOverrides,
            pageBackdropPageOverrides,
          ]),
          title: t.page_backdrop_page_section,
          footer: t.page_backdrop_page_hint,
          items: <SettingsItem>[
            for (final PageBackdropPage page in pages) _pageEntry(page),
          ],
        ),
    ],
  );
}

/// 「按页面设置」里一个页面的入口行。
SettingsNavigationItem _pageEntry(PageBackdropPage page) {
  final PageBackdropPageTier layer = PageBackdropPageTier(page);
  return SettingsNavigationItem(
    id: layer.idPrefix,
    title: layer.title,
    icon: layer.icon,
    subtitleBuilder: (SettingsContext c) => layer.summary(),
    child: () => buildPageBackdropPageDestination(page),
  );
}

/// 一个页面自己的背景子页：预设（多一个「跟随模块」，选「纯色」= 这一页不画背景）+
/// 选了自定义图片时的图片行。
SettingsDestination buildPageBackdropPageDestination(PageBackdropPage page) =>
    _layerDestination(PageBackdropPageTier(page));

SettingsDestination _layerDestination(
  PageBackdropTier layer, {
  List<SettingsSection> extra = const <SettingsSection>[],
}) {
  final String prefix = layer.idPrefix;
  PageBackdropModuleOverride? override() => layer.own;
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: layer.title,
    summary: layer.hint,
    icon: layer.icon,
    sections: <SettingsSection>[
      SettingsSection(
        id: '$prefix.section.style',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        liveListenable: (_) => layer.overrides,
        title: t.page_backdrop_style,
        footer: layer.hint,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: '$prefix.preset',
            icon: FushiIcons.pageBackdrop,
            searchTitle: t.page_backdrop_style,
            builder: (SettingsContext settingsContext) =>
                _PageBackdropPresetPicker(
                  settingsContext: settingsContext,
                  layer: layer,
                ),
          ),
        ],
      ),
      SettingsSection(
        id: '$prefix.section.image',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        liveListenable: (_) => layer.overrides,
        title: t.page_backdrop_preset_custom,
        visible: (_) => override()?.preset == PageBackdropPreset.custom,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: '$prefix.image',
            title: t.page_backdrop_image,
            subtitleBuilder: (SettingsContext c) =>
                override()?.landscapeImagePath == null
                ? t.page_backdrop_image_empty
                : t.page_backdrop_image_set,
            icon: FushiIcons.image,
            onTap: (SettingsContext c) =>
                pickPageBackdropImage(c, portrait: false, layer: layer),
          ),
          SettingsNavigationItem(
            id: '$prefix.portrait_image',
            title: t.page_backdrop_portrait_image,
            subtitleBuilder: (SettingsContext c) =>
                override()?.portraitImagePath == null
                ? t.page_backdrop_portrait_image_shared
                : t.page_backdrop_image_set,
            icon: FushiIcons.portraitImage,
            visible: (_) => override()?.landscapeImagePath != null,
            onTap: (SettingsContext c) =>
                pickPageBackdropImage(c, portrait: true, layer: layer),
          ),
          SettingsNavigationItem(
            id: '$prefix.portrait_image_clear',
            title: t.page_backdrop_portrait_image_clear,
            icon: FushiIcons.restart,
            visible: (_) =>
                override()?.landscapeImagePath != null &&
                override()?.portraitImagePath != null,
            onTap: (SettingsContext c) async {
              await layer.clearPortraitImage(_theme(c));
              c.refresh();
            },
          ),
        ],
      ),
      ...extra,
    ],
  );
}

ThemeNotifier _theme(SettingsContext c) => c.appModel.themeNotifier;

bool _isShapePreset(ThemeNotifier theme) => switch (theme.pageBackdropPreset) {
  PageBackdropPreset.plain || PageBackdropPreset.custom => false,
  _ => true,
};

/// 选一张图当背景（[portrait] = 竖屏单独的那张；[layer] 非空 = 只给这个模块 / 页面）。
/// 选完先弹裁剪框（反馈 nYjjaLYlfn），裁剪框锁成这块槽位在本机屏幕上的宽高比
/// （见 [pageBackdropCropAspectRatio]）；取消选图或取消裁剪都什么都不做。
///
/// 任何一步失败（选图器的平台异常 / 权限、复制、数据目录、偏好写入）都告诉用户
/// 并记应用日志——不只是复制时的 [FileSystemException]，否则别的失败会变成
/// 未处理的异步错误、用户点了没反应。
Future<void> pickPageBackdropImage(
  SettingsContext settingsContext, {
  required bool portrait,
  PageBackdropTier? layer,
}) async {
  try {
    final File? picked = await pickGalleryImageFile();
    if (picked == null) return;
    final BuildContext pickContext = settingsContext.context;
    if (!pickContext.mounted) return;
    final Size display = pageBackdropDisplaySize(pickContext);
    // 主图在没单独设竖屏图时横竖屏共用（`PageBackdropSettings.imagePathFor`），
    // 这时它没有确定的显示朝向，不能锁成横屏比例。
    final String? portraitImagePath = layer == null
        ? pageBackdropSettings.value.portraitImagePath
        : layer.own?.portraitImagePath;
    final File? cropped = await showCropImageDialog(
      pickContext,
      picked,
      aspectRatio: pageBackdropCropAspectRatio(
        display,
        portrait: portrait,
        sharedAcrossOrientations: !portrait && portraitImagePath == null,
      ),
      maxDimension: pageBackdropCropMaxDimension(display),
    );
    if (cropped == null) return;
    final ThemeNotifier theme = _theme(settingsContext);
    switch (layer) {
      case null:
        await theme.importPageBackdropImage(cropped, portrait: portrait);
      case PageBackdropModuleTier(:final HomeTab module):
        await theme.importPageBackdropModuleImage(
          module,
          cropped,
          portrait: portrait,
        );
      case PageBackdropPageTier(:final PageBackdropPage page):
        await theme.importPageBackdropPageImage(
          page,
          cropped,
          portrait: portrait,
        );
    }
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

/// 本机屏幕的物理像素尺寸（背景最终铺满的画布）；拿不到显示器信息（测试宿主、
/// 部分桌面环境返回零尺寸）时退回当前窗口的物理尺寸。
Size pageBackdropDisplaySize(BuildContext context) {
  final ui.FlutterView view = View.of(context);
  final Size display = view.display.size;
  if (!display.isEmpty) return display;
  return view.physicalSize;
}

/// 背景裁剪框的宽高比：横屏槽取屏幕「长边 / 短边」，竖屏槽取倒数。
///
/// 背景层按区域「高 > 宽」选竖屏图、再 [BoxFit.cover] 铺满
/// （`page_backdrop_layer.dart`），所以按屏幕比例裁出来的图在全屏时不会再被二次
/// 裁掉，裁剪框里看到的就是最终显示的范围。
///
/// 返回 null（自由裁剪）的情形：[display] 是空尺寸；或 [sharedAcrossOrientations]
/// ——主图在没单独设竖屏图时横竖屏共用，竖屏手机上显示的正是这张，锁成横屏
/// 「长边 / 短边」会让竖屏只剩中间一窄条，锁成竖屏比例又反过来坑横屏，
/// 没有一个比例两边都对，只能交给用户。
double? pageBackdropCropAspectRatio(
  Size display, {
  required bool portrait,
  required bool sharedAcrossOrientations,
}) {
  if (display.isEmpty || sharedAcrossOrientations) return null;
  final double long = math.max(display.width, display.height);
  final double short = math.min(display.width, display.height);
  return portrait ? short / long : long / short;
}

/// 背景裁剪的源图解码 / 输出长边上限 = 屏幕物理长边：超过屏幕分辨率的像素
/// 显示时只会被缩掉，按原图（相机原片动辄 4800 万像素）解码再整张裁剪在低内存
/// 手机上峰值过高（与应用图标裁剪的 BUG-3601 同一类问题）。空尺寸返回 null（原图）。
int? pageBackdropCropMaxDimension(Size display) {
  if (display.isEmpty) return null;
  return math.max(display.width, display.height).ceil();
}

String _presetLabel(PageBackdropPreset preset) => switch (preset) {
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
///
/// [layer] 非空时是某个模块 / 页面自己的选择器：最前面多一张「跟随全局 / 跟随模块」
/// （画的是继承来的背景），自定义图片用这一层自己的图。
class _PageBackdropPresetPicker extends StatelessWidget {
  const _PageBackdropPresetPicker({required this.settingsContext, this.layer});

  final SettingsContext settingsContext;
  final PageBackdropTier? layer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        pageBackdropSettings,
        pageBackdropModuleOverrides,
        pageBackdropPageOverrides,
      ]),
      builder: (BuildContext context, Widget? _) {
        final ThemeData theme = Theme.of(context);
        final bool apple = isGlassDesign(context);
        final List<_PresetChoice> choices = _choices();
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
                    itemCount: choices.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (BuildContext context, int index) {
                      final _PresetChoice choice = choices[index];
                      return _PresetTile(
                        label: choice.label,
                        preview: choice.preview,
                        needsImage: choice.needsImage,
                        selected: choice.selected,
                        onTap: () => _select(choice),
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

  /// 本选择器的格子：全局选择器是全部预设；模块 / 页面选择器先是「跟随全局 / 跟随模块」
  /// 再是全部预设。
  List<_PresetChoice> _choices() {
    final PageBackdropSettings global = pageBackdropSettings.value;
    final PageBackdropTier? layer = this.layer;
    if (layer == null) {
      return <_PresetChoice>[
        for (final PageBackdropPreset preset in PageBackdropPreset.values)
          _PresetChoice(
            preset: preset,
            label: _presetLabel(preset),
            preview: global.copyWith(preset: preset),
            needsImage:
                preset == PageBackdropPreset.custom &&
                global.landscapeImagePath == null,
            selected: global.preset == preset,
          ),
      ];
    }
    final PageBackdropModuleOverride? override = layer.own;
    final PageBackdropSettings inherited = layer.inherited;
    return <_PresetChoice>[
      _PresetChoice(
        preset: null,
        label: layer.followLabel,
        preview: inherited,
        needsImage: false,
        selected: override == null,
      ),
      for (final PageBackdropPreset preset in PageBackdropPreset.values)
        _PresetChoice(
          preset: preset,
          label: _presetLabel(preset),
          preview: resolvePageBackdropSettings(
            inherited,
            PageBackdropModuleOverride(
              preset: preset,
              landscapeImagePath: override?.landscapeImagePath,
              portraitImagePath: override?.portraitImagePath,
            ),
          ),
          needsImage:
              preset == PageBackdropPreset.custom &&
              override?.landscapeImagePath == null,
          selected: override?.preset == preset,
        ),
    ];
  }

  Future<void> _select(_PresetChoice choice) async {
    final ThemeNotifier theme = settingsContext.appModel.themeNotifier;
    final PageBackdropTier? layer = this.layer;
    if (choice.needsImage) {
      await pickPageBackdropImage(
        settingsContext,
        portrait: false,
        layer: layer,
      );
      return;
    }
    if (layer != null) {
      await layer.setPreset(theme, choice.preset);
    } else if (choice.preset case final PageBackdropPreset preset) {
      await theme.setPageBackdropPreset(preset);
    }
    settingsContext.refresh();
  }
}

/// 选择器里的一格。[preset] 为 null = 模块 / 页面的「跟随全局 / 跟随模块」。
class _PresetChoice {
  const _PresetChoice({
    required this.preset,
    required this.label,
    required this.preview,
    required this.needsImage,
    required this.selected,
  });

  final PageBackdropPreset? preset;
  final String label;
  final PageBackdropSettings preview;
  final bool needsImage;
  final bool selected;
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.label,
    required this.preview,
    required this.needsImage,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// 缩略图画的设置（真实背景层缩小）。
  final PageBackdropSettings preview;

  /// 选「自定义图片」但还没有图：画「加图片」图标，点了直接选图。
  final bool needsImage;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
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
                        PageBackdropLayer(settings: preview, animate: false),
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
