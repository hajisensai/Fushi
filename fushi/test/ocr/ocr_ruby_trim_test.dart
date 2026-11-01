// 反馈 ZBJTgLuPIb：本机 Manga CTC 识别注音密集的漫画（《葬送のフリーレン》）时汉字
// 认错。行检测器把紧贴正文的振假名和正文检成同一条列框，[dropOcrRubyLines] 删
// 不到它，CTC 把注音当正文读。「OCR 忽略振假名」开时逐列识别前用墨迹投影把列框
// 两侧的注音带裁掉（trimOcrRubyBands）。只忽略来源自带的注音，不生成任何读音。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ctc_column_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_ruby_trim.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;

/// 白底黑字的竖排列：正文列占 x∈[mainLeft, mainRight)，每 40px 一个「字」
/// （30px 高的实心块）；[ruby] 里的每段是 (left, right, top, bottom) 的注音块。
img.Image _column({
  int width = 60,
  int height = 200,
  int mainLeft = 10,
  int mainRight = 30,
  List<(int, int, int, int)> ruby = const <(int, int, int, int)>[],
  List<(int, int)> extraColumns = const <(int, int)>[],
  bool inverted = false,
}) {
  final img.ColorRgb8 paper = inverted
      ? img.ColorRgb8(0, 0, 0)
      : img.ColorRgb8(255, 255, 255);
  final img.ColorRgb8 ink = inverted
      ? img.ColorRgb8(255, 255, 255)
      : img.ColorRgb8(0, 0, 0);
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: paper);
  for (final (int left, int right) in <(int, int)>[
    (mainLeft, mainRight),
    ...extraColumns,
  ]) {
    for (int top = 5; top + 30 <= height; top += 40) {
      img.fillRect(
        image,
        x1: left,
        y1: top,
        x2: right - 1,
        y2: top + 29,
        color: ink,
      );
    }
  }
  for (final (int left, int right, int top, int bottom) in ruby) {
    img.fillRect(
      image,
      x1: left,
      y1: top,
      x2: right - 1,
      y2: bottom - 1,
      color: ink,
    );
  }
  return image;
}

const OcrRect _whole = OcrRect(left: 0, top: 0, right: 60, bottom: 200);

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

/// 记下每张交来识别的行图（竖列已逆时针转 90°：图高 = 列宽）。
class _RecordingRecognizer extends PpOcrLineRecognizer {
  _RecordingRecognizer() : super(_DeadSession(), vocab: const <String>['']);

  final List<img.Image> lines = <img.Image>[];

  @override
  Future<PpOcrPositionedLine> recognizeLinePositioned(img.Image line) async {
    lines.add(line);
    return PpOcrPositionedLine(
      text: '字',
      confidence: null,
      tokens: const <OcrLineToken>[],
    );
  }
}

