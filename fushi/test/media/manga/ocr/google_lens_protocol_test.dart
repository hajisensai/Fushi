import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:image/image.dart' as img;

import 'google_lens_fixture.dart';

void main() {
  test('prepares JPEG at quality path and caps longest edge to 1500', () {
    final img.Image source = img.Image(width: 2000, height: 1000);
    final GoogleLensPreparedImage prepared = GoogleLensProtocol.prepareImage(
      Uint8List.fromList(img.encodePng(source)),
    );
    expect(prepared.originalWidth, 2000);
    expect(prepared.originalHeight, 1000);
    expect(prepared.width, 1500);
    expect(prepared.height, 750);
    expect(prepared.data.take(2), <int>[0xff, 0xd8]);
  });

  test('request contains image payload and Japanese locale', () {
    final Uint8List request = GoogleLensProtocol.makeRequest(
      imageData: Uint8List.fromList(<int>[9, 8, 7, 6]),
      width: 320,
      height: 240,
      language: 'ja',
      requestId: 42,
    );
    expect(_containsBytes(request, <int>[9, 8, 7, 6]), isTrue);
    expect(_containsBytes(request, <int>[0x6a, 0x61]), isTrue);
  });

  test('decodes line text, removes CJK spaces and records UTF-16 regions', () {
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(),
      language: 'ja',
      imageWidth: 1000,
      imageHeight: 1000,
    );
    expect(result, hasLength(1));
    expect(result.single.sentence, '日本');
    expect(result.single.isVertical, isFalse);
    expect(result.single.regions, hasLength(2));
    expect(result.single.regions.first.utf16Start, 0);
    expect(result.single.regions.first.utf16End, 1);
    expect(result.single.regions.last.utf16Start, 1);
    expect(result.single.regions.last.utf16End, 2);
    expect(
        result.single.regions.first.normalizedBounds.left, closeTo(0.3, 1e-5));
  });

  test('rotation produces vertical regions', () {
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(
        firstWord: '縦',
        secondWord: '書',
        width: 0.1,
        height: 0.4,
        rotation: 1.57079632679,
      ),
      language: 'ja',
      imageWidth: 1000,
      imageHeight: 1000,
    );
    expect(result.single.isVertical, isTrue);
    expect(
      result.single.regions.first.normalizedBounds.top,
      lessThan(result.single.regions.last.normalizedBounds.top),
    );
    expect(
      result.single.regions.first.normalizedBounds.height,
      lessThan(result.single.normalizedBounds.height * 0.75),
      reason: '旋转行应先沿基线拆字符，不能让每个字符占满整行 AABB',
    );
  });

  test('horizontal lines are ordered from visual top to bottom', () {
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(
        firstWord: '上',
        secondWord: '',
        centerY: 0.3,
        secondLineText: '下',
        secondLineCenterY: 0.7,
      ),
      language: 'ja',
      imageWidth: 1000,
      imageHeight: 1000,
    );
    expect(result.single.sentence, '上下');
    expect(
      result.single.regions.first.normalizedBounds.top,
      lessThan(result.single.regions.last.normalizedBounds.top),
    );
  });

  test('malformed protobuf is rejected', () {
    expect(
      () => GoogleLensProtocol.decodeResponse(
        Uint8List.fromList(<int>[0x12, 0xff, 0xff]),
        language: 'ja',
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      throwsA(isA<GoogleLensProtocolException>()),
    );
  });

  // BUG-1172：旋转必须按送检图的宽高比还原。Lens 的 width 按图宽归一、height 按
  // 图高归一，直接把两者混进同一组 sin/cos 只在正方形页成立；漫画页恒是竖长图。
  // 判据一律放在**像素空间**——旋转矩形的像素 AABB 与归一化口径无关。
  test('45 度斜行保留非方形页 AABB 并按 Niratan 横排方向切分', () {
    const int pageWidth = 1200;
    const int pageHeight = 1700;
    const double rotation = math.pi / 4;
    const double lineWidth = 0.4;
    const double lineHeight = 0.1;
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(
        firstWord: '斜',
        secondWord: '体',
        width: lineWidth,
        height: lineHeight,
        rotation: rotation,
      ),
      language: 'ja',
      imageWidth: pageWidth,
      imageHeight: pageHeight,
    );
    expect(result.single.sentence, '斜体');
    expect(result.single.regions, hasLength(2));

    final double expectedLinePixelWidth =
        lineWidth * pageWidth * math.cos(rotation).abs() +
            lineHeight * pageHeight * math.sin(rotation).abs();
    final double expectedLinePixelHeight =
        lineWidth * pageWidth * math.sin(rotation).abs() +
            lineHeight * pageHeight * math.cos(rotation).abs();
    final Rect line = result.single.normalizedBounds;
    expect(line.width * pageWidth, closeTo(expectedLinePixelWidth, 0.5));
    expect(line.height * pageHeight, closeTo(expectedLinePixelHeight, 0.5));

    final Rect first = result.single.regions.first.normalizedBounds;
    expect(first.width * pageWidth, closeTo(expectedLinePixelWidth / 2, 0.5));
    expect(first.height * pageHeight, closeTo(expectedLinePixelHeight, 0.5));

    // Niratan 的最终命中语义按段落方向切 AABB：横排固定左到右，不再受
    // rotation 正负号影响而把字符命中顺序翻转。
    final Rect second = result.single.regions.last.normalizedBounds;
    expect(first.center.dx, lessThan(second.center.dx));
    expect(first.center.dy, closeTo(second.center.dy, 1e-5));
  });

  test('负 90 度竖排仍按视觉上到下切分', () {
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(
        firstWord: '上',
        secondWord: '下',
        width: 0.4,
        height: 0.08,
        rotation: -math.pi / 2,
      ),
      language: 'ja',
      imageWidth: 1200,
      imageHeight: 1700,
    );
    expect(result.single.isVertical, isTrue);
    expect(
      result.single.regions.first.normalizedBounds.top,
      lessThan(result.single.regions.last.normalizedBounds.top),
    );
  });

  test('90 度竖行在非方形页上的 X 半宽按页宽高比还原', () {
    const int pageWidth = 1200;
    const int pageHeight = 1700;
    const double lineWidth = 0.4;
    const double lineHeight = 0.06;
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(
        firstWord: '縦',
        secondWord: '書',
        width: lineWidth,
        height: lineHeight,
        rotation: math.pi / 2,
      ),
      language: 'ja',
      imageWidth: pageWidth,
      imageHeight: pageHeight,
    );
    final Rect bounds = result.single.normalizedBounds;
    // 90° 时行的像素宽 = 未旋转时的像素高（lineHeight * 页高），与页宽无关。
    expect(bounds.width * pageWidth, closeTo(lineHeight * pageHeight, 0.5));
    // 行的像素高 = 未旋转时的像素宽（lineWidth * 页宽）。
    expect(bounds.height * pageHeight, closeTo(lineWidth * pageWidth, 0.5));
  });

  test('English decode keeps word spaces instead of CJK stripping', () {
    final List<GoogleLensParagraph> result = GoogleLensProtocol.decodeResponse(
      makeGoogleLensFixture(firstWord: 'Hello ', secondWord: 'world'),
      language: 'en',
      imageWidth: 1000,
      imageHeight: 1000,
    );
    expect(result.single.sentence, 'Hello world');
  });

  test('request carries the requested locale language on the wire', () {
    final Uint8List request = GoogleLensProtocol.makeRequest(
      imageData: Uint8List.fromList(<int>[9, 8, 7, 6]),
      width: 320,
      height: 240,
      language: 'en',
      requestId: 42,
    );
    expect(_containsBytes(request, <int>[0x65, 0x6e]), isTrue);
  });

  test('engine signature appends the language to the shared prefix', () {
    expect(googleLensEngineSignature('ja'), 'google-lens-v2-niratan-ja');
    expect(googleLensEngineSignature('en'), 'google-lens-v2-niratan-en');
    expect(
      googleLensEngineSignature('ja'),
      startsWith(kGoogleLensEngineSignaturePrefix),
    );
  });

  test('normalizeLensLanguage keeps primary subtags and falls back otherwise',
      () {
    expect(normalizeLensLanguage('en'), 'en');
    expect(normalizeLensLanguage('pt-BR'), 'pt');
    expect(normalizeLensLanguage('zh_Hans'), 'zh');
    expect(normalizeLensLanguage('EN'), 'en');
    expect(normalizeLensLanguage(''), 'ja');
    expect(normalizeLensLanguage(null), 'ja');
    expect(normalizeLensLanguage('all'), 'ja');
    expect(normalizeLensLanguage('multi'), 'ja');
    expect(normalizeLensLanguage('42'), 'ja');
    expect(normalizeLensLanguage(null, fallback: 'en'), 'en');
  });
}

bool _containsBytes(Uint8List source, List<int> needle) {
  for (int offset = 0; offset <= source.length - needle.length; offset++) {
    bool matches = true;
    for (int index = 0; index < needle.length; index++) {
      if (source[offset + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
