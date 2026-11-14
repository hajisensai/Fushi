/// 桌面应用外「截屏识字」用哪个 OCR 引擎（反馈 Eemf0HOZhj，BUG-4069）。
///
/// 和 AI 的「功能 → 提供商」同一个模型：截屏识字有自己的引擎设置，**默认跟随全局**
/// （「设置 → 模型 → OCR」的引擎偏好 `manga_ocr_engine_preference`，漫画 / 视频 /
/// 抓图取词 / 互联截屏都读它），想单独改的再选具体引擎。以前桌面截屏识字写死系统
/// OCR、不读这个偏好，用户在 OCR 设置里选了本机模型 / Google Lens 对截屏识字不生效。
///
/// 截屏识字只有三种引擎可用：本机模型（整帧当文字图：行检测 + 逐行识别）、设备自带
/// （macOS Vision / Windows.Media.Ocr；Linux 没有）、Google Lens（上传整张截图，要
/// 单独同意）。全局偏好里的外部 mokuro / 互联服务端 / 自动对截屏识字一律按「自动」
/// 解析：本机模型就绪用它，否则设备自带——与漫画 `auto` 同一口径（质量优先、不自作
/// 主张上传）。
library;

import 'dart:io';

import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';

/// 截屏识字实际要跑的引擎。
enum ScreenOcrEngine { localModel, systemOcr, googleLens }

/// 截屏识字的引擎设置（偏好 `screen_ocr.engine`，wire 值冻结）。
enum ScreenOcrEngineSetting {
  /// 跟随全局 OCR 引擎偏好（出厂默认）。
  followGlobal(''),
  localModel('local_onnx'),
  systemOcr('system_ocr'),
  googleLens('google_lens');

  const ScreenOcrEngineSetting(this.storageValue);

  /// 偏好里存的值；`''` = 跟随全局。
  final String storageValue;

  /// 不认识的值（旧版本 / 手改）按跟随全局处理。
  static ScreenOcrEngineSetting fromStorage(String raw) {
    for (final ScreenOcrEngineSetting value in values) {
      if (value.storageValue == raw) return value;
    }
    return followGlobal;
  }
}

/// 本平台的截屏识字有没有设备自带 OCR：macOS（Vision）/ Windows（Windows.Media.Ocr）
/// 有，Linux 没有（只能用本机模型或 Lens）。
bool get screenOcrHasSystemEngine => Platform.isMacOS || Platform.isWindows;

/// 全局 OCR 引擎偏好在截屏识字里对应的引擎（不看本机模型是否就绪）：null = 按
/// 「自动」解析（自动 / 外部 mokuro / 互联服务端）。设置页「跟随全局（…）」的标签
/// 据此显示。
ScreenOcrEngine? screenOcrEngineOfGlobal(
  MangaOcrEnginePreference global, {
  required bool systemOcrSupported,
}) => switch (global) {
  MangaOcrEnginePreference.googleLens => ScreenOcrEngine.googleLens,
  MangaOcrEnginePreference.systemOcr =>
    systemOcrSupported ? ScreenOcrEngine.systemOcr : ScreenOcrEngine.localModel,
  MangaOcrEnginePreference.localOnnx => ScreenOcrEngine.localModel,
  MangaOcrEnginePreference.auto ||
  MangaOcrEnginePreference.externalMokuro ||
  MangaOcrEnginePreference.pairedHost => null,
};

/// 解析这次截屏识字用哪个引擎。
///
/// - 单独指定的引擎照用（设备自带在没有系统 OCR 的平台上退成本机模型——设置页在
///   这类平台不提供这一项，这里只兜旧值 / 同步来的值）。
/// - 跟随全局：Lens / 设备自带照用；本机模型与「自动」类在本机模型没下载、而平台
///   有设备自带 OCR 时用设备自带——出厂全局偏好就是本机模型，没下载模型的桌面用户
///   截屏识字照旧开箱可用，而不是一上来就叫人下载模型。没有系统 OCR 的平台（Linux）
///   只能用本机模型，没下载时由识别器报「请先下载 OCR 模型」。
ScreenOcrEngine resolveScreenOcrEngine({
  required ScreenOcrEngineSetting setting,
  required MangaOcrEnginePreference global,
  required bool systemOcrSupported,
  required bool localModelReady,
}) {
  switch (setting) {
    case ScreenOcrEngineSetting.localModel:
      return ScreenOcrEngine.localModel;
    case ScreenOcrEngineSetting.systemOcr:
      return systemOcrSupported
          ? ScreenOcrEngine.systemOcr
          : ScreenOcrEngine.localModel;
    case ScreenOcrEngineSetting.googleLens:
      return ScreenOcrEngine.googleLens;
    case ScreenOcrEngineSetting.followGlobal:
      final ScreenOcrEngine? fromGlobal = screenOcrEngineOfGlobal(
        global,
        systemOcrSupported: systemOcrSupported,
      );
      if (fromGlobal == ScreenOcrEngine.googleLens ||
          fromGlobal == ScreenOcrEngine.systemOcr) {
        return fromGlobal!;
      }
      return localModelReady || !systemOcrSupported
          ? ScreenOcrEngine.localModel
          : ScreenOcrEngine.systemOcr;
  }
}
