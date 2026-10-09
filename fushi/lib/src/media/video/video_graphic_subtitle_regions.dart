/// 图形字幕（PGS）每句位图在画面上的矩形：「模糊」遮蔽只糊字幕位图本身（略外扩），
/// 不再糊整条字幕带。
///
/// 图形字幕由 libmpv 直接画进画面，播放器不报位图坐标；坐标只在字幕包里——PCS 段给出
/// 合成画布尺寸与每个对象的位置，ODS 给出对象宽高（[PgsSubtitleParser]）。所以这里把
/// 当前轨原样抽成 `.sup`（与整轨转文字同一个抽取函数，按进度判活、可取消），解析出
/// 「起止时间 + 位图外包框」的时间表，播放时按当前位置取正在显示的那几句。
///
/// 抽轨要读完整个文件，耗时取决于磁盘吞吐；结果只有几 KB，按（路径, 大小, 修改时间,
/// 轨序号）缓存在内存与临时目录里，同一个文件第二次打开不再读盘。抽取完成之前、以及
/// 抽不出 `.sup` 的格式（VobSub / DVB），遮蔽层仍退回整条字幕带。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi/src/media/video/pgs_subtitle_parser.dart';

/// 句子出现前多早开始糊、消失后多晚才撤（毫秒）。播放位置是按帧 / 按包推进的，
/// 刚好压在起点上取会漏出一两帧字幕；两头各放一点余量。
const int kGraphicSubtitleRegionLeadMs = 150;
const int kGraphicSubtitleRegionTailMs = 150;

/// 模糊框在位图外包框之外的外扩：位图高度的这个比例，至少
/// [kGraphicSubtitleRegionMinOutsetFraction] × 画布高。位图本身已含描边，外扩只是
/// 盖住模糊核在边缘的衰减，不让字形边缘透出来。
const double kGraphicSubtitleRegionOutsetFraction = 0.18;
const double kGraphicSubtitleRegionMinOutsetFraction = 0.006;

/// 一句图形字幕：显示区间 + 位图外包框（画布坐标系，像素）。
class GraphicSubtitleRegion {
  const GraphicSubtitleRegion({
    required this.startMs,
    required this.endMs,
    required this.rect,
  });

  final int startMs;
  final int endMs;
  final Rect rect;
}

/// 一条图形字幕轨的位图时间表。[regions] 按 [GraphicSubtitleRegion.startMs] 升序。
class GraphicSubtitleRegionTrack {
  GraphicSubtitleRegionTrack({
    required this.canvas,
    required List<GraphicSubtitleRegion> regions,
  }) : regions = List<GraphicSubtitleRegion>.unmodifiable(
         List<GraphicSubtitleRegion>.of(regions)..sort(
           (GraphicSubtitleRegion a, GraphicSubtitleRegion b) =>
               a.startMs.compareTo(b.startMs),
         ),
       ),
       _maxDurationMs = regions.fold<int>(
         0,
         (int m, GraphicSubtitleRegion r) => math.max(m, r.endMs - r.startMs),
       );

  /// 位图坐标所在的合成画布尺寸（PCS 声明；播放器按它把位图等比映射到画面）。
  final Size canvas;
  final List<GraphicSubtitleRegion> regions;
  final int _maxDurationMs;

