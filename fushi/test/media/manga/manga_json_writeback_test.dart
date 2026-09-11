/// manga.json 写侧：字号估算 + 并发写串行化 + 原子落盘 + 锁覆盖守卫。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

String _mangaJson() {
  return jsonEncode(<String, Object?>{
    'ocr': <String, Object?>{
      'engine': 'local_onnx',
      'engine_signature': 'sig-abc',
      'schema_version': 2,
    },
    'pages': <Map<String, Object?>>[
      <String, Object?>{
        'url': 'p001.jpg',
        'width': 1000,
        'height': 1600,
        'blocks': <Object?>[],
      },
      <String, Object?>{
        'url': 'sub/p002.jpg',
        'width': 900,
        'height': 1200,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <double>[10, 20, 110, 220],
            'vertical': true,
            'font_size': 24,
            'z_index': 0,
            'lines': <String>['既存ブロック'],
            'lines_coords': <Object?>[
              <Object?>[
                <double>[10, 20],
                <double>[110, 20],
              ],
            ],
          },
        ],
      },
    ],
  });
}

MokuroBlock _block(MokuroRect rect, String text) {
  return MokuroBlock(
    rectangle: rect,
    isVertical: rect.height > rect.width,
    fontSize: 24,
    zIndex: 0,
    lines: <String>[text],
  );
}

