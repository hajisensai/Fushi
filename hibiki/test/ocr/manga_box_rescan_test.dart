/// P4 单框补扫服务测试：裁剪坐标正确性（已知像素图）、竖排判定、
/// isolate 路径（顶层 fake bootstrap 走真 Isolate.spawn，不碰 ORT）、
/// 服务层就绪判定与 fake runner 组装。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/ocr/manga_box_rescan.dart';
import 'package:hibiki/src/ocr/manga_ocr_model_manifest.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';

/// 已知像素图：pixel(x, y) 的 r 通道 = x*10 + y（8x8 内不溢出）。
img.Image _gridImage({int width = 8, int height = 8}) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x * 10 + y, 0, 0);
    }
  }
  return image;
}

/// isolate 内的回声识别器：把「解码出的页尺寸 + 收到的框 + 裁剪结果首像素」
/// 编码回文本，验证 isolate 全链路（解码/参数传递/裁剪几何）。
class _EchoRecognizer implements OcrRecognizer {
  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    final img.Image crop = cropMangaBoxRegion(page, box);
    final img.Pixel p0 = crop.getPixel(0, 0);
    return '${page.width}x${page.height}'
        '|${box.left.round()},${box.top.round()},'
        '${box.right.round()},${box.bottom.round()}'
        '|${crop.width}x${crop.height}'
        '|${p0.r.toInt()}';
  }
}

/// 顶层 bootstrap（跨 isolate 可发送），替代真 ORT 会话构建。
Future<OcrRecognizer> echoBootstrap(MangaRescanModelPaths paths) async {
  return _EchoRecognizer();
}

/// 进程内 fake runner（服务层组装测试用）。
class _FakeRunner implements MangaBoxRescanRunner {
  final List<(String, OcrRect)> calls = <(String, OcrRect)>[];
  bool disposed = false;

