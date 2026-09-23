import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/routing_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/text_detector.dart';
import 'package:image/image.dart' as img;

class _DeadSession implements OcrSession {
  bool closed = false;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeMangaOcr implements OcrRecognizer {
  final List<OcrRect> calls = <OcrRect>[];
  String reply = 'M';

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    calls.add(box);
    return reply;
  }
}

class _FakeBatchMangaOcr extends _FakeMangaOcr implements BatchOcrRecognizer {
  final List<List<OcrRect>> batches = <List<OcrRect>>[];
  double? emptyLeft;
  int? returnedCount;

  @override
  Future<List<String>> recognizeBatch(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    batches.add(List<OcrRect>.of(boxes));
    if (returnedCount != null) {
      return List<String>.filled(returnedCount!, 'bad count');
    }
    return <String>[
      for (final OcrRect box in boxes)
        box.left == emptyLeft ? '' : 'GPU@${box.left.toInt()}',
    ];
  }
}

class _FakeLineDetector extends PpOcrLineDetector {
  _FakeLineDetector(this.lines) : super(_DeadSession());

  final List<PpTextLine> lines;
  final List<img.Image> crops = <img.Image>[];
  List<List<PpTextLine>>? sequence;

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    crops.add(crop);
    return sequence == null ? lines : sequence!.removeAt(0);
  }
}

class _FakeLineRecognizer extends PpOcrLineRecognizer {
  _FakeLineRecognizer() : super(_DeadSession(), vocab: const <String>['']);

  final List<img.Image> lines = <img.Image>[];
  String reply = 'P';

  @override
  Future<String> recognizeLine(img.Image line) async {
    lines.add(line);
    return reply;
  }
}

PpTextLine _line(double l, double t, double r, double b) => PpTextLine(
      rect: OcrRect(left: l, top: t, right: r, bottom: b),
      score: 1,
    );

/// 与纯 Dart 复现同一组输出：父框 400x200、正文框 200x10，IoU=0.025。
class _NestedDetectionSession extends _DeadSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async =>
      <String, OcrTensor>{
        'scores': OcrTensor.float32(Float32List.fromList([0.9, 0.8]), [2]),
        'labels': OcrTensor.int64(Int64List.fromList([2, 2]), [2]),
        'boxes': OcrTensor.float32(
          Float32List.fromList([20, 20, 420, 220, 40, 140, 240, 150]),
          [2, 4],
        ),
      };
}

class _NestedLineDetector extends PpOcrLineDetector {
  _NestedLineDetector() : super(_DeadSession());
  final List<String> crops = <String>[];

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    crops.add('${crop.width}x${crop.height}');
    if (crop.width == 400 && crop.height == 200) {
      return <PpTextLine>[_line(20, 20, 380, 70), _line(20, 120, 220, 130)];
    }
    expect([crop.width, crop.height], [200, 10]);
    return <PpTextLine>[_line(0, 0, 200, 10)];
  }
}

class _NestedLineRecognizer extends PpOcrLineRecognizer {
  _NestedLineRecognizer() : super(_DeadSession(), vocab: const <String>['']);
  final List<int> heights = <int>[];

  @override
  Future<String> recognizeLine(img.Image crop) async {
    heights.add(crop.height);
    return crop.height == 10 ? 'BODY' : 'TITLE';
  }
}

