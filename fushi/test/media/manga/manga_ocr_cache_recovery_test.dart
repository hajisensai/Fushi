import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_cache_recovery.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/ocr_types.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late List<MangaOcrPageFile> pages;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('manga-cache-recovery-');
    final Directory images = Directory(p.join(temporary.path, 'images'));
    await images.create();
    for (int index = 0; index < 3; index++) {
      await File(p.join(images.path, 'page_$index.jpg'))
          .writeAsBytes(<int>[index, 1, 2, 3], flush: true);
    }
    pages = enumerateMangaPages(temporary);
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('recovers partial local and Lens pages without replacing formal OCR',
      () async {
    final MangaOcrFilePageCache local = _localCache(temporary, pages);
    await local.write(
      'manga_ocr',
      _localResult(pageIndex: 0, text: '本地'),
    );

    final GoogleLensPageCache lens = _lensCache(temporary);
    await lens.write(1, pages[1], _page(pages[1].relativeUrl, 'Lens'));

    final MokuroPayload formal = MokuroPayload(images: <MokuroImage>[
      _page(pages[0].relativeUrl, ''),
      _page(pages[1].relativeUrl, ''),
      _page(pages[2].relativeUrl, '正式'),
    ]);
    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      basePayload: formal,
      localEngineSignature: kLocalMangaOcrEngineSignature,
    );

    expect(recovery.recoveredPageIndices, <int>[0, 1]);
    expect(recovery.payload.images[0].blocks.single.lines, <String>['本地']);
    expect(recovery.payload.images[1].blocks.single.lines, <String>['Lens']);
    expect(recovery.payload.images[2].blocks.single.lines, <String>['正式']);
  });

  test('uses newest valid engine cache and ignores stale fingerprints',
      () async {
    final GoogleLensPageCache lens = _lensCache(temporary);
    await lens.write(0, pages[0], _page(pages[0].relativeUrl, '旧 Lens'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final MangaOcrFilePageCache local = _localCache(temporary, pages);
    await local.write(
      'manga_ocr',
      _localResult(pageIndex: 0, text: '新本地'),
    );
    await local.write(
      'manga_ocr',
      _localResult(pageIndex: 1, text: '即将失效'),
    );
    await pages[1].file.writeAsBytes(<int>[9, 9, 9], flush: true);

    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      basePayload: MokuroPayload(images: <MokuroImage>[
        for (final MangaOcrPageFile page in pages) _page(page.relativeUrl, ''),
      ]),
      localEngineSignature: kLocalMangaOcrEngineSignature,
    );

    expect(recovery.recoveredPageIndices, <int>[0]);
    expect(recovery.payload.images[0].blocks.single.lines, <String>['新本地']);
    expect(recovery.payload.images[1].blocks, isEmpty);
  });

  // BUG-1173：本地缓存目录名带模型内容指纹。换模型后签名变，旧模型产出的页缓存
  // 不得再被恢复回来冒充当前模型的结果。
  test('local cache from a different model signature is not recovered',
      () async {
    const String oldSignature = '$kLocalMangaOcrEngineSignature-aaaaaaaaaaaa';
    final MangaOcrFilePageCache stale =
        _localCache(temporary, pages, signature: oldSignature);
    await stale.write('manga_ocr', _localResult(pageIndex: 0, text: '旧模型'));

    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      basePayload: MokuroPayload(images: <MokuroImage>[
        for (final MangaOcrPageFile page in pages) _page(page.relativeUrl, ''),
      ]),
      localEngineSignature: '$kLocalMangaOcrEngineSignature-bbbbbbbbbbbb',
    );

    expect(recovery.recoveredPageIndices, isEmpty);
    expect(recovery.payload.images[0].blocks, isEmpty);

    // 同签名时同一份缓存必须能恢复（证明上面为空不是因为缓存没写成功）。
    final MangaOcrCacheRecovery sameModel = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      basePayload: MokuroPayload(images: <MokuroImage>[
        for (final MangaOcrPageFile page in pages) _page(page.relativeUrl, ''),
      ]),
      localEngineSignature: oldSignature,
    );
    expect(sameModel.recoveredPageIndices, <int>[0]);
    expect(sameModel.payload.images[0].blocks.single.lines, <String>['旧模型']);
  });
}

MangaOcrFilePageCache _localCache(
  Directory root,
  List<MangaOcrPageFile> pages, {
  String signature = kLocalMangaOcrEngineSignature,
}) =>
    MangaOcrFilePageCache(
      cacheDir: Directory(p.join(
        root.path,
        kMangaOcrOutDirName,
        kMangaOcrPagesCacheDirName,
        signature,
      )),
      pageNames: <String>[for (final page in pages) page.relativeUrl],
      pageFiles: <File>[for (final page in pages) page.file],
    );

GoogleLensPageCache _lensCache(Directory root) => GoogleLensPageCache(
      Directory(p.join(
        root.path,
        kMangaOcrOutDirName,
        kMangaOcrPagesCacheDirName,
        kGoogleLensEngineSignature,
      )),
    );

OcrPageResult _localResult({
  required int pageIndex,
  required String text,
}) =>
    OcrPageResult(
      pageIndex: pageIndex,
      imageWidth: 100,
      imageHeight: 200,
      blocks: <OcrBlock>[
        OcrBlock(
          box: const OcrRect(left: 10, top: 20, right: 40, bottom: 60),
          vertical: false,
          lines: <String>[text],
          score: 0.9,
          insideBubble: false,
        ),
      ],
    );

MokuroImage _page(String url, String text) => MokuroImage(
      url: url,
      size: const Size(100, 200),
      blocks: text.isEmpty
          ? const <MokuroBlock>[]
          : <MokuroBlock>[
              MokuroBlock(
                rectangle: const Rect.fromLTWH(10, 20, 30, 40),
                isVertical: false,
                fontSize: 12,
                zIndex: 0,
                lines: <String>[text],
              ),
            ],
    );
