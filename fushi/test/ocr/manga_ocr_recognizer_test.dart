import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

/// 测试词表：0=[PAD] 1=[UNK] 2=[CLS] 3=[SEP] 4=[MASK] 5=こ 6=ん 7=##は。
const String kVocabText = '[PAD]\n[UNK]\n[CLS]\n[SEP]\n[MASK]\nこ\nん\n##は\n';

/// fake encoder：小尺寸 hidden state（形状由测试控制，识别器按 shape 读）。
class FakeEncoderSession implements OcrSession {
  final List<Map<String, OcrTensor>> receivedInputs =
      <Map<String, OcrTensor>>[];

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    receivedInputs.add(inputs);
    // ONNX 只按元素总数收张量，NCHW 写成 NHWC 元素数不变、推理照跑，结果全错。
    // 维度必须逐位断言，否则这条契约在测试里等于没守（BUG-1173 同批审查）。
    expect(inputs['pixel_values']!.shape, <int>[
      1,
      3,
      224,
      224,
    ], reason: 'encoder 输入是 NCHW，通道在第 1 维');
    return <String, OcrTensor>{
      'last_hidden_state': OcrTensor.float32(Float32List(1 * 2 * 3), <int>[
        1,
        2,
        3,
      ]),
    };
  }

  @override
  Future<void> close() async {}
}

/// fake decoder：按「最后一个 token -> 下一个 token」的确定性转移产生 logits。
/// 转移：[CLS]→こ(5)、こ→ん(6)、ん→[SEP](3)。
class FakeDecoderSession implements OcrSession {
  final List<List<int>> receivedShapes = <List<int>>[];
  static const int vocabSize = 8;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final OcrTensor inputIds = inputs['input_ids']!;
    receivedShapes.add(List<int>.from(inputIds.shape));
    final int beams = inputIds.shape[0];
    final int seqLen = inputIds.shape[1];
    // 只断言 key 存在挡不住 beam tiling 写错：元素数相同，形状全错。
    expect(
      inputs['encoder_hidden_states']!.shape,
      <int>[beams, 2, 3],
      reason: 'encoder_hidden_states 必须沿 beam 维 tile 成 [beams, tokens, hidden]',
    );
    final Float32List logits = Float32List(beams * seqLen * vocabSize);
    for (int b = 0; b < beams; b++) {
      for (int t = 0; t < seqLen; t++) {
        final int last = inputIds.intData![b * seqLen + t];
        final int next = switch (last) {
          2 => 5,
          5 => 6,
          6 => 3,
          _ => 0,
        };
        final int offset = (b * seqLen + t) * vocabSize;
        for (int v = 0; v < vocabSize; v++) {
          logits[offset + v] = v == next ? 10 : -10;
        }
      }
    }
    return <String, OcrTensor>{
      'logits': OcrTensor.float32(logits, <int>[beams, seqLen, vocabSize]),
    };
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('MangaOcrTokenizer', () {
    test('vocab 加载与特殊符号定位', () {
      final MangaOcrTokenizer tokenizer = MangaOcrTokenizer.fromVocabText(
        kVocabText,
      );
      expect(tokenizer.vocabSize, 8);
      expect(tokenizer.padId, 0);
      expect(tokenizer.unkId, 1);
      expect(tokenizer.clsId, 2);
      expect(tokenizer.sepId, 3);
    });

    test('decode 跳过特殊符号并剥 ## 前缀', () {
      final MangaOcrTokenizer tokenizer = MangaOcrTokenizer.fromVocabText(
        kVocabText,
      );
      expect(tokenizer.decode(<int>[2, 5, 6, 7, 3, 0, 1]), 'こんは');
    });

    test('缺特殊符号的词表报错', () {
      expect(
        () => MangaOcrTokenizer.fromVocabText('a\nb\n'),
        throwsFormatException,
      );
    });

    test('postProcess：去空白、省略号与连点归一', () {
      expect(MangaOcrTokenizer.postProcess('こ ん\tに ち'), 'こんにち');
      expect(MangaOcrTokenizer.postProcess('あ…'), 'あ...');
      expect(MangaOcrTokenizer.postProcess('え・・'), 'え..');
      expect(MangaOcrTokenizer.postProcess('・'), '・'); // 单个中点保留
    });
  });

