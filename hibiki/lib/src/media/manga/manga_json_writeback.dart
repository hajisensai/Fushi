/// manga.json 回写（框选识别的「回写本页」动作 + 整卷 OCR 落盘的共同写侧）。
///
/// 读-改-写往返：`parseMangaJson` → 对应页追加 block → `mangaPayloadToJson` →
/// 原子落盘。追加保序（新块恒在本页 blocks 末尾，z_index = 追加前块数）。
///
/// 为什么要回写：识别结果落进 mokuro 格式的 `manga.json` 后，下次打开本书不必重跑
/// OCR，外部 mokuro 工具与其它设备读的是同一份真相源。
///
/// ## 两条不变量
///
/// 1. **并发串行化**：同一 manga.json 路径的**任何**写/删都必须经
///    [runExclusiveOnMangaJson]，否则读-改-写互相覆盖（丢更新），或两个写者踩同一个
///    per-path 固定名 `.tmp`。锁只在进程内、按规范化路径分桶；跨进程并发不在保护
///    范围（本 app 单进程持有书目录）。
///
///    全仓写/删 manga.json 的调用点（改动这张表时同步改
///    `manga_json_writeback_test.dart` 的锁覆盖守卫）：
///    - `appendMangaBlockToMangaJson`（框选回写，本文件，自带锁）
///    - `manga_hibiki_page.dart` 的 `_finishWholeVolumeOcr`（整卷 OCR 落盘）
///    - `manga_hibiki_page.dart` 的 `_persistOnlinePayloadGeometry`（在线几何回填）
///    - `manga_hibiki_page.dart` 的在线章节引导重写与 `_invalidateOnlineChapterPayload`
///    - `manga_ocr_wizard_dialog.dart` 的 `_writeManagedMangaJson`（向导对已入库书落盘）
///
///    其中向导那条是**整份覆写**：不进锁就会整段吞掉用户刚框选回写的块。
/// 2. **原子落盘**：先写 `<path>.tmp` 再 rename **直接覆盖**（不 delete），崩溃/断电
///    不会留下截断的 manga.json，也不会留下「目标暂时不存在」的窗口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 进程内 per-path 写锁（规范化路径 → 链尾 Future）。
final Map<String, Future<void>> _mangaJsonWriteChains =
    <String, Future<void>>{};

/// 同一 manga.json 的写操作串行化执行 [action]。
///
/// 链尾登记在第一个 `await` 之前**同步**完成，故并发调用严格排队；用
/// `whenComplete` 而非 `then` ⇒ 失败**不毒化链**（异常原样传给各自调用方，后继者
/// 照常放行）；清理链尾时用 `identical` 判定，避免误删后来者登记的链尾。
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

/// 原子落盘：先写同目录 `.tmp` 再 rename 覆盖 [mangaJsonPath]。
///
/// 直写 `writeAsString` 在写中途崩溃会留下截断的 JSON（整本 OCR 结果报废）；rename
/// 在同一文件系统上是原子的，读者要么看到旧文件、要么看到完整新文件。
///
/// **绝不先 `delete()` 再 rename**：那一步是整条路径上唯一破坏原子性的动作——delete
/// 与 rename 之间目标文件完全不存在，崩在这个窗口里整本 OCR 全丢。Dart 的
/// `File.rename` 在 Windows 上就能覆盖已存在的目标（实测 `RENAME_OVER_EXISTING: OK`），
/// POSIX 上更是天然覆盖，所以那步既危险又多余。守卫见
/// `manga_json_writeback_test.dart` 的「rename 直接覆盖」用例。
///
/// **调用方必须已持有 [runExclusiveOnMangaJson] 的锁**（本函数不自锁，以便读-改-写
/// 整体在同一临界区内）：`.tmp` 是 per-path 固定名，两个写者交叠会互相踩临时文件。
Future<void> writeMangaJsonAtomically(
  String mangaJsonPath,
  MokuroPayload payload,
) async {
  final File temporary = File('$mangaJsonPath.tmp');
  await temporary.writeAsString(
    jsonEncode(mangaPayloadToJson(payload)),
    flush: true,
  );
  await temporary.rename(mangaJsonPath);
}

/// 纯函数：回写块的 font_size 估算（页图像素单位）。
///
/// 面积均摊：`sqrt(框面积 / 字符数)`，clamp 到 `[8, min(宽, 高)]`——单行横排时不超
/// 框高、单列竖排时不超框宽；空文本按 1 字符算（不除零）。覆盖层渲染对 font_size
/// 只用于命中区域字号，估算偏差不致命。
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

/// 把一个识别块追加进 [mangaJsonPath] 的第 [pageIndex] 页并原子落盘，**返回落盘后
/// 的完整 payload**。
///
/// 返回值不是便利参数，是正确性要求：调用方若在锁外重读文件来刷新内存 payload，
/// 另一个写者（几何 debounce / 向导整份覆写）恰好插在中间时，读到的就是别人写的
/// 版本，刚追加的块会被无声吞掉。锁内已经有这份 payload，直接交出去，调用方不必
/// 也不应再读一次。
///
/// - [box]：页图像素坐标；[vertical]：竖排判定；[text]：识别文本（单行 lines）。
/// - z_index = 追加前该页块数（既有块保序，新块排最后）。
/// - 既有 `ocr` 元数据（引擎/签名/schema 版本）原样保留——抹掉它会让
///   `manga_ocr_cache_recovery.dart` 的同源判定失效，整卷缓存被判为异源作废。
/// - 页越界 / 文件缺失 / JSON 无该页 → [StateError]。
Future<MokuroPayload> appendMangaBlockToMangaJson({
  required String mangaJsonPath,
  required int pageIndex,
  required Rect box,
  required bool vertical,
  required String text,
}) {
  return runExclusiveOnMangaJson<MokuroPayload>(mangaJsonPath, () async {
    final File file = File(mangaJsonPath);
    if (!file.existsSync()) {
      throw StateError('manga.json not found: $mangaJsonPath');
    }
    final MokuroPayload payload = parseMangaJson(await file.readAsString());
    if (pageIndex < 0 || pageIndex >= payload.images.length) {
      throw StateError(
        'page $pageIndex out of range (${payload.images.length} pages)',
      );
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
    final MokuroPayload updated =
        MokuroPayload(images: images, ocr: payload.ocr);
    await writeMangaJsonAtomically(mangaJsonPath, updated);
    return updated;
  });
}
