/// 截屏识字 / 拍照查词制卡带图（反馈 Gz7z6Y6Mbr：「像漫画那样在卡片中添加截屏的
/// 图片」）。
///
/// 四条识字链路（Android MediaProjection、iOS 截自己窗口、拍照、桌面冻结层）点字时都
/// 手握识别用的那张图和 OCR 行框；这里把「卡图怎么取」收成一处：
///
/// - 取所点文字所在的**文本块**（Android 用 ML Kit 的 text block；其余平台只有行框，
///   按 [screenOcrTextBlockRect] 把相邻同向的行并成块），四周留白
///   （[screenOcrCardCropRect]），再按制卡图片质量档缩放编码——与漫画卡图同一个
///   裁切内核 [cropMangaPageAsync]、同一个 `AnkiMiningContext.coverPath` 通道。
/// - 偏好 `screen_ocr.card_image`（默认开）控制要不要带图；关掉时 Android 原生连截图
///   文件都不写。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:fushi/src/ocr/system_ocr_channel.dart' show SystemOcrTextLine;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/manga_page_crop.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:path/path.dart' as p;

/// 一次点字带出来的卡图来源：识别用的那张图（内存字节或 Android 原生写的文件）+
/// 所点文字的文本块与行框（都是**那张图**的像素坐标）。
class ScreenOcrCardImage {
  const ScreenOcrCardImage({
    this.bytes,
    this.path,
    required this.textBlock,
    required this.line,
  }) : assert(bytes != null || path != null);

  /// 识别用的那张图（iOS 截图 / 拍照 / 桌面截屏）。
  final Uint8List? bytes;

  /// Android：原生把定格帧写进 app 缓存目录的文件（查词窗在 `:popup` 进程，大图不走
  /// Intent，只传路径）。
  final String? path;

  /// 所点文字所在文本块（像素）。
  final Rect textBlock;

  /// 被点的那一行（像素），留白按它的粗细算。
  final Rect line;

  Future<Uint8List?> readBytes() async {
    final Uint8List? inMemory = bytes;
    if (inMemory != null) return inMemory;
    final String? file = path;
    if (file == null) return null;
    try {
      return await File(file).readAsBytes();
    } on FileSystemException catch (error, stack) {
      // 截图文件已被下一次截屏清掉 / 缓存被系统回收：这张卡不带图，照常制。
      ErrorLogService.instance.log('ScreenOcrCardImage.read', error, stack);
      return null;
    }
  }
}

/// 一行 OCR 结果在本模块眼里的样子（像素框 + 是否竖排）。
typedef ScreenOcrLineBox = ({Rect rect, bool vertical});

/// 只有行框的平台（Windows.Media.Ocr / Vision）把被点行 [hitIndex] 和与它同一段文字
/// 的行并成文本块：同向、粗细相近（0.6~1.6 倍）、在排列方向上相邻（行距不超过一个
/// 行粗）、在阅读方向上有重叠。逐步扩张，直到没有新行加入。
Rect screenOcrTextBlockRect({
  required List<ScreenOcrLineBox> lines,
  required int hitIndex,
}) {
  final ScreenOcrLineBox hit = lines[hitIndex];
  final bool vertical = hit.vertical;
  double thickness(Rect r) => vertical ? r.width : r.height;
  final double base = thickness(hit.rect);
  final Set<int> members = <int>{hitIndex};
  Rect block = hit.rect;
  bool grew = true;
  while (grew) {
    grew = false;
    for (int i = 0; i < lines.length; i++) {
      if (members.contains(i)) continue;
      final ScreenOcrLineBox line = lines[i];
      if (line.vertical != vertical) continue;
      final double t = thickness(line.rect);
      if (base <= 0 || t < base * 0.6 || t > base * 1.6) continue;
      final Rect r = line.rect;
      // 排列方向上的间隙（横排看上下，竖排看左右）。
      final double gap = vertical
          ? math.max(r.left - block.right, block.left - r.right)
          : math.max(r.top - block.bottom, block.top - r.bottom);
      if (gap > base) continue;
      // 阅读方向上要有重叠（横排看左右，竖排看上下）。
      final double overlap = vertical
          ? math.min(r.bottom, block.bottom) - math.max(r.top, block.top)
          : math.min(r.right, block.right) - math.max(r.left, block.left);
      if (overlap <= 0) continue;
      members.add(i);
      block = block.expandToInclude(r);
      grew = true;
    }
  }
  return block;
}

