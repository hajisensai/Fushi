import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/utils.dart';

/// 「功能模块」开关行的 item id。
///
/// **历史前缀 `system.` 冻结不改**：这些 id 是设置搜索的定位锚点，与展示分类本就
/// 解耦（同款先例见下面 app_shell 里关于 `appearance.startup_default_dictionary_tab`
/// 的注释），改 id 只会平白动摇锚点。四个后加的模块沿用同一前缀保持一致。
String _moduleItemId(ModuleId module) => switch (module) {
  ModuleId.books => 'system.module_books',
  ModuleId.manga => 'system.module_manga',
  ModuleId.video => 'system.module_video',
  ModuleId.games => 'system.module_games',
  ModuleId.downloads => 'system.module_downloads',
  ModuleId.lookup => 'system.module_lookup',
  ModuleId.browserExtension => 'system.module_browser_extension',
  ModuleId.listening => 'system.module_listening',
  ModuleId.cardCreation => 'system.module_card_creation',
  ModuleId.services => 'system.module_services',
  ModuleId.sync => 'system.module_sync',
};

/// 「功能模块」开关行的标题与图标。
///
/// **一律取别处已有的真值，绝不在这里抄第二份标签**——此前这里抄了一套
/// `module_*_label`（'小说' 对底栏「书架」、'Galgame' 对底栏「游戏」），两份真值
/// 各改各的必然漂移，用户看到的就是设置项名字对不上底栏。
/// 有底栏 tab 的模块取 [homeNavItemFor]（底栏改名这里自动跟着改）；没有 tab 的四个
/// 取它自己那个设置一级分类的标题与图标（同理，分类改名这里自动跟着改）。
({String label, IconData icon}) _moduleNavIdentity(ModuleId module) {
  final HomeTab? tab = homeTabOfModule(module);
  if (tab != null) {
    final AdaptiveNavItem navItem = homeNavItemFor(tab);
    return (label: navItem.label, icon: navItem.icon);
  }
  return switch (module) {
    ModuleId.listening => (
      label: t.settings_destination_listening,
      icon: Icons.headphones_outlined,
    ),
    ModuleId.cardCreation => (
      label: t.settings_destination_card_creation,
      icon: Icons.style_outlined,
    ),
    ModuleId.services => (
      label: t.settings_destination_services,
      icon: Icons.cloud_outlined,
    ),
    ModuleId.sync => (
      label: t.settings_destination_sync_backup,
      icon: Icons.sync,
    ),
    // 上面 homeTabOfModule 已经把有 tab 的七个消化掉了；这里补齐 switch 让编译器
    // 在新增模块时强制点名，而不是静默落进一个 default 里显示错标签。
    ModuleId.books ||
    ModuleId.manga ||
    ModuleId.video ||
    ModuleId.games ||
    ModuleId.downloads ||
    ModuleId.lookup ||
    ModuleId.browserExtension => throw StateError(
      '$module 有对应 HomeTab，标识应走 homeNavItemFor',
    ),
  };
}

/// 「功能模块」里的单个模块开关。
SettingsSwitchItem _moduleSwitch(ModuleId module) {
  final ({String label, IconData icon}) identity = _moduleNavIdentity(module);
  return SettingsSwitchItem(
    id: _moduleItemId(module),
    title: identity.label,
    icon: identity.icon,
    // 平台上不存在的模块不出开关（galgame 仅 Windows、浏览器扩展仅桌面）。判据
    // 与读取端同源（[ModuleId.availableOn]），不在这里另写一份 Platform 判断。
    visible: (_) => module.availableOn(
      isWindows: Platform.isWindows,
      isDesktop: DesktopLookupService.isDesktop,
    ),
    value: (SettingsContext settingsContext) =>
        settingsContext.appModel.moduleEnabled(module),
    onChanged: (SettingsContext settingsContext, bool enabled) async {
      await settingsContext.appModel.setModuleEnabled(module, enabled);
      settingsContext.refresh();
    },
  );
}

SettingsDestination buildAppearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance,
    summary: t.design_system_hint,
    icon: Icons.palette_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_interface,
        items: <SettingsItem>[
          // searchTitle 复用各自绘制行的既有标题（无新 key），让这些自定义选择器
          // 进入设置搜索（主题/语言/明暗等此前搜不到）。
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: Icons.devices_outlined,
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
            icon: Icons.font_download_outlined,
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
            icon: Icons.translate,
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
      // 「功能模块」：11 个模块的总开关，值域与顺序都是 [ModuleId]。
      //
      // **本区管的不再只是底栏**。这些开关原来只喂 `homeActiveTabs()`（底栏/侧栏
      // tab 列表），于是「关掉视频」之后设置页仍列着「视频」「在线服务」，首页活动
      // 筛选条仍有「观看」，视频后台照跑——用户看到的是「只有底栏变干净了」。现在
      // 一个开关关掉该模块的**全部入口**：底栏/侧栏 tab、首页 dashboard 的条目与
      // 筛选、设置一级分类（连带设置搜索索引）、跨页跳转、该域快捷键、外部打开，
      // 以及它专属后台的下次自启。
      //
      // 两条刻意的例外：
      // - 首页/设置**恒在**，是全部模块关光后的安全回退面，没有 ModuleId。
      // - 关掉「查词」只关**页面入口**，查词**能力全留**（阅读器划词弹窗、设置 →
      //   查词 分类里的词典导入管理与音频来源）——用户拍板：纯阅读器仍要能查词。
      //
      // 分区住外观而不是系统：它与同分类的「反转导航栏」同域（此前在 系统 ›
      // 功能模块）。item id 保留 `system.` 历史前缀不动，理由见 [_moduleItemId]。
      SettingsSection(
        title: t.settings_section_modules,
        // 遍历 ModuleId.values 生成，不再逐个手写：加模块只加一个 enum 值，
        // 枚举顺序就是这里的展示顺序（库页 → 工具页 → 横切能力 → 设备数据）。
        // 平台上不存在的模块由 _moduleSwitch 自己的 visible 判掉。
        items: <SettingsItem>[
          for (final ModuleId module in ModuleId.values) _moduleSwitch(module),
        ],
      ),
      SettingsSection(
        title: t.settings_section_app_shell,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            icon: Icons.widgets_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            builder: (_) => const MiscellaneousSettingsPage(),
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
          ),
          // 「启动时打开查词」(id 'appearance.startup_default_dictionary_tab') 已归位到
          // 「系统 · 通用」分区（它管的是启动落地页/导航行为，与主题/明暗等外观无关）；
          // id / 持久化 key 保持不变（历史命名 appearance 前缀，仅换展示分类）。
        ],
      ),
    ],
  );
}
