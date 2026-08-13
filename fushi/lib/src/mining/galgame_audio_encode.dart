import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

/// galgame 一键制卡（docs/specs/galgame-mining）音频编码：把 loopback 抓到的**裸 PCM**
/// 切片编码成 Anki 能播的 AAC/m4a 容器字节。
///
/// 为什么要这一步：`ImmersionMiningEngine` 对 `providedAudioBytes` **逐字节写盘不重编码**
/// （`immersion_mining_engine.dart:173`）。裸 PCM/裸 aac 流塞进卡 Anki 播不了（iOS 更直接
/// 拒绝下载裸 aac）。所以先把 PCM 包成合法 WAV 容器，再复用已验证的
/// [extractAudioSegmentViaFfmpeg] 转成 AAC——和 Netflix `transcodeClipToCapture` 同一条
/// 编码链，只是输入换成我们自己拼的 WAV。

/// 单个 PCM 采样的存储格式。WASAPI 共享模式混音输出常见两种：16-bit 整型 或 32-bit 浮点。
class PcmFormat {
  const PcmFormat({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.isFloat,
  });

  /// 采样率（Hz），如 48000。
  final int sampleRate;

  /// 声道数，如 2（立体声）。
  final int channels;

  /// 每采样位数，如 16 或 32。
  final int bitsPerSample;

  /// true = IEEE float（WAVE 格式码 3）；false = 整型 PCM（格式码 1）。
  final bool isFloat;

  /// 每帧（所有声道一组采样）字节数。
  int get blockAlign => channels * (bitsPerSample ~/ 8);

  /// 每秒字节数。
  int get byteRate => sampleRate * blockAlign;
}

/// 给定裸 PCM 字节长度算时长（毫秒）。纯函数，可单测。[byteRate]<=0 时返回 0。
int pcmDurationMs(int pcmByteLength, int byteRate) {
  if (byteRate <= 0 || pcmByteLength <= 0) {
    return 0;
  }
  return (pcmByteLength * 1000) ~/ byteRate;
}

/// 把裸 PCM 按时间区间 `[startMs, endMs)` 切出子段（**帧对齐**，供 galgame 波形选区后取音频）。
///
/// 纯函数，可单测。字节偏移按 [PcmFormat.byteRate] 换算并**向下对齐到 [PcmFormat.blockAlign]**
/// （切在整帧边界，不半帧撕裂立体声/多字节采样），再 clamp 到 `[0, pcm.length]`。
/// 收敛后 `start>=end`（区间空/倒置/越界）时返回空 [Uint8List]（调用方据此提示「未选到音频」，
/// 不塞空段假装成功）。返回的是**拷贝**（不与入参共享底层 buffer）。
Uint8List slicePcmByMs(
    Uint8List pcm, PcmFormat format, int startMs, int endMs) {
  final int blockAlign = format.blockAlign;
  final int byteRate = format.byteRate;
  if (pcm.isEmpty || blockAlign <= 0 || byteRate <= 0) {
    return Uint8List(0);
  }
  int startByte = startMs <= 0 ? 0 : (startMs * byteRate) ~/ 1000;
  int endByte = endMs <= 0 ? 0 : (endMs * byteRate) ~/ 1000;
  // 向下帧对齐（切在整帧边界）。
  startByte -= startByte % blockAlign;
  endByte -= endByte % blockAlign;
  // clamp 到实际 PCM 范围。
  if (startByte < 0) startByte = 0;
  if (endByte > pcm.length) endByte = pcm.length;
  // 末尾也对齐（clamp 后可能不再对齐）。
  endByte -= endByte % blockAlign;
  if (startByte >= endByte) {
    return Uint8List(0);
  }
  return Uint8List.fromList(pcm.sublist(startByte, endByte));
}

