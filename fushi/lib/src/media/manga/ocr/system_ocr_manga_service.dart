/// 用**设备自带的文字识别**跑一卷漫画。
///
/// 定位见 `system_ocr_channel.dart`：装完即用、完全离线、零上传，但对竖排气泡和
/// 手写体明显不如 manga-ocr。它是兜底档，不是主力。
///
/// 编排刻意照着 Google Lens 那条：同样的「当前页优先 → 逐页发布 → per-page 缓存
/// → 原子写 manga.json」。两者的差别只有一个——识别是发给云端还是问系统要。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:fushi_compute/fushi_compute.dart' show FfcImageFormat;
import 'package:fushi_engine/media/image_kernels.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart'
    show MangaOcrEngineId;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart'
    show GoogleLensPageCache;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart'
    show MangaOcrPageScheduler, OcrCancelledException;
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_page_tiling.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 单页识别超时。系统识别器正常是几百毫秒级，30 秒只用来兜住「彻底卡住」。
const Duration kSystemOcrPageTimeout = Duration(seconds: 30);

/// 系统 OCR 逐页缓存目录名的前缀（后接语言），签名与重开书恢复
/// （`manga_ocr_cache_recovery.dart`）共用这一个常量。
///
/// 前缀**带版本**。`v2`：切片识别 + 跨片合并（BUG-2767）。Apple 上旧结果只认出
/// 一成不到的字，签名不换的话，已经跑过的卷会一直命中那份缓存、永远拿不到新
/// 结果；恢复按这个前缀枚举目录，同样不会把 v1 的旧目录收进来。
const String kSystemOcrEngineSignaturePrefix = 'system_ocr_v2_';

/// 缓存目录名。带语言后缀，换语言不复用旧结果。
String systemOcrEngineSignature(String language) =>
    '$kSystemOcrEngineSignaturePrefix$language';

/// 系统 OCR 的整卷 runner。接口与 Lens 那条对齐，因此能直接接进
/// `manga_ocr_job_stream.dart` 的引擎分发。
abstract interface class SystemOcrMangaRunner {
  /// [focus]：运行中跟着读者当前页改道（[MangaOcrPageScheduler]）。
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage,
    bool onlyMissing,
    required String language,
    MangaOcrPageFocus? focus,
  });

  /// 识别一张已取到的页图（在线直读章的逐页识别用；不读写任何缓存）。
  Future<MokuroImage> recognizePageBytes(
    Uint8List bytes, {
    required String relativeUrl,
    required String language,
  });

  /// 识别一整页内存像素（视频暂停 OCR 的播放器截帧）：不经编码 / 平台解码，切片与跨片
  /// 合并同 [recognizePageBytes]。
  Future<MokuroImage> recognizePagePixels(
    OcrRgbaImage image, {
    required String relativeUrl,
    required String language,
  });

  /// 本机能不能用（决定引擎选项出不出现）。
  Future<bool> isAvailable();

  /// [language] 的识别模型 / Play 服务状态（BUG-4705）。只查询，不触发下载。
  ///
  /// [isAvailable] 只答「这个平台有没有系统 OCR」，选项因此恒保留；它答不了
  /// 「没有 Play 服务的 Android 设备上每页都会失败」——自动选引擎要靠这里。
  /// 没有模型概念的平台恒答 [SystemOcrModelStatus.ready]。
  Future<SystemOcrModelStatus> modelStatus({required String language});
}

/// [engine] 上的这次失败是不是「系统 OCR 没有可用模型 / Play 服务」（BUG-4705）。
///
/// 只认系统 OCR 引擎：本机模型的截屏识字同样借 [kSystemOcrModelUnavailableReason]
/// 报「本机模型没下载」，那不是 Play 服务的问题，不能被这里误判。
bool isSystemOcrModelUnavailableFailure(
  MangaOcrEngineId engine,
  Object error,
) =>
    engine == MangaOcrEngineId.systemOcr &&
    error is SystemOcrUnavailableException &&
    error.reason == kSystemOcrModelUnavailableReason;

