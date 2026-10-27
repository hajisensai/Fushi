import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 不算「加载失败」的网络层错误：导航被新导航顶掉 / 用户停止加载（iOS -999、
/// WebView2 `OPERATION_CANCELED`）。把它们当失败页盖上去，点链接时就会闪一下
/// 失败页。
final Set<WebResourceErrorType> _kIgnoredErrorTypes = <WebResourceErrorType>{
  WebResourceErrorType.CANCELLED,
  WebResourceErrorType.USER_CANCELLED_AUTHENTICATION,
};

/// 引擎错误类型 → 类别。三端的原生码由 platform_interface 落成同一个
/// [WebResourceErrorType]（Windows 是 COREWEBVIEW2_WEB_ERROR_STATUS，经
/// `WebResourceErrorType.fromNativeValue` 映射；Android 是 WebViewClient.ERROR_*；
/// iOS / macOS 是 NSURLError*）。不在表里的（含 UNKNOWN）→ generic。
final Map<WebResourceErrorType, WebBrowserLoadErrorKind>
_kKindByType = <WebResourceErrorType, WebBrowserLoadErrorKind>{
  // 断网
  WebResourceErrorType.NOT_CONNECTED_TO_INTERNET:
      WebBrowserLoadErrorKind.offline,
  WebResourceErrorType.NETWORK_CONNECTION_LOST: WebBrowserLoadErrorKind.offline,
  WebResourceErrorType.DATA_NOT_ALLOWED: WebBrowserLoadErrorKind.offline,
  WebResourceErrorType.INTERNATIONAL_ROAMING_OFF:
      WebBrowserLoadErrorKind.offline,
  WebResourceErrorType.CALL_IS_ACTIVE: WebBrowserLoadErrorKind.offline,
  // 域名解析
  WebResourceErrorType.HOST_LOOKUP: WebBrowserLoadErrorKind.dnsFailed,
  // 连不上（WebView2 CANNOT_CONNECT / HOST_NAME_UNREACHABLE /
  // CONNECTION_RESET / CONNECTION_ABORTED；Android ERROR_CONNECT）
  WebResourceErrorType.CANNOT_CONNECT_TO_HOST:
      WebBrowserLoadErrorKind.connectionFailed,
  WebResourceErrorType.SERVER_UNREACHABLE:
      WebBrowserLoadErrorKind.connectionFailed,
  WebResourceErrorType.RESET: WebBrowserLoadErrorKind.connectionFailed,
  WebResourceErrorType.CONNECTION_ABORTED:
      WebBrowserLoadErrorKind.connectionFailed,
  WebResourceErrorType.RESOURCE_UNAVAILABLE:
      WebBrowserLoadErrorKind.connectionFailed,
  // 超时
  WebResourceErrorType.TIMEOUT: WebBrowserLoadErrorKind.timedOut,
  // 证书 / TLS（Android / iOS 的类型；WebView2 的 1–5 号证书状态在平台接口里
  // 没有对应枚举，靠下面描述文本里的 "SSL certificate" 归类）
  WebResourceErrorType.FAILED_SSL_HANDSHAKE:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.SECURE_CONNECTION_FAILED:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.SERVER_CERTIFICATE_HAS_BAD_DATE:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.SERVER_CERTIFICATE_HAS_UNKNOWN_ROOT:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.SERVER_CERTIFICATE_NOT_YET_VALID:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.CLIENT_CERTIFICATE_REJECTED:
      WebBrowserLoadErrorKind.certificate,
  WebResourceErrorType.CLIENT_CERTIFICATE_REQUIRED:
      WebBrowserLoadErrorKind.certificate,
  // 响应坏了
  WebResourceErrorType.BAD_SERVER_RESPONSE: WebBrowserLoadErrorKind.badResponse,
  WebResourceErrorType.CANNOT_PARSE_RESPONSE:
      WebBrowserLoadErrorKind.badResponse,
  WebResourceErrorType.CANNOT_DECODE_CONTENT_DATA:
      WebBrowserLoadErrorKind.badResponse,
  WebResourceErrorType.CANNOT_DECODE_RAW_DATA:
      WebBrowserLoadErrorKind.badResponse,
  WebResourceErrorType.ZERO_BYTE_RESOURCE: WebBrowserLoadErrorKind.badResponse,
  // 重定向
  WebResourceErrorType.TOO_MANY_REDIRECTS:
      WebBrowserLoadErrorKind.tooManyRedirects,
  WebResourceErrorType.REDIRECT_FAILED:
      WebBrowserLoadErrorKind.tooManyRedirects,
  WebResourceErrorType.REDIRECT_TO_NON_EXISTENT_LOCATION:
      WebBrowserLoadErrorKind.tooManyRedirects,
};

