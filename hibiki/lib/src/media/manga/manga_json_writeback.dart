/// manga.json 单块回写（P4 单框补扫的「回写本页」动作）。
///
/// 读-改-写往返：`parseMangaJson` → 对应页追加 block → `mangaPayloadToJson` →
/// 落盘。追加保序（新块恒在本页 blocks 末尾，z_index = 追加前块数）。
///
/// 并发保护（简单文件级）：同一 manga.json 路径的写操作经进程内 Future 链串行
/// 化，防止并发追加互相覆盖（读-改-写丢更新）。跨进程并发不在保护范围（本
/// app 单进程持有书目录）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mokuro_payload.dart';

/// 进程内 per-path 写锁（规范化路径 → 链尾 Future）。
final Map<String, Future<void>> _mangaJsonWriteChains =
    <String, Future<void>>{};

/// 同一 manga.json 的写操作串行化执行 [action]（错误传给调用方、不毒化链）。
Future<T> runExclusiveOnMangaJson<T>(
  String mangaJsonPath,
  Future<T> Function() action,
) {
  final String key = p.canonicalize(mangaJsonPath);
  final Future<void> previous =
      _mangaJsonWriteChains[key] ?? Future<void>.value();
  final Completer<void> gate = Completer<void>();
  _mangaJsonWriteChains[key] = gate.future;
  return previous.then((_) => action()).whenComplete(() {
    gate.complete();
    if (identical(_mangaJsonWriteChains[key], gate.future)) {
      _mangaJsonWriteChains.remove(key);
    }
  });
}

/// 纯函数：回写块的 font_size 估算（页图像素单位）。
///
/// 面积均摊：`sqrt(框面积 / 字符数)`，clamp 到 [8, min(宽, 高)]——单行横排时
/// 不超框高、单列竖排时不超框宽；空文本按 1 字符算。覆盖层渲染对 font_size
/// 只用于命中区域字号（ERRATA M1 有非零下限兜底），估算偏差不致命。
double estimateMangaBlockFontSize({
  required double width,
  required double height,
  required int charCount,
}) {
  final double w = math.max(1.0, width);
  final double h = math.max(1.0, height);
  final int chars = math.max(1, charCount);
  final double bySqrt = math.sqrt(w * h / chars);
  return bySqrt.clamp(8.0, math.max(8.0, math.min(w, h)));
}

/// 把一个识别块追加进 [mangaJsonPath] 的第 [pageIndex] 页并落盘。
///
/// - [box]：页图像素坐标；[vertical]：竖排判定；[text]：识别文本（单行 lines）。
/// - z_index = 追加前该页块数（既有块保序，新块排最后）。
/// - 页越界 / 文件缺失 / JSON 无该页 → [StateError]。
Future<void> appendMangaBlockToMangaJson({
  required String mangaJsonPath,
  required int pageIndex,
  required Rect box,
  required bool vertical,
  required String text,
}) {
  return runExclusiveOnMangaJson<void>(mangaJsonPath, () async {
    final File file = File(mangaJsonPath);
    if (!file.existsSync()) {
      throw StateError('manga.json not found: $mangaJsonPath');
    }
    final MokuroPayload payload = parseMangaJson(await file.readAsString());
    if (pageIndex < 0 || pageIndex >= payload.images.length) {
      throw StateError(
          'page $pageIndex out of range (${payload.images.length} pages)');
    }
    final MokuroImage page = payload.images[pageIndex];
    final MokuroBlock block = MokuroBlock(
      rectangle: box,
      isVertical: vertical,
      fontSize: estimateMangaBlockFontSize(
        width: box.width,
        height: box.height,
        charCount: text.length,
      ),
      zIndex: page.blocks.length,
      lines: <String>[text],
    );
    final List<MokuroImage> images = List<MokuroImage>.of(payload.images);
    images[pageIndex] = MokuroImage(
      url: page.url,
      size: page.size,
      blocks: <MokuroBlock>[...page.blocks, block],
    );
    final String json =
        jsonEncode(mangaPayloadToJson(MokuroPayload(images: images)));
    await file.writeAsString(json, flush: true);
  });
}