  @override
  Future<String> recognize(String imagePath, OcrRect box) async {
    calls.add((imagePath, box));
    return 'テスト';
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Directory _tempDir(String prefix) {
  final Directory dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 在临时模型目录里放识别三件套（非空占位即视为就绪；detector 刻意不放）。
Directory _readyModelsDir() {
  final Directory dir = _tempDir('manga_rescan_models_');
  for (final String name in <String>[
    'encoder_model.onnx',
    'decoder_model.onnx',
    'vocab.txt',
  ]) {
    File(p.join(dir.path, name)).writeAsBytesSync(<int>[1, 2, 3]);
  }
  return dir;
}

void main() {
  group('纯函数', () {
    test('cropMangaBoxRegion 裁剪坐标正确（已知像素图断言裁剪区域）', () {
      final img.Image page = _gridImage();
      final img.Image crop = cropMangaBoxRegion(
        page,
        const OcrRect(left: 2, top: 1, right: 5, bottom: 4),
      );
      expect(crop.width, 3);
      expect(crop.height, 3);
      // 左上角像素 = 原图 (2,1)，r = 2*10+1 = 21。
      expect(crop.getPixel(0, 0).r.toInt(), 21);
      // 右下角像素 = 原图 (4,3)，r = 4*10+3 = 43。
      expect(crop.getPixel(2, 2).r.toInt(), 43);
    });

    test('cropMangaBoxRegion 越界框 clamp 页内、最小 1px', () {
      final img.Image page = _gridImage();
      final img.Image crop = cropMangaBoxRegion(
        page,
        const OcrRect(left: -5, top: -5, right: 100, bottom: 100),
      );
      expect(crop.width, 8);
      expect(crop.height, 8);
      final img.Image tiny = cropMangaBoxRegion(
        page,
        const OcrRect(left: 3, top: 3, right: 3, bottom: 3),
      );
      expect(tiny.width, greaterThanOrEqualTo(1));
      expect(tiny.height, greaterThanOrEqualTo(1));
    });

    test('mangaBoxIsVertical：高/宽 > 1.5 判竖排', () {
      expect(
          mangaBoxIsVertical(
              const OcrRect(left: 0, top: 0, right: 10, bottom: 16)),
          isTrue,
          reason: '16/10 > 1.5 → 竖排');
      expect(
          mangaBoxIsVertical(
              const OcrRect(left: 0, top: 0, right: 10, bottom: 15)),
          isFalse,
          reason: '15/10 == 1.5（不大于）→ 横排');
      expect(
          mangaBoxIsVertical(
              const OcrRect(left: 0, top: 0, right: 200, bottom: 60)),
          isFalse);
    });
  });

  group('isolate 路径（真 Isolate.spawn + 顶层 fake bootstrap）', () {
    test('解码页图、透传框坐标、按框裁剪', () async {
      final Directory dir = _tempDir('manga_rescan_iso_');
      final String imagePath = p.join(dir.path, 'page.png');
      File(imagePath)
          .writeAsBytesSync(img.encodePng(_gridImage(width: 20, height: 10)));

      final IsolateMangaBoxRescanRunner runner = IsolateMangaBoxRescanRunner(
        modelPaths: const MangaRescanModelPaths(
          encoderPath: 'unused',
          decoderPath: 'unused',
          vocabPath: 'unused',
        ),
        bootstrap: echoBootstrap,
      );
      addTearDown(runner.dispose);

      final String text = await runner.recognize(
        imagePath,
        const OcrRect(left: 5, top: 2, right: 9, bottom: 6),
      );
      // 页尺寸解码正确 | 框透传 | 裁剪 4x4 | 裁剪首像素 = 原图 (5,2) 的 52。
      expect(text, '20x10|5,2,9,6|4x4|52');
    });

    test('会话复用：同一 runner 连续两次请求（懒建一次 bootstrap）', () async {
      final Directory dir = _tempDir('manga_rescan_iso2_');
      final String imagePath = p.join(dir.path, 'page.png');
      File(imagePath).writeAsBytesSync(img.encodePng(_gridImage()));

      final IsolateMangaBoxRescanRunner runner = IsolateMangaBoxRescanRunner(
        modelPaths: const MangaRescanModelPaths(
          encoderPath: 'unused',
          decoderPath: 'unused',
          vocabPath: 'unused',
        ),
        bootstrap: echoBootstrap,
      );
      addTearDown(runner.dispose);

      final String first = await runner.recognize(
          imagePath, const OcrRect(left: 0, top: 0, right: 4, bottom: 4));
      final String second = await runner.recognize(
          imagePath, const OcrRect(left: 1, top: 1, right: 5, bottom: 5));
      expect(first, startsWith('8x8|0,0,4,4'));
      expect(second, startsWith('8x8|1,1,5,5'));
    });

    test('图片缺失经 isolate 回报为错误（不是挂死）', () async {
      final IsolateMangaBoxRescanRunner runner = IsolateMangaBoxRescanRunner(
        modelPaths: const MangaRescanModelPaths(
          encoderPath: 'unused',
          decoderPath: 'unused',
          vocabPath: 'unused',
        ),
        bootstrap: echoBootstrap,
      );
      addTearDown(runner.dispose);
      await expectLater(
        runner.recognize('Z:/definitely/missing.png',
            const OcrRect(left: 0, top: 0, right: 4, bottom: 4)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MangaBoxRescanService', () {
    test('就绪判定只看识别三件套（无检测器也就绪）', () async {
      final Directory ready = _readyModelsDir();
      final MangaBoxRescanService service = MangaBoxRescanService(
        modelsDirProvider: () async => ready,
      );
      addTearDown(service.dispose);
      expect(await service.isRecognizerReady(), isTrue);

      final Directory empty = _tempDir('manga_rescan_empty_');
      final MangaBoxRescanService notReady = MangaBoxRescanService(
        modelsDirProvider: () async => empty,
      );
      addTearDown(notReady.dispose);
      expect(await notReady.isRecognizerReady(), isFalse);
    });

    test('rescan：fake runner 组装 + 竖排判定落进结果', () async {
      final Directory ready = _readyModelsDir();
      final _FakeRunner runner = _FakeRunner();
      MangaRescanModelPaths? seenPaths;
      final MangaBoxRescanService service = MangaBoxRescanService(
        modelsDirProvider: () async => ready,
        runnerFactory: (MangaRescanModelPaths paths) {
          seenPaths = paths;
          return runner;
        },
      );

      final MangaBoxRescanResult vertical = await service.rescan(
        imagePath: 'page.png',
        box: const OcrRect(left: 0, top: 0, right: 40, bottom: 200),
      );
      expect(vertical.text, 'テスト');
      expect(vertical.vertical, isTrue);

      final MangaBoxRescanResult horizontal = await service.rescan(
        imagePath: 'page.png',
        box: const OcrRect(left: 0, top: 0, right: 200, bottom: 40),
      );
      expect(horizontal.vertical, isFalse);

      // runner 懒建一次、复用（页面生命周期内会话缓存）。
      expect(runner.calls.length, 2);
      expect(seenPaths, isNotNull);
      expect(seenPaths!.encoderPath, endsWith('encoder_model.onnx'));
      expect(seenPaths!.decoderPath, endsWith('decoder_model.onnx'));
      expect(seenPaths!.vocabPath, endsWith('vocab.txt'));

      await service.dispose();
      expect(runner.disposed, isTrue);
    });

    test('模型未就绪时 rescan 抛 StateError（不建 runner）', () async {
      final Directory empty = _tempDir('manga_rescan_gate_');
      bool factoryCalled = false;
      final MangaBoxRescanService service = MangaBoxRescanService(
        modelsDirProvider: () async => empty,
        runnerFactory: (MangaRescanModelPaths paths) {
          factoryCalled = true;
          return _FakeRunner();
        },
      );
      addTearDown(service.dispose);
      await expectLater(
        service.rescan(
          imagePath: 'page.png',
          box: const OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        ),
        throwsA(isA<StateError>()),
      );
      expect(factoryCalled, isFalse);
    });

    test('cropBoxPng：后台裁剪 + PNG 编码（可解码、尺寸正确）', () async {
      final Directory dir = _tempDir('manga_rescan_png_');
      final String imagePath = p.join(dir.path, 'page.png');
      File(imagePath)
          .writeAsBytesSync(img.encodePng(_gridImage(width: 20, height: 10)));
      final Uint8List png = await MangaBoxRescanService.cropBoxPng(
        imagePath: imagePath,
        box: const OcrRect(left: 5, top: 2, right: 9, bottom: 6),
      );
      final img.Image? decoded = img.decodeImage(png);
      expect(decoded, isNotNull);
      expect(decoded!.width, 4);
      expect(decoded.height, 4);
      expect(decoded.getPixel(0, 0).r.toInt(), 52);
    });

    test('清单契约：识别三件套在清单里（role=recognizer，供就绪判定/路径解析）', () {
      final Iterable<String> recognizerFiles = kMangaOcrModelManifest
          .where(
              (MangaOcrModelFile f) => f.role == MangaOcrModelRole.recognizer)
          .map((MangaOcrModelFile f) => f.fileName);
      expect(
          recognizerFiles,
          containsAll(<String>[
            'encoder_model.onnx',
            'decoder_model.onnx',
            'vocab.txt'
          ]));
    });
  });
}
