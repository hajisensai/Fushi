import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:image/image.dart' as img;

/// Blu-ray 图形字幕（HDMV PGS，`.sup` 裸流）解析：把段流折成「一条字幕一张图」的 cue。
///
/// 只做整轨 OCR 需要的那部分语义：
/// - 段头 `PG` + PTS(90 kHz) + DTS + 类型 + 长度；
/// - PCS(0x16) 给出这一刻屏上放哪些对象、用哪张调色板，`0` 个对象即清屏；
/// - PDS(0x14) 增量更新调色板项（YCrCb + Alpha）；
/// - ODS(0x15) 是 RLE 位图，可跨多段分片（首片带总长与宽高）；
/// - END(0x80) 收束一个显示集。
///
/// 一条 cue = 屏上对象（内容 + 位置 + 裁剪）保持不变的一段时间。淡入淡出只改调色板，
/// 不拆 cue；酸点（acquisition point）重发同内容对象也不拆。位图只存 RLE 原字节，
/// 渲染推迟到 [PgsCue.renderPng]——一整季的字幕全解码成像素会把内存吃掉。
class PgsSubtitleParser {
  PgsSubtitleParser._();

  /// 最后一条没有清屏收尾的 cue 的兜底时长。
  static const int openCueCapMs = 5000;

  /// 解析整份 `.sup` 字节。损坏 / 截断的尾段被忽略，已解析出的 cue 照常返回。
  static List<PgsCue> parse(Uint8List data) {
    final _PgsState state = _PgsState();
    final List<_PgsEvent> events = <_PgsEvent>[];
    int offset = 0;
    while (offset + 13 <= data.length) {
      if (data[offset] != 0x50 || data[offset + 1] != 0x47) break;
      final int pts = _u32(data, offset + 2);
      final int type = data[offset + 10];
      final int size = _u16(data, offset + 11);
      final int bodyStart = offset + 13;
      if (bodyStart + size > data.length) break;
      final Uint8List body = Uint8List.sublistView(
        data,
        bodyStart,
        bodyStart + size,
      );
      offset = bodyStart + size;
      final _PgsEvent? event = state.apply(type, pts, body);
      if (event != null) events.add(event);
    }
    return _groupCues(events);
  }

  static List<PgsCue> _groupCues(List<_PgsEvent> events) {
    final List<PgsCue> cues = <PgsCue>[];
    _PgsCueBuilder? open;
    for (final _PgsEvent event in events) {
      if (open != null && open.sameContent(event)) {
        open.absorb(event);
        continue;
      }
      if (open != null) cues.add(open.build(endPts: event.pts));
      open = event.placements.isEmpty ? null : _PgsCueBuilder(event);
    }
    if (open != null) cues.add(open.build(endPts: null));
    return cues;
  }
}

/// 一条图形字幕：显示区间 + 惰性渲染的位图。
class PgsCue {
  PgsCue._({
    required this.startMs,
    required this.endMs,
    required List<PgsPlacement> placements,
    required Uint32List palette,
  }) : _placements = placements,
       _palette = palette;

  /// 相对 `.sup` 时间轴原点（ffmpeg 抽取时已减去容器起点）的毫秒。
  final int startMs;
  final int endMs;
  final List<PgsPlacement> _placements;
  final Uint32List _palette;

  /// 对象并集外包框（视频坐标系，像素）。
  ({int left, int top, int right, int bottom}) get bounds {
    int l = 1 << 30, t = 1 << 30, r = 0, b = 0;
    for (final PgsPlacement pl in _placements) {
      l = l < pl.x ? l : pl.x;
      t = t < pl.y ? t : pl.y;
      r = r > pl.x + pl.width ? r : pl.x + pl.width;
      b = b > pl.y + pl.height ? b : pl.y + pl.height;
    }
    return (left: l, top: t, right: r, bottom: b);
  }

  /// 黑底合成、四周留 [padding] 像素的 PNG。Alpha 按本调色板最大不透明度归一化，
  /// 淡入帧也按满不透明渲染（OCR 只关心字形）。
  Uint8List renderPng({int padding = 16}) {
    final ({int left, int top, int right, int bottom}) box = bounds;
    final int w = box.right - box.left + padding * 2;
    final int h = box.bottom - box.top + padding * 2;
    final img.Image canvas = img.Image(width: w, height: h);
    int maxAlpha = 0;
    for (final int argb in _palette) {
      final int a = argb >>> 24;
      if (a > maxAlpha) maxAlpha = a;
    }
    if (maxAlpha == 0) return img.encodePng(canvas);
    for (final PgsPlacement pl in _placements) {
      _paint(canvas, pl, box.left - padding, box.top - padding, maxAlpha);
    }
    return img.encodePng(canvas);
  }

