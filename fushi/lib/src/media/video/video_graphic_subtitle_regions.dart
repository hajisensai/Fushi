/// 图形字幕（PGS / VobSub / DVB）每句位图在画面上的矩形：「模糊」遮蔽只糊字幕位图本身
/// （略外扩），不再糊整条字幕带；同一张表也给制卡当逐句时间（无文字 cue）。
///
/// 图形字幕由 libmpv 直接画进画面，播放器不报位图坐标；坐标只在字幕包里（PGS 的
/// PCS / ODS、VobSub 的 SET_DAREA、DVB 的页面 / 区域 / 对象位置）。所以这里把当前轨
/// 原样抽出来（与整轨转文字同一个抽取函数 [extractGraphicSubtitleTrack]，按进度判活、
/// 可取消），解码出「起止时间 + 位图外包框」的时间表，播放时按当前位置取正在显示的那几句。
///
/// 抽轨要读完整个文件，耗时取决于磁盘 / 网络吞吐；结果只有几 KB，本地文件按（路径, 大小,
/// 修改时间, 轨序号）、远端流按（地址, 轨序号）缓存在内存与临时目录里，第二次打开不再
/// 读一遍。抽取完成之前、以及解码不了的编码，遮蔽层仍退回整条字幕带。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:crypto/crypto.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show BitmapSubtitleTrackHeader, decodeBitmapSubtitlePayload;
import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_input.dart';

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

/// 位图 cue（任意编码）→ 位图时间表。cue 没写画布尺寸（0）时用 [fallbackCanvas]
/// （视频分辨率）。
GraphicSubtitleRegionTrack graphicSubtitleRegionsFromCues(
  List<BitmapSubtitleCue> cues, {
  required Size fallbackCanvas,
}) {
  Size canvas = Size.zero;
  final List<GraphicSubtitleRegion> regions = <GraphicSubtitleRegion>[];
  for (final BitmapSubtitleCue cue in cues) {
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

/// mpv `sub-start` 与时间表起点的匹配容差：两边都来自同一个 PTS，只差毫秒取整。
const int kGraphicTimingMatchToleranceMs = 100;

/// 位图时间表 → 逐句**无文字** cue（制卡锚点 / padding 邻句用）。
///
/// 不按首尾相接合并：解析器已把「内容不变、只换调色板 / 酸点重发」的连续显示集并成
/// 一条（各解码器同一口径），剩下首尾相接的相邻位图是**内容不同**的两句——蓝光
/// 字幕前一句的结束往往正好是后一句的开始，合并会把两句裁成一张卡。
List<AudioCue> graphicSubtitleTimingCuesFromRegions(
  GraphicSubtitleRegionTrack track,
) {
  final List<({int startMs, int endMs})> spans = <({int startMs, int endMs})>[
    for (final GraphicSubtitleRegion r in track.regions)
      if (r.endMs > r.startMs) (startMs: r.startMs, endMs: r.endMs),
  ];
  return <AudioCue>[
    for (int i = 0; i < spans.length; i++)
      AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = i
        ..textFragmentId = ''
        ..text = ''
        ..startMs = spans[i].startMs
        ..endMs = spans[i].endMs
        ..audioFileIndex = 0,
  ];
}

/// 要取哪个输入的哪条图形轨（[streamIndex] 是去 auto/no 后的序号，与抽轨 `0:s:N` 同义；
/// [codec] 是播放器报的 codec 名，PGS 免探测）。
@immutable
class GraphicSubtitleRegionRequest {
  const GraphicSubtitleRegionRequest({
    required this.input,
    required this.streamIndex,
    this.codec,
  });

  final GraphicSubtitleInput input;
  final int streamIndex;
  final String? codec;

  @override
  bool operator ==(Object other) =>
      other is GraphicSubtitleRegionRequest &&
      other.input == input &&
      other.streamIndex == streamIndex &&
      other.codec == codec;

  @override
  int get hashCode => Object.hash(input, streamIndex, codec);

  @override
  String toString() =>
      'GraphicSubtitleRegionRequest($input, s:$streamIndex, $codec)';
}

/// 播放页当前的图形轨能不能按位图坐标糊（**本地文件**入口）：本地路径 + 可解码的位图
/// 编码（[graphicSubtitleTrackOcrSupportsCodec]）。远端地址在这里一律返回 null——远端
/// 抽轨要带播放会话的请求头，走 [graphicSubtitleRegionRequestForInput]。不能时返回 null，
/// 遮蔽层退回整条字幕带。
GraphicSubtitleRegionRequest? graphicSubtitleRegionRequestFor({
  required String? videoPath,
  required ({int streamIndex, String? codec})? track,
}) {
  if (videoPath == null) return null;
  final GraphicSubtitleInput input = GraphicSubtitleInput.local(videoPath);
  if (input.isRemote) return null;
  return graphicSubtitleRegionRequestForInput(input: input, track: track);
}

/// 任意输入（本地路径，或 http(s) 地址 + 请求头）的图形轨请求。输入 ffmpeg 读不了
/// （[GraphicSubtitleInput.isSupported]）或编码不能解码时返回 null。
GraphicSubtitleRegionRequest? graphicSubtitleRegionRequestForInput({
  required GraphicSubtitleInput? input,
  required ({int streamIndex, String? codec})? track,
}) {
  if (input == null || track == null) return null;
  if (!input.isSupported) return null;
  if (!graphicSubtitleTrackOcrSupportsCodec(track.codec)) return null;
  return GraphicSubtitleRegionRequest(
    input: input,
    streamIndex: track.streamIndex,
    codec: track.codec,
  );
}

/// 位图时间表的来源。[load] 在拿不到时返回 null。
///
/// [cancel] 完成 = **这一位等待者**放弃：它的 [load] 立刻以 null 返回。同一条轨的抽取
/// 是各等待者共用的一份在途任务，只有全部等待者都放弃了才真的停（抽轨进程被杀）；
/// 不传 [cancel] 的等待者永不放弃，任务会跑到底。
abstract interface class GraphicSubtitleRegionLoader {
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  });
}

