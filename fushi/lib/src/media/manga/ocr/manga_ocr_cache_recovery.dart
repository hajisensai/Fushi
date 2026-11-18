import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart'
    show kSystemOcrEngineSignaturePrefix;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 用 [GoogleLensPageCache] 格式写逐页缓存的引擎 → 缓存目录名前缀（后接语言）。
///
/// 重开书恢复按这张表枚举缓存目录。新增一个写这种逐页缓存的引擎时在这里加
/// 一行；漏了的后果是该引擎被杀进程 / 取消后的成果重开书读不回来（BUG-4827）。
/// 前缀都带版本号：换签名作废的旧目录（例如系统 OCR 的 v1）不会被收回来。
const Map<MangaOcrEngineId, String> kMangaOcrPageJsonCachePrefixes =
    <MangaOcrEngineId, String>{
      MangaOcrEngineId.googleLens: kGoogleLensEngineSignaturePrefix,
      MangaOcrEngineId.systemOcr: kSystemOcrEngineSignaturePrefix,
    };

/// [directoryName]（`manga_ocr_out/_pages/` 下的子目录名）是不是某个已知引擎的
/// 逐页 JSON 缓存目录。
bool isMangaOcrPageJsonCacheDirectory(String directoryName) =>
    kMangaOcrPageJsonCachePrefixes.values.any(directoryName.startsWith);

/// A non-network reconstruction of the pages already completed by incremental
/// OCR engines.
///
/// The formal `manga.json` is intentionally replaced only after a complete
/// volume succeeds. Until then each engine's atomic page cache is the source of
/// truth. Reopening a book therefore has to merge those valid caches back into
/// otherwise-empty pages so lookup remains available without restarting OCR.
class MangaOcrCacheRecovery {
  const MangaOcrCacheRecovery({
    required this.payload,
    required this.recoveredPageIndices,
  });

  final MokuroPayload payload;
  final List<int> recoveredPageIndices;
}

/// [localEngineSignature] 是本地 ONNX 引擎的缓存子目录名。默认按本机**已安装模型**
/// 解析（含内容指纹），只恢复与当前模型同源的页；测试可直接传入固定签名
/// （BUG-1173）。
Future<MangaOcrCacheRecovery> recoverCachedMangaOcr({
  required String managedDirectory,
  required MokuroPayload basePayload,
  String? localEngineSignature,
}) async {
  final List<MangaOcrPageFile> pages = enumerateMangaPages(
    Directory(managedDirectory),
  );
  if (pages.isEmpty || basePayload.images.isEmpty) {
    return MangaOcrCacheRecovery(
      payload: basePayload,
      recoveredPageIndices: const <int>[],
    );
  }

  final Directory cacheRoot = Directory(
    p.join(managedDirectory, kMangaOcrOutDirName, kMangaOcrPagesCacheDirName),
  );
  // 生产调用方（阅读器重开）在本地服务是 MangaOcrPageService 时总会传入按已选
  // 模型解析的签名；只有拿不到服务签名时才走这里，此处没有已选模型可用，按默认
  // 模型解析。
  final String localSignature =
      localEngineSignature ??
      await resolveInstalledLocalMangaOcrEngineSignature();
  final Directory localDirectory = Directory(
    p.join(cacheRoot.path, localSignature),
  );
  // 逐页 JSON 缓存的引擎签名都带语言后缀（`<前缀><lang>`），同一卷可能有多个
  // 引擎、多个语言的缓存目录并存；全部纳入候选，逐页按文件时间取最新。
  final List<Directory> pageJsonDirectories = cacheRoot.existsSync()
      ? cacheRoot
            .listSync()
            .whereType<Directory>()
            .where(
              (Directory directory) =>
                  isMangaOcrPageJsonCacheDirectory(p.basename(directory.path)),
            )
            .toList(growable: false)
      : const <Directory>[];
  final MangaOcrFilePageCache localCache = MangaOcrFilePageCache(
    cacheDir: localDirectory,
    pageNames: <String>[
      for (final MangaOcrPageFile page in pages) page.relativeUrl,
    ],
    pageFiles: <File>[for (final MangaOcrPageFile page in pages) page.file],
  );
  final List<GoogleLensPageCache> pageJsonCaches = <GoogleLensPageCache>[
    for (final Directory directory in pageJsonDirectories)
      GoogleLensPageCache(directory),
  ];

  final List<MokuroImage> images = List<MokuroImage>.of(basePayload.images);
  final Map<String, int> payloadIndexByUrl = <String, int>{
    for (int index = 0; index < images.length; index++)
      normalizeMangaUrl(images[index].url): index,
  };
  final List<int> recovered = <int>[];

  for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final int? payloadIndex =
        payloadIndexByUrl[normalizeMangaUrl(pages[pageIndex].relativeUrl)];
    if (payloadIndex == null || images[payloadIndex].blocks.isNotEmpty) {
      continue;
    }

    final OcrPageResult? local = await localCache.read('manga_ocr', pageIndex);
    // 候选统一成 (mtime, page) 再取最新，本地 / 各引擎各语言的逐页缓存无特殊分支。
    final List<(DateTime, MokuroImage)> candidates =
        <(DateTime, MokuroImage)>[];
    if (local != null) {
      final File localFile = File(
        p.join(
          localDirectory.path,
          ocrPageCacheFileName(pages[pageIndex].relativeUrl),
        ),
      );
      candidates.add((
        (await localFile.stat()).modified,
        _localPage(pages[pageIndex], local),
      ));
    }
    for (final GoogleLensPageCache cache in pageJsonCaches) {
      final MokuroImage? cached = await cache.read(pageIndex, pages[pageIndex]);
      if (cached == null) continue;
      final File cachedFile = File(
        p.join(
          cache.directory.path,
          '${pageIndex.toString().padLeft(6, '0')}.json',
        ),
      );
      candidates.add(((await cachedFile.stat()).modified, cached));
    }
    if (candidates.isEmpty) {
      continue;
    }
    // 严格更新才换人：mtime 打平时保留先入队者（本地缓存在前，维持旧行为）。
    (DateTime, MokuroImage) newest = candidates.first;
    for (final (DateTime, MokuroImage) candidate in candidates.skip(1)) {
      if (candidate.$1.isAfter(newest.$1)) newest = candidate;
    }

    images[payloadIndex] = newest.$2;
    recovered.add(payloadIndex);
  }

  return MangaOcrCacheRecovery(
    payload: MokuroPayload(images: images, ocr: basePayload.ocr),
    recoveredPageIndices: recovered,
  );
}

MokuroImage _localPage(MangaOcrPageFile page, OcrPageResult result) =>
    buildMangaPayloadFromResults(
      <MangaOcrPageFile>[page],
      <OcrPageResult>[result],
    ).images.single;