void main() {
  group('trimOcrRubyBands', () {
    test('竖排正文右侧紧贴的注音带被裁掉，边界落在空隙中点', () {
      final img.Image page = _column(
        ruby: const <(int, int, int, int)>[(34, 42, 7, 33), (34, 42, 87, 113)],
      );
      final OcrRect trimmed = trimOcrRubyBands(page, _whole, vertical: true);
      expect(trimmed.left, 0);
      expect(trimmed.right, 32, reason: '正文止于 30、注音起于 34');
      expect(trimmed.top, 0);
      expect(trimmed.bottom, 200, reason: '沿阅读方向的长度不动');
    });

    test('相邻列伸进本列框左缘的注音同样裁掉', () {
      final img.Image page = _column(
        mainLeft: 20,
        mainRight: 40,
        ruby: const <(int, int, int, int)>[(4, 12, 47, 73)],
      );
      final OcrRect trimmed = trimOcrRubyBands(page, _whole, vertical: true);
      expect(trimmed.left, 16);
      expect(trimmed.right, 60);
    });

    test('没有注音时原样返回（同一个对象）', () {
      final img.Image page = _column();
      expect(
        identical(trimOcrRubyBands(page, _whole, vertical: true), _whole),
        isTrue,
      );
    });

    test('框里是两列正文（同宽的另一条带）时不裁', () {
      final img.Image page = _column(
        extraColumns: const <(int, int)>[(36, 56)],
      );
      expect(
        identical(trimOcrRubyBands(page, _whole, vertical: true), _whole),
        isTrue,
      );
    });

    test('反白台词（黑底白字）按少数像素认墨迹，照样裁', () {
      final img.Image page = _column(
        inverted: true,
        ruby: const <(int, int, int, int)>[(34, 42, 7, 33)],
      );
      expect(trimOcrRubyBands(page, _whole, vertical: true).right, 32);
    });

    test('横排：行上方的注音带被裁掉', () {
      // 把竖排页转 90° 当横排：正文行 y∈[10,30)，注音 y∈[2,7) 在上方。
      final img.Image page = img.Image(width: 200, height: 40);
      img.fill(page, color: img.ColorRgb8(255, 255, 255));
      for (int left = 5; left + 30 <= 200; left += 40) {
        img.fillRect(
          page,
          x1: left,
          y1: 12,
          x2: left + 29,
          y2: 33,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
      img.fillRect(
        page,
        x1: 8,
        y1: 2,
        x2: 30,
        y2: 7,
        color: img.ColorRgb8(0, 0, 0),
      );
      final OcrRect trimmed = trimOcrRubyBands(
        page,
        const OcrRect(left: 0, top: 0, right: 200, bottom: 40),
        vertical: false,
      );
      expect(trimmed.top, 10, reason: '注音止于 8、正文起于 12');
      expect(trimmed.bottom, 40);
      expect(trimmed.left, 0);
      expect(trimmed.right, 200);
    });

    test('没有对比度（空白 / 灰底）时不动', () {
      final img.Image page = img.Image(width: 60, height: 200);
      img.fill(page, color: img.ColorRgb8(200, 200, 200));
      expect(
        identical(trimOcrRubyBands(page, _whole, vertical: true), _whole),
        isTrue,
      );
    });
  });

  group('CtcColumnOcrRecognizer.ignoreFurigana', () {
    Future<img.Image> readColumn({required bool ignoreFurigana}) async {
      final _RecordingRecognizer columns = _RecordingRecognizer();
      final CtcColumnOcrRecognizer recognizer = CtcColumnOcrRecognizer(
        lineDetector: PpOcrLineDetector(_DeadSession()),
        lineRecognizer: columns,
        ignoreFurigana: ignoreFurigana,
      );
      final img.Image page = _column(
        ruby: const <(int, int, int, int)>[(34, 42, 7, 33), (34, 42, 87, 113)],
      );
      // 行检测器把注音和正文检成同一条列框（反馈里的情形）。
      final OcrRecognition result = await recognizer.recognizeWithLines(
        page,
        _whole,
        vertical: true,
        lineHints: const <OcrRect>[_whole],
      );
      expect(result.text, '字');
      expect(columns.lines, hasLength(1));
      return columns.lines.single;
    }

    test('关：列图带着注音（旧行为）', () async {
      final img.Image line = await readColumn(ignoreFurigana: false);
      expect(line.height, 60);
    });

    test('开：交给 CTC 的列图只剩正文列', () async {
      final img.Image line = await readColumn(ignoreFurigana: true);
      expect(line.height, 32);
      expect(line.width, 200);
    });
  });

  test('缓存签名：开关前后的结果不进同一个缓存目录', () {
    expect(
      mangaOcrEngineSignatureFor('manga_ctc_v1_abc', ignoreFurigana: false),
      'manga_ctc_v1_abc',
    );
    expect(
      mangaOcrEngineSignatureFor('manga_ctc_v1_abc', ignoreFurigana: true),
      isNot('manga_ctc_v1_abc'),
    );
  });
}
