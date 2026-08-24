/// 漫画阅读页「重新识别框选区域」的能力层（`media/manga/ocr/`）。
///
/// 这条路径**不是第六个 OCR 引擎**：它把用户框出的矩形裁成一张单页图，放进一个
/// 临时目录，交给整卷 / 点击识别共用的那条引擎链（`startMangaOcrWithPreferredEngine`
/// → `mangaOcrBackgroundEvents`）去跑——本地 ONNX、系统 OCR、Google Lens、外部
/// mokuro、配对主机五个引擎因此零分支复用，引擎解析、可用性原因、Lens 上传告知
/// 全在那一处。本文件只做三件纯事：
///
/// 1. 裁框落盘（[cropMangaRegionToTempDir]）：clamp 进页内、整数像素、PNG。
/// 2. 结果块平移回页图坐标（[offsetMangaBlocks]）：块框、字符区域、行多边形一起移。
/// 3. 区域内旧块换新块（[replaceMangaPageRegion]）：判据是块被裁图矩形**完整覆盖**。
///
/// ## 「删哪些块」与「裁多大的图」必须是同一块像素
///
/// 用户框（[isMangaBlockInsideRegion]：块面积过半落在框内）只表达**意图**——它会
/// 圈中只有一部分落在框内的竖排气泡。若照着用户框裁图，那个气泡会被整条删掉、却只
/// 有框内那部分被重新识别，用户静默丢字。
///
/// 所以裁图矩形先经 [expandMangaRegionToBlocks] 扩成「用户框 ∪ 被它圈中的旧块框」
/// 的包围盒，落盘删块的判据再换成 [isMangaBlockCoveredByRegion]（完整落在裁图矩形
/// 内）。两者合起来给出一条不变量：**被删的块必然被裁图完整覆盖，因而必然被完整重新
/// 识别**——「部分重叠」这个边界情况被消掉，而不是加分支绕开。
///
/// 前身是只走本地识别器、弹结果卡片再手点「回写」的「框选识别」；它对默认引擎是
/// Lens 的用户装完即不可用（没模型），且识别结果不直接进文字层。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset, Rect;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 临时目录里承载裁图的**子目录**名。引擎链跑的是这个子目录：外部 mokuro 会把
/// `.mokuro` 产物写到被扫描目录的同级，放一层子目录才能让它落在临时根目录内、
/// 随根目录一起删干净。
const String kMangaRegionCropDirName = 'page';

/// 裁图文件名（PNG：无损，裁下来的气泡本来就小）。
const String kMangaRegionCropFileName = 'region.png';

/// 「块属于区域」的面积占比阈值：块面积过半落在框内即视为用户要重识别的块。
const double kMangaRegionBlockOverlapRatio = 0.5;

/// 一次裁框：临时根目录 + 引擎链要扫的子目录 + 实际裁出的页图像素矩形。
class MangaRegionCrop {
  const MangaRegionCrop({required this.root, required this.rect});

  /// 临时根目录；用完整棵删。
  final Directory root;

  /// 页图像素坐标下实际裁出的区域（整数边界、已 clamp 进页内）。结果块以它的
  /// 左上角为平移原点，区域替换也以它为准。
  final Rect rect;

  /// 交给引擎链扫描的目录（只含一张 [kMangaRegionCropFileName]）。
  Directory get imageDir =>
      Directory(p.join(root.path, kMangaRegionCropDirName));
}