  /// 播放位置 [positionMs]（已扣字幕调轴的等效位置）此刻该糊的模糊框：正在显示的句子
  /// （两头各放 [leadMs] / [tailMs] 余量）的位图外包框，按 [graphicSubtitleBlurRect] 外扩。
  List<Rect> blurRectsAt(
    int positionMs, {
    int leadMs = kGraphicSubtitleRegionLeadMs,
    int tailMs = kGraphicSubtitleRegionTailMs,
  }) {
    if (regions.isEmpty) return const <Rect>[];
    // 最后一条 startMs - lead <= position 的下标（二分）。
    int lo = 0;
    int hi = regions.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (regions[mid].startMs - leadMs <= positionMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final List<Rect> out = <Rect>[];
    for (int i = lo - 1; i >= 0; i--) {
      final GraphicSubtitleRegion r = regions[i];
      // 比最长一句还早开始的不可能还在显示，到此为止。
      if (r.startMs + _maxDurationMs + tailMs < positionMs) break;
      if (r.endMs + tailMs > positionMs) {
        out.add(graphicSubtitleBlurRect(r.rect, canvas));
      }
    }
    return out;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'w': canvas.width,
    'h': canvas.height,
    'r': <List<num>>[
      for (final GraphicSubtitleRegion r in regions)
        <num>[
          r.startMs,
          r.endMs,
          r.rect.left,
          r.rect.top,
          r.rect.right,
          r.rect.bottom,
        ],
    ],
  };

  /// [toJson] 的逆；形状不对返回 null（缓存文件损坏就当没缓存）。
  static GraphicSubtitleRegionTrack? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? w = json['w'];
    final Object? h = json['h'];
    final Object? rows = json['r'];
    if (w is! num || h is! num || rows is! List) return null;
    final List<GraphicSubtitleRegion> regions = <GraphicSubtitleRegion>[];
    for (final Object? row in rows) {
      if (row is! List ||
          row.length != 6 ||
          row.any((Object? v) => v is! num)) {
        return null;
      }
      final List<num> v = row.cast<num>();
      regions.add(
        GraphicSubtitleRegion(
          startMs: v[0].toInt(),
          endMs: v[1].toInt(),
          rect: Rect.fromLTRB(
            v[2].toDouble(),
            v[3].toDouble(),
            v[4].toDouble(),
            v[5].toDouble(),
          ),
        ),
      );
    }
    return GraphicSubtitleRegionTrack(
      canvas: Size(w.toDouble(), h.toDouble()),
      regions: regions,
    );
  }
}

/// 位图外包框 → 模糊框：四周外扩 [kGraphicSubtitleRegionOutsetFraction] × 位图高
/// （至少 [kGraphicSubtitleRegionMinOutsetFraction] × 画布高），再夹回画布内。
Rect graphicSubtitleBlurRect(Rect bitmap, Size canvas) {
  final double pad = math.max(
    bitmap.height * kGraphicSubtitleRegionOutsetFraction,
    canvas.height * kGraphicSubtitleRegionMinOutsetFraction,
  );
  final Rect grown = bitmap.inflate(pad);
  if (canvas.isEmpty) return grown;
  return grown.intersect(Offset.zero & canvas);
}

/// PGS cue → 位图时间表。cue 没写画布尺寸（0）时用 [fallbackCanvas]（视频分辨率）。
GraphicSubtitleRegionTrack graphicSubtitleRegionsFromPgs(
  List<PgsCue> cues, {
  required Size fallbackCanvas,
}) {
  Size canvas = Size.zero;
  final List<GraphicSubtitleRegion> regions = <GraphicSubtitleRegion>[];
  for (final PgsCue cue in cues) {
    if (canvas.isEmpty && cue.canvasWidth > 0 && cue.canvasHeight > 0) {
      canvas = Size(cue.canvasWidth.toDouble(), cue.canvasHeight.toDouble());
    }
    final ({int left, int top, int right, int bottom}) b = cue.bounds;
    if (b.right <= b.left || b.bottom <= b.top) continue;
    regions.add(
      GraphicSubtitleRegion(
        startMs: cue.startMs,
        endMs: cue.endMs,
        rect: Rect.fromLTRB(
          b.left.toDouble(),
          b.top.toDouble(),
          b.right.toDouble(),
          b.bottom.toDouble(),
        ),
      ),
    );
  }
  return GraphicSubtitleRegionTrack(
    canvas: canvas.isEmpty ? fallbackCanvas : canvas,
    regions: regions,
  );
}

/// 要取哪个文件的哪条图形轨（去 auto/no 后的序号，与抽轨 `0:s:N` 同义）。
typedef GraphicSubtitleRegionRequest = ({String videoPath, int streamIndex});

