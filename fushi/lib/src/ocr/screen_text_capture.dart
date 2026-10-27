/// 「截屏 → OCR → 返回全文」：把用户此刻在 Fushi 窗口里看到的文字取成一段纯文本
/// （AI 助手的「附上屏幕文字」用，spec `2026-10-26-ai-operations-agent-design.md`
/// §6.4）。
///
/// 两步都复用现成能力，不另起一套截屏 / 识别流程：
///  1. 截图 = 反馈截图同一个入口 [captureFeedbackScreenshot]：iOS（`drawHierarchy`）
///     / Android（PixelCopy）截原生窗口，含 WebView 等平台视图；截之前悬浮球自己
///     藏起来（[feedbackWindowCaptureActive]）。桌面走 Flutter 根边界 toImage——
///     Windows 的 WebView 以纹理合成进场景，截得到；**macOS 的 WKWebView 是原生
///     视图，阅读器正文那块会是空白**（已知缺口，见 [screenTextCaptureSupported]）。
///  2. 识别 = 系统 OCR [MethodChannelSystemOcr]（Android ML Kit / Apple Vision /
///     Windows.Media.Ocr，悬浮球截屏识字同一个识别器与语言）。
///
/// 为什么不直接调悬浮球的截屏识字：Android 那条（`FloatingBallChannel.startScreenOcr`）
/// 是 MediaProjection 截整屏 + 原生取词页，识别结果只在原生侧点字查词，**不回传
/// Dart**；桌面那条（`startScreenOcrCapture`）截整块显示器并盖上可交互的冻结层，
/// 是给应用外球点字用的。AI 助手要的是「Fushi 自己这页上有什么字」，截自己窗口
/// 正合适，也不需要截屏授权弹窗。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart'
    show captureFeedbackScreenshot;
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart'
    show kFloatingBallOcrLanguage;
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 附进 AI 上下文的屏幕文字上限（字符）。一屏正文通常一两千字，4000 足够，
/// 再长只会白白吃 token。
const int kScreenTextMaxChars = 4000;

/// 附给视觉模型的截图长边上限（像素）。4K 截图原样发一张就是几 MB base64、每轮
/// 都要重发；各家视觉模型本来也会把图缩到 1.5k～2k 级别再看，1920 不丢可读性。
const int kScreenImageMaxEdge = 1920;

/// 本平台能不能识别屏幕文字：要有系统 OCR（Android / iOS / macOS / Windows）。
/// Linux 没有系统 OCR 实现：AI 助手的模型能收图时仍出按钮、只附截图，否则不出。
///
/// macOS 可用但有缺口：截图走 Flutter toImage，WKWebView（阅读器 EPUB 正文）截不到，
/// 只能拿到 Flutter 自己画的界面文字（标题、字幕、列表等）。
bool get screenTextCaptureSupported =>
    debugScreenTextCaptureSupportedOverride ??
    (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows);

/// 测试缝：覆盖 [screenTextCaptureSupported]（Linux CI 上也能测按钮出现）。
@visibleForTesting
bool? debugScreenTextCaptureSupportedOverride;

/// 一次取屏幕文字的结果。
enum ScreenTextCaptureStatus {
  /// 取到了文字（[ScreenTextCaptureResult.text] 非空）。
  ok,

  /// 截到了图，但没识别出字。
  empty,

  /// 系统 OCR 不可用（Android ML Kit 模型没就绪 / Windows 没装这门语言）。
  unavailable,

  /// 截图失败或识别出错。
  failed,
}

@immutable
class ScreenTextCaptureResult {
  const ScreenTextCaptureResult(
    this.status, {
    this.text = '',
    this.reason,
    this.image,
  });

  final ScreenTextCaptureStatus status;

  /// 识别出的全文（按行换行），已截到 [kScreenTextMaxChars]。
  final String text;

  /// [ScreenTextCaptureStatus.unavailable] 时的原因（
  /// [kSystemOcrModelUnavailableReason] / [kSystemOcrLanguageUnavailableReason]）。
  final String? reason;

  /// 截到的窗口图（PNG，已缩到 [kScreenImageMaxEdge] 以内）；只在调用方要图
  /// （`keepImage`）且截图成功时有，与 [status]（文字识别的结局）无关。
  final Uint8List? image;
}

