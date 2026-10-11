/// 手工构造的位图字幕码流（测试用）：DVD SPU 包、DVB 显示集、单轨 MPEG-TS 与
/// Matroska。纯 Dart、不依赖 flutter_test，也可在脚本里直接用来造真机样本。
library;

import 'dart:convert';
import 'dart:typed_data';

// ── 通用位写入 ──────────────────────────────────────────────────────────────

class BitWriter {
  final List<int> _bytes = <int>[];
  int _acc = 0;
  int _n = 0;

  void write(int value, int bits) {
    for (int i = bits - 1; i >= 0; i--) {
      _acc = (_acc << 1) | ((value >> i) & 1);
      _n++;
      if (_n == 8) {
        _bytes.add(_acc);
        _acc = 0;
        _n = 0;
      }
    }
  }

  void align() {
    if (_n > 0) write(0, 8 - _n);
  }

  Uint8List toBytes() {
    align();
    return Uint8List.fromList(_bytes);
  }
}

/// 一行像素 → (长度, 颜色) 游程。
List<(int, int)> runsOf(List<int> row) {
  final List<(int, int)> runs = <(int, int)>[];
  for (final int c in row) {
    if (runs.isNotEmpty && runs.last.$2 == c) {
      runs[runs.length - 1] = (runs.last.$1 + 1, c);
    } else {
      runs.add((1, c));
    }
  }
  return runs;
}

// ── DVD SPU ────────────────────────────────────────────────────────────────

/// 2 bit SPU RLE 编一个场（[rows] 是这个场的各行）。最后一个游程到行尾时用「填满本行」码。
Uint8List encodeSpuField(List<List<int>> rows) {
  final BitWriter w = BitWriter();
  for (final List<int> row in rows) {
    final List<(int, int)> runs = runsOf(row);
    for (int i = 0; i < runs.length; i++) {
      final (int len, int color) = runs[i];
      final bool last = i == runs.length - 1;
      if (last && len > 3) {
        w.write(color, 16); // 0x000c 形式：v < 4 = 填满本行。
        continue;
      }
      int left = len;
      while (left > 0) {
        final int n = left > 255 ? 255 : left;
        final int v = (n << 2) | color;
        if (n < 4) {
          w.write(v, 4);
        } else if (n < 16) {
          w.write(v, 8);
        } else if (n < 64) {
          w.write(v, 12);
        } else {
          w.write(v, 16);
        }
        left -= n;
      }
    }
    w.align();
  }
  return w.toBytes();
}

/// 一个完整 SPU 包。[pixels] 是 [height] 行 × [width] 列的 2 bit 码。
/// 延时单位是 1024/90000 秒（ffmpeg / DVD 规范同口径）；[stopDelay] 为 null = 不写
/// STP_DSP。[showCommand] 为 false = 只有 STP_DSP 的清屏包。
Uint8List buildSpuPacket({
  required int x,
  required int y,
  required List<List<int>> pixels,
  List<int> colors = const <int>[0, 1, 2, 3],
  List<int> alphas = const <int>[0, 15, 15, 15],
  int startDelay = 0,
  int? stopDelay,
  bool forced = false,
  bool showCommand = true,
}) {
  final int height = pixels.length;
  final int width = height == 0 ? 0 : pixels.first.length;
  final Uint8List top = encodeSpuField(<List<int>>[
    for (int r = 0; r < height; r += 2) pixels[r],
  ]);
  final Uint8List bottom = encodeSpuField(<List<int>>[
    for (int r = 1; r < height; r += 2) pixels[r],
  ]);
  const int topOffset = 4;
  final int bottomOffset = topOffset + top.length;
  final int seq1 = bottomOffset + bottom.length;
  final List<int> cmds1 = <int>[
    if (showCommand) forced ? 0x00 : 0x01,
    0x03,
    (colors[3] << 4) | colors[2],
    (colors[1] << 4) | colors[0],
    0x04,
    (alphas[3] << 4) | alphas[2],
    (alphas[1] << 4) | alphas[0],
    0x05,
    x >> 4,
    ((x & 0xF) << 4) | ((x + width - 1) >> 8),
    (x + width - 1) & 0xFF,
    y >> 4,
    ((y & 0xF) << 4) | ((y + height - 1) >> 8),
    (y + height - 1) & 0xFF,
    0x06,
    topOffset >> 8,
    topOffset & 0xFF,
    bottomOffset >> 8,
    bottomOffset & 0xFF,
    0xFF,
  ];
  final int seq2 = seq1 + 4 + cmds1.length;
  final BytesBuilder b = BytesBuilder()
    ..add(<int>[0, 0, seq1 >> 8, seq1 & 0xFF])
    ..add(top)
    ..add(bottom)
    ..add(<int>[startDelay >> 8, startDelay & 0xFF])
    ..add(
      stopDelay == null
          ? <int>[seq1 >> 8, seq1 & 0xFF]
          : <int>[seq2 >> 8, seq2 & 0xFF],
    )
    ..add(cmds1);
  if (stopDelay != null) {
    b
      ..add(<int>[stopDelay >> 8, stopDelay & 0xFF, seq2 >> 8, seq2 & 0xFF])
      ..add(<int>[0x02, 0xFF]);
  }
  final Uint8List out = b.toBytes();
  out[0] = out.length >> 8;
  out[1] = out.length & 0xFF;
  return out;
}

