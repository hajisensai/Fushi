import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_incognito_profile.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 壳菜单里对「当前标签页」的动作（壳放进「⋯」/ 工具栏，这里只给实现）。

/// 本平台的无痕标签页能不能做到真正隔离（独立 Cookie / 存储，关掉即清）。
///
/// - iOS / macOS：非持久 `WKWebsiteDataStore`（插件 `incognito: true`）；
/// - Windows：WebView2 InPrivate 配置（插件 `incognito: true` →
///   `IsInPrivateModeEnabled`），同一环境下所有 InPrivate 视图共用一份、最后一个
///   关掉即清；
/// - Linux：WPE 的临时网络会话（`webkit_network_session_new_ephemeral`）；
/// - Android：系统 WebView 的具名 Profile（androidx.webkit `MULTI_PROFILE`，见
///   [WebBrowserIncognitoProfiles]）。**不用**插件的 `incognito`——它只是把**全局**
///   CookieManager 清空，既不隔离还会清掉普通标签页 / 漫画源的登录态。系统
///   WebView 不支持多 Profile（[androidMultiProfile] 为 false，含还没探测完）时不提供
///   无痕入口。
bool webBrowserIncognitoSupportedOn(
  TargetPlatform platform, {
  bool androidMultiProfile = false,
}) => switch (platform) {
  TargetPlatform.android => androidMultiProfile,
  TargetPlatform.fuchsia => false,
  _ => true,
};

/// 同步问「现在能不能开无痕」。Android 的探测是异步的：第一次调用顺带发起探测，
/// 探测完之前答 false（浏览页的标签控制器建时就发起探测、支持时通知重建）。
bool webBrowserIncognitoSupported() {
  final WebBrowserIncognitoProfiles profiles =
      WebBrowserIncognitoProfiles.instance;
  if (profiles.needsNamedProfile && profiles.multiProfileSupported == null) {
    unawaited(profiles.ensureProbed());
  }
  return webBrowserIncognitoSupportedOn(
    defaultTargetPlatform,
    androidMultiProfile: profiles.multiProfileSupported ?? false,
  );
}

/// 分享当前页地址（系统分享面板；标题作 subject）。
Future<bool> shareTabUrl(WebBrowserTab tab) async {
  final Uri? url = tab.url;
  if (url == null) return false;
  return FushiShare.shareText(url.toString(), subject: tab.displayTitle);
}

/// 复制当前页地址并提示。
Future<void> copyTabUrl(WebBrowserTab tab) async {
  final Uri? url = tab.url;
  if (url == null) return;
  await copyWebBrowserText(url.toString());
}

Future<void> copyWebBrowserText(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  FushiToast.show(msg: t.copied_to_clipboard, severity: ToastSeverity.success);
}

/// 在系统浏览器 / 对应 app 里打开当前页。
Future<bool> openTabInSystemBrowser(WebBrowserTab tab) async {
  final Uri? url = tab.url;
  if (url == null) return false;
  return openWebBrowserUrlExternally(url);
}

Future<bool> openWebBrowserUrlExternally(Uri url) async {
  bool ok = false;
  try {
    ok = await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('WebBrowser.openExternally', error, stack);
  }
  if (!ok) {
    FushiToast.show(
      msg: t.web_browser_open_external_failed,
      severity: ToastSeverity.error,
    );
  }
  return ok;
}

/// 加载失败页的「重试」（壳接到 `WebBrowserErrorView.onRetry`）：清掉失败、重新
/// 加载失败的那个地址。
void retryTabLoad(WebBrowserTab tab) {
  final WebBrowserLoadError? error = tab.error;
  final InAppWebViewController? controller = tab.controller;
  tab.setError(null);
  if (controller == null) return;
  final Uri? url = error?.url ?? tab.url;
  unawaited(
    url == null
        ? controller.reload()
        : controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url))),
  );
}

/// 退出网页全屏（壳的返回键 / 退出全屏按钮）。
Future<void> exitTabFullscreen(WebBrowserTab tab) async {
  final InAppWebViewController? controller = tab.controller;
  if (controller == null) return;
  try {
    await controller.evaluateJavascript(
      source: kWebBrowserExitFullscreenScript,
    );
  } on Object {
    // 视图正在销毁：壳那边照常恢复 chrome。
  }
  tab.update(fullscreen: false);
}
