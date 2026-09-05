/// 有声书设备端语音转录（ASR）子系统的共享数据类型与模型常量。
///
/// 纯数据、无 IO。模型是 ReazonSpeech k2-v2（字符级 zipformer2 RNN-T，
/// sherpa-onnx 导出，见 `asr_model_manifest.dart`），VAD 是 k2-fsa 导出的
/// silero-vad v4（仅 16 kHz 分支）。所有 IO 名称/形状均已用 `onnx` 读取模型
/// 文件核实（2026-09-05）：
///
/// ```text
/// encoder : x[N,T,80] f32, x_lens[N] i64 -> encoder_out[N,T',512] f32,
///           encoder_out_lens[N] i64        （T' ≈ T/4，40 ms/帧）
/// decoder : y[N,2] i64                    -> decoder_out[N,512] f32
/// joiner  : encoder_out[N,512], decoder_out[N,512] -> logit[N,5224] f32
/// vad v4  : x[1,512] f32, h[2,1,64], c[2,1,64] -> prob[1,1], new_h, new_c
/// tokens  : 5224 行 `<token>\t<id>`；<blk>=0，<unk>=5222，<sos/eos>=5223
/// ```
library;

import 'dart:convert' show utf8;

import 'package:flutter/foundation.dart';

/// 全链路统一采样率（fbank / VAD / 模型都按 16 kHz 训练）。
const int kAsrSampleRate = 16000;

/// fbank 帧移（毫秒）与 zipformer2 的时间下采样倍数：编码器每帧 40 ms。
const int kAsrFrameShiftMs = 10;
const int kAsrSubsamplingFactor = 4;
const int kAsrEncoderFrameMs = kAsrFrameShiftMs * kAsrSubsamplingFactor;

/// fbank 维度。
const int kAsrFeatureDim = 80;

/// silero-vad v4 每次前向消费的样本数（16 kHz 下 32 ms）。
const int kAsrVadWindowSamples = 512;

/// RNN-T 解码器上下文长度（decoder 元数据 `context_size=2`）。
const int kAsrDecoderContextSize = 2;

/// 模型 IO 名称（与文件头注释一致，集中一处避免散落魔法串）。
abstract final class AsrModelIo {
  static const String encoderInputX = 'x';
  static const String encoderInputXLens = 'x_lens';
  static const String encoderOutput = 'encoder_out';
  static const String encoderOutputLens = 'encoder_out_lens';
  static const String decoderInputY = 'y';
  static const String decoderOutput = 'decoder_out';
  static const String joinerInputEncoder = 'encoder_out';
  static const String joinerInputDecoder = 'decoder_out';
  static const String joinerOutputLogit = 'logit';
  static const String vadInputX = 'x';
  static const String vadInputH = 'h';
  static const String vadInputC = 'c';
  static const String vadOutputProb = 'prob';
  static const String vadOutputH = 'new_h';
  static const String vadOutputC = 'new_c';
}

/// 词表（`tokens.txt`）。
///
/// 两种形态，按词表内容自动判定（[isSentencePiece]）：
/// - **字符级**（ReazonSpeech）：一行一个字符 token，拼接即文本。
/// - **SentencePiece BPE**（LibriHeavy 英语）：词首 token 带 `▁`（U+2581）表示
///   前面有空格；词表覆盖不到的字节走 byte-fallback token `<0xNN>`，连续若干个
///   拼成一个 UTF-8 序列。英语包实测大写字母/数字几乎全走 byte-fallback
///   （`<0x50>` = `P`），不合并就是满屏 `<0x44>ursley`。
///
/// [materialize] 把 id 序列变成可直接拼接的文本片段：做 `▁`→空格替换与字节合并，
/// 两条解码路径（Dart 逐帧 / Loop 图）共用，语义只此一处。
@immutable
class AsrTokenTable {
  const AsrTokenTable._(
    this._tokens,
    this.blankId,
    this.unkId,
    this.eosId,
    this.isSentencePiece,
  );

  /// SentencePiece 的词首标记（U+2581 LOWER ONE EIGHTH BLOCK）。
  static const String sentencePieceSpace = '▁';

  static final RegExp _byteToken = RegExp(r'^<0x([0-9A-Fa-f]{2})>$');

