import 'package:flutter/foundation.dart';

/// 某平台的 InAppWebView 能怎么做网络层拦截（cosmetic 隐藏五端都走 documentStart 的
/// UserScript + JS handler，不在这里区分）。
///
/// 判据来自本仓实际使用的各平台实现（2026-10 调查，flutter_inappwebview 6.1.5 家族）：
///
/// | 平台 | 逐请求拦截 | contentBlockers | 取用模式 |
/// |---|---|---|---|
/// | Android（vendored `third_party/flutter_inappwebview_android` 1.1.3） | `shouldInterceptRequest` 有效：WebView IO 线程**同步阻塞**等 Dart 主 isolate 回包（`Util.invokeMethodAndWaitResult`） | 有，但实现是 Java 里逐条正则 `matches()`——十几万条规则逐请求全扫不可用；且开了 `useShouldInterceptRequest` 后 contentBlockers 分支根本不执行（`InAppWebViewClient.java` 先 return） | [WebAdblockNetworkMode.perRequest] |
/// | Windows（fork `packages/flutter_inappwebview_windows` 0.6.0） | `shouldInterceptRequest` 有效：WebView2 `WebResourceRequested`（filter `*` / context ALL），deferral 异步回包，不卡 UI | **无**：原生侧没有任何 contentBlockers 代码，设置被静默忽略 | [WebAdblockNetworkMode.perRequest] |
/// | Linux（vendored `packages/flutter_inappwebview_linux`，WPE WebKit） | **无**：设置项会解析，但原生从不调用 `shouldInterceptRequest` | 原生有（编译成 `WebKitUserContentFilter`），但 **Dart 侧够不着**：共用的 platform_interface 1.3.0 里 `ContentBlockerActionType` 的原生值只为 Android / iOS / macOS 生成，Linux 上一取 `BLOCK` 就抛 TypeError（原生值为 null），规则根本序列化不出去 | [WebAdblockNetworkMode.cosmeticOnly] |
/// | iOS / macOS（hosted `_ios` / `_macos` 1.1.2，WKWebView） | **无**：只有自定义 scheme 的 `WKURLSchemeHandler` | 有：`WKContentRuleListStore.compileContentRuleList` | [WebAdblockNetworkMode.contentBlockers] |
///
/// `shouldInterceptAjaxRequest` / `shouldInterceptFetchRequest` 是 JS 注入实现、只拦 XHR /
/// fetch，拦不到 img / script / css，不作为网络层拦截手段。
enum WebAdblockNetworkMode {
  /// 每个子资源请求都过 adblock 引擎（`shouldInterceptRequest`）。
  perRequest,

  /// 不能逐请求：把列表导出成 WebKit 内容拦截规则交给 `contentBlockers`（有条数上限，
  /// 见 `kWebAdblockMaxContentBlockers`）。
  contentBlockers,

  /// 网络层什么也做不了，只做 cosmetic 隐藏。
  cosmeticOnly,
}

/// [platform] 上的网络层拦截模式。Android / Windows 走逐请求，iOS / macOS 走 contentBlockers，
/// Linux（见上表：插件 Dart 层的枚举没有 Linux 原生值）与不出包的平台只做 cosmetic。
/// 要让 Linux 也有网络层拦截，得给 platform_interface 的 `ContentBlockerActionType` 补 Linux
/// 原生值（vendored 补丁），或在 `packages/flutter_inappwebview_linux` 接上 `resource-load-started`。
WebAdblockNetworkMode webAdblockNetworkModeFor(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.windows:
      return WebAdblockNetworkMode.perRequest;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return WebAdblockNetworkMode.contentBlockers;
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return WebAdblockNetworkMode.cosmeticOnly;
  }
}

/// 当前运行平台的网络层拦截模式（Web 构建不出包，按 cosmetic 处理）。
WebAdblockNetworkMode get currentWebAdblockNetworkMode => kIsWeb
    ? WebAdblockNetworkMode.cosmeticOnly
    : webAdblockNetworkModeFor(defaultTargetPlatform);
