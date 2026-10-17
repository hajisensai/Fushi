/// 多声优配音时一章里混着不同引擎的音频（如 GPT-SoVITS 48 kHz WAV + Edge 24 kHz
/// MP3）。concat demuxer 只按第一个文件建解码器，后面换了编码 / 采样率 / 声道就会
/// 解成杂音，所以一章的流参数不一致时，先把不合规的句转成统一的中间文件再拼。
///
/// 中间格式：16-bit PCM 装在 QuickTime（`.mov`）里——桌面 ffmpeg-min 没有 wav 封装器，
/// 但有 `pcm_s16le` 编码器与 mov 封装器。无损（最后只做一次 AAC 编码），时长就是样本
/// 数（`mdhd` 的 timescale = 采样率），cue 时间按实测时长取，不会漂。
///
/// concat 只看编码参数不看容器：已经是「目标 PCM 参数」的 WAV 原样参与拼接，只有不合
/// 规的句才转码。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

/// 一个音频文件的流参数（concat 关心的那部分）。
class TtsAudioStreamInfo {
  const TtsAudioStreamInfo({
    required this.codec,
    required this.sampleRate,
    required this.channels,
  });

  /// ffmpeg 解码器名：`pcm_s16le` / `pcm_f32le` / `mp3` …
  final String codec;
  final int sampleRate;
  final int channels;

  @override
  bool operator ==(Object other) =>
      other is TtsAudioStreamInfo &&
      other.codec == codec &&
      other.sampleRate == sampleRate &&
      other.channels == channels;

  @override
  int get hashCode => Object.hash(codec, sampleRate, channels);

  @override
  String toString() => '$codec/$sampleRate/$channels';
}

