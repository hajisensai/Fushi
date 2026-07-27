import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart';
import 'package:hibiki/src/ocr/manga_ocr_model_fingerprint.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';

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
  final Directory lensDirectory =
      Directory(p.join(cacheRoot.path, kGoogleLensEngineSignature));
  final MangaOcrFilePageCache localCache = MangaOcrFilePageCache(
    cacheDir: localDirectory,
    pageNames: <String>[
      for (final MangaOcrPageFile page in pages) page.relativeUrl,
    ],
    pageFiles: <File>[
      for (final MangaOcrPageFile page in pages) page.file,
    ],
  );
  final GoogleLensPageCache lensCache = GoogleLensPageCache(lensDirectory);

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
    final MokuroImage? lens = await lensCache.read(pageIndex, pages[pageIndex]);
    if (local == null && lens == null) {
      continue;
    }

    MokuroImage selected;
    if (local != null && lens != null) {
      final File localFile = File(p.join(
        localDirectory.path,
        ocrPageCacheFileName(pages[pageIndex].relativeUrl),
      ));
      final File lensFile = File(p.join(
        lensDirectory.path,
        '${pageIndex.toString().padLeft(6, '0')}.json',
      ));
      final DateTime localModified = (await localFile.stat()).modified;
      final DateTime lensModified = (await lensFile.stat()).modified;
      selected = !localModified.isBefore(lensModified)
          ? _localPage(pages[pageIndex], local)
          : lens;
    } else if (local != null) {
      selected = _localPage(pages[pageIndex], local);
    } else {
      selected = lens!;
    }

    images[payloadIndex] = selected;
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
