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
///
/// Play 服务的问题按 `ConnectionResult` 码分开（BUG-4127，见
/// [systemOcrStatusForConnectionResult]）：以前合成「可修 / 不可修」两档，Play 服务
/// 已是最新的用户也只能看到「缺失、被停用或版本过旧」、被带去一个说「已是最新」的
/// 商店页。
enum SystemOcrModelStatus {
  /// 模型在，可以识别。
  ready,

  /// Play 服务在，但还没取下这门语言的模型：可以立即请它下载。
  missing,

  /// 本机没装 Play 服务（`SERVICE_MISSING`）。
  playServicesMissing,

  /// Play 服务被停用（`SERVICE_DISABLED`）：要去它的应用设置里启用。
  playServicesDisabled,

  /// Play 服务版本低于本库要求（`SERVICE_VERSION_UPDATE_REQUIRED`）。
  playServicesUpdateRequired,

  /// Play 服务正在更新（`SERVICE_UPDATING`）：等它更新完再查。
  playServicesUpdating,

  /// 装着的 Play 服务不是正版 / 已损坏（`SERVICE_INVALID`）。
  playServicesInvalid,

  /// 其它让 Play 服务用不了的情况：系统 OCR 在这台设备上用不了。
  playServicesUnavailable,
}

/// `com.google.android.gms.common.ConnectionResult` 里与 Play 服务可用性有关的码。
abstract final class PlayServicesConnectionResult {
  static const int serviceMissing = 1;
  static const int serviceVersionUpdateRequired = 2;
  static const int serviceDisabled = 3;
  static const int serviceInvalid = 9;
  static const int serviceUpdating = 18;
}

/// `isGooglePlayServicesAvailable` 的原始码 → 状态。整个仓库只在这里做这一步映射
/// （BUG-4127）：原生侧只回传原始码，不再自己二分。
SystemOcrModelStatus systemOcrStatusForConnectionResult(int code) =>
    switch (code) {
      PlayServicesConnectionResult.serviceMissing =>
        SystemOcrModelStatus.playServicesMissing,
      PlayServicesConnectionResult.serviceVersionUpdateRequired =>
        SystemOcrModelStatus.playServicesUpdateRequired,
      PlayServicesConnectionResult.serviceDisabled =>
        SystemOcrModelStatus.playServicesDisabled,
      PlayServicesConnectionResult.serviceInvalid =>
        SystemOcrModelStatus.playServicesInvalid,
      PlayServicesConnectionResult.serviceUpdating =>
        SystemOcrModelStatus.playServicesUpdating,
      _ => SystemOcrModelStatus.playServicesUnavailable,
    };

/// Play 服务出问题时原生侧带回的诊断：原始码与两边的版本号，弹窗原样显示，
/// 方便反馈人截图。
class SystemOcrPlayServicesDiagnostics {
  const SystemOcrPlayServicesDiagnostics({
    required this.connectionResult,
    required this.requiredVersionCode,
    this.installedVersionCode,
    this.installedVersionName,
  });

  /// `GoogleApiAvailability.isGooglePlayServicesAvailable` 的原始返回码。
  final int connectionResult;

  /// 本库要求的最低 Play 服务版本（`GOOGLE_PLAY_SERVICES_VERSION_CODE`）。
  final int requiredVersionCode;

  /// 本机 Play 服务 APK 的 versionCode；包管理器查不到该包时为 null。
  final int? installedVersionCode;

  /// 本机 Play 服务 APK 的 versionName（商店页上显示的那个）；查不到该包或
  /// 包没有 versionName 时为 null。
  final String? installedVersionName;

  @override
  bool operator ==(Object other) =>
      other is SystemOcrPlayServicesDiagnostics &&
      other.connectionResult == connectionResult &&
      other.requiredVersionCode == requiredVersionCode &&
      other.installedVersionCode == installedVersionCode &&
      other.installedVersionName == installedVersionName;

  @override
  int get hashCode => Object.hash(
    connectionResult,
    requiredVersionCode,
    installedVersionCode,
    installedVersionName,
  );

  @override
  String toString() =>
      'SystemOcrPlayServicesDiagnostics(code: $connectionResult, '
      'installed: $installedVersionName ($installedVersionCode), '
      'required: $requiredVersionCode)';
}

/// 一次模型状态查询的回答：状态，Play 服务有问题时再加诊断。
class SystemOcrModelReport {
  const SystemOcrModelReport(this.status, {this.playServices});

  final SystemOcrModelStatus status;

  /// 仅 Play 服务有问题时非空。
  final SystemOcrPlayServicesDiagnostics? playServices;

  @override
  bool operator ==(Object other) =>
      other is SystemOcrModelReport &&
      other.status == status &&
      other.playServices == playServices;

  @override
  int get hashCode => Object.hash(status, playServices);

