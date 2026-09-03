import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/forwarded_mine_payload.dart';

/// 互联「制卡到服务端」转发载体的序列化守卫。核心不变式：
/// * rawPayloadJson + context 文本 + 四类媒体字节能完整 round-trip；
/// * 单个媒体 base64 坏了只降级为 null，绝不因此把整个请求抛掉（只有 rawPayloadJson 缺失
///   才是真正的坏请求 → FormatException → 400）。
void main() {
  group('ForwardedMinePayload', () {
    test('全字段（含四类媒体字节）round-trip', () {
      final ForwardedMinePayload p = ForwardedMinePayload(
        rawPayloadJson: '{"expression":"猫"}',
        sentence: '猫がいる',
        cueSentence: 'cue',
        documentTitle: 'Book',
        sentenceOffset: 42,
        source: 'book',
        bookTitleTag: 'Book_tag',
        clipStartMs: 12345,
        clipEndMs: 67890,
        coverBytes: Uint8List.fromList(<int>[1, 2, 3]),
        coverExt: 'jpg',
        sentenceAudioBytes: Uint8List.fromList(<int>[4, 5]),
        sentenceAudioExt: 'aac',
        wordAudioBytes: Uint8List.fromList(<int>[6]),
        wordAudioExt: 'mp3',
        dictionaryMedia: <ForwardedDictMedia>[
          ForwardedDictMedia(
              dictionary: '明鏡',
              path: 'a/b.svg',
              bytes: Uint8List.fromList(<int>[7, 8])),
        ],
      );

      final Map<String, dynamic> j =
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final ForwardedMinePayload r = ForwardedMinePayload.fromJson(j);

      expect(r.rawPayloadJson, p.rawPayloadJson);
      expect(r.sentence, '猫がいる');
      expect(r.cueSentence, 'cue');
      expect(r.documentTitle, 'Book');
      expect(r.sentenceOffset, 42);
      expect(r.source, 'book');
      expect(r.bookTitleTag, 'Book_tag');
      expect(r.clipStartMs, 12345);
      expect(r.clipEndMs, 67890);
      expect(r.coverBytes, <int>[1, 2, 3]);
      expect(r.coverExt, 'jpg');
      expect(r.sentenceAudioBytes, <int>[4, 5]);
      expect(r.sentenceAudioExt, 'aac');
      expect(r.wordAudioBytes, <int>[6]);
      expect(r.wordAudioExt, 'mp3');
      expect(r.dictionaryMedia.single.dictionary, '明鏡');
      expect(r.dictionaryMedia.single.path, 'a/b.svg');
      expect(r.dictionaryMedia.single.bytes, <int>[7, 8]);
    });

    test('片段时间窗：不带两键的旧对端 → 解析成 null，卡照建', () {
      // 服务端渲染 `{clip-timestamp}` 时两端 null → 空串（唯一有效性判据在
      // AnkiHandlebarRenderer.formatClipTimestamp）。旧版本对端不发这两个键，
      // 解析必须落 null 而不是 0/抛异常——否则整条远端制卡请求挂掉。
      final ForwardedMinePayload r =
          ForwardedMinePayload.fromJson(<String, dynamic>{
        'rawPayloadJson': '{"expression":"猫"}',
        'sentence': 'x',
      });
      expect(r.clipStartMs, isNull);
      expect(r.clipEndMs, isNull);
    });

    test('片段时间窗：null 时不写进 wire（旧服务端不会收到多余键）', () {
      const ForwardedMinePayload p = ForwardedMinePayload(
        rawPayloadJson: '{"expression":"猫"}',
        sentence: '猫がいる',
      );
      final Map<String, dynamic> j = p.toJson();
      expect(j.containsKey('clipStartMs'), isFalse);
      expect(j.containsKey('clipEndMs'), isFalse);
    });

    test('片段时间窗：0 起点是有效值，必须照发不误当缺失', () {
      // `if (clipStartMs != null)` 而不是真值判断——0ms 起点（从头截的片段）
      // 是完全合法的窗口起点，被吞掉会让卡上时间窗错位。
      const ForwardedMinePayload p = ForwardedMinePayload(
        rawPayloadJson: '{}',
        sentence: 's',
        clipStartMs: 0,
        clipEndMs: 4200,
      );
      final Map<String, dynamic> j = p.toJson();
      expect(j['clipStartMs'], 0);
      expect(j['clipEndMs'], 4200);
      final ForwardedMinePayload r = ForwardedMinePayload.fromJson(
          jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(r.clipStartMs, 0);
      expect(r.clipEndMs, 4200);
    });

    test('rawPayloadJson 缺失/空 → FormatException（真正的坏请求）', () {
      expect(
          () =>
              ForwardedMinePayload.fromJson(<String, dynamic>{'sentence': 'x'}),
          throwsFormatException);
      expect(
          () => ForwardedMinePayload.fromJson(
              <String, dynamic>{'rawPayloadJson': ''}),
          throwsFormatException);
    });

    test('坏 base64 媒体降级为 null，不抛', () {
      final ForwardedMinePayload r =
          ForwardedMinePayload.fromJson(<String, dynamic>{
        'rawPayloadJson': '{}',
        'coverBase64': '!!!not base64!!!',
      });
      expect(r.coverBytes, isNull);
    });

    test('无字节的词典媒体条目被过滤掉', () {
      final ForwardedMinePayload r =
          ForwardedMinePayload.fromJson(<String, dynamic>{
        'rawPayloadJson': '{}',
        'dictionaryMedia': <dynamic>[
          <String, dynamic>{'path': 'a.svg'}, // 无 base64 → 丢弃
          <String, dynamic>{
            'path': 'b.svg',
            'base64': base64Encode(<int>[1])
          },
        ],
      });
      expect(r.dictionaryMedia.length, 1);
      expect(r.dictionaryMedia.single.path, 'b.svg');
    });

    test('sanitizeExt 剥分隔符、截断、空/非串回 null', () {
      expect(ForwardedMinePayload.sanitizeExt('JPG'), 'jpg');
      expect(ForwardedMinePayload.sanitizeExt('../etc'), 'etc');
      expect(ForwardedMinePayload.sanitizeExt('a' * 20), 'a' * 8);
      expect(ForwardedMinePayload.sanitizeExt(''), isNull);
      expect(ForwardedMinePayload.sanitizeExt(123), isNull);
    });

    test('toJson 省略空的可选字段（体积/向后兼容）', () {
      const ForwardedMinePayload p =
          ForwardedMinePayload(rawPayloadJson: '{}', sentence: '');
      final Map<String, dynamic> j = p.toJson();
      expect(j.containsKey('coverBase64'), isFalse);
      expect(j.containsKey('dictionaryMedia'), isFalse);
      expect(j.containsKey('source'), isFalse);
      expect(j.containsKey('cueSentence'), isFalse);
    });
  });
}
