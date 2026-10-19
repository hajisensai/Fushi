// 位图字幕内核回归用例：PGS / VobSub RLE 解码、DVB 像素串测量与区域渲染、黑底合成，
// 在确定性合成码流上跑公开 API 的摘要（向量见 bitmap_subtitle_kernel_vectors.dart，由改用
// 原生内核之前的纯 Dart 实现生成）。码流随机生成，刻意包含截断、越界游程、未知类型等坏数据。
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvb_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/pgs_subtitle_parser.dart';

import 'synthetic_images.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// 合法为主、夹杂坏字节的 PGS RLE 流。
Uint8List _pgsRle(
  SynthRng rng,
  int width,
  int height, {
  bool truncate = false,
}) {
  final BytesBuilder b = BytesBuilder();
  for (int y = 0; y < height; y++) {
    int x = 0;
    while (x < width) {
      final int kind = rng.below(6);
      final int color = 1 + rng.below(255);
      if (kind == 0) {
        b.addByte(color);
        x++;
      } else if (kind == 1) {
        final int n = 1 + rng.below(63);
        b.add(<int>[0, n]);
        x += n;
      } else if (kind == 2) {
        final int n = 64 + rng.below(400);
        b.add(<int>[0, 0x40 | (n >> 8), n & 0xFF]);
        x += n;
      } else if (kind == 3) {
        final int n = 3 + rng.below(60);
        b.add(<int>[0, 0x80 | n, color]);
        x += n;
      } else if (kind == 4) {
        final int n = 64 + rng.below(300);
        b.add(<int>[0, 0xC0 | (n >> 8), n & 0xFF, color]);
        x += n;
      } else {
        // 超长游程（越过行宽，解码器应截到行尾）。
        b.add(<int>[0, 0xC0 | 0x3F, 0xFF, color]);
        x += width;
      }
    }
    if (rng.below(9) != 0) b.add(<int>[0, 0]); // 偶尔漏掉行尾
  }
  final Uint8List out = b.toBytes();
  return truncate ? Uint8List.sublistView(out, 0, out.length * 2 ~/ 3) : out;
}

/// 两场的 SPU 半字节 RLE 包（随机码字，含越界偏移）。
({Uint8List packet, int top, int bottom}) _dvdPacket(SynthRng rng, int size) {
  final Uint8List p = Uint8List(size);
  for (int i = 0; i < size; i++) {
    p[i] = rng.below(256);
  }
  return (
    packet: p,
    top: rng.below(size ~/ 4),
    bottom: size ~/ 2 + rng.below(size ~/ 2 + 8),
  );
}

/// DVB 像素数据：2 / 4 / 8 bit 串、映射表段、行尾、偶尔一个未知类型。
Uint8List _dvbData(SynthRng rng, int lines, {bool garbage = false}) {
  final BytesBuilder b = BytesBuilder();
  for (int l = 0; l < lines; l++) {
    final int strings = 1 + rng.below(3);
    for (int s = 0; s < strings; s++) {
      final int kind = rng.below(8);
      if (kind == 0) {
        b.add(<int>[0x20, rng.below(256), rng.below(256)]);
      } else if (kind == 1) {
        b.add(<int>[0x21, for (int i = 0; i < 4; i++) rng.below(256)]);
      } else if (kind == 2) {
        b.add(<int>[0x22, for (int i = 0; i < 16; i++) rng.below(256)]);
      }
      b.addByte(<int>[0x10, 0x11, 0x12][rng.below(3)]);
      final int n = 4 + rng.below(40);
      for (int i = 0; i < n; i++) {
        b.addByte(rng.below(256));
      }
      b.add(<int>[0, 0]); // 多数码型下的串尾
    }
    b.addByte(0xF0);
  }
  if (garbage) b.add(<int>[0x99, 1, 2, 3]);
  return b.toBytes();
}

Uint32List _palette(SynthRng rng, int n) => Uint32List.fromList(<int>[
  for (int i = 0; i < n; i++)
    (<int>[0, 0x40, 0x80, 0xC0, 0xFF][rng.below(5)] << 24) | rng.below(1 << 24),
]);

