/// 整轨图形字幕（PGS）→ 文字 SRT：抽轨 → 解析位图 cue → 逐条 OCR（低置信度交 AI，
/// 与漫画同一开关）→ 合并相邻同文 → 写 SRT。生成的 SRT 当普通外挂文字字幕加载，
/// 播放中即可直接点字查词，不必暂停。
///
/// 抽轨走 mpegts 容器：捆绑的最小 ffmpeg 没有 `sup` 封装器，但有 mpegts；这里自己
/// 把 TS 里的 PES 拆回 `.sup` 段流，再交 [PgsSubtitleParser]。
library;

import 'dart:io';
import 'dart:typed_data';

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

/// 把第 [streamIndex] 条字幕轨（`0:s:N` 相对序号）原样复制成 mpegts 落到 [tsPath]。
/// 成功返回 true；失败时删掉空壳文件并返回 false，失败摘要交 [onFailure]。
Future<bool> extractGraphicSubtitleTrackToTs({
  required String videoPath,
  required int streamIndex,
  required String tsPath,
  void Function(String summary)? onFailure,
}) async {
  final File input = File(videoPath);
  if (!input.existsSync()) {
    onFailure?.call('input missing');
    return false;
  }
  final File out = File(tsPath);
  out.parent.createSync(recursive: true);
  final FfmpegRunResult result = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-i',
    videoPath,
    '-map',
    '0:s:$streamIndex',
    '-c',
    'copy',
    '-muxdelay',
    '0',
    '-muxpreload',
    '0',
    '-f',
    'mpegts',
    tsPath,
  ], graphicSubtitleExtractTimeout(input.lengthSync()));
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

/// MPEG-TS 里的 PGS PES → `.sup` 段流（每段 `PG` + PTS + DTS + 段头 + 段体）。
///
/// 取首个负载以私有流 1（`00 00 01 BD`）开头的 PID；PES 按 PUSI 切分。PTS/DTS
/// 是 33 位 90kHz 时钟，`.sup` 只存低 32 位（与 ffmpeg 的 sup 封装器同口径）。
Uint8List mpegTsToPgsSup(Uint8List ts) {
  const int packetSize = 188;
  final int start = ts.indexOf(0x47);
  if (start < 0) return Uint8List(0);
  int? pid;
  final BytesBuilder out = BytesBuilder(copy: false);
  BytesBuilder? pes;

  void flush() {
    final BytesBuilder? current = pes;
    pes = null;
    if (current != null) _appendPesAsSup(current.takeBytes(), out);
  }

  for (int o = start; o + packetSize <= ts.length; o += packetSize) {
    if (ts[o] != 0x47) continue;
    final bool unitStart = ts[o + 1] & 0x40 != 0;
    final int packetPid = ((ts[o + 1] & 0x1F) << 8) | ts[o + 2];
    final int afc = (ts[o + 3] >> 4) & 0x3;
    if (afc & 0x1 == 0) continue; // 无负载
    final int payload = afc & 0x2 != 0 ? o + 5 + ts[o + 4] : o + 4;
    if (payload >= o + packetSize) continue;
    final Uint8List body = Uint8List.sublistView(ts, payload, o + packetSize);
    if (unitStart && pid == null && _isPrivateStream1(body)) pid = packetPid;
    if (packetPid != pid) continue;
    if (unitStart) {
      flush();
      pes = BytesBuilder(copy: true);
    }
    pes?.add(body);
  }
  flush();
  return out.takeBytes();
}

bool _isPrivateStream1(Uint8List b) =>
    b.length >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 1 && b[3] == 0xBD;

void _appendPesAsSup(Uint8List pes, BytesBuilder out) {
  if (pes.length < 9 || !_isPrivateStream1(pes)) return;
  final int flags = pes[7] >> 6;
  final int headerEnd = 9 + pes[8];
  if (headerEnd > pes.length) return;
  final int pts = flags & 0x2 != 0 && pes.length >= 14
      ? _readTimestamp(pes, 9)
      : 0;
  final int dts = flags == 0x3 && pes.length >= 19
      ? _readTimestamp(pes, 14)
      : 0;
  int o = headerEnd;
  while (o + 3 <= pes.length) {
    final int type = pes[o];
    final int size = (pes[o + 1] << 8) | pes[o + 2];
    if (o + 3 + size > pes.length) break;
    final ByteData head = ByteData(13)
      ..setUint8(0, 0x50)
      ..setUint8(1, 0x47)
      ..setUint32(2, pts & 0xFFFFFFFF)
      ..setUint32(6, dts & 0xFFFFFFFF)
      ..setUint8(10, type)
      ..setUint16(11, size);
    out
      ..add(head.buffer.asUint8List())
      ..add(Uint8List.sublistView(pes, o + 3, o + 3 + size));
    o += 3 + size;
  }
}

int _readTimestamp(Uint8List b, int o) =>
    (((b[o] >> 1) & 0x7) << 30) |
    (b[o + 1] << 22) |
    ((b[o + 2] >> 1) << 15) |
    (b[o + 3] << 7) |
    (b[o + 4] >> 1);

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
