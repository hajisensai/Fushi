/// P4「回写本页」：manga.json 读-改-写往返 + 追加块保序 + 并发写保护（文件级）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/manga_json_writeback.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

String _mangaJson() {
  return jsonEncode(<String, Object?>{
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
      expect(estimateMangaBlockFontSize(width: 100, height: 100, charCount: 4),
          50);
      // 上限：不超 min(宽, 高)（单列竖排不超框宽）。
      expect(
          estimateMangaBlockFontSize(width: 30, height: 300, charCount: 1), 30);
      // 下限 8。
      expect(
          estimateMangaBlockFontSize(width: 20, height: 20, charCount: 100), 8);
      // 空文本按 1 字符算，不除零。
      expect(
          estimateMangaBlockFontSize(width: 40, height: 40, charCount: 0), 40);
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
      // z_index 是追加时的块数 → 恰为 0..7 各一次。
      expect(
        page.blocks.map((MokuroBlock b) => b.zIndex).toSet(),
        Set<int>.of(List<int>.generate(8, (int i) => i)),
      );
      // 8 段文本全部在场。
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
}
