// 反馈附带的诊断信息：设备 / 版本信息（meta）、压缩日志、当前画面截图。
//
// 只收排查需要的最少信息：App 版本、平台与系统版本、机型、界面语言、窗口尺寸；
// 不收账号等个人数据。日志就是「设置 › 诊断」里错误日志 / 调试日志页面上能看到的
// 那两份（用户在提交页可以关掉），上传前经 [redactFeedbackLog] 脱敏。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/feedback/feedback_log_redaction.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/debug_log_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 根布局外层的 [RepaintBoundary]（`main.dart` 的 MaterialApp builder 里），截「用户
/// 此刻看到的画面」的回退路径用。WebView 等平台视图不在 Flutter 场景里，
/// [RenderRepaintBoundary.toImage] 截出来那一块是空白——所以 iOS / Android 先走
/// 原生窗口快照（见 [captureFeedbackScreenshot]），原生不可用时才回到这里。
final GlobalKey feedbackScreenshotBoundaryKey = GlobalKey(
  debugLabel: 'feedbackScreenshotBoundary',
);

/// 截图长边上限（像素）：够看清界面，PNG 一般几百 KB，远低于服务端单张上限。
const int kFeedbackScreenshotMaxSide = 1600;

/// 原生窗口快照进行中。反馈截图的语义是「页面本身」，不含应用内悬浮球等全局
/// 浮层；原生快照截的是整个窗口，所以截之前悬浮球宿主据此把球藏掉。
final ValueNotifier<bool> feedbackWindowCaptureActive = ValueNotifier<bool>(
  false,
);

/// 原生窗口快照：返回本 App 窗口的编码图（含 WKWebView / Android WebView 等
/// 平台视图）；本设备做不到返回 null；失败抛 [PlatformException]。
typedef FeedbackNativeWindowCapture = Future<Uint8List?> Function();

/// 只有 iOS（`drawHierarchy`）与 Android（PixelCopy，API 26+）有原生窗口快照，
/// 实现挂在悬浮球通道的 `captureScreen` 上（iOS `FushiFloatingBall.swift`，
/// Android `FloatingBallChannel.java`；两端都在引擎起来时无条件注册，不依赖悬浮球
/// 开关）。桌面三端保持 toImage：Windows / Linux 的 WebView 以纹理合成进 Flutter
/// 场景，toImage 截得到；macOS 的 WKWebView 是原生视图，仍会缺一块。
bool get _nativeWindowCaptureSupported => Platform.isIOS || Platform.isAndroid;

/// 原生侧按 `maxSide` 在合成时就缩到上限内再编码（Android），不把全分辨率
/// PNG 经通道传过来再由 Dart 解码缩放；iOS 忽略该参数，由
/// [fitFeedbackScreenshotPng] 兜底缩放。
Future<Uint8List?> _invokeNativeWindowCapture() => FloatingBallChannel.channel
    .invokeMethod<Uint8List>('captureScreen', nativeWindowCaptureArguments());

/// `captureScreen` 的通道参数：输出长边上限。
@visibleForTesting
Map<String, Object> nativeWindowCaptureArguments({
  int maxSide = kFeedbackScreenshotMaxSide,
}) => <String, Object>{'maxSide': maxSide};

/// 截当前画面为 PNG（长边 ≤ [kFeedbackScreenshotMaxSide]、体积 ≤ 服务端单张上限）。
///
/// iOS / Android 先截原生窗口（平台视图也在里面）；原生没注册 / 本设备不支持 /
/// 失败 / 产物解不开时记日志，回退到 Flutter 根边界 toImage。都不行返回 null。
Future<Uint8List?> captureFeedbackScreenshot() => captureFeedbackScreenshotWith(
  nativeWindow: _nativeWindowCaptureSupported
      ? _invokeNativeWindowCapture
      : null,
  boundary: _captureFeedbackBoundary,
  awaitFrame: _awaitOverlayHiddenFrame,
);

/// 让「藏球」这一帧的 Dart 帧提交完再发原生快照（与悬浮球 iOS 截屏 OCR 同一做法）。
/// 这只保证 Dart 帧提交；Android Hybrid Composition 下 Flutter 画面还要等主线程
/// 重画一次窗口才进窗口缓冲区——那一步由原生侧（`AppWindowSnapshot` 先让窗口
/// 重画、画完再 PixelCopy）负责，不在这里多等几帧去凑。
Future<void> _awaitOverlayHiddenFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame;
}

