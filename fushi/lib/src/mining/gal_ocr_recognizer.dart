/// OCR 游戏模式用哪个识别器（spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §5）。
///
/// 跟「截屏识字」同一套引擎设置（默认跟随全局 OCR 引擎），只有一处不同：**Google Lens
/// 不用于连续识别**——它要把每一句的画面都上传，隐私与配额都不合适，所以解析到 Lens 时
/// 退成设备自带 OCR（Windows.Media.Ocr）。
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/local_screen_ocr.dart';
import 'package:fushi/src/ocr/screen_ocr_engine.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

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

/// 台词工作台「OCR 识别台词」的入口：按偏好（截屏识字的引擎设置 / 全局 OCR 引擎 / 识别
/// 语言）解析识别器，本机模型识别器用 [localService] 现建、跟会话走。
///
/// OCR 引擎、偏好解析与识别器装配都收在本文件（mining 层），台词工作台页面只调这一个
/// 入口再把结果交给 [GalHookSessionController.startOcrCapture]：页面同时是 galgame
/// 附着查词的宿主，查词扫描面不得直接 import OCR 包（`gal_attached_no_ocr_guard_test`）。
Future<GalOcrRecognizerResolution> resolveGalOcrRecognizerFromPrefs(
  PreferencesRepository prefs, {
  required MangaOcrService localService,
}) => resolveGalOcrRecognizer(
  setting: prefs.screenOcrEngine,
  global: MangaOcrEnginePreferenceKey.fromKey(prefs.mangaOcrEnginePreference),
  language: prefs.screenOcrLanguage,
  local: LocalScreenOcr(localService),
);

/// 解析失败是不是「本机模型没下载」（UI 据此给「去下载模型」而不是通用失败提示）。
bool galOcrModelMissing(GalOcrRecognizerResolution resolution) =>
    resolution.unavailableReason == kSystemOcrModelUnavailableReason;

/// 识别行 → 全文 + 逐字框（按平台给的阅读顺序，行间 `\n`；CJK 拼接交给 Rust 判定核心）。
///
/// 逐字框（BUG-5299 ②，游戏画面内嵌查词）与 `text.runes` 一一对应，每个字 `[l, t, r, b]`，
/// 坐标是送检图像素（与 [SystemOcrTextLine.rect] 同一空间）；行间的 `\n` 填空框。框怎么映回游戏
/// 客户区由 Rust 判定核心（撤放大、加裁框原点）与 [GalOcrLineSource]（截图 → 客户区）接着做。
GalOcrRecognition galOcrRecognitionOf(SystemOcrPageResult result) {
  final StringBuffer text = StringBuffer();
  final List<double> boxes = <double>[];
  for (final SystemOcrTextLine line in result.lines) {
    if (line.text.trim().isEmpty) continue;
    if (text.isNotEmpty) {
      text.write('\n');
      boxes.addAll(const <double>[0, 0, 0, 0]);
    }
    text.write(line.text);
    boxes.addAll(galOcrLineCharBoxes(line));
  }
  return GalOcrRecognition(
    text.toString(),
    charBoxes: Float32List.fromList(boxes),
  );
}

/// 一行里每个字（`line.text.runes`）的框，展平成 `[l, t, r, b, …]`。
///
/// 与截屏识字的逐字命中同一套估法（`screen_ocr_picker.dart`，BUG-4367）：落在平台词框
/// （[SystemOcrTextLine.segments]，Windows OCR 对日文多半逐字）里的字在词框内等分，其余在行框内
/// 按字数等分；竖排沿高度、横排沿宽度。
List<double> galOcrLineCharBoxes(SystemOcrTextLine line) {
  final List<int> starts = <int>[];
  final List<int> lengths = <int>[];
  int offset = 0;
  for (final int rune in line.text.runes) {
    final int length = rune > 0xFFFF ? 2 : 1;
    starts.add(offset);
    lengths.add(length);
    offset += length;
  }
  final int count = starts.length;
  final List<double> out = List<double>.filled(count * 4, 0);
  void put(int index, Rect rect, int slot, int slots) {
    final Rect box = line.isVertical
        ? Rect.fromLTWH(
            rect.left,
            rect.top + rect.height * slot / slots,
            rect.width,
            rect.height / slots,
          )
        : Rect.fromLTWH(
            rect.left + rect.width * slot / slots,
            rect.top,
            rect.width / slots,
            rect.height,
          );
    out
      ..[index * 4] = box.left
      ..[index * 4 + 1] = box.top
      ..[index * 4 + 2] = box.right
      ..[index * 4 + 3] = box.bottom;
  }

  final List<bool> placed = List<bool>.filled(count, false);
  for (final SystemOcrTextSegment segment in line.segments) {
    final List<int> members = <int>[
      for (int i = 0; i < count; i++)
        if (starts[i] >= segment.start &&
            starts[i] + lengths[i] <= segment.end &&
            !placed[i])
          i,
    ];
    for (int k = 0; k < members.length; k++) {
      put(members[k], segment.rect, k, members.length);
      placed[members[k]] = true;
    }
  }
  if (placed.contains(false)) {
    for (int i = 0; i < count; i++) {
      if (!placed[i]) put(i, line.rect, i, count);
    }
  }
  return out;
}

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
      recognize: (Uint8List rgba, int width, int height) async =>
          galOcrRecognitionOf(
            await local.recognizeRgba(rgba, width: width, height: height),
          ),
      unavailableReason: null,
    );
  }
  return (
    engine: engine,
    recognize: (Uint8List rgba, int width, int height) async =>
        galOcrRecognitionOf(
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