/// 播放页当前的图形轨能不能按位图坐标糊：本地文件 + PGS 轨（VobSub / DVB 抽不成
/// `.sup`，远端流不整读）。不能时返回 null，遮蔽层退回整条字幕带。
GraphicSubtitleRegionRequest? graphicSubtitleRegionRequestFor({
  required String? videoPath,
  required ({int streamIndex, String? codec})? track,
}) {
  if (videoPath == null || track == null) return null;
  if (!graphicSubtitleTrackOcrSupportsCodec(track.codec)) return null;
  final Uri? uri = Uri.tryParse(videoPath);
  if (uri != null && uri.hasScheme && uri.scheme.length > 1) return null;
  return (videoPath: videoPath, streamIndex: track.streamIndex);
}

/// 位图时间表的来源。[load] 在拿不到时返回 null；[cancel] 完成即放弃（抽轨进程被杀）。
abstract interface class GraphicSubtitleRegionLoader {
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  });
}

/// 生产实现：抽轨 → isolate 里解析 → 内存 + 临时目录 JSON 缓存。
class FfmpegGraphicSubtitleRegionLoader implements GraphicSubtitleRegionLoader {
  FfmpegGraphicSubtitleRegionLoader({Directory? cacheDir})
    : _cacheDirOverride = cacheDir;

  /// 播放页共用的一份（缓存跨页面保留）。
  static final FfmpegGraphicSubtitleRegionLoader shared =
      FfmpegGraphicSubtitleRegionLoader();

  final Directory? _cacheDirOverride;
  final Map<String, GraphicSubtitleRegionTrack> _memory =
      <String, GraphicSubtitleRegionTrack>{};

  Directory get _cacheDir =>
      _cacheDirOverride ??
      Directory(p.join(Directory.systemTemp.path, 'fushi_graphic_sub_regions'));

  @override
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  }) async {
    final File input = File(request.videoPath);
    final FileStat stat = input.statSync();
    if (stat.type != FileSystemEntityType.file) return null;
    final String key = _cacheKey(request, stat);
    final GraphicSubtitleRegionTrack? hot = _memory[key];
    if (hot != null) return hot;
    final File cached = File(p.join(_cacheDir.path, '$key.json'));
    if (cached.existsSync()) {
      try {
        final GraphicSubtitleRegionTrack? track =
            GraphicSubtitleRegionTrack.fromJson(
              jsonDecode(await cached.readAsString()),
            );
        if (track != null) return _memory[key] = track;
      } on FormatException {
        // 损坏的缓存当没有，下面重抽覆盖它。
      } on FileSystemException {
        // 同上。
      }
    }
    final Directory work = await Directory.systemTemp.createTemp(
      'fushi_graphic_sub_regions_',
    );
    try {
      final String supPath = p.join(work.path, 'track.sup');
      final bool ok = await extractGraphicSubtitleTrackToSup(
        videoPath: request.videoPath,
        streamIndex: request.streamIndex,
        supPath: supPath,
        cancel: cancel,
      );
      if (!ok) return null;
      final double fw = fallbackCanvas.width;
      final double fh = fallbackCanvas.height;
      // 一季的 .sup 动辄十几 MB：解析放 isolate，回来的只有几 KB 的数字表。
      final Map<String, Object?> json = await Isolate.run(() {
        final Uint8List bytes = File(supPath).readAsBytesSync();
        return graphicSubtitleRegionsFromPgs(
          PgsSubtitleParser.parse(bytes),
          fallbackCanvas: Size(fw, fh),
        ).toJson();
      });
      final GraphicSubtitleRegionTrack? track =
          GraphicSubtitleRegionTrack.fromJson(json);
      if (track == null) return null;
      _memory[key] = track;
      try {
        cached.parent.createSync(recursive: true);
        await cached.writeAsString(jsonEncode(json));
      } on FileSystemException {
        // 写不进缓存只是下次再抽一遍。
      }
      return track;
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // 临时目录留给系统清理。
      }
    }
  }

  static String _cacheKey(GraphicSubtitleRegionRequest r, FileStat stat) {
    final String raw =
        '${r.videoPath}|${stat.size}|'
        '${stat.modified.millisecondsSinceEpoch}|${r.streamIndex}|v1';
    return sha1.convert(utf8.encode(raw)).toString();
  }
}
