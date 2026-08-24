/// 「重新识别框选区域」编排原语的**数据安全性质**。
///
/// 这条链是全功能里唯一会永久删磁盘上用户文字块的路径，四条性质必须有测试钉住：
/// ① 引擎起不来 ⇒ manga.json 一个字节都不变；② 引擎返回零块 ⇒ 一个字节都不变；
/// ③ 落地时被删的旧块必然被裁图完整覆盖（部分重叠不再静默截断）；④ 成功时交出
/// 替换前的整页快照，撤销才有依据。
///
/// 编排原先住在 `MangaFushiPage` 的一个 `State` 方法里，只能靠人眼守；收成
/// `runMangaRegionRescan` 之后可以直接注入假引擎来测。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_auto_start.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_region_ocr.dart';
import 'package:fushi/src/media/manga/ocr/manga_region_rescan.dart';

/// 一页 1000x1600、上面一个竖排气泡的 manga.json，气泡框 [120,120,180,220]。
String _mangaJson() {
  return jsonEncode(<String, Object?>{
    'ocr': <String, Object?>{
      'engine': 'local_onnx',
      'engine_signature': 'sig-abc',
      'schema_version': 2,
    },
    'pages': <Map<String, Object?>>[
      <String, Object?>{
        'url': 'p001.png',
        'width': 1000,
        'height': 1600,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <double>[120, 120, 180, 220],
            'vertical': true,
            'font_size': 24,
            'z_index': 0,
            'lines': <String>['既存ブロック'],
          },
        ],
      },
    ],
  });
}

class _Fixture {
  const _Fixture(
      {required this.dir, required this.mangaJson, required this.page});

  final Directory dir;
  final File mangaJson;
  final File page;
}

_Fixture _fixture() {
  final Directory dir = Directory.systemTemp.createTempSync('manga_rescan_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final File mangaJson = File(p.join(dir.path, 'manga.json'))
    ..writeAsStringSync(_mangaJson());
  final img.Image image = img.Image(width: 1000, height: 1600);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  final File page = File(p.join(dir.path, 'p001.png'))
    ..writeAsBytesSync(img.encodePng(image));
  return _Fixture(dir: dir, mangaJson: mangaJson, page: page);
}

/// 页上现有的块（喂给扩框）。
List<MokuroBlock> _pageBlocks(File mangaJson) =>
    parseMangaJson(mangaJson.readAsStringSync()).images.first.blocks;

/// 假引擎：在裁图目录旁写一份结果 manga.json，事件流一次性给 finished。
MangaRegionEngineStarter _engineReturning(List<Map<String, Object?>> blocks) {
  return (String imageDirPath) async {
    final img.Image? crop = img.decodePng(
      File(p.join(imageDirPath, kMangaRegionCropFileName)).readAsBytesSync(),
    );
    expect(crop, isNotNull, reason: '引擎链拿到的必须是一张能解开的裁图');
    final File result = File(p.join(imageDirPath, 'result.json'))
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'pages': <Map<String, Object?>>[
            <String, Object?>{
              'url': 'region.png',
              'width': crop!.width,
              'height': crop.height,
              'blocks': blocks,
            },
          ],
        }),
      );
    return MangaOcrAutoStartResult.started(
      MangaOcrBackgroundJob(
        bookKey: 'book',
        managedDirectory: imageDirPath,
        engine: MangaOcrEngineId.localOnnx,
        events: Stream<MangaOcrBackgroundEvent>.fromIterable(
          <MangaOcrBackgroundEvent>[
            MangaOcrBackgroundEvent.finished(
              pagesTotal: 1,
              resultPath: result.path,
              external: false,
            ),
          ],
        ),
      ),
      MangaOcrEngineId.localOnnx,
    );
  };
}

