import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_clip_subtitle.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

// BUG-835：`extractFfmpegFailureReason` 的正准实现搬到 ffmpeg_backend.dart（最底层、
// 无依赖），供共享的 [FfmpegRunResult.failureSummary] 与音频/视频两路径统一复用。此处
// 再导出，保持既有 `import '.../video_clip_exporter.dart' show extractFfmpegFailureReason`
// 调用点与测试不变。
export 'package:hibiki/src/media/video/ffmpeg_backend.dart'
    show extractFfmpegFailureReason;

enum VideoClipExportFailure {
  invalidRange,
  inputMissing,
  ffmpegUnavailable,
  ffmpegFailed,
  outputMissing,
}

class VideoClipExportResult {
  const VideoClipExportResult._({
    required this.outputPath,
    required this.failure,
    this.detail,
    this.subtitleTrackCount = 0,
  });

  const VideoClipExportResult.success(
    String outputPath, {
    int subtitleTrackCount = 0,
  }) : this._(
          outputPath: outputPath,
          failure: null,
          subtitleTrackCount: subtitleTrackCount,
        );

  const VideoClipExportResult.failure(
    VideoClipExportFailure failure, {
    String? detail,
  }) : this._(outputPath: null, failure: failure, detail: detail);

  final String? outputPath;
  final VideoClipExportFailure? failure;
  final String? detail;

  /// 实际封进输出文件的字幕流条数（0 = 没带字幕：区间内无字幕、容器封不下，
  /// 或带字幕那次失败后降级重试成功）。
  final int subtitleTrackCount;

  bool get isSuccess => outputPath != null && failure == null;
}

/// 纯函数：拼 `-map` 段，copy 与 reencode 两条裁剪路径共用（唯一真相源）。
///
/// [subtitleInputCount] 是**额外字幕输入文件**的条数（输入下标从 1 起，0 是源视频）。
///
/// 关键约束：ffmpeg 一旦见到任何 `-map`，就**完全关闭**自动流选择。所以带字幕时
/// 必须把 video / audio 也显式 map 出来，否则输出只剩字幕、视频音频全丢；反过来
/// 不带字幕且 [explicitAudio] 未知时必须一个 `-map` 都不给，让 ffmpeg 自己选默认轨
/// （这是加字幕之前的既有行为，原样保留）。
@visibleForTesting
List<String> buildClipStreamMapArgs({
  required int? explicitAudio,
  required int subtitleInputCount,
}) {
  // 尾随 '?'：当 0:a:N 在真实 ffmpeg 流里越界（mpv 轨序号与 ffmpeg 0:a:N 不一致，
  // 挂外挂音频/枚举顺序不同时发生），ffmpeg 降级回退默认轨而非
  // 'Stream map matches no streams' 硬失败（BUG-345）。
  if (subtitleInputCount <= 0) {
    if (explicitAudio == null) return const <String>[];
    return <String>['-map', '0:v:0', '-map', '0:a:$explicitAudio?'];
  }
  return <String>[
    '-map',
    '0:v:0',
    '-map',
    // explicitAudio 已知就只带用户正在听的那条；未知时带**全部**音轨（'0:a?'）而不是
    // 赌 `0:a:0`——多音轨番剧里默认轨常常不是 0，赌错就导出了错误语言的音频。
    explicitAudio != null ? '0:a:$explicitAudio?' : '0:a?',
    for (int i = 0; i < subtitleInputCount; i++) ...<String>[
      '-map',
      '${i + 1}:s:0',
    ],
  ];
}