class SystemOcrMangaService implements SystemOcrMangaRunner {
  SystemOcrMangaService({SystemOcrPixelPlatform? platform})
    : _platform = platform ?? const MethodChannelSystemOcr();

  final SystemOcrPixelPlatform _platform;

  @override
  Future<bool> isAvailable() => _platform.isAvailable();

  @override
  Future<SystemOcrModelStatus> modelStatus({required String language}) async {
    final SystemOcrPlatform platform = _platform;
    if (platform case final SystemOcrModelSetup setup) {
      return (await setup.modelStatus(language)).status;
    }
    return SystemOcrModelStatus.ready;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
    MangaOcrPageFocus? focus,
  }) {
    late final StreamController<MangaOcrVolumeEvent> controller;
    bool cancelled = false;
    controller = StreamController<MangaOcrVolumeEvent>(
      onListen: () {
        unawaited(() async {
          try {
            final String output = await _runFolder(
              imageDirPath: imageDirPath,
              startPage: startPage,
              onlyMissing: onlyMissing,
              language: language,
              focus: focus,
              isCancelled: () => cancelled || controller.isClosed,
              onProgress: (int done, int total, int pageIndex) {
                if (!controller.isClosed) {
                  controller.add(
                    MangaOcrVolumeEvent.page(
                      pagesDone: done,
                      pagesTotal: total,
                      pageIndex: pageIndex,
                    ),
                  );
                }
              },
            );
            if (!controller.isClosed) {
              final int pages = enumerateMangaPages(
                Directory(imageDirPath),
              ).length;
              controller.add(
                MangaOcrVolumeEvent.finished(
                  pagesTotal: pages,
                  mangaJsonPath: output,
                ),
              );
              await controller.close();
            }
          } on Object catch (error, stack) {
            if (!controller.isClosed) {
              controller.addError(error, stack);
              await controller.close();
            }
          }
        }());
      },
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }

  Future<String> _runFolder({
    required String imageDirPath,
    required int startPage,
    required bool onlyMissing,
    required String language,
    required MangaOcrPageFocus? focus,
    required bool Function() isCancelled,
    required void Function(int done, int total, int pageIndex) onProgress,
  }) async {
    final List<MangaOcrPageFile> pages = enumerateMangaPages(
      Directory(imageDirPath),
    );
    if (pages.isEmpty) {
      throw StateError('no images found in $imageDirPath');
    }
    final GoogleLensPageCache cache = GoogleLensPageCache(
      Directory(
        p.join(
          imageDirPath,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          systemOcrEngineSignature(language),
        ),
      ),
    );
    await cache.writeManifest(pages);

    // 当前页优先，扫到末页后绕回开头补齐。用户点的那一页最先出结果——这条
    // 顺序正是「点一下就查词」能成立的前提；读者翻页后跟着读者改道（[focus]）。
    final MangaOcrPageScheduler scheduler = MangaOcrPageScheduler(
      pages.length,
      startPage,
    );

    final List<MokuroImage?> results = List<MokuroImage?>.filled(
      pages.length,
      null,
    );
    int done = 0;
    while (true) {
      final int? focused = focus?.take();
      if (focused != null) scheduler.focus(focused);
      final int? pageIndex = scheduler.next();
      if (pageIndex == null) break;
      // 取消 = 抛出，不落整卷产物（与 Lens 同一语义）。已识别的页都在逐页缓存
      // 里，续跑从那里接；半卷的 `manga_ocr_out/manga.json` 只会让后来的引擎
      // 看到一份「空页占位 + 本引擎署名」的假整卷（BUG-4815）。
      if (isCancelled()) throw const OcrCancelledException();
      final MangaOcrPageFile page = pages[pageIndex];
      MokuroImage? image;
      if (onlyMissing) {
        image = await cache.read(pageIndex, page);
      }
      image ??= await _recognizePage(page, language);
      results[pageIndex] = image;
      // 先写缓存再报进度。顺序不能反：进度事件是 UI 热替换该页文字层的信号，
      // 而 UI 拿该页数据读的正是这个 per-page 缓存（见 mangaOcrSystemEvents）；
      // 先通知后落盘，热替换会读到空。
      //
      // 中途取消的成果也由这个缓存兜住，**不**逐页重写整份 manga.json——那是
      // 同一个目的的第二套持久化，而且是 O(n²)：200 页的卷、每份 json 几 MB，
      // 累计写入能到 GB 级。Lens 那条链同样只在最后写一次。
      await cache.write(pageIndex, page, image);
      done++;
      onProgress(done, pages.length, pageIndex);
    }

    if (isCancelled()) throw const OcrCancelledException();
    return _writePayload(imageDirPath, results.cast<MokuroImage>(), language);
  }

  Future<MokuroImage> _recognizePage(
    MangaOcrPageFile page,
    String language,
  ) async => recognizePageBytes(
    await page.file.readAsBytes(),
    relativeUrl: page.relativeUrl,
    language: language,
  );

  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List bytes, {
    required String relativeUrl,
    required String language,
  }) async {
    final Uint8List page = await systemOcrDecodableBytes(bytes);
    final List<OcrRect> tiles = planSystemOcrTiles(page);
    // 单页超时放在这里而不是各平台原生侧：一处约束胜过四份各写一遍的实现，
    // 而且原生侧加超时要处理「回调已经发过一次」的双重回复风险。卡住的那一页
    // 按失败结束整个任务，用户能重试；不设上限则是整卷无声吊死。
    final SystemOcrPageResult result = await _platform
        .recognize(
          page,
          language: language,
          tiles: <Rect>[
            for (final OcrRect tile in tiles)
              Rect.fromLTRB(tile.left, tile.top, tile.right, tile.bottom),
          ],
        )
        .timeout(kSystemOcrPageTimeout);
    return buildSystemOcrPage(relativeUrl, mergeSystemOcrTiles(result, tiles));
  }

  @override
  Future<MokuroImage> recognizePagePixels(
    OcrRgbaImage image, {
    required String relativeUrl,
    required String language,
  }) async {
    // 像素就在显示方向上，没有 EXIF 要转：切片直接按像素尺寸规划。
    final List<OcrRect> tiles = planOcrPageTiles(image.width, image.height);
    final SystemOcrPageResult result = await _platform
        .recognizePixels(
          image.rgba,
          width: image.width,
          height: image.height,
          language: language,
          tiles: <Rect>[
            for (final OcrRect tile in tiles)
              Rect.fromLTRB(tile.left, tile.top, tile.right, tile.bottom),
          ],
        )
        .timeout(kSystemOcrPageTimeout);
    return buildSystemOcrPage(relativeUrl, mergeSystemOcrTiles(result, tiles));
  }

  Future<String> _writePayload(
    String imageDirPath,
    List<MokuroImage> images,
    String language,
  ) async {
    final MokuroPayload payload = MokuroPayload(
      images: images,
      ocr: MangaOcrMetadata(
        engine: 'system_ocr',
        engineSignature: systemOcrEngineSignature(language),
        schemaVersion: 1,
        completedAt: DateTime.now().toUtc(),
      ),
    );
    final String output = p.join(
      imageDirPath,
      kMangaOcrOutDirName,
      kMangaOcrOutputFileName,
    );
    await File(output).parent.create(recursive: true);
    await writeMangaJsonAtomically(output, payload);
    return output;
  }
}

