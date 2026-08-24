/// 「重新识别框选区域」的**编排原语**：裁框 → 引擎链 → 区域替换回写。
///
/// 为什么单独一层：这条链上住着这个功能全部的数据安全性质——引擎起不来要零写入、
/// 引擎返回空块要零写入、被删的块必须被裁图完整覆盖、撤销要拿得到替换前的快照。
/// 这些性质原先散在 `manga_fushi_page.dart` 的一个 `State` 方法里，只能靠人眼守；
/// 收成这个不碰 UI、不碰 `BuildContext` 的函数之后，它们可以被直接测（见
/// `test/media/manga/ocr/manga_region_rescan_test.dart`）。
///
/// 引擎的**选取**仍在 `startMangaOcrWithPreferredEngine`（要 `BuildContext` 弹 Lens
/// 告知），由调用方以 [MangaRegionEngineStarter] 注入；本层只负责「拿到 job 之后怎么
/// 安全落盘」。
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_auto_start.dart';
import 'package:fushi/src/media/manga/ocr/manga_region_ocr.dart';

/// 在裁图目录上启动引擎链。返回 [MangaOcrAutoStartResult.cancelled] 表示「调用方自己
/// 放弃了」（页面已 dispose、用户在 Lens 告知里点了取消），不该再报错。
typedef MangaRegionEngineStarter = Future<MangaOcrAutoStartResult> Function(
  String imageDirPath,
);

/// 一次区域重识别的终局。
enum MangaRegionRescanStatus {
  /// 引擎不可用（没模型 / 系统 OCR 不可用 / 没有配对主机）。零写入。
  unavailable,

  /// 用户或调用方主动放弃。零写入、不该报错。
  cancelled,

  /// 引擎跑完但一个块都没认出来。零写入——把气泡认成「没字」再抹掉原文字层只会更糟。
  empty,

  /// 区域已替换并落盘。
  replaced,
}

/// [runMangaRegionRescan] 的结果。
///
/// [payload] / [previousPage] / [region] 只在 [MangaRegionRescanStatus.replaced]
/// 时非空；[previousPage] 是撤销用的替换前快照（喂给 `restoreMangaPage`）。
class MangaRegionRescanOutcome {
  const MangaRegionRescanOutcome.unavailable(this.unavailableReason)
      : status = MangaRegionRescanStatus.unavailable,
        payload = null,
        previousPage = null,
        region = null;

  const MangaRegionRescanOutcome.cancelled()
      : status = MangaRegionRescanStatus.cancelled,
        unavailableReason = null,
        payload = null,
        previousPage = null,
        region = null;

  const MangaRegionRescanOutcome.empty()
      : status = MangaRegionRescanStatus.empty,
        unavailableReason = null,
        payload = null,
        previousPage = null,
        region = null;

  const MangaRegionRescanOutcome.replaced({
    required MokuroPayload this.payload,
    required MokuroImage this.previousPage,
    required Rect this.region,
  })  : status = MangaRegionRescanStatus.replaced,
        unavailableReason = null;

  final MangaRegionRescanStatus status;

  /// 引擎不可用的人话原因（已本地化，可直接 toast）；引擎链没给原因时为 null。
  final String? unavailableReason;

  /// 落盘后的完整 payload。
  final MokuroPayload? payload;

  /// 被替换那一页的替换前快照。
  final MokuroImage? previousPage;

  /// 实际参与替换的裁图矩形（页图像素）。
  final Rect? region;
}

/// 跑一次「重新识别框选区域」。
///
/// - [box] 是用户框（页图像素）。真正的裁图矩形是
///   `clamp(expandMangaRegionToBlocks(box, pageBlocks))`——见 `manga_region_ocr.dart`
///   的不变量：**被删的块必然被裁图完整覆盖**。
/// - [pageBlocks] 是该页当前的旧块（用来算扩框），[mangaJsonPath] 才是真相源。
/// - [onEngineStarted] 在引擎确实起来之后调用一次（页面用它弹「识别中…」）。
/// - [onBeforeWriteback] 在落盘之前调用一次（页面用它取消在线几何 debounce：那个
///   定时器到期会把内存里的旧 payload 整份写回，插在落盘与 setState 之间就会把刚
///   回写的区域吞掉）。
/// - 临时目录无论走哪条分支都会删干净。
Future<MangaRegionRescanOutcome> runMangaRegionRescan({
  required String imagePath,
  required String mangaJsonPath,
  required int pageIndex,
  required Rect box,
  required List<MokuroBlock> pageBlocks,
  required MangaRegionEngineStarter startEngine,
  void Function()? onEngineStarted,
  void Function()? onBeforeWriteback,
  Directory? tempRoot,
}) async {
  final MangaRegionCrop crop = await cropMangaRegionToTempDir(
    imagePath: imagePath,
    box: expandMangaRegionToBlocks(box, pageBlocks),
    tempRoot: tempRoot,
  );
  try {
    final MangaOcrAutoStartResult start = await startEngine(crop.imageDir.path);
    if (!start.started) {
      return start.cancelled
          ? const MangaRegionRescanOutcome.cancelled()
          : MangaRegionRescanOutcome.unavailable(start.unavailableReason);
    }
    onEngineStarted?.call();
    final List<MokuroBlock> blocks = await collectMangaRegionOcrBlocks(
      start.job!.events,
      origin: crop.rect.topLeft,
    );
    if (blocks.isEmpty) {
      return const MangaRegionRescanOutcome.empty();
    }
    onBeforeWriteback?.call();
    final MangaRegionReplaceResult replaced = await replaceMangaBlocksInRegion(
      mangaJsonPath: mangaJsonPath,
      pageIndex: pageIndex,
      region: crop.rect,
      blocks: blocks,
    );
    return MangaRegionRescanOutcome.replaced(
      payload: replaced.payload,
      previousPage: replaced.previousPage,
      region: crop.rect,
    );
  } finally {
    await deleteMangaRegionCrop(crop.root);
  }
}