/// 从文件头解析流参数（WAV `fmt ` 块 / 第一个 MPEG 音频帧头）。认不出返回 null
/// （调用方按「不合规」处理，转码兜底）。
TtsAudioStreamInfo? parseTtsAudioStreamInfo(Uint8List head) {
  if (head.length >= 12 &&
      String.fromCharCodes(head.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(head.sublist(8, 12)) == 'WAVE') {
    return _wavInfo(head);
  }
  return _mpegInfo(head);
}

TtsAudioStreamInfo? _wavInfo(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int size = data.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'fmt ') {
      if (body + 16 > bytes.length) return null;
      int tag = data.getUint16(body, Endian.little);
      final int channels = data.getUint16(body + 2, Endian.little);
      final int rate = data.getUint32(body + 4, Endian.little);
      final int bits = data.getUint16(body + 14, Endian.little);
      // WAVE_FORMAT_EXTENSIBLE：真正的格式在子格式 GUID 的前两个字节。
      if (tag == 0xFFFE && size >= 40 && body + 26 <= bytes.length) {
        tag = data.getUint16(body + 24, Endian.little);
      }
      final String? codec = switch ((tag, bits)) {
        (1, 8) => 'pcm_u8',
        (1, 16) => 'pcm_s16le',
        (1, 24) => 'pcm_s24le',
        (1, 32) => 'pcm_s32le',
        (3, 32) => 'pcm_f32le',
        (3, 64) => 'pcm_f64le',
        _ => null,
      };
      if (codec == null || channels <= 0 || rate <= 0) return null;
      return TtsAudioStreamInfo(
        codec: codec,
        sampleRate: rate,
        channels: channels,
      );
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

TtsAudioStreamInfo? _mpegInfo(Uint8List bytes) {
  int offset = 0;
  if (bytes.length >= 10 &&
      String.fromCharCodes(bytes.sublist(0, 3)) == 'ID3') {
    offset =
        10 +
        ((bytes[6] & 0x7F) << 21 |
            (bytes[7] & 0x7F) << 14 |
            (bytes[8] & 0x7F) << 7 |
            (bytes[9] & 0x7F));
  }
  for (; offset + 4 <= bytes.length; offset++) {
    final int b1 = bytes[offset + 1], b2 = bytes[offset + 2];
    if (bytes[offset] != 0xFF || (b1 & 0xE0) != 0xE0) continue;
    final int version = (b1 >> 3) & 0x3; // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
    final int layer = (b1 >> 1) & 0x3; // 1 = Layer III, 2 = Layer II
    final int rateIndex = (b2 >> 2) & 0x3;
    final int bitrateIndex = (b2 >> 4) & 0xF;
    if (version == 1 || layer == 0 || rateIndex == 3) continue;
    if (bitrateIndex == 0 || bitrateIndex == 15) continue;
    const List<int> baseRates = <int>[44100, 48000, 32000];
    final int rate =
        baseRates[rateIndex] ~/ (version == 3 ? 1 : (version == 2 ? 2 : 4));
    final int channelMode = (bytes[offset + 3] >> 6) & 0x3;
    return TtsAudioStreamInfo(
      codec: layer == 1 ? 'mp3' : (layer == 2 ? 'mp2' : 'mp1'),
      sampleRate: rate,
      channels: channelMode == 3 ? 1 : 2,
    );
  }
  return null;
}

/// 读文件头（够覆盖 ID3 标签后的第一帧 / WAV 的 fmt 块）并解析流参数。
Future<TtsAudioStreamInfo?> probeTtsAudioStreamInfo(String path) async {
  final RandomAccessFile raf = await File(path).open();
  try {
    final Uint8List head = await raf.read(64 * 1024);
    return parseTtsAudioStreamInfo(head);
  } finally {
    await raf.close();
  }
}

/// 一章能不能直接拼：所有句流参数都认得出且完全相同。
bool ttsStreamsAreUniform(List<TtsAudioStreamInfo?> infos) {
  if (infos.isEmpty) return true;
  final TtsAudioStreamInfo? first = infos.first;
  if (first == null) return false;
  for (final TtsAudioStreamInfo? info in infos) {
    if (info != first) return false;
  }
  return true;
}

/// 混合章的统一目标：16-bit PCM，采样率取章内最高（上限 48 kHz，不把高采样率
/// 的声音降质），声道取最多（上限 2）。认不出的句不参与取值。
TtsAudioStreamInfo pickTtsUniformTarget(List<TtsAudioStreamInfo?> infos) {
  int rate = 0;
  int channels = 0;
  for (final TtsAudioStreamInfo? info in infos) {
    if (info == null) continue;
    rate = math.max(rate, info.sampleRate);
    channels = math.max(channels, info.channels);
  }
  return TtsAudioStreamInfo(
    codec: 'pcm_s16le',
    sampleRate: rate == 0 ? 24000 : math.min(rate, 48000),
    channels: channels == 0 ? 1 : math.min(channels, 2),
  );
}

/// 一句转成中间文件的 ffmpeg 参数。
List<String> buildTtsUniformTranscodeArgs({
  required String inputPath,
  required String outputPath,
  required TtsAudioStreamInfo target,
}) => <String>[
  '-y',
  '-i',
  inputPath,
  '-vn',
  '-af',
  'aresample=${target.sampleRate}',
  '-ac',
  '${target.channels}',
  '-ar',
  '${target.sampleRate}',
  '-c:a',
  'pcm_s16le',
  '-f',
  'mov',
  outputPath,
];

/// 中间文件名：同一句、同一目标参数只转一次（续跑 / 别的章复用）。
String ttsUniformIntermediatePath(
  Directory mixDir,
  String key,
  TtsAudioStreamInfo target,
) => p.join(mixDir.path, '${key}_${target.sampleRate}_${target.channels}.mov');

/// mov / mp4 里第一条轨的时长（毫秒，按 `mdhd`：PCM 轨 timescale = 采样率、
/// duration = 样本数）。逐个顶层 atom 跳过（不把 `mdat` 读进内存）。
Future<int?> readMovTrackDurationMs(String path) =>
    _readMoovBoxDurationMs(path, 'mdhd');

Future<int?> _readMoovBoxDurationMs(String path, String box) async {
  final RandomAccessFile raf = await File(path).open();
  try {
    final int length = await raf.length();
    int offset = 0;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final Uint8List header = await raf.read(16);
      if (header.length < 8) return null;
      final ByteData h = ByteData.sublistView(header);
      int size = h.getUint32(0);
      final String type = String.fromCharCodes(header.sublist(4, 8));
      int headerLen = 8;
      if (size == 1) {
        if (header.length < 16) return null;
        size = h.getUint64(8);
        headerLen = 16;
      } else if (size == 0) {
        size = length - offset;
      }
      if (size < headerLen) return null;
      if (type == 'moov') {
        // 头部是按 16 字节读的，读 moov 内容前回到头部之后。
        await raf.setPosition(offset + headerLen);
        final Uint8List moov = await raf.read(size - headerLen);
        return _boxDurationMs(moov, box);
      }
      offset += size;
    }
    return null;
  } finally {
    await raf.close();
  }
}

/// mp4 / m4a 的播放时长（毫秒，按 `mvhd`——已扣掉编辑列表裁掉的 AAC 前导样本；
/// `mdhd` 的时长会多出那 1024 个样本）。
Future<int?> readMp4PresentationDurationMs(String path) =>
    _readMoovBoxDurationMs(path, 'mvhd');

/// `mvhd` 与 `mdhd` 的版本 0 / 1 布局在时长字段之前完全相同。
int? _boxDurationMs(Uint8List moov, String box) {
  final List<int> name = box.codeUnits;
  for (int i = 4; i + 4 <= moov.length; i++) {
    // `i` 是盒子类型所在位置（前 4 字节是盒子长度）。
    if (moov[i] != name[0] ||
        moov[i + 1] != name[1] ||
        moov[i + 2] != name[2] ||
        moov[i + 3] != name[3]) {
      continue;
    }
    final int body = i + 4;
    if (body + 24 > moov.length) return null;
    final ByteData d = ByteData.sublistView(moov, body);
    final int version = d.getUint8(0);
    final int scale;
    final int duration;
    if (version == 1) {
      if (body + 36 > moov.length) return null;
      scale = d.getUint32(20);
      duration = d.getUint64(24);
    } else {
      scale = d.getUint32(12);
      duration = d.getUint32(16);
    }
    if (scale <= 0) return null;
    return (duration * 1000 / scale).round();
  }
  return null;
}

/// 一句转码卡死多久算失败。
const Duration kTtsTranscodeStallTimeout = Duration(seconds: 60);

/// 把一句转成 [outputPath] 的统一中间文件（先写临时文件再改名），返回实测时长。
/// 已存在且读得出时长的直接复用。失败抛 `TtsRenderFailure('encode_failed')`（摘要
/// 交 [onFailure]），取消抛 [TtsRenderCancelled]。
Future<int> transcodeTtsToUniform({
  required FfmpegBackend backend,
  required String inputPath,
  required String outputPath,
  required TtsAudioStreamInfo target,
  required TtsRenderCancelToken cancel,
  required void Function(String summary) onFailure,
}) async {
  cancel.throwIfCancelled();
  final File out = File(outputPath);
  if (await out.exists()) {
    final int? existing = await readMovTrackDurationMs(outputPath);
    if (existing != null && existing > 0) return existing;
    await out.delete();
  }
  await out.parent.create(recursive: true);
  final String partPath = '${p.withoutExtension(outputPath)}.part.mov';
  final File part = File(partPath);
  final Completer<void> cancelled = Completer<void>();
  cancel.onCancel(() {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  final List<String> args = buildTtsUniformTranscodeArgs(
    inputPath: inputPath,
    outputPath: partPath,
    target: target,
  );
  try {
    final FfmpegRunResult result = switch (backend) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: kTtsTranscodeStallTimeout,
          cancel: cancelled.future,
        ),
      ),
      final FfmpegBackend plain => await plain.run(
        args,
        kTtsTranscodeStallTimeout,
      ),
    };
    cancel.throwIfCancelled();
    final int? duration = result.isSuccess && await part.exists()
        ? await readMovTrackDurationMs(partPath)
        : null;
    if (duration == null || duration <= 0) {
      onFailure(result.failureSummary);
      throw const TtsRenderFailure('encode_failed');
    }
    await part.rename(outputPath);
    return duration;
  } finally {
    if (await part.exists()) await part.delete();
  }
}

