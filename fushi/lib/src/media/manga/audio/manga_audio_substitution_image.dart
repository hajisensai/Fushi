/// 漫画 AI 上传副本：仅命中替换表的 OCR 块重绘，原始页图与 OCR 不落盘改写。
/// Flutter 负责系统字体排字；整页一次交 Rust 解码、合成与 JPEG 编码。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';

/// 该页是否需要重绘。跨 OCR 行的词与朗读端一样，拼接后只替换一次。
bool mangaPageHasSubstitutions(
  MokuroImage page,
  List<CastTextSubstitution> table,
) => page.blocks.any((MokuroBlock block) {
  final String text = block.lines.join();
  return applyCastSubstitutions(text, table) != text;
});

/// 上传副本；调用者只在 [mangaPageHasSubstitutions] 为真时走这里。
/// 坐标或图片无效、绘制失败时返回 null，绝不退回含旧字的原图。
Future<Uint8List?> prepareMangaSubstitutionImage({
  required Uint8List bytes,
  required MokuroImage page,
  required List<CastTextSubstitution> substitutions,
  int quality = 85,
}) async {
  final ({int width, int height})? size = await Isolate.run(() {
    final ({int width, int height, FfcImageFormat format})? info =
        FushiComputeImage.instance.probe(bytes);
    if (info == null) return null;
    return mangaAnnotateImageTarget(
          info.width.toDouble(),
          info.height.toDouble(),
        ) ??
        (width: info.width, height: info.height);
  });
  if (size == null) return null;
  final Uint8List? overlay = await renderMangaSubstitutionOverlay(
    page: page,
    width: size.width,
    height: size.height,
    substitutions: substitutions,
  );
  if (overlay == null) return null;
  return Isolate.run(
    () => FushiComputeImage.instance.compositeRgbaJpeg(
      bytes,
      overlay,
      width: size.width,
      height: size.height,
      quality: quality,
    ),
  );
}

