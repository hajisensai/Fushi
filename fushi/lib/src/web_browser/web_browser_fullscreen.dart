import 'package:flutter/services.dart' show DeviceOrientation;

/// 浏览器网页全屏的纯判据（「Fushi 接管网页全屏」，2026-11-20 用户拍板）。
///
/// 页内脚本（[webBrowserFullscreenScript]）把网站的全屏请求截成 Fushi 伪全屏，
/// 进 / 退时连同「全屏视频的方向」一起报给 Dart；方向锁和「竖拿横视频」分屏都只由
/// 这里的函数判定，浏览页只消费结论。

/// 全屏中视频的方向（页内脚本按视频的 `videoWidth / videoHeight` 判，没加载出尺寸
/// 时退到元素矩形）。值名即页内脚本上报的字符串。
enum WebBrowserFullscreenFit {
  /// 不知道（没有视频、或尺寸还是 0）。不锁方向。
  unknown,

  /// 横视频（宽 ≥ 高）。
  landscape,

  /// 竖视频（高 > 宽）。
  portrait;

  static WebBrowserFullscreenFit fromWire(Object? raw) =>
      WebBrowserFullscreenFit.values.firstWhere(
        (WebBrowserFullscreenFit f) => f.name == raw,
        orElse: () => WebBrowserFullscreenFit.unknown,
      );
}

/// 浏览页不在全屏时的方向集，与 `main.dart` 启动时设的集合一致（竖屏 + 两个横屏）。
const List<DeviceOrientation> kWebBrowserIdleOrientations = <DeviceOrientation>[
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

/// 网页全屏期间手机应允许的方向。
///
/// - 横视频 + 自动转横屏：只给两个横屏（系统据此立刻转过去，锁了方向也会转）；
/// - 竖视频：只给竖屏（横着拿手机进全屏也转回竖屏铺满）；
/// - 横视频但关了自动转横屏、或方向未知：不改（竖着拿就是「上视频、下字幕列表」分屏，
///   见 [webBrowserFullscreenSplit]）。
List<DeviceOrientation> webBrowserFullscreenOrientations({
  required bool fullscreen,
  required WebBrowserFullscreenFit fit,
  required bool autoRotate,
}) {
  if (!fullscreen) return kWebBrowserIdleOrientations;
  switch (fit) {
    case WebBrowserFullscreenFit.landscape:
      return autoRotate
          ? const <DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : kWebBrowserIdleOrientations;
    case WebBrowserFullscreenFit.portrait:
      return const <DeviceOrientation>[DeviceOrientation.portraitUp];
    case WebBrowserFullscreenFit.unknown:
      return kWebBrowserIdleOrientations;
  }
}

/// 「竖着拿手机看横视频」分屏：全屏中、横视频、而视口是竖的。此时视频贴顶，
/// 下面空出来的地方给字幕列表（功能侧栏的底部抽屉，推挤网页而不是盖在上面）。
bool webBrowserFullscreenSplit({
  required bool fullscreen,
  required WebBrowserFullscreenFit fit,
  required double width,
  required double height,
}) => fullscreen && fit == WebBrowserFullscreenFit.landscape && height > width;

/// 分屏时网页（视频）区的高度：16:9 视频按宽度铺满的高度，至少占 20% 视口，
/// 至多 60%（字幕列表至少留四成）。
double webBrowserFullscreenSplitVideoHeight({
  required double width,
  required double height,
}) {
  final double video = width * 9 / 16;
  return video.clamp(height * 0.2, height * 0.6);
}
