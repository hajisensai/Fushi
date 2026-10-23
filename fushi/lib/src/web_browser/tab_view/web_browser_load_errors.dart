import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 不算「加载失败」的网络层错误：导航被新导航顶掉 / 用户停止加载（iOS -999、
/// WebView2 `OPERATION_CANCELED`）。把它们当失败页盖上去，点链接时就会闪一下
/// 失败页。
final Set<WebResourceErrorType> _kIgnoredErrorTypes = <WebResourceErrorType>{
  WebResourceErrorType.CANCELLED,
  WebResourceErrorType.USER_CANCELLED_AUTHENTICATION,
};

/// 断网类：失败页换「检查网络连接」文案。
final Set<WebResourceErrorType> _kOfflineErrorTypes = <WebResourceErrorType>{
  WebResourceErrorType.NOT_CONNECTED_TO_INTERNET,
  WebResourceErrorType.NETWORK_CONNECTION_LOST,
  WebResourceErrorType.HOST_LOOKUP,
  WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
  WebResourceErrorType.TIMEOUT,
  WebResourceErrorType.DATA_NOT_ALLOWED,
  WebResourceErrorType.INTERNATIONAL_ROAMING_OFF,
  WebResourceErrorType.SERVER_UNREACHABLE,
};

/// WebView2 的错误码经 fork 只落成英文描述（`WebErrorStatusDescription`），类型
/// 常是 UNKNOWN：再按描述兜一层，与上面两张表同义。
final RegExp _kCancelledDescription = RegExp(
  r'operation was canceled|operation was cancelled|NSURLErrorCancelled|'
  r'ERR_ABORTED|frame load interrupted',
  caseSensitive: false,
);
final RegExp _kOfflineDescription = RegExp(
  r'internet connection has been lost|host name was not able to be resolved|'
  r'host is unreachable|connection has timed out|'
  r'connection to the destination was not established|'
  r'ERR_INTERNET_DISCONNECTED|ERR_NAME_NOT_RESOLVED|ERR_NAME_RESOLUTION_FAILED|'
  r'ERR_CONNECTION_TIMED_OUT|ERR_ADDRESS_UNREACHABLE|ERR_NETWORK_CHANGED|'
  r'offline',
  caseSensitive: false,
);

/// 主框架网络层错误 → 加载失败描述；null = 不显示失败页（导航被取消 / 不是主
/// 框架 / 不是网页地址）。
WebBrowserLoadError? classifyWebBrowserMainFrameError({
  required Uri? url,
  required bool isForMainFrame,
  required WebResourceErrorType type,
  required String description,
}) {
  if (!isForMainFrame || url == null) return null;
  if (!isWebBrowserNavigableUrl(url)) return null;
  if (_kIgnoredErrorTypes.contains(type)) return null;
  if (_kCancelledDescription.hasMatch(description)) return null;
  return WebBrowserLoadError(
    url: url,
    description: description,
    offline:
        _kOfflineErrorTypes.contains(type) ||
        _kOfflineDescription.hasMatch(description),
  );
}

/// 主框架 HTTP 错误码是否**可能**要显示失败页。
///
/// 只是候选：网站自己的 404 / 500 页、Cloudflare 的 403 / 503 验证页都有正文，
/// 盖上失败页会把它们挡住（Cloudflare 验证就过不去了）。真正盖不盖由
/// [shouldShowWebBrowserHttpError] 在加载结束后按页面是否空白决定——与 Chrome
/// 「响应体为空才换成自己的 HTTP ERROR 页」同一口径。
bool isWebBrowserHttpErrorCandidate({
  required bool isForMainFrame,
  required int? statusCode,
}) => isForMainFrame && statusCode != null && statusCode >= 400;

/// 加载结束后：候选 HTTP 错误且页面正文为空 → 显示失败页。
bool shouldShowWebBrowserHttpError({
  required int? pendingStatusCode,
  required int visibleTextLength,
  required int mediaElementCount,
}) =>
    pendingStatusCode != null &&
    visibleTextLength == 0 &&
    mediaElementCount == 0;

/// 取页面「有没有东西」的探针：可见文字长度与图片 / 视频 / iframe 数。
///
/// 空响应体的 HTTP 错误在 Chromium 系引擎（WebView2）里会被换成引擎自带的
/// 「HTTP ERROR 404」页（`chrome-error://` 文档，带 Edge 品牌与正文），按正文判
/// 就永远不是空白、我们的失败页永远盖不上去：这种文档按空白报。
const String kWebBrowserBlankPageProbeScript = '''
(function(){
  if (location.protocol === 'chrome-error:') return JSON.stringify({text: 0, media: 0});
  var b = document.body;
  if (!b) return JSON.stringify({text: 0, media: 0});
  var text = (b.innerText || '').trim().length;
  var media = document.querySelectorAll('img,video,iframe,canvas,svg,embed,object').length;
  return JSON.stringify({text: text, media: media});
})();
''';

/// 能显示 / 记历史的网页地址（http / https）。about:blank、data:、chrome-error
/// 之类一律不算。
bool isWebBrowserNavigableUrl(Uri? url) =>
    url != null &&
    (url.scheme == 'http' || url.scheme == 'https') &&
    url.host.isNotEmpty;
