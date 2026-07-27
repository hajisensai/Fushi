import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/ocr/ocr_inference.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';
import 'package:hibiki/src/ocr/text_detector.dart';
import 'package:image/image.dart' as img;

/// 回放固定输出的 fake 会话，并记录收到的输入。
class FakeSession implements OcrSession {
  FakeSession(this.outputs);

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

void main() {
  group('computeLetterbox', () {
    test('squish 模式：独立 scaleX/scaleY、零 pad、正反变换互逆', () {
      final LetterboxTransform t = computeLetterbox(1000, 500);
      expect(t.scaleX, closeTo(0.64, 1e-9));
      expect(t.scaleY, closeTo(1.28, 1e-9));
      expect(t.padX, 0);
      expect(t.padY, 0);
      expect(t.forwardX(1000), closeTo(640, 1e-9));
      expect(t.forwardY(500), closeTo(640, 1e-9));
      expect(t.inverseX(t.forwardX(123.4)), closeTo(123.4, 1e-9));
      expect(t.inverseY(t.forwardY(45.6)), closeTo(45.6, 1e-9));
    });

    test('letterbox 模式：等比缩放 + 居中 pad、正反变换互逆', () {
      final LetterboxTransform t =
          computeLetterbox(1000, 500, preserveAspect: true);
      expect(t.scaleX, closeTo(0.64, 1e-9));
      expect(t.scaleY, closeTo(0.64, 1e-9));
      expect(t.padX, 0);
      expect(t.padY, closeTo((640 - 320) / 2, 1e-9));
      expect(t.forwardY(0), closeTo(160, 1e-9));
      expect(t.forwardY(500), closeTo(480, 1e-9));
      expect(t.inverseX(t.forwardX(777)), closeTo(777, 1e-9));
      expect(t.inverseY(t.forwardY(321)), closeTo(321, 1e-9));
    });

    test('非法尺寸抛异常', () {
      expect(() => computeLetterbox(0, 100), throwsArgumentError);
    });
  });

  group('rtdetrPreprocess', () {
    test('squish：RGB / 255、CHW 布局', () {
      final img.Image src = img.Image(width: 2, height: 2);
      img.fill(src, color: img.ColorRgb8(255, 0, 0)); // 纯红
      final LetterboxTransform t =
          computeLetterbox(2, 2, dstWidth: 4, dstHeight: 4);
      final Float32List chw = rtdetrPreprocess(src, t);
      expect(chw.length, 3 * 4 * 4);
      // R 平面全 1，G/B 平面全 0。
      for (int i = 0; i < 16; i++) {
        expect(chw[i], closeTo(1.0, 1e-6));
        expect(chw[16 + i], closeTo(0.0, 1e-6));
        expect(chw[32 + i], closeTo(0.0, 1e-6));
      }
    });

    test('letterbox：pad 区域为 114 灰', () {
      final img.Image src = img.Image(width: 2, height: 1);
      img.fill(src, color: img.ColorRgb8(255, 255, 255));
      final LetterboxTransform t = computeLetterbox(2, 1,
          dstWidth: 4, dstHeight: 4, preserveAspect: true);
      // scale=2 → 内容占 4x2，上下各 1 行 pad。
      final Float32List chw = rtdetrPreprocess(src, t);
      const double gray = 114 / 255;
      // 第 0 行（pad）。
      for (int x = 0; x < 4; x++) {
        expect(chw[x], closeTo(gray, 1e-6));
      }
      // 第 1 行（内容，白色）。
      for (int x = 0; x < 4; x++) {
        expect(chw[4 + x], closeTo(1.0, 1e-6));
      }
      // 第 3 行（pad）。
      for (int x = 0; x < 4; x++) {
        expect(chw[12 + x], closeTo(gray, 1e-6));
      }
    });
  });

  group('decodeRtdetrOutputs', () {
    // src 1280x1280 → squish 到 640：scale 0.5。
    final LetterboxTransform transform = computeLetterbox(1280, 1280);

    Float32List logitsFor(List<List<double>> perQuery) => Float32List.fromList(
        <double>[for (final List<double> q in perQuery) ...q]);

    test('sigmoid + 阈值 + cxcywh 反变换回原图', () {
      final Float32List logits = logitsFor(<List<double>>[
        <double>[-10, 4, -10], // query0：text_bubble，sigmoid(4)≈0.982
        <double>[-4, -4, -4], // query1：全部低于阈值
      ]);
      final Float32List boxes = Float32List.fromList(<double>[
        0.5, 0.5, 0.25, 0.25, // 640 系：cx=320 cy=320 w=160 h=160
        0.1, 0.1, 0.05, 0.05,
      ]);
      final List<RawDetection> detections = decodeRtdetrOutputs(
        logits: logits,
        boxes: boxes,
        transform: transform,
        numQueries: 2,
        numClasses: 3,
      );
      expect(detections, hasLength(1));
      final RawDetection d = detections.single;
      expect(d.classId, kDetClassTextBubble);
      expect(d.score, greaterThan(0.9));
      expect(d.rect.left, closeTo(480, 1e-6));
      expect(d.rect.top, closeTo(480, 1e-6));
      expect(d.rect.right, closeTo(800, 1e-6));
      expect(d.rect.bottom, closeTo(800, 1e-6));
    });

    test('阈值边界：sigmoid(0)=0.5 保留，sigmoid(-2)≈0.12 丢弃', () {
      final Float32List logits = logitsFor(<List<double>>[
        <double>[0, -30, -30],
        <double>[-2, -30, -30],
      ]);
      final Float32List boxes = Float32List.fromList(<double>[
        0.5, 0.5, 0.2, 0.2, //
        0.5, 0.5, 0.2, 0.2,
      ]);
      final List<RawDetection> detections = decodeRtdetrOutputs(
        logits: logits,
        boxes: boxes,
        transform: transform,
        numQueries: 2,
        numClasses: 3,
      );
      expect(detections, hasLength(1));
      expect(detections.single.classId, kDetClassBubble);
    });

    test('坐标 clamp 到原图边界', () {
      final Float32List logits = logitsFor(<List<double>>[
        <double>[-10, -10, 5],
      ]);
      // 框超出左上边界。
      final Float32List boxes =
          Float32List.fromList(<double>[0.0, 0.0, 0.2, 0.2]);
      final List<RawDetection> detections = decodeRtdetrOutputs(
        logits: logits,
        boxes: boxes,
        transform: transform,
        numQueries: 1,
        numClasses: 3,
      );
      expect(detections, hasLength(1));
      expect(detections.single.rect.left, 0);
      expect(detections.single.rect.top, 0);
    });
  });

  group('decodeProcessedRtdetrOutputs', () {
    test('过滤分数并把 xyxy 从 640 输入坐标反变换回原图', () {
      final LetterboxTransform transform = computeLetterbox(100, 200);
      final List<RawDetection> detections = decodeProcessedRtdetrOutputs(
        scores: Float32List.fromList(<double>[0.9, 0.1]),
        labels: Float32List.fromList(<double>[2, 1]),
        boxes: Float32List.fromList(<double>[
          256,
          256,
          384,
          384,
          0,
          0,
          64,
          64,
        ]),
        transform: transform,
      );

      expect(detections, hasLength(1));
      expect(detections.single.classId, kDetClassTextFree);
      expect(detections.single.rect.left, closeTo(40, 0.01));
      expect(detections.single.rect.top, closeTo(80, 0.01));
      expect(detections.single.rect.right, closeTo(60, 0.01));
      expect(detections.single.rect.bottom, closeTo(120, 0.01));
    });
  });

  group('applyClassAwareNms', () {
    const OcrRect boxA = OcrRect(left: 0, top: 0, right: 100, bottom: 100);
    const OcrRect boxB = OcrRect(left: 5, top: 5, right: 105, bottom: 105);

    test('同类高重叠只留高分', () {
      final List<RawDetection> kept = applyClassAwareNms(<RawDetection>[
        const RawDetection(rect: boxA, score: 0.8, classId: 1),
        const RawDetection(rect: boxB, score: 0.9, classId: 1),
      ]);
      expect(kept, hasLength(1));
      expect(kept.single.score, 0.9);
    });

    test('不同类同位置都保留（bubble 与 text_bubble 天然套叠）', () {
      final List<RawDetection> kept = applyClassAwareNms(<RawDetection>[
        const RawDetection(rect: boxA, score: 0.8, classId: 0),
        const RawDetection(rect: boxB, score: 0.9, classId: 1),
      ]);
      expect(kept, hasLength(2));
    });
  });

  group('buildPageDetections', () {
    test('类过滤 + 气泡内外判定', () {
      const OcrRect bubble = OcrRect(left: 0, top: 0, right: 100, bottom: 100);
      const OcrRect insideText =
          OcrRect(left: 20, top: 20, right: 80, bottom: 80);
      const OcrRect outsideText =
          OcrRect(left: 200, top: 200, right: 260, bottom: 260);
      final PageDetections page = buildPageDetections(<RawDetection>[
        const RawDetection(rect: bubble, score: 0.9, classId: 0),
        const RawDetection(rect: insideText, score: 0.8, classId: 1),
        const RawDetection(rect: outsideText, score: 0.7, classId: 2),
      ]);
      expect(page.bubbles, hasLength(1));
      expect(page.textRegions, hasLength(2));
      final DetectedTextRegion inside =
          page.textRegions.firstWhere((DetectedTextRegion r) => r.classId == 1);
      final DetectedTextRegion outside =
          page.textRegions.firstWhere((DetectedTextRegion r) => r.classId == 2);
      expect(inside.insideBubble, isTrue);
      expect(outside.insideBubble, isFalse);
    });
  });

  group('TextDetector', () {
    test('端到端：输入张量形状正确、输出映射回原图', () async {
      // 合成输出：1 个 text_free 检测，覆盖输入中心 20% 区域。
      final Float32List logits = Float32List.fromList(<double>[
        -10, -10, 6, // query0 -> text_free
        -10, -10, -10, // query1 -> 无
      ]);
      final Float32List boxes = Float32List.fromList(<double>[
        0.5, 0.5, 0.2, 0.2, //
        0.9, 0.9, 0.05, 0.05,
      ]);
      final FakeSession session = FakeSession(<String, OcrTensor>{
        'logits': OcrTensor.float32(logits, <int>[1, 2, 3]),
        'pred_boxes': OcrTensor.float32(boxes, <int>[1, 2, 4]),
      });
      final TextDetector detector = TextDetector(session);
      final img.Image page = img.Image(width: 100, height: 200);
      final PageDetections result = await detector.detect(page);

      expect(session.receivedInputs, hasLength(1));
      final OcrTensor input = session.receivedInputs.single['pixel_values']!;
      expect(input.shape, <int>[1, 3, 640, 640]);
      expect(input.type, OcrTensorType.float32);
      final OcrTensor targetSize =
          session.receivedInputs.single['orig_target_sizes']!;
      expect(targetSize.shape, <int>[1, 2]);
      expect(targetSize.intData, <int>[640, 640]);

      expect(result.textRegions, hasLength(1));
      final OcrRect rect = result.textRegions.single.rect;
      // squish：640 系中心 20% 框 → 原图中心 20%。
      expect(rect.left, closeTo(40, 0.5));
      expect(rect.top, closeTo(80, 0.5));
      expect(rect.right, closeTo(60, 0.5));
      expect(rect.bottom, closeTo(120, 0.5));

      await detector.close();
      expect(session.closed, isTrue);
    });

    test('兼容图内后处理的 scores labels boxes 输出', () async {
      final FakeSession session = FakeSession(<String, OcrTensor>{
        'scores': OcrTensor.float32(
            Float32List.fromList(<double>[0.95]), <int>[1, 1]),
        'labels':
            OcrTensor.float32(Float32List.fromList(<double>[2]), <int>[1, 1]),
        'boxes': OcrTensor.float32(
          Float32List.fromList(<double>[256, 256, 384, 384]),
          <int>[1, 1, 4],
        ),
      });
      final TextDetector detector = TextDetector(session);

      final PageDetections result =
          await detector.detect(img.Image(width: 100, height: 200));

      expect(result.textRegions, hasLength(1));
      expect(result.textRegions.single.classId, kDetClassTextFree);
      expect(result.textRegions.single.rect.left, closeTo(40, 0.01));
      expect(result.textRegions.single.rect.top, closeTo(80, 0.01));
      expect(result.textRegions.single.rect.right, closeTo(60, 0.01));
      expect(result.textRegions.single.rect.bottom, closeTo(120, 0.01));
    });

    test('输出名缺失时报错而非静默', () async {
      final FakeSession session = FakeSession(<String, OcrTensor>{
        'wrong': OcrTensor.float32(Float32List(3), <int>[1, 1, 3]),
      });
      final TextDetector detector = TextDetector(session);
      expect(
        () => detector.detect(img.Image(width: 10, height: 10)),
        throwsStateError,
      );
    });
  });
}
