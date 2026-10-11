/// DVD 图形字幕（VobSub / `dvd_subtitle`，SPU）解码：一个包 = 一张 2 bit 隔行 RLE 位图
/// + 一串带延时的控制序列。
///
/// 包结构（DVD-Video SPU）：
/// - `u16` 包总长、`u16` 控制序列表（SP_DCSQT）偏移；
/// - 像素数据：顶场（偶数行）与底场（奇数行）各一段 2 bit RLE，每行字节对齐；
/// - 控制序列：`u16` 延时（单位 1024/90000 秒）、`u16` 下一序列偏移（指向自己 = 最后
///   一个），后接命令：`00` FSTA_DSP（强制显示）/ `01` STA_DSP / `02` STP_DSP /
///   `03` SET_COLOR（4 个 4 bit 调色板下标）/ `04` SET_CONTR（4 个 4 bit 不透明度）/
///   `05` SET_DAREA（12 bit 坐标 x1 x2 y1 y2，含端点）/ `06` SET_DSPXA（两场像素偏移）/
///   `07` CHG_COLCON（带长度，跳过）/ `FF` 结束。
///
/// 16 色调色板与画布尺寸不在包里，在 codec extradata（VobSub `.idx` 头的 `size:` /
/// `palette:` 行，Matroska `S_VOBSUB` 的 CodecPrivate 原样就是它）。没有调色板时按
/// ffmpeg 的做法按不透明度猜灰阶。
///
/// 时间：开始 = 包 PTS + STA_DSP 所在序列的延时；结束 = 包 PTS + STP_DSP 所在序列的
/// 延时。没有 STP_DSP 的包显示到下一个包（只含 STP_DSP 的「清屏包」也算），最后一条再
/// 没有就按 [kBitmapSubtitleOpenCueCapMs] 兜底。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';

/// 没有任何结束信号的尾 cue 的兜底时长（与 PGS 解析器同值）。
const int kBitmapSubtitleOpenCueCapMs = 5000;

/// VobSub extradata（`.idx` 头）里解码要用的部分。
class VobSubHeader {
  const VobSubHeader({this.width = 0, this.height = 0, this.palette});

  /// `size: WxH`；没写为 0。
  final int width;
  final int height;

  /// `palette:` 的 16 个 0xRRGGBB；没写为 null。
  final Uint32List? palette;

  /// 解析 extradata 文本（宽容：未知行忽略，坏值当没写）。
  static VobSubHeader parse(Uint8List? extradata) {
    if (extradata == null || extradata.isEmpty) return const VobSubHeader();
    final String text = latin1.decode(extradata, allowInvalid: true);
    int width = 0;
    int height = 0;
    Uint32List? palette;
    for (final String raw in const LineSplitter().convert(text)) {
      final String line = raw.trim();
      final int colon = line.indexOf(':');
      if (colon < 0) continue;
      final String key = line.substring(0, colon).trim().toLowerCase();
      final String value = line.substring(colon + 1).trim();
      if (key == 'size') {
        final RegExpMatch? m = RegExp(r'^(\d+)\s*x\s*(\d+)').firstMatch(value);
        if (m != null) {
          width = int.parse(m.group(1)!);
          height = int.parse(m.group(2)!);
        }
      } else if (key == 'palette') {
        final List<int> colors = <int>[
          for (final String part in value.split(','))
            if (int.tryParse(part.trim(), radix: 16) case final int c) c,
        ];
        if (colors.length >= 16) {
          palette = Uint32List.fromList(
            colors.take(16).map((int c) => c & 0xFFFFFF).toList(),
          );
        }
      }
    }
    return VobSubHeader(width: width, height: height, palette: palette);
  }
}