/// 系统 OCR 把页图字节交给平台自己的解码器（WIC / ImageIO / ImageDecoder），AVIF 在
/// 旧系统与没装 AV1 扩展的 Windows 上解不开，整页识别失败。认出 AVIF 就先在原生内核
/// （后台 isolate）转成 JPEG：irot / imir 已应用、不带 EXIF，切片与识别坐标都落在显示
/// 方向上——与导入时记录的页面尺寸同一坐标系。其余格式原样返回；转换失败也原样返回，
/// 由平台按原来的方式报错。
Future<Uint8List> systemOcrDecodableBytes(Uint8List bytes) async {
  if (probeImageNative(bytes)?.format != FfcImageFormat.avif) return bytes;
  final Uint8List? jpeg = await Isolate.run(
    () => encodeImageAsJpeg(bytes, quality: 95),
  );
  return jpeg ?? bytes;
}

/// 按页图的**原始像素尺寸**（只读文件头，不解码）规划切片。
///
/// 故意不用 `probeOrientedImageSize`：原生侧裁切的是未应用 EXIF 方向的像素
/// 缓冲（见 `FushiSystemOcr.swift` 类文档第 3 条），切片必须在同一个坐标系里。
/// 认不出尺寸就不切——整页识别是恒等的退路，不是错误。
List<OcrRect> planSystemOcrTiles(Uint8List bytes) {
  final img.DecodeInfo? info;
  try {
    info = img.findDecoderForData(bytes)?.startDecode(bytes);
  } on Object {
    return const <OcrRect>[];
  }
  if (info == null || info.width <= 0 || info.height <= 0) {
    return const <OcrRect>[];
  }
  return planOcrPageTiles(info.width, info.height);
}

