/// 「重新识别框选区域」能力层的纯函数与裁框落盘契约。
///
/// 守的是四件事：① 裁框 clamp / 取整口径；② 裁图真的落在临时根目录的子目录里
/// （外部 mokuro 把 `.mokuro` 写到被扫描目录同级，不放一层子目录就漏到临时根外）；
/// ③ 结果块（含字符区域与行多边形）平移回页图坐标；④ 「块属于区域」判据与区域
/// 换块的保序 / 重编号。
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/manga_region_ocr.dart';

MokuroBlock _block(
  Rect rect,
  String text, {
  int zIndex = 0,
  List<MangaOcrTextRegion>? regions,
  List<List<List<double>>>? linesCoords,
}) {
  return MokuroBlock(
    rectangle: rect,
    isVertical: rect.height > rect.width,
    fontSize: 24,
    zIndex: zIndex,
    lines: <String>[text],
    regions: regions,
    linesCoords: linesCoords,
  );
}

Directory _tempRoot(String prefix) {
  final Directory dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  group('clampMangaRegion', () {
    test('页内框：left/top 向下取整、right/bottom 向上取整', () {
      expect(
        clampMangaRegion(
            const Rect.fromLTRB(10.4, 20.6, 110.2, 220.1), 1000, 1600),
        const Rect.fromLTRB(10, 20, 111, 221),
      );
    });

    test('越界框 clamp 进页内，且至少 1px', () {
      expect(
        clampMangaRegion(const Rect.fromLTRB(-50, -50, 2000, 3000), 1000, 1600),
        const Rect.fromLTRB(0, 0, 1000, 1600),
      );
      expect(
        clampMangaRegion(
            const Rect.fromLTRB(999.5, 1599.5, 999.6, 1599.6), 1000, 1600),
        const Rect.fromLTRB(999, 1599, 1000, 1600),
      );
    });
  });

  group('cropMangaRegionToTempDir', () {
    test('裁图落在 <临时根>/page/region.png，尺寸 = clamp 后的整数矩形', () async {
      final Directory root = _tempRoot('manga_region_src_');
      final img.Image page = img.Image(width: 300, height: 200);
      img.fill(page, color: img.ColorRgb8(255, 255, 255));
      final File source = File(p.join(root.path, 'p001.png'));
      source.writeAsBytesSync(img.encodePng(page));

      final MangaRegionCrop crop = await cropMangaRegionToTempDir(
        imagePath: source.path,
        box: const Rect.fromLTRB(20.5, 30.2, 120.4, 90.9),
        tempRoot: root,
      );
      addTearDown(() => deleteMangaRegionCrop(crop.root));

      expect(crop.rect, const Rect.fromLTRB(20, 30, 121, 91));
      expect(p.isWithin(root.path, crop.root.path), isTrue);
      expect(
          crop.imageDir.path, p.join(crop.root.path, kMangaRegionCropDirName));
      final File output =
          File(p.join(crop.imageDir.path, kMangaRegionCropFileName));
      expect(output.existsSync(), isTrue);
      final img.Image? decoded = img.decodePng(output.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 101);
      expect(decoded.height, 61);
      // 引擎链扫的是子目录：里面只有这一张图，根目录本身没有图片。
      expect(
        crop.imageDir
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path)),
        <String>[kMangaRegionCropFileName],
      );
    });

    test('解码失败 → 抛出且不留临时目录', () async {
      final Directory root = _tempRoot('manga_region_bad_');
      final File source = File(p.join(root.path, 'broken.png'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await expectLater(
        cropMangaRegionToTempDir(
          imagePath: source.path,
          box: const Rect.fromLTRB(0, 0, 10, 10),
          tempRoot: root,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        root.listSync().whereType<Directory>(),
        isEmpty,
        reason: '失败路径也要把临时根删干净',
      );
    });
  });

  group('offsetMangaBlocks', () {
    test('块框、字符区域、行多边形一起平移', () {
      final List<MokuroBlock> moved = offsetMangaBlocks(
        <MokuroBlock>[
          _block(
            const Rect.fromLTRB(1, 2, 11, 42),
            'ab',
            regions: <MangaOcrTextRegion>[
              const MangaOcrTextRegion(
                rectangle: Rect.fromLTRB(1, 2, 11, 22),
                utf16Start: 0,
                utf16End: 1,
              ),
            ],
            linesCoords: <List<List<double>>>[
              <List<double>>[
                <double>[1, 2],
                <double>[11, 42],
              ],
            ],
          ),
        ],
        const Offset(100, 200),
      );
      final MokuroBlock block = moved.single;
      expect(block.rectangle, const Rect.fromLTRB(101, 202, 111, 242));
      expect(block.regions!.single.rectangle,
          const Rect.fromLTRB(101, 202, 111, 222));
      expect(block.regions!.single.utf16End, 1);
      expect(block.linesCoords, <List<List<double>>>[
        <List<double>>[
          <double>[101, 202],
          <double>[111, 242],
        ],
      ]);
      expect(block.lines, <String>['ab']);
    });

    test('无 regions / lines_coords 的块保持 null（不凭空造空列表）', () {
      final MokuroBlock block = offsetMangaBlocks(
        <MokuroBlock>[_block(const Rect.fromLTRB(0, 0, 10, 10), 'x')],
        const Offset(5, 5),
      ).single;
      expect(block.regions, isNull);
      expect(block.linesCoords, isNull);
    });
  });

  group('isMangaBlockInsideRegion', () {
    const Rect region = Rect.fromLTRB(100, 100, 200, 200);

    test('块面积过半在区域内 → 属于', () {
      expect(
        isMangaBlockInsideRegion(
            const Rect.fromLTRB(150, 150, 250, 190), region),
        isTrue,
        reason: '一半在内（恰好 50%）按属于算',
      );
      expect(
        isMangaBlockInsideRegion(
            const Rect.fromLTRB(110, 110, 190, 190), region),
        isTrue,
      );
    });

    test('只擦到边的邻块不属于', () {
      expect(
        isMangaBlockInsideRegion(
            const Rect.fromLTRB(180, 100, 300, 200), region),
        isFalse,
        reason: '只有 1/6 在区域内',
      );
      expect(
        isMangaBlockInsideRegion(
            const Rect.fromLTRB(300, 300, 400, 400), region),
        isFalse,
      );
    });

    test('零面积块退化为左上角判定', () {
      expect(
        isMangaBlockInsideRegion(
            const Rect.fromLTRB(150, 150, 150, 150), region),
        isTrue,
      );
      expect(
        isMangaBlockInsideRegion(const Rect.fromLTRB(50, 50, 50, 50), region),
        isFalse,
      );
    });
  });

  group('replaceMangaPageRegion', () {
    test('区域内旧块被换掉，区域外保序在前，新块在后，z_index 连续重编', () {
      final MokuroImage page = MokuroImage(
        url: 'p001.jpg',
        size: const Size(1000, 1600),
        blocks: <MokuroBlock>[
          _block(const Rect.fromLTRB(0, 0, 50, 50), 'keep-a', zIndex: 0),
          _block(const Rect.fromLTRB(110, 110, 190, 190), 'old', zIndex: 1),
          _block(const Rect.fromLTRB(500, 500, 600, 700), 'keep-b', zIndex: 2),
        ],
      );
      final MokuroImage replaced = replaceMangaPageRegion(
        page,
        const Rect.fromLTRB(100, 100, 200, 200),
        <MokuroBlock>[
          _block(const Rect.fromLTRB(105, 105, 150, 195), 'new-1'),
          _block(const Rect.fromLTRB(150, 105, 195, 195), 'new-2'),
        ],
      );
      expect(replaced.url, 'p001.jpg');
      expect(replaced.size, const Size(1000, 1600));
      expect(
        replaced.blocks.map((MokuroBlock b) => b.lines.single).toList(),
        <String>['keep-a', 'keep-b', 'new-1', 'new-2'],
      );
      expect(
        replaced.blocks.map((MokuroBlock b) => b.zIndex).toList(),
        <int>[0, 1, 2, 3],
      );
    });

    test('新块为空 = 只清掉区域内旧块（调用方决定要不要走到这一步）', () {
      final MokuroImage replaced = replaceMangaPageRegion(
        MokuroImage(
          url: 'p',
          size: const Size(10, 10),
          blocks: <MokuroBlock>[_block(const Rect.fromLTRB(1, 1, 5, 5), 'old')],
        ),
        const Rect.fromLTRB(0, 0, 10, 10),
        const <MokuroBlock>[],
      );
      expect(replaced.blocks, isEmpty);
    });
  });

  group('collectMangaRegionOcrBlocks', () {
    test('等 finished 事件、按 external 选解析器、块平移回页图坐标', () async {
      final Directory root = _tempRoot('manga_region_collect_');
      final File result = File(p.join(root.path, 'manga.json'))
        ..writeAsStringSync(
          '{"pages":[{"url":"region.png","width":100,"height":50,'
          '"blocks":[{"box":[10,5,40,45],"vertical":true,"font_size":12,'
          '"z_index":0,"lines":["こんにちは"]}]}]}',
        );
      final Stream<MangaOcrBackgroundEvent> events = Stream<
          MangaOcrBackgroundEvent>.fromIterable(<MangaOcrBackgroundEvent>[
        const MangaOcrBackgroundEvent.progress(pagesDone: 1, pagesTotal: 1),
        MangaOcrBackgroundEvent.finished(
          pagesTotal: 1,
          resultPath: result.path,
          external: false,
        ),
      ]);
      final List<MokuroBlock> blocks = await collectMangaRegionOcrBlocks(
        events,
        origin: const Offset(300, 400),
      );
      expect(blocks.single.rectangle, const Rect.fromLTRB(310, 405, 340, 445));
      expect(blocks.single.lines, <String>['こんにちは']);
      expect(blocks.single.isVertical, isTrue);
    });

    test('流里没有 finished（引擎中途收流）→ StateError，而不是静默当作空结果', () async {
      await expectLater(
        collectMangaRegionOcrBlocks(
          Stream<MangaOcrBackgroundEvent>.fromIterable(
            const <MangaOcrBackgroundEvent>[
              MangaOcrBackgroundEvent.progress(pagesDone: 0, pagesTotal: 1),
            ],
          ),
          origin: Offset.zero,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