/// 纯函数：拼「流复制」裁剪命令（`-c copy`，瞬时无损）。
///
/// [subtitlePaths] 是已裁好、时间轴已平移到片段起点为 0 的 SRT 文件（主字幕、副字幕
/// 各一条，见 [buildClipSrtContent]）；[subtitleCodec] 由 [resolveClipSubtitleCodec]
/// 按输出容器给出。两者任一为空就退回原来的 `-sn` 纯视频音频命令，一个参数都不变
/// ——加字幕不能以破坏既有导出为代价。
List<String> buildFfmpegVideoClipExportArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  List<String> subtitlePaths = const <String>[],
  String? subtitleCodec,
}) {
  final double startSeconds = startMs / 1000.0;
  final double durationSeconds = (endMs - startMs) / 1000.0;
  final int? explicitAudio = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  final bool withSubtitles = subtitlePaths.isNotEmpty && subtitleCodec != null;
  final int subtitleInputCount = withSubtitles ? subtitlePaths.length : 0;

  return <String>[
    '-hide_banner',
    '-y',
    // `-ss` / `-t` 是 per-input 选项，只作用于紧随其后的那个 `-i`：源视频按区间 seek，
    // 字幕输入**不带**这两个选项——它已经被 buildClipSrtContent 裁好并平移到 0，
    // 再 seek 一次会把时间轴推成负的、字幕整体消失。
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    if (withSubtitles)
      for (final String path in subtitlePaths) ...<String>['-i', path],
    ...buildClipStreamMapArgs(
      explicitAudio: explicitAudio,
      subtitleInputCount: subtitleInputCount,
    ),
    // 不带字幕时 `-sn` 丢掉源内嵌字幕；带字幕时显式 map 已保证只有我们这几条进输出，
    // 此时绝不能加 `-sn`——它会把刚 map 进来的字幕流一起禁掉。
    if (!withSubtitles) '-sn',
    '-dn',
    '-c',
    'copy',
    // 字幕流单独指定编码：Matroska 能直接 copy SRT，mp4/mov 系必须转 mov_text。
    if (withSubtitles) ...<String>['-c:s', subtitleCodec],
    '-avoid_negative_ts',
    'make_zero',
    outputPath,
  ];
}

/// 纯函数：拼「重编码」裁剪命令（libx264 视频 + aac 音频 → mp4）。
///
/// 当 [buildFfmpegVideoClipExportArgs] 的 `-c copy` 因源编码装不进 mp4 容器而失败
/// （vc1/wmv/mpeg2/rv/theora 视频、dts/truehd/pcm 音频等，或流复制不兼容）时用它兜底。
/// 桌面精简 ffmpeg（`tool/ffmpeg-min`）为此专门编入 libx264（`--enable-gpl`，TODO-1257），
/// mp4 muxer 也在白名单里；重编码后任何可解码的源都能落成通用可播的 .mp4，杜绝
/// 「输出跟随源容器 → matroska/webm muxer 缺失 → exit -22 EINVAL」（BUG-917/460）。
///
/// `-pix_fmt yuv420p` 把 10-bit / 4:2:2 等源统一降到 8-bit 4:2:0（浏览器/播放器通吃）；
/// `-movflags +faststart` 把 moov 前移便于边下边播。音频选择沿用与 copy 路径同一套
/// [resolveAudioMapIndex] 边界判定（越界回退默认轨，尾随 `?` 兜底，BUG-345）。
///
/// 字幕参数与 copy 路径同义（[subtitlePaths] / [subtitleCodec]）：字幕**不**参与
/// 重编码，仍是独立软字幕流，只是跟着这一轮一起 mux 进去——否则 copy 轮失败降级到
/// 重编码后，用户会拿到一个没有字幕的片段。
List<String> buildFfmpegVideoClipReencodeArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  List<String> subtitlePaths = const <String>[],
  String? subtitleCodec,
}) {
  final double startSeconds = startMs / 1000.0;
  final double durationSeconds = (endMs - startMs) / 1000.0;
  final int? explicitAudio = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  final bool withSubtitles = subtitlePaths.isNotEmpty && subtitleCodec != null;
  final int subtitleInputCount = withSubtitles ? subtitlePaths.length : 0;
  return <String>[
    '-hide_banner',
    '-y',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    if (withSubtitles)
      for (final String path in subtitlePaths) ...<String>['-i', path],
    ...buildClipStreamMapArgs(
      explicitAudio: explicitAudio,
      subtitleInputCount: subtitleInputCount,
    ),
    if (!withSubtitles) '-sn',
    '-dn',
    if (withSubtitles) ...<String>['-c:s', subtitleCodec],
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-avoid_negative_ts',
    'make_zero',
    '-movflags',
    '+faststart',
    outputPath,
  ];
}

/// 纯函数：把请求的 [audioStreamIndex] 归一成「实际拼进 `-map 0:a:N` 的下标」，
/// 否则返回 null（不加 `-map`，用 ffmpeg 默认音频选择）。两条 ffmpeg 裁剪路径
/// （视频片段导出 / 桌面音频裁剪）共用这套边界判定（BUG-345）。
///
/// 归一规则：
/// - index 为 null 或负数 → null（跟随默认）。
/// - [audioStreamCount] 已知且 `index >= count` → null。即便有尾随 `?` 兜底硬失败，
///   越界的显式 `-map` 也会让 ffmpeg 静默挑错轨/丢音；越界时干脆不加 `-map`，
///   回退默认轨更可预测。count 为 null（未知真实流数）时不在此层拦，交给 `?` 兜底。
/// - 其余 → index 原样。
int? resolveAudioMapIndex({
  required int? audioStreamIndex,
  required int? audioStreamCount,
}) {
  if (audioStreamIndex == null || audioStreamIndex < 0) return null;
  if (audioStreamCount != null && audioStreamIndex >= audioStreamCount) {
    return null;
  }
  return audioStreamIndex;
}

