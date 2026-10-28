import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/web_browser_routes.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_settings_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_web_adblock.dart';
import 'package:fushi/src/settings/settings_schema_web_browser_extension.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/utils.dart';

Future<void> _openDataPage(SettingsContext c, WebBrowserDataPage page) =>
    openWebBrowserDataPage(
      c.context,
      page,
      store: c.ref.read(webBrowserStoreProvider),
      prefs: c.appModel.prefsRepo,
    );

/// 「浏览器设置 › 通用」：标签页样式、滚动收起、搜索引擎、网页深色、默认桌面版、
/// 恢复标签页、清除浏览数据 / 网站设置入口。全是设备本地偏好（[web_browser_prefs]）。
SettingsSection buildWebBrowserSection() {
  return SettingsSection(
    id: 'web_browser.section.general',
    title: t.web_browser_title,
    items: <SettingsItem>[
      SettingsSegmentedItem<WebBrowserTabStyle>(
        id: 'system.web_browser_tab_style',
        title: t.web_browser_tab_style,
        subtitle: t.web_browser_settings_tab_style_hint,
        icon: FushiIcons.tab,
        defaultValue: kWebBrowserTabStyleDefault,
        options: <SettingsSegmentOption<WebBrowserTabStyle>>[
          SettingsSegmentOption<WebBrowserTabStyle>(
            value: WebBrowserTabStyle.sidebar,
            label: t.web_browser_tab_style_sidebar,
            icon: FushiIcons.sidebar,
          ),
          SettingsSegmentOption<WebBrowserTabStyle>(
            value: WebBrowserTabStyle.topStrip,
            label: t.web_browser_tab_style_top,
            icon: FushiIcons.tab,
          ),
        ],
        selected: (SettingsContext c) =>
            webBrowserTabStyle(c.appModel.prefsRepo),
        onChanged: (SettingsContext c, WebBrowserTabStyle value) async {
          await setWebBrowserTabStyle(c.appModel.prefsRepo, value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'system.web_browser_collapse_on_scroll',
        title: t.web_browser_settings_collapse_on_scroll,
        subtitle: t.web_browser_settings_collapse_on_scroll_hint,
        icon: FushiIcons.swipe,
        defaultValue: kWebBrowserCollapseOnScrollDefault,
        value: (SettingsContext c) =>
            webBrowserCollapseOnScroll(c.appModel.prefsRepo),
        onChanged: (SettingsContext c, bool value) async {
          await setWebBrowserCollapseOnScroll(c.appModel.prefsRepo, value);
          c.refresh();
        },
      ),
      SettingsSegmentedItem<String>(
        id: 'system.web_browser_search_engine',
        title: t.web_browser_search_engine,
        icon: FushiIcons.search,
        dropdown: true,
        defaultValue: WebBrowserSearchEngine.google.prefValue,
        options: <SettingsSegmentOption<String>>[
          for (final WebBrowserSearchEngine e in WebBrowserSearchEngine.values)
            SettingsSegmentOption<String>(value: e.prefValue, label: e.label),
        ],
        optionsBuilder: (SettingsContext c) => <SettingsSegmentOption<String>>[
          for (final WebBrowserSearchProvider p in webBrowserSearchProviders(
            c.appModel.prefsRepo,
          ))
            SettingsSegmentOption<String>(value: p.prefValue, label: p.label),
        ],
        selected: (SettingsContext c) =>
            readWebBrowserSearchProvider(c.appModel.prefsRepo).prefValue,
        onChanged: (SettingsContext c, String value) async {
          final List<WebBrowserSearchProvider> all = webBrowserSearchProviders(
            c.appModel.prefsRepo,
          );
          for (final WebBrowserSearchProvider p in all) {
            if (p.prefValue == value) {
              await writeWebBrowserSearchProvider(c.appModel.prefsRepo, p);
              break;
            }
          }
          c.refresh();
        },
      ),
      SettingsNavigationItem(
        id: 'system.web_browser_search_engines',
        title: t.web_browser_settings_manage_search_engines,
        icon: FushiIcons.manageSearch,
        onTap: (SettingsContext c) async {
          await _openDataPage(c, WebBrowserDataPage.searchEngines);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'system.web_browser_force_dark',
        title: t.web_browser_settings_force_dark,
        subtitle: t.web_browser_settings_force_dark_hint,
        icon: FushiIcons.darkMode,
        defaultValue: kWebBrowserForceDarkDefault,
        value: (SettingsContext c) => webBrowserForceDark(c.appModel.prefsRepo),
        onChanged: (SettingsContext c, bool value) async {
          await setWebBrowserForceDark(c.appModel.prefsRepo, value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'system.web_browser_desktop_mode_default',
        title: t.web_browser_settings_desktop_default,
        icon: FushiIcons.laptop,
        defaultValue: kWebBrowserDesktopModeDefaultDefault,
        value: (SettingsContext c) =>
            webBrowserDesktopModeDefault(c.appModel.prefsRepo),
        onChanged: (SettingsContext c, bool value) async {
          await setWebBrowserDesktopModeDefault(c.appModel.prefsRepo, value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'system.web_browser_restore_tabs',
        title: t.web_browser_settings_restore_tabs,
        subtitle: t.web_browser_settings_restore_tabs_hint,
        icon: FushiIcons.restart,
        defaultValue: kWebBrowserRestoreTabsDefault,
        value: (SettingsContext c) =>
            webBrowserRestoreTabs(c.appModel.prefsRepo),
        onChanged: (SettingsContext c, bool value) async {
          await setWebBrowserRestoreTabs(c.appModel.prefsRepo, value);
          c.refresh();
        },
      ),
      SettingsNavigationItem(
        id: 'system.web_browser_site_settings',
        title: t.web_browser_settings_site_settings,
        icon: FushiIcons.shield,
        onTap: (SettingsContext c) =>
            _openDataPage(c, WebBrowserDataPage.siteSettings),
      ),
      SettingsNavigationItem(
        id: 'system.web_browser_clear_data',
        title: t.web_browser_settings_clear_data,
        icon: FushiIcons.deleteSweep,
        onTap: (SettingsContext c) =>
            _openDataPage(c, WebBrowserDataPage.clearData),
      ),
    ],
  );
}

/// 「浏览器设置」的分组（宽屏是左侧导航的一项，窄屏是总览页的一行）。前两组是浏览器
/// 本身，其余是浏览器扩展的设置（文案来自扩展字典，见 [WebBrowserExtensionSettingsGroup]）。
enum WebBrowserSettingsGroup {
  general,
  adblock,
  lookup,
  subtitle,
  subtitleStyle,
  appearance,
  shortcuts,
  study;

  /// 对应的扩展分组；浏览器本身的分组为 null。
  WebBrowserExtensionSettingsGroup? get extension => switch (this) {
    general || adblock => null,
    lookup => WebBrowserExtensionSettingsGroup.lookup,
    subtitle => WebBrowserExtensionSettingsGroup.subtitle,
    subtitleStyle => WebBrowserExtensionSettingsGroup.subtitleStyle,
    appearance => WebBrowserExtensionSettingsGroup.appearance,
    shortcuts => WebBrowserExtensionSettingsGroup.shortcuts,
    study => WebBrowserExtensionSettingsGroup.study,
  };

  /// 本组的详情页（每次调用现建）。扩展分组的文案要求字典已读入（[WebBrowserExtensionStrings]）。
  SettingsDestination destination() => switch (this) {
    general => SettingsDestination(
      id: SettingsDestinationId.system,
      title: t.settings_section_general,
      icon: FushiIcons.globe,
      sections: <SettingsSection>[buildWebBrowserSection()],
    ),
    adblock => SettingsDestination(
      id: SettingsDestinationId.system,
      title: t.web_adblock_section_title,
      icon: FushiIcons.block,
      sections: <SettingsSection>[buildWebAdblockSection()],
    ),
    _ => extension!.destination(),
  };
}

/// 分组标题（扩展分组取扩展字典）。
String webBrowserSettingsGroupTitle(WebBrowserSettingsGroup g) {
  final WebBrowserExtensionStrings x = WebBrowserExtensionStrings.instance;
  return switch (g) {
    WebBrowserSettingsGroup.general => t.settings_section_general,
    WebBrowserSettingsGroup.adblock => t.web_adblock_section_title,
    WebBrowserSettingsGroup.lookup => x.tr('opt_group_lookup'),
    WebBrowserSettingsGroup.subtitle => x.tr('opt_group_subtitle'),
    WebBrowserSettingsGroup.subtitleStyle => x.tr('opt_group_subtitle_style'),
    WebBrowserSettingsGroup.appearance => x.tr('opt_group_appearance'),
    WebBrowserSettingsGroup.shortcuts => x.tr('opt_group_shortcut'),
    WebBrowserSettingsGroup.study => x.tr('opt_group_advanced'),
  };
}

/// 分组图标（与扩展设置页左侧导航同一语义）。
IconData webBrowserSettingsGroupIcon(WebBrowserSettingsGroup g) => switch (g) {
  WebBrowserSettingsGroup.general => FushiIcons.globe,
  WebBrowserSettingsGroup.adblock => FushiIcons.block,
  WebBrowserSettingsGroup.lookup => FushiIcons.search,
  WebBrowserSettingsGroup.subtitle => FushiIcons.subtitles,
  WebBrowserSettingsGroup.subtitleStyle => FushiIcons.textFields,
  WebBrowserSettingsGroup.appearance => FushiIcons.appearance,
  WebBrowserSettingsGroup.shortcuts => FushiIcons.keyboard,
  WebBrowserSettingsGroup.study => FushiIcons.timer,
};

/// 浏览器设置的总览页（窄屏下钻的第一层；也是设置搜索的子页路径）。
///
/// 浏览器本身两组用 `child`（行进设置搜索索引、进焦点覆盖遍历，与改版前同一批行）；
/// 扩展各组的文案来自扩展字典、要异步读入，故不进静态索引——点进去前先读字典。
/// 复用 `system` 的 id（子页不扩容枚举），必须经 `SettingsDetailPage.subPage` 推。
SettingsDestination webBrowserSettingsDestination() {
  unawaited(WebBrowserExtensionStrings.instance.ensureLoaded());
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.web_browser_menu_settings,
    icon: FushiIcons.globe,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'web_browser.section.browser',
        title: t.web_browser_title,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'web_browser.group.general',
            title: t.settings_section_general,
            icon: FushiIcons.globe,
            showIcon: true,
            child: WebBrowserSettingsGroup.general.destination,
          ),
          SettingsNavigationItem(
            id: 'web_browser.group.adblock',
            title: t.web_adblock_section_title,
            icon: FushiIcons.block,
            showIcon: true,
            child: WebBrowserSettingsGroup.adblock.destination,
          ),
        ],
      ),
      SettingsSection(
        id: 'web_browser.section.extension',
        title: t.nav_browser_extension,
        items: <SettingsItem>[
          for (final WebBrowserSettingsGroup g
              in WebBrowserSettingsGroup.values)
            if (g.extension != null)
              SettingsNavigationItem(
                id: 'web_browser.group.${g.name}',
                // 字典此刻可能还没读完：标题在渲染时取。
                title: webBrowserSettingsGroupTitle(g),
                titleBuilder: (SettingsContext _) =>
                    webBrowserSettingsGroupTitle(g),
                icon: webBrowserSettingsGroupIcon(g),
                showIcon: true,
                onTap: (SettingsContext c) async {
                  await WebBrowserExtensionStrings.instance.ensureLoaded();
                  if (!c.context.mounted) return;
                  await Navigator.of(c.context).push<void>(
                    adaptivePageRoute<void>(
                      context: c.context,
                      builder: (BuildContext _) =>
                          SettingsDetailPage.subPage(g.destination),
                    ),
                  );
                  c.refresh();
                },
              ),
        ],
      ),
    ],
  );
}

/// 「系统」分类里的浏览器入口：一行，点开统一的浏览器设置（宽屏双栏 / 窄屏总览）。
/// `child` 只给设置搜索与覆盖遍历用（搜到浏览器的行时沿总览 → 分组下钻定位）。
SettingsSection buildWebBrowserEntrySection() => SettingsSection(
  id: 'system.section.web_browser',
  title: t.web_browser_title,
  items: <SettingsItem>[
    SettingsNavigationItem(
      id: 'system.web_browser_settings',
      title: t.web_browser_menu_settings,
      icon: FushiIcons.globe,
      onTap: (SettingsContext c) async {
        await openWebBrowserSettings(c.context);
        c.refresh();
      },
      child: webBrowserSettingsDestination,
    ),
  ],
);
