/// 有声书 ASR 的 PCM 来源：经 [FfmpegBackend] 把任意音频文件（m4b/mp3/flac/…）
/// 解码成 16 kHz 单声道 float32 块流（[AsrPcmSource] 的 ffmpeg 实现）。
///
/// 设计要点（全部有实测数据支撑，见 `test/asr/asr_pcm_source_test.dart`）：
///
/// * **分块**：每块一次 ffmpeg，解码到临时文件再读回；块之间无重叠、无空洞。这样
///   10 小时的书不会在内存/磁盘里同时存 1 GB 的 PCM，也让上层能边解码边转录。
/// * **定位精度**：单独用输入端 `-ss`（放在 `-i` 前）**不是**样本精确的——mp3 靠 bit
///   reservoir 解码，跳到帧边界后第一帧缺上文，实测每块开头约 570~610 个样本
///   （≈36 ms）失真、峰值误差 4602/32768；AAC(m4b) 每块开头约 200 个样本失真（含
///   `-ss 0`），是 priming / 编辑列表裁剪在寻址后走了不同路径。单独用输出端 `-ss`
///   （放在 `-i` 后）逐样本精确，但要从文件头解码到目标点，10 小时书按 600 s 分块
///   是 O(n²) 的解码量。本实现取两者之长：输入端 `-ss` 粗跳到 **目标前
///   [kAsrPcmSeekPreRollSeconds] 秒**（让解码器有足够上文热身），再用输出端 `-ss`
///   精确裁掉这段预滚。实测 mp3(CBR/VBR/带封面)、m4b 与整段一次性解码逐样本一致
///   （|diff| = 0），仅 m4b **文件末尾**最后 ~240 个样本有 ≤ 12/32768 的差异（AAC 在
///   寻址后 EOF 冲洗的舍入不同，与预滚长度无关），对 ASR 无影响。
/// * **毫秒对齐**：所有 `-ss` / `-t` 以整毫秒表达（16 kHz 下 1 ms = 16 个样本，整数），
///   避免 62.5 µs 一个样本在 ffmpeg 的微秒时间基里被舍入。调用方给的 `startSample`
///   不是 16 的倍数时，向下取整到毫秒去寻址、多要 1 ms、在 Dart 侧丢掉多出的头部并
///   截到整块长度，块边界因此仍逐样本精确。
/// * **输出容器**：首选 `-f s16le` 裸 PCM。桌面捆绑的最小化 ffmpeg-min 至今
///   （n7.1.5，`third_party/ffmpeg-min/windows/ffmpeg.exe`）**没有** `s16le`/`wav`
///   muxer——`tool/ffmpeg-min/build-ffmpeg-min.sh` 的白名单已补上，但入库二进制要等
///   CI `ffmpeg-min.yml` 重建后另行 vendor。过渡期回退 `-f mov -c:a pcm_s16le`，
///   读回后按 ISO BMFF box 结构取 `mdat` payload（单音轨 pcm_s16le 的 mdat 就是连续
///   PCM，实测与 s16le 直出逐字节一致）。**清理条件：`ffmpeg-min` 重建带 `s16le,wav`
///   并 vendor 入库后，删除 [AsrPcmContainer.mov] 分支与 [extractMovMdatPayload]。**
/// * **能力探测**：`ffmpeg -muxers` / `-h muxer=s16le` 都写 **stdout**，而
///   [FfmpegBackend.run] 只收集 stderr（桌面 CLI 后端 drain 掉 stdout），无法据此判断。
///   故探测走真实工作：第一块先按 s16le 跑，ffmpeg 在打开输出阶段以
///   `Requested output format 's16le' is not known` 失败（stderr，尚未解码、代价可忽略）
///   即切到 mov 并重跑该块；结果缓存在实例上，之后的块与 [decode] 调用不再试探。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';

/// 输入端 `-ss` 的预滚秒数：粗跳到目标前这么多秒，让 mp3 bit reservoir / AAC 重叠加窗
/// 有足够上文热身，再由输出端 `-ss` 精确裁掉。实测 mp3 需 ≥ 1 帧（26 ms）+ 解码延迟，
/// AAC 需 1~2 帧；2 s 是宽裕值，相对 600 s 的块只多解码 0.3%。
const int kAsrPcmSeekPreRollSeconds = 2;

