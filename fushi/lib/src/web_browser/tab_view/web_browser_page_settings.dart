import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 标签页 WebView 的平台相关设置：桌面版网页、文字大小、网页深色模式。
///
/// 判据只按「平台 WebView 有没有这项原生能力」分，纯函数 + 显式传入平台，测试不随
/// 宿主漂移。

/// 「桌面版网页」只对手机 WebView 有意义：桌面平台本来就是桌面 UA + 宽视口。
bool webBrowserDesktopModeSupportedOn(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

bool webBrowserDesktopModeSupported() =>
    webBrowserDesktopModeSupportedOn(defaultTargetPlatform);

/// 兜底桌面 UA（拿不到系统默认 UA 时用）。
const String kWebBrowserFallbackDesktopUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/// 把 Android 系统 WebView 的默认 UA 改写成同版本 Chrome 的桌面 UA：平台段换成
/// `X11; Linux x86_64`，去掉 `; wv`、`Version/x.y` 与 `Mobile`。保留引擎版本号，
/// 比写死一个版本号更不容易被站点当成过时浏览器。
String webBrowserDesktopUserAgentFrom(String? mobileUserAgent) {
  final String ua = mobileUserAgent?.trim() ?? '';
  final RegExpMatch? chrome = RegExp(r'Chrome/[\d.]+').firstMatch(ua);
  if (chrome == null) return kWebBrowserFallbackDesktopUserAgent;
  return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) ${chrome.group(0)} Safari/537.36';
}

/// 本标签页应设的 UA；null = 不设（平台默认）。只有 Android 换 UA（iOS 走
/// `preferredContentMode`，WebKit 自己换成 macOS Safari 的 UA 与宽视口）。
///
/// Android 关掉桌面版时要显式写回系统默认 UA：插件的 `setSettings` 遇到空串
/// 不会把 UA 恢复（`InAppWebView.java` 只在非空时 `setUserAgentString`）。
String? webBrowserUserAgentFor({
  required TargetPlatform platform,
  required bool desktopMode,
  required String? defaultUserAgent,
}) {
  if (platform != TargetPlatform.android) return null;
  if (!desktopMode) {
    final String ua = defaultUserAgent?.trim() ?? '';
    return ua.isEmpty ? null : ua;
  }
  return webBrowserDesktopUserAgentFrom(defaultUserAgent);
}

/// 文字大小走哪条路。
enum WebBrowserTextZoomMode {
  /// Android 原生 `textZoom`（只放大文字，排版重排）。
  nativeTextZoom,

  /// iOS：`-webkit-text-size-adjust`（WebKit 移动版认它）。
  textSizeAdjust,

  /// 桌面：CSS `zoom` 整页缩放（桌面 Blink / WebKit 不认 text-size-adjust）。
  cssZoom,
}

WebBrowserTextZoomMode webBrowserTextZoomModeOn(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.android => WebBrowserTextZoomMode.nativeTextZoom,
      TargetPlatform.iOS => WebBrowserTextZoomMode.textSizeAdjust,
      _ => WebBrowserTextZoomMode.cssZoom,
    };

const String _kTextZoomStyleId = 'fushi-browser-text-zoom';

/// 应用 / 撤销文字大小的页内脚本（幂等，按 style id 覆盖）。原生 textZoom 平台
/// 返回 null。
String? webBrowserTextZoomScript(int percent, WebBrowserTextZoomMode mode) {
  final String css = switch (mode) {
    WebBrowserTextZoomMode.nativeTextZoom => '',
    WebBrowserTextZoomMode.textSizeAdjust =>
      percent == 100
          ? ''
          : 'html{-webkit-text-size-adjust:$percent% !important;'
                'text-size-adjust:$percent% !important;}',
    WebBrowserTextZoomMode.cssZoom =>
      percent == 100 ? '' : 'html{zoom:$percent% !important;}',
  };
  if (mode == WebBrowserTextZoomMode.nativeTextZoom) return null;
  return _styleScript(_kTextZoomStyleId, css);
}

/// 网页深色模式在本平台是否走原生实现。目前**五端都不走**，统一注入
/// [webBrowserForceDarkScript] 的保守反色：
///
/// Android 的原生路子在本 app 上不成立——`targetSdk 35` 下 `forceDark` 已被系统
/// 忽略，`algorithmicDarkeningAllowed` 只在宿主 Activity 主题是深色
/// （`isLightTheme=false`）时才生效，app 浅色主题下用户打开开关会毫无反应；而它一旦
/// 生效又不改计算样式，页内反色脚本判不出页面已变暗，会叠成二次反色。
bool webBrowserForceDarkNativeOn(TargetPlatform platform) => false;

