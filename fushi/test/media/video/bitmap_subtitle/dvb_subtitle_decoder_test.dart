// DVB 图形字幕（EN 300 743）解码：页面 / 区域 / CLUT / 对象 / 显示定义段，2 / 4 / 8 bit
// 像素串与默认映射表，page_time_out 与清屏集给结束时间，同内容重发并成一条。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvb_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart'
    show kBitmapSubtitleOpenCueCapMs;
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';

import 'bitmap_subtitle_fixtures.dart';

/// [w]×[h]：外圈 0，内部 [c]；最后一列整列 [edge]（检验行内游程衔接）。
List<List<int>> _glyph(int w, int h, int c, {int edge = 0}) => <List<int>>[
  for (int y = 0; y < h; y++)
    <int>[
      for (int x = 0; x < w; x++)
        x == w - 1 ? edge : (x > 0 && y > 0 && y < h - 1 ? c : 0),
    ],
];

BitmapSubtitlePacket _packet(int ms, Uint8List data) =>
    BitmapSubtitlePacket(pts90k: ms * 90, data: data);

/// 白（Y=235）、半透明灰。
const List<DvbClutEntry> _clut = <DvbClutEntry>[
  (1, 235, 128, 128, 0),
  (2, 126, 128, 128, 0x80),
];

Uint8List _show({
  int timeoutSec = 0,
  int pageState = 2,
  int pageId = 1,
  List<List<int>>? pixels,
  int stringBits = 4,
  int depthBits = 4,
  bool repeatTopField = false,
  bool tsWrapped = false,
  ({int width, int height})? display = (width: 1920, height: 1080),
  List<DvbClutEntry> clut = _clut,
}) => buildDvbDisplaySet(
  pageId: pageId,
  timeoutSec: timeoutSec,
  pageState: pageState,
  display: display,
  tsWrapped: tsWrapped,
  regions: <DvbRegionSpec>[
    DvbRegionSpec(
      id: 0,
      x: 300,
      y: 900,
      width: 800,
      height: 60,
      depthBits: depthBits,
      objects: <DvbObjectSpec>[
        DvbObjectSpec(
          id: 7,
          x: 40,
          y: 10,
          pixels: pixels ?? _glyph(30, 12, 1, edge: 2),
          stringBits: stringBits,
          repeatTopField: repeatTopField,
        ),
      ],
    ),
  ],
  cluts: <int, List<DvbClutEntry>>{0: clut},
);

Uint8List _clear({int pageId = 1}) =>
    buildDvbDisplaySet(pageId: pageId, pageState: 0, version: 1);

