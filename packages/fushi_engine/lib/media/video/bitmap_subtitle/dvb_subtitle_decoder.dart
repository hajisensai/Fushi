/// DVB 图形字幕（`dvb_subtitle`，ETSI EN 300 743）解码：一个包 = 一个显示集（display
/// set），由若干段（segment）组成，状态在 epoch 内跨显示集保留。
///
/// 段头：`0x0F` 同步字节 + 段类型 + `u16` page_id + `u16` 段长。认的段：
/// - `0x10` 页面合成（PCS）：page_time_out（秒）、page_state（`2` = mode change，epoch
///   开始，之前的区域 / 对象 / CLUT 全部作废）、本页显示哪些区域及其位置；
/// - `0x11` 区域合成（RCS）：区域尺寸、色深（2 / 4 / 8 bit）、CLUT、填充色、放哪些对象；
/// - `0x12` CLUT 定义：按 2 / 4 / 8 bit 三张表增量更新（YCrCb + T，Y = 0 即全透明）；
/// - `0x13` 对象数据（ODS）：顶场 / 底场两段像素串（2 / 4 / 8 bit 游程码 + 映射表 +
///   行尾码）；底场长度为 0 时重复顶场；
/// - `0x14` 显示定义（DDS）：画布尺寸（缺省 720×576）；
/// - `0x80` 显示集结束；`0xFF` 是 TS 封装时 PES 数据尾标记。
///
/// 一条 cue = 屏上区域内容不变的一段时间（只换 CLUT 的淡入淡出不拆，取最不透明的那张）。
/// 结束 = 下一个内容不同的显示集（含不放任何区域的清屏集），或 page_time_out 到期，
/// 二者取早；都没有就按 [kBitmapSubtitleOpenCueCapMs] 兜底。像素串只存原字节，渲染推迟
/// 到 [DvbSubtitleCue.renderRgba]。
///
/// codec extradata（Matroska `S_DVBSUB` 的 CodecPrivate / TS 的 subtitling descriptor）
/// 前 4 字节是 composition_page_id + ancillary_page_id：只认这两页的段，PCS 只认合成页。
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart'
    show kBitmapSubtitleOpenCueCapMs;
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';

/// DDS 缺省的画布尺寸（EN 300 743 §5.1.1：没有显示定义段即 720×576）。
const int kDvbDefaultDisplayWidth = 720;
const int kDvbDefaultDisplayHeight = 576;

/// 一条 DVB 图形字幕。
class DvbSubtitleCue implements BitmapSubtitleCue {
  DvbSubtitleCue._({
    required this.startMs,
    required this.endMs,
    required this.canvasWidth,
    required this.canvasHeight,
    required List<DvbRegionPlacement> regions,
  }) : _regions = regions;

  @override
  final int startMs;
  @override
  final int endMs;
  @override
  final int canvasWidth;
  @override
  final int canvasHeight;
  final List<DvbRegionPlacement> _regions;

  @override
  bool get forced => false;

  /// 区域内对象实际像素范围的并集（不是整块区域：区域常是整行宽的透明底）。
  @override
  BitmapSubtitleBounds get bounds =>
      bitmapSubtitleLayerBounds(<({int x, int y, int width, int height})>[
        for (final DvbRegionPlacement r in _regions) ...r.objectBoxes(),
      ]);

  img.Image _renderCanvas(int padding) => composeBitmapSubtitleImage(
    bounds: bounds,
    padding: padding,
    layers: <BitmapSubtitleLayer>[
      for (final DvbRegionPlacement r in _regions)
        BitmapSubtitleLayer(
          x: r.x,
          y: r.y,
          width: r.region.width,
          height: r.region.height,
          indices: r.region.render(),
          stride: r.region.width,
          palette: r.palette,
        ),
    ],
  );

  @override
  BitmapSubtitleImage renderRgba({int padding = 16}) =>
      bitmapSubtitleImageOf(_renderCanvas(padding));

  @override
  Uint8List renderPng({int padding = 16}) =>
      img.encodePng(_renderCanvas(padding));
}

/// 一个区域在页面上的一次摆放（内容快照 + 当时的 CLUT）。
class DvbRegionPlacement {
  DvbRegionPlacement({
    required this.x,
    required this.y,
    required this.region,
    required this.palette,
  });

