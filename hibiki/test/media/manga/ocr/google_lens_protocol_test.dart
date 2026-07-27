import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_protocol.dart';
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
      requestId: 42,
    );
    expect(_containsBytes(request, <int>[9, 8, 7, 6]), isTrue);
    expect(_containsBytes(request, <int>[0x6a, 0x61]), isTrue);
  });

  test('decodes line text, removes CJK spaces and records UTF-16 regions', () {
    final List<GoogleLensParagraph> result =
        GoogleLensProtocol.decodeResponse(makeGoogleLensFixture());
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
      ),
      throwsA(isA<GoogleLensProtocolException>()),
    );
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