/// 用例名 → 产出摘要。
Map<String, String Function()> bitmapSubtitleKernelCases() {
  final Map<String, String Function()> cases = <String, String Function()>{};

  for (final (int w, int h) in <(int, int)>[
    (1, 1),
    (37, 5),
    (640, 48),
    (1500, 120),
  ]) {
    for (final bool truncate in <bool>[false, true]) {
      cases['pgs/rle/${w}x$h/${truncate ? 'cut' : 'full'}'] = () {
        final SynthRng rng = SynthRng(w * 7 + h + (truncate ? 1 : 0));
        return _sha(
          decodePgsRle(_pgsRle(rng, w, h, truncate: truncate), w, h)!,
        );
      };
    }
  }
  cases['pgs/rle/empty'] = () => _sha(decodePgsRle(Uint8List(0), 9, 4)!);

  for (final (int w, int h, int size) in <(int, int, int)>[
    (16, 4, 32),
    (720, 60, 6000),
    (333, 101, 900),
  ]) {
    cases['dvd/rle/${w}x$h/$size'] = () {
      final ({Uint8List packet, int top, int bottom}) p = _dvdPacket(
        SynthRng(w + h + size),
        size,
      );
      return _sha(
        decodeDvdSubtitleRle(
          p.packet,
          width: w,
          height: h,
          topFieldOffset: p.top,
          bottomFieldOffset: p.bottom,
        ),
      );
    };
  }

  for (int seed = 0; seed < 6; seed++) {
    cases['dvb/size/$seed'] = () {
      final SynthRng rng = SynthRng(100 + seed);
      final DvbObject o = DvbObject(
        top: _dvbData(rng, 3 + rng.below(20), garbage: seed == 3),
        bottom: seed.isEven ? _dvbData(rng, 2 + rng.below(20)) : null,
      );
      final ({int width, int height}) s = o.size;
      return '${s.width}x${s.height}';
    };
    for (final int depth in <int>[2, 4, 8]) {
      cases['dvb/region/$seed/$depth'] = () {
        final SynthRng rng = SynthRng(200 + seed * 3 + depth);
        final DvbRegion region = DvbRegion(
          width: 50 + rng.below(400),
          height: 10 + rng.below(80),
          depth: depth,
          clutId: 0,
          background: seed == 1 ? 3 : 0,
          objects: <DvbObjectPlacement>[
            for (int i = 0; i < 1 + rng.below(3); i++)
              DvbObjectPlacement(
                object: DvbObject(
                  top: _dvbData(rng, 2 + rng.below(30)),
                  bottom: rng.below(2) == 0
                      ? _dvbData(rng, 2 + rng.below(30))
                      : null,
                ),
                x: rng.below(120) - 20,
                y: rng.below(40) - 5,
              ),
          ],
        );
        return _sha(region.render());
      };
    }
  }

  for (int seed = 0; seed < 8; seed++) {
    cases['compose/$seed'] = () {
      final SynthRng rng = SynthRng(300 + seed);
      final List<BitmapSubtitleLayer> layers = <BitmapSubtitleLayer>[];
      for (int i = 0; i < 1 + rng.below(3); i++) {
        final int stride = 20 + rng.below(300);
        final int rows = 5 + rng.below(60);
        final Uint8List idx = Uint8List(stride * rows - rng.below(stride));
        for (int k = 0; k < idx.length; k++) {
          idx[k] = rng.below(seed == 5 ? 300 : 20) & 0xFF;
        }
        layers.add(
          BitmapSubtitleLayer(
            x: rng.below(800),
            y: rng.below(200),
            width: 10 + rng.below(stride),
            height: 3 + rng.below(rows + 4),
            indices: idx,
            stride: stride,
            sourceX: rng.below(10),
            sourceY: rng.below(4),
            palette: seed == 6
                ? Uint32List(16) // 全透明调色板 → 纯黑
                : _palette(rng, 4 + rng.below(16)),
          ),
        );
      }
      final BitmapSubtitleBounds bounds = bitmapSubtitleLayerBounds(
        layers.map(
          (BitmapSubtitleLayer l) =>
              (x: l.x, y: l.y, width: l.width, height: l.height),
        ),
      );
      final BitmapSubtitleImage im = bitmapSubtitleImageOf(
        composeBitmapSubtitleImage(
          bounds: bounds,
          layers: layers,
          padding: seed == 7 ? 0 : 16,
        ),
      );
      return '${im.width}x${im.height}:${_sha(im.rgba)}';
    };
  }
  return cases;
}