  final int x;
  final int y;
  final DvbRegion region;

  /// 按区域色深选出的那张 CLUT（ARGB，4 / 16 / 256 项）。
  final Uint32List palette;

  /// 区域内各对象的实际像素框（页面坐标，夹在区域内）。
  Iterable<({int x, int y, int width, int height})> objectBoxes() sync* {
    for (final DvbObjectPlacement o in region.objects) {
      final ({int width, int height}) size = o.object.size;
      final int w = (region.width - o.x).clamp(0, size.width);
      final int h = (region.height - o.y).clamp(0, size.height);
      if (w <= 0 || h <= 0) continue;
      yield (x: x + o.x, y: y + o.y, width: w, height: h);
    }
  }

  bool sameContent(DvbRegionPlacement o) =>
      x == o.x && y == o.y && region.sameContent(o.region);
}

/// 区域内容快照：尺寸、色深、填充色、对象及位置。
class DvbRegion {
  DvbRegion({
    required this.width,
    required this.height,
    required this.depth,
    required this.clutId,
    required this.background,
    required this.objects,
  });

  final int width;
  final int height;

  /// 2 / 4 / 8。
  final int depth;
  final int clutId;
  final int background;
  final List<DvbObjectPlacement> objects;

  /// 合成区域的像素索引平面（填充色打底，再画各对象）。
  Uint8List render() {
    final Uint8List buffer = Uint8List(width * height);
    if (background != 0) buffer.fillRange(0, buffer.length, background);
    for (final DvbObjectPlacement o in objects) {
      o.object.drawInto(buffer, width, height, depth, o.x, o.y);
    }
    return buffer;
  }

  bool sameContent(DvbRegion o) =>
      width == o.width &&
      height == o.height &&
      depth == o.depth &&
      background == o.background &&
      objects.length == o.objects.length &&
      Iterable<int>.generate(objects.length).every(
        (int i) =>
            objects[i].x == o.objects[i].x &&
            objects[i].y == o.objects[i].y &&
            objects[i].object.sameAs(o.objects[i].object),
      );
}

class DvbObjectPlacement {
  const DvbObjectPlacement({
    required this.object,
    required this.x,
    required this.y,
  });

  final DvbObject object;
  final int x;
  final int y;
}

/// 对象像素数据（两场原字节；底场为 null = 重复顶场）。
class DvbObject {
  DvbObject({required this.top, required this.bottom});

  final Uint8List top;
  final Uint8List? bottom;
  ({int width, int height})? _size;

  bool sameAs(DvbObject o) =>
      identical(this, o) ||
      (const ListEquality<int>().equals(top, o.top) &&
          const ListEquality<int>().equals(bottom, o.bottom));

  /// 像素串实际覆盖的宽高（最长一行的像素数、行数）。只扫游程，不落像素。
  ({int width, int height}) get size => _size ??= _measure();

  ({int width, int height}) _measure() {
    int width = 0;
    int height = 0;
    for (int field = 0; field < 2; field++) {
      final Uint8List data = field == 0 ? top : (bottom ?? top);
      int lines = 0;
      walkDvbPixelData(data, 8, (int y, int x, int run, int code) {
        if (x + run > width) width = x + run;
      }, onLineEnd: (int line) => lines = line + 1);
      final int fieldHeight = lines == 0 ? 0 : (lines - 1) * 2 + 1 + field;
      if (fieldHeight > height) height = fieldHeight;
    }
    return (width: width, height: height);
  }

  /// 画进 [buffer]（区域平面，[regionWidth]×[regionHeight]，色深 [depth]）的 ([ox], [oy])。
  void drawInto(
    Uint8List buffer,
    int regionWidth,
    int regionHeight,
    int depth,
    int ox,
    int oy,
  ) {
    for (int field = 0; field < 2; field++) {
      final Uint8List data = field == 0 ? top : (bottom ?? top);
      walkDvbPixelData(data, depth, (int line, int x, int run, int code) {
        final int y = oy + line * 2 + field;
        if (y < 0 || y >= regionHeight || code == 0) return;
        final int start = (ox + x).clamp(0, regionWidth);
        final int end = (ox + x + run).clamp(0, regionWidth);
        if (end > start) {
          buffer.fillRange(
            y * regionWidth + start,
            y * regionWidth + end,
            code,
          );
        }
      });
    }
  }
}