void main() {
  test('显示集 → cue：时间、DDS 画布、对象实际像素框（不是整块区域）', () {
    final List<DvbSubtitleCue> cues = decodeDvbSubtitlePackets(
      <BitmapSubtitlePacket>[_packet(2000, _show()), _packet(4500, _clear())],
    );
    expect(cues, hasLength(1));
    final DvbSubtitleCue cue = cues.single;
    expect((cue.startMs, cue.endMs), (2000, 4500));
    expect((cue.canvasWidth, cue.canvasHeight), (1920, 1080));
    // 区域 (300, 900) + 对象 (40, 10)，对象 30×12。
    expect(cue.bounds, (left: 340, top: 910, right: 370, bottom: 922));
  });

  test('渲染：CLUT 的 YCrCb 换成 RGB、外圈透明成黑底、半透明项按最大不透明度归一', () {
    final DvbSubtitleCue cue = decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
      _packet(0, _show()),
    ]).single;
    final BitmapSubtitleImage image = cue.renderRgba(padding: 0);
    expect((image.width, image.height), (30, 12));
    int at(int x, int y) => image.rgba[(y * image.width + x) * 4];
    expect(at(0, 0), 0);
    expect(at(5, 5), greaterThan(250), reason: 'Y=235 → 白');
    // 最后一列是半透明灰（T=0x80 → alpha 0x7F），按 0x7F/0xFF 压暗。
    expect(at(29, 5), inInclusiveRange(55, 70));
  });

  test('page_time_out 先到就按它结束；没有后续也没有超时就按兜底时长', () {
    expect(
      decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
        _packet(1000, _show(timeoutSec: 3)),
        _packet(9000, _clear()),
      ]).map((DvbSubtitleCue c) => (c.startMs, c.endMs)),
      <(int, int)>[(1000, 4000)],
    );
    expect(
      decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
        _packet(1000, _show()),
      ]).single.endMs,
      1000 + kBitmapSubtitleOpenCueCapMs,
    );
  });

  test('同内容重发（acquisition point）并进一条，超时从最后一次重发起算', () {
    final List<DvbSubtitleCue> cues =
        decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
          _packet(1000, _show(timeoutSec: 2)),
          _packet(2500, _show(timeoutSec: 2, pageState: 1)),
          _packet(10000, _clear()),
        ]);
    expect(cues.map((DvbSubtitleCue c) => (c.startMs, c.endMs)), <(int, int)>[
      (1000, 4500),
    ]);
  });

  test('内容变了拆成两条，前一条在后一条开始处结束', () {
    final List<DvbSubtitleCue> cues =
        decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
          _packet(1000, _show()),
          _packet(3000, _show(pixels: _glyph(20, 12, 1))),
          _packet(5000, _clear()),
        ]);
    expect(cues.map((DvbSubtitleCue c) => (c.startMs, c.endMs)), <(int, int)>[
      (1000, 3000),
      (3000, 5000),
    ]);
    expect(cues[1].bounds.right - cues[1].bounds.left, 20);
  });

  test('2 bit 串进 4 bit 区域走默认映射表（1 → 7 = 默认 CLUT 白）', () {
    final DvbSubtitleCue cue = decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
      _packet(0, _show(stringBits: 2, clut: const <DvbClutEntry>[])),
    ]).single;
    final BitmapSubtitleImage image = cue.renderRgba(padding: 0);
    int at(int x, int y) => image.rgba[(y * image.width + x) * 4];
    expect(at(5, 5), 255);
    expect(image.rgba[(5 * image.width + 5) * 4 + 2], 255);
  });

  test('8 bit 串 + 8 bit 区域；底场长度 0 时重复顶场', () {
    final List<List<int>> pixels = <List<int>>[
      for (int y = 0; y < 6; y++)
        <int>[for (int x = 0; x < 200; x++) x >= 5 && x < 180 ? 1 : 0],
    ];
    final DvbSubtitleCue cue = decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
      _packet(
        0,
        _show(
          stringBits: 8,
          depthBits: 8,
          pixels: pixels,
          repeatTopField: true,
        ),
      ),
    ]).single;
    // 对象 200 宽（像素串覆盖整行）；顶场 3 行（0/2/4），底场重复 → 共 6 行。
    expect(cue.bounds, (left: 340, top: 910, right: 540, bottom: 916));
    final BitmapSubtitleImage image = cue.renderRgba(padding: 0);
    int at(int x, int y) => image.rgba[(y * image.width + x) * 4];
    expect(at(10, 1), greaterThan(250), reason: '奇数行来自重复的顶场');
    expect(at(0, 1), 0);
  });

  test('TS 封装的 0x20 0x00 … 0xFF 包装；没有 DDS 时画布 720×576', () {
    final DvbSubtitleCue cue = decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
      _packet(0, _show(tsWrapped: true, display: null)),
    ]).single;
    expect((cue.canvasWidth, cue.canvasHeight), (720, 576));
    expect(cue.bounds.left, 340);
  });

  test('包装叠了两层（TS 源再封 TS）也照样剥掉', () {
    final Uint8List once = _show(tsWrapped: true);
    final Uint8List twice = Uint8List.fromList(<int>[
      0x20,
      0x00,
      ...once,
      0xFF,
    ]);
    expect(
      decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
        _packet(0, twice),
      ]).single.bounds.left,
      340,
    );
  });

  test('extradata 给了页号：只认合成页 / 辅助页，别的页忽略', () {
    final List<DvbSubtitleCue> cues =
        decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
          _packet(1000, _show(pageId: 2)),
          _packet(2000, _show(pageId: 1, pixels: _glyph(10, 12, 1))),
          _packet(3000, _clear()),
        ], extradata: Uint8List.fromList(<int>[0, 1, 0, 1, 0]));
    expect(cues.map((DvbSubtitleCue c) => (c.startMs, c.endMs)), <(int, int)>[
      (2000, 3000),
    ]);
    expect(dvbSubtitlePagesOf(Uint8List.fromList(<int>[0, 1])), isNull);
  });

  test('截断的段被丢弃，不抛', () {
    final Uint8List full = _show();
    expect(
      decodeDvbSubtitlePackets(<BitmapSubtitlePacket>[
        _packet(0, Uint8List.sublistView(full, 0, 12)),
      ]),
      isEmpty,
    );
  });
}
