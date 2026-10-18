// 封面比对 / 大模型裁图 / TS 字幕解复用 回归用例：在确定性合成输入上跑公开 API，产出
// 摘要；测试比对 pipeline_kernel_vectors.dart 里钉住的值（由改用原生实现**之前**的纯
// Dart 实现生成）。
//
// 输入只用无损编码（PNG）或与解码无关的字节流：解码器换成 Rust 后这些用例仍须逐位相同。
// 有损（JPEG）输入的用例单独以 `/jpeg` 结尾，向量由 Rust 解码生成（差异见 PR）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/leaderboard/cover_compare.dart';
import 'package:fushi_engine/media/manga/mokuro_geometry.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:image/image.dart' as img;

import 'synthetic_images.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

class _Digest {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  void f(double v) {
    _scratch.setFloat64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List()));
  }

  void i(int v) {
    _scratch.setInt64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List()));
  }

  void s(String v) {
    final List<int> u = utf8.encode(v);
    i(u.length);
    _b.add(u);
  }

  void bytes(List<int> v) {
    i(v.length);
    _b.add(v);
  }

  String done() => _sha(_b.takeBytes());
}

img.Image _brighten(img.Image src, int delta) {
  final img.Image out = src.clone();
  for (final img.Pixel p in out) {
    p
      ..r = (p.r + delta).clamp(0, 255)
      ..g = (p.g + delta).clamp(0, 255)
      ..b = (p.b + delta).clamp(0, 255);
  }
  return out;
}

void _digestSimilarity(_Digest d, CoverSimilarity? s) {
  if (s == null) {
    d.s('null');
    return;
  }
  d.f(s.ncc);
  d.f(s.detailNcc);
  d.i(s.sameImage ? 1 : 0);
}