/// 默认映射表（EN 300 743 §10.4–10.6）。
const List<int> _kMap2to4 = <int>[0x0, 0x7, 0x8, 0xF];
const List<int> _kMap2to8 = <int>[0x00, 0x77, 0x88, 0xFF];
final List<int> _kMap4to8 = <int>[for (int i = 0; i < 16; i++) i * 0x11];

/// 遍历一场像素数据：每个游程回调 (场内行号, 行内起点, 长度, 映射到 [depth] 后的码)；
/// 当前色深放不下的像素串（4 bit 串进 2 bit 区域等，规范不允许）只推进位置、码给 0。
void walkDvbPixelData(
  Uint8List data,
  int depth,
  void Function(int line, int x, int run, int code) onRun, {
  void Function(int line)? onLineEnd,
}) {
  List<int> map2to4 = _kMap2to4;
  List<int> map2to8 = _kMap2to8;
  List<int> map4to8 = _kMap4to8;
  int line = 0;
  int x = 0;
  int o = 0;
  bool sawPixels = false;
  while (o < data.length) {
    final int type = data[o++];
    switch (type) {
      case 0x10:
      case 0x11:
      case 0x12:
        final _BitReader r = _BitReader(data, o);
        final int bits = type == 0x10 ? 2 : (type == 0x11 ? 4 : 8);
        final List<int>? map = switch ((bits, depth)) {
          (2, 4) => map2to4,
          (2, 8) => map2to8,
          (4, 8) => map4to8,
          _ => null,
        };
        final bool fits = bits <= depth;
        void emit(int run, int code) {
          if (run <= 0) return;
          final int mapped = !fits ? 0 : (map == null ? code : map[code]);
          onRun(line, x, run, mapped);
          x += run;
        }

        switch (bits) {
          case 2:
            _read2bit(r, emit);
          case 4:
            _read4bit(r, emit);
          default:
            _read8bit(r, emit);
        }
        sawPixels = true;
        o = r.bytePosAligned;
      case 0x20:
        if (o + 2 > data.length) return;
        map2to4 = <int>[
          data[o] >> 4,
          data[o] & 0x0F,
          data[o + 1] >> 4,
          data[o + 1] & 0x0F,
        ];
        o += 2;
      case 0x21:
        if (o + 4 > data.length) return;
        map2to8 = <int>[data[o], data[o + 1], data[o + 2], data[o + 3]];
        o += 4;
      case 0x22:
        if (o + 16 > data.length) return;
        map4to8 = <int>[for (int i = 0; i < 16; i++) data[o + i]];
        o += 16;
      case 0xF0:
        onLineEnd?.call(line);
        line++;
        x = 0;
        sawPixels = false;
      default:
        // 未知数据类型：长度不可知，后面的字节不可信。
        if (sawPixels) onLineEnd?.call(line);
        return;
    }
  }
  if (sawPixels) onLineEnd?.call(line);
}

void _read2bit(_BitReader r, void Function(int run, int code) emit) {
  while (!r.exhausted) {
    final int code = r.read(2);
    if (code != 0) {
      emit(1, code);
      continue;
    }
    if (r.read(1) == 1) {
      final int run = r.read(3) + 3;
      emit(run, r.read(2));
      continue;
    }
    if (r.read(1) == 1) {
      emit(1, 0);
      continue;
    }
    switch (r.read(2)) {
      case 0:
        return; // end of string
      case 1:
        emit(2, 0);
      case 2:
        final int run = r.read(4) + 12;
        emit(run, r.read(2));
      case 3:
        final int run = r.read(8) + 29;
        emit(run, r.read(2));
    }
  }
}

void _read4bit(_BitReader r, void Function(int run, int code) emit) {
  while (!r.exhausted) {
    final int code = r.read(4);
    if (code != 0) {
      emit(1, code);
      continue;
    }
    if (r.read(1) == 0) {
      final int run = r.read(3);
      if (run == 0) return; // end of string
      emit(run + 2, 0);
      continue;
    }
    if (r.read(1) == 0) {
      final int run = r.read(2) + 4;
      emit(run, r.read(4));
      continue;
    }
    switch (r.read(2)) {
      case 0:
        emit(1, 0);
      case 1:
        emit(2, 0);
      case 2:
        final int run = r.read(4) + 9;
        emit(run, r.read(4));
      case 3:
        final int run = r.read(8) + 25;
        emit(run, r.read(4));
    }
  }
}

