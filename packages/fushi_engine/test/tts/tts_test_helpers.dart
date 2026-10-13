import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 16-bit PCM WAV。[dataSizeField] 覆盖 data 块头里写的长度（模拟流式 WAV）。
Uint8List buildWav({
  int sampleRate = 8000,
  int channels = 1,
  int bitsPerSample = 16,
  int dataBytes = 1600,
  int? dataSizeField,
  bool extraChunk = false,
}) {
  final int byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final BytesBuilder b = BytesBuilder();
  void ascii(String s) => b.add(s.codeUnits);
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) =>
      b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  ascii('RIFF');
  u32(36 + dataBytes + (extraChunk ? 12 : 0));
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(channels * bitsPerSample ~/ 8);
  u16(bitsPerSample);
  if (extraChunk) {
    ascii('LIST');
    u32(3); // 奇数长度 → 补 1 字节
    b.add(<int>[1, 2, 3, 0]);
  }
  ascii('data');
  u32(dataSizeField ?? dataBytes);
  b.add(Uint8List(dataBytes));
  return b.toBytes();
}

/// MPEG1 Layer III, 128kbps, 44.1kHz 的 [frames] 帧（帧头后补零）。
/// 无 padding 帧 417 字节，padding 帧 418 字节。
Uint8List buildMp3({required int frames, bool padding = false}) {
  final BytesBuilder b = BytesBuilder();
  final int frameLength = padding ? 418 : 417;
  for (int i = 0; i < frames; i++) {
    final Uint8List frame = Uint8List(frameLength);
    frame[0] = 0xFF;
    frame[1] = 0xFB; // MPEG1, Layer III, no CRC
    frame[2] = 0x90 | (padding ? 0x02 : 0x00); // 128kbps, 44.1kHz
    frame[3] = 0x44;
    b.add(frame);
  }
  return b.toBytes();
}

class MemoryPrefStore implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

/// 可编排的假引擎：记录调用、可让某些文本失败或阻塞（直到放行或取消）。
class FakeTtsProvider extends TtsProvider {
  FakeTtsProvider({this.maxConcurrency = 1});

  final int maxConcurrency;
  final List<String> calls = <String>[];
  final List<String> cancelled = <String>[];
  final Set<String> failing = <String>{};
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  bool gateAll = false;
  int active = 0;
  int maxActive = 0;

  Completer<void> gate(String text) =>
      gates.putIfAbsent(text, Completer<void>.new);

  void release(String text) {
    final Completer<void> g = gate(text);
    if (!g.isCompleted) g.complete();
  }

  @override
  TtsCapabilities get capabilities => TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    maxConcurrency: maxConcurrency,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    calls.add(text);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gateAll || gates.containsKey(text)) {
        final Completer<void> cancelled = Completer<void>();
        final void Function() unregister = cancel.onCancel(cancelled.complete);
        await Future.any(<Future<void>>[gate(text).future, cancelled.future]);
        unregister();
      }
      if (cancel.isCancelled) {
        cancelled.add(text);
        throw const TtsFailure(TtsFailureCode.cancelled);
      }
      if (failing.contains(text)) {
        throw const TtsFailure(TtsFailureCode.serverError, 'HTTP 500');
      }
      await File(outputPath).writeAsBytes(buildWav());
      return const TtsResult(format: TtsAudioFormat.wav);
    } finally {
      active--;
    }
  }
}

/// 轮询直到 [condition] 成立（异步文件操作没有确定的 microtask 次数）。
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 让在途异步工作有机会推进（用于断言「什么都没发生」）。
Future<void> settle([int ms = 100]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
