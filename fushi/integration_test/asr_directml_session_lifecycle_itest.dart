/// DirectML 会话生命周期真机探针：复现「建 GPU 会话 → 大批次推理 → 关闭 → 再建 →
/// 再推理」是否会让进程被 native 层 fail-fast 掉（2026-09-05 真机上
/// `asr_transcribe_e2e_itest` 第二次装载 fp32/DirectML 时 fushi.exe 以
/// `c0000409`（ucrtbase fail-fast）退出，WER 事件 1000/1001）。
///
/// 只打印每一步的耗时与结果，不做正确性断言；哪一步之后进程消失，日志就断在哪。
/// 输入同 `asr_transcribe_e2e_itest.dart`（`ASR_MODEL_SEED` / `ASR_AUDIO` 环境变量
/// 或 dart-define）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';

String _env(String name, {String defaultValue = ''}) {
  final String? v = Platform.environment[name];
  return v == null || v.isEmpty ? defaultValue : v;
}

void _log(String msg) {
  // ignore: avoid_print
  print('[asr-dml-lifecycle] $msg');
}

Future<List<AsrSpeechSegment>> _segments(String audio) async {
  final List<AsrPcmChunk> chunks = await FfmpegAsrPcmSource()
      .decode(audio, chunkSeconds: 600)
      .toList();
  final AsrVadSegmenter vad = AsrVadSegmenter(scorer: EnergyVadScorer());
  final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
  for (final AsrPcmChunk c in chunks) {
    out.addAll(await vad.feed(c));
  }
  out.addAll(await vad.flush());
  return out;
}

Future<void> _round({
  required AsrModelStore store,
  required List<AsrSpeechSegment> segments,
  required AsrEncoderVariant variant,
  required AsrAccelerationPreference preference,
  required int batchSize,
  required String label,
  int lookaheadFrames = AsrTransducerDecoder.kDefaultLookaheadFrames,
  bool useGreedyGraph = true,
  int? greedyThreads = kAsrGreedyGraphIntraOpThreads,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  final AsrEngineSessions sessions = await AsrEngineLoader().load(
    store: store,
    variant: variant,
    preference: preference,
    greedyIntraOpThreads: greedyThreads,
  );
  _log(
    '$label load ok ${sw.elapsedMilliseconds}ms ${sessions.encoderResolution} '
    'greedyGraph=${sessions.greedy != null}'
    '${sessions.greedyUnavailableReason == null ? '' : ' (unavailable: ${sessions.greedyUnavailableReason})'}',
  );
  try {
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: sessions.encoder,
      decoder: sessions.decoder,
      joiner: sessions.joiner,
      tokens: sessions.tokens,
      lookaheadFrames: lookaheadFrames,
      greedy: useGreedyGraph ? sessions.greedy : null,
    );
    int tokens = 0;
    for (int i = 0; i < segments.length; i += batchSize) {
      final List<AsrSpeechSegment> batch = segments.sublist(
        i,
        i + batchSize > segments.length ? segments.length : i + batchSize,
      );
      sw.reset();
      for (final AsrDecodedSegment d in await decoder.decodeBatch(batch)) {
        tokens += d.tokens.length;
      }
      _log(
        '$label batch@$i size=${batch.length} ok ${sw.elapsedMilliseconds}ms',
      );
    }
    _log('$label decode done tokens=$tokens');
  } finally {
    sw.reset();
    await sessions.close();
    _log('$label close ok ${sw.elapsedMilliseconds}ms');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'DirectML 会话：大批次 → 关闭 → 再建 → 再推理',
    (WidgetTester tester) async {
      final String seed = _env('ASR_MODEL_SEED');
      expect(seed, isNotEmpty);
      final AsrModelStore store = AsrModelStore(Directory(seed));
      final String audioParam = _env(
        'ASR_AUDIO',
        defaultValue: 'test/asr/fixtures/ja_tts_16k.wav',
      );
      final String audio = p.isAbsolute(audioParam)
          ? audioParam
          : p.join(Directory.current.path, audioParam);
      final List<AsrSpeechSegment> segments = await _segments(audio);
      _log('segments=${segments.length}');

      // 第 1 轮：GPU fp32 batch 32（与 E2E 默认一致）。
      await _round(
        store: store,
        segments: segments,
        variant: AsrEncoderVariant.fp32,
        preference: AsrAccelerationPreference.auto,
        batchSize: 32,
        label: 'gpu#1(b32)',
      );
      // 第 2 轮：CPU int8（模拟 E2E 之后的 CPU 用例）。
      await _round(
        store: store,
        segments: segments,
        variant: AsrEncoderVariant.int8,
        preference: AsrAccelerationPreference.cpuOnly,
        batchSize: 16,
        label: 'cpu#1(b16)',
      );
      // 第 3 轮：再建 GPU 会话，小批次。
      await _round(
        store: store,
        segments: segments,
        variant: AsrEncoderVariant.fp32,
        preference: AsrAccelerationPreference.auto,
        batchSize: 8,
        label: 'gpu#2(b8)',
      );
      // 第 4 轮：再建 GPU 会话，大批次。
      await _round(
        store: store,
        segments: segments,
        variant: AsrEncoderVariant.fp32,
        preference: AsrAccelerationPreference.auto,
        batchSize: 32,
        label: 'gpu#3(b32)',
      );
      _log('all rounds survived');

      // Loop 图 vs Dart 逐帧：同一批段、同一 EP。
      for (final bool graph in <bool>[true, false]) {
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
          batchSize: 32,
          useGreedyGraph: graph,
          label: 'gpu-${graph ? 'loopgraph' : 'perframe'}',
        );
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
          batchSize: 16,
          useGreedyGraph: graph,
          label: 'cpu-${graph ? 'loopgraph' : 'perframe'}',
        );
      }
      // 贪心图 intra-op 线程数扫描（null = ORT 默认全核）。
      for (final int? threads in <int?>[null, 1, 2, 4, 8]) {
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
          batchSize: 32,
          greedyThreads: threads,
          label: 'gpu-loopgraph(threads=${threads ?? 'default'})',
        );
      }
      for (final int? threads in <int?>[null, 2, 4]) {
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
          batchSize: 16,
          greedyThreads: threads,
          label: 'cpu-loopgraph(threads=${threads ?? 'default'})',
        );
      }
      // 前瞻帧数扫描：同一批段、同一 EP，只变 K，看 ASR 阶段耗时（逐帧路径）。
      for (final int k in <int>[1, 4, 8, 16, 32]) {
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.fp32,
          preference: AsrAccelerationPreference.auto,
          batchSize: 32,
          lookaheadFrames: k,
          useGreedyGraph: false,
          label: 'gpu-sweep(k=$k)',
        );
      }
      for (final int k in <int>[1, 8, 16]) {
        await _round(
          store: store,
          segments: segments,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
          batchSize: 16,
          lookaheadFrames: k,
          useGreedyGraph: false,
          label: 'cpu-sweep(k=$k)',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
