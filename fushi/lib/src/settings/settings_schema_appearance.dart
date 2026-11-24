import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:fushi/src/platform/desktop/linux_steam_shortcut.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/jump_history.dart'
    show kJumpHistoryAutoHideDefaultSeconds, kJumpHistoryAutoHideOptions;
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/miscellaneous_settings_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/reader/eink_full_refresh.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart'
    show homeWidgetEditRequested;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/second_screen/input/controller_lookup_target.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema_page_backdrop.dart';
import 'package:fushi/src/settings/shell_style_preview.dart';
import 'package:fushi/src/settings/nav_module_order_list.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart'
    show currentAppIconSelection;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/platform/host_platform.dart';

/// 「功能模块」开关行的 item id。
///
/// **历史前缀 `system.` 冻结不改**：这些 id 是设置搜索的定位锚点，与展示分类本就
/// 解耦（同款先例见 settings_schema_system.dart 里 `buildStartupPageItem` 对
/// `appearance.startup_default_dictionary_tab` 的注释），改 id 只会平白动摇锚点。四个后加的模块沿用同一前缀保持一致。
String _moduleItemId(ModuleId module) => switch (module) {
  // 2026-10-09 新增，无历史包袱，但仍跟随同一前缀保持一致。
  ModuleId.home => 'system.module_home',
  ModuleId.books => 'system.module_books',
  ModuleId.manga => 'system.module_manga',
  ModuleId.video => 'system.module_video',
  // 2026-10 新增（音乐模块），跟随同一前缀。
  ModuleId.music => 'system.module_music',
  ModuleId.games => 'system.module_games',
  ModuleId.browse => 'system.module_downloads',
  ModuleId.lookup => 'system.module_lookup',
  // 2026-10-14 新增（复习 / Fushi 内置 SRS），跟随同一前缀。
  ModuleId.srs => 'system.module_srs',
  ModuleId.web => 'system.module_browser_extension',
  ModuleId.listening => 'system.module_listening',
  ModuleId.cardCreation => 'system.module_card_creation',
  ModuleId.services => 'system.module_services',
  // 2026-11-10 新增（媒体追踪），跟随同一前缀。
  ModuleId.tracking => 'system.module_tracking',
  // 2026-10-13 新增，跟随同一前缀。
  ModuleId.ai => 'system.module_ai',
  ModuleId.sync => 'system.module_sync',
};

/// 「功能模块」开关行的标题与图标。
///
/// **一律取别处已有的真值，绝不在这里抄第二份标签**——此前这里抄了一套
/// `module_*_label`（'小说' 对底栏「书架」、'Galgame' 对底栏「游戏」），两份真值
/// 各改各的必然漂移，用户看到的就是设置项名字对不上底栏。
/// 有底栏 tab 的模块取 [homeNavItemFor]（底栏改名这里自动跟着改）；没有 tab 的五个
/// 取它自己那个设置一级分类的标题与图标（同理，分类改名这里自动跟着改）。
({String label, IconData icon}) moduleNavIdentity(ModuleId module) {
  final HomeTab? tab = homeTabOfModule(module);
  if (tab != null) {
    final AdaptiveNavItem navItem = homeNavItemFor(tab);
    return (label: navItem.label, icon: navItem.icon);
  }
  return switch (module) {
    ModuleId.listening => (
      label: t.settings_destination_listening,
      icon: FushiIcons.audiobook,
    ),
    ModuleId.cardCreation => (
      label: t.settings_destination_card_creation,
      icon: FushiIcons.ankiCard,
    ),
    ModuleId.services => (
      label: t.settings_destination_services,
      icon: FushiIcons.cloud,
    ),
    ModuleId.tracking => (
      label: t.settings_destination_tracking,
      icon: FushiIcons.tracking,
    ),
    ModuleId.ai => (label: t.ai_settings_title, icon: FushiIcons.aiAssistant),
    ModuleId.sync => (
      label: t.settings_destination_sync_backup,
      icon: FushiIcons.sync,
    ),
    // 上面 homeTabOfModule 已经把有 tab 的七个消化掉了；这里补齐 switch 让编译器
    // 在新增模块时强制点名，而不是静默落进一个 default 里显示错标签。
    ModuleId.home ||
    ModuleId.books ||
    ModuleId.manga ||
    ModuleId.video ||
    ModuleId.music ||
    ModuleId.games ||
    ModuleId.browse ||
    ModuleId.lookup ||
    ModuleId.srs ||
    ModuleId.web => throw StateError('$module 有对应 HomeTab，标识应走 homeNavItemFor'),
  };
}

/// [module] 在本平台上是否存在（galgame 仅 Windows、浏览器扩展仅桌面、下载
/// 中心不进 App Store）。判据与读取端同源（[ModuleId.availableOn]），不在这里
/// 另写一份 Platform 判断。
bool _moduleAvailableHere(ModuleId module) => module.availableOn(
  isWindows: hostPlatform.isWindows,
  isDesktop: DesktopLookupService.isDesktop,
  isIOS: hostPlatform.isIOS,
  isAndroid: hostPlatform.isAndroid,
);

/// 翻转一个模块开关。导航模块的拖拽列表与无 tab 模块的开关行共用这一份。
Future<void> _applyModuleEnabled(
  SettingsContext settingsContext,
  ModuleId module,
  bool enabled,
) async {
  // 「至少保留一个导航模块」：最后一个有 tab 的模块关不掉（否则打开 app 只剩
  // 设置这一页）。拒绝时开关保持开着，并说明原因。
  if (!enabled &&
      isLastNavigationModule(
        module,
        settingsContext.appModel.moduleVisibility,
      )) {
    final BuildContext ctx = settingsContext.context;
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        FushiSnackBar(content: Text(t.settings_module_keep_one_navigation)),
      );
    }
    settingsContext.refresh();
    return;
  }
  await settingsContext.appModel.setModuleEnabled(module, enabled);
  settingsContext.refresh();
}

/// 「功能模块」行的副标题。复习默认关：开关本身要说清它是什么，否则用户不知道
/// 打开后会多出什么。导航模块的拖拽列表与无 tab 模块的开关行共用这一份。
String? moduleSwitchHint(ModuleId module) =>
    module == ModuleId.srs ? t.srs_module_switch_hint : null;

