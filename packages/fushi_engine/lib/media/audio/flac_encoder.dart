/// 无损音频 → FLAC 的唯一编码入口：音频 CD 抓轨与 AIFF 有声书落盘共用。
///
/// 只用随包 ffmpeg 的 `flac` 编码器 / 封装器（ffmpeg-min 与移动端 ffmpeg-kit 都带），
/// 输入是任何它能解的 PCM 容器（WAV / AIFF）。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart' show AudiobookStorage;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

/// FLAC 编码失败（ffmpeg 退出非零或没产出文件）。[message] 是 ffmpeg 的最后一行输出。
class FlacEncodeException implements Exception {
  const FlacEncodeException(this.message);

  final String message;

  @override
  String toString() => 'FlacEncodeException: $message';
}

/// 编码上限：基础 10 分钟，再按输入大小每 MB 加 1 秒（10 小时的 AIFF 约 6 GB，
/// 手机上编码十几分钟）。只防 ffmpeg 卡死，正常编码远到不了。
Duration flacEncodeTimeoutFor(int inputBytes) =>
    Duration(minutes: 10, seconds: inputBytes ~/ (1 << 20));

/// [input] → [output] FLAC，[metadata] 逐条写成 `-metadata k=v`（不写则沿用输入的标签）。
///
/// 先写 `<output>.part`，成功才改名到位：中途失败 / 被杀只会留下 `.part`（失败时
/// 当场删掉），所以 [output] 存在就等于编码完整。
Future<void> encodeFlacFile(
  FfmpegBackend ffmpeg, {
  required String input,
  required String output,
  Map<String, String> metadata = const <String, String>{},
}) async {
  final File part = File('$output.part');
  final FfmpegRunResult result = await ffmpeg.run(<String>[
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-i',
    input,
    '-map',
    '0:a:0',
    '-c:a',
    'flac',
    for (final MapEntry<String, String> tag in metadata.entries) ...<String>[
      '-metadata',
      '${tag.key}=${tag.value}',
    ],
    '-f',
    'flac',
    part.path,
  ], flacEncodeTimeoutFor(await File(input).length()));
  if (result.returnCode != 0 || !part.existsSync() || part.lengthSync() == 0) {
    if (part.existsSync()) part.deleteSync();
    final String detail = result.output.trim().split('\n').last;
    throw FlacEncodeException('exit ${result.returnCode}: $detail');
  }
  part.renameSync(output);
}

/// 把 [encodeFlacFile] 装进 [AudiobookStorage.flacTranscoder]（AIFF 有声书落盘转
/// FLAC）。app（`installEngineHostBindings`）与服务端（`installServerHostBindings`）
/// 各调一次；ffmpeg 后端每次编码时才解析，所以装配顺序不受 ffmpeg 路径覆盖影响。
void installAudiobookFlacTranscoder() {
  AudiobookStorage.flacTranscoder = (String source, String flacPath) =>
      encodeFlacFile(resolveFfmpegBackend(), input: source, output: flacPath);
}