/// 一「轮」裁剪的结果：快路径 `-c copy` + 失败后的重编码兜底。
class _ClipAttempt {
  const _ClipAttempt(this.produced, this.copy, this.reencode);

  final bool produced;
  final FfmpegRunResult copy;

  /// copy 轮直接成功时为 null（没跑重编码）。
  final FfmpegRunResult? reencode;

  /// 最后实际跑的那轮——失败诊断取它的 stderr。
  FfmpegRunResult get last => reencode ?? copy;
}

/// 导出片段。[subtitleContents] 是已裁剪、时间轴已平移到片段起点为 0 的 SRT 文本
/// （主字幕、副字幕各一条，由 [buildClipSrtContent] 生成）；为空、或输出容器封不下
/// 文本字幕（[resolveClipSubtitleCodec] 返回 null）时自动退回纯视频音频导出。
Future<VideoClipExportResult> exportVideoClipViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  List<String> subtitleContents = const <String>[],
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final File output = File(outputPath);
  if (endMs <= startMs) {
    _deleteIfPresent(output);
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.invalidRange,
    );
  }
  if (!File(inputPath).existsSync()) {
    _deleteIfPresent(output);
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.inputMissing,
    );
  }

  final String? subtitleCodec = resolveClipSubtitleCodec(outputPath);
  final List<String> wanted = subtitleContents
      .where((String s) => s.trim().isNotEmpty)
      .toList(growable: false);
  Directory? subtitleDir;

  try {
    output.parent.createSync(recursive: true);
    final FfmpegBackend resolved = backend ?? resolveFfmpegBackend();
    bool produced(FfmpegRunResult r) =>
        r.isSuccess && output.existsSync() && output.lengthSync() > 0;

    List<String> subtitlePaths = const <String>[];
    if (wanted.isNotEmpty && subtitleCodec != null) {
      subtitleDir = await _writeTempSubtitleFiles(wanted);
      if (subtitleDir != null) {
        subtitlePaths = List<String>.generate(
          wanted.length,
          (int i) => _tempSubtitlePath(subtitleDir!, i),
          growable: false,
        );
      }
    }

    /// 跑完整一轮：快路径 `-c copy`（瞬时、无损，多数 h264/hevc + aac 源直接成功），
    /// 失败则重编码 libx264 + aac 兜底（源编码装不进 mp4：vc1/wmv/dts/pcm… 桌面
    /// ffmpeg-min 专为此编入 libx264，TODO-1257；杜绝 BUG-917 的 exit -22）。
    /// 输出恒 `.mp4`——绝不跟随源容器扩展名，否则 mkv/webm 源会选中 ffmpeg-min
    /// 白名单里不存在的 matroska muxer。
    Future<_ClipAttempt> attempt(List<String> subs) async {
      final FfmpegRunResult copyResult = await resolved.run(
        buildFfmpegVideoClipExportArgs(
          inputPath: inputPath,
          startMs: startMs,
          endMs: endMs,
          outputPath: outputPath,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
          subtitlePaths: subs,
          subtitleCodec: subtitleCodec,
        ),
        timeout,
      );
      if (produced(copyResult)) return _ClipAttempt(true, copyResult, null);
      _deleteIfPresent(output);

      final FfmpegRunResult reencodeResult = await resolved.run(
        buildFfmpegVideoClipReencodeArgs(
          inputPath: inputPath,
          startMs: startMs,
          endMs: endMs,
          outputPath: outputPath,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
          subtitlePaths: subs,
          subtitleCodec: subtitleCodec,
        ),
        timeout,
      );
      final bool ok = produced(reencodeResult);
      if (!ok) _deleteIfPresent(output);
      return _ClipAttempt(ok, copyResult, reencodeResult);
    }

    _ClipAttempt result = await attempt(subtitlePaths);
    int subtitleTrackCount = result.produced ? subtitlePaths.length : 0;

    // 带字幕的整轮（copy + 重编码）都失败 → 去掉字幕再跑一整轮。字幕封装依赖的是
    // 不可控的外部 ffmpeg 能力：容器只能按扩展名猜，而用户机上的 ffmpeg 未必编入
    // movtext 编码器，缺它会直接 'Unknown encoder'。宁可导出一个没字幕的片段，也不
    // 能让「加字幕」这个增强把原本能成功的导出变成失败。
    //
    // ⚠️ 这条降级会**静默**吞掉字幕，所以它掩盖过一次真 bug：随包的精简 ffmpeg 自己
    // 就漏编了 movtext（BUG-1058），桌面端每次导出都走到这里，用户只看到"导出成功但
    // 没字幕"。入库二进制已重新 vendor 修好，且由
    // hibiki/test/tools/ffmpeg_min_vendored_recipe_guard_test.dart 守住不再漂移；
    // 降级本身保留，因为它要兜的是用户自带的第三方 ffmpeg，那个仍然不可控。
    // 失败原因照常写进错误日志（下方 ErrorLogService），排查时先看那条。
    if (!result.produced && subtitlePaths.isNotEmpty) {
      ErrorLogService.instance.log(
        'VideoClipExport',
        'subtitle mux failed, retrying without subtitles: '
            '${result.last.failureSummary}',
      );
      result = await attempt(const <String>[]);
      subtitleTrackCount = 0;
    }

    if (result.produced) {
      return VideoClipExportResult.success(
        outputPath,
        subtitleTrackCount: subtitleTrackCount,
      );
    }
    if (result.last.isSuccess) {
      return const VideoClipExportResult.failure(
        VideoClipExportFailure.outputMissing,
      );
    }
    // C 修（BUG-345）：把两轮 ffmpeg 的真实失败原因（退出码 + stderr）写进错误日志，
    // 与 desktop_audio_clipper 的 _reportFfmpegFailure 对齐——否则失败是黑盒，真机只
    // 看到一句固定文案，看不到「Stream map matches no streams」/「Invalid argument」。
    ErrorLogService.instance
        .log('VideoClipExport', 'stream-copy: ${result.copy.failureSummary}');
    final FfmpegRunResult? reencode = result.reencode;
    if (reencode != null) {
      ErrorLogService.instance
          .log('VideoClipExport', 'reencode: ${reencode.failureSummary}');
    }
    // TODO-910：detail 回传 stderr **尾段**抽出的真因行（最后实际跑的那轮），而非
    // 全量 stderr。ffmpeg stderr 开头恒是 `Input #0, ...: Metadata: encoder :...`
    // 输入 banner，真正的失败行（Conversion failed / matches no streams / Could not
    // open ...）出现在末尾；调用方拼 OSD 时绝不能从头截断，否则只显示 banner。
    final String reason = extractFfmpegFailureReason(result.last.output);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: reason.isEmpty ? null : reason,
    );
  } on ProcessException catch (e, stack) {
    _deleteIfPresent(output);
    ErrorLogService.instance.log(
      'VideoClipExport',
      describeFfmpegProcessException(e),
      stack,
    );
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegUnavailable,
      detail: e.message,
    );
  } catch (e, stack) {
    _deleteIfPresent(output);
    ErrorLogService.instance.log('VideoClipExport', e, stack);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: e.toString(),
    );
  } finally {
    // 临时 SRT 只在 ffmpeg 读取期间存在；无论成功、失败还是抛异常都必须清掉，
    // 否则每导出一次就在系统临时目录留一份字幕垃圾。
    if (subtitleDir != null) {
      try {
        await subtitleDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 把 SRT 文本写进一个独占的临时目录，返回该目录；写不出来（磁盘满/权限）返回 null，
/// 调用方据此**继续无字幕导出**——字幕落盘失败不该让整个片段导出失败。
Future<Directory?> _writeTempSubtitleFiles(List<String> contents) async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('hibiki_clip_sub');
    for (int i = 0; i < contents.length; i++) {
      // flush: true——ffmpeg 进程随后立刻读这些文件，不能停在 OS 写缓冲里。
      // encoding: utf8 且不写 BOM：ffmpeg 的 srt demuxer 默认按 UTF-8 解析。
      await File(_tempSubtitlePath(dir, i))
          .writeAsString(contents[i], encoding: utf8, flush: true);
    }
    return dir;
  } catch (e, stack) {
    ErrorLogService.instance.log('VideoClipExport', e, stack);
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    return null;
  }
}

String _tempSubtitlePath(Directory dir, int index) =>
    p.join(dir.path, 'clip_sub_$index.srt');

void _deleteIfPresent(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