const String _kForceDarkStyleId = 'fushi-browser-force-dark';

/// 保守反色：只在页面自己是浅底时才反（页面已是深色 / 声明了 dark color-scheme 的
/// 不动），图片 / 视频 / canvas / iframe 反两次还原。
String webBrowserForceDarkScript({required bool enabled}) {
  if (!enabled) return _styleScript(_kForceDarkStyleId, '');
  const String css =
      'html{filter:invert(1) hue-rotate(180deg) !important;'
      'background:#fff !important;}'
      'img,picture,video,canvas,iframe,svg image,embed,object,'
      '[style*="background-image"]{filter:invert(1) hue-rotate(180deg) !important;}';
  return '''
(function(){
  function lum(c){
    var m = /rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?/.exec(c || '');
    if (!m) return null;
    if (m[4] !== undefined && parseFloat(m[4]) < 0.1) return null;
    return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255;
  }
  function pageIsDark(){
    try {
      var meta = document.querySelector('meta[name="color-scheme"]');
      var cs = getComputedStyle(document.documentElement).colorScheme || '';
      if (/dark/.test(cs) && !/light/.test(cs)) return true;
      if (meta && /^\\s*dark\\s*\$/.test(meta.content || '')) return true;
      var l = lum(getComputedStyle(document.body || document.documentElement).backgroundColor);
      if (l === null) l = lum(getComputedStyle(document.documentElement).backgroundColor);
      return l !== null && l < 0.4;
    } catch (e) { return false; }
  }
  var id = '$_kForceDarkStyleId';
  var old = document.getElementById(id);
  if (old) old.remove();
  if (pageIsDark()) return;
  ${_styleScript(_kForceDarkStyleId, css)}
})();
''';
}

String _styleScript(String id, String css) =>
    '''
(function(){
  var id = ${jsonEncode(id)};
  var css = ${jsonEncode(css)};
  var el = document.getElementById(id);
  if (!css) { if (el) el.remove(); return; }
  if (!el) {
    el = document.createElement('style');
    el.id = id;
    (document.head || document.documentElement).appendChild(el);
  }
  el.textContent = css;
})();
''';

/// 页内样式（文字大小 + 网页深色）user script 的分组名：换设置时按组整体替换。
const String kWebBrowserPageStyleScriptGroup = 'fushi-browser-page-style';

/// 文字大小（非原生平台）+ 网页深色（非原生平台）的页内脚本，幂等（按 style id 覆盖 /
/// 撤销）。浏览器标签页与网页播放器的网页档共用这一份（同一个偏好在两边得到同一段脚本）。
String webBrowserPageStyleScript({
  required TargetPlatform platform,
  required int textZoom,
  required bool forceDark,
}) {
  final StringBuffer out = StringBuffer();
  final String? zoom = webBrowserTextZoomScript(
    textZoom,
    webBrowserTextZoomModeOn(platform),
  );
  if (zoom != null) out.writeln(zoom);
  if (!webBrowserForceDarkNativeOn(platform)) {
    out.writeln(webBrowserForceDarkScript(enabled: forceDark));
  }
  return out.toString();
}

/// [webBrowserPageStyleScript] 包成每个文档 DOMContentLoaded 时注入的 user script。
UserScript webBrowserPageStyleUserScript({
  required TargetPlatform platform,
  required int textZoom,
  required bool forceDark,
}) => UserScript(
  groupName: kWebBrowserPageStyleScriptGroup,
  source: webBrowserPageStyleScript(
    platform: platform,
    textZoom: textZoom,
    forceDark: forceDark,
  ),
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
);

/// 运行中改了样式设置：换掉以后每个文档的 user script，并对当前文档立即生效。
Future<void> applyWebBrowserPageStyle(
  InAppWebViewController controller, {
  required TargetPlatform platform,
  required int textZoom,
  required bool forceDark,
}) async {
  await controller.removeUserScriptsByGroupName(
    groupName: kWebBrowserPageStyleScriptGroup,
  );
  await controller.addUserScript(
    userScript: webBrowserPageStyleUserScript(
      platform: platform,
      textZoom: textZoom,
      forceDark: forceDark,
    ),
  );
  await controller.evaluateJavascript(
    source: webBrowserPageStyleScript(
      platform: platform,
      textZoom: textZoom,
      forceDark: forceDark,
    ),
  );
}

