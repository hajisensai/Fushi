import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
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

final String _yml = <String>[
  'Global:',
  '  model_name: PP-OCRv6_small_rec',
  'PostProcess:',
  '  character_dict:',
  "  - '!'",
  "  - ''''",
  '  - あ',
  '  - 漫',
  '  - \u3000',
  '  name: CTCLabelDecode',
  '  use_space_char: true',
].join('\n');

/// [T, V] logits：每帧只把 [ids] 指定的索引置 1，其余 0。
Float32List _logits(List<int> ids, int vocabSize) {
  final Float32List out = Float32List(ids.length * vocabSize);
  for (int t = 0; t < ids.length; t++) {
    out[t * vocabSize + ids[t]] = 1;
  }
  return out;
}

void main() {
  group('parsePpOcrCharacterDict', () {
    test('裸字符、单引号、\'\' 转义、全角空格；到非列表行为止', () {
      final List<String> dict = parsePpOcrCharacterDict(_yml);
      expect(dict, <String>['!', "'", 'あ', '漫', '\u3000']);
    });

    test('CRLF 文件同样解析', () {
      final List<String> dict = parsePpOcrCharacterDict(
        _yml.replaceAll('\n', '\r\n'),
      );
      expect(dict, hasLength(5));
      expect(dict[2], 'あ');
    });

    test('缺 character_dict 抛 FormatException 而不是空词表', () {
      expect(
        () => parsePpOcrCharacterDict('Global:\n  x: 1\n'),
        throwsFormatException,
      );
    });

    test('不支持的 YAML 标量形式抛异常（宁可失败也不错位）', () {
      expect(
        () => parsePpOcrCharacterDict(
          'PostProcess:\n  character_dict:\n  - "x"\n',
        ),
        throwsFormatException,
      );
    });
  });

  test('buildPpOcrCtcVocab：blank + 字典 + 空格', () {
    final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
    expect(vocab, <String>['', 'a', 'b', ' ']);
  });

  group('ppRecPreprocess', () {
    test('高 48、宽按比例、最小 320、右侧零填充、BGR 归一化', () {
      final img.Image line = img.Image(width: 100, height: 20);
      img.fill(line, color: img.ColorRgb8(255, 0, 0)); // 纯红
      final ({Float32List data, int width}) r = ppRecPreprocess(line);
      expect(r.width, kPpRecMinWidth);
      const int plane = kPpRecHeight * kPpRecMinWidth;
      expect(r.data.length, 3 * plane);
      // 缩放宽 = ceil(48*100/20) = 240；x=0 有像素，x=300 是填充。
      expect(r.data[0], closeTo(-1, 1e-6)); // B=0
      expect(r.data[2 * plane], closeTo(1, 1e-6)); // R=1
      expect(r.data[300], 0);
      expect(r.data[2 * plane + 300], 0);
    });

    test('超宽行：宽 = ceil(48 * w / h)，不截断', () {
      final img.Image line = img.Image(width: 1000, height: 40);
      final ({Float32List data, int width}) r = ppRecPreprocess(line);
      expect(r.width, 1200);
    });
  });

  test('ctcGreedyDecode：合并相邻重复、去 blank', () {
    final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
    // a a blank a b b blank → "aab"
    final Float32List logits = _logits(<int>[1, 1, 0, 1, 2, 2, 0], 4);
    expect(ctcGreedyDecode(logits, 7, 4, vocab), 'aab');
  });

  group('PpOcrLineRecognizer.recognizeLine', () {
    test('输入 [1,3,48,W]、按词表解码', () async {
      final List<String> vocab = buildPpOcrCtcVocab(
        parsePpOcrCharacterDict(_yml),
      );
      // vocab: '', '!', "'", 'あ', '漫', '　', ' '  → 7
      final Float32List logits = _logits(<int>[4, 4, 0, 3, 1], vocab.length);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(logits, <int>[1, 5, vocab.length]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );
      final String text = await rec.recognizeLine(
        img.Image(width: 200, height: 30),
      );
      expect(text, '漫あ!');
      expect(session.receivedInputs.single['x']!.shape, <int>[
        1,
        3,
        kPpRecHeight,
        kPpRecMinWidth,
      ]);
      await rec.close();
      expect(session.closed, isTrue);
    });

    // 漫画 OCR 的热路径必须保持单遍 argmax：不转调详细路径（逐帧全词表置信度 +
    // 全张量有限值检查），也不因个别非有限 logit 整行报错。两条路径解出的文字一致。
    test('recognizeLine 保持单遍解码：非有限 logit 不报错，文字与详细路径一致', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
      final Float32List logits = _logits(<int>[1, 1, 0, 1, 2, 2, 0], 4);
      final _FakeSession clean = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(logits, <int>[1, 7, 4]),
      });
      final PpOcrLineRecognizer cleanRec = PpOcrLineRecognizer(
        clean,
        vocab: vocab,
      );
      final img.Image line = img.Image(width: 200, height: 30);
      expect(
        await cleanRec.recognizeLine(line),
        (await cleanRec.recognizeLineDetailed(line)).text,
      );

      final Float32List noisy = Float32List.fromList(logits)..[3] = double.nan;
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(noisy, <int>[1, 7, 4]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );
      expect(await rec.recognizeLine(line), 'aab');
      expect(() => rec.recognizeLineDetailed(line), throwsStateError);
    });

    test('recognizeLineDetailed：blank 分隔的重复字保留为两个 token，并保留帧范围', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
      // a a blank a b b blank blank → aab，首尾 token 的帧范围不均分。
      final Float32List logits = _logits(<int>[
        1,
        1,
        0,
        1,
        2,
        2,
        0,
        0,
      ], vocab.length);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(logits, <int>[1, 8, vocab.length]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      final PpOcrLineRecognition result = await rec.recognizeLineDetailed(
        img.Image(width: 320, height: 48),
      );

      expect(result.text, 'aab');
      expect(result.tokens, hasLength(3));
      expect(result.tokens.map((PpOcrCtcToken token) => token.text), <String>[
        'a',
        'a',
        'b',
      ]);
      expect(
        result.tokens.map(
          (PpOcrCtcToken token) => <int>[
            token.frameStart,
            token.frameEndExclusive,
          ],
        ),
        <List<int>>[
          <int>[0, 2],
          <int>[3, 4],
          <int>[4, 6],
        ],
      );
      expect(result.tokens[0].centerX, closeTo(40, 1e-6));
      expect(result.tokens[1].centerX, closeTo(140, 1e-6));
      expect(result.tokens[2].centerX, closeTo(200, 1e-6));
      expect(
        result.tokens.every((PpOcrCtcToken token) => token.hasPosition),
        isTrue,
      );
      expect(
        result.tokens.every((PpOcrCtcToken token) => token.confidence == 1),
        isTrue,
      );
    });

    test('recognizeLineDetailed：右 padding 保留文本但不产生伪造的原图位置', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
      // line 100x20 → 内容缩放宽 240，模型输入宽 320；最后两帧在 padding。
      final Float32List logits = _logits(<int>[
        1,
        1,
        0,
        2,
        2,
        0,
        1,
        1,
      ], vocab.length);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(logits, <int>[1, 8, vocab.length]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      final PpOcrLineRecognition result = await rec.recognizeLineDetailed(
        img.Image(width: 100, height: 20),
      );

      expect(result.text, 'aba');
      expect(result.contentWidth, 240);
      expect(result.inputWidth, 320);
      expect(result.tokens[0].centerX, closeTo(16.6666667, 1e-5));
      expect(result.tokens[1].left, closeTo(50, 1e-6));
      expect(result.tokens[1].right, closeTo(83.3333333, 1e-5));
      expect(result.tokens[2].inputLeft, closeTo(240, 1e-6));
      expect(result.tokens[2].inputRight, closeTo(320, 1e-6));
      expect(result.tokens[2].hasPosition, isFalse);
      expect(result.tokens[2].centerX, isNull);
    });

    test('recognizeLineDetailed：非 padding 的坐标按原行图比例缩放', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a']);
      final Float32List logits = _logits(<int>[0, 1, 1, 0], vocab.length);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(logits, <int>[1, 4, vocab.length]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      final PpOcrLineRecognition result = await rec.recognizeLineDetailed(
        img.Image(width: 1000, height: 40),
      );

      // scaled/input width = 1200 and token frames [1,3) → original [250,750].
      expect(result.contentWidth, 1200);
      expect(result.inputWidth, 1200);
      expect(result.tokens.single.left, closeTo(250, 1e-6));
      expect(result.tokens.single.right, closeTo(750, 1e-6));
      expect(result.tokens.single.centerX, closeTo(500, 1e-6));
    });

    test('recognizeLineDetailed：概率输出直接作为 confidence', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a', 'b']);
      final Float32List probabilities = Float32List.fromList(<double>[
        0.05,
        0.9,
        0.05,
        0.0,
        0.7,
        0.2,
        0.1,
        0.0,
      ]);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(probabilities, <int>[
          1,
          2,
          vocab.length,
        ]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      final PpOcrLineRecognition result = await rec.recognizeLineDetailed(
        img.Image(width: 320, height: 48),
      );

      expect(result.text, 'a');
      expect(result.tokens.single.confidence, closeTo(0.9, 1e-6));
    });

    test('模型词表维度与字典不符时报错（错位一格整行全错）', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a']);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(Float32List(5), const <int>[1, 1, 5]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );
      expect(
        () => rec.recognizeLine(img.Image(width: 10, height: 10)),
        throwsStateError,
      );
    });

    test('输出 shape 不是 [1,T,V] 时明确报错', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a']);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.float32(Float32List(2 * vocab.length), <int>[
          2,
          vocab.length,
        ]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      expect(
        () => rec.recognizeLineDetailed(img.Image(width: 10, height: 10)),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('invalid output shape'),
          ),
        ),
      );
    });

    test('OcrTensor 构造时拒绝 data 长度与 shape 不符', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a']);
      expect(
        () => OcrTensor.float32(Float32List(1), <int>[1, 2, vocab.length]),
        throwsArgumentError,
      );
    });

    test('非 float32 输出时明确报 data 错误', () async {
      final List<String> vocab = buildPpOcrCtcVocab(<String>['a']);
      final _FakeSession session = _FakeSession(<String, OcrTensor>{
        'fetch_name_0': OcrTensor.int64(Int64List(2 * vocab.length), <int>[
          1,
          2,
          vocab.length,
        ]),
      });
      final PpOcrLineRecognizer rec = PpOcrLineRecognizer(
        session,
        vocab: vocab,
      );

      expect(
        () => rec.recognizeLineDetailed(img.Image(width: 10, height: 10)),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('missing or not float32'),
          ),
        ),
      );
    });
  });

  group('ctcGreedyDecodePositioned（逐字命中格的来源）', () {
    const List<String> vocab = <String>['', 'a', 'b'];

    test('文字与置信度和 ctcGreedyDecodeScored 逐字相同，token 带帧换算的位置', () {
      // 帧：a a _ b _ _ ；6 帧铺满 48 px 输入，内容宽 48，原行图宽 96。
      final Float32List logits = _logits(<int>[1, 1, 0, 2, 0, 0], 3);
      final scored = ctcGreedyDecodeScored(logits, 6, 3, vocab);
      final positioned = ctcGreedyDecodePositioned(
        logits,
        6,
        3,
        vocab,
        lineWidth: 96,
        contentWidth: 48,
        inputWidth: 48,
      );
      expect(positioned.text, scored.text);
      expect(positioned.text, 'ab');
      expect(positioned.confidence, scored.confidence);
      expect(positioned.tokens, hasLength(2));
      final OcrLineToken a = positioned.tokens[0];
      final OcrLineToken b = positioned.tokens[1];
      expect(<int>[a.start, a.end, b.start, b.end], <int>[0, 1, 1, 2]);
      // a 占帧 [0,2) → 输入 [0,16) → 原图 [0,32)；b 占帧 [3,4) → [24,32) → [48,64)。
      expect(<double?>[a.left, a.right], <double>[0, 32]);
      expect(<double?>[b.left, b.right], <double>[48, 64]);
    });

    test('blank 隔开的重复字是两个 token；落在右侧填充里的 token 没有位置', () {
      // a _ a _ b b：内容只有前 24 px（3 帧），b 在填充里。
      final Float32List logits = _logits(<int>[1, 0, 1, 0, 2, 2], 3);
      final positioned = ctcGreedyDecodePositioned(
        logits,
        6,
        3,
        vocab,
        lineWidth: 24,
        contentWidth: 24,
        inputWidth: 48,
      );
      expect(positioned.text, 'aab');
      expect(
        positioned.tokens.map((OcrLineToken t) => t.center != null),
        <bool>[true, true, false],
      );
    });
  });

  group('ocrLineGlyphBoxes', () {
    test('横行：字中心之间取中点分界，每格最多伸出 0.6 倍行厚，空格不出格', () {
      // 「第1 ロ」：空格两侧字距很大，均分会把「ロ」的格子挪到空格上。
      const OcrRect line = OcrRect(left: 100, top: 10, right: 500, bottom: 50);
      final List<OcrGlyphBox>? boxes = ocrLineGlyphBoxes(
        text: '第1 ロ',
        tokens: const <OcrLineToken>[
          OcrLineToken(start: 0, end: 1, left: 10, right: 30),
          OcrLineToken(start: 1, end: 2, left: 50, right: 70),
          OcrLineToken(start: 2, end: 3, left: 150, right: 160),
          OcrLineToken(start: 3, end: 4, left: 350, right: 370),
        ],
        line: line,
        vertical: false,
        alongOrigin: 100,
        utf16Offset: 5,
      );
      expect(boxes, isNotNull);
      expect(boxes!.map((OcrGlyphBox g) => g.start), <int>[5, 6, 8]);
      // 中心（页面）：120、160、460 → 分界 140、310；行厚 40，每格离字中心最多
      // 24（0.6 倍行厚）——「ロ」的格子不铺满空格那段空白。
      expect(boxes.map((OcrGlyphBox g) => g.rect.left), <double>[
        100,
        140,
        436,
      ]);
      expect(boxes.map((OcrGlyphBox g) => g.rect.right), <double>[
        140,
        184,
        484,
      ]);
      expect(boxes.every((OcrGlyphBox g) => g.rect.top == 10), isTrue);
      expect(boxes.every((OcrGlyphBox g) => g.rect.bottom == 50), isTrue);
    });

    test('竖列：位置沿 y 换回页面，字格横向占满列宽', () {
      const OcrRect line = OcrRect(left: 40, top: 200, right: 80, bottom: 320);
      final List<OcrGlyphBox>? boxes = ocrLineGlyphBoxes(
        text: 'あい',
        tokens: const <OcrLineToken>[
          OcrLineToken(start: 0, end: 1, left: 10, right: 30),
          OcrLineToken(start: 1, end: 2, left: 90, right: 110),
        ],
        line: line,
        vertical: true,
        alongOrigin: 200,
        utf16Offset: 0,
      );
      // 中心 220 / 300、分界 260；列宽 40 → 每格离字中心最多 24。
      expect(boxes!.map((OcrGlyphBox g) => g.rect.top), <double>[200, 276]);
      expect(boxes.map((OcrGlyphBox g) => g.rect.bottom), <double>[244, 320]);
      expect(boxes.every((OcrGlyphBox g) => g.rect.left == 40), isTrue);
      expect(boxes.every((OcrGlyphBox g) => g.rect.right == 80), isTrue);
    });

    test('有可见字拿不到位置就整行放弃（调用方退回按行均分）', () {
      expect(
        ocrLineGlyphBoxes(
          text: 'あい',
          tokens: const <OcrLineToken>[
            OcrLineToken(start: 0, end: 1, left: 10, right: 30),
            OcrLineToken(start: 1, end: 2),
          ],
          line: const OcrRect(left: 0, top: 0, right: 100, bottom: 30),
          vertical: false,
          alongOrigin: 0,
          utf16Offset: 0,
        ),
        isNull,
      );
      expect(
        joinOcrLineGlyphBoxes(<List<OcrGlyphBox>?>[
          const <OcrGlyphBox>[
            OcrGlyphBox(
              start: 0,
              end: 1,
              rect: OcrRect(left: 0, top: 0, right: 1, bottom: 1),
            ),
          ],
          null,
        ]),
        isNull,
      );
    });
  });
}
