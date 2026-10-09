// 反馈附带的诊断信息：设备 / 版本信息（meta）、压缩日志、当前画面截图。
//
// 只收排查需要的最少信息：App 版本、平台与系统版本、机型、界面语言、窗口尺寸；
// 不收账号、文件路径以外的个人数据。日志就是「设置 › 诊断」里错误日志 / 调试日志
// 页面上能看到的那两份（用户在提交页可以关掉）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/debug_log_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 根布局外层的 [RepaintBoundary]（`main.dart` 的 MaterialApp builder 里），截「用户
/// 此刻看到的画面」用。WebView / 视频纹理等平台视图在部分平台截出来是空白，用户可以
/// 在提交页删掉它、改从相册选图。
final GlobalKey feedbackScreenshotBoundaryKey = GlobalKey(
  debugLabel: 'feedbackScreenshotBoundary',
);

/// 截图长边上限（像素）：够看清界面，PNG 一般几百 KB，远低于服务端单张上限。
const int kFeedbackScreenshotMaxSide = 1600;

/// 截当前画面为 PNG；根边界还没布局（启动早期）或编码失败返回 null。
/// 超过服务端上限时逐级缩小重截。
Future<Uint8List?> captureFeedbackScreenshot() async {
  final RenderObject? object = feedbackScreenshotBoundaryKey.currentContext
      ?.findRenderObject();
  if (object is! RenderRepaintBoundary || !object.hasSize) return null;
  final Size size = object.size;
  final double longest = math.max(size.width, size.height);
  if (longest <= 0) return null;
  double ratio = math.min(
    ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
    kFeedbackScreenshotMaxSide / longest,
  );
  for (int attempt = 0; attempt < 4; attempt++) {
    final ui.Image image;
    try {
      image = await object.toImage(pixelRatio: ratio);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.screenshot', e, st);
      return null;
    }
    try {
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null) return null;
      final Uint8List png = bytes.buffer.asUint8List();
      if (png.length <= FeedbackLimits.screenshotMaxBytes) return png;
    } finally {
      image.dispose();
    }
    ratio *= 0.7;
  }
  return null;
}

/// 设备 / 版本信息（服务端只收一层标量键值，≤ 4KB）。
Future<Map<String, Object?>> collectFeedbackMeta() async {
  final Map<String, Object?> meta = <String, Object?>{};
  String version = fushiRunningCodeVersion ?? 'unknown';
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    // 与日志上传同一口径：优先报运行中这份 Dart 代码的版本（BUG-1786）。
    version = '${fushiRunningCodeVersion ?? info.version}+${info.buildNumber}';
  } on Object {
    // 拿不到 PackageInfo 就只报编译期版本。
  }
  meta['app_version'] = version;
  meta['platform'] = Platform.operatingSystem;
  meta['os_version'] = Platform.operatingSystemVersion;
  meta['locale'] = LocaleSettings.currentLocale.languageTag;
  meta['system_locale'] = Platform.localeName;
  final ui.FlutterView? view = ui.PlatformDispatcher.instance.views.firstOrNull;
  if (view != null) {
    final Size logical = view.physicalSize / view.devicePixelRatio;
    meta['window'] =
        '${logical.width.round()}x${logical.height.round()}'
        '@${view.devicePixelRatio.toStringAsFixed(2)}';
  }
  try {
    meta.addAll(await _deviceModel());
  } on Object catch (e, st) {
    ErrorLogService.instance.log('feedback.device_info', e, st);
  }
  return meta;
}

Future<Map<String, Object?>> _deviceModel() async {
  final DeviceInfoPlugin plugin = DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final AndroidDeviceInfo a = await plugin.androidInfo;
    return <String, Object?>{
      'device': '${a.manufacturer} ${a.model}',
      'android_sdk': a.version.sdkInt,
      'abi': a.supportedAbis.isEmpty ? '' : a.supportedAbis.first,
    };
  }
  if (Platform.isIOS) {
    final IosDeviceInfo i = await plugin.iosInfo;
    return <String, Object?>{
      'device': i.utsname.machine,
      'ios_version': i.systemVersion,
    };
  }
  if (Platform.isMacOS) {
    final MacOsDeviceInfo m = await plugin.macOsInfo;
    return <String, Object?>{'device': m.model, 'arch': m.arch};
  }
  if (Platform.isWindows) {
    final WindowsDeviceInfo w = await plugin.windowsInfo;
    return <String, Object?>{
      'device': w.productName,
      'windows_build': w.buildNumber,
    };
  }
  if (Platform.isLinux) {
    final LinuxDeviceInfo l = await plugin.linuxInfo;
    return <String, Object?>{'device': l.prettyName};
  }
  return const <String, Object?>{};
}

/// 当前的错误日志 + 调试日志（调试日志只在用户开着「调试日志」时有内容）。
String collectFeedbackLogText() {
  final StringBuffer buf = StringBuffer()
    ..writeln('==== error log ====')
    ..writeln(ErrorLogService.instance.getFullLog());
  if (DebugLogService.instance.enabled) {
    buf
      ..writeln()
      ..writeln('==== debug log ====')
      ..writeln(DebugLogService.instance.getFullLog());
  }
  return buf.toString();
}

/// 把日志文本压成 gzip，保证不超过 [maxBytes]（服务端上限）：超了就只留**末尾**
/// （最近的记录最有用）、逐次减半重压。截断时在开头注明。
Uint8List buildFeedbackLogGzip(
  String log, {
  int maxBytes = FeedbackLimits.logMaxBytes,
}) {
  List<int> raw = utf8.encode(log);
  // 先按 8 倍压缩比估一个上限，免得对几十 MB 文本做无用功。
  int keep = math.min(raw.length, maxBytes * 8);
  for (;;) {
    final bool truncated = keep < raw.length;
    final List<int> tail = truncated
        ? raw.sublist(_utf8Boundary(raw, raw.length - keep))
        : raw;
    final List<int> body = truncated
        ? <int>[
            ...utf8.encode('[truncated: kept last ${tail.length} bytes]\n'),
            ...tail,
          ]
        : tail;
    final Uint8List gz = Uint8List.fromList(gzip.encode(body));
    if (gz.length <= maxBytes || keep <= 1024) return gz;
    keep ~/= 2;
    raw = tail;
  }
}

/// 从 [start] 往后找到第一个 UTF-8 字符起点（不把多字节字符切成两半）。
int _utf8Boundary(List<int> bytes, int start) {
  int i = math.max(0, start);
  while (i < bytes.length && (bytes[i] & 0xC0) == 0x80) {
    i++;
  }
  return i;
}