void _read8bit(_BitReader r, void Function(int run, int code) emit) {
  while (!r.exhausted) {
    final int code = r.read(8);
    if (code != 0) {
      emit(1, code);
      continue;
    }
    if (r.read(1) == 0) {
      final int run = r.read(7);
      if (run == 0) return; // end of string
      emit(run, 0);
      continue;
    }
    final int run = r.read(7);
    emit(run, r.read(8));
  }
}

class _BitReader {
  _BitReader(this._data, int byteOffset) : _bit = byteOffset * 8;

  final Uint8List _data;
  int _bit;

  bool get exhausted => (_bit >> 3) >= _data.length;

  /// 串结束后按字节对齐的下一个字节位置。
  int get bytePosAligned => (_bit + 7) >> 3;

  int read(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      final int byte = _bit >> 3;
      final int bit = byte < _data.length
          ? (_data[byte] >> (7 - (_bit & 7))) & 1
          : 0;
      v = (v << 1) | bit;
      _bit++;
    }
    return v;
  }
}

/// DVB extradata 里的页号（前 4 字节）。不足 4 字节为 null（不按页过滤）。
({int composition, int ancillary})? dvbSubtitlePagesOf(Uint8List? extradata) {
  if (extradata == null || extradata.length < 4) return null;
  return (
    composition: (extradata[0] << 8) | extradata[1],
    ancillary: (extradata[2] << 8) | extradata[3],
  );
}

/// 把一整轨 DVB 字幕包解成 cue（包顺序即显示集顺序；坏段跳过）。
List<DvbSubtitleCue> decodeDvbSubtitlePackets(
  List<BitmapSubtitlePacket> packets, {
  Uint8List? extradata,
}) {
  final _DvbState state = _DvbState(dvbSubtitlePagesOf(extradata));
  final List<_DvbEvent> events = <_DvbEvent>[];
  for (final BitmapSubtitlePacket packet in packets) {
    final _DvbEvent? e = state.applyPacket(packet);
    if (e != null) events.add(e);
  }
  return _groupDvbCues(events);
}

/// 一个显示集收束时屏上的状态快照。
class _DvbEvent {
  _DvbEvent({
    required this.ptsMs,
    required this.timeoutMs,
    required this.width,
    required this.height,
    required this.regions,
  });

  final int ptsMs;

  /// page_time_out（毫秒）；0 = 码流没给。
  final int timeoutMs;
  final int width;
  final int height;
  final List<DvbRegionPlacement> regions;

  bool sameContent(_DvbEvent o) =>
      regions.length == o.regions.length &&
      Iterable<int>.generate(
        regions.length,
      ).every((int i) => regions[i].sameContent(o.regions[i]));

  int get opacity {
    int max = 0;
    for (final DvbRegionPlacement r in regions) {
      for (final int argb in r.palette) {
        final int a = argb >>> 24;
        if (a > max) max = a;
      }
    }
    return max;
  }
}

List<DvbSubtitleCue> _groupDvbCues(List<_DvbEvent> events) {
  final List<DvbSubtitleCue> cues = <DvbSubtitleCue>[];
  _DvbEvent? first;
  _DvbEvent? best;
  int? deadline;
  void close(int? nextPts) {
    final _DvbEvent? start = first;
    final _DvbEvent? shown = best;
    if (start == null || shown == null) return;
    int end =
        nextPts ?? (deadline ?? start.ptsMs + kBitmapSubtitleOpenCueCapMs);
    if (deadline != null && deadline < end) end = deadline;
    cues.add(
      DvbSubtitleCue._(
        startMs: start.ptsMs,
        endMs: end > start.ptsMs ? end : start.ptsMs + 1,
        canvasWidth: start.width,
        canvasHeight: start.height,
        regions: shown.regions,
      ),
    );
  }

  for (final _DvbEvent e in events) {
    final _DvbEvent? open = first;
    if (open != null &&
        e.sameContent(open) &&
        (deadline == null || e.ptsMs < deadline)) {
      // 同内容重发（acquisition point / 只换 CLUT 的淡入淡出）：并进当前 cue，
      // 超时从这一集重新起算。
      if (e.opacity > best!.opacity) best = e;
      if (e.timeoutMs > 0) deadline = e.ptsMs + e.timeoutMs;
      continue;
    }
    close(e.ptsMs);
    final bool visible = e.regions.any(
      (DvbRegionPlacement r) => r.objectBoxes().isNotEmpty,
    );
    first = visible ? e : null;
    best = visible ? e : null;
    deadline = visible && e.timeoutMs > 0 ? e.ptsMs + e.timeoutMs : null;
  }
  close(null);
  return cues;
}

