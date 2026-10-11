/// 整轨图形字幕（PGS）→ 文字 SRT：抽轨 → 解析位图 cue → 逐条 OCR（低置信度交 AI，
/// 与漫画同一开关）→ 合并相邻同文 → 写 SRT。生成的 SRT 当普通外挂文字字幕加载，
/// 播放中即可直接点字查词，不必暂停。
///
/// 抽轨直接 `-c copy -f sup` 落成 `.sup` 段流，再交 [PgsSubtitleParser]（桌面捆绑的
/// 精简 ffmpeg 已编入 sup / null 封装器，移动端 ffmpeg-kit 默认就有；`-c copy` 不需要
/// PGS 解码器，精简版只会多打一行 "Could not find codec parameters … unspecified size"
/// 的警告，抽取结果与完整版逐字节一致）。抽轨要读完整个容器，耗时取决于磁盘吞吐，
/// 所以按进度判活而不是给总超时（BUG-3102）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/pgs_subtitle_parser.dart';

/// 整轨转文字目前只支持 PGS（`hdmv_pgs_subtitle`）：抽轨落 `.sup` 段流交 [PgsSubtitleParser]。
/// VobSub（`dvd_subtitle`）/ DVB 的位图格式不同，`-f sup` 封装器直接拒收（实测
/// `Error submitting a packet to the muxer: Invalid data`），所以菜单只给 PGS 轨这个入口；
/// 它们仍可暂停后对画面 OCR 查词。
bool graphicSubtitleTrackOcrSupportsCodec(String? codec) =>
    codec != null && codec.toLowerCase().contains('pgs');

/// 一条识别出文字的字幕。
class GraphicSubtitleTextCue {
  const GraphicSubtitleTextCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

/// 整轨抽取的卡死判据：已处理媒体时间连续这么久不推进才算卡死（BUG-3102）。
///
/// 不是总时长：慢盘 / NAS 上整轨抽取可以合法地跑十几分钟，只要一直在推进就不该被杀。
const Duration kGraphicSubtitleExtractStallTimeout = Duration(seconds: 90);

/// 抽轨的 ffmpeg 参数（不含观察式运行由后端前置的进度参数）。
///
/// 一次读文件、两个输出：
/// 1. `0:s:N`（相对序号）原样复制成 `.sup` 段流——真正要的产物；
/// 2. 视频（可选，`?`：纯字幕容器没有视频流）+ 同一条字幕轨复制进 `-f null`——不落盘，
///    只为让 `-progress` 的已处理时间跟着文件读取位置**连续**推进。只映射字幕流时，
///    进度只在字幕包处跳一下，长段无对白就几分钟不动，按进度判活会误判卡死。拷贝视频包
///    不解码，额外开销只是内存里搬一次包（实测 7.5 GB / 30 分钟 mkv：单输出 11.1 s，
///    双输出 11.0 s，同为页缓存热态）。
List<String> buildGraphicSubtitleExtractArgs({
  required String videoPath,
  required int streamIndex,
  required String supPath,
}) => <String>[
  '-y',
  '-i',
  videoPath,
  '-map',
  '0:s:$streamIndex',
  '-c',
  'copy',
  '-f',
  'sup',
  supPath,
  '-map',
  '0:v:0?',
  '-map',
  '0:s:$streamIndex',
  '-c',
  'copy',
  '-f',
  'null',
  '-',
];

/// 旧的总时长预算，只给不支持观察式运行的后端兜底（测试替身等）。
Duration graphicSubtitleExtractTimeout(int fileBytes) {
  final int gb = fileBytes ~/ (1024 * 1024 * 1024);
  return Duration(seconds: (60 + gb * 8).clamp(60, 1200));
}

/// 把第 [streamIndex] 条字幕轨（`0:s:N` 相对序号）原样复制成 `.sup` 落到 [supPath]。
/// 成功返回 true；失败 / 被取消时删掉空壳文件并返回 false，失败摘要交 [onFailure]
/// （取消不报失败）。
///
/// 后端支持观察式运行（[FfmpegWatchedRunner]，桌面 CLI 与移动端 ffmpeg-kit）时按进度
/// 判活（[kGraphicSubtitleExtractStallTimeout]），[onProgress] 报已读到的媒体时间，
/// [cancel] 完成即强杀。[backend] 缺省为 [resolveFfmpegBackend]。
Future<bool> extractGraphicSubtitleTrackToSup({
  required String videoPath,
  required int streamIndex,
  required String supPath,
  void Function(String summary)? onFailure,
  void Function(Duration processed)? onProgress,
  Future<void>? cancel,
  FfmpegBackend? backend,
  Duration stallTimeout = kGraphicSubtitleExtractStallTimeout,
}) async {
  final File input = File(videoPath);
  if (!input.existsSync()) {
    onFailure?.call('input missing');
    return false;
  }
  final File out = File(supPath);
  out.parent.createSync(recursive: true);
  bool cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));
  final List<String> args = buildGraphicSubtitleExtractArgs(
    videoPath: videoPath,
    streamIndex: streamIndex,
    supPath: supPath,
  );
  final FfmpegRunResult result = switch (backend ?? resolveFfmpegBackend()) {
    final FfmpegWatchedRunner watched => await watched.runWatched(
      args,
      FfmpegWatch(
        stallTimeout: stallTimeout,
        onProgress: onProgress,
        cancel: cancel,
      ),
    ),
    final FfmpegBackend plain => await plain.run(
      args,
      graphicSubtitleExtractTimeout(input.lengthSync()),
    ),
  };
  if (!cancelled &&
      result.isSuccess &&
      out.existsSync() &&
      out.lengthSync() > 0) {
    return true;
  }
  if (out.existsSync()) {
    try {
      out.deleteSync();
    } on FileSystemException {
      // 空壳文件，留给临时目录清理。
    }
  }
  if (!cancelled) onFailure?.call(result.failureSummary);
  return false;
}

