// 单轨 TS → 字幕包：PAT / PMT 找基本流、跨 TS 包拼 PES、PTS、增长中的文件（尾部半个
// 包 / 半个 PES）、不定长 PES、失步重同步、33 位 PTS 环绕。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';

import 'bitmap_subtitle_fixtures.dart';

Uint8List _bytes(int n, int seed) => Uint8List.fromList(<int>[
  for (int i = 0; i < n; i++) (i * 31 + seed) & 0xFF,
]);

void main() {
  final List<(int, Uint8List)> payloads = <(int, Uint8List)>[
    (90000, _bytes(40, 1)),
    (180000, _bytes(700, 2)), // 跨 4 个 TS 包
    (450000, _bytes(169, 3)), // PES 共 183 字节：差 1 字节填满，单字节适配域
  ];

  test('逐包还原 payload 与 PTS', () {
    final List<BitmapSubtitlePacket> packets = demuxMpegTsSubtitlePackets(
      buildSubtitleTs(payloads),
    );
    expect(packets.map((BitmapSubtitlePacket p) => p.pts90k), <int>[
      90000,
      180000,
      450000,
    ]);
    for (int i = 0; i < payloads.length; i++) {
      expect(packets[i].data, payloads[i].$2, reason: 'packet $i');
    }
    expect(packets.first.ptsMs, 1000);
  });

  test('增长中的文件：尾部半个 TS 包 / 没收满的 PES 不交出', () {
    final Uint8List full = buildSubtitleTs(payloads);
    // 切在第二个 PES 中间（PAT + PMT + 第一个 PES 一个包 + 第二个 PES 两个包 + 半包）。
    final Uint8List partial = Uint8List.sublistView(full, 0, 188 * 5 + 77);
    final List<BitmapSubtitlePacket> packets = demuxMpegTsSubtitlePackets(
      partial,
      complete: false,
    );
    expect(packets.map((BitmapSubtitlePacket p) => p.pts90k), <int>[90000]);
  });

  test('不定长 PES：下一个 PES 开始才交出；文件完整时尾 PES 也交出', () {
    final Uint8List ts = buildSubtitleTs(payloads, unsizedPes: true);
    expect(
      demuxMpegTsSubtitlePackets(ts, complete: false).length,
      2,
      reason: '最后一个可能还没写完',
    );
    final List<BitmapSubtitlePacket> all = demuxMpegTsSubtitlePackets(ts);
    expect(all, hasLength(3));
    // 不定长 PES 尾部带着 TS 填充之外的字节无从区分——这里没有填充，原样相等。
    expect(all[1].data, payloads[1].$2);
  });

  test('失步：开头垃圾字节跳过后重新找到同步', () {
    final Uint8List ts = buildSubtitleTs(payloads);
    final Uint8List noisy = Uint8List.fromList(<int>[1, 2, 3, 0x47, 9, ...ts]);
    expect(demuxMpegTsSubtitlePackets(noisy), hasLength(3));
  });

  test('33 位 PTS 环绕后仍单调', () {
    const int period = 1 << 33;
    final List<BitmapSubtitlePacket> packets = demuxMpegTsSubtitlePackets(
      buildSubtitleTs(<(int, Uint8List)>[
        (period - 90000, _bytes(10, 1)),
        (90000, _bytes(10, 2)),
      ]),
    );
    expect(packets[1].pts90k - packets[0].pts90k, 180000);
  });
}