  void _paint(
    img.Image canvas,
    PgsPlacement pl,
    int originX,
    int originY,
    int maxAlpha,
  ) {
    final Uint8List? pixels = decodePgsRle(
      pl.object.rle,
      pl.object.width,
      pl.object.height,
    );
    if (pixels == null) return;
    for (int y = 0; y < pl.height; y++) {
      final int row = (pl.cropY + y) * pl.object.width + pl.cropX;
      for (int x = 0; x < pl.width; x++) {
        final int argb = _palette[pixels[row + x]];
        final int a = argb >>> 24;
        if (a == 0) continue;
        final double k = a >= maxAlpha ? 1 : a / maxAlpha;
        canvas.setPixelRgb(
          pl.x + x - originX,
          pl.y + y - originY,
          (((argb >> 16) & 0xFF) * k).round(),
          (((argb >> 8) & 0xFF) * k).round(),
          ((argb & 0xFF) * k).round(),
        );
      }
    }
  }
}

/// 位图对象（ODS 拼完后的 RLE + 尺寸）。
class PgsObject {
  PgsObject({required this.width, required this.height, required this.rle});
  final int width;
  final int height;
  final Uint8List rle;

  bool sameAs(PgsObject other) =>
      width == other.width &&
      height == other.height &&
      const ListEquality<int>().equals(rle, other.rle);
}

/// 对象在画面上的一次摆放（已应用裁剪）。
class PgsPlacement {
  PgsPlacement({
    required this.object,
    required this.x,
    required this.y,
    required this.cropX,
    required this.cropY,
    required this.width,
    required this.height,
  });
  final PgsObject object;
  final int x;
  final int y;
  final int cropX;
  final int cropY;
  final int width;
  final int height;

  bool sameAs(PgsPlacement o) =>
      x == o.x &&
      y == o.y &&
      cropX == o.cropX &&
      cropY == o.cropY &&
      width == o.width &&
      height == o.height &&
      object.sameAs(o.object);
}

/// PGS RLE 解码为调色板索引平面；数据不足时余下像素保持 0（透明）。
/// 尺寸非法返回 null。
Uint8List? decodePgsRle(Uint8List rle, int width, int height) {
  if (width <= 0 || height <= 0) return null;
  final Uint8List out = Uint8List(width * height);
  int i = 0, x = 0, y = 0;
  while (i < rle.length && y < height) {
    int color = rle[i++];
    int run = 1;
    if (color == 0) {
      if (i >= rle.length) break;
      final int flag = rle[i++];
      if (flag == 0) {
        x = 0;
        y++;
        continue;
      }
      run = flag & 0x3F;
      if (flag & 0x40 != 0) {
        if (i >= rle.length) break;
        run = (run << 8) | rle[i++];
      }
      if (flag & 0x80 != 0) {
        if (i >= rle.length) break;
        color = rle[i++];
      }
    }
    final int end = x + run > width ? width : x + run;
    if (color != 0) out.fillRange(y * width + x, y * width + end, color);
    x = end;
  }
  return out;
}

