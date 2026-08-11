import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_torrent/src/native_json.dart';
import 'package:test/test.dart';

void main() {
  test('localized malformed bytes do not discard an otherwise valid payload',
      () {
    final List<int> prefix = utf8.encode(
      '{"ok":true,"trackers":[{"url":"udp://tracker",'
      '"last_error":"',
    );
    final List<int> suffix = utf8.encode('","message":""}]}');
    final Uint8List payload = Uint8List.fromList(<int>[
      ...prefix,
      0xd6,
      0xd0,
      0xce,
      0xc4,
      ...suffix,
    ]);

    final Object? decoded = decodeNativeTorrentJsonBytes(payload);

    expect(decoded, isA<Map<String, Object?>>());
    final Map<String, Object?> json = decoded! as Map<String, Object?>;
    expect(json['ok'], isTrue);
    expect(json['trackers'], hasLength(1));
  });
}