class _DvbClut {
  _DvbClut()
    : clut4 = Uint32List.fromList(_kDefaultClut4),
      clut16 = Uint32List.fromList(_kDefaultClut16),
      clut256 = Uint32List.fromList(_kDefaultClut256);

  final Uint32List clut4;
  final Uint32List clut16;
  final Uint32List clut256;

  Uint32List forDepth(int depth) => switch (depth) {
    2 => clut4,
    4 => clut16,
    _ => clut256,
  };
}

int _argb(int r, int g, int b, int a) => (a << 24) | (r << 16) | (g << 8) | b;

/// 缺省 CLUT（EN 300 743 §10，与 ffmpeg dvbsubdec 同表）。
final List<int> _kDefaultClut4 = <int>[
  _argb(0, 0, 0, 0),
  _argb(255, 255, 255, 255),
  _argb(0, 0, 0, 255),
  _argb(127, 127, 127, 255),
];

final List<int> _kDefaultClut16 = <int>[
  _argb(0, 0, 0, 0),
  for (int i = 1; i < 16; i++)
    _argb(
      (i & 1) != 0 ? (i < 8 ? 255 : 127) : 0,
      (i & 2) != 0 ? (i < 8 ? 255 : 127) : 0,
      (i & 4) != 0 ? (i < 8 ? 255 : 127) : 0,
      255,
    ),
];

final List<int> _kDefaultClut256 = <int>[
  _argb(0, 0, 0, 0),
  for (int i = 1; i < 256; i++) _defaultClut256Entry(i),
];

int _defaultClut256Entry(int i) {
  if (i < 8) {
    return _argb(
      (i & 1) != 0 ? 255 : 0,
      (i & 2) != 0 ? 255 : 0,
      (i & 4) != 0 ? 255 : 0,
      63,
    );
  }
  int c(int lo, int hi, int base, int loV, int hiV) =>
      base + ((i & lo) != 0 ? loV : 0) + ((i & hi) != 0 ? hiV : 0);
  switch (i & 0x88) {
    case 0x00:
      return _argb(
        c(1, 0x10, 0, 85, 170),
        c(2, 0x20, 0, 85, 170),
        c(4, 0x40, 0, 85, 170),
        255,
      );
    case 0x08:
      return _argb(
        c(1, 0x10, 0, 85, 170),
        c(2, 0x20, 0, 85, 170),
        c(4, 0x40, 0, 85, 170),
        127,
      );
    case 0x80:
      return _argb(
        c(1, 0x10, 127, 43, 85),
        c(2, 0x20, 127, 43, 85),
        c(4, 0x40, 127, 43, 85),
        255,
      );
    default:
      return _argb(
        c(1, 0x10, 0, 43, 85),
        c(2, 0x20, 0, 43, 85),
        c(4, 0x40, 0, 43, 85),
        255,
      );
  }
}

class _DvbRegionDef {
  _DvbRegionDef({
    required this.width,
    required this.height,
    required this.depth,
    required this.clutId,
    required this.background,
    required this.objects,
  });

  final int width;
  final int height;
  final int depth;
  final int clutId;
  final int background;

  /// (object_id, x, y)。
  final List<({int id, int x, int y})> objects;
}

/// 段流状态机。
class _DvbState {
  _DvbState(this._pages);

  final ({int composition, int ancillary})? _pages;
  int? _compositionPage;
  final Map<int, _DvbClut> _cluts = <int, _DvbClut>{};
  final Map<int, _DvbRegionDef> _regions = <int, _DvbRegionDef>{};
  final Map<int, DvbObject> _objects = <int, DvbObject>{};
  int _displayWidth = kDvbDefaultDisplayWidth;
  int _displayHeight = kDvbDefaultDisplayHeight;
  List<({int id, int x, int y})>? _page;
  int _timeoutMs = 0;