/// 「功能模块」里没有底栏 tab 的模块（听书 / 制卡 / 在线服务 / AI / 同步）的开关。
/// 有 tab 的模块不走这里，而是进 [NavModuleOrderList]（开关 + 拖拽排序）。
SettingsSwitchItem _moduleSwitch(ModuleId module) {
  final ({String label, IconData icon}) identity = moduleNavIdentity(module);
  return SettingsSwitchItem(
    id: _moduleItemId(module),
    title: identity.label,
    icon: identity.icon,
    subtitle: moduleSwitchHint(module),
    visible: (_) => _moduleAvailableHere(module),
    value: (SettingsContext settingsContext) =>
        settingsContext.appModel.moduleEnabled(module),
    onChanged: (SettingsContext settingsContext, bool enabled) =>
        _applyModuleEnabled(settingsContext, module, enabled),
    // 与读取端（PreferencesRepository.moduleEnabled）同一真值：复习默认关。
    defaultValue: module.defaultEnabled,
  );
}

/// 导航模块的开关 + 拖拽排序（与词典管理同一套交互）。顺序就是底栏 / 侧栏 tab
/// 顺序，见 `homeActiveTabs`。
/// 本平台存在的导航模块，按用户顺序。列表渲染与设置搜索关键词共用。
List<ModuleId> _orderedNavModules(
  SettingsContext settingsContext,
) => <ModuleId>[
  for (final ModuleId module
      in settingsContext.appModel.moduleVisibility.ordered)
    if (homeTabOfModule(module) != null && _moduleAvailableHere(module)) module,
];

SettingsCustomItem _navModuleOrderItem() => SettingsCustomItem(
  id: 'appearance.nav_module_order',
  searchTitle: t.settings_module_nav_order,
  subtitle: t.settings_navigation_module_order_hint,
  // 合成一个列表后各模块不再是独立的 schema 行；把模块名挂成关键词，搜「视频」
  // 仍能直达这块（结果行露出命中的「视频」）。
  searchKeywords: (SettingsContext settingsContext) => <String>[
    for (final ModuleId module in _orderedNavModules(settingsContext))
      moduleNavIdentity(module).label,
  ],
  icon: FushiIcons.home,
  builder: (SettingsContext settingsContext) => NavModuleOrderList(
    settingsContext: settingsContext,
    modules: _orderedNavModules(settingsContext),
    identityOf: moduleNavIdentity,
    settingsIdentity: (
      label: homeNavItemFor(HomeTab.settings).label,
      icon: homeNavItemFor(HomeTab.settings).icon,
    ),
    hintOf: moduleSwitchHint,
    onEnabledChanged: (ModuleId module, bool enabled) =>
        _applyModuleEnabled(settingsContext, module, enabled),
  ),
);

/// 外壳样式选择行的公共壳：左边标题 + 说明，右边一组紧凑选择块（迷你示意 + 短
/// 标签）。声明选择块一行排开的固有宽度（[ShellChoiceTiles.widthFor]），行宽放不下
/// 时设置行自己把选择块换到标题下方（块再按 Wrap 折行），窄屏不溢出。
Widget _shellChoiceRow({
  required String title,
  required Widget tiles,
  required int optionCount,
  String? subtitle,
}) => AdaptiveSettingsRow(
  title: title,
  subtitle: subtitle,
  icon: FushiIcons.widgets,
  trailing: tiles,
  trailingWidth: ShellChoiceTiles.widthFor(optionCount),
);

/// 外壳样式枚举行的控制通道读写：取值 = 枚举名（与改成预览卡之前的分段行同一
/// 写法），也认界面名称（大小写无关）。
SettingsCliValue _shellEnumCli<T extends Enum>({
  required List<T> values,
  required T Function(SettingsContext context) read,
  required String Function(T value) labelOf,
  required Future<void> Function(SettingsContext context, T value) write,
}) => SettingsCliValue(
  read: (SettingsContext context) => read(context).name,
  options: (SettingsContext context) => <String>[
    for (final T value in values) value.name,
  ],
  write: (SettingsContext context, String raw) async {
    final String needle = raw.trim().toLowerCase();
    for (final T value in values) {
      if (value.name.toLowerCase() == needle ||
          labelOf(value).toLowerCase() == needle) {
        await write(context, value);
        return;
      }
    }
    throw ArgumentError(
      '取值必须是 ${values.map((T value) => value.name).join(' / ')}',
    );
  },
);

SettingsCustomItem _shellContentLayoutItem() => SettingsCustomItem(
  id: 'appearance.shell_content_layout',
  searchTitle: t.library_layout,
  searchKeywords: (SettingsContext c) => <String>[
    for (final ShellContentLayout layout in ShellContentLayout.values)
      shellContentLayoutLabel(layout),
  ],
  icon: FushiIcons.widgets,
  visible: (SettingsContext c) => !isEinkTheme(c.context),
  // 「默认」= 本安装的出厂布局：新安装拼贴，升级上来的老用户封面网格（G1）。
  reset: SettingsCustomReset(
    isModified: (SettingsContext c) =>
        c.appModel.shellContentLayout !=
        c.appModel.themeNotifier.shellContentLayoutDefault,
    reset: (SettingsContext c) => c.appModel
        .setShellContentLayout(
          c.appModel.themeNotifier.shellContentLayoutDefault,
        )
        .then((_) => c.refresh()),
    currentLabel: (SettingsContext c) =>
        shellContentLayoutLabel(c.appModel.shellContentLayout),
    defaultLabel: (SettingsContext c) => shellContentLayoutLabel(
      c.appModel.themeNotifier.shellContentLayoutDefault,
    ),
  ),
  cliValue: _shellEnumCli<ShellContentLayout>(
    values: ShellContentLayout.values,
    read: (SettingsContext c) => c.appModel.shellContentLayout,
    labelOf: shellContentLayoutLabel,
    write: (SettingsContext c, ShellContentLayout value) =>
        c.appModel.setShellContentLayout(value).then((_) => c.refresh()),
  ),
  builder: (SettingsContext settingsContext) {
    final AppModel appModel = settingsContext.appModel;
    return _shellChoiceRow(
      title: t.library_layout,
      optionCount: ShellContentLayout.values.length,
      tiles: ShellLayoutChoiceTiles(
        selected: appModel.shellContentLayout,
        arrangement: appModel.shellBlockArrangement,
        covers: shellPreviewCoversOf(settingsContext.ref, appModel),
        onSelected: (ShellContentLayout value) => appModel
            .setShellContentLayout(value)
            .then((_) => settingsContext.refresh()),
      ),
    );
  },
);

