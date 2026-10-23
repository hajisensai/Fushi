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