/// 一页 OCR 结果 → 字幕文字：块内各行直接拼接，块之间换行。
String graphicSubtitleTextOf(MokuroImage image) => image.blocks
    .map((MokuroBlock b) => b.lines.join().trim())
    .where((String s) => s.isNotEmpty)
    .join('\n');

/// 边看边识别往播放器里刷新文字字幕的最小间隔：每次刷新都会重置控制器的当前句状态，
/// 不逐条刷，攒一小批再换。
const Duration kGraphicSubtitleLivePublishInterval = Duration(
  milliseconds: 1500,
);

/// 边看边识别时下一条该识别的 cue：优先「还没播完」的第一条未开始识别的 cue（离播放头
/// 最近的将要出现的字幕先有字），播放头之后全开始了再回头补前面的。都开始了返回 null。
int? pickNextGraphicSubtitleCue(
  List<PgsCue> cues,
  Set<int> startedStarts,
  int positionMs,
) {
  int? firstPending;
  for (int i = 0; i < cues.length; i++) {
    if (startedStarts.contains(cues[i].startMs)) continue;
    if (cues[i].endMs > positionMs) return i;
    firstPending ??= i;
  }
  return firstPending;
}

List<GraphicSubtitleTextCue> _collectRecognized(
  List<PgsCue> cues,
  Map<int, String> texts,
) => <GraphicSubtitleTextCue>[
  for (final PgsCue cue in cues)
    if (texts[cue.startMs] case final String text)
      GraphicSubtitleTextCue(
        startMs: cue.startMs,
        endMs: cue.endMs,
        text: text,
      ),
];

/// 在后台 isolate 渲染一条 cue 的像素（解 RLE + 合成是纯 CPU 活，不放 UI 线程）。
Future<PgsRenderedImage> renderGraphicSubtitleCueInBackground(PgsCue cue) =>
    Isolate.run(cue.renderRgba);

/// 在后台 isolate 解析抽轨中的 `.sup`（不存在 / 读不了视为空）：每隔几秒重读一次
/// 增长中的文件，解析不该占 UI 线程。
Future<List<PgsCue>> readGraphicSubtitleSupInBackground(String supPath) async {
  try {
    final File sup = File(supPath);
    if (!await sup.exists()) return const <PgsCue>[];
    final Uint8List bytes = await sup.readAsBytes();
    return await Isolate.run(() => PgsSubtitleParser.parse(bytes));
  } on FileSystemException {
    return const <PgsCue>[];
  }
}