/// 把裸 PCM 拼成合法的 44 字节头 WAV（RIFF/WAVE，单 fmt + data chunk）。纯函数，可单测。
///
/// 头部字段全部小端。[PcmFormat.isFloat] 决定 WAVE 格式码（1=整型 / 3=浮点）。
Uint8List buildWavBytes(Uint8List pcm, PcmFormat fmt) {
  const int headerSize = 44;
  final int dataLen = pcm.length;
  final ByteData header = ByteData(headerSize);
  // RIFF chunk descriptor
  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + dataLen, Endian.little); // ChunkSize = 36 + dataLen
  _writeAscii(header, 8, 'WAVE');
  // fmt subchunk
  _writeAscii(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // Subchunk1Size = 16 (PCM)
  header.setUint16(20, fmt.isFloat ? 3 : 1, Endian.little); // AudioFormat
  header.setUint16(22, fmt.channels, Endian.little);
  header.setUint32(24, fmt.sampleRate, Endian.little);
  header.setUint32(28, fmt.byteRate, Endian.little);
  header.setUint16(32, fmt.blockAlign, Endian.little);
  header.setUint16(34, fmt.bitsPerSample, Endian.little);
  // data subchunk
  _writeAscii(header, 36, 'data');
  header.setUint32(40, dataLen, Endian.little);

  final Uint8List out = Uint8List(headerSize + dataLen);
  out.setRange(0, headerSize, header.buffer.asUint8List());
  out.setRange(headerSize, headerSize + dataLen, pcm);
  return out;
}

void _writeAscii(ByteData data, int offset, String ascii) {
  for (int i = 0; i < ascii.length; i++) {
    data.setUint8(offset + i, ascii.codeUnitAt(i));
  }
}

