import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/utils.dart';

/// 清 WebView 侧数据（Cookie / 网站存储 / 缓存）的平台边界。页面只认这个接口，
/// 测试注入假实现。
abstract interface class WebBrowserSiteDataCleaner {
  /// Cookie 与网站存储能否按时间范围清（不能时整段清除，页面给出说明）。
  bool get supportsTimeRange;

  /// 清 Cookie 与网站数据；[since] 为 null = 全部。返回是否全部成功。
  Future<bool> clearCookiesAndSiteData({DateTime? since});

  /// 清 HTTP 缓存。返回是否成功。
  Future<bool> clearCache();
}

/// 生产实现：与浏览器 WebView 同一个 WebView2 环境（Windows 上 cookie 归环境
/// 所有，见 [MangaWebViewEnvironment]）；Android / Apple 是系统 WebView 共享的
/// 一份。
class InAppWebViewSiteDataCleaner implements WebBrowserSiteDataCleaner {
  const InAppWebViewSiteDataCleaner();

  static bool get _apple =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// Cookie 与网站存储（不含缓存：缓存由 [clearCache] 单独管）。
  static final Set<WebsiteDataType> _siteDataTypes = <WebsiteDataType>{
    WebsiteDataType.WKWebsiteDataTypeCookies,
    WebsiteDataType.WKWebsiteDataTypeSessionStorage,
    WebsiteDataType.WKWebsiteDataTypeLocalStorage,
    WebsiteDataType.WKWebsiteDataTypeWebSQLDatabases,
    WebsiteDataType.WKWebsiteDataTypeIndexedDBDatabases,
    WebsiteDataType.WKWebsiteDataTypeServiceWorkerRegistrations,
  };

  /// 只有 Apple 的 WKWebsiteDataStore 支持按修改时间删除。
  @override
  bool get supportsTimeRange => _apple;

  @override
  Future<bool> clearCookiesAndSiteData({DateTime? since}) async {
    bool ok = true;
    try {
      if (_apple) {
        await WebStorageManager.instance().removeDataModifiedSince(
          dataTypes: _siteDataTypes,
          date: since ?? DateTime.fromMillisecondsSinceEpoch(0),
        );
        return true;
      }
      final WebViewEnvironment? environment =
          await MangaWebViewEnvironment.obtain();
      ok = await CookieManager.instance(
        webViewEnvironment: environment,
      ).deleteAllCookies();
      if (defaultTargetPlatform == TargetPlatform.android) {
        await WebStorageManager.instance().deleteAllData();
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebBrowserClearData.cookies', error, stack);
      return false;
    }
    return ok;
  }

  @override
  Future<bool> clearCache() async {
    try {
      await InAppWebViewController.clearAllCache();
      return true;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebBrowserClearData.cache', error, stack);
      return false;
    }
  }
}

/// 清除浏览数据：时间范围 + 勾选（历史 / Cookie 与网站数据 / 缓存）。
class WebBrowserClearDataPage extends StatefulWidget {
  const WebBrowserClearDataPage({
    required this.store,
    this.cleaner = const InAppWebViewSiteDataCleaner(),
    super.key,
  });

  final WebBrowserStore store;
  final WebBrowserSiteDataCleaner cleaner;

  @override
  State<WebBrowserClearDataPage> createState() =>
      _WebBrowserClearDataPageState();
}

class _WebBrowserClearDataPageState extends State<WebBrowserClearDataPage> {
  WebBrowserClearRange _range = WebBrowserClearRange.lastHour;
  bool _history = true;
  bool _cookies = false;
  bool _cache = true;
  bool _busy = false;

  bool get _anything => _history || _cookies || _cache;

  Future<void> _pickRange() async {
    final WebBrowserClearRange? range =
        await showFushiChoiceDialog<WebBrowserClearRange>(
          context: context,
          title: t.web_browser_range_title,
          selected: _range,
          options: <FushiChoiceOption<WebBrowserClearRange>>[
            for (final WebBrowserClearRange r in WebBrowserClearRange.values)
              FushiChoiceOption<WebBrowserClearRange>(value: r, label: r.label),
          ],
        );
    if (range != null && mounted) setState(() => _range = range);
  }

  Future<void> _clear() async {
    if (_busy || !_anything) return;
    setState(() => _busy = true);
    final DateTime? since = _range.sinceFrom(DateTime.now());
    bool ok = true;
    try {
      if (_history) await widget.store.clearHistory(since: since);
      if (_cookies) {
        ok &= await widget.cleaner.clearCookiesAndSiteData(since: since);
      }
      if (_cache) ok &= await widget.cleaner.clearCache();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    showWebBrowserPageSnack(
      context,
      ok ? t.web_browser_clear_data_done : t.web_browser_clear_data_failed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool allTimeNote =
        !widget.cleaner.supportsTimeRange &&
        _range != WebBrowserClearRange.allTime &&
        (_cookies || _cache);
    return FushiPageScaffold(
      title: t.web_browser_clear_data_title,
      body: webBrowserPageListView(
        replayKey: 0,
        key: const ValueKey<String>('web_browser_clear_data_list'),
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: FushiGroupedList(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                FushiListItem(
                  key: const ValueKey<String>('web_browser_clear_data_range'),
                  leading: const FushiListLeadingIcon(FushiIcons.schedule),
                  title: Text(t.web_browser_range_title),
                  subtitle: Text(_range.label),
                  trailing: const FushiIcon(FushiIcons.chevronRight),
                  onTap: () => unawaited(_pickRange()),
                ),
              ],
            ),
          ),
          FushiStaggeredEntrance(
            index: 1,
            child: FushiGroupedList(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: <Widget>[
                _check(
                  key: 'history',
                  icon: FushiIcons.history,
                  title: t.web_browser_clear_data_history,
                  value: _history,
                  onChanged: (bool v) => setState(() => _history = v),
                ),
                _check(
                  key: 'cookies',
                  icon: FushiIcons.storage,
                  title: t.web_browser_clear_data_cookies,
                  subtitle: t.web_browser_clear_data_cookies_hint,
                  value: _cookies,
                  onChanged: (bool v) => setState(() => _cookies = v),
                ),
                _check(
                  key: 'cache',
                  icon: FushiIcons.image,
                  title: t.web_browser_clear_data_cache,
                  value: _cache,
                  onChanged: (bool v) => setState(() => _cache = v),
                ),
              ],
            ),
          ),
          if (allTimeNote)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
              child: Text(
                t.web_browser_clear_data_all_time_note,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          FushiStaggeredEntrance(
            index: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: FushiFilledButton(
                  key: const ValueKey<String>('web_browser_clear_data_action'),
                  onPressed: _busy || !_anything
                      ? null
                      : () => unawaited(_clear()),
                  child: Text(t.web_browser_clear_data_action),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _check({
    required String key,
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) => FushiListItem(
    key: ValueKey<String>('web_browser_clear_data_$key'),
    leading: FushiListLeadingIcon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: FushiCheckbox(
      value: value,
      onChanged: (bool? v) => onChanged(v ?? false),
    ),
    onTap: () => onChanged(!value),
  );
}