  /// 解析 sherpa-onnx 的 `tokens.txt`（`<token>\t<id>` 每行，id 从 0 起）。
  /// 以最后一个制表符（没有则最后一个空格）切分，token 本体不裁剪——
  /// 空格本身可能是 token。
  factory AsrTokenTable.parse(String text) {
    final Map<int, String> byId = <int, String>{};
    for (final String raw in text.split('\n')) {
      final String line =
          raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) continue;
      final int tab = line.lastIndexOf('\t');
      final int sep = tab >= 0 ? tab : line.lastIndexOf(' ');
      if (sep <= 0) continue;
      final int? id = int.tryParse(line.substring(sep + 1));
      if (id == null) continue;
      byId[id] = line.substring(0, sep);
    }
    int maxId = -1;
    for (final int id in byId.keys) {
      if (id > maxId) maxId = id;
    }
    final List<String> tokens =
        List<String>.generate(maxId + 1, (int i) => byId[i] ?? '');
    int find(String name) => tokens.indexOf(name);
    return AsrTokenTable._(
      tokens,
      find('<blk>'),
      find('<unk>'),
      find('<sos/eos>'),
      tokens.any((String t) => t.startsWith(sentencePieceSpace)),
    );
  }

  final List<String> _tokens;

  /// blank id（找不到 `<blk>` 时为 -1；正常模型恒为 0）。
  final int blankId;
  final int unkId;
  final int eosId;

  /// 词表是否是 SentencePiece 形态（任一 token 以 `▁` 开头）。
  final bool isSentencePiece;

  int get size => _tokens.length;

  /// 原始 token 文本（不做 `▁` / byte-fallback 处理；诊断与 [materialize] 用）。
  String tokenAt(int id) => id >= 0 && id < _tokens.length ? _tokens[id] : '';

  /// 该 id 是否是不该进入文本的特殊符号（blank / unk / eos）。
  bool isSpecial(int id) => id == blankId || id == unkId || id == eosId;

  /// 若 [id] 是 byte-fallback token（`<0xNN>`）返回该字节值，否则 -1。
  int byteValueOf(int id) {
    final RegExpMatch? m = _byteToken.firstMatch(tokenAt(id));
    return m == null ? -1 : int.parse(m.group(1)!, radix: 16);
  }

  /// 把发射的 token id 序列（与各自的时间）变成**可直接拼接**的文本片段序列。
  ///
  /// - 字符级词表：逐个原样返回；
  /// - SentencePiece：`▁` 替换成空格；连续 byte-fallback token 合成一段 UTF-8
  ///   （坏序列按 `allowMalformed` 替换成 U+FFFD，不抛），时间取该段首个字节的
  ///   时间，其余字节的时间随之丢弃——一个字符只该有一个发射时刻。
  ///
  /// 返回的两个列表等长；合并后可能比输入短。
  ({List<String> tokens, List<int> timesMs}) materialize(
    List<int> ids,
    List<int> timesMs,
  ) {
    assert(ids.length == timesMs.length);
    final List<String> outTokens = <String>[];
    final List<int> outTimes = <int>[];
    final List<int> pendingBytes = <int>[];
    int pendingTime = 0;
    void flushBytes() {
      if (pendingBytes.isEmpty) return;
      outTokens.add(utf8.decode(pendingBytes, allowMalformed: true));
      outTimes.add(pendingTime);
      pendingBytes.clear();
    }

    for (int i = 0; i < ids.length; i++) {
      final int id = ids[i];
      if (isSentencePiece) {
        final int byte = byteValueOf(id);
        if (byte >= 0) {
          if (pendingBytes.isEmpty) pendingTime = timesMs[i];
          pendingBytes.add(byte);
          continue;
        }
      }
      flushBytes();
      final String raw = tokenAt(id);
      outTokens.add(
        isSentencePiece ? raw.replaceAll(sentencePieceSpace, ' ') : raw,
      );
      outTimes.add(timesMs[i]);
    }
    flushBytes();
    return (tokens: outTokens, timesMs: outTimes);
  }
}

/// VAD 切出的一段语音：相对**当前音频文件**的样本偏移 + 该段 16 kHz 单声道样本。
@immutable
class AsrSpeechSegment {
  const AsrSpeechSegment({
    required this.startSample,
    required this.samples,
  });

  final int startSample;
  final Float32List samples;

  int get endSample => startSample + samples.length;
  int get startMs => startSample * 1000 ~/ kAsrSampleRate;
  int get endMs => endSample * 1000 ~/ kAsrSampleRate;
  int get lengthMs => samples.length * 1000 ~/ kAsrSampleRate;
}

/// 一段语音的解码结果：字符 token 与各自的**段内**时间（毫秒，相对段起点）。
@immutable
class AsrDecodedSegment {
  const AsrDecodedSegment({
    required this.tokens,
    required this.tokenOffsetsMs,
  }) : assert(tokens.length == tokenOffsetsMs.length);