  _DvbEvent? applyPacket(BitmapSubtitlePacket packet) {
    final Uint8List b = packet.data;
    int o = 0;
    // TS 封装多出来的 data_identifier (0x20) + subtitle_stream_id (0x00)。可能叠了不止
    // 一层：源本身是 TS 时 demux 出的包已带这层（精简 ffmpeg 没有 dvbsub parser 去剥），
    // 抽轨再封 TS 又包一层（实测 149 → 152 字节：`20 00 20 00 0F … FF FF`）。
    while (o + 2 < b.length && b[o] == 0x20 && b[o + 1] == 0x00) {
      o += 2;
    }
    bool sawPage = false;
    _DvbEvent? event;
    while (o + 6 <= b.length && b[o] == 0x0F) {
      final int type = b[o + 1];
      final int pageId = (b[o + 2] << 8) | b[o + 3];
      final int length = (b[o + 4] << 8) | b[o + 5];
      final int start = o + 6;
      if (start + length > b.length) break; // 截断。
      final Uint8List body = Uint8List.sublistView(b, start, start + length);
      o = start + length;
      if (!_acceptsPage(pageId)) continue;
      switch (type) {
        case 0x10:
          if (_isCompositionPage(pageId)) {
            _readPcs(body);
            sawPage = true;
          }
        case 0x11:
          _readRcs(body);
        case 0x12:
          _readClut(body);
        case 0x13:
          _readOds(body);
        case 0x14:
          _readDds(body);
        case 0x80:
          if (sawPage) event = _snapshot(packet.ptsMs);
          sawPage = false;
      }
    }
    // 没有显示集结束段（部分封装把它省了）：包边界即显示集边界。
    if (sawPage) event = _snapshot(packet.ptsMs);
    return event;
  }

  bool _acceptsPage(int pageId) {
    final ({int composition, int ancillary})? pages = _pages;
    if (pages == null) return true;
    return pageId == pages.composition || pageId == pages.ancillary;
  }

  bool _isCompositionPage(int pageId) {
    final ({int composition, int ancillary})? pages = _pages;
    if (pages != null) return pageId == pages.composition;
    return pageId == (_compositionPage ??= pageId);
  }

  void _readPcs(Uint8List b) {
    if (b.length < 2) return;
    _timeoutMs = b[0] * 1000;
    final int state = (b[1] >> 2) & 0x3;
    if (state == 2) {
      // mode change：新 epoch。
      _cluts.clear();
      _regions.clear();
      _objects.clear();
    }
    final List<({int id, int x, int y})> page = <({int id, int x, int y})>[];
    for (int o = 2; o + 6 <= b.length; o += 6) {
      page.add((
        id: b[o],
        x: (b[o + 2] << 8) | b[o + 3],
        y: (b[o + 4] << 8) | b[o + 5],
      ));
    }
    _page = page;
  }

  void _readRcs(Uint8List b) {
    if (b.length < 10) return;
    final int id = b[0];
    final int width = (b[2] << 8) | b[3];
    final int height = (b[4] << 8) | b[5];
    if (!isDecodableBitmapSubtitleSize(width, height)) {
      // 损坏的区域定义：丢掉，页面引用它时 [_snapshot] 跳过。
      _regions.remove(id);
      return;
    }
    final int depthCode = (b[6] >> 2) & 0x7;
    final int depth = switch (depthCode) {
      1 => 2,
      2 => 4,
      _ => 8,
    };
    final int clutId = b[7];
    final int background = switch (depth) {
      2 => (b[9] >> 2) & 0x3,
      4 => b[9] >> 4,
      _ => b[8],
    };
    final bool fill = (b[1] >> 3) & 1 == 1;
    final List<({int id, int x, int y})> objects = <({int id, int x, int y})>[];
    int o = 10;
    while (o + 6 <= b.length) {
      final int objectId = (b[o] << 8) | b[o + 1];
      final int type = b[o + 2] >> 6;
      final int x = ((b[o + 2] & 0x0F) << 8) | b[o + 3];
      final int y = ((b[o + 4] & 0x0F) << 8) | b[o + 5];
      o += 6;
      if (type == 1 || type == 2) o += 2; // 字符对象的前景 / 背景码。
      objects.add((id: objectId, x: x, y: y));
    }
    final _DvbRegionDef? old = _regions[id];
    _regions[id] = _DvbRegionDef(
      width: width,
      height: height,
      depth: depth,
      clutId: clutId,
      // 不填充时沿用区域原有底色（新区域按规范以填充色起底）。
      background: fill || old == null ? background : old.background,
      objects: objects,
    );
  }

