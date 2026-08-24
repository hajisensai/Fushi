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
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart'
    show GoogleLensPageCache;
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 单页识别超时。系统识别器正常是几百毫秒级，30 秒只用来兜住「彻底卡住」。
const Duration kSystemOcrPageTimeout = Duration(seconds: 30);

/// 缓存目录名前缀。带语言后缀，换语言不复用旧结果。
String systemOcrEngineSignature(String language) => 'system_ocr_$language';

/// 系统 OCR 的整卷 runner。接口与 Lens 那条对齐，因此能直接接进
/// `manga_ocr_job_stream.dart` 的引擎分发。
abstract interface class SystemOcrMangaRunner {
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage,
    bool onlyMissing,
    required String language,
  });

  /// 本机能不能用（决定引擎选项出不出现）。
  Future<bool> isAvailable();
}

class SystemOcrMangaService implements SystemOcrMangaRunner {
  SystemOcrMangaService({SystemOcrPlatform? platform})
      : _platform = platform ?? const MethodChannelSystemOcr();

  final SystemOcrPlatform _platform;

  @override
  Future<bool> isAvailable() => _platform.isAvailable();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
    required String language,
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
              isCancelled: () => cancelled || controller.isClosed,
              onProgress: (int done, int total) {
                if (!controller.isClosed) {
                  controller.add(MangaOcrVolumeEvent.page(
                    pagesDone: done,
                    pagesTotal: total,
                  ));
                }
              },
            );
            if (!controller.isClosed) {
              final int pages =
                  enumerateMangaPages(Directory(imageDirPath)).length;
              controller.add(MangaOcrVolumeEvent.finished(
                pagesTotal: pages,
                mangaJsonPath: output,
              ));
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
    required bool Function() isCancelled,
    required void Function(int done, int total) onProgress,
  }) async {
    final List<MangaOcrPageFile> pages =
        enumerateMangaPages(Directory(imageDirPath));
    if (pages.isEmpty) {
      throw StateError('no images found in $imageDirPath');
    }
    final GoogleLensPageCache cache = GoogleLensPageCache(
      Directory(p.join(
        imageDirPath,
        kMangaOcrOutDirName,
        kMangaOcrPagesCacheDirName,
        systemOcrEngineSignature(language),
      )),
    );
    await cache.writeManifest(pages);

    // 当前页优先，扫到末页后绕回开头补齐。用户点的那一页最先出结果——这条
    // 顺序正是「点一下就查词」能成立的前提。
    final int start = startPage.clamp(0, pages.length - 1);
    final List<int> order = <int>[
      for (int index = start; index < pages.length; index++) index,
      for (int index = 0; index < start; index++) index,
    ];

    final Map<int, MokuroImage> results = <int, MokuroImage>{};
    int done = 0;
    for (final int pageIndex in order) {
      if (isCancelled()) {
        break;
      }
      final MangaOcrPageFile page = pages[pageIndex];
      MokuroImage? image;
      if (onlyMissing) {
        image = await cache.read(pageIndex, page);
      }
      image ??= await _recognizePage(page, language);
      results[pageIndex] = image;
      await cache.write(pageIndex, page, image);
      // 先落盘再报进度。顺序不能反：进度事件是 UI 热替换该页文字层的信号，
      // 收到信号就可能去读 manga.json——先通知后落盘，读到的是上一版。
      // 逐页落盘同时意味着中途取消也留得住已识别的部分，不用从头再来。
      await _writePayload(imageDirPath, pages, results, language);
      done++;
      onProgress(done, pages.length);
    }

    return _writePayload(imageDirPath, pages, results, language);
  }

  Future<MokuroImage> _recognizePage(
    MangaOcrPageFile page,
    String language,
  ) async {
    final Uint8List bytes = await page.file.readAsBytes();
    // 单页超时放在这里而不是各平台原生侧：一处约束胜过四份各写一遍的实现，
    // 而且原生侧加超时要处理「回调已经发过一次」的双重回复风险。卡住的那一页
    // 按失败结束整个任务，用户能重试；不设上限则是整卷无声吊死。
    final SystemOcrPageResult result = await _platform
        .recognize(bytes, language: language)
        .timeout(kSystemOcrPageTimeout);
    return buildSystemOcrPage(page.relativeUrl, result);
  }

  Future<String> _writePayload(
    String imageDirPath,
    List<MangaOcrPageFile> pages,
    Map<int, MokuroImage> results,
    String language,
  ) async {
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        for (int index = 0; index < pages.length; index++)
          results[index] ??
              MokuroImage(
                url: pages[index].relativeUrl,
                // 还没轮到的页先占位。尺寸未知时给 0——展示层按比例定位，
                // 空 blocks 不会用到它。
                size: Size.zero,
                blocks: const <MokuroBlock>[],
              ),
      ],
      ocr: MangaOcrMetadata(
        engine: 'system_ocr',
        engineSignature: systemOcrEngineSignature(language),
        schemaVersion: 1,
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

/// 把平台回传的行组装成一页 [MokuroImage]。
///
/// **一行一个 block**，不做几何聚类。这不是偷懒：Google Lens 也会把一个竖排气泡
/// 拆成好几列回来，展示层早就有一套「相邻列合成整句」的合并（见
/// `manga_overlay_html.dart` 的 sentence 合并）。再写第二套聚类只会得到两套在
/// 边界情况下不一致的实现。
MokuroImage buildSystemOcrPage(
  String relativeUrl,
  SystemOcrPageResult result,
) {
  final double width = result.imageWidth.toDouble();
  final double height = result.imageHeight.toDouble();
  final List<MokuroBlock> blocks = <MokuroBlock>[];
  for (int index = 0; index < result.lines.length; index++) {
    final SystemOcrTextLine line = result.lines[index];
    final Rect rect = Rect.fromLTRB(
      line.rect.left.clamp(0, width),
      line.rect.top.clamp(0, height),
      line.rect.right.clamp(0, width),
      line.rect.bottom.clamp(0, height),
    );
    if (rect.width <= 0 || rect.height <= 0) {
      continue;
    }
    blocks.add(MokuroBlock(
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
    ));
  }
  return MokuroImage(
    url: relativeUrl,
    size: Size(width, height),
    blocks: blocks,
  );
}