/// 「截屏 → OCR → 全文」的函数形（UI 注入假实现做测试）。
typedef ScreenTextCapture = Future<ScreenTextCaptureResult> Function();

/// 截当前窗口并识别出全文。调用方负责先把会挡住内容的自家浮层（AI 面板）藏掉。
///
/// [keepImage]：连截图一起带回（发给视觉模型）。[recognize] 为 false 时不跑
/// OCR（本平台没有系统 OCR），文字一栏按 [ScreenTextCaptureStatus.unavailable]。
///
/// [capture] / [ocr] / [shrink] 是测试缝，默认分别是 [captureFeedbackScreenshot]、
/// [MethodChannelSystemOcr] 与 [shrinkScreenImage]。
Future<ScreenTextCaptureResult> captureScreenText({
  bool keepImage = false,
  bool recognize = true,
  Future<Uint8List?> Function()? capture,
  SystemOcrPlatform? ocr,
  Future<Uint8List> Function(Uint8List png)? shrink,
  String language = kFloatingBallOcrLanguage,
  int maxChars = kScreenTextMaxChars,
}) async {
  final Uint8List? png;
  try {
    png = await (capture ?? captureFeedbackScreenshot)();
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('ai_agent.screen_text.capture', error, stack);
    return const ScreenTextCaptureResult(ScreenTextCaptureStatus.failed);
  }
  if (png == null || png.isEmpty) {
    return const ScreenTextCaptureResult(ScreenTextCaptureStatus.failed);
  }
  Uint8List? image;
  if (keepImage) {
    try {
      image = await (shrink ?? shrinkScreenImage)(png);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'ai_agent.screen_image.shrink',
        error,
        stack,
      );
    }
  }
  if (!recognize) {
    return ScreenTextCaptureResult(
      ScreenTextCaptureStatus.unavailable,
      image: image,
    );
  }
  final SystemOcrPageResult result;
  try {
    result = await (ocr ?? const MethodChannelSystemOcr()).recognize(
      png,
      language: language,
    );
  } on SystemOcrUnavailableException catch (error) {
    return ScreenTextCaptureResult(
      ScreenTextCaptureStatus.unavailable,
      reason: error.reason,
      image: image,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('ai_agent.screen_text.ocr', error, stack);
    return ScreenTextCaptureResult(
      ScreenTextCaptureStatus.failed,
      image: image,
    );
  }
  final String text = screenTextFromOcrLines(result.lines, maxChars: maxChars);
  if (text.isEmpty) {
    return ScreenTextCaptureResult(ScreenTextCaptureStatus.empty, image: image);
  }
  return ScreenTextCaptureResult(
    ScreenTextCaptureStatus.ok,
    text: text,
    image: image,
  );
}

/// 截图缩到长边 [maxEdge] 以内再编回 PNG（引擎解码 / 编码，不占 Dart 堆做像素）；
/// 本来就不大的原样返回。
Future<Uint8List> shrinkScreenImage(
  Uint8List png, {
  int maxEdge = kScreenImageMaxEdge,
}) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(png);
  final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
    buffer,
  );
  final int width = descriptor.width;
  final int height = descriptor.height;
  if (width <= maxEdge && height <= maxEdge) {
    descriptor.dispose();
    buffer.dispose();
    return png;
  }
  final double scale = maxEdge / (width > height ? width : height);
  final ui.Codec codec = await descriptor.instantiateCodec(
    targetWidth: (width * scale).round(),
    targetHeight: (height * scale).round(),
  );
  try {
    final ui.FrameInfo frame = await codec.getNextFrame();
    try {
      final ByteData? data = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data == null ? png : data.buffer.asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// 识别行 → 全文：按平台给的顺序一行一行拼（平台已按阅读顺序排好），去掉空行，
/// 超过 [maxChars] 截断。纯函数。
@visibleForTesting
String screenTextFromOcrLines(
  List<SystemOcrTextLine> lines, {
  int maxChars = kScreenTextMaxChars,
}) {
  final String joined = <String>[
    for (final SystemOcrTextLine line in lines)
      if (line.text.trim().isNotEmpty) line.text.trim(),
  ].join('\n');
  if (joined.length <= maxChars) return joined;
  // 不把代理对（emoji / 扩展汉字）劈成半个。
  int end = maxChars;
  final int last = joined.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return joined.substring(0, end);
}