/// 抽取失败摘要的去向（[FfmpegGraphicSubtitleRegionLoader] 的失败日志口）。
typedef GraphicSubtitleRegionFailureLog =
    void Function(GraphicSubtitleRegionRequest request, String summary);

/// 生产失败日志口：进错误日志（与整轨转文字那条路同一去向），用户导出日志时能看到
/// 「为什么只糊了整条字幕带 / 图形字幕制卡没有逐句时间」。
void _logGraphicSubtitleRegionFailure(
  GraphicSubtitleRegionRequest request,
  String summary,
) {
  ErrorLogService.instance.log(
    'video.graphicSubtitleRegions.extract',
    'graphic subtitle region extract failed '
        '(${request.input.isRemote ? 'remote' : 'local'}, '
        's:${request.streamIndex}, ${request.codec}): $summary',
  );
}

/// ffmpeg 失败摘要里说明「这次失败出在环境上」的系统错误文本（小写）：输出盘写满 / 写不
/// 进去（载荷写在系统临时目录下）、读写中途的设备错误（网络盘断开）。环境好了再抽就能
/// 成，所以这类非零退出不算「这条轨抽不出来」。
const List<String> _kEnvironmentalExtractFailureMarkers = <String>[
  'no space left on device',
  'disk quota exceeded',
  'permission denied',
  'input/output error',
  'i/o error',
  'error opening output',
];

/// [summary]（[FfmpegRunResult.failureSummary]）是不是环境造成的失败，见
/// [_kEnvironmentalExtractFailureMarkers]。
@visibleForTesting
bool graphicSubtitleExtractFailureIsEnvironmental(String summary) {
  final String lower = summary.toLowerCase();
  return _kEnvironmentalExtractFailureMarkers.any(lower.contains);
}

/// 一次抽轨的结局（[GraphicSubtitleTrackLease.outcome]）。
@immutable
class GraphicSubtitleTrackExtractOutcome {
  const GraphicSubtitleTrackExtractOutcome({
    required this.ok,
    this.exitCode,
    this.failure,
  });

  /// 载荷完整落盘。
  final bool ok;

  /// 抽取那一次 ffmpeg 的退出码；还没跑到 ffmpeg（探测就失败了）或被强杀时为 null。
  final int? exitCode;

  /// 失败摘要（[extractGraphicSubtitleTrack] 的 `onFailure`）；成功 / 被取消时为 null。
  final String? failure;
}

