/// 整轨图形字幕（PGS）→ 文字 SRT：抽轨 → 解析位图 cue → 逐条 OCR（低置信度交 AI，
/// 与漫画同一开关）→ 合并相邻同文 → 写 SRT。生成的 SRT 当普通外挂文字字幕加载，
/// 播放中即可直接点字查词，不必暂停。
///
/// 抽轨直接 `-c copy -f sup` 落成 `.sup` 段流，再交 [PgsSubtitleParser]（桌面捆绑的
/// 精简 ffmpeg 已编入 sup 封装器，移动端 ffmpeg-kit 默认就有）。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/pgs_subtitle_parser.dart';

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

/// 抽轨超时：按文件体积放宽（整轨 copy 要读完整个容器）。
Duration graphicSubtitleExtractTimeout(int fileBytes) {
  final int gb = fileBytes ~/ (1024 * 1024 * 1024);
  return Duration(seconds: (60 + gb * 8).clamp(60, 1200));
}

/// 把第 [streamIndex] 条字幕轨（`0:s:N` 相对序号）原样复制成 `.sup` 落到 [supPath]。
/// 成功返回 true；失败时删掉空壳文件并返回 false，失败摘要交 [onFailure]。
/// [backend] 缺省为 [resolveFfmpegBackend]。
Future<bool> extractGraphicSubtitleTrackToSup({
  required String videoPath,
  required int streamIndex,
  required String supPath,
  void Function(String summary)? onFailure,
  FfmpegBackend? backend,
}) async {
  final File input = File(videoPath);
  if (!input.existsSync()) {
    onFailure?.call('input missing');
    return false;
  }
  final File out = File(supPath);
  out.parent.createSync(recursive: true);
  final FfmpegRunResult result = await (backend ?? resolveFfmpegBackend()).run(
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
    ],
    graphicSubtitleExtractTimeout(input.lengthSync()),
  );
  if (result.isSuccess && out.existsSync() && out.lengthSync() > 0) {
    return true;
  }
  if (out.existsSync()) {
    try {
      out.deleteSync();
    } on FileSystemException {
      // 空壳文件，留给临时目录清理。
    }
  }
  onFailure?.call(result.failureSummary);
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
