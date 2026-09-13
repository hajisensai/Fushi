import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:image/image.dart' as img;

class _FakeSession implements OcrSession {
  _FakeSession(this.outputs);

  final Map<String, OcrTensor> outputs;
  final List<Map<String, OcrTensor>> receivedInputs =
      <Map<String, OcrTensor>>[];
  bool closed = false;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    receivedInputs.add(inputs);
    return outputs;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 概率图：全 0，[rects] 里每个 (l,t,r,b) 半开区间填 [value]。
Float32List _probMap(
  int w,
  int h,
  List<List<int>> rects, {
  double value = 0.9,
}) {
  final Float32List prob = Float32List(w * h);
  for (final List<int> r in rects) {
    for (int y = r[1]; y < r[3]; y++) {
      for (int x = r[0]; x < r[2]; x++) {
        prob[y * w + x] = value;
      }
    }
  }
  return prob;
}

PpTextLine _line(double l, double t, double r, double b) => PpTextLine(
  rect: OcrRect(left: l, top: t, right: r, bottom: b),
  score: 1,
);

void main() {
  group('ppDetInputSize', () {
    test('短边 ≥ 64：原尺寸取整到 32 倍数', () {
      final ({int width, int height}) s = ppDetInputSize(800, 190);
      expect(s.width, 800);
      expect(s.height, 192);
    });

    test('短边 < 64：按短边放大到 64 再取整', () {
      final ({int width, int height}) s = ppDetInputSize(300, 40);
      // ratio = 1.6：300*1.6=480 → 480；40*1.6=64 → 64。
      expect(s.width, 480);
      expect(s.height, 64);
    });

    test('极小图不低于 32', () {
      final ({int width, int height}) s = ppDetInputSize(5, 5);
      expect(s.width, greaterThanOrEqualTo(32));
      expect(s.height, greaterThanOrEqualTo(32));
    });

    test('非法尺寸抛异常', () {
      expect(() => ppDetInputSize(0, 10), throwsArgumentError);
    });
  });

  group('ppDetPreprocess', () {
    test('BGR 通道序 + ImageNet 归一化、CHW 布局', () {
      final img.Image src = img.Image(width: 32, height: 32);
      img.fill(src, color: img.ColorRgb8(255, 0, 0)); // 纯红
      final Float32List chw = ppDetPreprocess(src, 32, 32);
      const int plane = 32 * 32;
      // channel0 = B = 0 → (0 - 0.485) / 0.229
      expect(chw[0], closeTo((0 - 0.485) / 0.229, 1e-5));
      expect(chw[plane], closeTo((0 - 0.456) / 0.224, 1e-5));
      // channel2 = R = 1 → (1 - 0.406) / 0.225
      expect(chw[2 * plane], closeTo((1 - 0.406) / 0.225, 1e-5));
    });
  });

  group('ppDetPostprocess', () {
    test('两条横排行 → 两个框，unclip 四边外扩 area*ratio/perimeter', () {
      const int w = 100, h = 60;
      final Float32List prob = _probMap(w, h, <List<int>>[
        <int>[10, 10, 90, 20],
        <int>[10, 35, 90, 45],
      ]);
      final List<PpTextLine> lines = ppDetPostprocess(prob, w, h);
      expect(lines, hasLength(2));
      // 80×10 的域：d = 800*1.4/(2*90) ≈ 6.22
      const double d = 800 * 1.4 / 180;
      expect(lines[0].rect.left, closeTo(10 - d, 1e-6));
      expect(lines[0].rect.top, closeTo(10 - d, 1e-6));
      expect(lines[0].rect.right, closeTo(90 + d, 1e-6));
      expect(lines[0].rect.bottom, closeTo(20 + d, 1e-6));
      expect(lines[0].vertical, isFalse);
      expect(lines[0].score, closeTo(0.9, 1e-6));
    });

    test('域内均值低于 box_thresh 的连通域丢弃', () {
      const int w = 50, h = 50;
      final Float32List prob = _probMap(w, h, <List<int>>[
        <int>[5, 5, 45, 15],
      ], value: 0.3);
      expect(ppDetPostprocess(prob, w, h), isEmpty);
      // 阈值可注入：放宽后同一张图保留。
      expect(ppDetPostprocess(prob, w, h, boxThresh: 0.2), hasLength(1));
    });

    test('外扩后 clamp 在概率图内', () {
      const int w = 40, h = 40;
      final Float32List prob = _probMap(w, h, <List<int>>[
        <int>[0, 0, 40, 40],
      ]);
      final List<PpTextLine> lines = ppDetPostprocess(prob, w, h);
      expect(lines.single.rect.left, 0);
      expect(lines.single.rect.top, 0);
      expect(lines.single.rect.right, 40);
      expect(lines.single.rect.bottom, 40);
    });

    test('竖条判竖排（高 ≥ 1.5 宽）', () {
      const int w = 60, h = 100;
      final Float32List prob = _probMap(w, h, <List<int>>[
        <int>[20, 5, 30, 95],
      ]);
      expect(ppDetPostprocess(prob, w, h).single.vertical, isTrue);
    });
  });

  group('filterThinLines', () {
    test('细于 0.6 × p75 厚度的行（振假名）丢弃', () {
      final List<PpTextLine> lines = <PpTextLine>[
        _line(0, 0, 100, 20), // 厚 20
        _line(0, 30, 100, 50), // 厚 20
        _line(0, 60, 100, 80), // 厚 20
        _line(0, 22, 100, 28), // 厚 6 → 振假名
      ];
      final List<PpTextLine> kept = filterThinLines(lines);
      expect(kept, hasLength(3));
      expect(kept.any((PpTextLine l) => l.rect.top == 22), isFalse);
    });

    test('空列表原样返回', () {
      expect(filterThinLines(<PpTextLine>[]), isEmpty);
    });
  });

  group('orderLinesForReading', () {
    test('横排占多数：自上而下、同高从左到右', () {
      final List<PpTextLine> ordered = orderLinesForReading(<PpTextLine>[
        _line(50, 30, 150, 40),
        _line(0, 0, 100, 10),
        _line(0, 30, 40, 40),
      ]);
      expect(ordered.map((PpTextLine l) => l.rect.top).toList(), <double>[
        0,
        30,
        30,
      ]);
      expect(ordered[1].rect.left, 0);
      expect(ordered[2].rect.left, 50);
    });

    test('竖排占多数：按列从右到左', () {
      final List<PpTextLine> ordered = orderLinesForReading(<PpTextLine>[
        _line(0, 0, 10, 100),
        _line(40, 0, 50, 100),
        _line(20, 0, 30, 100),
      ]);
      expect(ordered.map((PpTextLine l) => l.rect.left).toList(), <double>[
        40,
        20,
        0,
      ]);
    });
  });

  group('PpOcrLineDetector.detect', () {
    test('输入 [1,3,H,W]、输出反变换回裁图像素系', () async {
      // 裁图 200×50 → 输入 256×64（短边放大 1.28，两边取整 32 倍数）。
      const int outW = 256, outH = 64;
      final Float32List prob = _probMap(outW, outH, <List<int>>[
        <int>[32, 16, 224, 48],
      ]);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(prob, const <int>[1, 1, outH, outW]),
      });
      final PpOcrLineDetector det = PpOcrLineDetector(session);
      final img.Image crop = img.Image(width: 200, height: 50);
      final List<PpTextLine> lines = await det.detect(crop);

      final OcrTensor input = session.receivedInputs.single['x']!;
      expect(input.shape, <int>[1, 3, outH, outW]);
      expect(lines, hasLength(1));
      // 概率图 → 裁图：x 缩 200/256、y 缩 50/64；框已含 unclip 外扩。
      final OcrRect r = lines.single.rect;
      expect(r.left, lessThan(32 * 200 / 256));
      expect(r.right, greaterThan(224 * 200 / 256));
      expect(r.right, lessThanOrEqualTo(200));
      expect(r.bottom, lessThanOrEqualTo(50));
      expect(lines.single.vertical, isFalse);

      await det.close();
      expect(session.closed, isTrue);
    });

    test('输出个数不为 1 时报错', () async {
      final _FakeSession session = _FakeSession(<String, OcrTensor>{});
      final PpOcrLineDetector det = PpOcrLineDetector(session);
      expect(
        () => det.detect(img.Image(width: 64, height: 64)),
        throwsStateError,
      );
    });
  });
}
