import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/utils.dart';

/// 「功能模块」里的单个 tab 显隐开关。
///
/// 标题与图标一律从底栏/侧栏的**同一个**真值 [homeNavItemFor] 取，杜绝设置页再抄一份
/// 标签（那是「设置里叫 Galgame、底栏叫游戏」这类不一致的成因）。[isTool] 区分库页与
/// 工具页两句提示文案。
SettingsSwitchItem _moduleSwitch({
  required String id,
  required HomeTab tab,
  required SettingsSwitchGetter value,
  required Future<void> Function(SettingsContext settingsContext, bool enabled)
      setValue,
  SettingsVisibility? visible,
  bool isTool = false,
}) {
  final AdaptiveNavItem navItem = homeNavItemFor(tab);
  return SettingsSwitchItem(
    id: id,
    title: navItem.label,
    subtitle: isTool ? t.module_tool_toggle_hint : t.module_toggle_hint,
    icon: navItem.icon,
    visible: visible,
    value: value,
    onChanged: (SettingsContext settingsContext, bool enabled) async {
      await setValue(settingsContext, enabled);
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
              settingsContext.refresh();
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
      // 「功能模块」：小说/漫画/视频/游戏/浏览器扩展五个库页 tab 加 下载/查词 两个
      // 工具 tab 的显隐开关（库页那几项与新手引导的功能选择写同一真值）。首页/设置
      // 恒在，不提供开关；games 仅 Windows、扩展仅桌面显示（读取端还叠加平台门控）。
      // 顺序与底栏一致：库页 → 下载 → 查词 → 扩展。
      //
      // 本区管的是「底栏/侧栏出现哪些 tab」，与同分类的「反转导航栏」同域，故住外观
      // 而不是系统（此前在 系统 › 功能模块）。item id 保留 `system.` 历史前缀不动
      // ——id 与展示分类本就解耦（同款先例见下面 app_shell 里关于
      // 'appearance.startup_default_dictionary_tab' 的注释），改 id 只会平白动摇
      // 搜索定位锚点。
      //
      // 标题与图标**一律取底栏真值** [homeNavItemFor]，不再手写第二份：此前这里抄了
      // 一套 module_*_label（'小说' 对底栏「书架」、'Galgame' 对底栏「游戏」、
      // 英文 'Novels'/'Browser extension' 对 'Books'/'Extension'），两份真值各改各的
      // 必然漂移，用户看到的就是设置项名字对不上底栏。现在底栏改名，这里自动跟着改。
      SettingsSection(
        title: t.settings_section_modules,
        items: <SettingsItem>[
          _moduleSwitch(
            id: 'system.module_books',
            tab: HomeTab.books,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleBooksEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleBooksEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_manga',
            tab: HomeTab.manga,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleMangaEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleMangaEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_video',
            tab: HomeTab.video,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleVideoEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleVideoEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_games',
            tab: HomeTab.games,
            visible: (_) => Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleGamesEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleGamesEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_downloads',
            tab: HomeTab.downloads,
            isTool: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleDownloadsEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleDownloadsEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_lookup',
            tab: HomeTab.dictionaries,
            isTool: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleDictionariesEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel.setModuleDictionariesEnabled(value),
          ),
          _moduleSwitch(
            id: 'system.module_browser_extension',
            tab: HomeTab.browserExtension,
            visible: (_) => DesktopLookupService.isDesktop,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.moduleBrowserExtensionEnabled,
            setValue: (SettingsContext settingsContext, bool value) =>
                settingsContext.appModel
                    .setModuleBrowserExtensionEnabled(value),
          ),
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
