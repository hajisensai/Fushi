import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/nav_module_order_list.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart'
    show currentAppIconSelection;
import 'package:fushi/utils.dart';

/// 「功能模块」开关行的 item id。
///
/// **历史前缀 `system.` 冻结不改**：这些 id 是设置搜索的定位锚点，与展示分类本就
/// 解耦（同款先例见下面 app_shell 里关于 `appearance.startup_default_dictionary_tab`
/// 的注释），改 id 只会平白动摇锚点。四个后加的模块沿用同一前缀保持一致。
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
  isWindows: Platform.isWindows,
  isDesktop: DesktopLookupService.isDesktop,
  isIOS: Platform.isIOS,
  isAndroid: Platform.isAndroid,
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

SettingsDestination buildAppearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance_interaction,
    summary: t.design_system_hint,
    icon: FushiIcons.appearance,
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
          // 玻璃材质档位：只在设计系统选「玻璃」时出现（设计系统行负责开关玻璃，
          // 这里只在毛玻璃 / 液态之间选）。正文、视频画面不变；墨水屏、系统增强
          // 对比度 / 降低透明度下自动回退实心，liquid 在引擎不支持着色器
          // ImageFilter 时降级为 frosted。随 Profile 走。
          //
          // 2026-10-06 用户拍板：Apple 设计系统固定毛玻璃，液态玻璃入口先关掉
          // ——本行恒不可见（设置页与设置搜索都走 visible 谓词，一并消失），
          // 生效值由 ThemeNotifier.glassMaterialTier 钉死（2026-10-12 起为 off：
          // 原生 Cupertino 实色，无玻璃特效）。schema 项、
          // 偏好键 `glass_material` 与液态渲染代码都保留，恢复时把 visible 改回
          // `designSystem == 'glass'` 并撤掉 glassMaterialTier 的钉死即可。
          SettingsSegmentedItem<FushiGlassMaterial>(
            id: 'appearance.glass_material',
            title: t.glass_material,
            subtitle: t.glass_material_hint,
            icon: Icons.blur_on_outlined,
            visible: (SettingsContext settingsContext) => false,
            options: <SettingsSegmentOption<FushiGlassMaterial>>[
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.frosted,
                label: t.glass_material_frosted,
              ),
              SettingsSegmentOption<FushiGlassMaterial>(
                value: FushiGlassMaterial.liquid,
                label: t.glass_material_liquid,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.glassMaterialTier,
            onChanged:
                (SettingsContext settingsContext, FushiGlassMaterial value) =>
                    settingsContext.appModel.setGlassMaterial(value),
            defaultValue: FushiGlassMaterial.frosted,
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
          // 「界面语言」从系统分类归位到这里：它改的是界面呈现语言，与主题/明暗/
          // 缩放同属界面外观；id/持久化 key 不变（本就带 appearance 前缀）。
          SettingsCustomItem(
            id: 'appearance.language',
            icon: Icons.translate_outlined,
            searchTitle: t.options_language,
            builder: buildLanguageSelector,
          ),
        ],
      ),
      SettingsSection(
        id: 'appearance.section.typography',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 排版分区**不折叠**：改字体是外观页的高频操作（用户显式反馈），折叠让每次
        // 改字体都多一次展开点击，收益（省一行高度）远小于代价。
        title: t.section_typography,
        items: <SettingsItem>[
          // TODO-231: 全app 只有一个可见字体库；每行字体自己管「用在哪些用途」
          // （font_catalog / font_targets 两个偏好键）。用途集合 = FontTarget.values
          // 全量，UI 侧遍历枚举渲染，新增用途不需要改这里。
          // 不传 target：外观入口是全局作用域，新增字体默认挂 FontTarget.body。
          SettingsNavigationItem(
            id: 'appearance.font_catalog',
            title: t.custom_fonts_catalog_title,
            icon: FushiIcons.font,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // 内容语言紧挨字体库：它决定的正是「用哪条字体链渲染内容」，属于同一件事
          // 的两半（选哪些字体 / 按什么语言挑）。这里设的是**默认值**，书/视频/
          // 游戏/词典各自的设置压过它，内容自带的声明（EPUB dc:language、词典
          // index.json、字幕轨 language）也压过它——见 resolveContentLanguage。
          SettingsNavigationItem(
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
            subtitle: t.settings_content_language_description,
            icon: FushiIcons.language,
            onTap: (SettingsContext settingsContext) async {
              final String current =
                  settingsContext.appModel.prefsRepo.defaultContentLanguage;
              await showContentLanguagePicker(
                context: settingsContext.context,
                title: t.settings_content_language_title,
                description: t.settings_content_language_description,
                current: current.isEmpty ? null : current,
                autoDetected: '',
                autoLabel: t.settings_content_language_unset,
                onSelected: (String? tag) async {
                  await settingsContext.appModel.prefsRepo
                      .setDefaultContentLanguage(tag ?? '');
                  settingsContext.refresh();
                  notifyReaderSettingsChanged(settingsContext);
                },
              );
            },
          ),
        ],
      ),
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
      // 分区住外观而不是系统：它与同分类的「反转导航栏」同域（此前在 系统 ›
      // 功能模块）。item id 保留 `system.` 历史前缀不动，理由见 [_moduleItemId]。
      SettingsSection(
        id: 'appearance.section.modules',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_modules,
        // 有底栏 tab 的模块收进一个可拖拽排序的列表（用户排的顺序就是底栏顺序）；
        // 没有 tab 的横切模块仍是逐个开关，按枚举顺序。两者都遍历 ModuleId.values
        // 生成，加模块只加一个 enum 值。平台上不存在的模块各自判掉。
        items: <SettingsItem>[
          _navModuleOrderItem(),
          for (final ModuleId module in ModuleId.values)
            if (homeTabOfModule(module) == null) _moduleSwitch(module),
        ],
      ),
      // 「首页面板」：首页 dashboard 上按用户情况出现的可选面板
      // （[HomeDashboardPanel] 注册表），每个面板一行 自动 / 显示 / 隐藏。首页
      // 模块关着时整段隐藏；面板所属模块关着时那一行隐藏。
      SettingsSection(
        id: 'appearance.section.home_panels',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_home_panels,
        visible: (SettingsContext c) =>
            c.appModel.moduleVisibility.isEnabled(ModuleId.home),
        items: <SettingsItem>[
          for (final HomeDashboardPanel panel in HomeDashboardPanel.values)
            _homePanelModeItem(panel),
        ],
      ),
      SettingsSection(
        id: 'appearance.section.navigation',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_app_shell,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            icon: FushiIcons.widgets,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
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
          SettingsSwitchItem(
            id: 'appearance.reverse_navigation_bar',
            title: t.reverse_navigation_bar,
            icon: Icons.swap_horiz_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.reverseNavigationBar,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleReverseNavigationBar();
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          // MD3 悬浮底栏（手机竖屏）图标下的标签；默认关 = M3E floating toolbar
          // 的纯图标形态（标签进 tooltip）。Apple 设计系统的标签栏不读它。
          SettingsSwitchItem(
            id: 'appearance.nav_bar_labels',
            title: t.home_nav_bar_labels,
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
          ),
          // 手机底栏形态：平铺（放不下收进「更多」）/ 拇指转盘 / 相机模式条
          // （出厂默认）。分页滑动与圆柱滚筒已于 2026-10-25 删除。
          SettingsSegmentedItem<AdaptiveNavBarStyle>(
            id: 'appearance.nav_bar_style',
            title: t.home_nav_bar_style,
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
            onChanged:
                (SettingsContext settingsContext, AdaptiveNavBarStyle value) =>
                    settingsContext.appModel
                        .setNavBarStyle(value)
                        .then((_) => settingsContext.refresh()),
            defaultValue: AdaptiveNavBarStyle.defaultStyle,
          ),
          // 「启动页」(id 'appearance.startup_default_dictionary_tab'，前身是开关
          // 「启动时打开查词」) 在「系统 · 通用」分区（它管的是启动落地页/导航行为，
          // 与主题/明暗等外观无关）；id 保持不变（历史命名 appearance 前缀）。
        ],
      ),
    ],
  );
}