/// 一章要拼接的文件与时长（与 [sentences] 一一对应）。
///
/// 流参数全章一致（单一声音的常态）原样返回缓存文件与缓存时长；不一致（多声优混了
/// 不同引擎）时，已是目标 PCM 参数的句原样拼（WAV 头算出的时长精确），其余转成
/// [mixDir] 下的统一中间文件（同键只转一次），时长取中间文件实测值——cue 时间轴
/// 就按这份时长累加，和实际拼进去的音频一致。
///
/// [requirePcm16]：本章还要插 16-bit PCM 静音（停顿），全章一致但不是 `pcm_s16le`
/// （如整章 MP3）时也走统一路径。返回的 `target` 是拼接用的流参数（静音按它生成）。
Future<
  ({List<({String path, int durationMs})> entries, TtsAudioStreamInfo target})
>
prepareTtsUniformEntries({
  required FfmpegBackend backend,
  required List<({String key, String path, int durationMs})> sentences,
  required Directory mixDir,
  required TtsRenderCancelToken cancel,
  required void Function(String summary) onFailure,
  bool requirePcm16 = false,
}) async {
  final Map<String, TtsAudioStreamInfo?> infoByKey =
      <String, TtsAudioStreamInfo?>{};
  for (final ({String key, String path, int durationMs}) s in sentences) {
    if (infoByKey.containsKey(s.key)) continue;
    infoByKey[s.key] = await probeTtsAudioStreamInfo(s.path);
  }
  final List<TtsAudioStreamInfo?> infos = <TtsAudioStreamInfo?>[
    for (final ({String key, String path, int durationMs}) s in sentences)
      infoByKey[s.key],
  ];
  if (ttsStreamsAreUniform(infos) &&
      (infos.isEmpty || !requirePcm16 || infos.first!.codec == 'pcm_s16le')) {
    return (
      entries: <({String path, int durationMs})>[
        for (final ({String key, String path, int durationMs}) s in sentences)
          (path: s.path, durationMs: s.durationMs),
      ],
      target: infos.isEmpty ? pickTtsUniformTarget(infos) : infos.first!,
    );
  }
  final TtsAudioStreamInfo target = pickTtsUniformTarget(infos);
  final Map<String, ({String path, int durationMs})> converted =
      <String, ({String path, int durationMs})>{};
  final List<({String path, int durationMs})> entries =
      <({String path, int durationMs})>[];
  for (int k = 0; k < sentences.length; k++) {
    final ({String key, String path, int durationMs}) s = sentences[k];
    if (infos[k] == target) {
      entries.add((path: s.path, durationMs: s.durationMs));
      continue;
    }
    final ({String path, int durationMs})? done = converted[s.key];
    if (done != null) {
      entries.add(done);
      continue;
    }
    final String outPath = ttsUniformIntermediatePath(mixDir, s.key, target);
    final int durationMs = await transcodeTtsToUniform(
      backend: backend,
      inputPath: s.path,
      outputPath: outPath,
      target: target,
      cancel: cancel,
      onFailure: onFailure,
    );
    final ({String path, int durationMs}) entry = (
      path: outPath,
      durationMs: durationMs,
    );
    converted[s.key] = entry;
    entries.add(entry);
  }
  return (entries: entries, target: target);
}
