import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart';
import 'package:hibiki/src/ocr/manga_ocr_pipeline.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 每页一个居中文字块的 fake 检测器，记录检测过的页尺寸。
class _FakeDetector implements OcrDetector {
  final List<String> detectedSizes = <String>[];

  @override
  Future<PageDetections> detect(img.Image page) async {
    detectedSizes.add('${page.width}x${page.height}');
    return PageDetections(
      textRegions: <DetectedTextRegion>[
        DetectedTextRegion(
          rect: OcrRect(
            left: 1,
            top: 1,
            right: page.width - 1.0,
            bottom: page.height - 1.0,
          ),
          score: 0.9,
          classId: 1,
          insideBubble: true,
        ),
      ],
      bubbles: const <OcrRect>[],
    );
  }
}

/// 用页宽标记文本的 fake 识别器（页宽在本测试里逐页唯一）。
class _FakeRecognizer implements OcrRecognizer {
  int calls = 0;

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    calls++;
    return 'text-w${page.width}';
  }
}

/// 写一张 [width]x[height] 的真实 PNG（走真实解码路径）。
void _writePng(String path, int width, int height) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(img.Image(width: width, height: height)));
}

/// 写一张 [width]x[height] 的真实 BMP（BUG-1121：bmp 页必须走完整解码路径）。
void _writeBmp(String path, int width, int height) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodeBmp(img.Image(width: width, height: height)));
}

