/// 整轨图形字幕（PGS / VobSub / DVB）的抽取与解码：抽轨 → 轨头 → 后台解码成位图 cue。
///
/// app（本地播放 / 整轨 OCR / 模糊遮蔽 / 逐句时间表）与无头服务端（互联 host 回传整轨，
/// `GET /api/library/videos/<id>/graphicsubtitle`）共用这一份；本文件纯 Dart，不碰
/// Flutter / 插件，ffmpeg 一律经 [resolveFfmpegBackend]（app 在移动端装 ffmpeg-kit，
/// 桌面与服务端走 CLI）。
///
/// 抽轨一律 `-c copy`（不需要位图字幕解码器——捆绑的精简 ffmpeg 一个都没编），载荷容器
/// 按编码选（[BitmapSubtitleCodec.muxer]）：
/// - PGS：`-f sup` 段流，交 `PgsSubtitleParser`（结果与完整版 ffmpeg 逐字节一致）；
/// - VobSub / DVB：`-f sup` 直接拒收（实测 `Invalid data`），改封单轨 `-f mpegts`——
///   精简版编入的封装器里只有它能原样承载任意字幕编码、逐包带 PTS、边写边可读；
///   TS 丢掉的 codec extradata（VobSub 调色板 / 画布、DVB 页号）抽轨前用 ffprobe 读进
///   头文件（`bitmap_subtitle_track.dart`）。`-muxdelay 0` 必须带：TS 封装器默认给时间戳
///   整体加 1.4 s 的复用延迟（实测 1.000 s 的包写成 2.400 s）。
///
/// 抽轨要读完整个容器，耗时取决于磁盘 / 网络吞吐，所以按进度判活而不是给总超时
/// （BUG-3102）。输入可以是本地文件，也可以是 http(s) 远端流（[GraphicSubtitleInput]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_input.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';

/// 这条图形字幕轨能不能整轨解码（转文字 / 逐句时间表 / 按位图模糊）：PGS
/// （`hdmv_pgs_subtitle`）、VobSub（`dvd_subtitle`）、DVB（`dvb_subtitle`）。
bool graphicSubtitleTrackOcrSupportsCodec(String? codec) =>
    bitmapSubtitleCodecOf(codec) != null;

/// 整轨抽取的卡死判据：已处理媒体时间连续这么久不推进才算卡死（BUG-3102）。
///
/// 不是总时长：慢盘 / NAS 上整轨抽取可以合法地跑十几分钟，只要一直在推进就不该被杀。
const Duration kGraphicSubtitleExtractStallTimeout = Duration(seconds: 90);

/// 读轨头的 ffprobe 只探流头（不读全文件），给一个固定上限；远端输入要多算一次连接。
const Duration kGraphicSubtitleProbeTimeout = Duration(seconds: 60);

