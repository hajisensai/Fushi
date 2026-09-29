import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';

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

  // 番剧（bilibili-pgc）：音轨由扩展在页面主世界里解析后随响应体回传，服务端据此挑流。
  // 它不参与 isImmersion 判据（那是「有没有可裁原始流 + 时间窗」的问题），但少了它服务端就得
  // 匿名去打 playurl —— 大会员内容必然失败。
  test('parses clipSourcePlayurlBody for the bilibili-pgc path', () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'sentence': '正道ではなく邪道'},
      'clipSourceKind': 'bilibili-pgc',
      'clipSourceId': '815751',
      'clipSourcePlayurlBody': '{"code":0,"result":{"dash":{"audio":[]}}}',
      'clipStartMs': 61000,
      'clipEndMs': 64500,
    });
    expect(p.clipSourceKind, 'bilibili-pgc');
    expect(p.clipSourceId, '815751');
    expect(p.clipSourcePlayurlBody, '{"code":0,"result":{"dash":{"audio":[]}}}');
    expect(p.isImmersion, isTrue);
  });

  test('clipSourcePlayurlBody absent -> null (falls back to no clip source)',
      () {
    final ImmersionMinePayload p =
        ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{'sentence': 'x'},
      'clipSourceKind': 'bilibili',
      'clipSourceId': 'BV1Este6wExx',
      'clipStartMs': 0,
      'clipEndMs': 1000,
    });
    expect(p.clipSourcePlayurlBody, isNull);
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
  test(
      'malformed clip/screenshot base64 -> null bytes, does NOT throw (no 400)',
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

  test('normalizes form-encoded text without corrupting literal plus signs',
      () {
    final p = ImmersionMinePayload.fromJson(<String, dynamic>{
      'fields': <String, dynamic>{
        'glossary': '(明鏡国語辞典+第三版)+たい%E3%81%9D%E3%81%86',
        'note': 'C++ primer',
      },
      'sentence':
          '%E3%81%86%E3%82%8D%E8%A6%9A%E3%81%88%E3%83%A9%E3%82%B8%E3%82%AA%E4%BD%93%E6%93%8D%E3%81%A7%E3%82%82%E3%81%97%E3%82%88%E3%81%86%EF%BC%81',
      'documentTitle':
          '[Kamigami]+Himouto%21+Umaru-chan+-+10+%5B1920x1080+x264+AAC%5D\n'
              '/var/mobile/Containers/Data/Application/ABC/Library/Caches/immersion_audio.aac',
    });

    expect(p.fields['glossary'], '(明鏡国語辞典 第三版) たいそう');
    expect(p.fields['note'], 'C++ primer');
    expect(p.sentence, 'うろ覚えラジオ体操でもしよう！');
    expect(
      p.documentTitle,
      '[Kamigami] Himouto! Umaru-chan - 10 [1920x1080 x264 AAC]',
    );
  });

  // 通用可裁流身份（bilibili 等）：加一个新站点不必再往 payload 上挂一对专用字段。
  group('clipSource（通用可裁流身份）', () {
    test('解析 kind/id/part 并进入沉浸路径', () {
      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': '正道'},
        'sentence': '正道ではなく邪道',
        'clipSourceKind': 'bilibili',
        'clipSourceId': 'BV1Este6wExx',
        'clipSourcePart': 13,
        'clipStartMs': 61000,
        'clipEndMs': 64500,
      });
      expect(p.clipSourceKind, 'bilibili');
      expect(p.clipSourceId, 'BV1Este6wExx');
      expect(p.clipSourcePart, 13);
      expect(p.isImmersion, true,
          reason: '有可裁源 + 时间窗就该走沉浸引擎，而不是退成纯文本卡');
    });

    test('缺时间窗 / 缺 id 时不算沉浸（没有窗就没得裁）', () {
      final noWindow = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': 'x'},
        'clipSourceKind': 'bilibili',
        'clipSourceId': 'BV1x',
      });
      expect(noWindow.isImmersion, false);

      final noId = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': 'x'},
        'clipSourceKind': 'bilibili',
        'clipStartMs': 1,
        'clipEndMs': 2,
      });
      expect(noId.isImmersion, false);
    });

    test('老扩展不发这些字段时一律 null（向后兼容）', () {
      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': 'x'},
        'sentence': 's',
      });
      expect(p.clipSourceKind, isNull);
      expect(p.clipSourceId, isNull);
      expect(p.clipSourcePart, isNull);
      expect(p.isImmersion, false);
    });

    test('只有解码帧、没有可裁流时仍是沉浸路径（出一张有图的卡）', () {
      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': 'x'},
        'sentence': 's',
        'screenshotBase64': base64Encode(<int>[7, 8]),
        'documentTitle': 'テスト動画_哔哩哔哩_bilibili',
      });
      expect(p.isImmersion, true);
      expect(p.screenshotBytes, <int>[7, 8]);
      expect(p.documentTitle, 'テスト動画_哔哩哔哩_bilibili');
    });
  });

  // BUG-2573：制卡时 `fields.audio` 是服务端把短命 token 换成的 `data:` 自包含 URI
  // （3007ff272 起）。标准 base64 字母表含 `+`，而 `_normalizeIncomingText` 原本按
  // 「加号 = 表单编码里的空格」还原，把 base64 里的孤立 `+` 全换成空格 → 落卡侧
  // `UriData.parse` 抛 Invalid base64 data → `AnkiAudioRef.decodeDataUri` 返回 null
  // → `_storeRemoteAudio` 返回 none → 卡片 ExpressionAudio 没有单词音频。
  // 2.2.4 的 token URL 用 base64UrlEncode（字母表是 `-` / `_`，不含 `+`）所以从没触发。
  group('BUG-2573：data: URI 载荷不被「加号→空格」归一化打坏', () {
    // 确定性伪随机字节（模拟真实单词音频），保证 base64 里出现多个孤立 `+`。
    List<int> sampleBytes() =>
        List<int>.generate(1024, (int i) => (i * 7919 + 13) % 256);

    int lonePlusCount(String s) {
      var n = 0;
      for (var i = 0; i < s.length; i++) {
        if (s.codeUnitAt(i) != 0x2b) continue;
        final prevIsPlus = i > 0 && s.codeUnitAt(i - 1) == 0x2b;
        final nextIsPlus = i + 1 < s.length && s.codeUnitAt(i + 1) == 0x2b;
        if (!prevIsPlus && !nextIsPlus) n++;
      }
      return n;
    }

    test('含加号的 data: URI 原样透传（+ 不被换成空格）', () {
      final dataUri = 'data:audio/mpeg;base64,${base64Encode(sampleBytes())}';
      // 自证：构造出的载荷必须真含孤立 +，否则这条用例测了个寂寞。
      expect(lonePlusCount(dataUri), greaterThan(1));

      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{'expression': '走る', 'audio': dataUri},
        'sentence': 's',
      });
      expect(p.fields['audio'], dataUri);
      expect(p.fields['audio'], isNot(contains(' ')),
          reason: 'base64 的 + 被换成空格，落卡侧就会解码失败');
    });

    test('端到端：解码出的字节与原始单词音频一致（不丢音频）', () {
      final bytes = sampleBytes();
      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{
          'expression': '走る',
          'reading': 'はしる',
          'audio': 'data:audio/mpeg;base64,${base64Encode(bytes)}',
        },
        'sentence': 's',
      });
      final AnkiAudioData? decoded =
          AnkiAudioRef.decodeDataUri(p.fields['audio']!);
      expect(decoded, isNotNull,
          reason: '解码失败 = 落卡侧 AudioFetchOutcome.none() = 卡片没有单词音频');
      expect(decoded!.bytes, bytes);
      expect(decoded.extension, 'mp3');
    });

    test('回归：普通文本字段仍照常做表单编码还原', () {
      final p = ImmersionMinePayload.fromJson(<String, dynamic>{
        'fields': <String, dynamic>{
          'glossary': '(明鏡+第三版)+たい%E3%81%9D%E3%81%86',
          'note': 'C++ primer',
        },
        'sentence': 's',
      });
      expect(p.fields['glossary'], '(明鏡 第三版) たいそう');
      expect(p.fields['note'], 'C++ primer', reason: '连续 ++ 不是分隔符，保持原样');
    });
  });
}
