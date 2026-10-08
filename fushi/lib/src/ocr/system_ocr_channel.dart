/// 系统自带 OCR 的平台能力面。
///
/// 存在的理由是用户那句「安装后不用下载模型也能用」：模型由**系统**保管而不是
/// 由我们打进包里（Android 走 unbundled ML Kit，模型住在 Google Play 服务、多个
/// app 共享，安装时由 manifest 的 DEPENDENCIES meta-data 触发取下；Apple Vision /
/// Windows.Media.Ocr 本来就是系统组件）。一个字节都不上传。
///
/// 反过来说，这条路依赖系统组件到位。**不到位时不许静默**：Android 侧把 ML Kit 的
/// UNAVAILABLE 单独报成 `MODEL_UNAVAILABLE`，这里映射成
/// [SystemOcrUnavailableException]，与真正的识别失败分开——两者合成一类的话，
/// 用户看到「识别失败」会去怀疑图片，而实际该做的是等模型下完或换引擎。
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
    this.tile,
  });

  final String text;

  /// 该行在原图中的包围盒（像素）。
  final Rect rect;

  /// 平台判定的竖排。平台不给这个信息时由 Dart 侧按包围盒长宽比推断。
  final bool isVertical;

  /// 产出该行的切片下标（对应 [SystemOcrPlatform.recognize] 的 `tiles`）。
  /// 整页识别（没切、或平台忽略了切片请求）时为 null。
  final int? tile;

  @override
  String toString() =>
      'SystemOcrTextLine($text, $rect, vertical: $isVertical, tile: $tile)';
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

/// [SystemOcrUnavailableException.reason]：模型没就绪（Android 的 ML Kit 模型还没由
/// Play 服务取下）。只有这一种该带用户去下载模型（BUG-2906）。
const String kSystemOcrModelUnavailableReason = 'model_unavailable';

/// [SystemOcrUnavailableException.reason]：系统没装这门语言的识别器（Windows OCR
/// 按语言随语言包安装，没装日语就识别不了日文）。用户要去系统设置里装语言。
const String kSystemOcrLanguageUnavailableReason = 'language_unavailable';

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
  ///
  /// [tiles] 是可选的切片（整页像素坐标，见 `ocr_page_tiling.dart`）：平台逐片
  /// 识别，回传的行仍是整页坐标，并用 [SystemOcrTextLine.tile] 标明出自哪片。
  /// 平台可以忽略它（整页识别、行不带下标）——调用方的跨片合并对这种结果是
  /// 恒等的。
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
    List<Rect> tiles = const <Rect>[],
  });
}

/// 系统 OCR 模型的就绪状态（BUG-2906）。
///
/// 只有 Android 会出现「未就绪」：ML Kit 模型由 Google Play 服务保管，安装时的
/// 顺手下载不保证真取到。其它平台的系统 OCR 是系统组件，恒 [ready]。
enum SystemOcrModelStatus {
  /// 模型在，可以识别。
  ready,

  /// Play 服务在，但还没取下这门语言的模型：可以立即请它下载。
  missing,

  /// Play 服务缺失 / 停用 / 过旧，但系统能引导用户修好。
  playServicesResolvable,

  /// 本机没有可用的 Play 服务：系统 OCR 在这台设备上用不了。
  playServicesUnavailable;

  /// 平台回答的线上值（与 Android `SystemOcrChannel.STATUS_*` 一一对应）。
  static SystemOcrModelStatus? fromWire(Object? raw) => switch (raw) {
        'ready' => ready,
        'missing' => missing,
        'play_services_resolvable' => playServicesResolvable,
        'play_services_unavailable' => playServicesUnavailable,
        _ => null,
      };
}

/// 系统 OCR 模型的查询与下载——识别报 [SystemOcrUnavailableException] 后，带用户
/// 去把模型配好，而不是只丢一句「没就绪」（BUG-2906）。测试注 fake。
abstract interface class SystemOcrModelSetup {
  /// 查 [language] 的模型是否在本机。只查询，不触发下载。
  Future<SystemOcrModelStatus> modelStatus(String language);

  /// 请系统立即下载 [language] 的模型，下完才返回；失败抛 [PlatformException]。
  Future<void> installModel(String language);

  /// 让系统引导用户修复 Play 服务（安装 / 启用 / 更新）。修好返回 true。
  Future<bool> resolvePlayServices();
}

/// 生产实现：走平台通道。
class MethodChannelSystemOcr implements SystemOcrPlatform, SystemOcrModelSetup {
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
    List<Rect> tiles = const <Rect>[],
  }) async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>(
        'recognize',
        <String, Object?>{
          'bytes': imageBytes,
          'language': language,
          if (tiles.isNotEmpty)
            'tiles': <List<double>>[
              for (final Rect tile in tiles)
                <double>[tile.left, tile.top, tile.right, tile.bottom],
            ],
        },
      );
    } on PlatformException catch (error) {
      // 模型没就绪（unbundled ML Kit 的模型由 Google Play 服务保管，可能还在下、
      // 或本机压根没有 GMS）不是「这张图识别失败」：调用方据此该提示等待或换引擎，
      // 而不是让用户去怀疑图片。原生侧用 MODEL_UNAVAILABLE 把它单独标出来。
      if (error.code == 'MODEL_UNAVAILABLE') {
        throw const SystemOcrUnavailableException(
            kSystemOcrModelUnavailableReason);
      }
      // Windows：该语言的识别器没装（随系统语言包安装），同样不是图片的问题。
      if (error.code == 'LANGUAGE_UNAVAILABLE') {
        throw const SystemOcrUnavailableException(
            kSystemOcrLanguageUnavailableReason);
      }
      rethrow;
    }
    if (raw == null) {
      throw const SystemOcrUnavailableException('empty_response');
    }
    return parseSystemOcrPayload(raw);
  }

  @override
  Future<SystemOcrModelStatus> modelStatus(String language) async {
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>(
        'modelStatus',
        <String, Object?>{'language': language},
      );
    } on MissingPluginException {
      // 只有 Android 实现了它：其它平台的系统 OCR 是系统组件，没有模型可缺。
      return SystemOcrModelStatus.ready;
    }
    final SystemOcrModelStatus? status = SystemOcrModelStatus.fromWire(raw);
    if (status == null) {
      throw PlatformException(
        code: 'INVALID_STATUS',
        message: 'unknown system OCR model status: $raw',
      );
    }
    return status;
  }

  @override
  Future<void> installModel(String language) async {
    try {
      await _channel.invokeMethod<String>(
        'installModel',
        <String, Object?>{'language': language},
      );
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<bool> resolvePlayServices() async {
    try {
      return await _channel.invokeMethod<bool>('resolvePlayServices') ?? false;
    } on MissingPluginException {
      return false;
    }
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
      final Object? tile = entry['tile'];
      lines.add(SystemOcrTextLine(
        text: text,
        rect: rect,
        isVertical: vertical is bool ? vertical : inferSystemOcrVertical(rect),
        tile: tile is num ? tile.toInt() : null,
      ));
    }
  }
  return SystemOcrPageResult(
    lines: lines,
    imageWidth: width,
    imageHeight: height,
  );
}

/// 平台不表态时按包围盒推断竖排：高远大于宽的行就是竖排。漫画气泡里这条
/// 启发式足够准，而且错了也只影响 writing-mode，不影响能不能查词。
///
/// 跨片拼接后的行也走这一条，所以单独抽出来——两处各写一遍就是两套判据。
bool inferSystemOcrVertical(Rect rect) => rect.height > rect.width * 1.6;

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