/// 一段 TS 合成流：PAT / PMT / 若干 PES（定长或不定长、跨包、带适配域）、空包与
/// 别的 PID 穿插、PTS 33 位环绕、没有 PTS 的 PES、垃圾字节（触发重同步）。
Uint8List synthSubtitleTs(int seed, {int pesCount = 60, bool junk = true}) {
  final SynthRng rng = SynthRng(seed);
  final BytesBuilder out = BytesBuilder();
  const int esPid = 0x101;
  const int pmtPid = 0x1001;
  Uint8List psi(int pid, List<int> section) {
    final Uint8List p = Uint8List(188)..fillRange(0, 188, 0xFF);
    p[0] = 0x47;
    p[1] = 0x40 | (pid >> 8);
    p[2] = pid & 0xFF;
    p[3] = 0x10;
    p[4] = 0; // pointer_field
    p.setRange(5, 5 + section.length, section);
    return p;
  }

  // CRC 不校验，写 4 个 0。
  final List<int> pat = <int>[
    0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, //
    0x00, 0x00, 0xE0, 0x10, // program 0 → network PID（应被跳过）
    0x00, 0x01, 0xE0 | (pmtPid >> 8), pmtPid & 0xFF,
    0, 0, 0, 0,
  ]..[2] = 17;
  final List<int> pmt = <int>[
    0x02, 0xB0, 18, 0x00, 0x01, 0xC1, 0x00, 0x00, //
    0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00,
    0x06, 0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00,
    0x06, 0xE0, 0x55, 0xF0, 0x00, // 第二条流：不应被选中
    0, 0, 0, 0,
  ]..[2] = 23;
  out
    ..add(psi(0, pat))
    ..add(psi(pmtPid, pmt));
  int cc = 0;
  int pts = (1 << 33) - 90000 * 20; // 二十秒后环绕
  for (int k = 0; k < pesCount; k++) {
    pts = (pts + 9000 + rng.below(200000)) % (1 << 33);
    if (rng.below(25) == 0) pts = (pts - 50000) % (1 << 33); // 偶尔回退一点
    final int size = rng.below(7) == 0 ? rng.below(3000) : rng.below(400);
    final List<int> data = <int>[for (int i = 0; i < size; i++) rng.below(256)];
    final bool withPts = rng.below(15) != 0;
    final bool unsized = rng.below(6) == 0;
    final List<int> header = withPts
        ? <int>[
            0x80,
            0x80,
            5 + (rng.below(4) == 0 ? 3 : 0),
            0x21 | ((pts >> 29) & 0x0E),
            (pts >> 22) & 0xFF,
            0x01 | ((pts >> 14) & 0xFE),
            (pts >> 7) & 0xFF,
            0x01 | ((pts << 1) & 0xFE),
          ]
        : <int>[0x80, 0x00, 0];
    if (withPts && header[2] == 8) header.addAll(<int>[0xFF, 0xFF, 0xFF]);
    final int length = unsized ? 0 : header.length + data.length;
    final List<int> pes = <int>[
      0, 0, 1, 0xBD, (length >> 8) & 0xFF, length & 0xFF, //
      ...header,
      ...data,
    ];
    int o = 0;
    bool first = true;
    while (o < pes.length) {
      if (rng.below(8) == 0) {
        // 空包 / 别的 PID 穿插。
        final Uint8List n = Uint8List(188)..fillRange(4, 188, rng.below(256));
        n[0] = 0x47;
        final int pid = rng.below(2) == 0 ? 0x1FFF : 0x55;
        n[1] = pid >> 8;
        n[2] = pid & 0xFF;
        n[3] = 0x10;
        out.add(n);
      }
      if (junk && rng.below(40) == 0) {
        out.add(<int>[
          for (int i = 0; i < 1 + rng.below(300); i++) rng.below(256),
        ]);
      }
      final int afc = rng.below(9);
      final Uint8List p = Uint8List(188);
      p[0] = 0x47;
      p[1] = (first ? 0x40 : 0) | (esPid >> 8);
      p[2] = esPid & 0xFF;
      if (afc == 0) {
        // 只有适配域、没有 payload 的包。
        p[3] = 0x20 | (cc++ & 0xF);
        p[4] = 183;
        out.add(p);
        continue;
      }
      final int maxRoom = afc == 1 ? 184 - 1 - rng.below(40) : 184;
      final int n = pes.length - o < maxRoom ? pes.length - o : maxRoom;
      if (n == 184) {
        p[3] = 0x10 | (cc++ & 0xF);
        p.setRange(4, 188, pes.sublist(o, o + n));
      } else {
        final int stuffing = 184 - n;
        p[3] = 0x30 | (cc++ & 0xF);
        p[4] = stuffing - 1;
        if (stuffing > 1) {
          p[5] = 0x00;
          p.fillRange(6, 4 + stuffing, 0xFF);
        }
        p.setRange(4 + stuffing, 188, pes.sublist(o, o + n));
      }
      out.add(p);
      o += n;
      first = false;
    }
  }
  return out.toBytes();
}

void _digestPackets(_Digest d, List<BitmapSubtitlePacket> packets) {
  d.i(packets.length);
  for (final BitmapSubtitlePacket p in packets) {
    d.i(p.pts90k);
    d.i(p.duration90k ?? -1);
    d.bytes(sha256.convert(p.data).bytes);
  }
}