/// 边抽轨边识别（边看边 OCR）：抽轨进程还在写 `.sup` 时就按 [snapshot] 反复读出已落盘
/// 的 cue，按 [pickNextGraphicSubtitleCue] 的顺序（播放头附近优先）识别，同时在途
/// [GraphicSubtitleOcrSession.subtitleParallelism] 条；每有一条出字（本地结果，或
/// 大模型重读回来的新文字）就把「目前已识别的全部 cue」（按时间升序）交给
/// [onRecognized]，页面据此把字幕实时补进可点 overlay。
///
/// - [sourceComplete] 为假时最后一条 cue 不识别：它可能还没收尾（PGS 解析器给未清屏的
///   尾 cue 兜底时长，后续段落会改它的结束时间）。其余 cue 的起止由后一个显示集决定，
///   不会因文件继续增长而改变，所以按起点认身份、识别过的不再重做；
/// - 识别追上抽轨时等 [sourceDone] 或 [pollInterval] 再读；
/// - 本地全部识别完后等大模型重读收尾（[onAiProgress] 报进度），再返回最终文字；
/// - [isCancelled] 为真 / 会话关闭返回 null；识别不可用抛 [GraphicSubtitleOcrUnavailable]。
///
/// [render] 把 cue 渲染成像素（默认后台 isolate；测试可注入同步实现）。
/// 返回全部识别结果（升序）。[onProgress] 报 (已识别, 目前已知总数)。
Future<List<GraphicSubtitleTextCue>?> recognizeGraphicSubtitleCuesLive({
  required Future<List<PgsCue>> Function() snapshot,
  required bool Function() sourceComplete,
  required Future<void> sourceDone,
  required GraphicSubtitleOcrSession session,
  required int Function() positionMs,
  required bool Function() isCancelled,
  void Function(List<GraphicSubtitleTextCue> recognized)? onRecognized,
  void Function(int done, int known)? onProgress,
  void Function(int done, int total)? onAiProgress,
  void Function(Object error, StackTrace stack)? onRefineError,
  Future<PgsRenderedImage> Function(PgsCue cue)? render,
  Duration pollInterval = const Duration(milliseconds: 800),
  Duration resnapshotEvery = const Duration(seconds: 2),
}) async {
  final Future<PgsRenderedImage> Function(PgsCue cue) renderCue =
      render ?? renderGraphicSubtitleCueInBackground;
  final int parallelism = await session.subtitleParallelism();
  final Map<int, String> texts = <int, String>{};
  final Set<int> started = <int>{};
  int recognized = 0;
  int inFlight = 0;
  bool closed = false;
  Object? failure;
  StackTrace? failureStack;
  Completer<void>? changed;
  void signal() {
    final Completer<void>? c = changed;
    changed = null;
    c?.complete();
  }

  List<PgsCue> latest = const <PgsCue>[];
  void emit() => onRecognized?.call(_collectRecognized(latest, texts));

  void launch(PgsCue cue) {
    final int start = cue.startMs;
    started.add(start);
    inFlight++;
    unawaited(() async {
      try {
        final PgsRenderedImage image = await renderCue(cue);
        if (isCancelled()) return;
        final String? text = await session.recognizeSubtitleImage(
          image,
          onRefined: (String refined) {
            if (isCancelled()) return;
            texts[start] = refined;
            emit();
          },
          onRefineError: onRefineError,
        );
        if (text == null) {
          closed = true;
          return;
        }
        if (isCancelled()) return;
        // 大模型可能比本地慢一步也可能先到（同图去重）：已有重读文字就不回退。
        texts.putIfAbsent(start, () => text);
        recognized++;
        onProgress?.call(recognized, latest.length);
        emit();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      } finally {
        inFlight--;
        signal();
      }
    }());
  }

  Future<void> waitChange() => (changed ??= Completer<void>()).future;

  Future<void> drainInFlight() async {
    while (inFlight > 0) {
      await waitChange();
    }
  }

  while (true) {
    if (isCancelled() || closed) {
      await drainInFlight();
      return null;
    }
    if (failure != null) {
      await drainInFlight();
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    // 先读完成标志再读文件：标志为真时读到的必然是完整产物。
    final bool complete = sourceComplete();
    final List<PgsCue> all = await snapshot();
    if (isCancelled()) continue;
    latest = complete || all.isEmpty ? all : all.sublist(0, all.length - 1);
    final Stopwatch sw = Stopwatch()..start();
    bool progressed = false;
    while (complete || sw.elapsed < resnapshotEvery) {
      if (isCancelled() || closed || failure != null) break;
      while (inFlight < parallelism) {
        final int? i = pickNextGraphicSubtitleCue(
          latest,
          started,
          positionMs(),
        );
        if (i == null) break;
        launch(latest[i]);
        progressed = true;
      }
      if (inFlight == 0) break;
      await waitChange();
    }
    if (isCancelled() || closed || failure != null) continue;
    if (complete && inFlight == 0) break;
    if (!progressed && inFlight == 0) {
      await Future.any(<Future<void>>[
        sourceDone,
        Future<void>.delayed(pollInterval),
      ]);
    }
  }
  await session.drainSubtitleRefinements(onProgress: onAiProgress);
  if (isCancelled() || session.isClosed) return null;
  return _collectRecognized(latest, texts);
}

/// 合并相邻同文：跳过空文字；时间上首尾相接（间隔 ≤ [joinGapMs]）且文字相同的相邻
/// cue 合并成一条（PGS 常把同一句拆成多次显示：淡入淡出、换位置）。
List<GraphicSubtitleTextCue> mergeGraphicSubtitleTextCues(
  List<GraphicSubtitleTextCue> cues, {
  int joinGapMs = 50,
}) {
  final List<GraphicSubtitleTextCue> merged = <GraphicSubtitleTextCue>[];
  for (final GraphicSubtitleTextCue cue in cues) {
    if (cue.text.trim().isEmpty || cue.endMs <= cue.startMs) continue;
    final GraphicSubtitleTextCue? last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.text == cue.text &&
        cue.startMs - last.endMs <= joinGapMs) {
      merged[merged.length - 1] = GraphicSubtitleTextCue(
        startMs: last.startMs,
        endMs: cue.endMs > last.endMs ? cue.endMs : last.endMs,
        text: last.text,
      );
      continue;
    }
    merged.add(cue);
  }
  return merged;
}