File _writeTempMangaJson() {
  final Directory dir = Directory.systemTemp.createTempSync('manga_writeback_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final File file = File(p.join(dir.path, 'manga.json'));
  file.writeAsStringSync(_mangaJson());
  return file;
}

void main() {
  group('estimateMangaBlockFontSize', () {
    test('面积均摊 + clamp [8, min(宽,高)]', () {
      // 100x100、4 字 → sqrt(10000/4) = 50。
      expect(
        estimateMangaBlockFontSize(width: 100, height: 100, charCount: 4),
        50,
      );
      // 上限：不超 min(宽, 高)（单列竖排不超框宽）。
      expect(
        estimateMangaBlockFontSize(width: 30, height: 300, charCount: 1),
        30,
      );
      // 下限 8。
      expect(
        estimateMangaBlockFontSize(width: 20, height: 20, charCount: 100),
        8,
      );
      // 空文本按 1 字符算，不除零。
      expect(
        estimateMangaBlockFontSize(width: 40, height: 40, charCount: 0),
        40,
      );
    });
  });

  group('writeMangaJsonAtomically', () {
    test('rename 直接覆盖已存在的目标：绝不先 delete（那是唯一的原子性缺口）', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload payload = parseMangaJson(file.readAsStringSync());
      // 目标已存在时照样写成功。若实现改回「先 delete 再 rename」，delete 与
      // rename 之间目标完全不存在，崩在那个窗口整本 OCR 全丢。
      await writeMangaJsonAtomically(file.path, payload);
      expect(file.existsSync(), isTrue);
      expect(parseMangaJson(file.readAsStringSync()).images, hasLength(2));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('源码守卫：writeMangaJsonAtomically 里不得出现 delete()', () {
      // 行为断言证不了「中途没有不存在窗口」（测不到崩溃时刻），只能钉源码。
      final File source = File('lib/src/media/manga/manga_json_writeback.dart');
      final String body = source.readAsStringSync();
      final int start = body.indexOf('Future<void> writeMangaJsonAtomically(');
      expect(start, greaterThan(0));
      final int end = body.indexOf('\n}', start);
      expect(end, greaterThan(start));
      expect(
        body.substring(start, end),
        isNot(contains('.delete()')),
        reason: 'rename 已能覆盖已存在目标（Windows 实测 RENAME_OVER_EXISTING: OK）；'
            '先 delete 再 rename 会开出一个目标不存在的窗口',
      );
    });
  });

  // 锁的价值全在「一个写者都不许漏」。行为测试只能验已经进锁的那些；漏进锁的
  // 调用点必须靠源码扫描抓——这条守卫与文件头的调用点清单是同一份真相。
  group('锁覆盖守卫：书根 manga.json 的每个写/删都在锁内', () {
    const List<String> consumers = <String>[
      // 2026-09-12 起阅读器不再写任何 manga.json（在线几何回填 / 章节引导重写随
      // 「先下载再读」一起删除）；章 manga.json 由下载服务落盘。
      'lib/src/media/manga/download/manga_download_service.dart',
      'lib/src/media/manga/manga_ocr_wizard_dialog.dart',
      // BUG-2449：整卷 OCR 的完成落盘随任务所有权搬到了注册表。
      'lib/src/media/manga/ocr/manga_ocr_job_registry.dart',
    ];

    test('每处 writeMangaJsonAtomically 调用都由 runExclusiveOnMangaJson 包住', () {
      for (final String path in consumers) {
        final String body = File(path).readAsStringSync();
        int at = body.indexOf('writeMangaJsonAtomically(');
        expect(at, greaterThan(0), reason: '$path 应当经本模块落盘');
        while (at >= 0) {
          final String preceding = body.substring(at < 400 ? 0 : at - 400, at);
          expect(
            preceding,
            contains('runExclusiveOnMangaJson'),
            reason: '$path 偏移 $at 处的落盘不在 per-path 写锁内：'
                '与另一写者交叠会整份覆写、吞掉对方刚落盘的改动',
          );
          at = body.indexOf('writeMangaJsonAtomically(', at + 1);
        }
      }
    });

    test('删章目录（连带其 manga.json）也在锁内', () {
      final String body =
          File('lib/src/media/manga/library/manga_chapter_storage.dart')
              .readAsStringSync();
      final int start =
          body.indexOf('Future<void> deleteChapterDownload(');
      expect(start, greaterThan(0));
      final int end = body.indexOf('\nFuture<', start + 1);
      final String fn = body.substring(start, end > start ? end : body.length);
      expect(
        fn,
        contains('runExclusiveOnMangaJson'),
        reason: '无锁 delete 会落在整卷 OCR 落盘的读-改-写之间，让删掉的目录被写回一半',
      );
    });

    test('阅读器页不再写书根 manga.json（写侧只剩下载服务 / 向导 / 注册表）', () {
      final String body =
          File('lib/src/media/manga/reader/manga_fushi_page.dart')
              .readAsStringSync();
      expect(body, isNot(contains('writeMangaJsonAtomically(')));
    });

    test('阅读器页不得再自己拼书根 manga.json 的落盘（绕过锁与原子写）', () {
      // 只钉阅读器页：它对书根 manga.json 的写全部应经本模块。向导那边还留着一处
      // 合法的 mangaPayloadToJson——写的是 `manga_ocr_out/` 里的 OCR 中间产物，
      // 与书根 manga.json 不同路径，不在这把锁的语义范围内。
      final String body =
          File('lib/src/media/manga/reader/manga_fushi_page.dart')
              .readAsStringSync();
      expect(
        body,
        isNot(contains('mangaPayloadToJson(')),
        reason: '直接序列化 payload 就等于绕过 writeMangaJsonAtomically 与 per-path 写锁',
      );
    });

    test('向导对书根 manga.json 的落盘经本模块（其余 mangaPayloadToJson 是 OCR 中间产物）', () {
      final String body =
          File('lib/src/media/manga/manga_ocr_wizard_dialog.dart')
              .readAsStringSync();
      final int at = body.indexOf('MangaStorage.kMangaJsonFileName');
      expect(at, greaterThan(0));
      // 书根 manga.json 的那处落盘必须紧跟锁 + 原子写，而不是自己拼 .tmp。
      final String after = body.substring(at, at + 400);
      expect(after, contains('runExclusiveOnMangaJson'));
      expect(after, contains('writeMangaJsonAtomically'));
      expect(after, isNot(contains('.tmp')));
    });
  });

  group('runExclusiveOnMangaJson', () {
    test('同路径严格串行：临界区不重入', () async {
      final File file = _writeTempMangaJson();
      int active = 0;
      int maxActive = 0;
      Future<void> critical() async {
        active++;
        maxActive = maxActive > active ? maxActive : active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
      }

      await Future.wait(<Future<void>>[
        for (int i = 0; i < 4; i++)
          runExclusiveOnMangaJson<void>(file.path, critical),
      ]);
      expect(maxActive, 1, reason: '同一 manga.json 路径上临界区任何时刻只能有一个执行者');
    });

    test('不同路径互不阻塞（锁按路径分桶，不是全局单锁）', () async {
      final File a = _writeTempMangaJson();
      final File b = _writeTempMangaJson();
      final Completer<void> holdA = Completer<void>();
      final Future<void> first =
          runExclusiveOnMangaJson<void>(a.path, () => holdA.future);
      // b 的临界区不该等 a 释放。
      await runExclusiveOnMangaJson<void>(b.path, () async {}).timeout(
        const Duration(seconds: 2),
      );
      holdA.complete();
      await first;
    });

    // 整卷 OCR 落盘与在线几何回填都是整份覆写，两者都必须经这把锁，否则交叠会
    // 互相覆盖、留下半份 + 半份的拼接。
    test('两个整份覆写者共用一把锁：交叠不丢更新、文件仍合法', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload baseline = parseMangaJson(file.readAsStringSync());
      final List<MokuroImage> images = List<MokuroImage>.of(baseline.images);
      images[0] = MokuroImage(
        url: images[0].url,
        size: images[0].size,
        blocks: <MokuroBlock>[
          _block(const MokuroRect.fromLTRB(0, 0, 50, 50), 'replaced'),
        ],
      );
      final MokuroPayload edited =
          MokuroPayload(images: images, ocr: baseline.ocr);
      await Future.wait(<Future<void>>[
        runExclusiveOnMangaJson<void>(
          file.path,
          () => writeMangaJsonAtomically(file.path, edited),
        ),
        runExclusiveOnMangaJson<void>(
          file.path,
          () => writeMangaJsonAtomically(file.path, baseline),
        ),
      ]);
      // 两个写者都跑完且文件仍是合法 JSON（不是半份 + 半份的拼接）。
      final MokuroPayload after = parseMangaJson(file.readAsStringSync());
      expect(after.images, hasLength(2));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });
}
