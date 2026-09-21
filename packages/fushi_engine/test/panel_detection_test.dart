import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/text_detector.dart'
    show computeLetterbox, kDetInputSize;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

void main() {
  test('orders panels in RTL and removes heavy overlap', () {
    final List<PanelRect> panels = orderPanelRects(<PanelRect>[
      const PanelRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.5, score: 0.4),
      const PanelRect(
        left: 0.12,
        top: 0.12,
        right: 0.88,
        bottom: 0.48,
        score: 0.9,
      ),
      const PanelRect(
        left: 0.1,
        top: 0.55,
        right: 0.4,
        bottom: 0.9,
        score: 0.8,
      ),
      const PanelRect(
        left: 0.6,
        top: 0.55,
        right: 0.9,
        bottom: 0.9,
        score: 0.8,
      ),
    ], direction: PanelReadingDirection.rtl);
    expect(panels, hasLength(3));
    expect(panels[1].centerX, greaterThan(panels[2].centerX));
  });

  test('splits a large panel when text boxes provide anchors', () {
    const PanelRect whole = PanelRect(left: 0, top: 0, right: 1, bottom: 1);
    final List<PanelRect> result = splitLargePanel(whole, const <PanelTextBox>[
      PanelTextBox(
        rect: PanelRect(left: 0.2, top: 0.2, right: 0.3, bottom: 0.3),
        score: 0.9,
      ),
      PanelTextBox(
        rect: PanelRect(left: 0.7, top: 0.7, right: 0.8, bottom: 0.8),
        score: 0.9,
      ),
    ], direction: PanelReadingDirection.ltr);
    expect(result, hasLength(2));
    expect(result.first.top, 0);
    expect(result.last.bottom, 1);
  });

  test('merges sidecar blocks without replacing managed URLs', () {
    const MokuroPayload downloaded = MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: 'images/page-000001.jpg',
          size: MokuroSize(100, 200),
          blocks: <MokuroBlock>[],
        ),
      ],
    );
    final MokuroSidecarMergeResult result = mergeMokuroSidecar(
      downloaded: downloaded,
      sidecarJson:
          '{"pages":[{"img_path":"001.jpg","img_width":100,"img_height":200,"blocks":[{"box":[1,2,10,20],"lines":["x"]}]}]}',
    );
    expect(result.accepted, isTrue);
    expect(result.payload.images.single.url, 'images/page-000001.jpg');
    expect(result.payload.images.single.blocks, hasLength(1));
  });

  group('detectPrepared 只在缓存未命中时预处理', () {
    // 预处理（整页解码 + 640x640 letterbox）由调用方在后台 isolate 里做，
    // detector 必须先查缓存再调它——否则翻回读过的页照样白解码一次整页。
    PreprocessedPanelPage prepared() => PreprocessedPanelPage(
      input: Float32List(3 * kDetInputSize * kDetInputSize),
      transform: computeLetterbox(1000, 1500),
    );

    test('缓存命中时既不预处理也不推理', () async {
      final _CountingSession session = _CountingSession();
      final OnnxPanelDetector detector = OnnxPanelDetector(session);
      int prepareCalls = 0;
      Future<PanelDetectionResult> run() => detector.detectPrepared(
        pageKey: 'page-1',
        direction: PanelReadingDirection.rtl,
        prepare: () async {
          prepareCalls++;
          return prepared();
        },
      );

      final PanelDetectionResult first = await run();
      expect(first.status, PanelDetectionStatus.ready);
      expect(prepareCalls, 1);
      expect(session.runs, 1);

      final PanelDetectionResult second = await run();
      expect(second.status, PanelDetectionStatus.ready);
      expect(prepareCalls, 1, reason: '缓存命中不得再预处理');
      expect(session.runs, 1);

      await detector.close();
      expect(session.closed, isTrue);
    });

    test('预处理返回 null 判定解码失败且不跑推理', () async {
      final _CountingSession session = _CountingSession();
      final OnnxPanelDetector detector = OnnxPanelDetector(session);
      final PanelDetectionResult result = await detector.detectPrepared(
        pageKey: 'broken',
        direction: PanelReadingDirection.ltr,
        prepare: () async => null,
      );
      expect(result.status, PanelDetectionStatus.failed);
      expect(result.error, 'image decode failed');
      expect(session.runs, 0);
    });

    test('preprocessPanelPageBytes 对坏字节返回 null 而不是抛', () {
      expect(
        preprocessPanelPageBytes(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isNull,
      );
    });
  });
}

/// 只记账的假会话：固定回一个 class 0 的检测框。
class _CountingSession implements OcrSession {
  int runs = 0;
  bool closed = false;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    runs++;
    return <String, OcrTensor>{
      'output': OcrTensor.float32(
        Float32List.fromList(<double>[100, 100, 400, 500, 0.9, 0]),
        const <int>[1, 6],
      ),
    };
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