/// 只有行框的平台（iOS 截屏、拍照、桌面截屏）点中 [hit] 这一行时的卡图来源：图是识别
/// 用的那张 [bytes]，文本块按 [screenOcrTextBlockRect] 从全部行 [lines] 里并出来。
ScreenOcrCardImage screenOcrCardImageForHit({
  required Uint8List bytes,
  required List<SystemOcrTextLine> lines,
  required SystemOcrTextLine hit,
}) {
  final int hitIndex = math.max(0, lines.indexOf(hit));
  final Rect block = lines.isEmpty
      ? hit.rect
      : screenOcrTextBlockRect(
          lines: <ScreenOcrLineBox>[
            for (final SystemOcrTextLine line in lines)
              (rect: line.rect, vertical: line.isVertical),
          ],
          hitIndex: hitIndex,
        );
  return ScreenOcrCardImage(bytes: bytes, textBlock: block, line: hit.rect);
}

/// 卡图裁切框（像素）：文本块四周留白——取行粗的 1.5 倍与图短边 2% 的较大者，让字不
/// 贴边、带上一点周围画面——再夹进图内。
Rect screenOcrCardCropRect({
  required Rect textBlock,
  required Rect line,
  required Size image,
}) {
  final double lineThickness = math.min(line.width, line.height);
  final double pad = math.max(
    lineThickness * 1.5,
    math.min(image.width, image.height) * 0.02,
  );
  final Rect padded = textBlock.inflate(pad);
  final Rect bounds = Offset.zero & image;
  final Rect clamped = padded.intersect(bounds);
  return clamped.isEmpty ? bounds : clamped;
}

/// 按 [source] 裁出卡图、按制卡图片质量档 [imageTier] 缩放编码，写进一个新临时目录。
/// 读图 / 解码失败返回 null（这张卡不带图）。调用方制卡后删 `dir`。
Future<({String path, Directory dir})?> writeScreenOcrCardImage(
  ScreenOcrCardImage source, {
  required int imageTier,
}) async {
  final Uint8List? bytes = await source.readBytes();
  if (bytes == null || bytes.isEmpty) return null;
  Directory? dir;
  try {
    final ({int width, int height})? size = await mangaPageOrientedSizeAsync(
      bytes,
    );
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    final Rect crop = screenOcrCardCropRect(
      textBlock: source.textBlock,
      line: source.line,
      image: Size(size.width.toDouble(), size.height.toDouble()),
    );
    final MiningMediaCompression compression = MiningMediaCompression.resolve(
      imageTier: imageTier,
      audioTier: 0,
    );
    final MangaPageCropResult? cropped = await cropMangaPageAsync(
      bytes,
      left: crop.left / size.width,
      top: crop.top / size.height,
      right: crop.right / size.width,
      bottom: crop.bottom / size.height,
      maxLongEdge: compression.screenshotMaxLongEdge,
      quality: compression.screenshotQuality,
    );
    if (cropped == null) return null;
    dir = await Directory.systemTemp.createTemp('fushi_screen_ocr_card_');
    // 扩展名跟着真实编码走：两个 Anki 后端都按扩展名推导媒体类型。
    final File out = File(p.join(dir.path, 'card.${cropped.extension}'));
    await out.writeAsBytes(cropped.bytes, flush: true);
    return (path: out.path, dir: dir);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('ScreenOcrCardImage.write', error, stack);
    if (dir != null) await deleteScreenOcrCardDir(dir);
    return null;
  }
}

/// 制卡结束后删掉 [writeScreenOcrCardImage] 建的临时目录（Anki 后端已拷走媒体）。
Future<void> deleteScreenOcrCardDir(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException catch (error, stack) {
    ErrorLogService.instance.log('ScreenOcrCardImage.cleanup', error, stack);
  }
}