/// BT.709 YCbCr（studio range）→ ARGB。
int pgsYCbCrToArgb(int yy, int cr, int cb, int alpha) {
  final double y = 1.164 * (yy - 16);
  final double r = y + 1.793 * (cr - 128);
  final double g = y - 0.213 * (cb - 128) - 0.533 * (cr - 128);
  final double b = y + 2.112 * (cb - 128);
  int c(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  return (alpha << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
}

int _u16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
int _u24(Uint8List d, int o) => (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];
int _u32(Uint8List d, int o) =>
    (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

/// 一个显示集收束时屏上的状态快照。
class _PgsEvent {
  _PgsEvent(this.pts, this.placements, this.palette);
  final int pts;
  final List<PgsPlacement> placements;
  final Uint32List palette;
}

class _PgsCompositionObject {
  _PgsCompositionObject(this.objectId, this.x, this.y, this.crop);
  final int objectId;
  final int x;
  final int y;
  final ({int x, int y, int w, int h})? crop;
}

class _PgsPendingObject {
  _PgsPendingObject(this.width, this.height);
  final int width;
  final int height;
  final BytesBuilder rle = BytesBuilder(copy: false);
}

/// 段流状态机：epoch 内的调色板与对象表，PCS 暂存到 END 再出快照。
class _PgsState {
  final Map<int, Uint32List> _palettes = <int, Uint32List>{};
  final Map<int, PgsObject> _objects = <int, PgsObject>{};
  final Map<int, _PgsPendingObject> _pending = <int, _PgsPendingObject>{};
  int? _pts;
  int _paletteId = 0;
  List<_PgsCompositionObject>? _composition;

  _PgsEvent? apply(int type, int pts, Uint8List body) {
    switch (type) {
      case 0x16:
        _readPcs(pts, body);
      case 0x14:
        _readPds(body);
      case 0x15:
        _readOds(body);
      case 0x80:
        return _flush();
    }
    return null;
  }

  void _readPcs(int pts, Uint8List b) {
    if (b.length < 11) return;
    final int state = b[7];
    if (state & 0x80 != 0) {
      // epoch start：之前的对象与调色板全部作废。
      _palettes.clear();
      _objects.clear();
      _pending.clear();
    }
    _pts = pts;
    _paletteId = b[9];
    final int count = b[10];
    final List<_PgsCompositionObject> objs = <_PgsCompositionObject>[];
    int o = 11;
    for (int n = 0; n < count && o + 8 <= b.length; n++) {
      final int id = _u16(b, o);
      final bool cropped = b[o + 3] & 0x40 != 0;
      final int x = _u16(b, o + 4);
      final int y = _u16(b, o + 6);
      o += 8;
      ({int x, int y, int w, int h})? crop;
      if (cropped && o + 8 <= b.length) {
        crop = (
          x: _u16(b, o),
          y: _u16(b, o + 2),
          w: _u16(b, o + 4),
          h: _u16(b, o + 6),
        );
        o += 8;
      }
      objs.add(_PgsCompositionObject(id, x, y, crop));
    }
    _composition = objs;
  }

  void _readPds(Uint8List b) {
    if (b.length < 2) return;
    final Uint32List palette = _palettes.putIfAbsent(
      b[0],
      () => Uint32List(256),
    );
    for (int o = 2; o + 5 <= b.length; o += 5) {
      palette[b[o]] = pgsYCbCrToArgb(b[o + 1], b[o + 2], b[o + 3], b[o + 4]);
    }
  }

  void _readOds(Uint8List b) {
    if (b.length < 4) return;
    final int id = _u16(b, 0);
    final int seq = b[3];
    int o = 4;
    if (seq & 0x80 != 0) {
      if (b.length < 11) return;
      _pending[id] = _PgsPendingObject(_u16(b, o + 3), _u16(b, o + 5));
      _u24(b, o); // 总长含宽高 4 字节；分片按 last 标志收束即可，不依赖它。
      o += 7;
    }
    final _PgsPendingObject? pending = _pending[id];
    if (pending == null) return;
    pending.rle.add(Uint8List.sublistView(b, o));
    if (seq & 0x40 == 0) return;
    _pending.remove(id);
    _objects[id] = PgsObject(
      width: pending.width,
      height: pending.height,
      rle: pending.rle.toBytes(),
    );
  }

  _PgsEvent? _flush() {
    final int? pts = _pts;
    final List<_PgsCompositionObject>? comp = _composition;
    _composition = null;
    if (pts == null || comp == null) return null;
    final List<PgsPlacement> placements = <PgsPlacement>[];
    for (final _PgsCompositionObject c in comp) {
      final PgsPlacement? pl = _place(c);
      if (pl != null) placements.add(pl);
    }
    final Uint32List palette = Uint32List.fromList(
      _palettes[_paletteId] ?? Uint32List(256),
    );
    return _PgsEvent(pts, placements, palette);
  }

  PgsPlacement? _place(_PgsCompositionObject c) {
    final PgsObject? obj = _objects[c.objectId];
    if (obj == null) return null;
    final ({int x, int y, int w, int h}) crop =
        c.crop ?? (x: 0, y: 0, w: obj.width, h: obj.height);
    final int cx = crop.x.clamp(0, obj.width);
    final int cy = crop.y.clamp(0, obj.height);
    final int w = crop.w.clamp(0, obj.width - cx);
    final int h = crop.h.clamp(0, obj.height - cy);
    if (w == 0 || h == 0) return null;
    return PgsPlacement(
      object: obj,
      x: c.x,
      y: c.y,
      cropX: cx,
      cropY: cy,
      width: w,
      height: h,
    );
  }
}

/// 把内容不变的连续显示集并成一条 cue，调色板取最不透明的那一帧（淡入的首帧常全透明）。
class _PgsCueBuilder {
  _PgsCueBuilder(_PgsEvent first)
    : _startPts = first.pts,
      _placements = first.placements,
      _palette = first.palette,
      _opacity = _opacityOf(first.palette);

  final int _startPts;
  final List<PgsPlacement> _placements;
  Uint32List _palette;
  int _opacity;

  bool sameContent(_PgsEvent e) =>
      e.placements.length == _placements.length &&
      Iterable<int>.generate(
        _placements.length,
      ).every((int i) => _placements[i].sameAs(e.placements[i]));

  void absorb(_PgsEvent e) {
    final int opacity = _opacityOf(e.palette);
    if (opacity <= _opacity) return;
    _palette = e.palette;
    _opacity = opacity;
  }

  PgsCue build({required int? endPts}) {
    final int startMs = _startPts ~/ 90;
    final int endMs = endPts == null
        ? startMs + PgsSubtitleParser.openCueCapMs
        : endPts ~/ 90;
    return PgsCue._(
      startMs: startMs,
      endMs: endMs > startMs ? endMs : startMs + 1,
      placements: _placements,
      palette: _palette,
    );
  }

  static int _opacityOf(Uint32List palette) {
    int max = 0;
    for (final int argb in palette) {
      final int a = argb >>> 24;
      if (a > max) max = a;
    }
    return max;
  }
}