/// 一条 DVD 图形字幕。
class DvdSubtitleCue implements BitmapSubtitleCue {
  DvdSubtitleCue._({
    required this.startMs,
    required this.endMs,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.forced,
    required this.area,
    required Uint8List packet,
    required int topFieldOffset,
    required int bottomFieldOffset,
    required Uint32List palette,
  }) : _packet = packet,
       _topFieldOffset = topFieldOffset,
       _bottomFieldOffset = bottomFieldOffset,
       _palette = palette;

  @override
  final int startMs;
  @override
  final int endMs;
  @override
  final int canvasWidth;
  @override
  final int canvasHeight;
  @override
  final bool forced;

  /// SET_DAREA 给的显示区（右 / 下为开区间）。
  final BitmapSubtitleBounds area;
  final Uint8List _packet;
  final int _topFieldOffset;
  final int _bottomFieldOffset;

  /// 4 项 ARGB（SET_COLOR 选出的颜色 + SET_CONTR 的不透明度）。
  final Uint32List _palette;

  int get _width => area.right - area.left;
  int get _height => area.bottom - area.top;

  @override
  BitmapSubtitleBounds get bounds => area;

  /// 解出的 2 bit 索引平面（[_width]×[_height]）。
  Uint8List decodeIndices() => decodeDvdSubtitleRle(
    _packet,
    width: _width,
    height: _height,
    topFieldOffset: _topFieldOffset,
    bottomFieldOffset: _bottomFieldOffset,
  );

