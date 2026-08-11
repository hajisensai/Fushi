import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_torrent/src/native_json.dart';
import 'package:test/test.dart';

/// native 侧没修好的本地化错误串（旧随包 DLL）在 payload 里长这样：
/// CP936 会把它解成「中文」、CP1252 会把它解成「ÖÐÎÄ」，两个 code page 都能
/// 解出「像样」的文本，但它本身不是合法 UTF-8。
const List<int> _localizedAnsiBytes = <int>[0xd6, 0xd0, 0xce, 0xc4];

/// 同一份 payload 里合法 UTF-8 的那半：任何整包重解码都会毁掉它。
/// - CP936 解 `テスト` 的 UTF-8 字节 → 汉字垃圾
/// - CP1252 解同一串 → `ãƒ†ã‚¹ãƒˆ` 之类的 Latin-1 垃圾
const String _validUtf8Name = 'テスト・中文 Ω';

Uint8List _mixedPayload() {
  return Uint8List.fromList(<int>[
    ...utf8.encode(
      '{"ok":true,"torrents":[{"name":"$_validUtf8Name"}],'
      '"trackers":[{"url":"udp://tracker","last_error":"',
    ),
    ..._localizedAnsiBytes,
    ...utf8.encode('","message":""}]}'),
  ]);
}

void main() {
  group('decodeNativeTorrentJsonBytes', () {
    test('malformed bytes do not discard an otherwise valid payload', () {
      final Object? decoded = decodeNativeTorrentJsonBytes(_mixedPayload());

      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> json = decoded! as Map<String, Object?>;
      expect(json['ok'], isTrue);
      expect(json['trackers'], hasLength(1));
    });

    // BUG-1522 回归门：坏字段不得连累同包的合法字段。
    //
    // 这条断言与本机 ANSI code page 无关——旧实现在 CP936 和 CP1252 上都会
    // 把整包换成 ANSI 重解，两种 code page 下 name 都不再等于原字符串，所以
    // 936 的开发机和 1252 的 CI 上它同样会红。
    test('a malformed field never corrupts valid UTF-8 fields beside it', () {
      final Map<String, Object?> json =
          decodeNativeTorrentJsonBytes(_mixedPayload())!
              as Map<String, Object?>;

      final List<Object?> torrents = json['torrents']! as List<Object?>;
      final Map<String, Object?> torrent =
          torrents.single! as Map<String, Object?>;
      expect(torrent['name'], _validUtf8Name);
    });

    // Dart 层不做编码猜测：坏字节只能就地变成 U+FFFD。断言「不等于任何一种
    // code page 的猜测结果」，因此在 936 与 1252 下含义一致。
    test('the malformed field degrades to U+FFFD instead of a code page guess',
        () {
      final Map<String, Object?> json =
          decodeNativeTorrentJsonBytes(_mixedPayload())!
              as Map<String, Object?>;

      final List<Object?> trackers = json['trackers']! as List<Object?>;
      final Map<String, Object?> tracker =
          trackers.single! as Map<String, Object?>;
      final String lastError = tracker['last_error']! as String;

      expect(lastError, contains('�'));
      expect(lastError, isNot(contains('中文')), reason: 'CP936 猜测结果');
      expect(lastError, isNot(contains('ÖÐÎÄ')), reason: 'CP1252 猜测结果');
      expect(lastError.replaceAll('�', ''), isEmpty);
    });

    // native 侧修好后的正常路径：整包合法 UTF-8，原样解出，一个字节不改。
    test('valid UTF-8 payloads round-trip untouched', () {
      final Map<String, Object?> json = decodeNativeTorrentJsonBytes(
        Uint8List.fromList(
          utf8.encode(
            '{"ok":true,"torrents":[{"name":"$_validUtf8Name"}],'
            '"trackers":[{"url":"udp://tracker",'
            '"last_error":"中文 �"}]}',
          ),
        ),
      )! as Map<String, Object?>;

      final List<Object?> torrents = json['torrents']! as List<Object?>;
      expect(
          (torrents.single! as Map<String, Object?>)['name'], _validUtf8Name);
      final List<Object?> trackers = json['trackers']! as List<Object?>;
      expect(
        (trackers.single! as Map<String, Object?>)['last_error'],
        '中文 �',
      );
    });

    test('non-JSON payloads decode to null instead of throwing', () {
      expect(
        decodeNativeTorrentJsonBytes(Uint8List.fromList(utf8.encode('{oops'))),
        isNull,
      );
      expect(decodeNativeTorrentJsonBytes(Uint8List(0)), isNull);
    });
  });
}
