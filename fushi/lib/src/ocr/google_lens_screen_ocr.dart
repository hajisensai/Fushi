/// 桌面应用外截屏识字的 Google Lens 识别器（反馈 Eemf0HOZhj：截屏识字的引擎设置选了
/// / 跟随到 Google Lens 时用它）。
///
/// 对外仍是 [SystemOcrPlatform]：冻结层、命中测试、查词那一整套不分引擎。上传同意
/// （`GoogleLensDisclosureScene.desktopScreens`）由宿主在截屏前问，这里不弹框。
///
/// Lens 一段（paragraph）一块、块文字是各显示行无分隔拼接（拉丁文行界补一个空格），
/// 字级框 [MokuroBlock.regions] 逐字给出——转成「一块一行 + 逐字词框」，点字按字框
/// 定位（`screenOcrHitTest` 的词框路径），跨显示行的段落也点得准。
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

class GoogleLensScreenOcr implements SystemOcrPlatform {
  const GoogleLensScreenOcr({
    required GoogleLensMangaOcrRunner runner,
    required this.lensLanguage,
  }) : _runner = runner;

  final GoogleLensMangaOcrRunner _runner;

  /// Lens 识别语言（OCR 设置里的「Lens 语言」）。截屏识字的 `language` 参数是给系统
  /// OCR 挑识别器的，Lens 跟随用户在 OCR 设置里给 Lens 选的语言。
  final String lensLanguage;

  /// Lens 不用下载、不挑平台；联网失败在 [recognize] 里报。
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
    List<Rect> tiles = const <Rect>[],
  }) async {
    final MokuroImage page = await _runner.recognizePageBytes(
      imageBytes,
      relativeUrl: 'screen',
      language: lensLanguage,
    );
    return systemOcrPageFromMokuro(page);
  }
}

/// Lens 的识别结果（Mokuro 形状）→ 冻结层要的行（截图像素）：一块一行，块框作行框，
/// 字级框作词框（[SystemOcrTextLine.segments]）。越界 / 无面积的字框丢掉；字框必须
/// 按行内顺序互不重叠，乱序的整块不带词框（退回按行等分），免得点字定位到错字。
@visibleForTesting
SystemOcrPageResult systemOcrPageFromMokuro(MokuroImage page) {
  final List<SystemOcrTextLine> lines = <SystemOcrTextLine>[];
  for (final MokuroBlock block in page.blocks) {
    final String text = block.lines.join();
    if (text.trim().isEmpty) continue;
    final MokuroRect box = block.rectangle;
    if (box.isEmpty) continue;
    lines.add(
      SystemOcrTextLine(
        text: text,
        rect: Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
        isVertical: block.isVertical,
        segments: _segmentsOf(block.regions, text.length),
      ),
    );
  }
  return SystemOcrPageResult(
    lines: lines,
    imageWidth: page.size.width.round(),
    imageHeight: page.size.height.round(),
  );
}

List<SystemOcrTextSegment> _segmentsOf(
  List<MangaOcrTextRegion>? regions,
  int textLength,
) {
  if (regions == null || regions.isEmpty) {
    return const <SystemOcrTextSegment>[];
  }
  final List<SystemOcrTextSegment> out = <SystemOcrTextSegment>[];
  int cursor = 0;
  for (final MangaOcrTextRegion region in regions) {
    final MokuroRect r = region.rectangle;
    if (r.isEmpty) continue;
    if (region.utf16Start < cursor ||
        region.utf16End <= region.utf16Start ||
        region.utf16End > textLength) {
      return const <SystemOcrTextSegment>[];
    }
    out.add(
      SystemOcrTextSegment(
        start: region.utf16Start,
        length: region.utf16End - region.utf16Start,
        rect: Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      ),
    );
    cursor = region.utf16End;
  }
  return out;
}