/// 抽轨的 ffmpeg 参数（不含观察式运行由后端前置的进度参数）。
///
/// 一次读文件、两个输出：
/// 1. `0:s:N`（相对序号）原样复制成载荷——PGS 为 `.sup` 段流，其它为单轨 TS
///    （[BitmapSubtitleCodec.muxer]；TS 带 `-muxdelay 0 -muxpreload 0`，见文件头）；
/// 2. 视频（可选，`?`：纯字幕容器没有视频流）+ 同一条字幕轨复制进 `-f null`——不落盘，
///    只为让 `-progress` 的已处理时间跟着文件读取位置**连续**推进。只映射字幕流时，
///    进度只在字幕包处跳一下，长段无对白就几分钟不动，按进度判活会误判卡死。拷贝视频包
///    不解码，额外开销只是内存里搬一次包（实测 7.5 GB / 30 分钟 mkv：单输出 11.1 s，
///    双输出 11.0 s，同为页缓存热态）。
List<String> buildGraphicSubtitleExtractArgs({
  required GraphicSubtitleInput input,
  required int streamIndex,
  required String outputPath,
  required BitmapSubtitleCodec codec,
}) => <String>[
  '-y',
  ...input.ffmpegInputArgs(),
  '-map',
  '0:s:$streamIndex',
  '-c',
  'copy',
  if (codec.muxer == 'mpegts') ...<String>[
    '-muxdelay',
    '0',
    '-muxpreload',
    '0',
  ],
  '-f',
  codec.muxer,
  outputPath,
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

/// 读轨头的 ffprobe 参数：只列这一条字幕流，`-show_data` 带出 extradata 的十六进制转储。
List<String> buildGraphicSubtitleProbeArgs({
  required GraphicSubtitleInput input,
  required int streamIndex,
}) => <String>[
  '-v',
  'error',
  '-print_format',
  'json',
  '-show_streams',
  '-show_data',
  '-select_streams',
  's:$streamIndex',
  ...input.ffmpegInputArgs(),
];

/// 旧的总时长预算，只给不支持观察式运行的后端兜底（测试替身等）。
Duration graphicSubtitleExtractTimeout(int fileBytes) {
  final int gb = fileBytes ~/ (1024 * 1024 * 1024);
  return Duration(seconds: (60 + gb * 8).clamp(60, 1200));
}

/// 探测第 [streamIndex] 条字幕轨的编码与 extradata。不是位图字幕 / 探测失败返回 null，
/// 原因交 [onFailure]。
Future<BitmapSubtitleTrackHeader?> probeGraphicSubtitleTrack({
  required GraphicSubtitleInput input,
  required int streamIndex,
  void Function(String summary)? onFailure,
  FfmpegBackend? backend,
  Duration timeout = kGraphicSubtitleProbeTimeout,
}) async {
  final _ProbeOutcome outcome = await _probeTrack(
    input,
    streamIndex,
    backend ?? resolveFfmpegBackend(),
    timeout,
  );
  if (outcome.failure case final String failure) onFailure?.call(failure);
  return outcome.header;
}

/// 探测结果：[header] 拿到了；或 [identified] 为真 = 流明确不是位图字幕；否则是
/// 探测本身失败（ffprobe 跑不起来 / 输出读不懂）。
typedef _ProbeOutcome = ({
  BitmapSubtitleTrackHeader? header,
  bool identified,
  String? failure,
});

Future<_ProbeOutcome> _probeTrack(
  GraphicSubtitleInput input,
  int streamIndex,
  FfmpegBackend backend,
  Duration timeout,
) async {
  final FfmpegRunResult result;
  try {
    result = await backend.runProbe(
      buildGraphicSubtitleProbeArgs(input: input, streamIndex: streamIndex),
      timeout,
    );
  } on ProcessException catch (e) {
    return (
      header: null,
      identified: false,
      failure: 'ffprobe launch failed: ${e.message}',
    );
  }
  if (!result.isSuccess) {
    return (
      header: null,
      identified: false,
      failure: 'probe: ${result.failureSummary}',
    );
  }
  String? codecName;
  final BitmapSubtitleTrackHeader? header = parseBitmapSubtitleProbe(
    result.output,
    codecName: (String? name) => codecName = name,
  );
  if (header != null) return (header: header, identified: true, failure: null);
  return (
    header: null,
    identified: codecName != null,
    failure: codecName == null
        ? 'probe: no subtitle stream s:$streamIndex'
        : 'probe: unsupported subtitle codec $codecName',
  );
}

/// 把 [input] 的第 [streamIndex] 条字幕轨（`0:s:N` 相对序号）原样抽成载荷 [outputPath]，
/// 并在它旁边写好头文件（[bitmapSubtitleTrackHeaderPath]），供
/// [readGraphicSubtitleTrackInBackground] 解码——抽轨还在写时也能读。
///
/// [codec] 是播放器报的 codec 名（如 mpv 的 `hdmv_pgs_subtitle`）。PGS 不需要 extradata，
/// 直接抽；其它编码（或 [codec] 不知道）先 ffprobe 读轨头：VobSub / DVB 探测失败但
/// [codec] 已知时仍照抽（VobSub 退回按不透明度猜灰阶、DVB 不按页过滤），[codec] 也不知道
/// 就失败。
///
/// 成功返回 true；失败 / 被取消时删掉载荷与头文件并返回 false，失败摘要交 [onFailure]
/// （取消不报失败）。后端支持观察式运行（[FfmpegWatchedRunner]，桌面 CLI 与移动端
/// ffmpeg-kit）时按进度判活（[kGraphicSubtitleExtractStallTimeout]），[onProgress] 报已读到
/// 的媒体时间，[cancel] 完成即强杀。[backend] 缺省为 [resolveFfmpegBackend]。
Future<bool> extractGraphicSubtitleTrack({
  required GraphicSubtitleInput input,
  required int streamIndex,
  required String outputPath,
  String? codec,
  void Function(String summary)? onFailure,
  void Function(Duration processed)? onProgress,
  Future<void>? cancel,
  FfmpegBackend? backend,
  Duration stallTimeout = kGraphicSubtitleExtractStallTimeout,
}) async {
  if (!input.isSupported) {
    onFailure?.call('unsupported input ${input.uri}');
    return false;
  }
  final File? local = input.isRemote ? null : File(input.uri);
  if (local != null && !local.existsSync()) {
    onFailure?.call('input missing');
    return false;
  }
  bool cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));
  final FfmpegBackend runner = backend ?? resolveFfmpegBackend();
  final BitmapSubtitleCodec? known = bitmapSubtitleCodecOf(codec);
  BitmapSubtitleTrackHeader? header = known == BitmapSubtitleCodec.pgs
      ? const BitmapSubtitleTrackHeader(codec: BitmapSubtitleCodec.pgs)
      : null;
  if (header == null) {
    final _ProbeOutcome probe = await _probeTrack(
      input,
      streamIndex,
      runner,
      kGraphicSubtitleProbeTimeout,
    );
    if (cancelled) return false;
    // 探测本身失败但调用方知道编码：照抽，只是少了 extradata（见上）。探测明确说
    // 这不是位图字幕时不抽。
    header =
        probe.header ??
        (known != null && !probe.identified
            ? BitmapSubtitleTrackHeader(codec: known)
            : null);
    if (header == null) {
      onFailure?.call(probe.failure ?? 'probe failed');
      return false;
    }
  }
  final File out = File(outputPath);
  final File headerFile = File(bitmapSubtitleTrackHeaderPath(outputPath));
  out.parent.createSync(recursive: true);
  // 头文件先于载荷落盘：边抽边读的读者拿到载荷时必须已经知道怎么解它。
  headerFile.writeAsStringSync(jsonEncode(header.toJson()), flush: true);
  final List<String> args = buildGraphicSubtitleExtractArgs(
    input: input,
    streamIndex: streamIndex,
    outputPath: outputPath,
    codec: header.codec,
  );
  final FfmpegRunResult result = switch (runner) {
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
      graphicSubtitleExtractTimeout(local?.lengthSync() ?? 0),
    ),
  };
  if (!cancelled &&
      result.isSuccess &&
      out.existsSync() &&
      out.lengthSync() > 0) {
    return true;
  }
  for (final File f in <File>[out, headerFile]) {
    if (!f.existsSync()) continue;
    try {
      f.deleteSync();
    } on FileSystemException {
      // 空壳文件，留给临时目录清理。
    }
  }
  if (!cancelled) onFailure?.call(result.failureSummary);
  return false;
}