/// 16 kHz 下每毫秒的样本数（整数 16），是「毫秒对齐」策略成立的前提。
const int kAsrPcmSamplesPerMs = kAsrSampleRate ~/ 1000;

/// 每块 ffmpeg 的超时下限（秒）。
const int kAsrPcmChunkTimeoutFloorSeconds = 60;

/// 抛 [AsrPcmDecodeException] 时附带的 ffmpeg 日志尾部长度（真因在日志末尾，见
/// `extractFfmpegFailureReason` 的说明）。
const int kAsrPcmLogTailChars = 500;

/// PCM 块的落盘容器。见文件头「输出容器」。
enum AsrPcmContainer {
  /// `-f s16le`：裸小端 16 位 PCM，读回即样本。
  s16le,

  /// `-f mov -c:a pcm_s16le`：临时兼容层（捆绑 ffmpeg-min 缺 s16le/wav muxer），
  /// 读回后取 `mdat` payload。ffmpeg-min 重建带 `s16le,wav` 后删除。
  mov,
}

/// **纯函数**：ffmpeg 输出打开失败、且原因正是「没有 `s16le` muxer」的判据。
///
/// 匹配 libavformat 的固定文案 `Requested output format 's16le' is not known`
/// （stderr，error 级别，`-loglevel error` 下仍打印）。只认这一条：其它非零退出
/// （输入损坏、无音频流、权限）都不该触发容器切换。
bool isMissingS16leMuxerFailure(FfmpegRunResult result) {
  if (result.returnCode == null || result.returnCode == 0) return false;
  return RegExp(
    "Requested output format 's16le' is not known",
    caseSensitive: false,
  ).hasMatch(result.output);
}

/// **纯函数**：按块长度给宽裕超时——`chunkSeconds × 2 + 30 s`，下限
/// [kAsrPcmChunkTimeoutFloorSeconds]。解码到 PCM 远快于实时（mp3/AAC 百倍以上），
/// 2 倍块长已覆盖冷缓存 + 播放 IO 争用的慢盘。
Duration asrPcmChunkTimeout(int chunkSeconds) {
  final int seconds = math.max(
    kAsrPcmChunkTimeoutFloorSeconds,
    chunkSeconds * 2 + 30,
  );
  return Duration(seconds: seconds);
}

/// **纯函数**：构造解码一块 PCM 的 ffmpeg 参数（无 IO，可单测）。
///
/// * [startMs] 块起点（毫秒，相对文件起点）；[durationMs] 块长（毫秒）。
/// * 输入端 `-ss max(0, startMs - preRoll)`（整秒，`-i` 之前）粗跳；输出端
///   `-ss (startMs - 输入跳点)`（`-i` 之后）精裁——两者都为 0 时省略。
/// * `-map 0:a:0` + `-vn -sn -dn`：只取第一条音轨。很多有声书 mp3/m4b 带封面图
///   （attached_pic 视频流），不排除会被 mov muxer 当视频流封进去（或 s16le muxer
///   直接拒绝多流），三个 `-xn` 兜住没被 `-map` 排除的字幕/数据流。
/// * `-ac 1 -ar 16000 -c:a pcm_s16le`：下混单声道、重采样 16 kHz、16 位小端。
/// * `-f s16le` / `-f mov`：见 [AsrPcmContainer]。
List<String> buildAsrPcmChunkArgs({
  required String inputPath,
  required String outputPath,
  required int startMs,
  required int durationMs,
  required AsrPcmContainer container,
  int preRollSeconds = kAsrPcmSeekPreRollSeconds,
}) {
  assert(startMs >= 0 && durationMs > 0);
  final int preRollMs = math.max(0, preRollSeconds) * 1000;
  // 输入端跳点取整秒（预滚本身就是粗跳，整秒最稳），不为负。
  final int inputSeekMs = math.max(0, (startMs - preRollMs) ~/ 1000 * 1000);
  final int outputSeekMs = startMs - inputSeekMs;
  return <String>[
    '-hide_banner',
    '-nostats',
    '-loglevel',
    'error',
    '-y',
    if (inputSeekMs > 0) ...<String>['-ss', _formatMs(inputSeekMs)],
    '-i',
    inputPath,
    if (outputSeekMs > 0) ...<String>['-ss', _formatMs(outputSeekMs)],
    '-t',
    _formatMs(durationMs),
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-ac',
    '1',
    '-ar',
    '$kAsrSampleRate',
    '-c:a',
    'pcm_s16le',
    '-f',
    container == AsrPcmContainer.s16le ? 's16le' : 'mov',
    outputPath,
  ];
}

