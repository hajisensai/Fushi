/// 系统自带 OCR 的平台能力面。
///
/// 存在的理由是用户那句「安装后不用下载模型也能用」：设备自己就带着文字识别
/// （Android 的 ML Kit 打包模型 / Apple Vision / Windows.Media.Ocr），装完即用、
/// 完全离线、一个字节都不上传。
///
/// **别把它当主力**。这些通用识别器是冲着横排印刷体去的，对漫画的竖排气泡和
/// 手写拟声词明显不如 manga-ocr；它在这里的定位是「零成本兜底档」——没下模型、
/// 又不想上传 Lens 的时候还有得用。UI 上必须如实这么说，把它吹成主力就是骗人。
///
/// 平台侧只需回答两件事：本机能不能用（[SystemOcrPlatform.isAvailable]），以及
/// 给一张图返回若干条文本行（[SystemOcrPlatform.recognize]）。行的分组、竖排
/// 判定和 [MokuroBlock] 组装留在 Dart 侧，四个平台因此只需实现最薄的一层。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 平台识别出的一条文本行，坐标是**送检图的像素坐标**。
class SystemOcrTextLine {
  const SystemOcrTextLine({
    required this.text,
    required this.rect,
    required this.isVertical,
  });

  final String text;

  /// 该行在原图中的包围盒（像素）。
  final Rect rect;

  /// 平台判定的竖排。平台不给这个信息时由 Dart 侧按包围盒长宽比推断。
  final bool isVertical;

  @override
  String toString() => 'SystemOcrTextLine($text, $rect, vertical: $isVertical)';
}

/// 一次识别的结果。
class SystemOcrPageResult {
  const SystemOcrPageResult({
    required this.lines,
    required this.imageWidth,
    required this.imageHeight,
  });

  final List<SystemOcrTextLine> lines;

  /// 送检图尺寸；坐标换算的分母，缺了它没法映射回页图。
  final int imageWidth;
  final int imageHeight;

  bool get isEmpty => lines.isEmpty;
}

/// 系统 OCR 不可用时的原因（直接抛给上层做人话提示）。
class SystemOcrUnavailableException implements Exception {
  const SystemOcrUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => 'SystemOcrUnavailableException($reason)';
}

/// 平台能力接口。测试注 fake，生产走 [MethodChannelSystemOcr]。
abstract interface class SystemOcrPlatform {
  /// 本机是否具备系统 OCR。
  ///
  /// 这个答案会被缓存到一次能力探测里，所以平台侧要能便宜地回答——不要在这里
  /// 做真识别，也不要触发任何按需下载。
  Future<bool> isAvailable();

  /// 识别一张图。[language] 是 BCP-47 主子标签（`ja`/`en`/`zh`…）。
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
  });
}

/// 生产实现：走平台通道。
class MethodChannelSystemOcr implements SystemOcrPlatform {
  const MethodChannelSystemOcr({MethodChannel? channel})
      : _channel = channel ?? kSystemOcrChannel;

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>('isAvailable');
      return ok ?? false;
    } on MissingPluginException {
      // 这个平台还没实现原生侧——「没有」不是错误，是当前事实。
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
  }) async {
    final Map<Object?, Object?>? raw =
        await _channel.invokeMapMethod<Object?, Object?>(
      'recognize',
      <String, Object?>{
        'bytes': imageBytes,
        'language': language,
      },
    );
    if (raw == null) {
      throw const SystemOcrUnavailableException('empty_response');
    }
    return parseSystemOcrPayload(raw);
  }
}

/// 平台通道。原生侧实现同名方法。
const MethodChannel kSystemOcrChannel =
    MethodChannel('app.fushi.reader/system_ocr');

/// 把平台回传的 Map 解析成 [SystemOcrPageResult]。
///
/// 单独抽成纯函数是为了让四个平台的**契约**有一个可测的落点：原生侧改一个字段
/// 名，这里的测试会立刻红，而不是等到真机上返回一页空结果——那种失败在设备上
/// 看起来和「这页真没字」一模一样。
SystemOcrPageResult parseSystemOcrPayload(Map<Object?, Object?> raw) {
  final int width = _asInt(raw['width']);
  final int height = _asInt(raw['height']);
  if (width <= 0 || height <= 0) {
    throw const SystemOcrUnavailableException('invalid_image_size');
  }
  final Object? rawLines = raw['lines'];
  final List<SystemOcrTextLine> lines = <SystemOcrTextLine>[];
  if (rawLines is List) {
    for (final Object? entry in rawLines) {
      if (entry is! Map) continue;
      final String text = (entry['text'] ?? '').toString();
      if (text.trim().isEmpty) continue;
      final double left = _asDouble(entry['left']);
      final double top = _asDouble(entry['top']);
      final double right = _asDouble(entry['right']);
      final double bottom = _asDouble(entry['bottom']);
      if (right <= left || bottom <= top) continue;
      final Rect rect = Rect.fromLTRB(left, top, right, bottom);
      final Object? vertical = entry['vertical'];
      lines.add(SystemOcrTextLine(
        text: text,
        rect: rect,
        // 平台不表态时按包围盒推断：高远大于宽的行就是竖排。漫画气泡里这条
        // 启发式足够准，而且错了也只影响 writing-mode，不影响能不能查词。
        isVertical: vertical is bool ? vertical : rect.height > rect.width * 1.6,
      ));
    }
  }
  return SystemOcrPageResult(
    lines: lines,
    imageWidth: width,
    imageHeight: height,
  );
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