/// VobSub `.idx` 头（Matroska `S_VOBSUB` CodecPrivate）。
Uint8List vobSubIdxHeader({
  int width = 720,
  int height = 480,
  List<int>? palette,
}) {
  final List<int> p =
      palette ??
      <int>[
        0x000000, 0xffffff, 0x808080, 0x202020, //
        for (int i = 4; i < 16; i++) 0x101010 * i,
      ];
  return ascii.encode(
    '# VobSub index file, v7 (do not modify this line!)\n'
    'size: ${width}x$height\n'
    'palette: ${p.map((int c) => c.toRadixString(16).padLeft(6, '0')).join(', ')}\n',
  );
}

// ── DVB ────────────────────────────────────────────────────────────────────

/// 4 bit 像素串（data_type 0x11）编一行，含游程编码。
void _write4bitLine(BitWriter w, List<int> row) {
  for (final (int len0, int c) in runsOf(row)) {
    int len = len0;
    while (len > 0) {
      if (c == 0) {
        if (len == 1) {
          w
            ..write(0, 4)
            ..write(1, 1)
            ..write(1, 1)
            ..write(0, 2);
          len -= 1;
        } else if (len == 2) {
          w
            ..write(0, 4)
            ..write(1, 1)
            ..write(1, 1)
            ..write(1, 2);
          len -= 2;
        } else if (len <= 9) {
          w
            ..write(0, 4)
            ..write(0, 1)
            ..write(len - 2, 3);
          len = 0;
        } else {
          final int n = len > 280 ? 280 : len;
          if (n >= 25) {
            w
              ..write(0, 4)
              ..write(1, 1)
              ..write(1, 1)
              ..write(3, 2)
              ..write(n - 25, 8)
              ..write(0, 4);
          } else {
            w
              ..write(0, 4)
              ..write(1, 1)
              ..write(1, 1)
              ..write(2, 2)
              ..write(n - 9, 4)
              ..write(0, 4);
          }
          len -= n;
        }
      } else if (len >= 4) {
        final int n = len > 280 ? 280 : len;
        if (n <= 7) {
          w
            ..write(0, 4)
            ..write(1, 1)
            ..write(0, 1)
            ..write(n - 4, 2)
            ..write(c, 4);
        } else if (n <= 8) {
          // 8 无法用 4–7 / 9–24 一次编，拆成 4 + 4。
          for (int k = 0; k < 2; k++) {
            w
              ..write(0, 4)
              ..write(1, 1)
              ..write(0, 1)
              ..write(0, 2)
              ..write(c, 4);
          }
        } else if (n <= 24) {
          w
            ..write(0, 4)
            ..write(1, 1)
            ..write(1, 1)
            ..write(2, 2)
            ..write(n - 9, 4)
            ..write(c, 4);
        } else {
          w
            ..write(0, 4)
            ..write(1, 1)
            ..write(1, 1)
            ..write(3, 2)
            ..write(n - 25, 8)
            ..write(c, 4);
        }
        len -= n;
      } else {
        w.write(c, 4);
        len -= 1;
      }
    }
  }
  w
    ..write(0, 4)
    ..write(0, 1)
    ..write(0, 3); // end of string
}

