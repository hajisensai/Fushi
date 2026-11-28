// 「制卡优先」档截取链路的只读体检（BUG-5611）：fork 纹理桥累计收到的 WGC 帧数 + 最近一帧的
// 采样像素。集成测试用它断言「网页视频交给播放页后，纹理确实持续收到有内容的帧」；产品代码
// 不调用，fork 侧不调用就没有开销。纯数据 + 一个通道调用。
import 'package:flutter/services.dart';

import 'package:fushi/src/media/video/web_video_shaders.dart'
    show kWebVideoPlatformViewChannelPrefix;

/// fork 方法名（`custom_platform_view.cc` 的 `kMethodGetCaptureStats`，守卫测试比对字面量）。
const String kWebVideoGetCaptureStatsMethod = 'getCaptureStats';

/// 一次体检结果。[samples] 是帧里 5 个采样点（中心 + 四个四分点）的 `[b, g, r, a]`。
class WebVideoCaptureStats {
  const WebVideoCaptureStats({
    required this.frames,
    required this.width,
    required this.height,
    required this.samples,
  });

  final int frames;
  final int width;
  final int height;
  final List<List<int>> samples;

  /// 有帧、且采样点不是一片白（BUG-5611 的症状：截不到画面时纹理是空的、露出白底；
  /// 网页本身没画出来时截到的也是 WebView2 默认白底）。
  bool get hasNonWhiteContent =>
      width > 0 &&
      height > 0 &&
      samples.isNotEmpty &&
      samples.any((List<int> s) => s.length >= 3 && !_isNearWhite(s));

  /// 采样点之间有明显差异（真画面，不是纯色底）。
  bool get hasVariedContent {
    if (samples.length < 2) return false;
    for (int i = 1; i < samples.length; i++) {
      int diff = 0;
      for (int c = 0; c < 3; c++) {
        diff += (samples[i][c] - samples[0][c]).abs();
      }
      if (diff > 24) return true;
    }
    return false;
  }

  static bool _isNearWhite(List<int> bgra) =>
      bgra[0] >= 240 && bgra[1] >= 240 && bgra[2] >= 240;

  @override
  String toString() =>
      'WebVideoCaptureStats(frames: $frames, ${width}x$height, '
      'samples: $samples)';
}

/// 解 fork 回的 map；形状不对返回 null。
WebVideoCaptureStats? parseWebVideoCaptureStats(Object? raw) {
  if (raw is! Map) return null;
  final Object? frames = raw['frames'];
  final Object? width = raw['width'];
  final Object? height = raw['height'];
  final Object? samples = raw['samples'];
  if (frames is! int || width is! int || height is! int || samples is! List) {
    return null;
  }
  final List<List<int>> parsed = <List<int>>[];
  for (final Object? s in samples) {
    if (s is! List || s.length != 4 || s.any((Object? v) => v is! int)) {
      return null;
    }
    parsed.add(s.cast<int>());
  }
  return WebVideoCaptureStats(
    frames: frames,
    width: width,
    height: height,
    samples: parsed,
  );
}

/// 读 [viewId]（`InAppWebViewController.platform.id`）那一路纹理桥的体检；窗口宿主档 /
/// 通道不通 / 形状不对返回 null。[invoke] 可注入便于单测。
Future<WebVideoCaptureStats?> readWebVideoCaptureStats(
  Object? viewId, {
  Future<Object?> Function(String channel, String method)? invoke,
}) async {
  if (viewId == null) return null;
  final String channel = '$kWebVideoPlatformViewChannelPrefix$viewId';
  try {
    final Object? raw =
        await (invoke ??
            (String channel, String method) =>
                MethodChannel(channel).invokeMethod<Object?>(method))(
          channel,
          kWebVideoGetCaptureStatsMethod,
        );
    return parseWebVideoCaptureStats(raw);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
