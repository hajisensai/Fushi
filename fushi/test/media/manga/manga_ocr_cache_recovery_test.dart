import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_cache_recovery.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late List<MangaOcrPageFile> pages;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('manga-cache-recovery-');
    final Directory images = Directory(p.join(temporary.path, 'images'));
    await images.create();
    for (int index = 0; index < 3; index++) {
      await File(
        p.join(images.path, 'page_$index.jpg'),
      ).writeAsBytes(<int>[index, 1, 2, 3], flush: true);
    }
    pages = enumerateMangaPages(temporary);
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'recovers partial local and Lens pages without replacing formal OCR',
    () async {
      final MangaOcrFilePageCache local = _localCache(temporary, pages);
      await local.write('manga_ocr', _localResult(pageIndex: 0, text: '本地'));

      final GoogleLensPageCache lens = _lensCache(temporary);
      await lens.write(1, pages[1], _page(pages[1].relativeUrl, 'Lens'));

      final MokuroPayload formal = MokuroPayload(
        images: <MokuroImage>[
          _page(pages[0].relativeUrl, ''),
          _page(pages[1].relativeUrl, ''),
          _page(pages[2].relativeUrl, '正式'),
        ],
      );
      final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
        managedDirectory: temporary.path,
        mangaJsonPath: _mangaJson(temporary),
        basePayload: formal,
        localEngineSignature: kLocalMangaOcrEngineSignature,
      );

      expect(recovery.recoveredPageIndices, <int>[0, 1]);
      expect(recovery.payload.images[0].blocks.single.lines, <String>['本地']);
      expect(recovery.payload.images[1].blocks.single.lines, <String>['Lens']);
      expect(recovery.payload.images[2].blocks.single.lines, <String>['正式']);
    },
  );

  test(
    'uses newest valid engine cache and ignores stale fingerprints',
    () async {
      final GoogleLensPageCache lens = _lensCache(temporary);
      await lens.write(0, pages[0], _page(pages[0].relativeUrl, '旧 Lens'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final MangaOcrFilePageCache local = _localCache(temporary, pages);
      await local.write('manga_ocr', _localResult(pageIndex: 0, text: '新本地'));
      await local.write('manga_ocr', _localResult(pageIndex: 1, text: '即将失效'));
      await pages[1].file.writeAsBytes(<int>[9, 9, 9], flush: true);

      final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
        managedDirectory: temporary.path,
        mangaJsonPath: _mangaJson(temporary),
        basePayload: MokuroPayload(
          images: <MokuroImage>[
            for (final MangaOcrPageFile page in pages)
              _page(page.relativeUrl, ''),
          ],
        ),
        localEngineSignature: kLocalMangaOcrEngineSignature,
      );

      expect(recovery.recoveredPageIndices, <int>[0]);
      expect(recovery.payload.images[0].blocks.single.lines, <String>['新本地']);
      expect(recovery.payload.images[1].blocks, isEmpty);
    },
  );

  // BUG-1173：本地缓存目录名带模型内容指纹。换模型后签名变，旧模型产出的页缓存
  // 不得再被恢复回来冒充当前模型的结果。
  test(
    'local cache from a different model signature is not recovered',
    () async {
      const String oldSignature = '$kLocalMangaOcrEngineSignature-aaaaaaaaaaaa';
      final MangaOcrFilePageCache stale = _localCache(
        temporary,
        pages,
        signature: oldSignature,
      );
      await stale.write('manga_ocr', _localResult(pageIndex: 0, text: '旧模型'));

      final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
        managedDirectory: temporary.path,
        mangaJsonPath: _mangaJson(temporary),
        basePayload: MokuroPayload(
          images: <MokuroImage>[
            for (final MangaOcrPageFile page in pages)
              _page(page.relativeUrl, ''),
          ],
        ),
        localEngineSignature: '$kLocalMangaOcrEngineSignature-bbbbbbbbbbbb',
      );

      expect(recovery.recoveredPageIndices, isEmpty);
      expect(recovery.payload.images[0].blocks, isEmpty);

      // 同签名时同一份缓存必须能恢复（证明上面为空不是因为缓存没写成功）。
      final MangaOcrCacheRecovery sameModel = await recoverCachedMangaOcr(
        managedDirectory: temporary.path,
        mangaJsonPath: _mangaJson(temporary),
        basePayload: MokuroPayload(
          images: <MokuroImage>[
            for (final MangaOcrPageFile page in pages)
              _page(page.relativeUrl, ''),
          ],
        ),
        localEngineSignature: oldSignature,
      );
      expect(sameModel.recoveredPageIndices, <int>[0]);
      expect(sameModel.payload.images[0].blocks.single.lines, <String>['旧模型']);
    },
  );

  // BUG-4827：系统 OCR 与 Lens 同格式同根写逐页缓存，被杀进程 / 取消后重开书
  // 只能靠这份缓存读回已识别的页。
  test('recovers pages cached by a system OCR run', () async {
    final GoogleLensPageCache system = _pageJsonCache(
      temporary,
      systemOcrEngineSignature('ja'),
    );
    await system.write(1, pages[1], _page(pages[1].relativeUrl, 'システム'));

    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      mangaJsonPath: _mangaJson(temporary),
      basePayload: MokuroPayload(
        images: <MokuroImage>[
          for (final MangaOcrPageFile page in pages)
            _page(page.relativeUrl, ''),
        ],
      ),
      localEngineSignature: kLocalMangaOcrEngineSignature,
    );

    expect(recovery.recoveredPageIndices, <int>[1]);
    expect(recovery.payload.images[1].blocks.single.lines, <String>['システム']);
  });

  // 前缀带版本：v1 是 BUG-2767 换签名作废的旧结果，不得被恢复回来。
  test('retired system OCR v1 cache is not recovered', () async {
    for (final String retired in <String>[
      'system_ocr_ja',
      'system_ocr_v1_ja',
    ]) {
      await _pageJsonCache(
        temporary,
        retired,
      ).write(0, pages[0], _page(pages[0].relativeUrl, '旧版'));
    }

    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      mangaJsonPath: _mangaJson(temporary),
      basePayload: MokuroPayload(
        images: <MokuroImage>[
          for (final MangaOcrPageFile page in pages)
            _page(page.relativeUrl, ''),
        ],
      ),
      localEngineSignature: kLocalMangaOcrEngineSignature,
    );

    expect(recovery.recoveredPageIndices, isEmpty);
  });

  test('page-json cache prefix table covers every engine that writes one', () {
    expect(
      isMangaOcrPageJsonCacheDirectory(googleLensEngineSignature('en')),
      isTrue,
    );
    expect(
      isMangaOcrPageJsonCacheDirectory(systemOcrEngineSignature('zh')),
      isTrue,
    );
    expect(
      isMangaOcrPageJsonCacheDirectory(kLocalMangaOcrEngineSignature),
      isFalse,
      reason: '本地模型是另一种缓存格式，走 MangaOcrFilePageCache',
    );
  });

  test('recovers pages cached by a non-Japanese Lens run', () async {
    final GoogleLensPageCache lens = _lensCache(temporary, language: 'en');
    await lens.write(0, pages[0], _page(pages[0].relativeUrl, 'Hello world'));

    final MokuroPayload formal = MokuroPayload(
      images: <MokuroImage>[
        _page(pages[0].relativeUrl, ''),
        _page(pages[1].relativeUrl, ''),
        _page(pages[2].relativeUrl, '正式'),
      ],
    );
    final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
      managedDirectory: temporary.path,
      mangaJsonPath: _mangaJson(temporary),
      basePayload: formal,
      localEngineSignature: kLocalMangaOcrEngineSignature,
    );

    expect(recovery.recoveredPageIndices, <int>[0]);
    expect(
      recovery.payload.images.first.blocks.single.lines.single,
      'Hello world',
    );
  });
  // 拍板 design-nmv-ocr-cache-rule（方案 b）：先用系统 OCR 跑过一部分、后来换
  // Lens 整卷跑完并把某页判无字，重开书时这页不得被过期的系统 OCR 结果填回来。
  group(
    'formal volume result gates which page caches may refill empty pages',
    () {
      final DateTime formalAt = DateTime.utc(2026, 11, 20, 12);

      Future<void> touch(String signature, int pageIndex, DateTime at) => File(
        p.join(
          temporary.path,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          signature,
          '${pageIndex.toString().padLeft(6, '0')}.json',
        ),
      ).setLastModified(at);

      MokuroPayload formalPayload(
        String engine,
        String signature, {
        DateTime? at,
      }) => MokuroPayload(
        images: <MokuroImage>[
          for (final MangaOcrPageFile page in pages)
            _page(page.relativeUrl, ''),
        ],
        ocr: MangaOcrMetadata(
          engine: engine,
          engineSignature: signature,
          schemaVersion: 1,
          completedAt: at,
        ),
      );

      test('older cache from another engine is not recovered', () async {
        final String system = systemOcrEngineSignature('ja');
        await _pageJsonCache(
          temporary,
          system,
        ).write(0, pages[0], _page(pages[0].relativeUrl, '過期システム'));
        await touch(system, 0, formalAt.subtract(const Duration(hours: 1)));

        final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
          managedDirectory: temporary.path,
          mangaJsonPath: _mangaJson(temporary),
          basePayload: formalPayload(
            'google_lens',
            googleLensEngineSignature('ja'),
            at: formalAt,
          ),
          localEngineSignature: kLocalMangaOcrEngineSignature,
        );

        expect(recovery.recoveredPageIndices, isEmpty);
        expect(recovery.payload.images[0].blocks, isEmpty);
      });

      test(
        'same-engine cache is recovered even if older than the volume',
        () async {
          final String lens = googleLensEngineSignature('ja');
          await _pageJsonCache(
            temporary,
            lens,
          ).write(0, pages[0], _page(pages[0].relativeUrl, '同引擎'));
          await touch(lens, 0, formalAt.subtract(const Duration(hours: 1)));

          final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
            managedDirectory: temporary.path,
            mangaJsonPath: _mangaJson(temporary),
            basePayload: formalPayload('google_lens', lens, at: formalAt),
            localEngineSignature: kLocalMangaOcrEngineSignature,
          );

          expect(recovery.recoveredPageIndices, <int>[0]);
          expect(recovery.payload.images[0].blocks.single.lines, <String>[
            '同引擎',
          ]);
        },
      );

      test('another engine run after the volume is recovered', () async {
        final String system = systemOcrEngineSignature('ja');
        await _pageJsonCache(
          temporary,
          system,
        ).write(1, pages[1], _page(pages[1].relativeUrl, '後発システム'));
        await touch(system, 1, formalAt.add(const Duration(hours: 1)));
        // 本地模型缓存也走同一判据：比整卷早的不收。
        final MangaOcrFilePageCache local = _localCache(temporary, pages);
        await local.write('manga_ocr', _localResult(pageIndex: 2, text: '旧本地'));
        await File(
          p.join(
            local.cacheDir.path,
            ocrPageCacheFileName(pages[2].relativeUrl),
          ),
        ).setLastModified(formalAt.subtract(const Duration(hours: 1)));

        final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
          managedDirectory: temporary.path,
          mangaJsonPath: _mangaJson(temporary),
          basePayload: formalPayload(
            'google_lens',
            googleLensEngineSignature('ja'),
            at: formalAt,
          ),
          localEngineSignature: kLocalMangaOcrEngineSignature,
        );

        expect(recovery.recoveredPageIndices, <int>[1]);
        expect(recovery.payload.images[1].blocks.single.lines, <String>[
          '後発システム',
        ]);
        expect(recovery.payload.images[2].blocks, isEmpty);
      });

      test(
        'legacy volume without completedAt falls back to manga.json mtime',
        () async {
          final String system = systemOcrEngineSignature('ja');
          final GoogleLensPageCache cache = _pageJsonCache(temporary, system);
          await cache.write(0, pages[0], _page(pages[0].relativeUrl, '過期'));
          await cache.write(1, pages[1], _page(pages[1].relativeUrl, '後発'));
          await touch(system, 0, formalAt.subtract(const Duration(hours: 1)));
          await touch(system, 1, formalAt.add(const Duration(hours: 1)));
          final File mangaJson = File(_mangaJson(temporary));
          await mangaJson.writeAsString('{}', flush: true);
          await mangaJson.setLastModified(formalAt);

          final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
            managedDirectory: temporary.path,
            mangaJsonPath: mangaJson.path,
            basePayload: formalPayload(
              'google_lens',
              googleLensEngineSignature('ja'),
            ),
            localEngineSignature: kLocalMangaOcrEngineSignature,
          );

          expect(recovery.recoveredPageIndices, <int>[1]);
          expect(recovery.payload.images[0].blocks, isEmpty);
        },
      );

      test('completedAt survives the manga.json round trip', () {
        final MokuroPayload parsed = parseMangaJson(
          jsonEncode(
            mangaPayloadToJson(
              formalPayload('system_ocr', 'system_ocr_v2_ja', at: formalAt),
            ),
          ),
        );
        expect(parsed.ocr?.completedAt, formalAt);
        expect(
          parseMangaJson(
            jsonEncode(
              mangaPayloadToJson(
                formalPayload('system_ocr', 'system_ocr_v2_ja'),
              ),
            ),
          ).ocr?.completedAt,
          isNull,
        );
      });
    },
  );
}