/// 毫秒 → ffmpeg 时间串（秒，固定 3 位小数，如 `12.345`）。
String _formatMs(int ms) => (ms / 1000).toStringAsFixed(3);

/// **纯函数**：构造 ffprobe 时长探测参数（`format.duration` 以 JSON 写 stdout）。
List<String> buildAsrProbeDurationArgs({required String inputPath}) {
  return <String>[
    '-v',
    'quiet',
    '-print_format',
    'json',
    '-show_entries',
    'format=duration',
    inputPath,
  ];
}

/// **纯函数**：从 `ffprobe -show_entries format=duration -print_format json` 的 stdout
/// 解析时长（毫秒，四舍五入）。缺字段 / 非数字 / 非 JSON / 非正值 → null（不抛）。
int? parseFfprobeDurationMs(String probeStdout) {
  final String trimmed = probeStdout.trim();
  if (trimmed.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? format = decoded['format'];
  if (format is! Map) return null;
  final Object? duration = format['duration'];
  final double? seconds = switch (duration) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return (seconds * 1000).round();
}

/// **纯函数**：在 ISO BMFF（QuickTime/MP4）字节流里找第一个 `mdat` box，返回其
/// payload 视图（不拷贝）。
///
/// box 头：32 位大端 size + 4 字节 type。`size == 1` 时紧跟 64 位 `largesize`
/// （movenc 在 mdat 超 4 GB 时改写成这种；它预留的 `wide` 占位 box 就是为此），
/// `size == 0` 表示延伸到文件尾。ffmpeg 的 mov 输出是 `ftyp` `wide` `mdat` … `moov`
/// （moov 在尾部），逐个 box 跳到 mdat 即可；单音轨 pcm_s16le 的 mdat payload 就是
/// 连续的 s16le 样本。找不到 mdat / box 头越界 / size 小于头长 → [FormatException]。
Uint8List extractMovMdatPayload(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  final int length = bytes.length;
  int offset = 0;
  while (offset + 8 <= length) {
    int size = view.getUint32(offset);
    int headerLength = 8;
    final String type = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
      allowInvalid: true,
    );
    if (size == 1) {
      if (offset + 16 > length) {
        throw FormatException(
          'truncated largesize box header at offset $offset',
        );
      }
      final int large = view.getUint64(offset + 8);
      // 大于 Dart int 安全范围或超出文件长度的 largesize 都按到文件尾处理不了，直接判坏。
      if (large < 16 || large > length - offset) {
        throw FormatException(
          'largesize $large out of range at offset $offset (file $length)',
        );
      }
      size = large;
      headerLength = 16;
    } else if (size == 0) {
      size = length - offset;
    }
    if (size < headerLength) {
      throw FormatException(
        'box "$type" size $size < header at offset $offset',
      );
    }
    if (type == 'mdat') {
      final int end = math.min(offset + size, length);
      return Uint8List.sublistView(bytes, offset + headerLength, end);
    }
    offset += size;
  }
  throw const FormatException('no mdat box found');
}