  group('mangaOcrNormalize', () {
    test('白 -> 1.0、黑 -> -1.0（(x/255-0.5)/0.5）', () {
      final img.Image white = img.Image(
        width: kRecInputSize,
        height: kRecInputSize,
      );
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      final Float32List whiteChw = mangaOcrNormalize(white);
      expect(whiteChw.first, closeTo(1.0, 1e-6));
      expect(whiteChw.last, closeTo(1.0, 1e-6));

      final img.Image black = img.Image(
        width: kRecInputSize,
        height: kRecInputSize,
      );
      final Float32List blackChw = mangaOcrNormalize(black);
      expect(blackChw.first, closeTo(-1.0, 1e-6));
    });

    test('彩色按 ITU-R 601-2 灰度化后三通道相同', () {
      final img.Image red = img.Image(
        width: kRecInputSize,
        height: kRecInputSize,
      );
      img.fill(red, color: img.ColorRgb8(255, 0, 0));
      final Float32List chw = mangaOcrNormalize(red);
      // PIL convert('L') 在归一化前取整成 8 位灰度，纯红得到 76。
      const double expected = (76 / 255 - 0.5) / 0.5;
      const int planeSize = kRecInputSize * kRecInputSize;
      expect(chw[0], closeTo(expected, 1e-4));
      expect(chw[planeSize], closeTo(expected, 1e-4));
      expect(chw[2 * planeSize], closeTo(expected, 1e-4));
    });
  });

  group('cropAndResizeForRecognition', () {
    // Oracle 由 Pillow 12.3.0 独立生成（不是 Dart helper 自己生成）：
    // RGB[x,y] = [(17*x+13*y)%256, (x*x+7*y)%256, (3*x+y*y)%256]
    // sha256(im.convert('L').convert('RGB')
    //          .resize((224,224), Image.Resampling.BILINEAR).tobytes())
    const List<(int, int, String)> pillowCases = <(int, int, String)>[
      (
        317,
        109,
        '2db809373936a27138e6e76ae91a52914d2ade4a7755ace1d6554685c0234e48',
      ),
      (
        109,
        317,
        'd126d7193d13160e3a3db487421b0f4552fe1aafcb487949e0b71d461c2450ac',
      ),
      (
        448,
        448,
        '99fd7083df5c65b943f3e2df6237249c9d4d98344d7053f1da99148eb5fbbc1a',
      ),
      (
        224,
        224,
        '8d4613580a4beac9084755ed163a2ddaa3dff548bf9e3e9487c7f33a50d80cf8',
      ),
      (
        1,
        5,
        '93b32e89babd9bc33733f31f9a08ba58596e192fa057a784baff1e038f309e95',
      ),
      (
        5,
        1,
        '3ed0162153f758b604695f1ee62b0bbda5f530a585f453c147a56aaad8aad12f',
      ),
    ];
    for (final (int width, int height, String expected) in pillowCases) {
      test('BUG-2643 灰度后双线性缩放与 Pillow 逐像素一致：$width×$height', () {
        final img.Image page = img.Image(width: width, height: height);
        for (final img.Pixel pixel in page) {
          final int x = pixel.x;
          final int y = pixel.y;
          pixel.setRgb(
            (17 * x + 13 * y) % 256,
            (x * x + 7 * y) % 256,
            (3 * x + y * y) % 256,
          );
        }
        final img.Image out = cropAndResizeForRecognition(
          page,
          OcrRect(
            left: 0,
            top: 0,
            right: width.toDouble(),
            bottom: height.toDouble(),
          ),
        );
        expect(
          sha256.convert(out.getBytes(order: img.ChannelOrder.rgb)).toString(),
          expected,
        );
      });
    }

    test('BUG-2643 索引色单像素笔画缩小不消失，与 RGB 输入一致', () {
      final img.Image palette = img.Image(
        width: 448,
        height: 448,
        numChannels: 3,
        withPalette: true,
      );
      palette.palette!.setRgb(0, 255, 255, 255);
      palette.palette!.setRgb(1, 0, 0, 0);
      for (final img.Pixel pixel in palette) {
        pixel.index = pixel.x % 2;
      }
      const OcrRect box = OcrRect(left: 0, top: 0, right: 448, bottom: 448);
      final img.Image out = cropAndResizeForRecognition(palette, box);
      final img.Image rgbOut = cropAndResizeForRecognition(
        palette.convert(numChannels: 3),
        box,
      );
      expect(out.getPixel(112, 112).r, 128);
      expect(out.getPixel(0, 112).r, 146);
      expect(out.getPixel(223, 112).r, 109);
      expect(out.hasPalette, isFalse);
      expect(out.getBytes(), orderedEquals(rgbOut.getBytes()));
    });

    test('BUG-2643 灰度 PNG 与等价 RGB 输入保持同样的亮度和细笔画', () {
      final img.Image gray = img.Image(width: 448, height: 448, numChannels: 1);
      final img.Image rgb = img.Image(width: 448, height: 448);
      for (final img.Pixel pixel in gray) {
        final int value = pixel.x.isEven ? 255 : 0;
        pixel.r = value;
        rgb.setPixelRgb(pixel.x, pixel.y, value, value, value);
      }
      final img.Image decoded = img.decodePng(img.encodePng(gray))!;
      const OcrRect box = OcrRect(left: 0, top: 0, right: 448, bottom: 448);
      final img.Image out = cropAndResizeForRecognition(decoded, box);
      final img.Image rgbOut = cropAndResizeForRecognition(rgb, box);
      expect(out.getPixel(112, 112).r, 128);
      expect(out.getBytes(), orderedEquals(rgbOut.getBytes()));
    });

    test('BUG-2643 小数裁框完整包含右边末列与下边末行', () {
      final img.Image page = img.Image(width: 8, height: 8);
      for (int i = 0; i <= 4; i++) {
        page.setPixelRgb(4, i, 255, 255, 255);
        page.setPixelRgb(i, 4, 255, 255, 255);
      }
      final img.Image out = cropAndResizeForRecognition(
        page,
        const OcrRect(left: 0.8, top: 0.8, right: 4.2, bottom: 4.2),
      );
      expect(out.getPixel(223, 112).r, 255);
      expect(out.getPixel(112, 223).r, 255);
      expect(out.getPixel(112, 112).r, 0);
    });

    test('裁出目标区域并 squish 到 224x224', () {
      final img.Image page = img.Image(width: 100, height: 100);
      img.fill(page, color: img.ColorRgb8(0, 0, 0));
      // 目标区域填白。
      img.fillRect(
        page,
        x1: 20,
        y1: 30,
        x2: 59,
        y2: 69,
        color: img.ColorRgb8(255, 255, 255),
      );
      final img.Image out = cropAndResizeForRecognition(
        page,
        const OcrRect(left: 20, top: 30, right: 60, bottom: 70),
      );
      expect(out.width, kRecInputSize);
      expect(out.height, kRecInputSize);
      final img.Pixel center = out.getPixel(112, 112);
      expect(center.r, greaterThan(200)); // 中心是白色内容
    });

    test('越界框被 clamp 而不是抛错', () {
      final img.Image page = img.Image(width: 50, height: 50);
      final img.Image out = cropAndResizeForRecognition(
        page,
        const OcrRect(left: -10, top: -10, right: 100, bottom: 100),
      );
      expect(out.width, kRecInputSize);
    });
  });

