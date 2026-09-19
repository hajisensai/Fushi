import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';

/// BUG-2609：中继对视频源扩展流的两项归一化（伪装分片剥前缀 / 播放列表改写）的
/// 纯函数判据。真流形状：AnimeKai 的分片是 `image/png`，前 252 字节是一张 1×1 PNG
/// （IEND 在 62、之后垫零），然后才是 MPEG-TS。
void main() {
  Uint8List png1x1() => Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 魔数
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
    0x00, 0x1F, 0x15, 0xC4, 0x89,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, // IDAT
    0x78, 0xDA, 0x63, 0x64, 0xF8, 0xCF, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82, // IEND
  ]);

  Uint8List tsPackets(int count, {int seed = 1}) {
    final Uint8List out = Uint8List(kTransportStreamPacketLength * count);
    for (int p = 0; p < count; p++) {
      final int base = p * kTransportStreamPacketLength;
      out[base] = 0x47;
      for (int i = 1; i < kTransportStreamPacketLength; i++) {
        out[base + i] = (i * seed + p) & 0xFF;
        // 包内不许出现假同步字节（确保起点判据不是碰巧命中）。
        if (out[base + i] == 0x47) out[base + i] = 0x48;
      }
    }
    return out;
  }

  Uint8List concat(List<List<int>> parts) =>
      Uint8List.fromList(parts.expand((List<int> p) => p).toList());

  group('looksLikeImagePrefix', () {
    test('recognises PNG / JPEG / GIF / WebP / BMP magics', () {
      expect(looksLikeImagePrefix(png1x1()), isTrue);
      expect(
        looksLikeImagePrefix(<int>[
          0xFF,
          0xD8,
          0xFF,
          0xE0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]),
        isTrue,
      );
      expect(looksLikeImagePrefix('GIF89a......'.codeUnits), isTrue);
      expect(looksLikeImagePrefix('RIFF....WEBPVP8 '.codeUnits), isTrue);
      expect(looksLikeImagePrefix('BM..........'.codeUnits), isTrue);
    });

    test('plain TS / mp4 / playlist / short input are not images', () {
      expect(looksLikeImagePrefix(tsPackets(1)), isFalse);
      expect(
        looksLikeImagePrefix(<int>[
          0,
          0,
          0,
          0x18,
          ...'ftypisom'.codeUnits,
          0,
          0,
          0,
          0,
        ]),
        isFalse,
      );
      expect(looksLikeImagePrefix('#EXTM3U\n#EXT-X'.codeUnits), isFalse);
      expect(looksLikeImagePrefix(<int>[0x89, 0x50, 0x4E]), isFalse);
    });
  });

  group('disguisedMediaPayloadOffset', () {
    test(
      'finds the TS start after a PNG prefix and padding (AnimeKai shape)',
      () {
        final Uint8List png = png1x1();
        final Uint8List body = concat(<List<int>>[
          png,
          List<int>.filled(252 - png.length, 0),
          tsPackets(6),
        ]);
        expect(disguisedMediaPayloadOffset(body), 252);
      },
    );

    test('needs a run of sync bytes, not a lone 0x47 in the image', () {
      // 图片数据里散落的 0x47 不算：只有一个包宽的同步串。
      final Uint8List body = concat(<List<int>>[
        png1x1(),
        <int>[0x47],
        List<int>.filled(kTransportStreamPacketLength - 1, 0x11),
        <int>[0x47],
        List<int>.filled(kTransportStreamPacketLength - 1, 0x11),
        List<int>.filled(600, 0x22),
      ]);
      expect(disguisedMediaPayloadOffset(body), isNull);
    });

    test('too little data after the prefix is undecided (null)', () {
      // 探针要看到 4 个包的同步字节；只给两个包 → 还判不了，让中继继续攒。
      final Uint8List body = concat(<List<int>>[png1x1(), tsPackets(2)]);
      expect(disguisedMediaPayloadOffset(body), isNull);
      expect(
        disguisedMediaPayloadOffset(
          concat(<List<int>>[png1x1(), tsPackets(4)]),
        ),
        png1x1().length,
      );
    });

    test('finds a fragmented-mp4 box after the image prefix', () {
      final Uint8List body = concat(<List<int>>[
        png1x1(),
        <int>[0, 0, 0, 0x18],
        'ftypisom'.codeUnits,
        List<int>.filled(0x18 - 8, 0),
        <int>[0, 0, 0, 0x08],
        'moov'.codeUnits,
      ]);
      expect(disguisedMediaPayloadOffset(body), png1x1().length);
    });

    test('a genuine image (no media after it) stays null', () {
      final Uint8List body = concat(<List<int>>[
        png1x1(),
        List<int>.generate(4000, (int i) => (i * 7) & 0xFF),
      ]);
      expect(disguisedMediaPayloadOffset(body), isNull);
    });
  });

  group('playlist detection', () {
    test('content type / path / body magic', () {
      expect(isHlsPlaylistContentType('application/vnd.apple.mpegurl'), isTrue);
      expect(
        isHlsPlaylistContentType('application/x-mpegURL; charset=utf-8'),
        isTrue,
      );
      expect(isHlsPlaylistContentType('audio/mpegurl'), isTrue);
      expect(isHlsPlaylistContentType('video/mp2t'), isFalse);
      expect(isHlsPlaylistContentType(null), isFalse);
      expect(isHlsPlaylistPath('/a/b/index-f1-v1-a1.m3u8'), isTrue);
      expect(isHlsPlaylistPath('/a/b/list.M3U'), isTrue);
      expect(isHlsPlaylistPath('/a/b/seg.image'), isFalse);
      expect(looksLikeHlsPlaylist('#EXTM3U\n'.codeUnits), isTrue);
      expect(looksLikeHlsPlaylist('#EXTM'.codeUnits), isFalse);
      expect(looksLikeHlsPlaylist(png1x1()), isFalse);
    });
  });

  group('rewriteHlsPlaylistUris', () {
    String map(String uri) => 'MAPPED(${Uri.parse(uri).host})';

    test('rewrites absolute https segment lines and URI attributes only', () {
      const String playlist =
          '#EXTM3U\r\n'
          '#EXT-X-VERSION:3\r\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="https://key.example/k.bin",IV=0x1\r\n'
          '#EXT-X-MAP:URI="init.mp4"\r\n'
          '#EXTINF:3.84,\r\n'
          'https://p19.tiktokcdn.com/x.image?sig=a%2Fb\r\n'
          '#EXTINF:2.44,\r\n'
          'seg002.ts\r\n'
          '#EXTINF:2.44,\r\n'
          'http://plain.example/seg003.ts\r\n'
          '#EXT-X-ENDLIST\r\n';
      expect(
        rewriteHlsPlaylistUris(playlist, map),
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="MAPPED(key.example)",IV=0x1\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:3.84,\n'
        'MAPPED(p19.tiktokcdn.com)\n'
        '#EXTINF:2.44,\n'
        'seg002.ts\n'
        '#EXTINF:2.44,\n'
        'http://plain.example/seg003.ts\n'
        '#EXT-X-ENDLIST\n',
      );
    });

    test('master playlists get their variant and media URIs rewritten', () {
      const String master =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="https://cdn.example/a.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\n'
          'https://cdn.example/v.m3u8\n';
      expect(
        rewriteHlsPlaylistUris(master, map),
        '#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="MAPPED(cdn.example)"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\n'
        'MAPPED(cdn.example)\n',
      );
    });
  });

  group('range judgements', () {
    test('whole-body requests: no Range or bytes=0-', () {
      expect(isWholeBodyRangeRequest(null), isTrue);
      expect(isWholeBodyRangeRequest('bytes=0-'), isTrue);
      expect(isWholeBodyRangeRequest('bytes = 0-'), isTrue);
      expect(isWholeBodyRangeRequest('bytes=0-1023'), isFalse);
      expect(isWholeBodyRangeRequest('bytes=100-'), isFalse);
    });

    test('complete Content-Range covers the whole entity', () {
      expect(isCompleteContentRange('bytes 0-436787/436788'), isTrue);
      expect(isCompleteContentRange('bytes 0-436786/436788'), isFalse);
      expect(isCompleteContentRange('bytes 1-436787/436788'), isFalse);
      expect(isCompleteContentRange('bytes 0-10/*'), isFalse);
      expect(isCompleteContentRange(null), isFalse);
    });
  });
}