/// 2 bit 像素串（0x10）编一行。
void _write2bitLine(BitWriter w, List<int> row) {
  for (final (int len0, int c) in runsOf(row)) {
    int len = len0;
    while (len > 0) {
      if (len >= 3 && len <= 10) {
        w
          ..write(0, 2)
          ..write(1, 1)
          ..write(len - 3, 3)
          ..write(c, 2);
        len = 0;
      } else if (len >= 12 && len <= 27) {
        w
          ..write(0, 2)
          ..write(0, 1)
          ..write(0, 1)
          ..write(2, 2)
          ..write(len - 12, 4)
          ..write(c, 2);
        len = 0;
      } else if (len >= 29) {
        final int n = len > 284 ? 284 : len;
        w
          ..write(0, 2)
          ..write(0, 1)
          ..write(0, 1)
          ..write(3, 2)
          ..write(n - 29, 8)
          ..write(c, 2);
        len -= n;
      } else if (c == 0) {
        w
          ..write(0, 2)
          ..write(0, 1)
          ..write(1, 1); // one pixel colour 0
        len -= 1;
      } else {
        w.write(c, 2);
        len -= 1;
      }
    }
  }
  w
    ..write(0, 2)
    ..write(0, 1)
    ..write(0, 1)
    ..write(0, 2); // end of string
}

/// 8 bit 像素串（0x12）编一行。
void _write8bitLine(BitWriter w, List<int> row) {
  for (final (int len0, int c) in runsOf(row)) {
    int len = len0;
    while (len > 0) {
      final int n = len > 127 ? 127 : len;
      if (c == 0) {
        w
          ..write(0, 8)
          ..write(0, 1)
          ..write(n, 7);
        len -= n;
      } else if (n >= 3) {
        w
          ..write(0, 8)
          ..write(1, 1)
          ..write(n, 7)
          ..write(c, 8);
        len -= n;
      } else {
        w.write(c, 8);
        len -= 1;
      }
    }
  }
  w
    ..write(0, 8)
    ..write(0, 1)
    ..write(0, 7);
}

/// 一个场的像素数据（每行一个像素串 + 行尾码 0xF0）。[bits] = 2 / 4 / 8。
Uint8List encodeDvbField(List<List<int>> rows, int bits) {
  final BytesBuilder b = BytesBuilder();
  for (final List<int> row in rows) {
    final BitWriter w = BitWriter();
    switch (bits) {
      case 2:
        b.addByte(0x10);
        _write2bitLine(w, row);
      case 4:
        b.addByte(0x11);
        _write4bitLine(w, row);
      default:
        b.addByte(0x12);
        _write8bitLine(w, row);
    }
    b
      ..add(w.toBytes())
      ..addByte(0xF0);
  }
  return b.toBytes();
}

Uint8List _segment(int type, int pageId, List<int> body) =>
    Uint8List.fromList(<int>[
      0x0F,
      type,
      pageId >> 8,
      pageId & 0xFF,
      body.length >> 8,
      body.length & 0xFF,
      ...body,
    ]);

class DvbRegionSpec {
  const DvbRegionSpec({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.depthBits = 4,
    this.clutId = 0,
    this.background = 0,
    this.objects = const <DvbObjectSpec>[],
  });

  final int id;
  final int x;
  final int y;
  final int width;
  final int height;
  final int depthBits;
  final int clutId;
  final int background;
  final List<DvbObjectSpec> objects;
}

class DvbObjectSpec {
  const DvbObjectSpec({
    required this.id,
    required this.x,
    required this.y,
    required this.pixels,
    this.stringBits = 4,
    this.repeatTopField = false,
  });

  final int id;
  final int x;
  final int y;
  final List<List<int>> pixels;
  final int stringBits;

  /// 底场长度写 0（解码器应重复顶场）。
  final bool repeatTopField;
}

/// CLUT 项：(entry, Y, Cr, Cb, T)，按 full range 写进 4 / 16 / 256 三张表。
typedef DvbClutEntry = (int entry, int y, int cr, int cb, int t);