/// 纯函数：把 [box] clamp 进 `pageWidth × pageHeight` 并落到整数像素
/// （left/top 向下取整，right/bottom 向上取整，至少 1px）。
Rect clampMangaRegion(Rect box, int pageWidth, int pageHeight) {
  final int maxX = pageWidth - 1;
  final int maxY = pageHeight - 1;
  final int left = box.left.floor().clamp(0, maxX);
  final int top = box.top.floor().clamp(0, maxY);
  final int right = box.right.ceil().clamp(left + 1, pageWidth);
  final int bottom = box.bottom.ceil().clamp(top + 1, pageHeight);
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// 纯函数：按 [clamped]（须来自 [clampMangaRegion]）从整页图裁出区域。
img.Image cropMangaRegion(img.Image page, Rect clamped) {
  return img.copyCrop(
    page,
    x: clamped.left.toInt(),
    y: clamped.top.toInt(),
    width: clamped.width.toInt(),
    height: clamped.height.toInt(),
  );
}

/// 把 [imagePath] 页图上的 [box] 裁成 `<临时根>/page/region.png`。
///
/// 解码 / 裁剪 / 编码整段放进 `Isolate.run`：页图动辄几 MB，在 UI isolate 解码会
/// 掉帧。[tempRoot] 缺省为系统临时目录（测试注入）。
Future<MangaRegionCrop> cropMangaRegionToTempDir({
  required String imagePath,
  required Rect box,
  Directory? tempRoot,
}) async {
  final Directory root = await (tempRoot ?? Directory.systemTemp)
      .createTemp('fushi_manga_region_');
  final String output =
      p.join(root.path, kMangaRegionCropDirName, kMangaRegionCropFileName);
  try {
    final Rect rect = await Isolate.run<Rect>(
      () => _cropToFile(imagePath: imagePath, box: box, outputPath: output),
    );
    return MangaRegionCrop(root: root, rect: rect);
  } catch (_) {
    await deleteMangaRegionCrop(root);
    rethrow;
  }
}

Future<Rect> _cropToFile({
  required String imagePath,
  required Rect box,
  required String outputPath,
}) async {
  // `decodeImage` 对认不出的字节通常返 null，但截断/垃圾文件也可能让某个格式
  // 探测器直接抛 RangeError；两种都是「这页图解不开」，对调用方必须是同一个错。
  img.Image? page;
  try {
    page = img.decodeImage(await File(imagePath).readAsBytes());
  } catch (error) {
    throw StateError('failed to decode manga page: $imagePath ($error)');
  }
  if (page == null) {
    throw StateError('failed to decode manga page: $imagePath');
  }
  final Rect clamped = clampMangaRegion(box, page.width, page.height);
  final File output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsBytes(
    img.encodePng(cropMangaRegion(page, clamped)),
    flush: true,
  );
  return clamped;
}

/// 删除裁框临时目录；不存在 / 删失败都吞掉（临时目录残留不该变成用户可见错误）。
Future<void> deleteMangaRegionCrop(Directory root) async {
  try {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  } catch (_) {}
}

/// 等引擎链在裁图目录上跑完，把结果页的块平移回页图坐标（原点 [origin] =
/// 裁出矩形的左上角）。流里没有 finished 事件（引擎中途收流）按失败抛出。
Future<List<MokuroBlock>> collectMangaRegionOcrBlocks(
  Stream<MangaOcrBackgroundEvent> events, {
  required Offset origin,
}) async {
  MangaOcrBackgroundEvent? finished;
  await for (final MangaOcrBackgroundEvent event in events) {
    if (event.finished) {
      finished = event;
    }
  }
  final String? resultPath = finished?.resultPath;
  if (finished == null || resultPath == null) {
    throw StateError('region OCR ended without a result file');
  }
  final String source = await File(resultPath).readAsString();
  final MokuroPayload result =
      finished.external ? parseMokuro(source) : parseMangaJson(source);
  if (result.images.isEmpty) {
    return const <MokuroBlock>[];
  }
  return offsetMangaBlocks(result.images.first.blocks, origin);
}

/// 纯函数：把裁图坐标系里的块整体平移 [origin]（块框、字符区域、行多边形一起）。
List<MokuroBlock> offsetMangaBlocks(List<MokuroBlock> blocks, Offset origin) {
  return <MokuroBlock>[
    for (final MokuroBlock block in blocks)
      MokuroBlock(
        rectangle: block.rectangle.shift(origin),
        isVertical: block.isVertical,
        fontSize: block.fontSize,
        zIndex: block.zIndex,
        lines: block.lines,
        linesCoords: block.linesCoords == null
            ? null
            : <List<List<double>>>[
                for (final List<List<double>> line in block.linesCoords!)
                  <List<double>>[
                    for (final List<double> point in line)
                      <double>[
                        point[0] + origin.dx,
                        point[1] + origin.dy,
                      ],
                  ],
              ],
        regions: block.regions == null
            ? null
            : <MangaOcrTextRegion>[
                for (final MangaOcrTextRegion region in block.regions!)
                  MangaOcrTextRegion(
                    rectangle: region.rectangle.shift(origin),
                    utf16Start: region.utf16Start,
                    utf16End: region.utf16End,
                  ),
              ],
      ),
  ];
}

/// 纯函数：块是否**被用户框圈中**——块面积过半落在 [region] 内（阈值
/// [kMangaRegionBlockOverlapRatio]）。零面积块退化为「左上角在区域内」。
///
/// 这只是**意图**判据（用户框到哪些块），只喂给 [expandMangaRegionToBlocks]。落盘删
/// 块用的是 [isMangaBlockCoveredByRegion]。
bool isMangaBlockInsideRegion(Rect block, Rect region) {
  final double blockArea = block.width * block.height;
  if (blockArea <= 0) {
    return region.contains(block.topLeft);
  }
  final Rect overlap = block.intersect(region);
  if (overlap.width <= 0 || overlap.height <= 0) {
    return false;
  }
  return overlap.width * overlap.height >=
      blockArea * kMangaRegionBlockOverlapRatio;
}

/// 纯函数：块是否被 [region] **完整覆盖**（左上闭、右下闭）。
///
/// 这是落盘删块的唯一判据。传进来的 [region] 是[裁图矩形][MangaRegionCrop.rect]，
/// 所以「被删」等价于「被裁图完整覆盖」⇒ 必然被完整重新识别，绝不会出现「删了一整
/// 条、只认回来一半」。
bool isMangaBlockCoveredByRegion(Rect block, Rect region) {
  return block.left >= region.left &&
      block.top >= region.top &&
      block.right <= region.right &&
      block.bottom <= region.bottom;
}

/// 纯函数：把用户框 [region] 扩成「[region] ∪ 被它圈中的旧块框」的包围盒。
///
/// 「圈中」用的是意图判据 [isMangaBlockInsideRegion]（面积过半）。只扩一轮、不迭代
/// 到不动点：包围盒本身是矩形，再迭代一轮就会把只擦到包围盒边的邻块也拉进来，密集
/// 页上会链式膨胀到整页——用户框一个气泡却整页被重识别，比部分重叠更糟。
///
/// 扩完的框仍要过 [clampMangaRegion] 才是最终裁图矩形（本函数不做 clamp：页图尺寸
/// 只有解码后才知道）。
Rect expandMangaRegionToBlocks(Rect region, List<MokuroBlock> pageBlocks) {
  Rect expanded = region;
  for (final MokuroBlock block in pageBlocks) {
    if (isMangaBlockInsideRegion(block.rectangle, region)) {
      expanded = expanded.expandToInclude(block.rectangle);
    }
  }
  return expanded;
}

/// 纯函数：用 [blocks] 替换 [page] 上被 [region] 完整覆盖的旧块。
///
/// [region] 必须是[裁图矩形][MangaRegionCrop.rect]（见本库文档的不变量）。区域外的
/// 块原样保留、保序在前；新块接在后面；z_index 按最终顺序重新编号（相对次序不变，
/// 编号连续）。
MokuroImage replaceMangaPageRegion(
  MokuroImage page,
  Rect region,
  List<MokuroBlock> blocks,
) {
  final List<MokuroBlock> merged = <MokuroBlock>[
    for (final MokuroBlock block in page.blocks)
      if (!isMangaBlockCoveredByRegion(block.rectangle, region)) block,
    ...blocks,
  ];
  return MokuroImage(
    url: page.url,
    size: page.size,
    blocks: <MokuroBlock>[
      for (int index = 0; index < merged.length; index++)
        MokuroBlock(
          rectangle: merged[index].rectangle,
          isVertical: merged[index].isVertical,
          fontSize: merged[index].fontSize,
          zIndex: index,
          lines: merged[index].lines,
          linesCoords: merged[index].linesCoords,
          regions: merged[index].regions,
        ),
    ],
  );
}