/// 把裸 PCM 切片编码成 AAC/m4a 容器字节（供 `providedAudioBytes`）。
///
/// 流程：拼 WAV → 落临时文件 → [extractAudioSegmentViaFfmpeg] 转全段 AAC → 读回字节 →
/// 清理临时目录。任何一步失败（PCM 空 / ffmpeg 不可用 / 转码丢音）返回 null（fail-open，
/// 调用方据此提示「音频编码失败」，不塞裸流假装成功）。
///
/// [outputExtension] 桌面/Android 传 `aac`、iOS 传 `m4a`（见 [immersionMiningAudioExtension]）。
Future<Uint8List?> pcmSliceToAacBytes({
  required Uint8List pcm,
  required PcmFormat format,
  required String tempDir,
  required String outputExtension,
  int audioChannels = 1,
  String audioBitrate = '64k',
  FfmpegFailureReporter? onFailure,
}) async {
  if (pcm.isEmpty) {
    return null;
  }
  final int durationMs = pcmDurationMs(pcm.length, format.byteRate);
  if (durationMs <= 0) {
    return null;
  }
  final Directory dir = Directory('$tempDir/gal_pcm_${pcm.length}');
  await dir.create(recursive: true);
  try {
    final File wav = File('${dir.path}/slice.wav');
    await wav.writeAsBytes(buildWavBytes(pcm, format), flush: true);
    final String? aacPath = await extractAudioSegmentViaFfmpeg(
      inputPath: wav.path,
      startMs: 0,
      endMs: durationMs,
      outputPath: '${dir.path}/slice.$outputExtension',
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
      onFailure: onFailure,
    );
    if (aacPath == null) {
      return null;
    }
    return await File(aacPath).readAsBytes();
  } catch (_) {
    return null;
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

/// 这个容器格式是否「字节首尾相接仍是合法流」。
///
/// ADTS（`.aac`）每帧自带同步字与帧长，多段直接拼起来就是一段连续音频，播放器与 Anki
/// 都当作一个流解。MP4/M4A 有全局 `moov` 索引，拼接只会得到废文件——所以那边只能退回
/// 单段。判据写成函数而不是散在调用点，是因为它决定「多语音能不能合成」这一整条分支。
bool isSelfSynchronizingAudioContainer(String outputExtension) =>
    outputExtension.toLowerCase() == 'aac';

/// 按顺序把多段音频字节接成一段。纯函数，可单测。空段自动跳过；全空返回空。
Uint8List concatAudioStreams(List<Uint8List> streams) {
  int total = 0;
  for (final Uint8List part in streams) {
    total += part.length;
  }
  final Uint8List out = Uint8List(total);
  int offset = 0;
  for (final Uint8List part in streams) {
    if (part.isEmpty) continue;
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

/// 把**同一句台词的全部原始语音资源**转码并合成一段制卡音频（BUG-1605）。
///
/// 为什么需要它：男女声优同台时引擎会为同一条文本读入多个语音资源，hook 各 dump 一个
/// 文件。旧实现每层只挑一个，卡里就只剩其中一个人的声音。
///
/// 合成方式是**按顺序接续播放**，不是叠加混音。这不是偷懒：
///  - 入库的 `third_party/ffmpeg-min` 是白名单裁剪版，滤镜只留了
///    `aresample/astats/...`（见 `tool/ffmpeg-min/build-ffmpeg-min.sh` 的 `FILTERS`），
///    **没有 `amix`/`adelay`/`volume`**；要混音就得改配方、重编三平台二进制并重新
///    vendor，而 `ffmpeg_min_vendored_recipe_guard_test.dart` 会在二进制换上来之前一直
///    红。为一个能用接续解决的需求换掉整条工具链不划算。
///  - 对制卡本身，两个人的台词分开听比叠在一起更能听清——这正是用户要的。
///
/// [resourcePaths] 首元素是主语音（配对层已排好序，见 [pickPairedGameResources]）。
/// 单个资源、或输出容器不是自同步格式（[isSelfSynchronizingAudioContainer]）时退回
/// 单段转码，语义与旧行为逐字节一致。任何一段转码失败就跳过它（Never break：宁可少一
/// 个声音，也不能整句没音频）；全部失败返回 null。
Future<Uint8List?> transcodeVoiceResourcesToMiningAudio({
  required List<String> resourcePaths,
  required String tempDir,
  required String outputExtension,
  int audioChannels = 1,
  String audioBitrate = '128k',
}) async {
  if (resourcePaths.isEmpty) {
    return null;
  }
  if (resourcePaths.length == 1 ||
      !isSelfSynchronizingAudioContainer(outputExtension)) {
    return transcodeVoiceOggToMiningAudio(
      oggPath: resourcePaths.first,
      tempDir: tempDir,
      outputExtension: outputExtension,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
    );
  }
  final List<Uint8List> parts = <Uint8List>[];
  for (final String path in resourcePaths) {
    final Uint8List? bytes = await transcodeVoiceOggToMiningAudio(
      oggPath: path,
      tempDir: tempDir,
      outputExtension: outputExtension,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
    );
    if (bytes != null && bytes.isNotEmpty) {
      parts.add(bytes);
    }
  }
  if (parts.isEmpty) {
    return null;
  }
  if (parts.length == 1) {
    return parts.first;
  }
  return concatAudioStreams(parts);
}

/// galgame 纯人声一键制卡（docs/specs/galgame-mining）：把注入 hook DLL dump 的**原始语音
/// OGG 文件** [oggPath] 整段转码成制卡管线容器（桌面 `aac`）字节，供 `providedAudioBytes`
/// 逐字节写盘。
///
/// 为什么转码而非直接塞 OGG：`ImmersionMiningEngine` 把 `providedAudioBytes` 逐字节写成
/// `immersion_audio.<扩展>`（引擎固定用制卡管线扩展名，桌面 = `aac`），Anki 按该扩展识别
/// 媒体。OGG 字节塞进 `.aac` 名下既错又 Anki 不一定自动播；转成与句子音频同一条 AAC 容器
/// （[extractAudioSegmentViaFfmpeg] 同款 `-c:a aac`）最稳。语音行本就短，整段转、不做区间
/// 裁剪。[outputExtension] 由调用方按运行平台传（此路径 Windows 专属，恒为 `aac`）。ffmpeg
/// 缺失 / 转码失败 / 空产出返回 null（调用方回退 PCM 采集链，Never break）。
Future<Uint8List?> transcodeVoiceOggToMiningAudio({
  required String oggPath,
  required String tempDir,
  required String outputExtension,
  int audioChannels = 1,
  String audioBitrate = '128k',
}) async {
  if (!File(oggPath).existsSync()) {
    return null;
  }
  final Directory dir = Directory('$tempDir/gal_voice_${oggPath.hashCode}');
  await dir.create(recursive: true);
  try {
    final String outPath = '${dir.path}/voice.$outputExtension';
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      <String>[
        '-y',
        '-i',
        oggPath,
        '-vn',
        '-ac',
        '$audioChannels',
        '-ar',
        '44100',
        '-c:a',
        'aac',
        '-b:a',
        audioBitrate,
        outPath,
      ],
      const Duration(seconds: 30),
    );
    final File out = File(outPath);
    if (result.returnCode == 0 && out.existsSync() && out.lengthSync() > 0) {
      return await out.readAsBytes();
    }
    return null;
  } on ProcessException {
    // ffmpeg 缺失 / 跑不起来：优雅回退（调用方改用 PCM 采集链）。
    return null;
  } catch (_) {
    return null;
  } finally {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}