/// [extractGraphicSubtitleTrack] 的本地文件入口（历史名：PGS 时代产物恒为 `.sup`）。
/// [videoPath] 也接受 http(s) 地址（不带请求头）；[supPath] 是载荷路径，内容格式随编码
/// 而定，读取一律用 [readGraphicSubtitleSupInBackground] / [readGraphicSubtitleTrackInBackground]。
Future<bool> extractGraphicSubtitleTrackToSup({
  required String videoPath,
  required int streamIndex,
  required String supPath,
  String? codec,
  void Function(String summary)? onFailure,
  void Function(Duration processed)? onProgress,
  Future<void>? cancel,
  FfmpegBackend? backend,
  Duration stallTimeout = kGraphicSubtitleExtractStallTimeout,
}) => extractGraphicSubtitleTrack(
  input: GraphicSubtitleInput(uri: videoPath),
  streamIndex: streamIndex,
  outputPath: supPath,
  codec: codec,
  onFailure: onFailure,
  onProgress: onProgress,
  cancel: cancel,
  backend: backend,
  stallTimeout: stallTimeout,
);

/// 在后台 isolate 渲染一条 cue 的像素（解 RLE + 合成是纯 CPU 活，不放 UI 线程）。
Future<BitmapSubtitleImage> renderGraphicSubtitleCueInBackground(
  BitmapSubtitleCue cue,
) => Isolate.run(cue.renderRgba);

/// 读抽轨载荷 [payloadPath] 的头文件；没有头文件时按内容认（`PG` 开头 = 旧式 `.sup`）。
/// 认不出返回 null。
BitmapSubtitleTrackHeader? readGraphicSubtitleTrackHeader(
  String payloadPath,
  Uint8List payload,
) {
  final File headerFile = File(bitmapSubtitleTrackHeaderPath(payloadPath));
  if (headerFile.existsSync()) {
    try {
      return BitmapSubtitleTrackHeader.fromJson(
        jsonDecode(headerFile.readAsStringSync()),
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
  if (payload.length >= 2 && payload[0] == 0x50 && payload[1] == 0x47) {
    return const BitmapSubtitleTrackHeader(codec: BitmapSubtitleCodec.pgs);
  }
  return null;
}

/// 在后台 isolate 解码抽轨载荷（[extractGraphicSubtitleTrack] 的产物；不存在 / 读不了 /
/// 认不出视为空）：边抽边识别时每隔几秒重读一次增长中的文件，解码不该占 UI 线程。
/// [complete] 为假 = 抽轨还在写，尾部没收完的包不交出。
Future<List<BitmapSubtitleCue>> readGraphicSubtitleTrackInBackground(
  String payloadPath, {
  bool complete = false,
}) async {
  try {
    final File payload = File(payloadPath);
    if (!await payload.exists()) return const <BitmapSubtitleCue>[];
    final Uint8List bytes = await payload.readAsBytes();
    final BitmapSubtitleTrackHeader? header = readGraphicSubtitleTrackHeader(
      payloadPath,
      bytes,
    );
    if (header == null) return const <BitmapSubtitleCue>[];
    return await Isolate.run(
      () => decodeBitmapSubtitlePayload(bytes, header, complete: complete),
    );
  } on FileSystemException {
    return const <BitmapSubtitleCue>[];
  }
}

/// [readGraphicSubtitleTrackInBackground] 的历史名（PGS 时代载荷恒为 `.sup`）。
Future<List<BitmapSubtitleCue>> readGraphicSubtitleSupInBackground(
  String supPath,
) => readGraphicSubtitleTrackInBackground(supPath);
