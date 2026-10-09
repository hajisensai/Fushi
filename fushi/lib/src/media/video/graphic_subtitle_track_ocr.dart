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
}) =>
    <String>[
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
    final FfmpegBackend plain =>
      await plain.run(args, graphicSubtitleExtractTimeout(input.lengthSync())),
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

/// 逐条识别 [cues]。[onProgress] 报 (已完成, 总数)；[isCancelled] 为真时提前结束并
/// 返回 null。会话关闭（[GraphicSubtitleOcrSession.recognizePage] 返回 null）同样
/// 视为取消。识别不可用抛 [GraphicSubtitleOcrUnavailable]。
Future<List<GraphicSubtitleTextCue>?> recognizeGraphicSubtitleCues({
  required List<PgsCue> cues,
  required GraphicSubtitleOcrSession session,
  required bool Function() isCancelled,
  void Function(int done, int total)? onProgress,
  void Function(Object error, StackTrace stack)? onRefineError,
}) async {
  final List<GraphicSubtitleTextCue> out = <GraphicSubtitleTextCue>[];
  for (int i = 0; i < cues.length; i++) {
    if (isCancelled()) return null;
    final PgsCue cue = cues[i];
    final MokuroImage? page = await session.recognizePage(
      cue.renderPng(),
      onRefineError: onRefineError,
    );
    if (page == null || isCancelled()) return null;
    out.add(
      GraphicSubtitleTextCue(
        startMs: cue.startMs,
        endMs: cue.endMs,
        text: graphicSubtitleTextOf(page),
      ),
    );
    onProgress?.call(i + 1, cues.length);
  }
  return out;
}

/// 生成 SRT：跳过空文字；时间上首尾相接（间隔 ≤ [joinGapMs]）且文字相同的相邻
/// cue 合并成一条（PGS 常把同一句拆成多次显示：淡入淡出、换位置）。
String buildGraphicSubtitleSrt(
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
