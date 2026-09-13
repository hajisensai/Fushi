import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/routing_ocr_recognizer.dart';
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

class _FakeLineDetector extends PpOcrLineDetector {
  _FakeLineDetector(this.lines) : super(_DeadSession());

  final List<PpTextLine> lines;
  final List<img.Image> crops = <img.Image>[];

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    crops.add(crop);
    return lines;
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

void main() {
  final img.Image page = img.Image(width: 400, height: 300);

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