  @override
  String toString() => 'SystemOcrModelReport($status, $playServices)';
}

/// 解析 Android `SystemOcrChannel` 的 `modelStatus` 载荷（也是
/// `PLAY_SERVICES_UNAVAILABLE` 错误的 details）。认不出就返回 null——调用方必须
/// 报错，不能把看不懂的回答当成就绪。
///
/// 字段名是跨语言契约，改这里必须同步改 `SystemOcrChannel.KEY_*`。
SystemOcrModelReport? parseSystemOcrModelReport(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['status']) {
    case 'ready':
      return const SystemOcrModelReport(SystemOcrModelStatus.ready);
    case 'missing':
      return const SystemOcrModelReport(SystemOcrModelStatus.missing);
    case 'play_services_problem':
      final Object? code = raw['connectionResult'];
      final Object? required = raw['requiredVersionCode'];
      if (code is! int || required is! int) return null;
      final Object? installedCode = raw['installedVersionCode'];
      final Object? installedName = raw['installedVersionName'];
      return SystemOcrModelReport(
        systemOcrStatusForConnectionResult(code),
        playServices: SystemOcrPlayServicesDiagnostics(
          connectionResult: code,
          requiredVersionCode: required,
          installedVersionCode: installedCode is int ? installedCode : null,
          installedVersionName: installedName is String ? installedName : null,
        ),
      );
  }
  return null;
}

/// 下载模型时发现 Play 服务有问题（原生 `PLAY_SERVICES_UNAVAILABLE`）：带着与
/// `modelStatus` 同形的报告，弹窗据此切到对应状态，而不是只显示一句错误。
class SystemOcrPlayServicesException implements Exception {
  const SystemOcrPlayServicesException(this.report);

  final SystemOcrModelReport report;

  @override
  String toString() => 'SystemOcrPlayServicesException($report)';
}

/// 系统 OCR 模型的查询与下载——识别报 [SystemOcrUnavailableException] 后，带用户
/// 去把模型配好，而不是只丢一句「没就绪」（BUG-2906）。测试注 fake。
abstract interface class SystemOcrModelSetup {
  /// 查 [language] 的模型是否在本机。只查询，不触发下载。
  Future<SystemOcrModelReport> modelStatus(String language);

  /// 请系统立即下载 [language] 的模型，下完才返回。Play 服务有问题时抛
  /// [SystemOcrPlayServicesException]，其它失败抛 [PlatformException]。
  Future<void> installModel(String language);

  /// 让系统引导用户安装 / 更新 Play 服务（系统对话框 → Play 商店）。修好返回 true。
  Future<bool> resolvePlayServices();

  /// 打开 Play 服务的应用详情页（被停用时去那里启用）。打不开抛 [PlatformException]。
  Future<void> openPlayServicesSettings();
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
          kSystemOcrModelUnavailableReason,
        );
      }
      // Windows：该语言的识别器没装（随系统语言包安装），同样不是图片的问题。
      if (error.code == 'LANGUAGE_UNAVAILABLE') {
        throw const SystemOcrUnavailableException(
          kSystemOcrLanguageUnavailableReason,
        );
      }
      rethrow;
    }
    if (raw == null) {
      throw const SystemOcrUnavailableException('empty_response');
    }
    return parseSystemOcrPayload(raw);
  }

  @override
  Future<SystemOcrModelReport> modelStatus(String language) async {
    final Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>(
        'modelStatus',
        <String, Object?>{'language': language},
      );
    } on MissingPluginException {
      // 只有 Android 实现了它：其它平台的系统 OCR 是系统组件，没有模型可缺。
      return const SystemOcrModelReport(SystemOcrModelStatus.ready);
    }
    final SystemOcrModelReport? report = parseSystemOcrModelReport(raw);
    if (report == null) {
      throw PlatformException(
        code: 'INVALID_STATUS',
        message: 'unknown system OCR model status: $raw',
      );
    }
    return report;
  }

  @override
  Future<void> installModel(String language) async {
    try {
      await _channel.invokeMethod<String>('installModel', <String, Object?>{
        'language': language,
      });
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      if (error.code == 'PLAY_SERVICES_UNAVAILABLE') {
        final SystemOcrModelReport? report = parseSystemOcrModelReport(
          error.details,
        );
        if (report != null) throw SystemOcrPlayServicesException(report);
      }
      rethrow;
    }
  }

  @override
  Future<void> openPlayServicesSettings() async {
    await _channel.invokeMethod<bool>('openPlayServicesSettings');
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
const MethodChannel kSystemOcrChannel = MethodChannel(
  'app.fushi.reader/system_ocr',
);

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
      lines.add(
        SystemOcrTextLine(
          text: text,
          rect: rect,
          isVertical: vertical is bool
              ? vertical
              : inferSystemOcrVertical(rect),
          tile: tile is num ? tile.toInt() : null,
        ),
      );
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
