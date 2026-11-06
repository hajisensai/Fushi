import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart'
    show FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi/src/mining/web_mine_replay.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 网页播放器逐句重放采到的帧序列 + 回取的句子音频 → 一个中间片段（Matroska：MJPEG +
/// 原样拷贝的音频）。之后交给 `transcodeClipToCapture`，与浏览器扩展录制片段走同一条
/// 已验证的链路，按用户的图片模式出音画同步片段 / 动图。
///
/// 网页重放过去只截中点一张 PNG 当封面：用户图片模式选「视频片段 / 动图」时卡上也只有
/// 一张静图——重放明明完整播了一遍，画面却没留下来。

/// 第 [index] 帧的落盘文件名（concat 清单与写盘共用这一处）。
String webMineFrameName(int index) =>
    'frame_${index.toString().padLeft(4, '0')}.jpg';

/// 纯函数：concat 解复用器清单（ffconcat）。帧 i 在片段时间轴上的起点是
/// `atMs + audioLeadMs`（音频回取窗从 t0 前 lead 毫秒起），首帧从 0 起顶住开头，
/// 末帧撑到 [clipDurationMs]。concat 只认「后面还有条目」的 duration，所以末帧按惯例
/// 再列一次。
String buildWebMineFrameConcat({
  required List<WebMineReplayFrame> frames,
  required int audioLeadMs,
  required int clipDurationMs,
}) {
  final StringBuffer out = StringBuffer('ffconcat version 1.0\n');
  for (int i = 0; i < frames.length; i++) {
    final int start = i == 0 ? 0 : frames[i].atMs + audioLeadMs;
    final int end = i + 1 < frames.length
        ? frames[i + 1].atMs + audioLeadMs
        : clipDurationMs;
    // 至少一帧时长（25 fps），时间戳乱序 / 末帧越界时不写出 0 或负数。
    final int durationMs = end - start < 40 ? 40 : end - start;
    out
      ..writeln("file '${webMineFrameName(i)}'")
      ..writeln('duration ${(durationMs / 1000).toStringAsFixed(3)}');
  }
  if (frames.isNotEmpty) {
    out.writeln("file '${webMineFrameName(frames.length - 1)}'");
  }
  return out.toString();
}

/// 纯函数：合成中间片段的 ffmpeg 参数。画面按 25 fps 恒定帧率重采（片段导出器按
/// 时间窗裁，需要规整时间戳）、宽高取偶（H.264 / VP9 要求）；音频原样拷贝。
List<String> buildWebMineClipArgs({
  required String concatPath,
  required String? audioPath,
  required String outputPath,
}) => <String>[
  '-y',
  '-f',
  'concat',
  '-safe',
  '0',
  '-i',
  concatPath,
  if (audioPath != null) ...<String>['-i', audioPath],
  '-map',
  '0:v:0',
  if (audioPath != null) ...<String>['-map', '1:a:0'],
  '-vf',
  'fps=25,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuvj420p',
  '-c:v',
  'mjpeg',
  '-q:v',
  '3',
  if (audioPath != null) ...<String>['-c:a', 'copy'],
  outputPath,
];

/// 合成中间片段，返回 Matroska 字节；帧不足两帧 / ffmpeg 不可用或失败回 null
/// （调用方退回单张封面，不让整张卡失败）。
Future<Uint8List?> composeWebMineClip({
  required WebMineReplayCapture capture,
  required String audioExtension,
  required String tempDir,
}) async {
  if (capture.frames.length < 2) return null;
  final Directory dir = await Directory(tempDir).createTemp('web_mine_clip_');
  try {
    for (int i = 0; i < capture.frames.length; i++) {
      await File(
        p.join(dir.path, webMineFrameName(i)),
      ).writeAsBytes(capture.frames[i].bytes);
    }
    final String concatPath = p.join(dir.path, 'frames.ffconcat');
    await File(concatPath).writeAsString(
      buildWebMineFrameConcat(
        frames: capture.frames,
        audioLeadMs: capture.audioLeadMs,
        clipDurationMs: capture.clipDurationMs,
      ),
    );
    final Uint8List? audio = capture.audio;
    String? audioPath;
    if (audio != null) {
      audioPath = p.join(dir.path, 'audio.$audioExtension');
      await File(audioPath).writeAsBytes(audio);
    }
    final String outputPath = p.join(dir.path, 'clip.mkv');
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      buildWebMineClipArgs(
        concatPath: concatPath,
        audioPath: audioPath,
        outputPath: outputPath,
      ),
      const Duration(seconds: 60),
    );
    final File output = File(outputPath);
    if (result.returnCode != 0 || !output.existsSync()) {
      ErrorLogService.instance.log(
        'web_video.mineClip',
        'compose failed: ${result.failureSummary}',
      );
      return null;
    }
    return await output.readAsBytes();
  } catch (e, st) {
    ErrorLogService.instance.log('web_video.mineClip', e, st);
    return null;
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}