SettingsCustomItem _shellBlockArrangementItem() => SettingsCustomItem(
  id: 'appearance.shell_block_arrangement',
  searchTitle: t.library_arrangement,
  searchKeywords: (SettingsContext c) => <String>[
    for (final ShellBlockArrangement arrangement
        in ShellBlockArrangement.values)
      shellBlockArrangementLabel(arrangement),
  ],
  subtitle: t.library_arrangement_hint,
  icon: FushiIcons.widgets,
  // 摆放只属于拼贴：选封面网格时整行隐藏（不是置灰）。
  visible: (SettingsContext c) =>
      !isEinkTheme(c.context) &&
      c.appModel.shellContentLayout == ShellContentLayout.collage,
  reset: SettingsCustomReset(
    isModified: (SettingsContext c) =>
        c.appModel.shellBlockArrangement !=
        ShellBlockArrangement.defaultFor(c.appModel.shellContentLayout),
    // 恢复默认清掉偏好回到「没选过」（BUG-4703），不把此刻布局下的默认值钉死。
    reset: (SettingsContext c) =>
        c.appModel.resetShellBlockArrangement().then((_) => c.refresh()),
    currentLabel: (SettingsContext c) =>
        shellBlockArrangementLabel(c.appModel.shellBlockArrangement),
    defaultLabel: (SettingsContext c) => shellBlockArrangementLabel(
      ShellBlockArrangement.defaultFor(c.appModel.shellContentLayout),
    ),
  ),
  cliValue: _shellEnumCli<ShellBlockArrangement>(
    values: ShellBlockArrangement.values,
    read: (SettingsContext c) => c.appModel.shellBlockArrangement,
    labelOf: shellBlockArrangementLabel,
    write: (SettingsContext c, ShellBlockArrangement value) =>
        c.appModel.setShellBlockArrangement(value).then((_) => c.refresh()),
  ),
  builder: (SettingsContext settingsContext) => _shellChoiceRow(
    title: t.library_arrangement,
    subtitle: t.library_arrangement_hint,
    optionCount: ShellBlockArrangement.values.length,
    tiles: ShellArrangementChoiceTiles(
      selected: settingsContext.appModel.shellBlockArrangement,
      onSelected: (ShellBlockArrangement value) => settingsContext.appModel
          .setShellBlockArrangement(value)
          .then((_) => settingsContext.refresh()),
    ),
  ),
);

SettingsCustomItem _shellRailStyleItem() => SettingsCustomItem(
  id: 'appearance.shell_rail_style',
  searchTitle: t.home_nav_rail_style,
  searchKeywords: (SettingsContext c) => <String>[
    for (final ShellRailStyle style in ShellRailStyle.values)
      shellRailStyleLabel(style),
  ],
  icon: FushiIcons.widgets,
  visible: (SettingsContext c) =>
      !isGlassDesign(c.context) && !isEinkTheme(c.context),
  reset: SettingsCustomReset(
    isModified: (SettingsContext c) =>
        c.appModel.shellRailStyle != ShellRailStyle.defaultStyle,
    reset: (SettingsContext c) => c.appModel
        .setShellRailStyle(ShellRailStyle.defaultStyle)
        .then((_) => c.refresh()),
    currentLabel: (SettingsContext c) =>
        shellRailStyleLabel(c.appModel.shellRailStyle),
    defaultLabel: (SettingsContext c) =>
        shellRailStyleLabel(ShellRailStyle.defaultStyle),
  ),
  cliValue: _shellEnumCli<ShellRailStyle>(
    values: ShellRailStyle.values,
    read: (SettingsContext c) => c.appModel.shellRailStyle,
    labelOf: shellRailStyleLabel,
    write: (SettingsContext c, ShellRailStyle value) =>
        c.appModel.setShellRailStyle(value).then((_) => c.refresh()),
  ),
  builder: (SettingsContext settingsContext) => _shellChoiceRow(
    title: t.home_nav_rail_style,
    optionCount: ShellRailStyle.values.length,
    tiles: ShellRailChoiceTiles(
      selected: settingsContext.appModel.shellRailStyle,
      onSelected: (ShellRailStyle value) => settingsContext.appModel
          .setShellRailStyle(value)
          .then((_) => settingsContext.refresh()),
    ),
  ),
);