void main() {
  final img.Image page = img.Image(width: 400, height: 300);

  test('父块过滤小字号 BODY 后独立内框仍能补正文，保留振假名过滤规则', () async {
    final _FakeMangaOcr manga = _FakeMangaOcr();
    final _NestedLineDetector detector = _NestedLineDetector();
    final _NestedLineRecognizer rec = _NestedLineRecognizer();
    final OcrPageResult result = await MangaOcrPipeline(
      detector: TextDetector(_NestedDetectionSession()),
      recognizer: RoutingOcrRecognizer(
        mangaOcr: manga,
        lineDetector: detector,
        lineRecognizer: rec,
      ),
    ).processPage(pageIndex: 0, image: img.Image(width: 640, height: 640));
    expect(result.blocks.map((OcrBlock b) => b.lines.single), [
      'TITLE',
      'BODY',
    ]);
    expect(detector.crops, ['400x200', '200x10']);
    // 父块仍过滤掉厚 10 的行；正文只能由自己的独立框补回。
    expect(rec.heights, [50, 10]);
    expect(manga.calls, isEmpty);
  });

  test('只有主识别器具备 batch 能力时才向 pipeline 暴露批接口', () {
    for (final OcrRecognizer main in <OcrRecognizer>[
      _FakeMangaOcr(),
      _FakeBatchMangaOcr(),
    ]) {
      final RoutingOcrRecognizer routed = RoutingOcrRecognizer(
        mangaOcr: main,
        lineDetector: _FakeLineDetector(<PpTextLine>[]),
        lineRecognizer: _FakeLineRecognizer(),
      );
      expect(routed is BatchOcrRecognizer, main is BatchOcrRecognizer);
    }
  });

  test('混排的竖框和横排空检测后备合批，PP 结果与空串保留原索引', () async {
    final _FakeBatchMangaOcr manga = _FakeBatchMangaOcr()..emptyLeft = 260;
    final _FakeLineDetector detector = _FakeLineDetector(<PpTextLine>[])
      ..sequence = <List<PpTextLine>>[
        <PpTextLine>[_line(0, 0, 180, 40)],
        <PpTextLine>[],
      ];
    final _FakeLineRecognizer lineRecognizer = _FakeLineRecognizer();
    final BatchOcrRecognizer routed = RoutingOcrRecognizer(
      mangaOcr: manga,
      lineDetector: detector,
      lineRecognizer: lineRecognizer,
    ) as BatchOcrRecognizer;
    const List<OcrRect> boxes = <OcrRect>[
      OcrRect(left: 310, top: 0, right: 350, bottom: 150),
      OcrRect(left: 20, top: 160, right: 220, bottom: 210),
      OcrRect(left: 260, top: 0, right: 300, bottom: 150),
      OcrRect(left: 0, top: 230, right: 150, bottom: 280),
    ];
    expect(await routed.recognizeBatch(page, boxes), <String>[
      'GPU@310',
      'P',
      '',
      'GPU@0',
    ]);
    expect(manga.batches.single, <OcrRect>[boxes[0], boxes[2], boxes[3]]);
    expect(manga.calls, isEmpty);
    expect(detector.crops, hasLength(2));
    expect(lineRecognizer.lines, hasLength(1));
  });

  test('横排 PP 检出但文字为空时，也加入整框 GPU 后备批次', () async {
    final _FakeBatchMangaOcr manga = _FakeBatchMangaOcr();
    final _FakeLineRecognizer lineRecognizer = _FakeLineRecognizer()
      ..reply = '';
    final BatchOcrRecognizer routed = RoutingOcrRecognizer(
      mangaOcr: manga,
      lineDetector: _FakeLineDetector(<PpTextLine>[
        _line(0, 0, 150, 40),
      ]),
      lineRecognizer: lineRecognizer,
    ) as BatchOcrRecognizer;
    const OcrRect box = OcrRect(left: 20, top: 0, right: 220, bottom: 50);
    expect(await routed.recognizeBatch(page, <OcrRect>[box]), <String>[
      'GPU@20',
    ]);
    expect(manga.batches.single, <OcrRect>[box]);
    expect(manga.calls, isEmpty);
    expect(lineRecognizer.lines, hasLength(1));
  });

  test('全横排有 PP 结果和空输入都不发空 GPU 批次', () async {
    final _FakeBatchMangaOcr manga = _FakeBatchMangaOcr();
    final _FakeLineDetector detector = _FakeLineDetector(<PpTextLine>[
      _line(0, 0, 150, 40),
    ]);
    final BatchOcrRecognizer routed = RoutingOcrRecognizer(
      mangaOcr: manga,
      lineDetector: detector,
      lineRecognizer: _FakeLineRecognizer(),
    ) as BatchOcrRecognizer;
    expect(
      await routed.recognizeBatch(page, const <OcrRect>[
        OcrRect(left: 0, top: 0, right: 200, bottom: 50),
        OcrRect(left: 0, top: 100, right: 200, bottom: 150),
      ]),
      <String>['P', 'P'],
    );
    expect(await routed.recognizeBatch(page, const <OcrRect>[]), isEmpty);
    expect(manga.batches, isEmpty);
    expect(manga.calls, isEmpty);
    expect(detector.crops, hasLength(2));
  });

  test('GPU 路由批次中的横排块仍保留竖行坐标变换、边距和拼接顺序', () async {
    final _FakeBatchMangaOcr manga = _FakeBatchMangaOcr()..reply = 'v';
    final _FakeLineRecognizer rec = _FakeLineRecognizer()..reply = 'h';
    final BatchOcrRecognizer routed = RoutingOcrRecognizer(
      mangaOcr: manga,
      lineDetector: _FakeLineDetector(<PpTextLine>[
        _line(10, 40, 290, 70),
        _line(10, 30, 290, 36),
        _line(200, 5, 220, 95),
      ]),
      lineRecognizer: rec,
    ) as BatchOcrRecognizer;
    expect(
      await routed.recognizeBatch(page, const <OcrRect>[
        OcrRect(left: 50, top: 100, right: 350, bottom: 200),
      ]),
      <String>['vh'],
    );
    final OcrRect line = manga.calls.single;
    expect(
      <double>[line.left, line.top, line.right, line.bottom],
      <double>[246, 101, 274, 199],
    );
    expect(manga.batches, isEmpty);
    expect(rec.lines.single.width, 280);
    expect(rec.lines.single.height, 30);
  });

  test('GPU 后端结果不等长时抛错，不能把文本拼到另一框', () async {
    final _FakeBatchMangaOcr manga = _FakeBatchMangaOcr()..returnedCount = 1;
    final BatchOcrRecognizer routed = RoutingOcrRecognizer(
      mangaOcr: manga,
      lineDetector: _FakeLineDetector(<PpTextLine>[]),
      lineRecognizer: _FakeLineRecognizer(),
    ) as BatchOcrRecognizer;
    await expectLater(
      routed.recognizeBatch(page, const <OcrRect>[
        OcrRect(left: 0, top: 0, right: 40, bottom: 150),
        OcrRect(left: 60, top: 0, right: 100, bottom: 150),
      ]),
      throwsA(isA<StateError>()),
    );
  });

  test('routesToHorizontalPath：宽 ≥ 高才走横排路径', () {
    expect(
      routesToHorizontalPath(
        const OcrRect(left: 0, top: 0, right: 100, bottom: 100),
      ),
      isTrue,
    );
    expect(
      routesToHorizontalPath(
        const OcrRect(left: 0, top: 0, right: 98, bottom: 121),
      ),
      isFalse,
    );
  });

  test('竖排块：只调 manga-ocr，PP 一步不跑', () async {
    final _FakeMangaOcr mangaOcr = _FakeMangaOcr();
    final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[]);
    final _FakeLineRecognizer rec = _FakeLineRecognizer();
    final RoutingOcrRecognizer r = RoutingOcrRecognizer(
      mangaOcr: mangaOcr,
      lineDetector: det,
      lineRecognizer: rec,
    );
    const OcrRect box = OcrRect(left: 10, top: 10, right: 60, bottom: 200);
    expect(await r.recognize(page, box), 'M');
    expect(mangaOcr.calls, <OcrRect>[box]);
    expect(det.crops, isEmpty);
    expect(rec.lines, isEmpty);
  });

  test('横排块：切行后横行走 PP rec、竖行回页面坐标带边距喂 manga-ocr、按阅读序拼接', () async {
    final _FakeMangaOcr mangaOcr = _FakeMangaOcr()..reply = 'v';
    // 裁图 300×100 内：一条横行、一条细振假名行（被过滤）、一条竖行。
    final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
      _line(10, 40, 290, 70), // 横行，厚 30
      _line(10, 30, 290, 36), // 厚 6 → 振假名
      _line(200, 5, 220, 95), // 竖行（top=5 排在横行之前）
    ]);
    final _FakeLineRecognizer rec = _FakeLineRecognizer()..reply = 'h';
    final RoutingOcrRecognizer r = RoutingOcrRecognizer(
      mangaOcr: mangaOcr,
      lineDetector: det,
      lineRecognizer: rec,
    );
    const OcrRect box = OcrRect(left: 50, top: 100, right: 350, bottom: 200);
    expect(await r.recognize(page, box), 'vh');

    expect(det.crops.single.width, 300);
    expect(det.crops.single.height, 100);
    // 竖行：裁图坐标 (200,5)-(220,95) → 页面 (250,105)-(270,195) 再各扩 4。
    final OcrRect v = mangaOcr.calls.single;
    expect(v.left, 246);
    expect(v.top, 101);
    expect(v.right, 274);
    expect(v.bottom, 199);
    // 横行裁图尺寸 = 行框尺寸。
    expect(rec.lines.single.width, 280);
    expect(rec.lines.single.height, 30);
  });

  test('横排块但 PP 没检到行：回落整块 manga-ocr', () async {
    final _FakeMangaOcr mangaOcr = _FakeMangaOcr()..reply = 'whole';
    final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[]);
    final RoutingOcrRecognizer r = RoutingOcrRecognizer(
      mangaOcr: mangaOcr,
      lineDetector: det,
      lineRecognizer: _FakeLineRecognizer(),
    );
    const OcrRect box = OcrRect(left: 0, top: 0, right: 200, bottom: 50);
    expect(await r.recognize(page, box), 'whole');
    expect(mangaOcr.calls, <OcrRect>[box]);
  });

  test('横排块 PP 识别为空串：回落整块 manga-ocr', () async {
    final _FakeMangaOcr mangaOcr = _FakeMangaOcr()..reply = 'whole';
    final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
      _line(0, 0, 200, 50),
    ]);
    final _FakeLineRecognizer rec = _FakeLineRecognizer()..reply = '';
    final RoutingOcrRecognizer r = RoutingOcrRecognizer(
      mangaOcr: mangaOcr,
      lineDetector: det,
      lineRecognizer: rec,
    );
    const OcrRect box = OcrRect(left: 0, top: 0, right: 200, bottom: 50);
    expect(await r.recognize(page, box), 'whole');
    expect(rec.lines, hasLength(1));
    expect(mangaOcr.calls, <OcrRect>[box]);
  });
}