/// 按描述细分：Android 描述是 Chromium 的 `net::ERR_*`，比 WebViewClient 的
/// ERROR_* 细（断网在 Android 上报成 HOST_LOOKUP、只有描述能分出来）；WebView2 的
/// 描述是 fork 按 COREWEBVIEW2_WEB_ERROR_STATUS 查表的固定英文句子
/// （`web_resource_error.h` 的 `WebErrorStatusDescription`）。按顺序取第一个命中。
final List<(RegExp, WebBrowserLoadErrorKind)>
_kKindByDescription = <(RegExp, WebBrowserLoadErrorKind)>[
  (
    RegExp(
      r'ERR_INTERNET_DISCONNECTED|ERR_NETWORK_CHANGED|'
      r'internet connection has been lost|appears to be offline',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.offline,
  ),
  (
    RegExp(
      r'ERR_NAME_NOT_RESOLVED|ERR_NAME_RESOLUTION_FAILED|'
      r'host name was not able to be resolved|'
      r'server with the specified hostname could not be found',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.dnsFailed,
  ),
  (
    RegExp(
      r'ERR_CONNECTION_TIMED_OUT|ERR_TIMED_OUT|timed out',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.timedOut,
  ),
  (
    RegExp(
      r'ERR_CERT_|ERR_SSL_|ERR_BAD_SSL|SSL certificate|SSL client certificate',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.certificate,
  ),
  (
    RegExp(
      r'ERR_CONNECTION_REFUSED|ERR_CONNECTION_RESET|ERR_CONNECTION_CLOSED|'
      r'ERR_CONNECTION_FAILED|ERR_CONNECTION_ABORTED|ERR_ADDRESS_UNREACHABLE|'
      r'host is unreachable|connection was reset|connection was stopped|'
      r'connection to the destination was not established|'
      r'could not connect to the server',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.connectionFailed,
  ),
  (
    RegExp(
      r'ERR_EMPTY_RESPONSE|ERR_INVALID_RESPONSE|'
      r'ERR_CONTENT_DECODING_FAILED|invalid or unrecognized response',
      caseSensitive: false,
    ),
    WebBrowserLoadErrorKind.badResponse,
  ),
  (
    RegExp(r'ERR_TOO_MANY_REDIRECTS|redirect failed', caseSensitive: false),
    WebBrowserLoadErrorKind.tooManyRedirects,
  ),
];

/// 引擎错误 → 类别：先按描述（更细），再按类型，都不中 → generic。
WebBrowserLoadErrorKind webBrowserLoadErrorKindOf({
  required WebResourceErrorType type,
  required String description,
}) {
  for (final (RegExp pattern, WebBrowserLoadErrorKind kind)
      in _kKindByDescription) {
    if (pattern.hasMatch(description)) return kind;
  }
  return _kKindByType[type] ?? WebBrowserLoadErrorKind.generic;
}

/// WebView2 的错误码经 fork 只落成英文描述（`WebErrorStatusDescription`），类型
/// 常是 UNKNOWN：取消类再按描述兜一层。
final RegExp _kCancelledDescription = RegExp(
  r'operation was canceled|operation was cancelled|NSURLErrorCancelled|'
  r'ERR_ABORTED|frame load interrupted',
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
    kind: webBrowserLoadErrorKindOf(type: type, description: description),
  );
}

/// 本标签页最近开始的主框架导航（按开始顺序），用来认出「已被后来导航顶掉」的
/// 那次导航迟到的错误。
///
/// 页面自己改址（YouTube 首开会 `location.replace` 加 `&themeRefresh=1`）时，
/// WebView2 把被顶掉的首个导航报成 `CONNECTION_ABORTED`（「connection was
/// stopped」），而且报在新导航开始之后——新导航的 loadStart 已经清过失败页，这条
/// 迟到的错误再盖上去，失败页就压在已加载好的新文档上、吞掉所有点击（BUG-3856）。
/// 取消类判据认不出它（描述与真断连同一句），只能按「是不是当前这次导航」判。
class WebBrowserNavigationLog {
  static const int _capacity = 8;
  final List<String> _started = <String>[];

  static String _key(Uri url) => url.removeFragment().toString();

  /// 主框架开始导航（`onLoadStart`）。
  void onStart(Uri? url) {
    if (url == null) return;
    _started.add(_key(url));
    if (_started.length > _capacity) _started.removeAt(0);
  }

  /// [url] 的错误是否属于已被后来导航顶掉的那次：它开始过、但不是最近一次。没记
  /// 录过的地址（如重定向后的地址，部分平台不为重定向报 loadStart）不算过期。
  bool isSuperseded(Uri url) {
    if (_started.isEmpty) return false;
    final String key = _key(url);
    return _started.last != key && _started.contains(key);
  }
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