/// 用例名 → 产出摘要。
Map<String, String Function()> pipelineKernelCases() {
  final Map<String, String Function()> cases = <String, String Function()>{};

  // ---- 封面比对 ----
  final img.Image coverA = synthImage(212, 300, 3, 71);
  final img.Image coverB = synthImage(212, 300, 3, 72);
  final Map<String, Uint8List> covers = <String, Uint8List>{
    'a': img.encodePng(coverA),
    'a-rgba': img.encodePng(synthImage(212, 300, 4, 71)),
    'a-small': img.encodePng(
      img.copyResize(
        coverA,
        width: 106,
        interpolation: img.Interpolation.average,
      ),
    ),
    'a-tiny': img.encodePng(img.copyResize(coverA, width: 20, height: 9)),
    'a-bright': img.encodePng(_brighten(coverA, 30)),
    'a-big': img.encodePng(
      img.copyResize(
        coverA,
        width: 900,
        interpolation: img.Interpolation.linear,
      ),
    ),
    'b': img.encodePng(coverB),
    'flat': img.encodePng(
      img.Image(width: 50, height: 70)..clear(img.ColorRgb8(90, 90, 90)),
    ),
    'flat2': img.encodePng(
      img.Image(width: 64, height: 64)..clear(img.ColorRgb8(100, 92, 90)),
    ),
    'one-pixel': img.encodePng(
      img.Image(width: 1, height: 1)..clear(img.ColorRgb8(1, 2, 3)),
    ),
    'garbage': Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9]),
  };
  final Map<String, Uint8List> jpegCovers = <String, Uint8List>{
    'a-q85': img.encodeJpg(coverA, quality: 85),
    'b-q60': img.encodeJpg(coverB, quality: 60),
  };
  for (final MapEntry<String, Uint8List> e in covers.entries) {
    cases['cover/signature/${e.key}'] = () {
      final CoverSignature? s = coverSignature(e.value);
      final _Digest d = _Digest();
      if (s == null) {
        d.s('null');
      } else {
        for (final double v in s.grid) {
          d.f(v);
        }
      }
      return d.done();
    };
  }
  const List<(String, String)> pairs = <(String, String)>[
    ('a', 'a'),
    ('a', 'a-rgba'),
    ('a', 'a-small'),
    ('a', 'a-tiny'),
    ('a', 'a-bright'),
    ('a', 'a-big'),
    ('a', 'b'),
    ('flat', 'flat'),
    ('flat', 'flat2'),
    ('flat', 'a'),
    ('one-pixel', 'flat'),
    ('a', 'garbage'),
    ('garbage', 'a'),
  ];
  for (final (String l, String r) in pairs) {
    cases['cover/compare/$l~$r'] = () {
      final _Digest d = _Digest();
      _digestSimilarity(d, compareCoverBytes(covers[l]!, covers[r]!));
      return d.done();
    };
  }
  cases['cover/compare/a~a-q85/jpeg'] = () {
    final _Digest d = _Digest();
    _digestSimilarity(d, compareCoverBytes(covers['a']!, jpegCovers['a-q85']!));
    _digestSimilarity(
      d,
      compareCoverBytes(jpegCovers['b-q60']!, jpegCovers['a-q85']!),
    );
    return d.done();
  };

  // ---- 大模型裁图 ----
  final Map<String, Uint8List> pages = <String, Uint8List>{
    'rgb': img.encodePng(synthImage(1300, 1800, 3, 81)),
    'rgba': img.encodePng(synthImage(700, 500, 4, 82)),
    'small': img.encodePng(synthImage(60, 40, 3, 83)),
  };
  final List<MokuroRect> boxes = <MokuroRect>[
    const MokuroRect.fromLTRB(100, 120, 400, 900), // 普通块
    const MokuroRect.fromLTRB(10, 10, 30, 50), // 短边 < 96：立方放大
    const MokuroRect.fromLTRB(0, 0, 1300, 1800), // 长边 > 1024：均值缩小
    const MokuroRect.fromLTRB(-50, -50, 5, 5), // 贴边外扩
    const MokuroRect.fromLTRB(2000, 2000, 2100, 2100), // 图外
    const MokuroRect.fromLTRB(500.5, 600.25, 500.75, 600.5), // 退化成很小
    const MokuroRect.fromLTRB(300, 300, 333, 1100), // 窄高：放大系数受长边限制
    const MokuroRect.fromLTRB(40, 700, 1290, 760), // 宽扁
  ];
  for (final MapEntry<String, Uint8List> e in pages.entries) {
    for (final (double pw, double ph) in <(double, double)>[
      (1300, 1800),
      (650, 900),
      (0, 0),
      (1000, 1500),
    ]) {
      cases['aicrop/${e.key}/${pw}x$ph'] = () {
        final List<Uint8List?> crops = cropMangaAiOcrBlocks(
          e.value,
          pageWidth: pw,
          pageHeight: ph,
          boxes: boxes,
        );
        final _Digest d = _Digest();
        d.i(crops.length);
        for (final Uint8List? c in crops) {
          if (c == null) {
            d.s('null');
            continue;
          }
          // 比对的是像素，不是 PNG 字节（编码器换了，压缩流不同）。
          final img.Image png = img.decodePng(c)!;
          d.i(png.width);
          d.i(png.height);
          d.i(png.numChannels);
          d.bytes(sha256.convert(png.toUint8List()).bytes);
        }
        return d.done();
      };
    }
  }
  cases['aicrop/garbage'] = () {
    final List<Uint8List?> crops = cropMangaAiOcrBlocks(
      Uint8List.fromList(<int>[0, 1, 2]),
      pageWidth: 10,
      pageHeight: 10,
      boxes: boxes,
    );
    return crops.map((Uint8List? c) => c == null ? 'n' : 'x').join();
  };
  cases['aicrop/nan-box'] = () {
    try {
      cropMangaAiOcrBlocks(
        pages['small']!,
        pageWidth: 60,
        pageHeight: 40,
        boxes: const <MokuroRect>[MokuroRect.fromLTRB(double.nan, 0, 10, 10)],
      );
      return 'no-throw';
    } on UnsupportedError {
      return 'UnsupportedError';
    }
  };

  // ---- TS 字幕解复用 ----
  for (final int seed in <int>[1, 2, 3]) {
    final Uint8List ts = synthSubtitleTs(seed, junk: seed != 3);
    for (final double cut in <double>[1.0, 0.73, 0.5, 0.21]) {
      final int end = (ts.length * cut).floor();
      for (final bool complete in <bool>[true, false]) {
        cases['ts/$seed/$cut/${complete ? 'complete' : 'growing'}'] = () {
          final _Digest d = _Digest();
          _digestPackets(
            d,
            demuxMpegTsSubtitlePackets(
              Uint8List.sublistView(ts, 0, end),
              complete: complete,
            ),
          );
          return d.done();
        };
      }
    }
  }
  for (final int seed in <int>[4, 5]) {
    // 每隔 7 个 TS 包（加一个奇数偏移）切一次：覆盖切在 PES 中间、不定长 PES 尾、
    // 半个 TS 包等各种「增长中」的边界。
    cases['ts/$seed/sweep'] = () {
      final Uint8List ts = synthSubtitleTs(seed, pesCount: 40);
      final _Digest d = _Digest();
      for (int end = 0; end <= ts.length; end += 188 * 7 + 61) {
        for (final bool complete in <bool>[false, true]) {
          _digestPackets(
            d,
            demuxMpegTsSubtitlePackets(
              Uint8List.sublistView(ts, 0, end),
              complete: complete,
            ),
          );
        }
      }
      return d.done();
    };
  }
  cases['ts/empty'] = () {
    final _Digest d = _Digest();
    _digestPackets(d, demuxMpegTsSubtitlePackets(Uint8List(0)));
    _digestPackets(d, demuxMpegTsSubtitlePackets(Uint8List(187)));
    _digestPackets(
      d,
      demuxMpegTsSubtitlePackets(Uint8List(188 * 3)..fillRange(0, 564, 0x47)),
    );
    return d.done();
  };
  return cases;
}

/// 生成向量时用：把整张表打印成 Dart 源码。
void printPipelineKernelVectors() {
  for (final MapEntry<String, String Function()> e
      in pipelineKernelCases().entries) {
    // ignore: avoid_print
    print("  '${e.key}': '${e.value()}',");
  }
}
