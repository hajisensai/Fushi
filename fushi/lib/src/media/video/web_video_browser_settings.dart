// 网页播放器（原生视频页的网页档，[WebVideoSession]）与 app 内浏览器共享的站点设置。
//
// 单一真相源：读浏览器同一份偏好（[web_browser_prefs]）/ 网站设置（[WebBrowserSiteSettings]）/
// 广告拦截服务（[WebAdblockPolicy]），应用代码也是浏览器那份（[applyAdblockTo]、
// [webBrowserPageStyleScript]、[resolveWebBrowserPermissionRequest]），这里只做两件事：
// · 决定哪些浏览器设置在播放器页上有意义、怎么落（盘点见各函数注释）；
// · 播放器必需项压在共享设置之上（[enforceWebVideoRequiredSettings]）——两者冲突时以播放器为准。
//
// 不接的浏览器设置与原因：
// · 标签页样式 / 滚动收起 / 恢复标签页 / 搜索引擎：浏览器壳自己的 UI 行为，播放器页没有标签页；
// · 默认桌面版 / 标签页文字大小：桌面版只对手机 WebView 有意义（[webBrowserDesktopModeSupportedOn]），
//   本页只在 Windows（WebView2 窗口宿主档）跑，本来就是桌面 UA；文字大小是标签页级状态不是偏好；
// · 扩展（查词 / 字幕 / 字幕样式 / 外观 / 快捷键 / 学习）：浏览器的扩展宿主在页内画自己的字幕层与
//   查词，播放器页的字幕叠层 / 查词 / 快捷键是原生的，两套叠上去会重复显示、抢按键；
// · 弹窗（网站设置 `popups`）：Windows fork 的 `NewWindowRequested`（`in_app_webview.cpp`）里
//   「不接管」= 在当前视图打开，没有「丢弃」分支（接管又不建窗口会挂住 deferral）；浏览器在
//   Windows 上「阻止」的实际效果同样是本页打开，本页的默认行为已与之一致，不另接。
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

/// 播放器页 WebView 的必需设置（任何共享设置都不能改掉）：
/// · `javaScriptEnabled`：glue / 站点 bridge / 键盘桥全靠页内 JS；
/// · `mediaPlaybackRequiresUserGesture: false`：播放由原生控件经 glue 发 `play()`，不是页内手势；
/// · `disableContextMenu` / `supportZoom: false` / `sharedCookiesEnabled`：本页接入共享设置前
///   就有的宿主设置（不弹 WebView2 右键菜单、站点页面不缩放、cookie 走环境共享罐——登录 cookie
///   由会话从内置档 / 浏览器抄进本环境），原样保留。
void enforceWebVideoRequiredSettings(InAppWebViewSettings settings) {
  settings
    ..javaScriptEnabled = true
    ..mediaPlaybackRequiresUserGesture = false
    ..disableContextMenu = true
    ..supportZoom = false
    ..sharedCookiesEnabled = true;
}

/// 播放器页 WebView 的设置 + 浏览器的广告拦截接线（[applyAdblockTo]，与浏览器标签页同一个
/// 服务、同一份开关 / 订阅 / 白名单，逐请求平台每次现问，用户中途改设置下一个请求就生效）。
///
/// 广告拦截不另设视频站白名单：白名单只有浏览器「网页广告拦截」里用户填的那一份（Rust 按顶层
/// 页面判），YouTube / Netflix 在浏览器标签页里本来就过同一个引擎；顶层导航不拦（见
/// [WebAdblockWiring.interceptForAdblock]），站点误伤时用户在同一处加白名单，两边一起生效。
/// 必需项最后再压一次：拦截接线只加 `useShouldInterceptRequest` / `contentBlockers`，但这里
/// 不依赖它的实现细节。
WebAdblockWiring webVideoSurfaceWiring({
  required WebAdblockPolicy policy,
  WebAdblockNetworkMode? mode,
}) {
  final InAppWebViewSettings base = InAppWebViewSettings();
  enforceWebVideoRequiredSettings(base);
  final WebAdblockWiring wiring = applyAdblockTo(
    base,
    policy: policy,
    mode: mode,
  );
  enforceWebVideoRequiredSettings(wiring.settings);
  return wiring;
}

/// 网页深色在播放器页上是否生效：只在网页档（登录 / 选集 / 详情页）跟随浏览器的「网页深色」；
/// 播放器档（页面只留画面）一律关——反色滤镜挂在 `<html>` 上，受保护视频（硬件 PlayReady）
/// 被套滤镜可能退出 overlay 变黑，且画面周围本来就只有黑底，深色化没有意义。
bool webVideoPageForceDark({
  required bool browserForceDark,
  required bool playerMode,
}) => browserForceDark && !playerMode;

/// 播放器页读到的浏览器「网页深色」偏好（读失败按关，与浏览器标签页同口径）。
bool webVideoBrowserForceDark(PrefStore prefs) {
  try {
    return webBrowserForceDark(prefs);
  } on Object {
    return false;
  }
}

/// 播放器页的页内样式脚本：浏览器同一段（[webBrowserPageStyleScript]），文字大小固定 100%
/// （标签页级状态，播放器页没有），深色按 [webVideoPageForceDark]。
String webVideoPageStyleScript({
  required TargetPlatform platform,
  required bool browserForceDark,
  required bool playerMode,
}) => webBrowserPageStyleScript(
  platform: platform,
  textZoom: 100,
  forceDark: webVideoPageForceDark(
    browserForceDark: browserForceDark,
    playerMode: playerMode,
  ),
);