void main() {
  group('naturalCompare', () {
    test('数字段按数值比较', () {
      expect(naturalCompare('p2.jpg', 'p10.jpg'), lessThan(0));
      expect(naturalCompare('p10.jpg', 'p2.jpg'), greaterThan(0));
      expect(naturalCompare('p002.jpg', 'p2.jpg'), greaterThan(0),
          reason: '数值相等时位数少的在前（全序稳定）');
      expect(naturalCompare('a.jpg', 'a.jpg'), 0);
      expect(naturalCompare('ch1/p1.jpg', 'ch2/p1.jpg'), lessThan(0));
      expect(naturalCompare('A1.jpg', 'a2.jpg'), lessThan(0), reason: '大小写不敏感');
    });
  });

  group('estimateMangaFontSize', () {
    test('sqrt(面积/字符数) 估计', () {
      const OcrBlock block = OcrBlock(
        box: OcrRect(left: 0, top: 0, right: 40, bottom: 90),
        vertical: true,
        lines: <String>['あいうえ', 'かきくけこ'], // 9 字，面积 3600 → 20px
      );
      expect(estimateMangaFontSize(block), closeTo(20, 0.001));
    });

    test('无字符 / 零面积回 0（渲染端有兜底）', () {
      const OcrBlock empty = OcrBlock(
        box: OcrRect(left: 0, top: 0, right: 40, bottom: 90),
        vertical: false,
        lines: <String>[],
      );
      expect(estimateMangaFontSize(empty), 0);
      const OcrBlock zeroArea = OcrBlock(
        box: OcrRect(left: 5, top: 5, right: 5, bottom: 5),
        vertical: false,
        lines: <String>['あ'],
      );
      expect(estimateMangaFontSize(zeroArea), 0);
    });
  });

  test('组装 payload 时升级旧缓存中的倾斜竖排方向', () {
    const OcrPageResult cached = OcrPageResult(
      pageIndex: 0,
      imageWidth: 100,
      imageHeight: 140,
      blocks: <OcrBlock>[
        OcrBlock(
          box: OcrRect(left: 0, top: 0, right: 100, bottom: 140),
          vertical: false,
          lines: <String>['進化を体感'],
        ),
      ],
    );

    final MokuroPayload payload = buildMangaPayloadFromResults(
      <MangaOcrPageFile>[
        MangaOcrPageFile(file: File('unused.jpg'), relativeUrl: 'page.jpg'),
      ],
      const <OcrPageResult>[cached],
    );

    expect(payload.images.single.blocks.single.isVertical, isTrue);
  });

  group('ocrPageCacheFileName', () {
    test('子目录斜杠折叠', () {
      expect(ocrPageCacheFileName('p001.jpg'), 'p001.jpg.json');
      expect(ocrPageCacheFileName('vol1/p001.jpg'), 'vol1__p001.jpg.json');
    });
  });

  group('enumerateMangaPages', () {
    test('递归下钻、白名单扩展名、排除产物目录、自然序', () {
      final Directory root = Directory.systemTemp.createTempSync('manga_enum_');
      addTearDown(() => root.deleteSync(recursive: true));
      _writePng(p.join(root.path, 'p10.png'), 10, 10);
      _writePng(p.join(root.path, 'p2.png'), 10, 10);
      _writePng(p.join(root.path, 'extra', 'p1.png'), 10, 10);
      // bmp 页：导入白名单认它，OCR 枚举也必须收（BUG-1121）。
      _writeBmp(p.join(root.path, 'p3.bmp'), 10, 10);
      // 二层子目录：**要收**。已入库书的页图在 `images/<源子目录>/页`，
      // mokuro.moe 的卷 CBZ 顶层带 `<卷名>/`，页图正落在这一层；旧实现只扫一层
      // 子目录，整本书一页都枚举不到（BUG-1434）。
      _writePng(p.join(root.path, 'extra', 'deep', 'x.png'), 10, 10);
      // 产物目录里的图：不收。
      _writePng(p.join(root.path, kMangaOcrOutDirName, 'y.png'), 10, 10);
      // 嵌套在子目录里的产物目录：同样不收。
      _writePng(
          p.join(root.path, 'extra', kMangaOcrOutDirName, 'z.png'), 10, 10);
      // 非图片：不收。
      File(p.join(root.path, 'note.txt')).writeAsStringSync('x');

      final List<MangaOcrPageFile> pages = enumerateMangaPages(root);
      expect(
        pages.map((MangaOcrPageFile page) => page.relativeUrl).toList(),
        <String>[
          'extra/deep/x.png',
          'extra/p1.png',
          'p2.png',
          'p3.bmp',
          'p10.png',
        ],
        reason: '正斜杠相对 url + 自然序（p2 < p3 < p10）',
      );
    });

    test('下钻深度封顶 kMangaPageScanMaxDepth，更深的不收', () {
      final Directory root =
          Directory.systemTemp.createTempSync('manga_enum_deep_');
      addTearDown(() => root.deleteSync(recursive: true));
      // 恰好在上限层：收。
      final List<String> atLimit = <String>[
        root.path,
        for (int i = 0; i < kMangaPageScanMaxDepth; i++) 'd$i',
        'ok.png',
      ];
      _writePng(p.joinAll(atLimit), 10, 10);
      // 再深一层：不收（防误选磁盘根时走穿整棵树）。
      final List<String> tooDeep = <String>[
        root.path,
        for (int i = 0; i < kMangaPageScanMaxDepth + 1; i++) 'e$i',
        'nope.png',
      ];
      _writePng(p.joinAll(tooDeep), 10, 10);

      final List<String> urls = enumerateMangaPages(root)
          .map((MangaOcrPageFile page) => page.relativeUrl)
          .toList();
      expect(urls, hasLength(1));
      expect(urls.single, endsWith('ok.png'));
    });
  });

  group('runMangaOcrFolderJob', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('manga_job_');
      // 页宽逐页唯一（40/50/60），fake 识别文本借页宽定位页。
      _writePng(p.join(root.path, 'p1.png'), 40, 80);
      _writePng(p.join(root.path, 'p2.png'), 50, 80);
      _writePng(p.join(root.path, 'p3.png'), 60, 80);
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('解码时烘焙 EXIF 方向，OCR 坐标与浏览器显示坐标一致', () async {
      final img.Image encoded = img.Image(width: 40, height: 80)
        ..exif.imageIfd.orientation = 6;
      final File page = File(p.join(root.path, 'oriented.jpg'));
      page.writeAsBytesSync(img.encodeJpg(encoded));

      final img.Image decoded = await decodeMangaPageFile(page);

      expect(decoded.width, 80);
      expect(decoded.height, 40);
      expect(decoded.exif.imageIfd.hasOrientation, isFalse);
    });

    test('全卷：逐页进度、manga.json 内容（url/尺寸/块）、缓存落盘', () async {
      final _FakeDetector detector = _FakeDetector();
      final _FakeRecognizer recognizer = _FakeRecognizer();
      final List<List<int>> progress = <List<int>>[];

      final String outPath = await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: detector,
        recognizer: recognizer,
        onProgress: (int done, int total) => progress.add(<int>[done, total]),
      );

      expect(progress, <List<int>>[
        <int>[1, 3],
        <int>[2, 3],
        <int>[3, 3],
      ]);
      expect(outPath,
          p.join(root.path, kMangaOcrOutDirName, kMangaOcrOutputFileName));

      final MokuroPayload payload =
          parseMangaJson(File(outPath).readAsStringSync());
      expect(payload.images, hasLength(3));
      expect(
        payload.images.map((MokuroImage image) => image.url).toList(),
        <String>['p1.png', 'p2.png', 'p3.png'],
      );
      expect(payload.images[1].size.width, 50);
      expect(payload.images[1].size.height, 80);
      expect(payload.images[0].blocks, hasLength(1));
      expect(payload.images[0].blocks.single.lines.single, 'text-w40');
      expect(payload.images[0].blocks.single.fontSize, greaterThan(0));

      // 逐页断点缓存：一页一文件。
      final Directory cacheDir = Directory(
        p.join(
          root.path,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          kLocalMangaOcrEngineSignature,
        ),
      );
      expect(
        cacheDir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        containsAll(<String>['p1.png.json', 'p2.png.json', 'p3.png.json']),
      );
    });

    test('取消：页边界停 + 已完成页缓存保留；重跑只补缺页', () async {
      final _FakeDetector detector = _FakeDetector();
      final _FakeRecognizer recognizer = _FakeRecognizer();
      final OcrCancelToken token = OcrCancelToken();

      await expectLater(
        runMangaOcrFolderJob(
          imageDirPath: root.path,
          engineSignature: kLocalMangaOcrEngineSignature,
          detector: detector,
          recognizer: recognizer,
          cancelToken: token,
          onProgress: (int done, int total) {
            if (done == 1) token.cancel();
          },
        ),
        throwsA(isA<OcrCancelledException>()),
      );
      expect(detector.detectedSizes, <String>['40x80'], reason: '取消后第二页不应再检测');

      // 重跑：第一页命中缓存，检测只补 p2/p3。
      final _FakeDetector detector2 = _FakeDetector();
      final String outPath = await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: detector2,
        recognizer: recognizer,
      );
      expect(detector2.detectedSizes, <String>['50x80', '60x80']);
      final MokuroPayload payload =
          parseMangaJson(File(outPath).readAsStringSync());
      expect(payload.images, hasLength(3));
      expect(payload.images[0].blocks.single.lines.single, 'text-w40',
          reason: '缓存页的识别结果必须原样进入 manga.json');
    });

    // BUG-1173：缓存目录名带模型内容指纹，换模型后必须整卷重跑而不是复用旧结果。
    test('引擎签名不同（换模型）时不复用旧页缓存', () async {
      const String oldSignature = '$kLocalMangaOcrEngineSignature-aaaaaaaaaaaa';
      const String newSignature = '$kLocalMangaOcrEngineSignature-bbbbbbbbbbbb';
      final _FakeRecognizer recognizer = _FakeRecognizer();
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: oldSignature,
        detector: _FakeDetector(),
        recognizer: recognizer,
      );
      final int callsAfterFirstRun = recognizer.calls;
      expect(callsAfterFirstRun, greaterThan(0));

      // 同签名重跑：全部命中缓存，识别器一次都不再调用。
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: oldSignature,
        detector: _FakeDetector(),
        recognizer: recognizer,
      );
      expect(recognizer.calls, callsAfterFirstRun, reason: '同模型必须走断点缓存');

      // 换模型（签名变）：旧结果不得复用，整卷重跑。
      final _FakeDetector newDetector = _FakeDetector();
      final String outPath = await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: newSignature,
        detector: newDetector,
        recognizer: recognizer,
      );
      expect(newDetector.detectedSizes, <String>['40x80', '50x80', '60x80'],
          reason: '换模型后每页都要重新检测，不能沿用另一份模型的缓存');
      expect(recognizer.calls, greaterThan(callsAfterFirstRun));

      final Directory cacheRoot = Directory(
          p.join(root.path, kMangaOcrOutDirName, kMangaOcrPagesCacheDirName));
      expect(
          Directory(p.join(cacheRoot.path, oldSignature)).existsSync(), isTrue);
      expect(
          Directory(p.join(cacheRoot.path, newSignature)).existsSync(), isTrue);
      expect(
        parseMangaJson(File(outPath).readAsStringSync()).ocr?.engineSignature,
        newSignature,
        reason: '产物元数据必须记录真正产出它的引擎签名',
      );
    });

    test('含 .bmp 页：整卷 OCR 真实解码、不再静默跳过（BUG-1121）', () async {
      final Directory mixed = Directory.systemTemp.createTempSync('manga_bmp_');
      addTearDown(() => mixed.deleteSync(recursive: true));
      _writePng(p.join(mixed.path, 'p1.png'), 40, 80);
      _writeBmp(p.join(mixed.path, 'p2.bmp'), 50, 80);

      final _FakeDetector detector = _FakeDetector();
      final String outPath = await runMangaOcrFolderJob(
        imageDirPath: mixed.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: detector,
        recognizer: _FakeRecognizer(),
      );

      expect(detector.detectedSizes, <String>['40x80', '50x80'],
          reason: 'bmp 页必须真实解码并进入检测，而非被扩展名白名单静默跳过');
      final MokuroPayload payload =
          parseMangaJson(File(outPath).readAsStringSync());
      expect(
        payload.images.map((MokuroImage image) => image.url).toList(),
        <String>['p1.png', 'p2.bmp'],
        reason: '产物 manga.json 必须包含 bmp 页（不缺页）',
      );
    });

    test('空目录报错（不产出空 manga.json）', () async {
      final Directory empty =
          Directory.systemTemp.createTempSync('manga_empty_');
      addTearDown(() => empty.deleteSync(recursive: true));
      await expectLater(
        runMangaOcrFolderJob(
          imageDirPath: empty.path,
          engineSignature: kLocalMangaOcrEngineSignature,
          detector: _FakeDetector(),
          recognizer: _FakeRecognizer(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('损坏缓存当 miss：该页重跑', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer();
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: _FakeDetector(),
        recognizer: recognizer,
      );
      // 毁掉第二页缓存。
      File(p.join(root.path, kMangaOcrOutDirName, kMangaOcrPagesCacheDirName,
              kLocalMangaOcrEngineSignature, 'p2.png.json'))
          .writeAsStringSync('not json');
      final _FakeDetector detector = _FakeDetector();
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: detector,
        recognizer: recognizer,
      );
      expect(detector.detectedSizes, <String>['50x80'], reason: '只有损坏缓存的页重新检测');
    });

    test('源图变化只失效对应页缓存', () async {
      final _FakeRecognizer recognizer = _FakeRecognizer();
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: _FakeDetector(),
        recognizer: recognizer,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      _writePng(p.join(root.path, 'p2.png'), 55, 80);

      final _FakeDetector detector = _FakeDetector();
      await runMangaOcrFolderJob(
        imageDirPath: root.path,
        engineSignature: kLocalMangaOcrEngineSignature,
        detector: detector,
        recognizer: recognizer,
      );
      expect(detector.detectedSizes, <String>['55x80']);
    });
  });
}