  // 注：const 构造里的 assert 不能对 const 列表取 length，故这里只能是 final。
  static final AsrDecodedSegment empty = AsrDecodedSegment(
      tokens: const <String>[], tokenOffsetsMs: const <int>[]);

  /// 由发射的 token id 与段内时间构造：经 [AsrTokenTable.materialize] 做词表
  /// 形态相关的拼接（`▁` / byte-fallback），两条解码路径共用。
  factory AsrDecodedSegment.fromTokenIds({
    required AsrTokenTable table,
    required List<int> ids,
    required List<int> offsetsMs,
  }) {
    final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
      ids,
      offsetsMs,
    );
    return AsrDecodedSegment(
      tokens: List<String>.unmodifiable(m.tokens),
      tokenOffsetsMs: List<int>.unmodifiable(m.timesMs),
    );
  }

  final List<String> tokens;
  final List<int> tokenOffsetsMs;

  String get text => tokens.join();
  bool get isEmpty => tokens.isEmpty;
}

/// 一段语音的最终转录（段落绝对时间 + token 绝对时间），持久化与 cue 构造的输入。
@immutable
class AsrTranscribedSegment {
  const AsrTranscribedSegment({
    required this.audioFileIndex,
    required this.startMs,
    required this.endMs,
    required this.tokens,
    required this.tokenTimesMs,
  }) : assert(tokens.length == tokenTimesMs.length);

  factory AsrTranscribedSegment.fromDecoded({
    required int audioFileIndex,
    required AsrSpeechSegment speech,
    required AsrDecodedSegment decoded,
  }) {
    return AsrTranscribedSegment(
      audioFileIndex: audioFileIndex,
      startMs: speech.startMs,
      endMs: speech.endMs,
      tokens: List<String>.unmodifiable(decoded.tokens),
      tokenTimesMs: List<int>.unmodifiable(
        decoded.tokenOffsetsMs.map((int o) => speech.startMs + o),
      ),
    );
  }

  factory AsrTranscribedSegment.fromJson(Map<String, Object?> json) {
    return AsrTranscribedSegment(
      audioFileIndex: (json['f'] as num).toInt(),
      startMs: (json['s'] as num).toInt(),
      endMs: (json['e'] as num).toInt(),
      tokens: List<String>.unmodifiable(
        (json['t'] as List<Object?>).cast<String>(),
      ),
      tokenTimesMs: List<int>.unmodifiable(
        (json['m'] as List<Object?>).map((Object? v) => (v as num).toInt()),
      ),
    );
  }

  /// 多音频文件时的文件下标（与 `AudioCue.audioFileIndex` 同语义）。
  final int audioFileIndex;

  /// 段起止（毫秒，相对该音频文件）。来自 VAD 边界，不是 token 时间。
  final int startMs;
  final int endMs;
  final List<String> tokens;

  /// 每个 token 的发射时间（毫秒，相对该音频文件）。
  final List<int> tokenTimesMs;

  String get text => tokens.join();

  Map<String, Object?> toJson() => <String, Object?>{
        'f': audioFileIndex,
        's': startMs,
        'e': endMs,
        't': tokens,
        'm': tokenTimesMs,
      };
}

/// 解码后的 PCM 块：16 kHz 单声道 float32（[-1, 1]），带相对文件起点的样本偏移。
@immutable
class AsrPcmChunk {
  const AsrPcmChunk({required this.startSample, required this.samples});

  final int startSample;
  final Float32List samples;

  int get endSample => startSample + samples.length;
}

/// 把任意音频文件解码成顺序 PCM 块的来源（实现见 `asr_pcm_source.dart`）。
///
/// 契约：块按时间顺序、无重叠、无空洞地覆盖 `[startSample, 文件末尾)`；
/// 最后一块可以短于 [chunkSeconds]；文件不可解码时抛 [AsrPcmDecodeException]。
abstract interface class AsrPcmSource {
  /// 探测时长（毫秒）；探不出返回 null（不抛）。
  Future<int?> probeDurationMs(String audioPath);

  /// 从 [startSample] 起按约 [chunkSeconds] 秒一块流式解码。
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  });
}

class AsrPcmDecodeException implements Exception {
  const AsrPcmDecodeException(this.audioPath, this.message);

  final String audioPath;
  final String message;

  @override
  String toString() => 'AsrPcmDecodeException($audioPath): $message';
}