/// 把逐片识别出的行合成整页结果（跨切线拼接 + 重叠区去重，见
/// `ocr_page_tiling.dart`）。平台没切片时原样返回。
SystemOcrPageResult mergeSystemOcrTiles(
  SystemOcrPageResult result,
  List<OcrRect> tiles,
) {
  if (tiles.isEmpty ||
      result.lines.every((SystemOcrTextLine line) => line.tile == null)) {
    return result;
  }
  final List<OcrTextLine> merged = mergeTiledOcrLines(<OcrTextLine>[
    for (final SystemOcrTextLine line in result.lines)
      OcrTextLine(
        text: line.text,
        rect: OcrRect(
          left: line.rect.left,
          top: line.rect.top,
          right: line.rect.right,
          bottom: line.rect.bottom,
        ),
        tile: line.tile,
      ),
  ], tiles);
  return SystemOcrPageResult(
    lines: <SystemOcrTextLine>[
      for (final OcrTextLine line in merged)
        () {
          final Rect rect = Rect.fromLTRB(
            line.rect.left,
            line.rect.top,
            line.rect.right,
            line.rect.bottom,
          );
          return SystemOcrTextLine(
            text: line.text,
            rect: rect,
            isVertical: inferSystemOcrVertical(rect),
          );
        }(),
    ],
    imageWidth: result.imageWidth,
    imageHeight: result.imageHeight,
  );
}

/// 把平台回传的行组装成一页 [MokuroImage]。
///
/// **一行一个 block**，不做几何聚类。这不是偷懒：Google Lens 也会把一个竖排气泡
/// 拆成好几列回来，展示层早就有一套「相邻列合成整句」的合并（见
/// `manga_overlay_html.dart` 的 sentence 合并）。再写第二套聚类只会得到两套在
/// 边界情况下不一致的实现。
MokuroImage buildSystemOcrPage(String relativeUrl, SystemOcrPageResult result) {
  final double width = result.imageWidth.toDouble();
  final double height = result.imageHeight.toDouble();
  final List<MokuroBlock> blocks = <MokuroBlock>[];
  for (int index = 0; index < result.lines.length; index++) {
    final SystemOcrTextLine line = result.lines[index];
    final MokuroRect rect = MokuroRect.fromLTRB(
      line.rect.left.clamp(0, width),
      line.rect.top.clamp(0, height),
      line.rect.right.clamp(0, width),
      line.rect.bottom.clamp(0, height),
    );
    if (rect.width <= 0 || rect.height <= 0) {
      continue;
    }
    blocks.add(
      MokuroBlock(
        rectangle: rect,
        isVertical: line.isVertical,
        // 复用回写路径那套面积均摊估算（带 clamp），不再写第二个 sqrt。字号只
        // 影响透明文字层的命中区域大小，估歪一点不影响能不能查词。
        fontSize: estimateMangaBlockFontSize(
          width: rect.width,
          height: rect.height,
          charCount: line.text.length,
        ),
        zIndex: index,
        lines: <String>[line.text],
      ),
    );
  }
  return MokuroImage(
    url: relativeUrl,
    size: MokuroSize(width, height),
    blocks: blocks,
  );
}
