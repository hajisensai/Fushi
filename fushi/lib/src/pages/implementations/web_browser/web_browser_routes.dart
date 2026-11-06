import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_bookmarks_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_clear_data_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_downloads_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_history_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_search_engines_page.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_site_settings_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// 数据页回调：在浏览器里打开 [url]（[newTab] = 新标签页）。
typedef WebBrowserOpenUrl = void Function(Uri url, {bool newTab});

/// 浏览器数据页（历史 / 书签 / 下载 / 清除浏览数据 / 网站设置 / 搜索引擎）。
/// 侧边栏、「⋯」菜单、设置页都从这里推，构造参数只在这一处写。
enum WebBrowserDataPage {
  history,
  bookmarks,
  downloads,
  clearData,
  siteSettings,
  searchEngines,
}

Widget buildWebBrowserDataPage(
  WebBrowserDataPage page, {
  required WebBrowserStore store,
  required PrefStore prefs,
  WebBrowserOpenUrl? onOpen,
}) => switch (page) {
  WebBrowserDataPage.history => WebBrowserHistoryPage(
    store: store,
    onOpen: onOpen,
  ),
  WebBrowserDataPage.bookmarks => WebBrowserBookmarksPage(
    store: store,
    onOpen: onOpen,
  ),
  WebBrowserDataPage.downloads => WebBrowserDownloadsPage(store: store),
  WebBrowserDataPage.clearData => WebBrowserClearDataPage(store: store),
  WebBrowserDataPage.siteSettings => WebBrowserSiteSettingsPage(
    settings: WebBrowserSiteSettings(prefs),
  ),
  WebBrowserDataPage.searchEngines => WebBrowserSearchEnginesPage(prefs: prefs),
};

Future<void> openWebBrowserDataPage(
  BuildContext context,
  WebBrowserDataPage page, {
  required WebBrowserStore store,
  required PrefStore prefs,
  WebBrowserOpenUrl? onOpen,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (BuildContext _) => buildWebBrowserDataPage(
      page,
      store: store,
      prefs: prefs,
      onOpen: onOpen,
    ),
  ),
);