SettingsDestination buildAppearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance,
    summary: t.settings_appearance_summary,
    icon: FushiIcons.appearance,
    // 本页只管「长什么样」：主题 / 背景与缩放 / 字体 / 应用图标。语言归「通用」，
    // 功能模块、首页面板、底栏与跳转记录归「导航与首页」——那些项留在本文件
    // （依赖这里的私有 helper），以顶层 builder 导出给对应分类装配。
    sections: <SettingsSection>[
      SettingsSection(
        id: 'appearance.section.interface',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.section_interface,
        items: <SettingsItem>[
          // searchTitle 复用各自绘制行的既有标题（无新 key），让这些自定义选择器
          // 进入设置搜索（主题/语言/明暗等此前搜不到）。
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: FushiIcons.devices,
            searchTitle: t.design_system_label,
            builder: buildDesignSystemSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.theme',
            icon: Icons.color_lens_outlined,
            searchTitle: t.reader_theme,
            builder: buildThemeSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            icon: Icons.contrast_outlined,
            searchTitle: t.dark_mode,
            builder: buildBrightnessSelector,
          ),
          // 阅读器纸色（拍板台 vJSj4RsKFt）：浅色 / 深色各一行，默认跟随 app 主题，
          // 显式选羊皮纸 / 护眼 / 深灰等即覆盖；与主题种子色无关。
          SettingsCustomItem(
            id: 'appearance.reader_paper_light',
            icon: FushiIcons.lightMode,
            searchTitle: t.reader_paper_light,
            builder: (SettingsContext settingsContext) =>
                buildReaderPaperSelector(settingsContext, dark: false),
            cliValue: readerPaperCliValue(dark: false),
          ),
          SettingsCustomItem(
            id: 'appearance.reader_paper_dark',
            icon: FushiIcons.darkMode,
            searchTitle: t.reader_paper_dark,
            builder: (SettingsContext settingsContext) =>
                buildReaderPaperSelector(settingsContext, dark: true),
            cliValue: readerPaperCliValue(dark: true),
          ),
          // 「纯黑深色背景」：原「纯黑」预设的语义（2026-10 预设只决定种子色、不再
          // 自带明暗 / 纯黑），改成明暗旁的独立开关；对系统取色 / 预设 / 自定义主题
          // 一律生效，只在深色下起作用。
          SettingsSwitchItem(
            id: 'appearance.pure_black_dark',
            title: t.theme_pure_black,
            subtitle: t.theme_pure_black_hint,
            icon: FushiIcons.darkMode,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.pureBlackDark,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPureBlackDark(value);
              notifyReaderSettingsChanged(settingsContext);
            },
            defaultValue: false,
          ),
          // 墨水屏模式：全局单开关（设备属性，不随 Profile 快照），叠加在主题/
          // 明暗机制之上——开=纯黑白+无动画+线式高亮，关=还原原主题。
          SettingsSwitchItem(
            id: 'appearance.eink_mode',
            title: t.eink_mode,
            subtitle: t.eink_mode_hint,
            icon: Icons.filter_b_and_w_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setEinkMode(value);
              // BUG-2329：einkMode 是正文 CSS 的入参（ReaderContentStyles.css 的
              // einkMode），开着书切换必须重注入，否则正文要退出重进才变黑白。
              notifyReaderSettingsChanged(settingsContext);
            },
            defaultValue: false,
          ),
          // 墨水屏「每 N 页全刷」（拍板台 oF0jVdOTIE）：小说三种 view mode 与漫画翻页
          // 计数，到点做一次全刷清残影。不挂在墨水屏主题开关下面——漫画阅读器有自己
          // 的墨水屏开关，用墨水屏设备但不开全局黑白主题的人也要能用。设备本地。
          SettingsSegmentedItem<int>(
            id: 'appearance.eink_full_refresh_interval',
            title: t.eink_full_refresh_interval,
            subtitle: t.eink_full_refresh_interval_hint,
            icon: FushiIcons.refresh,
            dropdown: true,
            options: <SettingsSegmentOption<int>>[
              for (final int interval in kEinkFullRefreshIntervalChoices)
                SettingsSegmentOption<int>(
                  value: interval,
                  label: einkFullRefreshIntervalLabel(interval),
                ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkFullRefreshInterval,
            onChanged: (SettingsContext settingsContext, int value) async {
              await settingsContext.appModel.setEinkFullRefreshInterval(value);
              settingsContext.refresh();
            },
            defaultValue: kEinkFullRefreshIntervalDefault,
          ),
          SettingsSegmentedItem<EinkFullRefreshMethod>(
            id: 'appearance.eink_full_refresh_method',
            title: t.eink_full_refresh_method,
            subtitle: t.eink_full_refresh_method_hint,
            icon: FushiIcons.flash,
            visible: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkFullRefreshInterval > 0,
            options: <SettingsSegmentOption<EinkFullRefreshMethod>>[
              SettingsSegmentOption<EinkFullRefreshMethod>(
                value: EinkFullRefreshMethod.auto,
                label: t.eink_full_refresh_method_auto,
              ),
              SettingsSegmentOption<EinkFullRefreshMethod>(
                value: EinkFullRefreshMethod.flash,
                label: t.eink_full_refresh_method_flash,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkFullRefreshMethod,
            onChanged:
                (
                  SettingsContext settingsContext,
                  EinkFullRefreshMethod value,
                ) async {
                  await settingsContext.appModel.setEinkFullRefreshMethod(
                    value,
                  );
                  settingsContext.refresh();
                },
            defaultValue: EinkFullRefreshMethod.auto,
          ),
          // 玻璃画质（2026-11 用户拍板）：只在 Apple（Cupertino）设计系统下出现，
          // M3E 不显示。四档 实色 / 精简 / 标准 / 高级，默认精简；只影响悬浮控件层，
          // 正文、视频画面不变。墨水屏、系统增强对比度 / 降低透明度下自动实色，
          // 高级档在引擎不支持着色器 ImageFilter 时降为标准——这些回退都在
          // glassMaterialOf 里判，这里只存用户的选择（偏好 `glass_quality`，随
          // Profile 走）。schema id 沿用 `appearance.glass_material`（设置搜索 /
          // 深链只认 id，不是存储名）。
          SettingsSegmentedItem<FushiGlassMaterial>(
            id: 'appearance.glass_material',
            title: t.glass_quality,
            subtitle: t.glass_quality_hint,
            icon: Icons.blur_on_outlined,
            visible: (SettingsContext settingsContext) =>
                glassQualitySettingVisible(settingsContext.context),
            options: <SettingsSegmentOption<FushiGlassMaterial>>[
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.off,
                label: t.glass_quality_solid,
              ),
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.minimal,
                label: t.glass_quality_minimal,
              ),
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.standard,
                label: t.glass_quality_standard,
              ),
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.premium,
                label: t.glass_quality_premium,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.glassMaterialTier,
            onChanged:
                (SettingsContext settingsContext, FushiGlassMaterial value) =>
                    settingsContext.appModel.setGlassMaterial(value),
            defaultValue: FushiGlassMaterial.defaultTier,
          ),
          // 外壳重设计的几项（设计稿 S1）：生效范围同 `shellRedesignActive`——非墨水屏
          // 一律生效（MD3 与 Apple 都是），墨水屏保持原外壳（库页恒为封面网格），所以
          // 都不显示。三项各是一行：左边标题，右边一组带迷你示意的紧凑选择块
          // （shell_style_preview.dart 的 Shell*ChoiceTiles；升级弹窗与新手引导用同一套
          // 示意的大卡）。不再单列整块「实时预览」：所有者反馈太占位置，每个选项的
          // 迷你示意已看得出差别。色块摆放只属于拼贴，选封面网格时整行隐藏；侧栏样式
          // 只管 MD3 侧栏（Apple 设计系统用系统侧栏，不读它）。
          _shellContentLayoutItem(),
          _shellBlockArrangementItem(),
          _shellRailStyleItem(),
          SettingsSwitchItem(
            id: 'appearance.shell_smooth_corners',
            title: t.theme_smooth_corners,
            subtitle: t.theme_smooth_corners_hint,
            icon: FushiIcons.widgets,
            visible: (SettingsContext c) => !isEinkTheme(c.context),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.shellSmoothCorners,
            onChanged: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel
                    .setShellSmoothCorners(value)
                    .then((_) => settingsContext.refresh()),
            defaultValue: true,
          ),
          // 第二块屏（双屏掌机下屏 / 外接显示器）：只在系统报告有可用副屏时出现。
          SettingsSegmentedItem<SecondScreenMode>(
            id: 'appearance.second_screen_mode',
            title: t.second_screen_setting_title,
            subtitle: t.second_screen_setting_hint,
            icon: FushiIcons.devices,
            visible: (SettingsContext c) =>
                c.ref.read(secondScreenControllerProvider).displayAvailable,
            options: <SettingsSegmentOption<SecondScreenMode>>[
              SettingsSegmentOption<SecondScreenMode>(
                value: SecondScreenMode.auto,
                label: t.second_screen_mode_auto,
              ),
              SettingsSegmentOption<SecondScreenMode>(
                value: SecondScreenMode.always,
                label: t.second_screen_mode_always,
              ),
              SettingsSegmentOption<SecondScreenMode>(
                value: SecondScreenMode.off,
                label: t.second_screen_mode_off,
              ),
            ],
            selected: (SettingsContext c) =>
                c.ref.read(secondScreenControllerProvider).mode,
            onChanged: (SettingsContext c, SecondScreenMode value) => c.ref
                .read(secondScreenControllerProvider)
                .setMode(value)
                .then((_) => c.refresh()),
            defaultValue: SecondScreenMode.auto,
          ),
          // 副屏在用时主屏查词结果显示在哪：下屏「查词」页（默认）/ 上屏页内弹窗。
          // 所有媒体与手柄查词模式共用（路由点 CompanionContextRegistry）；在副屏面板
          // 上长按 / 点字发起的查词始终在下屏。与上一行同样只在有副屏时出现。
          SettingsSegmentedItem<SecondScreenLookupScreen>(
            id: 'appearance.second_screen_lookup_screen',
            title: t.second_screen_lookup_screen_title,
            subtitle: t.second_screen_lookup_screen_hint,
            icon: FushiIcons.dictionary,
            visible: (SettingsContext c) =>
                c.ref.read(secondScreenControllerProvider).displayAvailable,
            options: <SettingsSegmentOption<SecondScreenLookupScreen>>[
              SettingsSegmentOption<SecondScreenLookupScreen>(
                value: SecondScreenLookupScreen.bottom,
                label: t.second_screen_lookup_screen_bottom,
              ),
              SettingsSegmentOption<SecondScreenLookupScreen>(
                value: SecondScreenLookupScreen.top,
                label: t.second_screen_lookup_screen_top,
              ),
            ],
            selected: (SettingsContext c) =>
                c.ref.read(secondScreenControllerProvider).lookupScreen,
            onChanged: (SettingsContext c, SecondScreenLookupScreen value) => c
                .ref
                .read(secondScreenControllerProvider)
                .setLookupScreen(value)
                .then((_) => c.refresh()),
            defaultValue: SecondScreenLookupScreen.bottom,
          ),
        ],
      ),
      // 「背景与缩放」：页面背景与界面大小都是「整页底下 / 整页尺度」的呈现，
      // 与配色分开放，主题分区只剩配色相关的选择。
      SettingsSection(
        id: 'appearance.section.background',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_appearance_section_background,
        items: <SettingsItem>[
          // 「页面背景」子页（2026-10-30）：每一页底下的装饰——形状预设、纯色、
          // 用户自定义图片（可从图片取色）。
          SettingsNavigationItem(
            id: 'appearance.page_backdrop',
            title: t.page_backdrop_title,
            subtitle: t.page_backdrop_hint,
            icon: FushiIcons.pageBackdrop,
            child: buildPageBackdropDestination,
          ),
          // 「界面大小」滑条：commitOnRelease——本滑条位于受 FushiAppUiScale 的
          // Transform.scale 缩放的子树内，拖动逐帧提交会让整树立刻按新比例重排、
          // 滑块在手指下位移、手势断裂（TODO-374 旧 _AppUiScaleSliderRow 注释）。
          // 渲染层 _CommitOnReleaseSlider 拖动只更新本地预览值（跟手 + 标题读数
          // 实时），松手才经 onChanged 一次性提交真实缩放；键盘/手柄步进每按即提交。
          // 一等 schema 项同时带来静止常驻读数（titleReadout）与搜索索引，替代原
          // 自定义 custom 行双实现。id/持久化路径不变。
          SettingsSliderItem(
            id: 'appearance.app_ui_scale',
            title: t.app_ui_scale,
            subtitle: t.app_ui_scale_hint,
            icon: Icons.format_size_outlined,
            min: FushiAppUiScale.minScale,
            max: FushiAppUiScale.maxScale,
            divisions: 27,
            label: (double value) => '${(value * 100).round()}%',
            titleReadout: true,
            commitOnRelease: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.appUiScale,
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setAppUiScale(value);
            },
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.section.typography',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 字体分区**不折叠**：改字体是外观页的高频操作（用户显式反馈），折叠让每次
        // 改字体都多一次展开点击，收益（省一行高度）远小于代价。
        title: t.font_library_section_fonts,
        items: <SettingsItem>[
          // TODO-231: 全app 只有一个可见字体库；每行字体自己管「用在哪些用途」
          // （font_catalog / font_targets 两个偏好键）。用途集合 = FontTarget.values
          // 全量，UI 侧遍历枚举渲染，新增用途不需要改这里。
          // 不传 target：外观入口是全局作用域，新增字体默认挂 FontTarget.body。
          SettingsNavigationItem(
            id: 'appearance.font_catalog',
            title: t.custom_fonts_catalog_title,
            subtitle: t.settings_appearance_font_catalog_hint,
            icon: FushiIcons.font,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      // 「应用图标」：图标入口与图标 ↔ 主题色的两个联动开关。分区 id 沿用旧
      // 「应用」分区（搜索 / 展开状态按 id 记忆）。
      SettingsSection(
        id: 'appearance.section.navigation',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_app_shell,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            subtitle: t.settings_appearance_app_icon_hint,
            icon: FushiIcons.widgets,
            visible: (_) => hostPlatform.isAndroid || hostPlatform.isWindows,
            builder: (_) => const MiscellaneousSettingsPage(),
          ),
          // 应用图标 ↔ 主题色的两个开关，紧挨「应用图标」入口，默认都关。
          // ①「图标跟随主题色」：内置吉祥物 logo（宽屏 rail 品牌位、悬浮球）按
          // 强调色换色；关 = 始终原图。对用户自定义的图标图片从不换色。
          SettingsSwitchItem(
            id: 'appearance.tint_app_logo',
            title: t.theme_logo_tint_enabled,
            subtitle: t.theme_logo_tint_hint,
            icon: FushiIcons.widgets,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.tintAppLogo,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.themeNotifier.setTintAppLogo(
                value,
              );
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          // 「吉祥物光晕」：悬浮球上的吉祥物外圈呼吸光晕，后台同步时更亮更快。
          SettingsSwitchItem(
            id: 'appearance.mascot_glow',
            title: t.theme_logo_glow_enabled,
            subtitle: t.theme_logo_glow_hint,
            icon: FushiIcons.widgets,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.mascotGlow,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.themeNotifier.setMascotGlow(value);
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          // ②「主题色跟随图标」：设置了自定义图标图片时才出现；开着时从该图
          // 取种子色覆盖生效主题（不改写主题偏好，关掉即恢复原主题）。
          SettingsSwitchItem(
            id: 'appearance.follow_app_icon_accent',
            title: t.theme_icon_accent_follow,
            subtitle: t.theme_icon_accent_hint,
            icon: FushiIcons.appearance,
            visible: (_) => currentAppIconSelection.value.usesCustomFile,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.followAppIconAccent,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.themeNotifier
                  .setFollowAppIconAccent(value);
              notifyReaderSettingsChanged(settingsContext);
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
        ],
      ),
    ],
  );
}

/// 「通用 › 语言」的界面语言行。改的是整个界面的呈现语言，与内容语言并列放在
/// 通用页；id / 持久化 key 不变（历史 appearance 前缀）。
SettingsItem buildInterfaceLanguageItem() {
  return SettingsCustomItem(
    id: 'appearance.language',
    icon: Icons.translate_outlined,
    searchTitle: t.options_language,
    subtitle: t.settings_general_language_hint,
    builder: buildLanguageSelector,
  );
}

/// 「通用 › 语言」的默认内容语言行。这里设的是**默认值**，书/视频/游戏/词典
/// 各自的设置压过它，内容自带的声明（EPUB dc:language、词典 index.json、字幕轨
/// language）也压过它——见 resolveContentLanguage。
SettingsItem buildDefaultContentLanguageItem() {
  return SettingsNavigationItem(
    id: 'appearance.content_language',
    title: t.settings_content_language_title,
    titleBuilder: (SettingsContext settingsContext) {
      final String current =
          settingsContext.appModel.prefsRepo.defaultContentLanguage;
      final String label = current.isEmpty
          ? t.settings_content_language_unset
          : contentLanguageLabelOf(current);
      return '${t.settings_content_language_title} · $label';
    },
    subtitle:
        '${t.settings_content_language_description} '
        '${t.settings_content_language_screen_ocr_note}',
    icon: FushiIcons.language,
    onTap: (SettingsContext settingsContext) async {
      final String current =
          settingsContext.appModel.prefsRepo.defaultContentLanguage;
      await showContentLanguagePicker(
        context: settingsContext.context,
        title: t.settings_content_language_title,
        description:
            '${t.settings_content_language_description} '
            '${t.settings_content_language_screen_ocr_note}',
        current: current.isEmpty ? null : current,
        autoDetected: '',
        autoLabel: t.settings_content_language_unset,
        onSelected: (String? tag) async {
          await settingsContext.appModel.prefsRepo.setDefaultContentLanguage(
            tag ?? '',
          );
          settingsContext.refresh();
          notifyReaderSettingsChanged(settingsContext);
        },
      );
    },
  );
}

// 「功能模块」：14 个模块的总开关，值域与顺序都是 [ModuleId]。
//
// **本区管的不再只是底栏**。这些开关原来只喂 `homeActiveTabs()`（底栏/侧栏
// tab 列表），于是「关掉视频」之后设置页仍列着「视频」「在线服务」，首页活动
// 筛选条仍有「观看」，视频后台照跑——用户看到的是「只有底栏变干净了」。现在
// 一个开关关掉该模块的**全部入口**：底栏/侧栏 tab、首页 dashboard 的条目与
// 筛选、设置一级分类（连带设置搜索索引）、跨页跳转、该域快捷键、外部打开，
// 以及它专属后台的下次自启。
//
// 两条刻意的例外：
// - 设置**恒在**，是全部模块关光后的安全回退面，没有 ModuleId。首页
//   2026-10-09 起可关（[ModuleId.home]），但导航模块至少留一个
//   （[isLastNavigationModule]）。
// - 关掉「查词」只关**页面入口**，查词**能力全留**（阅读器划词弹窗、设置 →
//   查词 分类里的词典导入管理与音频来源）——用户拍板：纯阅读器仍要能查词。
//
// 分区住「导航与首页」：它决定底栏有哪些页、按什么顺序，与底栏样式 / 启动页
// 同域。item id 保留 `system.` 历史前缀不动，理由见 [_moduleItemId]。
SettingsSection buildModulesSection() {
  return SettingsSection(
    id: 'appearance.section.modules',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.settings_section_modules,
    footer: t.settings_navigation_modules_footer,
    // 有底栏 tab 的模块收进一个可拖拽排序的列表（用户排的顺序就是底栏顺序）；
    // 没有 tab 的横切模块仍是逐个开关，按枚举顺序。两者都遍历 ModuleId.values
    // 生成，加模块只加一个 enum 值。平台上不存在的模块各自判掉。
    items: <SettingsItem>[
      _navModuleOrderItem(),
      for (final ModuleId module in ModuleId.values)
        if (homeTabOfModule(module) == null) _moduleSwitch(module),
    ],
  );
}

// 「首页」：首页小组件网格（spec 2026-11-15）的入口。原「首页面板」分区（每个可选
// 面板一行 自动 / 显示 / 隐藏）撤掉：组件的增删、排序、尺寸都在首页编辑态里做，这里
// 只留一个「编辑首页」——切到首页 tab 并进入编辑态。首页模块关着时整段隐藏。
SettingsSection buildHomePanelsSection() {
  return SettingsSection(
    id: 'navigation.section.home_widgets',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.nav_home,
    visible: (SettingsContext c) =>
        c.appModel.moduleVisibility.isEnabled(ModuleId.home),
    items: <SettingsItem>[
      SettingsNavigationItem(
        id: 'navigation.home_widgets.edit',
        title: t.home_widget_edit,
        subtitle: t.settings_home_widgets_edit_subtitle,
        icon: FushiIcons.dashboardCustomize,
        showIcon: true,
        onTap: (SettingsContext settingsContext) {
          homeShellTabNotifier.value = HomeTab.home;
          homeWidgetEditRequested.value = true;
        },
      ),
    ],
  );
}

/// 「跳转记录」（2026-11-02 浮动胶囊改顶栏图标）：小说 / 漫画 / 视频三页共用。
/// 顶栏图标关掉照样记录；自动隐藏只藏图标，记录 / 面板 / 刻度保留。三项都
/// 由页面现读偏好（无双写）。自动隐藏紧跟它所修饰的顶栏图标开关。
SettingsSection buildJumpHistorySection() {
  return SettingsSection(
    id: 'appearance.section.jump_history',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.media_jump_history_title,
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'appearance.jump_history.toolbar',
        title: t.media_jump_history_setting_toolbar,
        subtitle: t.media_jump_history_setting_toolbar_hint,
        icon: FushiIcons.undo,
        value: (SettingsContext settingsContext) =>
            settingsContext.appModel.jumpHistoryToolbar,
        onChanged: (SettingsContext settingsContext, bool value) async {
          await settingsContext.appModel.setJumpHistoryToolbar(value);
        },
        defaultValue: true,
      ),
      SettingsSegmentedItem<int>(
        id: 'appearance.jump_history.auto_hide',
        title: t.media_jump_history_setting_auto_hide,
        subtitle: t.media_jump_history_setting_auto_hide_hint,
        icon: FushiIcons.timer,
        options: <SettingsSegmentOption<int>>[
          for (final int seconds in kJumpHistoryAutoHideOptions)
            SettingsSegmentOption<int>(
              value: seconds,
              label: seconds == 0
                  ? t.media_jump_history_setting_auto_hide_never
                  : seconds % 60 == 0
                  ? t.media_jump_history_setting_auto_hide_minutes(
                      minutes: seconds ~/ 60,
                    )
                  : t.media_jump_history_setting_auto_hide_seconds(
                      seconds: seconds,
                    ),
            ),
        ],
        selected: (SettingsContext settingsContext) =>
            settingsContext.appModel.jumpHistoryAutoHideSeconds,
        onChanged: (SettingsContext settingsContext, int seconds) async {
          await settingsContext.appModel.setJumpHistoryAutoHideSeconds(seconds);
        },
        defaultValue: kJumpHistoryAutoHideDefaultSeconds,
      ),
      SettingsSwitchItem(
        id: 'appearance.jump_history.progress_marks',
        title: t.media_jump_history_setting_marks,
        subtitle: t.media_jump_history_setting_marks_hint,
        icon: FushiIcons.flag,
        value: (SettingsContext settingsContext) =>
            settingsContext.appModel.jumpHistoryProgressMarks,
        onChanged: (SettingsContext settingsContext, bool value) async {
          await settingsContext.appModel.setJumpHistoryProgressMarks(value);
        },
        defaultValue: true,
      ),
    ],
  );
}

