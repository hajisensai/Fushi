import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// app 内浏览器的一次子资源 / 导航请求（交给 [WebBrowserRequestFilter] 判定）。
@immutable
class WebBrowserRequest {
  const WebBrowserRequest({
    required this.url,
    required this.pageUrl,
    required this.isMainFrame,
  });

  /// 被请求的地址。
  final Uri url;

  /// 发起请求时浏览器所在的页面（第三方判定用）；未知为 null。
  final Uri? pageUrl;

  /// 是否是顶层文档导航（过滤器通常不该拦它，拦了用户只会看到空白页）。
  final bool isMainFrame;
}

/// app 内浏览器的请求过滤器（广告拦截等）。
///
/// 两条腿，因为平台能力不同：
/// - [shouldBlock]：逐请求判定，接在 `shouldInterceptRequest` 上（Android /
///   Windows 有这条回调）。返回 true = 拦掉（浏览器收到一个空的 204）。
/// - [contentBlockers]：声明式规则，接在 `InAppWebViewSettings.contentBlockers`
///   上（iOS / macOS 的 WKContentRuleList 只认这种）。不支持时返回空表。
///
/// 实现方（例如另一分支的 Rust adblock 引擎）只需实现这个接口并赋给
/// [webBrowserRequestFilter]；浏览器页每次建 WebView 时读一次装配点。
abstract interface class WebBrowserRequestFilter {
  bool shouldBlock(WebBrowserRequest request);

  List<ContentBlocker> contentBlockers();
}

/// 全局装配点：null（默认）= 不拦截任何请求，浏览器也不开 `shouldInterceptRequest`
/// （Windows 上那条回调要给每个请求绕一圈宿主，没有过滤器时白白拖慢加载）。
WebBrowserRequestFilter? webBrowserRequestFilter;