/// 同一条图形轨同一时刻只抽一份（[GraphicSubtitleTrackExtractionHub]）的一份使用权。
///
/// 模糊遮蔽 / 制卡时间表（[FfmpegGraphicSubtitleRegionLoader]）与整轨转文字各持一份，
/// 读同一个载荷文件 [payloadPath]（整轨转文字边抽边读）。载荷不保留：最后一份租约
/// [release] 时还没抽完就杀掉抽轨进程，随后删掉载荷；在那之前加入的使用方直接共用。
class GraphicSubtitleTrackLease {
  GraphicSubtitleTrackLease._(this._job);

  final _SharedTrackExtraction _job;
  bool _released = false;

  /// 载荷路径（旁边带轨头，[bitmapSubtitleTrackHeaderPath]）；抽取还在写时它在长。
  String get payloadPath => _job.payloadPath;

  /// 抽取结局（所有租约共用同一个）。
  Future<GraphicSubtitleTrackExtractOutcome> get outcome => _job.outcome;

  /// 抽取已经结束（成功或失败）。
  bool get isDone => _job.done;

  /// 订阅「已读到的媒体时间」；加入时先补发最近一次。返回取消订阅的函数。
  void Function() listenProgress(void Function(Duration processed) onProgress) {
    final Duration? last = _job.lastProgress;
    if (last != null) onProgress(last);
    _job.progressListeners.add(onProgress);
    return () => _job.progressListeners.remove(onProgress);
  }

  /// 交回使用权。幂等。最后一份交回时：还在抽就杀进程，等它退出后删载荷。
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _job.hub._release(_job);
  }
}

/// 一份共享抽取。
class _SharedTrackExtraction {
  _SharedTrackExtraction(this.hub, this.key, this.workPath)
    : payloadPath = p.join(workPath, 'track.bin');

  final GraphicSubtitleTrackExtractionHub hub;
  final String key;
  final String workPath;
  final String payloadPath;

  /// 完成 = 最后一份租约交回时抽取还没结束：抽轨进程被杀。
  final Completer<void> abort = Completer<void>();
  late final Future<GraphicSubtitleTrackExtractOutcome> outcome;
  bool done = false;
  int leases = 0;
  Duration? lastProgress;
  final List<void Function(Duration processed)> progressListeners =
      <void Function(Duration processed)>[];
}

/// 同一条图形轨（输入地址 + 轨序号）同一时刻只抽一份：模糊遮蔽 / 制卡时间表与整轨转文字
/// 原先各自起一个 ffmpeg 把整个视频读一遍，现在后来的一方加入在途的那份（[acquire]）。
/// 不缓存载荷：全部租约交回即删，之后再要就重抽（位图时间表另有几 KB 的 JSON 缓存）。
class GraphicSubtitleTrackExtractionHub {
  GraphicSubtitleTrackExtractionHub({FfmpegBackend? backend})
    : _backend = backend;

  /// 播放页共用的一份（[FfmpegGraphicSubtitleRegionLoader.shared] 与整轨转文字都用它）。
  static final GraphicSubtitleTrackExtractionHub shared =
      GraphicSubtitleTrackExtractionHub();

  /// 抽轨后端；null = [resolveFfmpegBackend]（测试可注入）。
  final FfmpegBackend? _backend;

  final Map<String, _SharedTrackExtraction> _jobs =
      <String, _SharedTrackExtraction>{};

  static int _seq = 0;

  /// 测试可见：还在共享表里的抽取数。
  @visibleForTesting
  int get debugActiveExtractions => _jobs.length;

  /// 取 [input] 第 [streamIndex] 条轨的一份抽取租约：同一条轨已有在途 / 抽完但还有人
  /// 持有的抽取就加入它，否则开一份新的。用完必须 [GraphicSubtitleTrackLease.release]。
  GraphicSubtitleTrackLease acquire({
    required GraphicSubtitleInput input,
    required int streamIndex,
    String? codec,
  }) {
    final String key = '${input.uri}|$streamIndex';
    final _SharedTrackExtraction job = _jobs[key] ??= _start(
      key,
      input: input,
      streamIndex: streamIndex,
      codec: codec,
    );
    job.leases++;
    return GraphicSubtitleTrackLease._(job);
  }

