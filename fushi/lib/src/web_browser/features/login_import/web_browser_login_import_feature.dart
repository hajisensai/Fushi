import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
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
class WebBrowserLoginImportFeature extends WebBrowserFeature {
  WebBrowserLoginImportFeature({
    Future<WebViewEnvironment?> Function()? environment,
    Future<bool> Function(Uri url)? openExternal,
  }) : _environment = environment ?? MangaWebViewEnvironment.obtain,
       _openExternal =
           openExternal ??
           ((Uri url) => launchUrl(url, mode: LaunchMode.externalApplication));

  final Future<WebViewEnvironment?> Function() _environment;
  final Future<bool> Function(Uri url) _openExternal;

  BrowserCookieImportRequestHandle? _import;
  String _lastSignature = '';

  @override
  String get id => 'login-import';

  @override
  bool get available =>
      browserExtensionSupportedOn(isDesktop: DesktopLookupService.isDesktop);

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

  /// 登记 [url] 的站点并在系统浏览器打开它；扩展送回的 cookie 写进来后重载 [tab]。
  @visibleForTesting
  Future<void> begin(WebBrowserTab tab, Uri url) async {
    final String host = BrowserCookieImportGate.normalizeHost(url.host);
    _import?.end();
    _lastSignature = '';
    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin(host);
    _import = handle;
    // 句柄 end() 关闭 deliveries，订阅随之结束，不必另存。
    handle.deliveries.listen(
      (BrowserCookieDelivery delivery) =>
          unawaited(_apply(tab, host, delivery)),
    );
    FushiToast.show(
      msg: t.web_browser_login_import_waiting,
      toastLength: Toast.LENGTH_LONG,
      severity: ToastSeverity.info,
    );
    try {
      await _openExternal(Uri(scheme: 'https', host: url.host, path: '/'));
    } catch (e) {
      ErrorLogService.instance.log('web_browser', 'login import open: $e');
    }
  }

  Future<void> _apply(
    WebBrowserTab tab,
    String host,
    BrowserCookieDelivery delivery,
  ) async {
    final List<BrowserSiteCookie> cookies = browserSiteCookiesForSite(
      delivery.cookies,
      host,
    );
    if (cookies.isEmpty) return;
    // 扩展会在页面每次变化时重送同一批：内容没变就不再写、不再重载。
    final String signature =
        (cookies
                .map(
                  (BrowserSiteCookie c) => '${c.domain}|${c.name}=${c.value}',
                )
                .toList()
              ..sort())
            .join(';');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    final CookieManager manager;
    try {
      manager = CookieManager.instance(
        webViewEnvironment: await _environment(),
      );
    } catch (e) {
      ErrorLogService.instance.log('web_browser', 'login import env: $e');
      return;
    }
    final int written = await writeBrowserSiteCookies(manager, cookies);
    if (written == 0) return;
    FushiToast.show(
      msg: t.web_browser_login_import_received(count: written),
      severity: ToastSeverity.success,
    );
    await tab.controller?.reload();
  }

  @override
  void dispose() {
    _import?.end();
    _import = null;
  }
}
