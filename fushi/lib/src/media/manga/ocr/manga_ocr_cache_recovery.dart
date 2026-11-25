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
///
/// 「空页」也可能是整卷结果判定的无字页：一卷先用引擎 A 跑过一部分、后来换引擎 B
/// 整卷跑完，B 判无字的页不能被 A 更早留下的逐页缓存填回来。所以回填只收
/// [isMangaOcrCacheEligibleForRecovery] 放行的缓存：与 manga.json 同引擎（同签名）
/// 的，或比整卷结果落盘更新的（拍板 design-nmv-ocr-cache-rule 方案 b：不删别的
/// 引擎的缓存，切回去仍可复用）。
class MangaOcrCacheRecovery {
  const MangaOcrCacheRecovery({
    required this.payload,
    required this.recoveredPageIndices,
  });

  final MokuroPayload payload;
  final List<int> recoveredPageIndices;
}

/// 逐页缓存（目录名 [cacheSignature]、文件修改时间 [cachedAt]）能不能回填进
/// 整卷结果 [formal] 里的空页。
///
/// - 还没有整卷结果（[formal] 为 null）：空页就是没识别过，全部放行。
/// - 同引擎同签名：整卷结果本来就由这份缓存组装，判无字的页它也是无字，放行。
/// - 别的引擎 / 语言：只有比整卷落盘时刻 [formalAt] 严格更新才放行（整卷之后又
///   换引擎跑了一部分）；拿不到落盘时刻时按「不更新」处理——宁可留空页让用户
///   重认，也不把过期文字冒充整卷结果。
bool isMangaOcrCacheEligibleForRecovery({
  required MangaOcrMetadata? formal,
  required DateTime? formalAt,
  required String cacheSignature,
  required DateTime cachedAt,
}) {
  if (formal == null) return true;
  if (cacheSignature == formal.engineSignature) return true;
  return formalAt != null && cachedAt.isAfter(formalAt);
}

/// [localEngineSignature] 是本地 ONNX 引擎的缓存子目录名。默认按本机**已安装模型**
/// 解析（含内容指纹），只恢复与当前模型同源的页；测试可直接传入固定签名
/// （BUG-1173）。
///
/// [mangaJsonPath] 是 [basePayload] 所在的 manga.json：整卷元数据没记落盘时刻
/// （[MangaOcrMetadata.completedAt] 之前写的旧卷）时，退回用它的修改时间当整卷
/// 落盘时刻。之后的读-改-写只会让这个时刻偏晚，偏向「不回填」，不会放出过期缓存。
Future<MangaOcrCacheRecovery> recoverCachedMangaOcr({
  required String managedDirectory,
  required MokuroPayload basePayload,
  required String mangaJsonPath,
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

  final MangaOcrMetadata? formal = basePayload.ocr;
  final DateTime? formalAt = formal == null
      ? null
      : formal.completedAt ?? await _modifiedOrNull(File(mangaJsonPath));
  bool eligible(String cacheSignature, DateTime cachedAt) =>
      isMangaOcrCacheEligibleForRecovery(
        formal: formal,
        formalAt: formalAt,
        cacheSignature: cacheSignature,
        cachedAt: cachedAt,
      );

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

    // 候选统一成 (mtime, page) 再取最新，本地 / 各引擎各语言的逐页缓存无特殊分支。
    // 先按文件时间过资格判据，不合格的缓存不读不解析。
    final List<(DateTime, MokuroImage)> candidates =
        <(DateTime, MokuroImage)>[];
    final DateTime? localAt = await _modifiedOrNull(
      File(
        p.join(
          localDirectory.path,
          ocrPageCacheFileName(pages[pageIndex].relativeUrl),
        ),
      ),
    );
    if (localAt != null && eligible(localSignature, localAt)) {
      final OcrPageResult? local = await localCache.read(
        'manga_ocr',
        pageIndex,
      );
      if (local != null) {
        candidates.add((localAt, _localPage(pages[pageIndex], local)));
      }
    }
    for (final GoogleLensPageCache cache in pageJsonCaches) {
      final DateTime? cachedAt = await _modifiedOrNull(
        File(
          p.join(
            cache.directory.path,
            '${pageIndex.toString().padLeft(6, '0')}.json',
          ),
        ),
      );
      if (cachedAt == null ||
          !eligible(p.basename(cache.directory.path), cachedAt)) {
        continue;
      }
      final MokuroImage? cached = await cache.read(pageIndex, pages[pageIndex]);
      if (cached != null) candidates.add((cachedAt, cached));
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

/// 文件的修改时间；不存在 / 读不到返回 null。
Future<DateTime?> _modifiedOrNull(File file) async {
  try {
    final FileStat stat = await file.stat();
    return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
  } on FileSystemException {
    return null;
  }
}

MokuroImage _localPage(MangaOcrPageFile page, OcrPageResult result) =>
    buildMangaPayloadFromResults(
      <MangaOcrPageFile>[page],
      <OcrPageResult>[result],
    ).images.single;