/// 识别结果 → 可点 overlay 用的 cue（合并规则与 SRT 相同，边看边识别实时喂播放器）。
List<AudioCue> graphicSubtitleAudioCues(List<GraphicSubtitleTextCue> cues) {
  final List<GraphicSubtitleTextCue> merged = mergeGraphicSubtitleTextCues(
    cues,
  );
  return <AudioCue>[
    for (int i = 0; i < merged.length; i++)
      AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = i
        ..textFragmentId = ''
        ..text = merged[i].text
        ..startMs = merged[i].startMs
        ..endMs = merged[i].endMs
        ..audioFileIndex = 0,
  ];
}

/// 生成 SRT（相邻同文合并见 [mergeGraphicSubtitleTextCues]）。
String buildGraphicSubtitleSrt(
  List<GraphicSubtitleTextCue> cues, {
  int joinGapMs = 50,
}) {
  final List<GraphicSubtitleTextCue> merged = mergeGraphicSubtitleTextCues(
    cues,
    joinGapMs: joinGapMs,
  );
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < merged.length; i++) {
    final GraphicSubtitleTextCue c = merged[i];
    sb
      ..writeln(i + 1)
      ..writeln('${_srtTime(c.startMs)} --> ${_srtTime(c.endMs)}')
      ..writeln(c.text)
      ..writeln();
  }
  return sb.toString();
}

String _srtTime(int ms) {
  String two(int v) => v.toString().padLeft(2, '0');
  final int h = ms ~/ 3600000;
  final int m = (ms ~/ 60000) % 60;
  final int s = (ms ~/ 1000) % 60;
  return '${two(h)}:${two(m)}:${two(s)},${(ms % 1000).toString().padLeft(3, '0')}';
}