/// 「导航与首页 › 启动与底栏」的底栏样式。
SettingsItem buildNavBarStyleItem() {
  // 手机底栏形态：平铺（放不下收进「更多」）/ 拇指转盘 / 相机模式条
  // （出厂默认）。分页滑动与圆柱滚筒已于 2026-10-25 删除。
  return SettingsSegmentedItem<AdaptiveNavBarStyle>(
    id: 'appearance.nav_bar_style',
    title: t.home_nav_bar_style,
    subtitle: t.settings_navigation_nav_bar_style_hint,
    icon: FushiIcons.swipe,
    options: <SettingsSegmentOption<AdaptiveNavBarStyle>>[
      SettingsSegmentOption<AdaptiveNavBarStyle>(
        value: AdaptiveNavBarStyle.flat,
        label: t.home_nav_bar_style_flat,
      ),
      SettingsSegmentOption<AdaptiveNavBarStyle>(
        value: AdaptiveNavBarStyle.dial,
        label: t.home_nav_bar_style_dial,
      ),
      SettingsSegmentOption<AdaptiveNavBarStyle>(
        value: AdaptiveNavBarStyle.modeStrip,
        label: t.home_nav_bar_style_mode_strip,
      ),
    ],
    dropdown: true,
    selected: (SettingsContext settingsContext) =>
        settingsContext.appModel.navBarStyle,
    onChanged: (SettingsContext settingsContext, AdaptiveNavBarStyle value) =>
        settingsContext.appModel
            .setNavBarStyle(value)
            .then((_) => settingsContext.refresh()),
    defaultValue: AdaptiveNavBarStyle.defaultStyle,
  );
}

