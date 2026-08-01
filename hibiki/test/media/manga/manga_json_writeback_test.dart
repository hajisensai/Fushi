/// 「回写本页」：manga.json 读-改-写往返 + 追加块保序 + 并发写串行化 + 原子落盘。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/manga_json_writeback.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

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

  group('appendMangaBlockToMangaJson', () {
    test('读-改-写往返：追加块落到对应页末尾、既有块与 lines_coords 保序保真', () async {
      final File file = _writeTempMangaJson();
      await appendMangaBlockToMangaJson(
        mangaJsonPath: file.path,
        pageIndex: 1,
        box: const Rect.fromLTRB(300, 100, 380, 500),
        vertical: true,
        text: 'テスト行',
      );

      final MokuroPayload payload = parseMangaJson(file.readAsStringSync());
      expect(payload.images, hasLength(2));
      // 未触碰页不变。
      expect(payload.images[0].blocks, isEmpty);
      expect(payload.images[0].size, const Size(1000, 1600));

      final MokuroImage page = payload.images[1];
      expect(page.url, 'sub/p002.jpg', reason: '页 url 往返不丢子目录结构');
      expect(page.blocks, hasLength(2));
      // 既有块保序保真（含 lines_coords）。
      expect(page.blocks[0].lines, <String>['既存ブロック']);
      expect(page.blocks[0].zIndex, 0);
      expect(page.blocks[0].linesCoords, isNotNull);
      // 追加块在末尾，z_index = 追加前块数。
      final MokuroBlock added = page.blocks[1];
      expect(added.rectangle, const Rect.fromLTRB(300, 100, 380, 500));
      expect(added.isVertical, isTrue);
      expect(added.lines, <String>['テスト行']);
      expect(added.zIndex, 1);
      // font_size 估算落在 [8, min(宽,高)]。
      expect(added.fontSize, greaterThanOrEqualTo(8));
      expect(added.fontSize, lessThanOrEqualTo(80));
    });

    test('保留 ocr 元数据：回写不得抹掉引擎签名（否则整卷缓存被判异源作废）', () async {
      final File file = _writeTempMangaJson();
      await appendMangaBlockToMangaJson(
        mangaJsonPath: file.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(0, 0, 50, 50),
        vertical: false,
        text: 'x',
      );
      final MangaOcrMetadata? ocr = parseMangaJson(file.readAsStringSync()).ocr;
      expect(ocr, isNotNull);
      expect(ocr!.engine, 'local_onnx');
      expect(ocr.engineSignature, 'sig-abc');
      expect(ocr.schemaVersion, 2);
    });

    test('原子落盘：写完不留 .tmp 残渣', () async {
      final File file = _writeTempMangaJson();
      await appendMangaBlockToMangaJson(
        mangaJsonPath: file.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(0, 0, 50, 50),
        vertical: false,
        text: 'x',
      );
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(file.existsSync(), isTrue);
    });

    test('返回落盘后的 payload：调用方不必（也不该）锁外重读文件', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload returned = await appendMangaBlockToMangaJson(
        mangaJsonPath: file.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(0, 0, 50, 50),
        vertical: false,
        text: 'inline',
      );
      expect(returned.images[0].blocks.single.lines, <String>['inline']);
      // 返回值与磁盘一致（不是凭空构造的另一份）。
      final MokuroPayload onDisk = parseMangaJson(file.readAsStringSync());
      expect(onDisk.images[0].blocks.single.lines, <String>['inline']);
      expect(returned.ocr?.engineSignature, onDisk.ocr?.engineSignature);
    });

    test('页越界 / 文件缺失 → StateError', () async {
      final File file = _writeTempMangaJson();
      await expectLater(
        appendMangaBlockToMangaJson(
          mangaJsonPath: file.path,
          pageIndex: 2,
          box: const Rect.fromLTRB(0, 0, 10, 10),
          vertical: false,
          text: 'x',
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        appendMangaBlockToMangaJson(
          mangaJsonPath: p.join(p.dirname(file.path), 'missing.json'),
          pageIndex: 0,
          box: const Rect.fromLTRB(0, 0, 10, 10),
          vertical: false,
          text: 'x',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('并发追加串行化：8 个并发写全部落盘、无丢更新', () async {
      final File file = _writeTempMangaJson();
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 8; i++)
          appendMangaBlockToMangaJson(
            mangaJsonPath: file.path,
            pageIndex: 0,
            box: Rect.fromLTRB(i * 10.0, 0, i * 10.0 + 50, 100),
            vertical: false,
            text: 'block$i',
          ),
      ]);

      final MokuroPayload payload = parseMangaJson(file.readAsStringSync());
      final MokuroImage page = payload.images[0];
      expect(page.blocks, hasLength(8), reason: '文件级锁串行化读-改-写，并发追加不得互相覆盖');
      // z_index 是追加时的块数 → 恰为 0..7 各一次。非串行时多个块会读到同一份旧
      // 快照、拿到相同 z_index，这条比只数条数更能证明真串行。
      expect(
        page.blocks.map((MokuroBlock b) => b.zIndex).toSet(),
        Set<int>.of(List<int>.generate(8, (int i) => i)),
      );
      // 8 段文本全部在场（顺序不作要求：Future.wait 的调度顺序不保证）。
      expect(
        page.blocks.map((MokuroBlock b) => b.lines.single).toSet(),
        Set<String>.of(List<String>.generate(8, (int i) => 'block$i')),
      );
    });

    test('错误不毒化写锁链：失败后同路径仍可继续写', () async {
      final File file = _writeTempMangaJson();
      await expectLater(
        appendMangaBlockToMangaJson(
          mangaJsonPath: file.path,
          pageIndex: 99,
          box: const Rect.fromLTRB(0, 0, 10, 10),
          vertical: false,
          text: 'bad',
        ),
        throwsA(isA<StateError>()),
      );
      await appendMangaBlockToMangaJson(
        mangaJsonPath: file.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(0, 0, 50, 50),
        vertical: false,
        text: 'ok',
      );
      final MokuroPayload payload = parseMangaJson(file.readAsStringSync());
      expect(payload.images[0].blocks.single.lines, <String>['ok']);
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
      'lib/src/media/manga/reader/manga_hibiki_page.dart',
      'lib/src/media/manga/manga_ocr_wizard_dialog.dart',
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
                '与框选回写交叠会整份覆写、吞掉刚追加的块',
          );
          at = body.indexOf('writeMangaJsonAtomically(', at + 1);
        }
      }
    });

    test('在线章节失效时删 manga.json 也在锁内', () {
      final String body =
          File('lib/src/media/manga/reader/manga_hibiki_page.dart')
              .readAsStringSync();
      final int start =
          body.indexOf('Future<void> _invalidateOnlineChapterPayload(');
      expect(start, greaterThan(0));
      final int end = body.indexOf('\n  Future<', start + 1);
      final String fn = body.substring(start, end > start ? end : body.length);
      expect(
        fn,
        contains('runExclusiveOnMangaJson'),
        reason: '无锁 delete 会落在别的写者的读-改-写之间，让删掉的内容被原样写回',
      );
    });

    test('阅读器页不得再自己拼书根 manga.json 的落盘（绕过锁与原子写）', () {
      // 只钉阅读器页：它对书根 manga.json 的写全部应经本模块。向导那边还留着一处
      // 合法的 mangaPayloadToJson——写的是 `manga_ocr_out/` 里的 OCR 中间产物，
      // 与书根 manga.json 不同路径，不在这把锁的语义范围内。
      final String body =
          File('lib/src/media/manga/reader/manga_hibiki_page.dart')
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

    // 写回整份 payload 的另一条路径（整卷 OCR 落盘 / 在线几何回填）也必须经这把
    // 锁，否则与追加块交叠会互相覆盖。
    test('整份覆写与追加块共用一把锁：交叠不丢更新', () async {
      final File file = _writeTempMangaJson();
      final MokuroPayload baseline = parseMangaJson(file.readAsStringSync());
      await Future.wait(<Future<void>>[
        appendMangaBlockToMangaJson(
          mangaJsonPath: file.path,
          pageIndex: 0,
          box: const Rect.fromLTRB(0, 0, 50, 50),
          vertical: false,
          text: 'appended',
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
