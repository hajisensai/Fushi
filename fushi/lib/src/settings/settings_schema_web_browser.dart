import 'package:fushi/src/pages/implementations/web_browser/web_browser_routes.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_web_adblock.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
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

/// 「系统 › 浏览器」分组：标签页样式、滚动收起、搜索引擎、网页深色、默认桌面版、
/// 恢复标签页、清除浏览数据 / 网站设置入口。全是设备本地偏好（[web_browser_prefs]）。
SettingsSection buildWebBrowserSection() {
  return SettingsSection(
    id: 'system.section.web_browser',
    presentation: SettingsSectionPresentation.collapsed,
    title: t.web_browser_title,
    items: <SettingsItem>[
      SettingsSegmentedItem<WebBrowserTabStyle>(
        id: 'system.web_browser_tab_style',
        title: t.web_browser_tab_style,
        subtitle: t.web_browser_settings_tab_style_hint,
        icon: FushiIcons.webAsset,
        defaultValue: kWebBrowserTabStyleDefault,
        options: <SettingsSegmentOption<WebBrowserTabStyle>>[
          SettingsSegmentOption<WebBrowserTabStyle>(
            value: WebBrowserTabStyle.sidebar,
            label: t.web_browser_tab_style_sidebar,
            icon: FushiIcons.menuOpen,
          ),
          SettingsSegmentOption<WebBrowserTabStyle>(
            value: WebBrowserTabStyle.topStrip,
            label: t.web_browser_tab_style_top,
            icon: FushiIcons.webAsset,
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

/// 浏览页「⋯ › 浏览器设置」推的独立子页：浏览器分组 + 网页广告拦截分组。
/// 复用 `system` 的 id（子页不扩容枚举），必须经 `SettingsDetailPage.subPage` 推。
SettingsDestination webBrowserSettingsDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: t.web_browser_menu_settings,
  icon: FushiIcons.globe,
  sections: <SettingsSection>[
    buildWebBrowserSection(),
    buildWebAdblockSection(),
  ],
);
