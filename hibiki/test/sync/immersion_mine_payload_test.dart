import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';

void main() {
  test('parses fields+sentence+timestamp+screenshot', () {
    final b64 = base64Encode(<int>[1, 2, 3]);
    final p = ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'expression': '走る'},
      'sentence': 's',
      'timestampMs': 1234,
      'netflixVideoId': '81',
      'screenshotBase64': b64,
    });
    expect(p.fields['expression'], '走る');
    expect(p.sentence, 's');
    expect(p.timestampMs, 1234);
    expect(p.netflixVideoId, '81');
    expect(p.screenshotBytes, <int>[1, 2, 3]);
    expect(p.isImmersion, true);
  });

  test('missing optionals -> nulls, sentence falls back to fields, not immersion', () {
    final p = ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'sentence': 'fromfield'},
    });
    expect(p.timestampMs, isNull);
    expect(p.screenshotBytes, isNull);
    expect(p.sentence, 'fromfield');
    expect(p.isImmersion, false);
  });

  test('non-map fields throws FormatException', () {
    expect(
      () => ImmersionMinePayload.fromJson(<String, dynamic>{'fields': 'x'}),
      throwsFormatException,
    );
  });

  test('clip range + videoId marks immersion (2B path)', () {
    final p = ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'expression': 'x'},
      'netflixVideoId': '81',
      'clipStartMs': 1000,
      'clipEndMs': 3000,
    });
    expect(p.clipStartMs, 1000);
    expect(p.clipEndMs, 3000);
    expect(p.isImmersion, true);
  });
}