  void _readClut(Uint8List b) {
    if (b.length < 2) return;
    final _DvbClut clut = _cluts.putIfAbsent(b[0], _DvbClut.new);
    int o = 2;
    while (o + 2 <= b.length) {
      final int entry = b[o];
      final int flags = b[o + 1];
      final bool full = flags & 1 == 1;
      int y, cr, cb, t;
      if (full) {
        if (o + 6 > b.length) return;
        y = b[o + 2];
        cr = b[o + 3];
        cb = b[o + 4];
        t = b[o + 5];
        o += 6;
      } else {
        if (o + 4 > b.length) return;
        final int v0 = b[o + 2];
        final int v1 = b[o + 3];
        y = v0 & 0xFC;
        cr = (((v0 & 0x3) << 2) | (v1 >> 6)) << 4;
        cb = (v1 << 2) & 0xF0;
        t = (v1 << 6) & 0xC0;
        o += 4;
      }
      final int alpha = y == 0 ? 0 : 255 - t;
      final int argb = bt601YCbCrToArgb(y, cr, cb, alpha);
      if (flags & 0x80 != 0 && entry < 4) clut.clut4[entry] = argb;
      if (flags & 0x40 != 0 && entry < 16) clut.clut16[entry] = argb;
      if (flags & 0x20 != 0) clut.clut256[entry] = argb;
    }
  }

  void _readOds(Uint8List b) {
    if (b.length < 3) return;
    final int id = (b[0] << 8) | b[1];
    final int coding = (b[2] >> 2) & 0x3;
    if (coding != 0) return; // 字符串编码对象：没有位图。
    if (b.length < 7) return;
    final int topLength = (b[3] << 8) | b[4];
    final int bottomLength = (b[5] << 8) | b[6];
    if (7 + topLength + bottomLength > b.length) return;
    final Uint8List top = Uint8List.fromList(
      Uint8List.sublistView(b, 7, 7 + topLength),
    );
    final Uint8List? bottom = bottomLength == 0
        ? null
        : Uint8List.fromList(
            Uint8List.sublistView(
              b,
              7 + topLength,
              7 + topLength + bottomLength,
            ),
          );
    _objects[id] = DvbObject(top: top, bottom: bottom);
  }

  void _readDds(Uint8List b) {
    if (b.length < 5) return;
    _displayWidth = ((b[1] << 8) | b[2]) + 1;
    _displayHeight = ((b[3] << 8) | b[4]) + 1;
  }

  _DvbEvent _snapshot(int ptsMs) {
    final List<DvbRegionPlacement> placements = <DvbRegionPlacement>[];
    for (final ({int id, int x, int y}) p
        in _page ?? const <({int id, int x, int y})>[]) {
      final _DvbRegionDef? def = _regions[p.id];
      if (def == null) continue;
      final List<DvbObjectPlacement> objects = <DvbObjectPlacement>[
        for (final ({int id, int x, int y}) ref in def.objects)
          if (_objects[ref.id] case final DvbObject object)
            DvbObjectPlacement(object: object, x: ref.x, y: ref.y),
      ];
      final _DvbClut clut = _cluts[def.clutId] ?? _DvbClut();
      placements.add(
        DvbRegionPlacement(
          x: p.x,
          y: p.y,
          region: DvbRegion(
            width: def.width,
            height: def.height,
            depth: def.depth,
            clutId: def.clutId,
            background: def.background,
            objects: objects,
          ),
          palette: Uint32List.fromList(clut.forDepth(def.depth)),
        ),
      );
    }
    return _DvbEvent(
      ptsMs: ptsMs,
      timeoutMs: _timeoutMs,
      width: _displayWidth,
      height: _displayHeight,
      regions: placements,
    );
  }
}
