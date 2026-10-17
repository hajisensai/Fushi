// DVD 图形字幕（VobSub / SPU）解码：控制序列（时间 / 颜色 / 不透明度 / 显示区 / 强制）、
// 两场隔行 2 bit RLE、extradata 调色板与画布、结束时间的三种来源。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';

import 'bitmap_subtitle_fixtures.dart';

/// [w]×[h]，四周一圈 0、中间 [c]；第 [stripeRow] 行（若给）整行为 [stripe]。
List<List<int>> _glyph(int w, int h, int c, {int? stripeRow, int stripe = 2}) =>
    <List<int>>[
      for (int y = 0; y < h; y++)
        <int>[
          for (int x = 0; x < w; x++)
            y == stripeRow
                ? stripe
                : (x > 0 && x < w - 1 && y > 0 && y < h - 1 ? c : 0),
        ],
    ];

BitmapSubtitlePacket _packet(int ms, Uint8List data) =>
    BitmapSubtitlePacket(pts90k: ms * 90, data: data);

final VobSubHeader _header = VobSubHeader.parse(vobSubIdxHeader());

void main() {
  group('VobSubHeader', () {
    test('读 size 与 16 色 palette，其它行忽略', () {
      expect(_header.width, 720);
      expect(_header.height, 480);
      expect(_header.palette, hasLength(16));
      expect(_header.palette![1], 0xFFFFFF);
      expect(_header.palette![2], 0x808080);
    });

    test('缺行 / 坏值 / 空 extradata 当没写', () {
      final VobSubHeader h = VobSubHeader.parse(
        Uint8List.fromList('size: abc\npalette: 1, 2\n'.codeUnits),
      );
      expect(h.width, 0);
      expect(h.palette, isNull);
      expect(VobSubHeader.parse(null).palette, isNull);
    });
  });

  group('decodeDvdSubtitlePackets', () {
    test('开始 = PTS + STA 延时；结束 = PTS + STP 延时；显示区 / 画布 / 强制', () {
      final List<DvdSubtitleCue> cues =
          decodeDvdSubtitlePackets(<BitmapSubtitlePacket>[
            _packet(
              1000,
              buildSpuPacket(
                x: 100,
                y: 400,
                pixels: _glyph(40, 9, 1),
                startDelay: 9, // 9 × 1024/90 = 102 ms
                stopDelay: 176, // 176 × 1024/90 = 2002 ms
                forced: true,
              ),
            ),
          ], header: _header);
      expect(cues, hasLength(1));
      final DvdSubtitleCue cue = cues.single;
      expect(cue.startMs, 1102);
      expect(cue.endMs, 3002);
      expect(cue.forced, isTrue);
      expect(cue.bounds, (left: 100, top: 400, right: 140, bottom: 409));
      expect((cue.canvasWidth, cue.canvasHeight), (720, 480));
    });

    test('两场隔行 RLE：奇偶行各自还原，长游程（>255）与行尾填充都对', () {
      final List<List<int>> pixels = <List<int>>[
        for (int y = 0; y < 7; y++)
          <int>[
            for (int x = 0; x < 400; x++)
              y.isEven
                  ? (x >= 10 && x < 310 ? 1 : 0) // 300 像素长游程
                  : (x % 7 == 0 ? 3 : (x < 70 ? 2 : 0)),
          ],
      ];
      final DvdSubtitleCue cue = decodeDvdSubtitlePackets(
        <BitmapSubtitlePacket>[
          _packet(0, buildSpuPacket(x: 0, y: 0, pixels: pixels, stopDelay: 90)),
        ],
        header: _header,
      ).single;
      final Uint8List indices = cue.decodeIndices();
      expect(indices, hasLength(400 * 7));
      for (int y = 0; y < 7; y++) {
        expect(
          indices.sublist(y * 400, (y + 1) * 400),
          pixels[y],
          reason: 'row $y',
        );
      }
    });

    test('渲染：黑底、按 SET_COLOR 取 extradata 调色板、按最大不透明度归一化', () {
      final DvdSubtitleCue cue = decodeDvdSubtitlePackets(
        <BitmapSubtitlePacket>[
          _packet(
            0,
            buildSpuPacket(
              x: 10,
              y: 20,
              pixels: _glyph(6, 5, 1, stripeRow: 4, stripe: 2),
              // 下标 1 → palette[1] 白，下标 2 → palette[2] 灰；整体半透明（淡入帧）。
              colors: const <int>[0, 1, 2, 3],
              alphas: const <int>[0, 8, 8, 8],
              stopDelay: 90,
            ),
          ),
        ],
        header: _header,
      ).single;
      final BitmapSubtitleImage image = cue.renderRgba(padding: 2);
      expect((image.width, image.height), (10, 9));
      int at(int x, int y) => image.rgba[(y * image.width + x) * 4];
      expect(at(0, 0), 0, reason: '留边是黑的');
      expect(at(2, 2), 0, reason: '下标 0 透明 → 黑底');
      expect(at(3, 3), 255, reason: '半透明也按满不透明渲染白字');
      expect(at(3, 6), 0x80, reason: '第 5 行是灰色条');
      expect(image.rgba[3], 255, reason: '整图不透明');
    });

    test('没有 16 色调色板：按不透明度从暗到亮猜灰阶（ffmpeg guess_palette）', () {
      final DvdSubtitleCue cue = decodeDvdSubtitlePackets(
        <BitmapSubtitlePacket>[
          _packet(
            0,
            buildSpuPacket(
              x: 0,
              y: 0,
              pixels: _glyph(5, 4, 1, stripeRow: 3, stripe: 2),
              colors: const <int>[0, 5, 9, 9],
              alphas: const <int>[0, 15, 15, 15],
              stopDelay: 90,
            ),
          ),
        ],
      ).single;
      final BitmapSubtitleImage image = cue.renderRgba(padding: 0);
      int at(int x, int y) => image.rgba[(y * image.width + x) * 4];
      // 两种不透明颜色：先出现的（下标 1）暗、后出现的（下标 2）亮。
      expect(at(1, 1), 0x00);
      expect(at(0, 3), 0xFF);
      expect((cue.canvasWidth, cue.canvasHeight), (0, 0));
    });

    test('没有 STP_DSP：显示到下一个包（含只清屏的包）；最后一条按兜底时长', () {
      final List<DvdSubtitleCue> cues =
          decodeDvdSubtitlePackets(<BitmapSubtitlePacket>[
            _packet(1000, buildSpuPacket(x: 0, y: 0, pixels: _glyph(4, 2, 1))),
            _packet(
              2500,
              buildSpuPacket(
                x: 0,
                y: 0,
                pixels: _glyph(4, 2, 1),
                showCommand: false,
                stopDelay: 0,
              ),
            ),
            _packet(4000, buildSpuPacket(x: 0, y: 0, pixels: _glyph(5, 2, 1))),
          ], header: _header);
      expect(cues.map((DvdSubtitleCue c) => (c.startMs, c.endMs)), <(int, int)>[
        (1000, 2500),
        (4000, 4000 + kBitmapSubtitleOpenCueCapMs),
      ]);
    });

    test('截断 / 坏包跳过，其余照常', () {
      final Uint8List good = buildSpuPacket(
        x: 0,
        y: 0,
        pixels: _glyph(4, 2, 1),
        stopDelay: 90,
      );
      final List<DvdSubtitleCue> cues = decodeDvdSubtitlePackets(
        <BitmapSubtitlePacket>[
          _packet(0, Uint8List.sublistView(good, 0, good.length - 3)),
          _packet(100, Uint8List.fromList(<int>[0, 1])),
          _packet(5000, good),
        ],
        header: _header,
      );
      expect(cues.map((DvdSubtitleCue c) => c.startMs), <int>[5000]);
    });
  });
}
