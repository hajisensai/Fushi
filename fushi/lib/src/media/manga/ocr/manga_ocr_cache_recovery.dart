import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_model_fingerprint.dart';
import 'package:fushi/src/ocr/ocr_types.dart';

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
  final List<MangaOcrPageFile> pages =
      enumerateMangaPages(Directory(managedDirectory));
  if (pages.isEmpty || basePayload.images.isEmpty) {
    return MangaOcrCacheRecovery(
      payload: basePayload,
      recoveredPageIndices: const <int>[],
    );
  }

  final Directory cacheRoot = Directory(p.join(
    managedDirectory,
    kMangaOcrOutDirName,
    kMangaOcrPagesCacheDirName,
  ));
  final String localSignature = localEngineSignature ??
      await resolveInstalledLocalMangaOcrEngineSignature();
  final Directory localDirectory =
      Directory(p.join(cacheRoot.path, localSignature));
  // Lens 签名带语言后缀（`google-lens-v2-niratan-<lang>`），同一卷可能有多个
  // 语言的缓存目录并存；全部纳入候选，逐页按文件时间取最新。
  final List<Directory> lensDirectories = cacheRoot.existsSync()
      ? cacheRoot
          .listSync()
          .whereType<Directory>()
          .where((Directory directory) => p
              .basename(directory.path)
              .startsWith(kGoogleLensEngineSignaturePrefix))
          .toList(growable: false)
      : const <Directory>[];
  final MangaOcrFilePageCache localCache = MangaOcrFilePageCache(
    cacheDir: localDirectory,
    pageNames: <String>[
      for (final MangaOcrPageFile page in pages) page.relativeUrl,
    ],
    pageFiles: <File>[
      for (final MangaOcrPageFile page in pages) page.file,
    ],
  );
  final List<GoogleLensPageCache> lensCaches = <GoogleLensPageCache>[
    for (final Directory directory in lensDirectories)
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
    // 候选统一成 (mtime, page) 再取最新，本地/各语言 Lens 缓存无特殊分支。
    final List<(DateTime, MokuroImage)> candidates =
        <(DateTime, MokuroImage)>[];
    if (local != null) {
      final File localFile = File(p.join(
        localDirectory.path,
        ocrPageCacheFileName(pages[pageIndex].relativeUrl),
      ));
      candidates.add((
        (await localFile.stat()).modified,
        _localPage(pages[pageIndex], local),
      ));
    }
    for (final GoogleLensPageCache lensCache in lensCaches) {
      final MokuroImage? lens =
          await lensCache.read(pageIndex, pages[pageIndex]);
      if (lens == null) continue;
      final File lensFile = File(p.join(
        lensCache.directory.path,
        '${pageIndex.toString().padLeft(6, '0')}.json',
      ));
      candidates.add(((await lensFile.stat()).modified, lens));
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