/// 「导航与首页 › 启动与底栏」的底栏文字开关。
SettingsItem buildNavBarLabelsItem() {
  // MD3 悬浮底栏（手机竖屏）图标下的标签；默认关 = M3E floating toolbar
  // 的纯图标形态（标签进 tooltip）。Apple 设计系统的标签栏不读它。
  return SettingsSwitchItem(
    id: 'appearance.nav_bar_labels',
    title: t.home_nav_bar_labels,
    subtitle: t.settings_navigation_nav_bar_labels_hint,
    icon: FushiIcons.textFields,
    value: (SettingsContext settingsContext) =>
        settingsContext.appModel.navBarLabelsVisible,
    onChanged: (SettingsContext settingsContext, bool value) {
      unawaited(
        settingsContext.appModel
            .setNavBarLabelsVisible(value)
            .then((_) => settingsContext.refresh()),
      );
    },
    defaultValue: false,
  );
}

/// 「导航与首页 › 启动与底栏」的反转底栏方向。
SettingsItem buildReverseNavigationBarItem() {
  return SettingsSwitchItem(
    id: 'appearance.reverse_navigation_bar',
    title: t.reverse_navigation_bar,
    subtitle: t.settings_navigation_reverse_nav_bar_hint,
    icon: Icons.swap_horiz_outlined,
    value: (SettingsContext settingsContext) =>
        settingsContext.appModel.reverseNavigationBar,
    onChanged: (SettingsContext settingsContext, bool value) {
      settingsContext.appModel.toggleReverseNavigationBar();
      settingsContext.refresh();
    },
    defaultValue: false,
  );
}