  group('MangaOcrRecognizer', () {
    test('encoder 一次 + decoder beam 自回归 → 文本', () async {
      final FakeEncoderSession encoder = FakeEncoderSession();
      final FakeDecoderSession decoder = FakeDecoderSession();
      final MangaOcrRecognizer recognizer = MangaOcrRecognizer(
        encoderSession: encoder,
        decoderSession: decoder,
        tokenizer: MangaOcrTokenizer.fromVocabText(kVocabText),
      );
      final img.Image page = img.Image(width: 64, height: 64);
      final String text = await recognizer.recognize(
        page,
        const OcrRect(left: 0, top: 0, right: 64, bottom: 64),
      );
      expect(text, 'こん');

      // encoder 只跑一次，输入形状 [1,3,224,224]。
      expect(encoder.receivedInputs, hasLength(1));
      expect(encoder.receivedInputs.single['pixel_values']!.shape, <int>[
        1,
        3,
        kRecInputSize,
        kRecInputSize,
      ]);

      // decoder 每步 batch = numBeams(4)，序列逐步加长。
      expect(decoder.receivedShapes.first, <int>[4, 1]);
      for (int i = 1; i < decoder.receivedShapes.length; i++) {
        expect(decoder.receivedShapes[i][0], 4);
        expect(
          decoder.receivedShapes[i][1],
          decoder.receivedShapes[i - 1][1] + 1,
        );
      }
    });
  });
}
