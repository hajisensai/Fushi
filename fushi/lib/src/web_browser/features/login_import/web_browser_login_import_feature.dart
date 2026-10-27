import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
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
///
/// **一次登记只导一次**：扩展在该站每次页面加载 / 每分钟心跳都会重送 cookie，登记若一直
/// 挂着，用户之后每次在系统浏览器里打开这个站，都会再往 app 里灌一批 cookie 并重载当前
/// 标签页。所以收到第一批本站 cookie 就**同步**结束登记（[BrowserCookieImportGate] 不再
/// 认这个 nonce，之后的回传一律 409），再去写 jar。等待期间页面内容上方有状态条（可取消）。
/// 还没在浏览器登录就送来的那批也算一次：状态条与提示让用户先登录再点一次。
class WebBrowserLoginImportFeature extends WebBrowserFeature {
  WebBrowserLoginImportFeature({
    Future<WebViewEnvironment?> Function()? environment,
    Future<bool> Function(Uri url)? openExternal,
    Future<int> Function(List<BrowserSiteCookie> cookies)? writeCookies,
  }) : _environment = environment ?? MangaWebViewEnvironment.obtain,
       _openExternal =
           openExternal ??
           ((Uri url) => launchUrl(url, mode: LaunchMode.externalApplication)),
       _writeCookiesOverride = writeCookies;

  final Future<WebViewEnvironment?> Function() _environment;
  final Future<bool> Function(Uri url) _openExternal;
  final Future<int> Function(List<BrowserSiteCookie> cookies)?
  _writeCookiesOverride;
  final WebBrowserFeatureNotifier _changed = WebBrowserFeatureNotifier();

  BrowserCookieImportRequestHandle? _import;
  WebBrowserTab? _target;

  @override
  String get id => 'login-import';

  @override
  bool get available =>
      browserExtensionSupportedOn(isDesktop: DesktopLookupService.isDesktop);

  @override
  Listenable get actionsChanged => _changed;

  /// 正在等扩展送回的站点（归一化 host）；没在等为 null。
  String? get pendingHost => _import?.request.host;

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
  Widget? statusBar(BuildContext context) {
    final String? host = pendingHost;
    if (host == null) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: FushiInlineNotice(
        icon: FushiIcons.login,
        message: t.web_browser_login_import_pending(host: host),
        actions: <Widget>[
          FushiTextButton(onPressed: cancel, child: Text(t.cancel)),
        ],
      ),
    );
  }

  /// 登记 [url] 的站点并在系统浏览器打开它；扩展送回的第一批本站 cookie 写进来后
  /// 结束登记并重载 [tab]。
  @visibleForTesting
  Future<void> begin(WebBrowserTab tab, Uri url) async {
    final String host = BrowserCookieImportGate.normalizeHost(url.host);
    _import?.end();
    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin(host);
    _import = handle;
    _target = tab;
    // 句柄 end() 关闭 deliveries，订阅随之结束，不必另存。
    handle.deliveries.listen(
      (BrowserCookieDelivery delivery) => _onDelivery(handle, delivery),
    );
    _changed.notify();
    try {
      await _openExternal(Uri(scheme: 'https', host: url.host, path: '/'));
    } catch (e) {
      // 打不开浏览器不撤登记：用户可以自己把站点打开，扩展照样会送；状态条可取消。
      ErrorLogService.instance.log('web_browser', 'login import open: $e');
    }
  }

  /// 用户点了状态条上的「取消」：撤销登记，之后扩展的回传被拒（409）。
  void cancel() {
    if (_import == null) return;
    _finish();
  }

  /// [BrowserCookieImportGate.deliver] 同步派发进来：这里在 deliver 返回之前就结束
  /// 登记，同一个 nonce 的下一次回传不会再被收下。
  void _onDelivery(
    BrowserCookieImportRequestHandle handle,
    BrowserCookieDelivery delivery,
  ) {
    if (!identical(_import, handle)) return;
    final String host = handle.request.host;
    final List<BrowserSiteCookie> cookies = browserSiteCookiesForSite(
      delivery.cookies,
      host,
    );
    // 没有本站 cookie 的一批不算导入（多半是别的站的心跳），接着等。
    if (cookies.isEmpty) return;
    final WebBrowserTab? tab = _target;
    _finish();
    unawaited(_apply(tab, cookies));
  }

  void _finish() {
    _import?.end();
    _import = null;
    _target = null;
    _changed.notify();
  }

  Future<void> _apply(
    WebBrowserTab? tab,
    List<BrowserSiteCookie> cookies,
  ) async {
    final int written;
    try {
      written = await (_writeCookiesOverride ?? _writeCookies)(cookies);
    } catch (e) {
      ErrorLogService.instance.log('web_browser', 'login import write: $e');
      _showWriteFailed();
      return;
    }
    if (written == 0) {
      _showWriteFailed();
      return;
    }
    FushiToast.show(
      msg: t.web_browser_login_import_received(count: written),
      severity: ToastSeverity.success,
    );
    await tab?.controller?.reload();
  }

  void _showWriteFailed() => FushiToast.show(
    msg: t.web_browser_login_import_write_failed,
    severity: ToastSeverity.error,
  );

  Future<int> _writeCookies(List<BrowserSiteCookie> cookies) async {
    final CookieManager manager = CookieManager.instance(
      webViewEnvironment: await _environment(),
    );
    return writeBrowserSiteCookies(manager, cookies);
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    // 要重载的标签页没了：登记也没有意义了。
    if (identical(_target, tab)) cancel();
  }

  @override
  void dispose() {
    _import?.end();
    _import = null;
    _target = null;
    _changed.dispose();
  }
}