  _SharedTrackExtraction _start(
    String key, {
    required GraphicSubtitleInput input,
    required int streamIndex,
    required String? codec,
  }) {
    final _SharedTrackExtraction job = _SharedTrackExtraction(
      this,
      key,
      p.join(
        Directory.systemTemp.path,
        'fushi_graphic_sub_track_${pid}_'
        '${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      ),
    );
    job.outcome = _run(
      job,
      input: input,
      streamIndex: streamIndex,
      codec: codec,
    );
    return job;
  }

  Future<GraphicSubtitleTrackExtractOutcome> _run(
    _SharedTrackExtraction job, {
    required GraphicSubtitleInput input,
    required int streamIndex,
    required String? codec,
  }) async {
    GraphicSubtitleTrackExtractOutcome outcome;
    try {
      await Directory(job.workPath).create(recursive: true);
      final _ExitRecordingBackend backend = _ExitRecordingBackend.wrap(
        _backend ?? resolveFfmpegBackend(),
      );
      String? failure;
      final bool ok = await extractGraphicSubtitleTrack(
        input: input,
        streamIndex: streamIndex,
        outputPath: job.payloadPath,
        codec: codec,
        cancel: job.abort.future,
        backend: backend,
        onProgress: (Duration processed) {
          job.lastProgress = processed;
          for (final void Function(Duration) listener
              in List<void Function(Duration)>.of(job.progressListeners)) {
            listener(processed);
          }
        },
        // 取消不报失败（抽取函数的契约），这里拿到的都是真失败。
        onFailure: (String summary) => failure = summary,
      );
      outcome = GraphicSubtitleTrackExtractOutcome(
        ok: ok,
        exitCode: backend.extractExitCode,
        failure: failure,
      );
    } on FileSystemException catch (error) {
      outcome = GraphicSubtitleTrackExtractOutcome(
        ok: false,
        failure: 'work dir: ${error.message}',
      );
    }
    job.done = true;
    // 失败的不留给后来者加入：下一位重新抽。
    if (!outcome.ok && identical(_jobs[job.key], job)) _jobs.remove(job.key);
    return outcome;
  }

  Future<void> _release(_SharedTrackExtraction job) async {
    if (--job.leases > 0) return;
    // 先摘条目再杀进程（同步、中间没有 await）：之后来的使用方开新抽取，不会加入这份
    // 正在被杀 / 正在删载荷的。
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    if (!job.done && !job.abort.isCompleted) job.abort.complete();
    await job.outcome;
    try {
      await Directory(job.workPath).delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
  }
}

/// 一条轨的在途抽取，各等待者共用。
class _InflightRegionLoad {
  /// 完成 = 全部等待者都放弃了：抽轨进程被杀。
  final Completer<void> abort = Completer<void>();

  /// 还在等结果的调用方数。
  int waiters = 0;

  late final Future<GraphicSubtitleRegionTrack?> result;
}

/// 生产实现：抽轨 → isolate 里解码 → 内存 + 临时目录 JSON 缓存。
class FfmpegGraphicSubtitleRegionLoader implements GraphicSubtitleRegionLoader {
  /// [extractions] 缺省：给了 [backend]（测试）就用一份独立的、按它抽轨的共享表，
  /// 否则用与整轨转文字共用的 [GraphicSubtitleTrackExtractionHub.shared]。
  FfmpegGraphicSubtitleRegionLoader({
    Directory? cacheDir,
    FfmpegBackend? backend,
    GraphicSubtitleTrackExtractionHub? extractions,
    GraphicSubtitleRegionFailureLog? onExtractFailure,
  }) : _cacheDirOverride = cacheDir,
       _extractions =
           extractions ??
           (backend == null
               ? GraphicSubtitleTrackExtractionHub.shared
               : GraphicSubtitleTrackExtractionHub(backend: backend)),
       _onExtractFailure = onExtractFailure ?? _logGraphicSubtitleRegionFailure;

  /// 播放页共用的一份（缓存跨页面保留）。
  static final FfmpegGraphicSubtitleRegionLoader shared =
      FfmpegGraphicSubtitleRegionLoader();

  final Directory? _cacheDirOverride;

  /// 抽轨走的共享表：与整轨转文字同一条轨同一时刻只抽一份。
  final GraphicSubtitleTrackExtractionHub _extractions;

  /// 抽取失败摘要的去向；缺省进错误日志（测试替换成收集器）。
  final GraphicSubtitleRegionFailureLog _onExtractFailure;

  final Map<String, GraphicSubtitleRegionTrack> _memory =
      <String, GraphicSubtitleRegionTrack>{};

  /// 在途加载（同一输入同一轨只抽一次：模糊遮蔽层与制卡时间表会同时要它）。
  final Map<String, _InflightRegionLoad> _inflight =
      <String, _InflightRegionLoad>{};

  /// 本次运行里确定抽不出来的轨（本地文件 + ffmpeg 非零退出，且不是环境造成的失败），
  /// 键同缓存键——含文件大小与修改时间，文件换了键就变。只在内存里：重启 app 后会再试
  /// 一次。
  final Set<String> _failed = <String>{};

  /// 测试可见：所有在途任务上还在等结果的调用方总数。
  @visibleForTesting
  int get debugInflightWaiters => _inflight.values.fold<int>(
    0,
    (int n, _InflightRegionLoad job) => n + job.waiters,
  );

  Directory get _cacheDir =>
      _cacheDirOverride ??
      Directory(p.join(Directory.systemTemp.path, 'fushi_graphic_sub_regions'));

  @override
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  }) async {
    final String? key = await _cacheKey(request);
    if (key == null) return null;
    final GraphicSubtitleRegionTrack? hot = _memory[key];
    if (hot != null) return hot;
    if (_failed.contains(key)) return null;
    final _InflightRegionLoad job = _inflight[key] ??= _startLoad(
      request,
      key,
      fallbackCanvas: fallbackCanvas,
    );
    job.waiters++;
    if (cancel == null) return job.result;
    final Completer<GraphicSubtitleRegionTrack?> mine =
        Completer<GraphicSubtitleRegionTrack?>();
    unawaited(
      job.result.then(
        (GraphicSubtitleRegionTrack? track) {
          if (!mine.isCompleted) mine.complete(track);
        },
        onError: (Object error, StackTrace stack) {
          if (!mine.isCompleted) mine.completeError(error, stack);
        },
      ),
    );
    unawaited(
      cancel.then((_) {
        if (mine.isCompleted) return;
        mine.complete(null);
        if (--job.waiters > 0) return;
        // 最后一位等待者也放弃了：先把条目摘掉再杀进程（同步、中间没有 await），
        // 之后来的调用方开一份新任务，不会接到这份正在被杀的任务拿 null。
        if (identical(_inflight[key], job)) _inflight.remove(key);
        job.abort.complete();
      }),
    );
    return mine.future;
  }