/// 一页透明 straight RGBA 覆盖层：未命中的区域 alpha = 0，命中的整块先铺不透明白底。
/// 使用 OCR 元数据到实际上传尺寸的比例，不假设原图与 OCR 尺寸完全相等。
Future<Uint8List?> renderMangaSubstitutionOverlay({
  required MokuroImage page,
  required int width,
  required int height,
  required List<CastTextSubstitution> substitutions,
}) async {
  if (width <= 0 ||
      height <= 0 ||
      width > kMangaAnnotateImageMaxSide ||
      height > kMangaAnnotateImageMaxSide ||
      !page.size.width.isFinite ||
      !page.size.height.isFinite ||
      page.size.isEmpty) {
    return null;
  }
  final List<({MokuroBlock block, String text, ui.Rect rect})> changed =
      <({MokuroBlock block, String text, ui.Rect rect})>[];
  final ui.Rect bounds = ui.Rect.fromLTWH(
    0,
    0,
    width.toDouble(),
    height.toDouble(),
  );
  final double sx = width / page.size.width;
  final double sy = height / page.size.height;
  for (final MokuroBlock block in page.blocks) {
    final String original = block.lines.join();
    final String text = applyCastSubstitutions(original, substitutions);
    if (text == original) continue;
    ui.Rect rect = ui.Rect.fromLTRB(
      block.rectangle.left,
      block.rectangle.top,
      block.rectangle.right,
      block.rectangle.bottom,
    );
    // 某些 OCR 的行多边形超出块框；一起盖住，避免斜排字从块框边缘露出。
    for (final List<List<double>> line
        in block.linesCoords ?? const <List<List<double>>>[]) {
      for (final List<double> point in line) {
        if (point.length < 2 || !point[0].isFinite || !point[1].isFinite) {
          return null;
        }
        rect = rect.expandToInclude(ui.Rect.fromLTWH(point[0], point[1], 0, 0));
      }
    }
    for (final MangaOcrTextRegion region
        in block.regions ?? const <MangaOcrTextRegion>[]) {
      final MokuroRect r = region.bounds;
      if (!r.left.isFinite ||
          !r.top.isFinite ||
          !r.right.isFinite ||
          !r.bottom.isFinite) {
        return null;
      }
      rect = rect.expandToInclude(
        ui.Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      );
    }
    if (!rect.isFinite || rect.isEmpty) return null;
    rect = ui.Rect.fromLTRB(
      (rect.left * sx).floorToDouble() - 1,
      (rect.top * sy).floorToDouble() - 1,
      (rect.right * sx).ceilToDouble() + 1,
      (rect.bottom * sy).ceilToDouble() + 1,
    ).intersect(bounds);
    if (rect.isEmpty) return null;
    changed.add((block: block, text: text, rect: rect));
  }
  if (changed.isEmpty) return null;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  final ui.Paint background = ui.Paint()
    ..color = const ui.Color(0xffffffff)
    ..isAntiAlias = false;
  for (final ({MokuroBlock block, String text, ui.Rect rect}) item in changed) {
    canvas.drawRect(item.rect, background);
  }
  for (final ({MokuroBlock block, String text, ui.Rect rect}) item in changed) {
    if (item.text.isEmpty) continue;
    canvas.save();
    canvas.clipRect(item.rect);
    if (item.block.isVertical) {
      _paintVertical(canvas, item.rect, item.text);
    } else {
      _paintHorizontal(
        canvas,
        item.rect,
        item.text,
        item.block.fontSize * math.min(sx, sy),
      );
    }
    canvas.restore();
  }
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(width, height);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

ui.Paragraph _paragraph(String text, double size, double width) {
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textDirection: ui.TextDirection.ltr,
            textAlign: ui.TextAlign.center,
            fontSize: size,
            height: 1.1,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xff000000),
            fontSize: size,
            fontFamilyFallback: const <String>[
              'Noto Sans CJK JP',
              'Yu Gothic',
              'Hiragino Sans',
              'sans-serif',
            ],
          ),
        )
        ..addText(text);
  return builder.build()..layout(ui.ParagraphConstraints(width: width));
}

void _paintHorizontal(
  ui.Canvas canvas,
  ui.Rect rect,
  String text,
  double fontSize,
) {
  final double size = fontSize.isFinite && fontSize > 0
      ? math.min(fontSize, rect.height)
      : rect.height;
  final ui.Paragraph paragraph = _paragraph(text, size, rect.width);
  try {
    final double scale = math.min(1, rect.height / paragraph.height);
    canvas.save();
    canvas.translate(
      rect.center.dx - rect.width * scale / 2,
      rect.center.dy - paragraph.height * scale / 2,
    );
    canvas.scale(scale);
    canvas.drawParagraph(paragraph, ui.Offset.zero);
    canvas.restore();
  } finally {
    paragraph.dispose();
  }
}

void _paintVertical(ui.Canvas canvas, ui.Rect rect, String text) {
  final List<String> glyphs = text
      .replaceAll(RegExp(r'[\r\n]'), '')
      .characters
      .toList();
  if (glyphs.isEmpty) return;
  final int columns = math
      .sqrt(glyphs.length * rect.width / rect.height)
      .round()
      .clamp(1, glyphs.length);
  final int rows = (glyphs.length / columns).ceil();
  final double cell = math.min(rect.width / columns, rect.height / rows);
  final double left = rect.center.dx - columns * cell / 2;
  final double top = rect.center.dy - rows * cell / 2;
  for (int i = 0; i < glyphs.length; i++) {
    final int column = columns - 1 - i ~/ rows;
    final int row = i % rows;
    _paintHorizontal(
      canvas,
      ui.Rect.fromLTWH(left + column * cell, top + row * cell, cell, cell),
      glyphs[i],
      cell / 1.1,
    );
  }
}
