import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_sentence_audio_source.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:just_audio/just_audio.dart';

Uint8List _wav(int dataBytes) {
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  for (int i = 0; i < dataBytes; i++) {
    b.setUint8(44 + i, i & 0xFF);
  }
  return b.buffer.asUint8List();
}

class _WavProvider extends TtsProvider {
  int calls = 0;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    calls++;
    await File(outputPath).writeAsBytes(_wav(32000));
    return const TtsResult(format: TtsAudioFormat.wav);
  }
}

// StreamAudioSource 是 just_audio 标的 experimental API，与生产代码同一处豁免。
// ignore_for_file: experimental_member_use
void main() {
  late Directory root;
  late TtsSynthesisScheduler scheduler;
  late _WavProvider provider;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_source_test');
    provider = _WavProvider();
    scheduler = TtsSynthesisScheduler(
      provider: provider,
      cache: TtsAudioCache(root: root),
      texts: const <String>['一。', '二。'],
      audioIdentity: const <String, Object?>{'provider': 'fake'},
      lookahead: 0,
    );
  });

  tearDown(() async {
    await scheduler.dispose();
    await root.delete(recursive: true);
  });

  test('a request waits for synthesis and serves the cached WAV', () async {
    final TtsSentenceAudioSource source = TtsSentenceAudioSource(
      scheduler: scheduler,
      index: 1,
    );
    final StreamAudioResponse full = await source.request();
    expect(full.contentType, 'audio/wav');
    expect(full.sourceLength, 44 + 32000);
    expect(full.contentLength, 44 + 32000);
    expect(full.offset, 0);
    final List<int> bytes = (await full.stream.toList())
        .expand((List<int> c) => c)
        .toList();
    expect(bytes.length, 44 + 32000);
    // 被请求的第 1 句 + 光标所在第 0 句的预取。
    expect(provider.calls, 2);
    expect(File(scheduler.audioPathOf(1)).existsSync(), isTrue);
  });

  test('range requests return exactly the requested bytes', () async {
    final TtsSentenceAudioSource source = TtsSentenceAudioSource(
      scheduler: scheduler,
      index: 0,
    );
    final StreamAudioResponse part = await source.request(100, 200);
    expect(part.offset, 100);
    expect(part.contentLength, 100);
    final List<int> bytes = (await part.stream.toList())
        .expand((List<int> c) => c)
        .toList();
    expect(bytes.first, (100 - 44) & 0xFF);
    expect(bytes, hasLength(100));
    // 第二次请求命中缓存，不再合成。
    await source.request(0, 10);
    expect(provider.calls, 1);
  });
}