/// 「首页面板」分区里一个面板的显示档（自动 / 显示 / 隐藏）。
SettingsItem _homePanelModeItem(HomeDashboardPanel panel) {
  final (
    String title,
    String hint,
    IconData icon,
    ModuleId module,
  ) = switch (panel) {
    HomeDashboardPanel.srsReview => (
      t.nav_srs,
      t.home_panel_srs_hint,
      FushiIcons.repeat,
      ModuleId.srs,
    ),
    HomeDashboardPanel.aiAgent => (
      t.ai_agent_title,
      t.home_panel_ai_agent_hint,
      FushiIcons.aiAssistant,
      ModuleId.ai,
    ),
    HomeDashboardPanel.panorama => (
      t.home_panel_panorama_title,
      t.home_panel_panorama_hint,
      FushiIcons.blur,
      ModuleId.home,
    ),
  };
  return SettingsSegmentedItem<HomeDashboardPanelMode>(
    id: 'appearance.home_panel.${panel.id}',
    title: title,
    subtitle: hint,
    icon: icon,
    visible: (SettingsContext c) =>
        c.appModel.moduleVisibility.isEnabled(module),
    options: <SettingsSegmentOption<HomeDashboardPanelMode>>[
      SettingsSegmentOption<HomeDashboardPanelMode>(
        value: HomeDashboardPanelMode.auto,
        label: t.home_panel_mode_auto,
      ),
      SettingsSegmentOption<HomeDashboardPanelMode>(
        value: HomeDashboardPanelMode.shown,
        label: t.home_panel_mode_shown,
      ),
      SettingsSegmentOption<HomeDashboardPanelMode>(
        value: HomeDashboardPanelMode.hidden,
        label: t.home_panel_mode_hidden,
      ),
    ],
    selected: (SettingsContext c) => c.appModel.homeDashboardPanelMode(panel),
    onChanged: (SettingsContext c, HomeDashboardPanelMode value) => c.appModel
        .setHomeDashboardPanelMode(panel, value)
        .then((_) => c.refresh()),
    defaultValue: HomeDashboardPanelMode.auto,
  );
}