/// 把桌面版 / 文字大小 / 深色模式落到一份 [InAppWebViewSettings] 上（建 WebView
/// 与运行中 `setSettings` 共用）。
void applyWebBrowserPageSettings(
  InAppWebViewSettings settings, {
  required TargetPlatform platform,
  required bool desktopMode,
  required int textZoom,
  required bool forceDark,
  required String? defaultUserAgent,
}) {
  final String? userAgent = webBrowserUserAgentFor(
    platform: platform,
    desktopMode: desktopMode,
    defaultUserAgent: defaultUserAgent,
  );
  if (userAgent != null) settings.userAgent = userAgent;
  if (platform == TargetPlatform.android) {
    settings.useWideViewPort = true;
    settings.loadWithOverviewMode = desktopMode;
    settings.textZoom = textZoom;
  }
  if (platform == TargetPlatform.iOS) {
    settings.preferredContentMode = desktopMode
        ? UserPreferredContentMode.DESKTOP
        : UserPreferredContentMode.RECOMMENDED;
  }
}

/// 退出网页全屏后把页面缩放还原成进全屏前的样子（Android）。
///
/// 现象：允许缩放（没有 `user-scalable=no`）的网页退出 HTML5 全屏后，页面缩到约
/// 0.76、视口读成 541x1050；YouTube（`user-scalable=no`）不出现。原因：Android
/// WebView 进全屏时把内容挪进系统给的全屏 custom view（尺寸 / 方向都跟着变），
/// Blink 按全屏视口重算缩放约束；`loadWithOverviewMode`（插件默认开）下，退出时
/// 视口先回到窗口尺寸、内容宽度还停在全屏布局上，「缩小到能放下内容」把页面缩放
/// 压到最小；内容随后缩回原宽，但 Blink 把这次缩放当作用户可调的当前缩放保留，
/// 不会自己再放大。禁止缩放的页面最小 = 最大缩放，压不下去，所以不受影响。
///
/// 修法：记下全屏前最后一次缩放；退出全屏后（以及之后引擎还在调整缩放的这段时间）
/// 发现缩放偏离就 `zoomBy(全屏前 / 当前)` 拉回。用户一碰网页（可能是自己捏合
/// 缩放）或开始新导航即停手，不和用户抢缩放。缩放值只取比值，单位（含不含屏幕
/// 密度）抵消，`onZoomScaleChanged` 的原始值可以直接用。
class WebBrowserFullscreenZoomGuard {
  /// 相对偏差小于这个值不算偏离（浮点 / 引擎取整的抖动）。
  static const double tolerance = 0.01;

  double? _scale;
  double? _scaleBeforeFullscreen;
  bool _fullscreen = false;
  bool _restoring = false;

  /// 当前是否在等待还原（测试用）。
  bool get restoring => _restoring;

  /// 引擎报告了新缩放；返回需要 `zoomBy` 的倍数，null = 不动。
  double? onScaleChanged(double newScale) {
    if (!newScale.isFinite || newScale <= 0) return null;
    _scale = newScale;
    if (_fullscreen || !_restoring) return null;
    return _correction();
  }

  /// 进入网页全屏：冻结全屏前的缩放。
  void onEnterFullscreen() {
    if (_fullscreen) return;
    _fullscreen = true;
    _restoring = false;
    _scaleBeforeFullscreen = _scale;
  }

  /// 退出网页全屏：开始还原；返回立即需要 `zoomBy` 的倍数（全屏期间缩放已被
  /// 压下、退出时不再有新事件的情况）。
  double? onExitFullscreen() {
    if (!_fullscreen) return null;
    _fullscreen = false;
    _restoring = _scaleBeforeFullscreen != null;
    return _restoring ? _correction() : null;
  }

  /// 用户触碰网页 / 新导航：停止还原。
  void stop() => _restoring = false;

  double? _correction() {
    final double? target = _scaleBeforeFullscreen;
    final double? current = _scale;
    if (target == null || current == null) return null;
    final double factor = target / current;
    if ((factor - 1).abs() < tolerance) return null;
    return factor;
  }
}