/// 「添加到 Steam」：写 Steam 的 shortcuts.vdf + 库封面（linux_steam_shortcut.dart）。
Future<void> _addFushiToSteam(SettingsContext settingsContext) async {
  try {
    final ByteData icon = await rootBundle.load('assets/meta/icon.png');
    final SteamShortcutReport report = await LinuxSteamShortcut.forThisProcess()
        .install(
          iconPng: icon.buffer.asUint8List(
            icon.offsetInBytes,
            icon.lengthInBytes,
          ),
        );
    if (report.failures.isNotEmpty) {
      ErrorLogService.instance.log(
        'settings.steam_shortcut',
        StateError(report.failures.join('; ')),
        StackTrace.current,
      );
    }
    switch (report.outcome) {
      case SteamShortcutOutcome.added:
        FushiToast.show(msg: t.settings_steam_shortcut_added);
      case SteamShortcutOutcome.steamNotFound:
        FushiToast.show(msg: t.settings_steam_shortcut_not_found);
      case SteamShortcutOutcome.failed || SteamShortcutOutcome.removed:
        FushiToast.show(
          msg: t.settings_steam_shortcut_failed(
            reason: report.failures.join('; '),
          ),
        );
    }
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('settings.steam_shortcut', error, stack);
    FushiToast.show(msg: t.settings_steam_shortcut_failed(reason: '$error'));
  }
  // 行在「添加 / 移除」之间切换。
  settingsContext.refresh();
}