/// **纯函数**：s16le 小端字节 → float32（`/32768`，范围 [-1, 1)）。奇数尾字节丢弃。
Float32List pcmS16leToFloat32(Uint8List bytes) {
  final int count = bytes.length ~/ 2;
  final Float32List out = Float32List(count);
  // ByteData 视图不要求 2 字节对齐（mdat payload 的偏移未必是偶数），逐样本读。
  final ByteData view = ByteData.sublistView(bytes, 0, count * 2);
  for (int i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// [AsrPcmSource] 的 ffmpeg 实现。见文件头设计说明。
class FfmpegAsrPcmSource implements AsrPcmSource {
  /// [backend] 缺省为 [resolveFfmpegBackend]（桌面 CLI / 移动端 ffmpeg-kit，按平台
  /// 分流，惰性取以免构造期就固定后端）；[tempDir] 缺省 [Directory.systemTemp]，每次
  /// [decode] 在其下 `createTemp('fushi_asr_pcm_')`。
  FfmpegAsrPcmSource({
    FfmpegBackend? backend,
    Directory? tempDir,
    this.preRollSeconds = kAsrPcmSeekPreRollSeconds,
  }) : _backend = backend,
       _tempDir = tempDir ?? Directory.systemTemp;

  final FfmpegBackend? _backend;
  final Directory _tempDir;

  /// 输入端预滚秒数（见 [kAsrPcmSeekPreRollSeconds]）。
  final int preRollSeconds;

  /// 已探明可用的输出容器；null 表示还没试过（首块按 s16le 试探）。
  AsrPcmContainer? _container;

  FfmpegBackend get _resolvedBackend => _backend ?? resolveFfmpegBackend();

  /// 当前已探明的输出容器（测试断言用；生产代码不需要读）。
  @visibleForTesting
  AsrPcmContainer? get resolvedContainer => _container;

  @override
  Future<int?> probeDurationMs(String audioPath) async {
    if (!File(audioPath).existsSync()) return null;
    try {
      final FfmpegRunResult result = await _resolvedBackend.runProbe(
        buildAsrProbeDurationArgs(inputPath: audioPath),
        const Duration(seconds: 30),
      );
      if (result.returnCode != 0) {
        debugPrint(
          '[asr-pcm] ffprobe duration failed for "$audioPath": '
          '${result.failureSummary}',
        );
        return null;
      }
      return parseFfprobeDurationMs(result.output);
    } on ProcessException catch (e) {
      // ffprobe 不在（桌面未捆绑且 PATH 没有）：探不出，调用方按未知时长处理。
      debugPrint(
        '[asr-pcm] ffprobe unavailable: '
        '${describeFfmpegProcessException(e)}',
      );
      return null;
    }
  }

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    if (startSample < 0) {
      throw ArgumentError.value(startSample, 'startSample', 'must be >= 0');
    }
    if (chunkSeconds <= 0) {
      throw ArgumentError.value(chunkSeconds, 'chunkSeconds', 'must be > 0');
    }
    if (!File(audioPath).existsSync()) {
      throw AsrPcmDecodeException(audioPath, 'input file does not exist');
    }
    final Directory work = await _tempDir.createTemp('fushi_asr_pcm_');
    try {
      final int chunkSamples = chunkSeconds * kAsrSampleRate;
      // startSample 不是整毫秒时：寻址向下取整到毫秒，多要 1 ms，丢掉头部多出的样本。
      // 块长是整秒（16 的倍数），所以每块的余数相同。
      final int dropLeading = startSample % kAsrPcmSamplesPerMs;
      final int durationMs = chunkSeconds * 1000 + (dropLeading > 0 ? 1 : 0);
      int blockStart = startSample;
      int index = 0;
      while (true) {
        final Float32List raw = await _decodeBlock(
          audioPath: audioPath,
          workDir: work,
          index: index,
          startMs: blockStart ~/ kAsrPcmSamplesPerMs,
          durationMs: durationMs,
        );
        Float32List samples = raw;
        if (dropLeading > 0) {
          samples = raw.length > dropLeading
              ? Float32List.sublistView(raw, dropLeading)
              : Float32List(0);
        }
        if (samples.length > chunkSamples) {
          samples = Float32List.sublistView(samples, 0, chunkSamples);
        }
        // 契约：某块 0 样本即文件末尾（超出 EOF 的 -ss 让 ffmpeg 正常退出、输出为空）。
        if (samples.isEmpty) break;
        yield AsrPcmChunk(startSample: blockStart, samples: samples);
        blockStart += chunkSamples;
        index++;
      }
    } finally {
      // 取消 / 异常 / 正常结束都走这里：块文件读完即删，目录整体兜底清理。
      try {
        if (work.existsSync()) work.deleteSync(recursive: true);
      } catch (e) {
        debugPrint('[asr-pcm] failed to clean temp dir ${work.path}: $e');
      }
    }
  }

  /// 解码一块，返回 float32 样本（可能为空 = EOF）。失败抛 [AsrPcmDecodeException]。
  Future<Float32List> _decodeBlock({
    required String audioPath,
    required Directory workDir,
    required int index,
    required int startMs,
    required int durationMs,
  }) async {
    final AsrPcmContainer container = _container ?? AsrPcmContainer.s16le;
    final String ext = container == AsrPcmContainer.s16le ? 'pcm' : 'mov';
    final File output = File(
      '${workDir.path}${Platform.pathSeparator}'
      'chunk_$index.$ext',
    );
    final Duration timeout = asrPcmChunkTimeout((durationMs / 1000).ceil());
    final FfmpegRunResult result;
    try {
      result = await _resolvedBackend.run(
        buildAsrPcmChunkArgs(
          inputPath: audioPath,
          outputPath: output.path,
          startMs: startMs,
          durationMs: durationMs,
          container: container,
          preRollSeconds: preRollSeconds,
        ),
        timeout,
      );
    } on ProcessException catch (e) {
      _deleteQuietly(output);
      throw AsrPcmDecodeException(audioPath, describeFfmpegProcessException(e));
    }
    try {
      if (result.returnCode == null) {
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg timed out after ${timeout.inSeconds}s decoding block $index '
          '(startMs=$startMs, durationMs=$durationMs)',
        );
      }
      if (result.returnCode != 0) {
        if (_container == null &&
            container == AsrPcmContainer.s16le &&
            isMissingS16leMuxerFailure(result)) {
          // 临时兼容层（见文件头）：捆绑 ffmpeg-min 没有 s16le muxer → 切 mov 重跑本块。
          // 只在「还没探明」时切一次；探明后缓存在实例上。
          _container = AsrPcmContainer.mov;
          debugPrint(
            '[asr-pcm] ffmpeg has no s16le muxer '
            '(executable=${result.executable}); falling back to mov container',
          );
          _deleteQuietly(output);
          return _decodeBlock(
            audioPath: audioPath,
            workDir: workDir,
            index: index,
            startMs: startMs,
            durationMs: durationMs,
          );
        }
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg exit ${result.returnCode} decoding block $index '
          '(startMs=$startMs, durationMs=$durationMs, '
          'executable=${result.executable}); log tail: '
          '${_logTail(result.output)}',
        );
      }
      _container ??= container;
      if (!output.existsSync()) {
        throw AsrPcmDecodeException(
          audioPath,
          'ffmpeg exit 0 but produced no output file for block $index '
          '(startMs=$startMs); log tail: ${_logTail(result.output)}',
        );
      }
      final Uint8List bytes = await output.readAsBytes();
      final Uint8List pcm;
      switch (container) {
        case AsrPcmContainer.s16le:
          pcm = bytes;
        case AsrPcmContainer.mov:
          try {
            pcm = extractMovMdatPayload(bytes);
          } on FormatException catch (e) {
            throw AsrPcmDecodeException(
              audioPath,
              'mov fallback output for block $index is not parseable '
              '(${bytes.length} bytes): ${e.message}',
            );
          }
      }
      return pcmS16leToFloat32(pcm);
    } finally {
      _deleteQuietly(output);
    }
  }

  static String _logTail(String output) {
    final String trimmed = output.trim();
    if (trimmed.length <= kAsrPcmLogTailChars) return trimmed;
    return trimmed.substring(trimmed.length - kAsrPcmLogTailChars);
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      debugPrint('[asr-pcm] failed to delete ${file.path}: $e');
    }
  }
}
