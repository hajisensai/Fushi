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

  test(
      'missing optionals -> nulls, sentence falls back to fields, not immersion',
      () {
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

  test('parses youtubeVideoId + video-time window as immersion', () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'sentence': 'これはテスト'},
      'sentence': 'これはテスト',
      'youtubeVideoId': 'dQw4w9WgXcQ',
      'clipStartMs': 12000,
      'clipEndMs': 15000,
    });
    expect(p.youtubeVideoId, 'dQw4w9WgXcQ');
    expect(p.clipStartMs, 12000);
    expect(p.clipEndMs, 15000);
    expect(p.isImmersion, isTrue);
    expect(p.clipBytes, isNull);
  });

  test('youtubeVideoId without a window is not immersion', () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'sentence': 'x'},
      'youtubeVideoId': 'abc',
    });
    expect(p.youtubeVideoId, 'abc');
    expect(p.isImmersion, isFalse);
  });

  test('valid clipBase64 decodes to clipBytes', () {
    final String clip = base64Encode(<int>[10, 20, 30, 40]);
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'expression': 'x'},
      'clipBase64': clip,
      'clipDurationMs': 8000,
    });
    expect(p.clipBytes, <int>[10, 20, 30, 40]);
    expect(p.clipDurationMs, 8000);
    expect(p.isImmersion, true);
  });

  // BUG（TODO-1000）：offscreen 曾用 split(',')[1] 从 webm data URL 取 base64，但 webm 的
  // MIME（video/webm;codecs=vp8,opus）含逗号 → 取到 'opus;base64' 这种垃圾。服务端此前 base64Decode
  // 直接抛 FormatException → 整张卡 HTTP 400。根因已在 offscreen 修好；此处守卫服务端**容错**：
  // 坏的可选媒体 base64 一律降级为 null，绝不把整张卡 400 掉（只有 fields 缺失才是坏请求）。
  test('malformed clip/screenshot base64 -> null bytes, does NOT throw (no 400)',
      () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'expression': 'x'},
      'sentence': 's',
      'clipBase64': 'opus;base64', // 旧 split bug 会产出的垃圾片段
      'screenshotBase64': 'not*valid*base64!!',
    });
    expect(p.clipBytes, isNull);
    expect(p.screenshotBytes, isNull);
    expect(p.sentence, 's'); // 卡照常可组（文本），不因坏媒体失败
  });
}