/// 「从 Steam 移除」：删 Fushi 自己的条目、库封面和启动脚本。
Future<void> _removeFushiFromSteam(SettingsContext settingsContext) async {
  try {
    final SteamShortcutReport report = await LinuxSteamShortcut.forThisProcess()
        .uninstall();
    if (report.outcome == SteamShortcutOutcome.removed) {
      FushiToast.show(msg: t.settings_steam_shortcut_removed);
    } else {
      FushiToast.show(
        msg: t.settings_steam_shortcut_remove_failed(
          reason: report.failures.join('; '),
        ),
      );
    }
    if (report.failures.isNotEmpty) {
      ErrorLogService.instance.log(
        'settings.steam_shortcut',
        StateError(report.failures.join('; ')),
        StackTrace.current,
      );
    }
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('settings.steam_shortcut', error, stack);
    FushiToast.show(
      msg: t.settings_steam_shortcut_remove_failed(reason: '$error'),
    );
  }
  settingsContext.refresh();
}

/// 「通用 › 性能与上手」的「添加到 Steam / 从 Steam 移除」两行（只在 Linux 出现，
/// 二者按是否已加过互斥显示）。是一次性的安装动作，与界面长什么样无关，所以不在
/// 外观页；留在本文件是因为依赖这里的私有 helper。id 不变（历史 appearance 前缀）。
List<SettingsItem> buildSteamShortcutItems() {
  return <SettingsItem>[
    // Linux：把 Fushi 作为非 Steam 游戏加进 Steam 库（带库封面），Steam Deck
    // 游戏模式里从库启动，配合游戏模式截屏识字（gamescope_overlay.h）。
    // 已加过就换成「从 Steam 移除」（只认 Fushi 自己写的条目）。
    SettingsActionItem(
      id: 'appearance.steam_shortcut',
      title: t.settings_steam_shortcut_add,
      subtitle: t.settings_steam_shortcut_add_hint,
      icon: FushiIcons.games,
      visible: (_) =>
          hostPlatform.isLinux &&
          !LinuxSteamShortcut.forThisProcess().isInstalled(),
      // 写的是 Steam 的配置（Fushi 数据之外），CLI 要带 --yes。
      cli: const SettingsCliAction.tap(confirm: true),
      onTap: _addFushiToSteam,
    ),
    SettingsActionItem(
      id: 'appearance.steam_shortcut_remove',
      title: t.settings_steam_shortcut_remove,
      subtitle: t.settings_steam_shortcut_remove_hint,
      icon: FushiIcons.games,
      visible: (_) =>
          hostPlatform.isLinux &&
          LinuxSteamShortcut.forThisProcess().isInstalled(),
      cli: const SettingsCliAction.tap(confirm: true),
      onTap: _removeFushiFromSteam,
    ),
  ];
}

/// 「通用 › 键盘与手柄」的手柄查词模式行。没有第二块屏也能用，是手柄输入方式，
/// 所以和快捷键、焦点导航放在一起；id 不变（历史 appearance 前缀）。
SettingsItem buildControllerLookupStyleItem() {
  // 手柄查词模式（S6）：按住 L1 / Select 切换 / 关。未设时一律按住 L1，单屏也是
  // （2026-11-22 手柄查词统一拍板）。
  return SettingsSegmentedItem<ControllerLookupStyle>(
    id: 'appearance.controller_lookup_style',
    title: t.second_screen_controller_lookup_title,
    subtitle: t.second_screen_controller_lookup_hint,
    icon: FushiIcons.lookup,
    options: <SettingsSegmentOption<ControllerLookupStyle>>[
      SettingsSegmentOption<ControllerLookupStyle>(
        value: ControllerLookupStyle.holdL1,
        label: t.second_screen_controller_lookup_hold_l1,
      ),
      SettingsSegmentOption<ControllerLookupStyle>(
        value: ControllerLookupStyle.selectToggle,
        label: t.second_screen_controller_lookup_select,
      ),
      SettingsSegmentOption<ControllerLookupStyle>(
        value: ControllerLookupStyle.off,
        label: t.second_screen_controller_lookup_off,
      ),
    ],
    selected: (SettingsContext c) => ControllerLookupStyle.resolve(
      c.appModel.prefsRepo.getPref(kControllerLookupStylePrefKey),
    ),
    onChanged: (SettingsContext c, ControllerLookupStyle value) => c
        .appModel
        .prefsRepo
        .setPref(kControllerLookupStylePrefKey, value.name)
        .then((_) => c.refresh()),
    defaultValue: ControllerLookupStyle.holdL1,
  );
}

/// 全刷间隔下拉的选项文案：0 = 关，1 = 每页，其余 = 每 N 页。
String einkFullRefreshIntervalLabel(int interval) => switch (interval) {
  <= 0 => t.eink_full_refresh_interval_off,
  1 => t.eink_full_refresh_interval_every_page,
  _ => t.eink_full_refresh_interval_every_n_pages(n: interval),
};

/// 「玻璃画质」设置行是否显示：只在 Apple（Cupertino）设计系统下（[isGlassDesign]
/// 已排除墨水屏），M3E 不显示。
bool glassQualitySettingVisible(BuildContext context) => isGlassDesign(context);