void main() {
  group('runMangaRegionRescan：零写入护栏', () {
    test('引擎不可用（start.started == false）⇒ manga.json 一个字节都不变', () async {
      final _Fixture f = _fixture();
      final List<int> before = f.mangaJson.readAsBytesSync();
      final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: (String _) async =>
            const MangaOcrAutoStartResult.unavailable(
          '模型没下',
          MangaOcrEngineId.localOnnx,
        ),
      );
      expect(outcome.status, MangaRegionRescanStatus.unavailable);
      expect(outcome.unavailableReason, '模型没下');
      expect(outcome.payload, isNull);
      expect(f.mangaJson.readAsBytesSync(), before);
      expect(File('${f.mangaJson.path}.tmp').existsSync(), isFalse);
    });

    test('用户取消 ⇒ 零写入且不算失败', () async {
      final _Fixture f = _fixture();
      final List<int> before = f.mangaJson.readAsBytesSync();
      final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: (String _) async =>
            const MangaOcrAutoStartResult.cancelled(),
      );
      expect(outcome.status, MangaRegionRescanStatus.cancelled);
      expect(f.mangaJson.readAsBytesSync(), before);
    });

    test('引擎返回零块 ⇒ manga.json 一个字节都不变（绝不清空文字层）', () async {
      final _Fixture f = _fixture();
      final List<int> before = f.mangaJson.readAsBytesSync();
      final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: _engineReturning(const <Map<String, Object?>>[]),
      );
      expect(outcome.status, MangaRegionRescanStatus.empty);
      expect(outcome.payload, isNull);
      expect(
        f.mangaJson.readAsBytesSync(),
        before,
        reason: '把气泡认成「没字」再抹掉原文字层是纯损失',
      );
      expect(File('${f.mangaJson.path}.tmp').existsSync(), isFalse);
    });

    test('每条分支都把裁框临时目录删干净', () async {
      final _Fixture f = _fixture();
      Future<void> run(MangaRegionEngineStarter starter) async {
        await runMangaRegionRescan(
          imagePath: f.page.path,
          mangaJsonPath: f.mangaJson.path,
          pageIndex: 0,
          box: const Rect.fromLTRB(100, 100, 200, 200),
          pageBlocks: _pageBlocks(f.mangaJson),
          tempRoot: f.dir,
          startEngine: starter,
        );
      }

      await run((String _) async => const MangaOcrAutoStartResult.cancelled());
      await run(_engineReturning(const <Map<String, Object?>>[]));
      await run(
        _engineReturning(<Map<String, Object?>>[
          <String, Object?>{
            'box': <double>[5, 5, 45, 95],
            'vertical': true,
            'font_size': 12,
            'z_index': 0,
            'lines': <String>['新'],
          },
        ]),
      );
      expect(
        f.dir.listSync().whereType<Directory>(),
        isEmpty,
        reason: '裁框临时根目录不得残留',
      );
    });
  });

  group('runMangaRegionRescan：落地', () {
    test('部分重叠的竖排气泡整块重识别，不再静默截断', () async {
      final _Fixture f = _fixture();
      // 用户框 (100,100,200,200) 只盖住气泡 [120,120,180,220] 的上 80%。
      final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: _engineReturning(<Map<String, Object?>>[
          <String, Object?>{
            'box': <double>[20, 20, 80, 120],
            'vertical': true,
            'font_size': 12,
            'z_index': 0,
            'lines': <String>['重識別'],
          },
        ]),
      );
      expect(outcome.status, MangaRegionRescanStatus.replaced);
      // 裁图矩形被撑到覆盖整个气泡（100,100 → 200,220），而不是停在用户框的 y=200。
      expect(outcome.region, const Rect.fromLTRB(100, 100, 200, 220));

      final MokuroImage page =
          parseMangaJson(f.mangaJson.readAsStringSync()).images.first;
      expect(
        page.blocks.map((MokuroBlock b) => b.lines.single).toList(),
        <String>['重識別'],
        reason: '旧块被删，且删掉的那块整条都在裁图里被重新识别过',
      );
      // 结果块按裁图原点平移回页图坐标。
      expect(page.blocks.single.rectangle,
          const Rect.fromLTRB(120, 120, 180, 220));
      // ocr 元数据原样保留（抹掉会让整卷缓存被判异源作废）。
      expect(
        parseMangaJson(f.mangaJson.readAsStringSync()).ocr?.engineSignature,
        'sig-abc',
      );
    });

    test('交出替换前的整页快照（撤销的唯一依据）', () async {
      final _Fixture f = _fixture();
      final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: _engineReturning(<Map<String, Object?>>[
          <String, Object?>{
            'box': <double>[20, 20, 80, 120],
            'vertical': true,
            'font_size': 12,
            'z_index': 0,
            'lines': <String>['重識別'],
          },
        ]),
      );
      expect(outcome.previousPage, isNotNull);
      expect(
        outcome.previousPage!.blocks.single.lines,
        <String>['既存ブロック'],
      );
      expect(outcome.previousPage!.url, 'p001.png');
    });

    test('回调时序：onEngineStarted 在引擎起来后、onBeforeWriteback 在落盘前', () async {
      final _Fixture f = _fixture();
      final List<String> log = <String>[];
      await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: (String dir) {
          log.add('start');
          return _engineReturning(<Map<String, Object?>>[
            <String, Object?>{
              'box': <double>[20, 20, 80, 120],
              'vertical': true,
              'font_size': 12,
              'z_index': 0,
              'lines': <String>['新'],
            },
          ])(dir);
        },
        onEngineStarted: () => log.add('started'),
        onBeforeWriteback: () {
          log.add('before-writeback');
          // 落盘还没发生：几何 debounce 必须在这一刻之前被取消。
          expect(
            parseMangaJson(f.mangaJson.readAsStringSync())
                .images
                .first
                .blocks
                .single
                .lines,
            <String>['既存ブロック'],
          );
        },
      );
      expect(log, <String>['start', 'started', 'before-writeback']);
    });

    test('引擎起不来时不调 onEngineStarted / onBeforeWriteback', () async {
      final _Fixture f = _fixture();
      final List<String> log = <String>[];
      await runMangaRegionRescan(
        imagePath: f.page.path,
        mangaJsonPath: f.mangaJson.path,
        pageIndex: 0,
        box: const Rect.fromLTRB(100, 100, 200, 200),
        pageBlocks: _pageBlocks(f.mangaJson),
        tempRoot: f.dir,
        startEngine: (String _) async =>
            const MangaOcrAutoStartResult.unavailable(
          'nope',
          MangaOcrEngineId.localOnnx,
        ),
        onEngineStarted: () => log.add('started'),
        onBeforeWriteback: () => log.add('before-writeback'),
      );
      expect(log, isEmpty);
    });
  });
}