/// 一个 DVB 显示集（PCS + DDS? + RCS + CLUT + ODS + END）。[pageState] 2 = mode change。
/// [tsWrapped] 为真时加上 TS 封装的 `0x20 0x00 … 0xFF`。
Uint8List buildDvbDisplaySet({
  int pageId = 1,
  int timeoutSec = 0,
  int pageState = 2,
  int version = 0,
  List<DvbRegionSpec> regions = const <DvbRegionSpec>[],
  Map<int, List<DvbClutEntry>> cluts = const <int, List<DvbClutEntry>>{},
  ({int width, int height})? display,
  bool includeEnd = true,
  bool tsWrapped = false,
}) {
  final BytesBuilder b = BytesBuilder();
  if (tsWrapped) b.add(<int>[0x20, 0x00]);
  if (display != null) {
    b.add(
      _segment(0x14, pageId, <int>[
        0x00,
        (display.width - 1) >> 8,
        (display.width - 1) & 0xFF,
        (display.height - 1) >> 8,
        (display.height - 1) & 0xFF,
      ]),
    );
  }
  b.add(
    _segment(0x10, pageId, <int>[
      timeoutSec,
      (version << 4) | (pageState << 2),
      for (final DvbRegionSpec r in regions) ...<int>[
        r.id,
        0,
        r.x >> 8,
        r.x & 0xFF,
        r.y >> 8,
        r.y & 0xFF,
      ],
    ]),
  );
  for (final DvbRegionSpec r in regions) {
    final int depthCode = switch (r.depthBits) {
      2 => 1,
      4 => 2,
      _ => 3,
    };
    b.add(
      _segment(0x11, pageId, <int>[
        r.id,
        (version << 4) | 0x08, // fill flag
        r.width >> 8,
        r.width & 0xFF,
        r.height >> 8,
        r.height & 0xFF,
        (depthCode << 5) | (depthCode << 2),
        r.clutId,
        r.depthBits == 8 ? r.background : 0,
        (r.depthBits == 4 ? r.background << 4 : 0) |
            (r.depthBits == 2 ? r.background << 2 : 0),
        for (final DvbObjectSpec o in r.objects) ...<int>[
          o.id >> 8,
          o.id & 0xFF,
          (o.x >> 8) & 0x0F,
          o.x & 0xFF,
          (o.y >> 8) & 0x0F,
          o.y & 0xFF,
        ],
      ]),
    );
  }
  for (final MapEntry<int, List<DvbClutEntry>> clut in cluts.entries) {
    b.add(
      _segment(0x12, pageId, <int>[
        clut.key,
        version << 4,
        for (final DvbClutEntry e in clut.value) ...<int>[
          e.$1,
          0xE1,
          e.$2,
          e.$3,
          e.$4,
          e.$5,
        ],
      ]),
    );
  }
  for (final DvbRegionSpec r in regions) {
    for (final DvbObjectSpec o in r.objects) {
      final Uint8List top = encodeDvbField(<List<int>>[
        for (int i = 0; i < o.pixels.length; i += 2) o.pixels[i],
      ], o.stringBits);
      final Uint8List bottom = o.repeatTopField
          ? Uint8List(0)
          : encodeDvbField(<List<int>>[
              for (int i = 1; i < o.pixels.length; i += 2) o.pixels[i],
            ], o.stringBits);
      b.add(
        _segment(0x13, pageId, <int>[
          o.id >> 8,
          o.id & 0xFF,
          version << 4,
          top.length >> 8,
          top.length & 0xFF,
          bottom.length >> 8,
          bottom.length & 0xFF,
          ...top,
          ...bottom,
        ]),
      );
    }
  }
  if (includeEnd) b.add(_segment(0x80, pageId, const <int>[]));
  if (tsWrapped) b.addByte(0xFF);
  return b.toBytes();
}

// ── 单轨 MPEG-TS（与 ffmpeg mpegts 封装器同形：PAT / PMT / 一条私有数据 PES 流）──

Uint8List _psiPacket(int pid, List<int> section, int cc) {
  final Uint8List p = Uint8List(188)..fillRange(0, 188, 0xFF);
  p[0] = 0x47;
  p[1] = 0x40 | (pid >> 8);
  p[2] = pid & 0xFF;
  p[3] = 0x10 | (cc & 0xF);
  p[4] = 0; // pointer_field
  p.setRange(5, 5 + section.length, section);
  return p;
}

List<int> _withCrc(List<int> section) => <int>[...section, 0, 0, 0, 0];

