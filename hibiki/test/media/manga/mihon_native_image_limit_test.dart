import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:http/http.dart' as http;

void main() {
  test('desktop image proxy streams through a bounded reader', () {
    final String source = File(
      'lib/src/media/manga/mihon/desktop_mihon_runtime.dart',
    ).readAsStringSync();

    expect(source.contains('readMihonImageBytesBounded'), isTrue);
    expect(source.contains('response.bodyBytes'), isFalse);
  });

  test('Android image proxy never buffers an unbounded ResponseBody', () {
    final String source = File(
      'android/app/src/main/kotlin/app/hibiki/reader/mihon/'
      'MihonChannelHandler.kt',
    ).readAsStringSync();

    expect(source.contains('readImageBodyBounded'), isTrue);
    expect(source.contains('response.body.bytes()'), isFalse);
  });

  test('declared oversized image is cancelled before body consumption',
      () async {
    var cancelled = false;
    final StreamController<List<int>> controller =
        StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final http.StreamedResponse response = http.StreamedResponse(
      controller.stream,
      HttpStatus.ok,
      contentLength: 6,
    );

    await expectLater(
      readMihonImageBytesBounded(response, maximumBytes: 5),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'IMAGE_TOO_LARGE',
        ),
      ),
    );
    expect(cancelled, isTrue);
    await controller.close();
  });

  test('chunked image without Content-Length stops at the hard limit',
      () async {
    final http.StreamedResponse response = http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5, 6],
        <int>[7, 8, 9],
      ]),
      HttpStatus.ok,
    );

    await expectLater(
      readMihonImageBytesBounded(response, maximumBytes: 5),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'IMAGE_TOO_LARGE',
        ),
      ),
    );
  });

  test('image exactly at the hard limit remains a valid positive control',
      () async {
    final http.StreamedResponse response = http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        <int>[1, 2],
        <int>[3, 4, 5],
      ]),
      HttpStatus.ok,
    );

    expect(
      await readMihonImageBytesBounded(response, maximumBytes: 5),
      Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
    );
  });
}