String _mangaJson(Directory root) => p.join(root.path, 'manga.json');

MangaOcrFilePageCache _localCache(
  Directory root,
  List<MangaOcrPageFile> pages, {
  String signature = kLocalMangaOcrEngineSignature,
}) => MangaOcrFilePageCache(
  cacheDir: Directory(
    p.join(
      root.path,
      kMangaOcrOutDirName,
      kMangaOcrPagesCacheDirName,
      signature,
    ),
  ),
  pageNames: <String>[for (final page in pages) page.relativeUrl],
  pageFiles: <File>[for (final page in pages) page.file],
);

GoogleLensPageCache _lensCache(Directory root, {String language = 'ja'}) =>
    _pageJsonCache(root, googleLensEngineSignature(language));

GoogleLensPageCache _pageJsonCache(Directory root, String signature) =>
    GoogleLensPageCache(
      Directory(
        p.join(
          root.path,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          signature,
        ),
      ),
    );

OcrPageResult _localResult({required int pageIndex, required String text}) =>
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
  size: const MokuroSize(100, 200),
  blocks: text.isEmpty
      ? const <MokuroBlock>[]
      : <MokuroBlock>[
          MokuroBlock(
            rectangle: const MokuroRect.fromLTWH(10, 20, 30, 40),
            isVertical: false,
            fontSize: 12,
            zIndex: 0,
            lines: <String>[text],
          ),
        ],
);
