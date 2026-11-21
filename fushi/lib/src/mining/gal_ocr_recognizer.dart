/// OCR 游戏模式用哪个识别器（spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §5）。
///
/// 跟「截屏识字」同一套引擎设置（默认跟随全局 OCR 引擎），只有一处不同：**Google Lens
/// 不用于连续识别**——它要把每一句的画面都上传，隐私与配额都不合适，所以解析到 Lens 时
/// 退成设备自带 OCR（Windows.Media.Ocr）。
library;

import 'dart:typed_data';

import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/ocr/local_screen_ocr.dart';
import 'package:fushi/src/ocr/screen_ocr_engine.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 解析结果：[recognize] 可用；或 [unavailableReason]（[kSystemOcrModelUnavailableReason]
/// 之类，UI 翻译成提示）。
typedef GalOcrRecognizerResolution = ({
  ScreenOcrEngine engine,
  GalOcrRecognize? recognize,
  String? unavailableReason,
});

/// OCR 游戏模式实际跑的引擎：截屏识字的解析结果里 Lens 换成设备自带。
ScreenOcrEngine galOcrEngineFor({
  required ScreenOcrEngineSetting setting,
  required MangaOcrEnginePreference global,
  required bool systemOcrSupported,
  required bool localModelReady,
}) {
  final ScreenOcrEngine resolved = resolveScreenOcrEngine(
    setting: setting,
    global: global,
    systemOcrSupported: systemOcrSupported,
    localModelReady: localModelReady,
  );
  if (resolved != ScreenOcrEngine.googleLens) return resolved;
  return systemOcrSupported
      ? ScreenOcrEngine.systemOcr
      : ScreenOcrEngine.localModel;
}

/// 识别行 → 全文（按平台给的阅读顺序，行间 `\n`；CJK 拼接交给 Rust 判定核心）。
String galOcrTextOf(SystemOcrPageResult result) => <String>[
  for (final SystemOcrTextLine line in result.lines)
    if (line.text.trim().isNotEmpty) line.text,
].join('\n');

/// 按设置解析识别器。[local] 是本机模型识别器（调用方持有、跟会话走）；[system] 默认
/// [MethodChannelSystemOcr]。本机模型被选中却没下载时返回 [kSystemOcrModelUnavailableReason]。
Future<GalOcrRecognizerResolution> resolveGalOcrRecognizer({
  required ScreenOcrEngineSetting setting,
  required MangaOcrEnginePreference global,
  required String language,
  required LocalScreenOcr local,
  SystemOcrPixelPlatform system = const MethodChannelSystemOcr(),
  bool? systemOcrSupported,
}) async {
  final bool hasSystem = systemOcrSupported ?? screenOcrHasSystemEngine;
  final bool localReady = await local.isAvailable();
  final ScreenOcrEngine engine = galOcrEngineFor(
    setting: setting,
    global: global,
    systemOcrSupported: hasSystem,
    localModelReady: localReady,
  );
  if (engine == ScreenOcrEngine.localModel) {
    if (!localReady) {
      return (
        engine: engine,
        recognize: null,
        unavailableReason: kSystemOcrModelUnavailableReason,
      );
    }
    return (
      engine: engine,
      recognize: (Uint8List rgba, int width, int height) async => galOcrTextOf(
        await local.recognizeRgba(rgba, width: width, height: height),
      ),
      unavailableReason: null,
    );
  }
  return (
    engine: engine,
    recognize: (Uint8List rgba, int width, int height) async => galOcrTextOf(
      await system.recognizePixels(
        rgba,
        width: width,
        height: height,
        language: language,
      ),
    ),
    unavailableReason: null,
  );
}
