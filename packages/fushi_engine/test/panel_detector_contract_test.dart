import 'dart:typed_data';

import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  test('converts 640 pixel boxes to page-normalized coordinates', () async {
    final _FakeSession session = _FakeSession(
      OcrTensor.float32(
        Float32List.fromList(<double>[64, 128, 256, 512, 0.9, 0]),
        const <int>[1, 1, 6],
      ),
    );
    final OnnxPanelDetector detector = OnnxPanelDetector(
      session,
      modelRevision: 'test-revision',
    );
    final PanelDetectionResult result = await detector.detect(
      img.Image(width: 320, height: 640),
      pageKey: 'page-a',
      direction: PanelReadingDirection.ltr,
    );
    expect(result.status, PanelDetectionStatus.ready);
    expect(result.panels.single.left, closeTo(0.1, 1e-6));
    expect(result.panels.single.right, closeTo(0.4, 1e-6));
    expect(result.panels.single.top, closeTo(0.2, 1e-6));
    expect(session.runCount, 1);
  });

  test('serializes inference and reuses the revision-aware cache', () async {
    final _FakeSession session = _FakeSession(
      OcrTensor.float32(
        Float32List.fromList(<double>[0, 0, 640, 640, 0.9, 0]),
        const <int>[1, 1, 6],
      ),
      delay: const Duration(milliseconds: 10),
    );
    final OnnxPanelDetector detector = OnnxPanelDetector(
      session,
      modelRevision: 'revision-a',
    );
    final img.Image page = img.Image(width: 640, height: 640);
    final List<PanelDetectionResult> results =
        await Future.wait(<Future<PanelDetectionResult>>[
          detector.detect(
            page,
            pageKey: 'same',
            direction: PanelReadingDirection.rtl,
          ),
          detector.detect(
            page,
            pageKey: 'same',
            direction: PanelReadingDirection.rtl,
          ),
        ]);
    expect(results[0].usable, isTrue);
    expect(results[1].usable, isTrue);
    expect(session.maxConcurrentRuns, 1);
    expect(session.runCount, 1);
    await detector.detect(
      page,
      pageKey: 'same',
      direction: PanelReadingDirection.ltr,
    );
    expect(session.runCount, 2);
  });

  test('cache is bounded and reads promote the entry', () {
    final PanelDetectionCache cache = PanelDetectionCache(capacity: 2);
    const PanelDetectionResult first = PanelDetectionResult(
      status: PanelDetectionStatus.empty,
      panels: <PanelRect>[],
    );
    cache.write('a', first);
    cache.write('b', first);
    expect(cache.read('a'), same(first));
    cache.write('c', first);
    expect(cache.read('a'), same(first));
    expect(cache.read('b'), isNull);
  });
}

class _FakeSession implements OcrSession {
  _FakeSession(this.output, {this.delay = Duration.zero});

  final OcrTensor output;
  final Duration delay;
  int runCount = 0;
  int concurrentRuns = 0;
  int maxConcurrentRuns = 0;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    concurrentRuns++;
    maxConcurrentRuns = concurrentRuns > maxConcurrentRuns
        ? concurrentRuns
        : maxConcurrentRuns;
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    concurrentRuns--;
    runCount++;
    return <String, OcrTensor>{'output0': output};
  }

  @override
  Future<void> close() async {}
}