  _InflightRegionLoad _startLoad(
    GraphicSubtitleRegionRequest request,
    String key, {
    required Size fallbackCanvas,
  }) {
    final _InflightRegionLoad job = _InflightRegionLoad();
    job.result =
        _loadUncached(
          request,
          key,
          fallbackCanvas: fallbackCanvas,
          cancel: job.abort.future,
        ).whenComplete(() {
          if (identical(_inflight[key], job)) _inflight.remove(key);
        });
    // 等待者全放弃之后任务才出错的话没人接这个错；各等待者自己那一份照常收到。
    job.result.ignore();
    return job;
  }

  Future<GraphicSubtitleRegionTrack?> _loadUncached(
    GraphicSubtitleRegionRequest request,
    String key, {
    required Size fallbackCanvas,
    required Future<void> cancel,
  }) async {
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
    // 与整轨转文字共用一次抽轨：这里放弃（全部等待者都取消）只交回自己的租约，
    // 整轨转文字还在用时抽轨照跑。
    final GraphicSubtitleTrackLease lease = _extractions.acquire(
      input: request.input,
      streamIndex: request.streamIndex,
      codec: request.codec,
    );
    try {
      final GraphicSubtitleTrackExtractOutcome? outcome = await Future.any(
        <Future<GraphicSubtitleTrackExtractOutcome?>>[
          lease.outcome,
          cancel.then((_) => null),
        ],
      );
      if (outcome == null) return null;
      if (!outcome.ok) {
        final String? summary = outcome.failure;
        if (summary != null) _onExtractFailure(request, summary);
        // 只记「本地文件 + ffmpeg 非零退出」：同一份文件再抽还是同样的结果。网络流、
        // 无进度判活 / 超时（退出码为 null，慢盘 / NAS）、探测失败都可能是瞬时的，不记；
        // 非零退出里出在环境上的（临时目录所在盘写满、网络盘断开）也不记。
        final int? exitCode = outcome.exitCode;
        if (!request.input.isRemote &&
            exitCode != null &&
            exitCode != 0 &&
            (summary == null ||
                !graphicSubtitleExtractFailureIsEnvironmental(summary))) {
          _failed.add(key);
        }
        return null;
      }
      final String payloadPath = lease.payloadPath;
      final Uint8List payload = await File(payloadPath).readAsBytes();
      final BitmapSubtitleTrackHeader? header = readGraphicSubtitleTrackHeader(
        payloadPath,
        payload,
      );
      if (header == null) return null;
      final Map<String, Object?> json = await _decodeRegionsInIsolate(
        payload,
        header,
        fallbackCanvas.width,
        fallbackCanvas.height,
      );
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
      await lease.release();
    }
  }

