/// 图形字幕 / 扩展抓图识别的结果值类型（帧、字、不可用原因）。
///
/// 单独成叶子库：浏览器扩展 API（`sync/fushi_extension_api_core.dart`）只需要
/// 这些值类型来回 JSON，不应经识别会话（[GraphicSubtitleOcrSession] 所在的
/// `graphic_subtitle_ocr.dart` → 漫画 OCR 引擎 → AppModel）把整条 sync API 接进
/// AppModel 的 import 环（守卫 `test/build/import_cycle_guard_test.dart`）。
library;

import 'dart:ui' show Rect, Size;

/// 识别不可用的原因（[GraphicSubtitleOcrUnavailable.reason]）。
enum GraphicSubtitleOcrUnavailableReason {
  /// 本机没有可用的 OCR 引擎。
  noEngine,

  /// 选中的是 Lens，用户拒绝了上传同意。
  lensDeclined,

  /// 当前平台不支持选中的引擎。
  unsupported,
}

/// [GraphicSubtitleOcrSession.recognize] 在引擎不可用时抛出。
class GraphicSubtitleOcrUnavailable implements Exception {
  const GraphicSubtitleOcrUnavailable(this.reason);

  final GraphicSubtitleOcrUnavailableReason reason;

  @override
  String toString() => 'GraphicSubtitleOcrUnavailable($reason)';
}

/// 一个可点的字：所属整句、句内字素下标、在**帧图像素**坐标系下的矩形。
typedef GraphicSubtitleOcrChar = ({
  String sentence,
  int graphemeIndex,
  Rect rect,
});

/// 一帧的识别结果：帧图尺寸 + 可点的字。
class GraphicSubtitleOcrFrame {
  const GraphicSubtitleOcrFrame({required this.imageSize, required this.chars});

  final Size imageSize;
  final List<GraphicSubtitleOcrChar> chars;

  bool get isEmpty => chars.isEmpty;
}