/// [payloads] 按 (pts90k, data) 打成 PES（stream_id 0xBD），切进 188 字节 TS 包。
Uint8List buildSubtitleTs(
  List<(int, Uint8List)> payloads, {
  int esPid = 0x100,
  int pmtPid = 0x1000,
  bool unsizedPes = false,
}) {
  final BytesBuilder out = BytesBuilder();
  final List<int> pat = _withCrc(<int>[
    0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, //
    0x00, 0x01, 0xE0 | (pmtPid >> 8), pmtPid & 0xFF,
  ]);
  final List<int> pmt = _withCrc(<int>[
    0x02, 0xB0, 18, 0x00, 0x01, 0xC1, 0x00, 0x00, //
    0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00,
    0x06, 0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00,
  ]);
  out
    ..add(_psiPacket(0, pat, 0))
    ..add(_psiPacket(pmtPid, pmt, 0));
  int cc = 0;
  for (final (int pts, Uint8List data) in payloads) {
    final List<int> header = <int>[
      0x80,
      0x80,
      5,
      0x21 | ((pts >> 29) & 0x0E),
      (pts >> 22) & 0xFF,
      0x01 | ((pts >> 14) & 0xFE),
      (pts >> 7) & 0xFF,
      0x01 | ((pts << 1) & 0xFE),
    ];
    final int length = unsizedPes ? 0 : header.length + data.length;
    final List<int> pes = <int>[
      0,
      0,
      1,
      0xBD,
      length >> 8,
      length & 0xFF,
      ...header,
      ...data,
    ];
    int o = 0;
    bool first = true;
    while (o < pes.length) {
      const int room = 184;
      final int n = pes.length - o < room ? pes.length - o : room;
      final Uint8List p = Uint8List(188);
      p[0] = 0x47;
      p[1] = (first ? 0x40 : 0) | (esPid >> 8);
      p[2] = esPid & 0xFF;
      if (n == room) {
        p[3] = 0x10 | (cc++ & 0xF);
        p.setRange(4, 188, pes.sublist(o, o + n));
      } else {
        // 用自适应域填充到 188 字节。
        final int stuffing = room - n; // 适配域总长（含长度字节）
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

// ── 最小 Matroska（真机 ffmpeg / ffprobe 样本用）─────────────────────────────

List<int> _ebmlId(int id) {
  final List<int> b = <int>[];
  int v = id;
  while (v > 0) {
    b.insert(0, v & 0xFF);
    v >>= 8;
  }
  return b;
}

List<int> _ebmlSize(int size) => <int>[
  0x01,
  for (int i = 6; i >= 0; i--) (size >> (8 * i)) & 0xFF,
];

List<int> _el(int id, List<int> body) => <int>[
  ..._ebmlId(id),
  ..._ebmlSize(body.length),
  ...body,
];

List<int> _uint(int id, int v) {
  final List<int> b = <int>[];
  int x = v;
  do {
    b.insert(0, x & 0xFF);
    x >>= 8;
  } while (x > 0);
  return _el(id, b);
}

List<int> _str(int id, String s) => _el(id, ascii.encode(s));

/// 单字幕轨 Matroska：[codecId] 如 `S_VOBSUB` / `S_DVBSUB` / `S_HDMV/PGS`，
/// [blocks] 为 (时间毫秒, 时长毫秒?, 数据)。
Uint8List buildSubtitleMatroska({
  required String codecId,
  Uint8List? codecPrivate,
  required List<(int, int?, Uint8List)> blocks,
}) {
  final List<int> header = _el(0x1A45DFA3, <int>[
    ..._uint(0x4286, 1),
    ..._uint(0x42F7, 1),
    ..._uint(0x42F2, 4),
    ..._uint(0x42F3, 8),
    ..._str(0x4282, 'matroska'),
    ..._uint(0x4287, 4),
    ..._uint(0x4285, 2),
  ]);
  final List<int> info = _el(0x1549A966, <int>[
    ..._uint(0x2AD7B1, 1000000),
    ..._str(0x4D80, 'fushi-test'),
    ..._str(0x5741, 'fushi-test'),
  ]);
  final List<int> tracks = _el(0x1654AE6B, <int>[
    ..._el(0xAE, <int>[
      ..._uint(0xD7, 1),
      ..._uint(0x73C5, 1),
      ..._uint(0x83, 0x11),
      ..._str(0x86, codecId),
      if (codecPrivate != null) ..._el(0x63A2, codecPrivate),
    ]),
  ]);
  final List<int> clusters = <int>[
    for (final (int ms, int? dur, Uint8List data) in blocks)
      ..._el(0x1F43B675, <int>[
        ..._uint(0xE7, ms),
        ..._el(0xA0, <int>[
          ..._el(0xA1, <int>[0x81, 0x00, 0x00, 0x00, ...data]),
          if (dur != null) ..._uint(0x9B, dur),
        ]),
      ]),
  ];
  final List<int> segment = _el(0x18538067, <int>[
    ...info,
    ...tracks,
    ...clusters,
  ]);
  return Uint8List.fromList(<int>[...header, ...segment]);
}
