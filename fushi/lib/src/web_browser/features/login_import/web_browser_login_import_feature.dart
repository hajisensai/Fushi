import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/browser_login_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 「从浏览器导入登录」：把系统浏览器里本站的登录（cookie）搬进 app 内浏览器。
///
/// 与视频站点、漫画源登录页同一条通道（[BrowserCookieImportGate]）：登记本站 → 在系统
/// 浏览器打开本站 → Fushi 浏览器扩展把本站 cookie 送回来 → 写进浏览器标签页用的那份
/// cookie 存储（Windows 是 [MangaWebViewEnvironment]，其它平台是系统 WebView 共享的
/// 那份）→ 重载当前页。2026-10-26 用户：「站点里面怎么没有从浏览器复制数据的功能」——
/// 之前只有视频站点的工具条有这个按钮。
///
/// 只在装得了浏览器扩展的平台（桌面）装配；无痕标签页不给（无痕 cookie 不落盘，
/// 导进去也带不走）。
///
/// 登记 / 一次即结束 / 等待状态条 / 取消全在共用实现 [BrowserLoginImport] 里（漫画源
/// 登录页、视频站点网页档同一份）；这里只决定 cookie 写到哪、写完刷新哪个标签页。
class WebBrowserLoginImportFeature extends WebBrowserFeature {
  WebBrowserLoginImportFeature({
    Future<WebViewEnvironment?> Function()? environment,
    Future<bool> Function(Uri url)? openExternal,
    Future<int> Function(List<BrowserSiteCookie> cookies)? writeCookies,
  }) : _environment = environment ?? MangaWebViewEnvironment.obtain,
       _writeCookiesOverride = writeCookies {
    _import = BrowserLoginImport(
      write: (List<BrowserSiteCookie> cookies) =>
          (_writeCookiesOverride ?? _writeCookies)(cookies),
      openExternal: openExternal == null
          ? null
          : (Uri url) async {
              await openExternal(url);
            },
      onImported: _onImported,
      onFailed: () => FushiToast.show(
        msg: t.login_import_write_failed,
        severity: ToastSeverity.error,
      ),
    );
  }

  final Future<WebViewEnvironment?> Function() _environment;
  final Future<int> Function(List<BrowserSiteCookie> cookies)?
  _writeCookiesOverride;
  late final BrowserLoginImport _import;
  WebBrowserTab? _target;

  @override
  String get id => 'login-import';

  @override
  bool get available =>
      browserExtensionSupportedOn(isDesktop: DesktopLookupService.isDesktop);

  @override
  Listenable get actionsChanged => _import;

  /// 正在等扩展送回的站点（归一化 host）；没在等为 null。
  String? get pendingHost => _import.pendingHost;

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    final Uri? url = tab.url;
    if (tab.incognito ||
        url == null ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty) {
      return const <WebBrowserAction>[];
    }
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'login-import',
        icon: FushiIcons.login,
        label: t.web_browser_login_import,
        onPressed: () => unawaited(begin(tab, url)),
      ),
    ];
  }

  @override
  Widget? statusBar(BuildContext context) =>
      _import.waiting ? BrowserLoginImportStatusBar(import: _import) : null;

  /// 登记 [url] 的站点并在系统浏览器打开它；扩展送回的第一批本站 cookie 写进来后
  /// 结束登记并重载 [tab]。
  @visibleForTesting
  Future<void> begin(WebBrowserTab tab, Uri url) {
    _target = tab;
    return _import.begin(url);
  }

  /// 用户点了状态条上的「取消」。
  void cancel() => _import.cancel();

  void _onImported(int count) {
    FushiToast.show(
      msg: t.web_browser_login_import_received(count: count),
      severity: ToastSeverity.success,
    );
    final WebBrowserTab? tab = _target;
    _target = null;
    unawaited(tab?.controller?.reload());
  }

  Future<int> _writeCookies(List<BrowserSiteCookie> cookies) async {
    final CookieManager manager = CookieManager.instance(
      webViewEnvironment: await _environment(),
    );
    return writeBrowserSiteCookies(manager, cookies);
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    // 要重载的标签页没了：登记也没有意义了。
    if (identical(_target, tab)) {
      _target = null;
      cancel();
    }
  }

  @override
  void dispose() {
    _target = null;
    _import.dispose();
  }
}