  /// 一季的载荷动辄十几 MB：解码放 isolate，回来的只有几 KB 的数字表。
  ///
  /// 单独一个静态函数：isolate 闭包会把所在作用域的整个上下文发过去，写在
  /// [_loadUncached] 里就会连 `this`（在途任务表里的 Completer 发不过去）一起带上。
  static Future<Map<String, Object?>> _decodeRegionsInIsolate(
    Uint8List payload,
    BitmapSubtitleTrackHeader header,
    double fallbackWidth,
    double fallbackHeight,
  ) => Isolate.run(
    () => graphicSubtitleRegionsFromCues(
      decodeBitmapSubtitlePayload(payload, header),
      fallbackCanvas: Size(fallbackWidth, fallbackHeight),
    ).toJson(),
  );

  /// 缓存键：本地文件带大小与修改时间（文件换了就重抽）；远端流只认地址（请求头里的
  /// 会话凭据会轮换，不进键）。本地文件不存在返回 null。`v2`：解码器扩到 VobSub / DVB。
  ///
  /// async stat：本地视频可能在网络盘上，同步 stat 会冻结 UI isolate（BUG-3756）。
  static Future<String?> _cacheKey(GraphicSubtitleRegionRequest r) async {
    final String identity;
    if (r.input.isRemote) {
      identity = r.input.uri;
    } else {
      final FileStat stat = await File(r.input.uri).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      identity =
          '${r.input.uri}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    }
    final String raw = '$identity|${r.streamIndex}|v2';
    return sha1.convert(utf8.encode(raw)).toString();
  }
}

/// 抽轨后端的转发壳：记下抽取那一次 ffmpeg 的退出码（[FfmpegRunResult.returnCode]；
/// 超时 / 卡死 / 取消被强杀时为 null），供 [FfmpegGraphicSubtitleRegionLoader] 区分
/// 「确定性失败」与「瞬时失败」。探测 / 查询原样转发、不记。
class _ExitRecordingBackend implements FfmpegBackend {
  _ExitRecordingBackend(this._inner);

  /// [inner] 支持观察式运行（[FfmpegWatchedRunner]）时，壳也要支持——抽取函数按这个
  /// 能力选「按进度判活、可取消」的那条路。
  static _ExitRecordingBackend wrap(FfmpegBackend inner) =>
      inner is FfmpegWatchedRunner
      ? _ExitRecordingWatchedBackend(inner, inner as FfmpegWatchedRunner)
      : _ExitRecordingBackend(inner);

  final FfmpegBackend _inner;

  /// 抽取那一次 ffmpeg 的退出码；还没跑到 ffmpeg（探测就失败了）或被强杀时为 null。
  int? extractExitCode;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final FfmpegRunResult result = await _inner.run(args, timeout);
    extractExitCode = result.returnCode;
    return result;
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      _inner.runProbe(args, timeout);

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      _inner.runQuery(args, timeout);
}

class _ExitRecordingWatchedBackend extends _ExitRecordingBackend
    implements FfmpegWatchedRunner {
  _ExitRecordingWatchedBackend(super.inner, this._watched);

  final FfmpegWatchedRunner _watched;

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    final FfmpegRunResult result = await _watched.runWatched(args, watch);
    extractExitCode = result.returnCode;
    return result;
  }
}
