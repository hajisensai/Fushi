import 'package:fushi_engine/foundation/pref_store.dart';

/// 浏览器的设备本地偏好（不进备份 / 同步 / Profile）。读写一律走这里的函数，
/// 设置页、浏览页、标签页 WebView 共用同一份键与默认值。

/// 宽窗口（≥ `kWebBrowserChromeTopMinWidth`）下标签页摆在哪。值名即持久化值。
enum WebBrowserTabStyle {
  /// 左侧页面栏（竖排标签页 + 书签 / 历史 / 下载入口）。默认（用户 2026-10-23 拍板）。
  sidebar,

  /// 地址栏上方一排横向标签。
  topStrip;

  static WebBrowserTabStyle fromName(Object? name) =>
      WebBrowserTabStyle.values.firstWhere(
        (WebBrowserTabStyle s) => s.name == name,
        orElse: () => WebBrowserTabStyle.sidebar,
      );
}

const String kWebBrowserTabStylePref = 'web_browser_tab_style';
const String kWebBrowserSidebarOpenPref = 'web_browser_sidebar_open';
const String kWebBrowserCollapseOnScrollPref =
    'web_browser_collapse_toolbar_on_scroll';
const String kWebBrowserForceDarkPref = 'web_browser_force_dark';
const String kWebBrowserDesktopModeDefaultPref =
    'web_browser_desktop_mode_default';
const String kWebBrowserRestoreTabsPref = 'web_browser_restore_tabs';

/// 默认值（设置页 `defaultValue` 与读取端共用）。
const WebBrowserTabStyle kWebBrowserTabStyleDefault =
    WebBrowserTabStyle.sidebar;
const bool kWebBrowserSidebarOpenDefault = true;
const bool kWebBrowserCollapseOnScrollDefault = true;
const bool kWebBrowserForceDarkDefault = false;
const bool kWebBrowserDesktopModeDefaultDefault = false;
const bool kWebBrowserRestoreTabsDefault = true;

bool _readBool(PrefStore prefs, String key, bool fallback) {
  final Object? raw = prefs.getPref(key, defaultValue: fallback);
  return raw is bool ? raw : fallback;
}

WebBrowserTabStyle webBrowserTabStyle(PrefStore prefs) =>
    WebBrowserTabStyle.fromName(prefs.getPref(kWebBrowserTabStylePref));

Future<void> setWebBrowserTabStyle(PrefStore prefs, WebBrowserTabStyle style) =>
    prefs.setPref(kWebBrowserTabStylePref, style.name);

/// 侧边栏模式下侧边栏是否展开（记住开关状态）。
bool webBrowserSidebarOpen(PrefStore prefs) =>
    _readBool(prefs, kWebBrowserSidebarOpenPref, kWebBrowserSidebarOpenDefault);

Future<void> setWebBrowserSidebarOpen(PrefStore prefs, bool open) =>
    prefs.setPref(kWebBrowserSidebarOpenPref, open);

/// 手机上往下滚网页时把工具栏收成小地址条。
bool webBrowserCollapseOnScroll(PrefStore prefs) => _readBool(
  prefs,
  kWebBrowserCollapseOnScrollPref,
  kWebBrowserCollapseOnScrollDefault,
);

Future<void> setWebBrowserCollapseOnScroll(PrefStore prefs, bool value) =>
    prefs.setPref(kWebBrowserCollapseOnScrollPref, value);

/// 网页深色模式（标签页 WebView 读它决定是否强制深色）。
bool webBrowserForceDark(PrefStore prefs) =>
    _readBool(prefs, kWebBrowserForceDarkPref, kWebBrowserForceDarkDefault);

Future<void> setWebBrowserForceDark(PrefStore prefs, bool value) =>
    prefs.setPref(kWebBrowserForceDarkPref, value);

/// 新标签页默认打开桌面版网页。
bool webBrowserDesktopModeDefault(PrefStore prefs) => _readBool(
  prefs,
  kWebBrowserDesktopModeDefaultPref,
  kWebBrowserDesktopModeDefaultDefault,
);

Future<void> setWebBrowserDesktopModeDefault(PrefStore prefs, bool value) =>
    prefs.setPref(kWebBrowserDesktopModeDefaultPref, value);

/// 重启后恢复上次的（非无痕）标签页。
bool webBrowserRestoreTabs(PrefStore prefs) =>
    _readBool(prefs, kWebBrowserRestoreTabsPref, kWebBrowserRestoreTabsDefault);

Future<void> setWebBrowserRestoreTabs(PrefStore prefs, bool value) =>
    prefs.setPref(kWebBrowserRestoreTabsPref, value);

/// 浏览器的设备本地偏好键：不进备份 / 同步 / Profile 快照
/// （`SyncRepository._deviceLocalFixedKeys` 展开它）。功能插件的键用字面量登记，
/// 免得本文件反向依赖各功能目录。
const List<String> kWebBrowserDeviceLocalPrefKeys = <String>[
  kWebBrowserTabStylePref,
  kWebBrowserSidebarOpenPref,
  kWebBrowserCollapseOnScrollPref,
  kWebBrowserForceDarkPref,
  kWebBrowserDesktopModeDefaultPref,
  kWebBrowserRestoreTabsPref,
  // features/furigana（整页注音开关）。
  'web_browser_furigana',
  // 已删除的「生词高亮」开关：不再读写，存量值仍不进备份 / 同步。
  'web_browser_known_words',
  // web_browser_sites.dart（当前搜索引擎、自定义引擎）。
  'web_browser_search_engine',
  'web_browser_custom_search_engines',
  // data/web_browser_site_settings.dart（按站点的权限决定）。
  'web_browser_site_permissions',
  // features/youtube_subtitles（页内可点字幕开关）。
  'web_browser_youtube_subtitles',
];