  img.Image _renderCanvas(int padding) => composeBitmapSubtitleImage(
    bounds: area,
    padding: padding,
    layers: <BitmapSubtitleLayer>[
      BitmapSubtitleLayer(
        x: area.left,
        y: area.top,
        width: _width,
        height: _height,
        indices: decodeIndices(),
        stride: _width,
        palette: _palette,
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

/// 把一整轨 SPU 包解成 cue（按包顺序；坏包跳过）。
///
/// [header] 来自 codec extradata；它没写画布尺寸时用 [fallbackWidth] / [fallbackHeight]
/// （探测出的流宽高，仍没有就是 0）。
List<DvdSubtitleCue> decodeDvdSubtitlePackets(
  List<BitmapSubtitlePacket> packets, {
  VobSubHeader header = const VobSubHeader(),
  int fallbackWidth = 0,
  int fallbackHeight = 0,
}) {
  final int canvasW = header.width > 0 ? header.width : fallbackWidth;
  final int canvasH = header.height > 0 ? header.height : fallbackHeight;
  final List<_SpuDisplay> displays = <_SpuDisplay>[];
  for (final BitmapSubtitlePacket packet in packets) {
    final _SpuDisplay? d = _parseSpu(packet, header.palette);
    if (d != null) displays.add(d);
  }
  final List<DvdSubtitleCue> cues = <DvdSubtitleCue>[];
  for (int i = 0; i < displays.length; i++) {
    final _SpuDisplay d = displays[i];
    if (!d.shows) continue;
    int? end = d.stopMs;
    if (end == null) {
      // 没有 STP_DSP：显示到下一个包开始生效为止（清屏包 / 下一张字幕都算）。
      for (int j = i + 1; j < displays.length; j++) {
        final int next = displays[j].shows
            ? displays[j].startMs
            : (displays[j].stopMs ?? displays[j].ptsMs);
        if (next > d.startMs) {
          end = next;
          break;
        }
      }
    }
    final int endMs = (end ?? d.startMs + kBitmapSubtitleOpenCueCapMs);
    cues.add(
      DvdSubtitleCue._(
        startMs: d.startMs,
        endMs: endMs > d.startMs ? endMs : d.startMs + 1,
        canvasWidth: canvasW,
        canvasHeight: canvasH,
        forced: d.forced,
        area: d.area,
        packet: d.packet,
        topFieldOffset: d.topFieldOffset,
        bottomFieldOffset: d.bottomFieldOffset,
        palette: d.palette,
      ),
    );
  }
  return cues;
}

/// 一个 SPU 包的控制序列解析结果。
class _SpuDisplay {
  _SpuDisplay({
    required this.ptsMs,
    required this.packet,
    required this.shows,
    required this.startMs,
    required this.stopMs,
    required this.forced,
    required this.area,
    required this.topFieldOffset,
    required this.bottomFieldOffset,
    required this.palette,
  });

  final int ptsMs;
  final Uint8List packet;

  /// 有 STA_DSP / FSTA_DSP 且显示区、像素偏移齐全。
  final bool shows;
  final int startMs;
  final int? stopMs;
  final bool forced;
  final BitmapSubtitleBounds area;
  final int topFieldOffset;
  final int bottomFieldOffset;
  final Uint32List palette;
}

/// 控制序列延时（1024/90000 秒为单位）→ 毫秒。
int _spuDelayMs(int delay) => delay * 1024 ~/ 90;

_SpuDisplay? _parseSpu(BitmapSubtitlePacket packet, Uint32List? palette16) {
  final Uint8List b = packet.data;
  if (b.length < 4) return null;
  final int size = (b[0] << 8) | b[1];
  if (size < 4 || size > b.length) return null; // 截断（抽轨还在写）或坏包。
  final Uint8List spu = Uint8List.sublistView(b, 0, size);
  int seq = (spu[2] << 8) | spu[3];
  final int ptsMs = packet.ptsMs;
  int? startMs;
  int? stopMs;
  bool forced = false;
  List<int> colors = const <int>[0, 1, 2, 3];
  List<int> alphas = const <int>[0, 15, 15, 15];
  BitmapSubtitleBounds? area;
  int? top;
  int? bottom;
  final Set<int> visited = <int>{};
  while (seq + 4 <= spu.length && visited.add(seq)) {
    final int delayMs = _spuDelayMs((spu[seq] << 8) | spu[seq + 1]);
    final int next = (spu[seq + 2] << 8) | spu[seq + 3];
    int o = seq + 4;
    bool done = false;
    while (!done && o < spu.length) {
      final int cmd = spu[o++];
      switch (cmd) {
        case 0x00:
          forced = true;
          startMs ??= ptsMs + delayMs;
        case 0x01:
          startMs ??= ptsMs + delayMs;
        case 0x02:
          stopMs ??= ptsMs + delayMs;
        case 0x03:
          if (o + 2 > spu.length) return null;
          colors = <int>[
            spu[o + 1] & 0x0F,
            spu[o + 1] >> 4,
            spu[o] & 0x0F,
            spu[o] >> 4,
          ];
          o += 2;
        case 0x04:
          if (o + 2 > spu.length) return null;
          alphas = <int>[
            spu[o + 1] & 0x0F,
            spu[o + 1] >> 4,
            spu[o] & 0x0F,
            spu[o] >> 4,
          ];
          o += 2;
        case 0x05:
          if (o + 6 > spu.length) return null;
          final int x1 = (spu[o] << 4) | (spu[o + 1] >> 4);
          final int x2 = ((spu[o + 1] & 0x0F) << 8) | spu[o + 2];
          final int y1 = (spu[o + 3] << 4) | (spu[o + 4] >> 4);
          final int y2 = ((spu[o + 4] & 0x0F) << 8) | spu[o + 5];
          if (x2 >= x1 && y2 >= y1) {
            area = (left: x1, top: y1, right: x2 + 1, bottom: y2 + 1);
          }
          o += 6;
        case 0x06:
          if (o + 4 > spu.length) return null;
          top = (spu[o] << 8) | spu[o + 1];
          bottom = (spu[o + 2] << 8) | spu[o + 3];
          o += 4;
        case 0x07:
          // CHG_COLCON：u16 长度（含自身），按行改色 / 不透明度。整轨识别不需要，跳过。
          if (o + 2 > spu.length) return null;
          o += (spu[o] << 8) | spu[o + 1];
        case 0xFF:
          done = true;
        default:
          // 未知命令无法知道长度，后面的字节不可信。
          done = true;
      }
    }
    if (next == seq) break;
    seq = next;
  }
  final bool shows =
      startMs != null && area != null && top != null && bottom != null;
  return _SpuDisplay(
    ptsMs: ptsMs,
    packet: spu,
    shows: shows,
    startMs: startMs ?? ptsMs,
    stopMs: stopMs != null && startMs != null && stopMs <= startMs
        ? null
        : stopMs,
    forced: forced,
    area: area ?? (left: 0, top: 0, right: 0, bottom: 0),
    topFieldOffset: top ?? 0,
    bottomFieldOffset: bottom ?? 0,
    palette: _spuPalette(colors, alphas, palette16),
  );
}

/// SET_COLOR / SET_CONTR → 4 项 ARGB。没有 16 色调色板时按 ffmpeg `guess_palette`：
/// 不透明的颜色按出现顺序从暗到亮分配灰阶（最常见的口径是背景 / 描边暗、字体亮）。
Uint32List _spuPalette(
  List<int> colors,
  List<int> alphas,
  Uint32List? palette16,
) {
  final Uint32List out = Uint32List(4);
  if (palette16 != null) {
    for (int i = 0; i < 4; i++) {
      out[i] = ((alphas[i] * 17) << 24) | (palette16[colors[i]] & 0xFFFFFF);
    }
    return out;
  }
  const List<List<int>> levels = <List<int>>[
    <int>[0xFF],
    <int>[0x00, 0xFF],
    <int>[0x00, 0x80, 0xFF],
    <int>[0x00, 0x55, 0xAA, 0xFF],
  ];
  final Set<int> opaqueColors = <int>{
    for (int i = 0; i < 4; i++)
      if (alphas[i] != 0) colors[i],
  };
  final Map<int, int> assigned = <int, int>{};
  for (int i = 0; i < 4; i++) {
    if (alphas[i] == 0) continue;
    final int level = assigned.putIfAbsent(
      colors[i],
      () => levels[opaqueColors.length - 1][assigned.length],
    );
    out[i] = ((alphas[i] * 17) << 24) | (level << 16) | (level << 8) | level;
  }
  return out;
}

/// 解 SPU 的两场 2 bit RLE 成 [width]×[height] 索引平面（0..3）。数据不足的余下像素
/// 保持 0。
Uint8List decodeDvdSubtitleRle(
  Uint8List packet, {
  required int width,
  required int height,
  required int topFieldOffset,
  required int bottomFieldOffset,
}) {
  final Uint8List out = Uint8List(width > 0 && height > 0 ? width * height : 0);
  if (out.isEmpty) return out;
  for (int field = 0; field < 2; field++) {
    final _NibbleReader r = _NibbleReader(
      packet,
      field == 0 ? topFieldOffset : bottomFieldOffset,
    );
    for (int y = field; y < height; y += 2) {
      int x = 0;
      while (x < width) {
        if (r.exhausted) return out;
        int v = 0;
        for (int t = 1; v < t && t <= 0x40; t <<= 2) {
          v = (v << 4) | r.next();
        }
        final int color = v & 3;
        int run = v < 4 ? width - x : v >> 2;
        if (run > width - x) run = width - x;
        if (color != 0) {
          out.fillRange(y * width + x, y * width + x + run, color);
        }
        x += run;
      }
      r.alignToByte();
    }
  }
  return out;
}

class _NibbleReader {
  _NibbleReader(this._data, int byteOffset) : _pos = byteOffset * 2;

  final Uint8List _data;
  int _pos;

  bool get exhausted => (_pos >> 1) >= _data.length;

  int next() {
    final int byte = _pos >> 1;
    if (byte >= _data.length) {
      _pos++;
      return 0;
    }
    final int v = _pos.isEven ? _data[byte] >> 4 : _data[byte] & 0x0F;
    _pos++;
    return v;
  }

  void alignToByte() {
    if (_pos.isOdd) _pos++;
  }
}