/// [captureFeedbackScreenshot] 的可注入实现（测试缝）。[nativeWindow] 为 null
/// 表示本平台没有原生窗口快照，直接走 [boundary]；[awaitFrame] 等藏掉浮层的那一帧
/// 画完。
@visibleForTesting
Future<Uint8List?> captureFeedbackScreenshotWith({
  required FeedbackNativeWindowCapture? nativeWindow,
  required Future<Uint8List?> Function() boundary,
  required Future<void> Function() awaitFrame,
}) async {
  if (nativeWindow != null) {
    final Uint8List? shot = await _captureNativeWindow(
      nativeWindow,
      awaitFrame,
    );
    if (shot != null) return shot;
  }
  return boundary();
}

/// 藏掉全局浮层、等这一帧画完，再要原生快照；产物缩到上限内。每一种失败都
/// 记日志后返回 null，由调用方回退到 toImage。
Future<Uint8List?> _captureNativeWindow(
  FeedbackNativeWindowCapture nativeWindow,
  Future<void> Function() awaitFrame,
) async {
  final Uint8List? raw;
  feedbackWindowCaptureActive.value = true;
  try {
    await awaitFrame();
    raw = await nativeWindow();
  } on MissingPluginException catch (e) {
    ErrorLogService.instance.logDiagnostic(
      'feedback.screenshot',
      'native window capture not registered, falling back to toImage ($e)',
    );
    return null;
  } on PlatformException catch (e, st) {
    ErrorLogService.instance.log('feedback.screenshot.native', e, st);
    return null;
  } finally {
    feedbackWindowCaptureActive.value = false;
  }
  if (raw == null || raw.isEmpty) {
    ErrorLogService.instance.logDiagnostic(
      'feedback.screenshot',
      'native window capture unsupported on this device, falling back to '
          'toImage',
    );
    return null;
  }
  try {
    final Uint8List? fitted = await fitFeedbackScreenshotPng(raw);
    if (fitted == null) {
      ErrorLogService.instance.logDiagnostic(
        'feedback.screenshot',
        'native capture (${raw.length} bytes) does not fit the upload limit, '
            'falling back to toImage',
      );
    }
    return fitted;
  } on Object catch (e, st) {
    ErrorLogService.instance.log('feedback.screenshot.native_decode', e, st);
    return null;
  }
}

/// 把一张编码好的截图缩到长边 ≤ [maxSide]、体积 ≤ [maxBytes]（PNG）；原图已满足
/// 就原样返回。逐级缩小 4 次仍超限返回 null。解码失败抛出。
@visibleForTesting
Future<Uint8List?> fitFeedbackScreenshotPng(
  Uint8List encoded, {
  int maxSide = kFeedbackScreenshotMaxSide,
  int maxBytes = FeedbackLimits.screenshotMaxBytes,
}) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    encoded,
  );
  final ui.ImageDescriptor descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } finally {
    buffer.dispose();
  }
  try {
    final int longest = math.max(descriptor.width, descriptor.height);
    if (longest <= 0) return null;
    if (longest <= maxSide && encoded.length <= maxBytes) return encoded;
    double scale = math.min(1, maxSide / longest);
    for (int attempt = 0; attempt < 4; attempt++) {
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      final ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      try {
        final Uint8List? png = await _encodePng(image);
        if (png == null) return null;
        if (png.length <= maxBytes) return png;
      } finally {
        image.dispose();
      }
      scale *= 0.7;
    }
    return null;
  } finally {
    descriptor.dispose();
  }
}

Future<Uint8List?> _encodePng(ui.Image image) async {
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  return bytes?.buffer.asUint8List();
}

/// Flutter 根边界 toImage（回退路径，平台视图那块是空白）；根边界还没布局
/// （启动早期）或编码失败返回 null。超过服务端上限时逐级缩小重截。
Future<Uint8List?> _captureFeedbackBoundary() async {
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
      final Uint8List? png = await _encodePng(image);
      if (png == null) return null;
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

/// 要上传的日志：错误日志 + 调试日志（调试日志只在 [includeDebugLog] 且用户开着
/// 「调试日志」时带）。这是反馈 / 闪退报告日志附件的**唯一汇总点**，出口统一过
/// [redactFeedbackLog] 脱敏（家目录、令牌、Authorization / Cookie、邮箱）。
///
/// 闪退自动报告传 `includeDebugLog: false`（[FeedbackDraft.includeDebugLog]）：用户只
/// 同意了发错误日志与退出摘要，调试日志是整段 `debugPrint` 原文，不随之发出。
String collectFeedbackLogText({required bool includeDebugLog}) {
  final StringBuffer buf = StringBuffer()
    ..writeln('==== error log ====')
    ..writeln(ErrorLogService.instance.getFullLog());
  if (includeDebugLog && DebugLogService.instance.enabled) {
    buf
      ..writeln()
      ..writeln('==== debug log ====')
      ..writeln(DebugLogService.instance.getFullLog());
  }
  return redactFeedbackLog(buf.toString());
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
