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
/// - 「高级制卡」对话框里可以像漫画那样手动调卡图（反馈 mOe5HjBtuG）：
///   [screenOcrAdvancedMiningImageSection] 把这张截图交给漫画同款裁切分区
///   （`MangaCropFullscreenPage` / `MangaCropWorkspace`），预选框就是上面的自动裁切框；
///   用户的选择经 `MiningRequestOverrides`（crop / 打码 / 不要图）回到制卡路径，由
///   [resolveScreenOcrCardImagePlan] 决定这张卡最终怎么出图。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:fushi/src/floating_ball/screen_ocr_text_block.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart'
    show
        AdvancedMiningCropSource,
        AdvancedMiningMangaImageSection,
        MangaCropSuggestions;
import 'package:fushi/src/ocr/system_ocr_channel.dart' show SystemOcrTextLine;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show MiningImageCrop, MiningMosaicRegion, MiningRequestOverrides;
import 'package:fushi_engine/media/manga/manga_page_crop.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:path/path.dart' as p;

export 'package:fushi/src/floating_ball/screen_ocr_text_block.dart'
    show ScreenOcrLineBox, screenOcrTextBlockRect;

/// 一次点字带出来的卡图来源：识别用的那张图（内存字节或 Android 原生写的文件）+
/// 所点文字的文本块与行框（都是**那张图**的像素坐标）。
///
/// Android 的定格帧文件只活到下一次截屏（原生写新帧时清掉旧帧，缓存目录不无限长）：
/// 本实例第一次读到字节就留在内存里（[readBytes]），高级制卡分区与出卡图共用这一份，
/// 查词窗收到来源时就先读一次（`PopupDictionaryPage`），之后再截屏也不会让这张卡丢图。
class ScreenOcrCardImage {
  ScreenOcrCardImage({
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

  /// 第一次成功读到的定格帧字节（[path] 来源）。
  Uint8List? _readBack;

  /// 正在读的那一次：并发的读取共用它，不重复读盘。
  Future<Uint8List?>? _reading;

  /// 识别用的那张图的字节。文件来源第一次读成功后留在本实例里，之后不再读盘——
  /// 原生下一次截屏会删掉这个文件。读失败（文件还没写完 / 已被清掉）不记住，下次再读。
  Future<Uint8List?> readBytes() async {
    final Uint8List? inMemory = bytes ?? _readBack;
    if (inMemory != null) return inMemory;
    final String? file = path;
    if (file == null) return null;
    final Future<Uint8List?> reading = _reading ??= _readFile(file);
    final Uint8List? data = await reading;
    if (identical(_reading, reading)) _reading = null;
    if (data != null) _readBack = data;
    return data;
  }

  static Future<Uint8List?> _readFile(String file) async {
    try {
      return await File(file).readAsBytes();
    } on FileSystemException catch (error, stack) {
      // 截图文件已被下一次截屏清掉 / 缓存被系统回收：这张卡不带图，照常制。
      ErrorLogService.instance.log('ScreenOcrCardImage.read', error, stack);
      return null;
    }
  }
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

/// 截图在「高级制卡」裁切覆盖项里的页号：截屏识字只有一张图，恒为 0（漫画用它对账
/// 「裁的是哪一页」，这里用它拒收不是本分区产出的裁切）。
const int kScreenOcrCardCropPageIndex = 0;

/// 把像素矩形 [rect] 换成相对 [image] 的 0..1 归一化矩形（夹进图内）。
Rect _normalized(Rect rect, Size image) => Rect.fromLTRB(
  (rect.left / image.width).clamp(0.0, 1.0),
  (rect.top / image.height).clamp(0.0, 1.0),
  (rect.right / image.width).clamp(0.0, 1.0),
  (rect.bottom / image.height).clamp(0.0, 1.0),
);

/// 裁切分区的预选建议（反馈 mOe5HjBtuG）：[image] 是截图的像素尺寸（转正后），
/// 「这句话的位置」= 所点文本块，「文字周围」= 一键「+」本来会裁的那个框
/// （[screenOcrCardCropRect]），所以不动直接确认与一键「+」出同一张图。截图没有分镜。
MangaCropSuggestions screenOcrCropSuggestions(
  ScreenOcrCardImage source,
  Size image,
) {
  final Rect crop = screenOcrCardCropRect(
    textBlock: source.textBlock,
    line: source.line,
    image: image,
  );
  final Rect text = _normalized(source.textBlock, image);
  return MangaCropSuggestions(
    pageIndex: kScreenOcrCardCropPageIndex,
    pageSize: image,
    textRect: text.isEmpty ? null : text,
    textAreaRect: _normalized(crop, image),
  );
}

/// 「高级制卡」对话框里截图的裁切分区（漫画同款框选页，截图模式：无分镜）。图只读一次，
/// 预览与预选共用。
AdvancedMiningMangaImageSection screenOcrAdvancedMiningImageSection(
  ScreenOcrCardImage source,
) {
  Future<Uint8List?>? bytes;
  Future<Uint8List?> loadPage() => bytes ??= source.readBytes();

  Future<MangaCropSuggestions?> loadSuggestions() async {
    final Uint8List? data = await loadPage();
    if (data == null || data.isEmpty) return null;
    final ({int width, int height})? size = await mangaPageOrientedSizeAsync(
      data,
    );
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    return screenOcrCropSuggestions(
      source,
      Size(size.width.toDouble(), size.height.toDouble()),
    );
  }

  return AdvancedMiningMangaImageSection(
    loadPage: loadPage,
    loadSuggestions: loadSuggestions,
    panelModelAvailable: false,
    source: AdvancedMiningCropSource.screenshot,
  );
}

/// 这张卡的卡图怎么出。
enum ScreenOcrCardImageKind {
  /// 一键「+」：自动裁到所点文本块（[screenOcrCardCropRect]）。
  auto,

  /// 按对话框里框的 [ScreenOcrCardImagePlan.crop] 裁（含打码）。
  crop,

  /// 不要卡图。
  omit,
}

/// [resolveScreenOcrCardImagePlan] 的结果。
class ScreenOcrCardImagePlan {
  const ScreenOcrCardImagePlan(
    this.kind, {
    this.crop,
    this.mosaic = const <MiningMosaicRegion>[],
  });

  final ScreenOcrCardImageKind kind;

  /// 相对截图的 0..1 归一化框；只在 [ScreenOcrCardImageKind.crop] 时非 null。
  final Rect? crop;

  /// 打码区域（相对未裁切截图）；先打码再裁。
  final List<MiningMosaicRegion> mosaic;
}

/// 决定本次截屏识字制卡的卡图方案（纯函数，制卡入口同步读齐覆盖项再调）。
///
/// * 没有覆盖项（一键「+」）→ 自动裁到文本块。
/// * `omitImage`（对话框选了「不要」）→ 不要卡图。
/// * 有裁切且页号是截图的 → 按框裁（带打码）。
/// * 裁切页号不对（不是本分区产出）：没打码退回自动裁切；打了码就不要图——码的位置
///   对不上，退回自动裁切会把用户想遮住的东西原样送进卡片。没有裁切却有打码同理。
ScreenOcrCardImagePlan resolveScreenOcrCardImagePlan(
  MiningRequestOverrides? overrides,
) {
  if (overrides == null) {
    return const ScreenOcrCardImagePlan(ScreenOcrCardImageKind.auto);
  }
  if (overrides.omitImage) {
    return const ScreenOcrCardImagePlan(ScreenOcrCardImageKind.omit);
  }
  final MiningImageCrop? crop = overrides.crop;
  final List<MiningMosaicRegion> mosaic = overrides.mosaic;
  if (crop == null || crop.pageIndex != kScreenOcrCardCropPageIndex) {
    return ScreenOcrCardImagePlan(
      mosaic.isEmpty
          ? ScreenOcrCardImageKind.auto
          : ScreenOcrCardImageKind.omit,
    );
  }
  return ScreenOcrCardImagePlan(
    ScreenOcrCardImageKind.crop,
    crop: Rect.fromLTRB(crop.left, crop.top, crop.right, crop.bottom),
    mosaic: mosaic,
  );
}

/// 按 [source] 裁出卡图、按制卡图片质量档 [imageTier] 缩放编码，写进一个新临时目录。
/// [crop]（相对截图的 0..1 归一化框，高级制卡对话框里框的）为 null 时自动裁到文本块；
/// [mosaic] 先打码再裁。读图 / 解码失败返回 null（这张卡不带图）。调用方制卡后删 `dir`。
Future<({String path, Directory dir})?> writeScreenOcrCardImage(
  ScreenOcrCardImage source, {
  required int imageTier,
  Rect? crop,
  List<MiningMosaicRegion> mosaic = const <MiningMosaicRegion>[],
}) async {
  final Uint8List? bytes = await source.readBytes();
  if (bytes == null || bytes.isEmpty) return null;
  Directory? dir;
  try {
    final ({int width, int height})? size = await mangaPageOrientedSizeAsync(
      bytes,
    );
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    final Size image = Size(size.width.toDouble(), size.height.toDouble());
    final Rect box =
        crop ??
        _normalized(
          screenOcrCardCropRect(
            textBlock: source.textBlock,
            line: source.line,
            image: image,
          ),
          image,
        );
    final MiningMediaCompression compression = MiningMediaCompression.resolve(
      imageTier: imageTier,
      audioTier: 0,
    );
    final MangaPageCropResult? cropped = await cropMangaPageAsync(
      bytes,
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
      maxLongEdge: compression.screenshotMaxLongEdge,
      quality: compression.screenshotQuality,
      mosaic: mosaic,
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
