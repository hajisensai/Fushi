/// 有声书设备端转录的**端到端真机测试**：真 ONNX Runtime + 真模型（日语 ReazonSpeech
/// 或英语 LibriHeavy）+ 真 ffmpeg 解码，把一段音频跑成 SRT，并断言识别文本与
/// ground truth 一致。
///
/// 单测层（`test/asr/`）用 fake 会话只能证明算法结构正确；这条证明在这台机器上
/// GPU / CPU 两条 EP 路径都真能把话读出来，并给出实时因子——「GPU 快多少」
/// 的结论只能从这里拿数，不能靠推断。
///
/// 输入：
///   --dart-define=ASR_MODEL_SEED=<dir>   含 encoder/decoder/joiner/tokens/vad 的目录（或同名环境变量）
///                                        （fp32 与 int8 编码器都在时才会跑 GPU 用例）
///   --dart-define=ASR_LANG=ja|en         模型包语言（决定文件名与词表形态）；缺省 ja
///   --dart-define=ASR_AUDIO=<wav/mp3>    音频；缺省用 test/asr/fixtures/ja_tts_16k.wav
///                                        （相对 fushi/，仅桌面可读）
///   --dart-define=ASR_EXPECT=<text>      期望文本子串（比较前去空白/标点并小写；`ANY` = 不断言，只看输出）；
///                                        缺省「今日はいい天気ですね」
///
/// 跑法（Windows，从 fushi/）：
///   $env:ASR_MODEL_SEED = '<模型目录>'
///   .\tool\run_windows_itest.ps1 -Target integration_test\asr_transcribe_e2e_itest.dart
///   （脚本不透传自定义 --dart-define，故走环境变量；直接 flutter test -d windows 时
///   两种传法都行）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// `--dart-define` 优先；没有就读同名进程环境变量——`tool/run_windows_itest.ps1`
/// 不透传自定义 dart-define，但会把父进程环境原样传给运行器。
String _param(String name, {String defaultValue = ''}) {
  final String fromDefine = switch (name) {
    'ASR_MODEL_SEED' => const String.fromEnvironment('ASR_MODEL_SEED'),
    'ASR_LANG' => const String.fromEnvironment('ASR_LANG'),
    'ASR_AUDIO' => const String.fromEnvironment('ASR_AUDIO'),
    'ASR_EXPECT' => const String.fromEnvironment('ASR_EXPECT'),
    'ASR_OUT' => const String.fromEnvironment('ASR_OUT'),
    'ASR_ONLY' => const String.fromEnvironment('ASR_ONLY'),
    'ASR_CHUNK_SECONDS' => const String.fromEnvironment('ASR_CHUNK_SECONDS'),
    'ASR_PIPELINE' => const String.fromEnvironment('ASR_PIPELINE'),
    'ASR_BUCKETS' => const String.fromEnvironment('ASR_BUCKETS'),
    'ASR_FP16' => const String.fromEnvironment('ASR_FP16'),
    'ASR_GREEDY_SESSIONS' => const String.fromEnvironment(
        'ASR_GREEDY_SESSIONS',
      ),
    'ASR_GREEDY_THREADS' => const String.fromEnvironment('ASR_GREEDY_THREADS'),
    'ASR_PCM_PARALLEL' => const String.fromEnvironment('ASR_PCM_PARALLEL'),
    _ => '',
  };
  if (fromDefine.isNotEmpty) return fromDefine;
  final String? fromEnv = Platform.environment[name];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return defaultValue;
}

final String _kSeed = _param('ASR_MODEL_SEED');
final AsrLanguage _kLang =
    AsrLanguage.fromTag(_param('ASR_LANG', defaultValue: 'ja')) ??
        AsrLanguage.japanese;
final String _kAudio = _param(
  'ASR_AUDIO',
  defaultValue: 'test/asr/fixtures/ja_tts_16k.wav',
);
final String _kExpect = _param('ASR_EXPECT', defaultValue: '今日はいい天気ですね');

/// ASR_EXPECT=ANY：不断言文本（探索性跑一个还没有参考文本的语言包，只看输出）。
void _expectTranscript(String actual) {
  if (_kExpect == 'ANY') return;
  expect(_normalize(actual), contains(_normalize(_kExpect)));
}

List<AsrEncoderBucket>? _bucketsFromEnv(String spec) {
  if (spec.isEmpty) return null;
  return <AsrEncoderBucket>[
    for (final String item in spec.split(','))
      AsrEncoderBucket(
        frames: int.parse(item.split('x')[0]),
        batch: int.parse(item.split('x')[1]),
      ),
  ];
}

String _normalize(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\s、。！？!?,.\x27"“”’]'), '');

Future<
    ({
      String text,
      AsrTranscribeResult result,
      OnnxProviderResolution resolution,
      Duration wall,
    })> _runOnce({
  required AsrModelStore store,
  required Directory jobsRoot,
  required String audio,
  required AsrAccelerationPreference preference,
  required AsrEncoderVariant variant,
}) async {
  final AsrTranscriptionService service = AsrTranscriptionService(
    openStore: (AsrLanguage _) async => store,
    jobsRoot: () async => jobsRoot,
    // 缺省 60 s 让检查点/续跑路径多走几次；ASR_CHUNK_SECONDS=300 对齐生产值拿速度数。
    chunkSeconds: int.tryParse(_param('ASR_CHUNK_SECONDS')) ?? 60,
    // ASR_PIPELINE=0：逐批串行解码（与三段式流水线做 A/B）。
    usePipeline: _param('ASR_PIPELINE') != '0',
    // ASR_BUCKETS=560x32,1120x16：静态桶表覆盖（帧数x行数，按帧数递增）。
    staticBucketsOverride: _bucketsFromEnv(_param('ASR_BUCKETS')),
    // ASR_FP16=0：GPU 上仍用 fp32 编码器（与 fp16 派生图做 A/B）。
    useFp16Encoder: _param('ASR_FP16') != '0',
    // ASR_GREEDY_SESSIONS / ASR_GREEDY_THREADS：贪心 Loop 图会话数 / 每会话
    // intra-op 线程数扫描；ASR_PCM_PARALLEL：同时在解的 ffmpeg 块数。
    greedySessions: int.tryParse(_param('ASR_GREEDY_SESSIONS')),
    greedyIntraOpThreads: int.tryParse(_param('ASR_GREEDY_THREADS')),
    pcm: FfmpegAsrPcmSource(
      parallelism: int.tryParse(_param('ASR_PCM_PARALLEL')),
    ),
  );
  await service.discard(<String>[audio], _kLang);
  final Stopwatch loadClock = Stopwatch()..start();
  final AsrRunningTranscription running = await service.start(
    audioPaths: <String>[audio],
    language: _kLang,
    variant: variant,
    preference: preference,
  );
  loadClock.stop();
  // ignore: avoid_print
  print(
    '[asr-e2e][load] variant=${variant.name} preference=${preference.name} '
    'engineLoad=${loadClock.elapsedMilliseconds}ms '
    'resolution=${running.encoderResolution} '
    'fp16=${running.encoderFp16} '
    'greedyGraph=${running.greedyGraphAvailable}'
    '${running.greedyUnavailableReason == null ? '' : ' (unavailable: ${running.greedyUnavailableReason})'}',
  );
  final Stopwatch sw = Stopwatch()..start();
  try {
    AsrTranscribeResult? result;
    await for (final AsrTranscribeEvent e in running.run()) {
      if (e is AsrTranscribeFinishedEvent) result = e.result;
      if (e is AsrTranscribeProgressEvent) {
        // 时间线：音频以什么速度穿过前端（ffmpeg → VAD → 攒批）、段何时落盘。
        // ignore: avoid_print
        print(
          '[asr-e2e][progress] t=${sw.elapsedMilliseconds}ms '
          'processedMs=${e.progress.processedMs} '
          'segmentsDone=${e.progress.segmentsDone} '
          'speechMs=${e.progress.speechMs}',
        );
      }
    }
    sw.stop();
    expect(result, isNotNull, reason: '任务没有以 finished 结束');
    // ignore: avoid_print
    print('[asr-e2e][stats] variant=${variant.name} ${running.decodeStats}');
    // ASR_OUT=<dir>：把产物 SRT 拷出去（按 variant 命名），供
    // test/asr/realdata/asr_realdata_match_test.dart 与 SubPlz 字幕对照。
    final String outDir = _param('ASR_OUT');
    if (outDir.isNotEmpty) {
      await Directory(outDir).create(recursive: true);
      final String dst = p.join(outDir, 'transcript_${variant.name}.srt');
      await File(result!.srtPath).copy(dst);
      // 逐 token 时间 sidecar 一起拷（realdata 测试据此做正文句界重切对照）。
      final File tokens = File(
        p.join(p.dirname(result.srtPath), AsrJobFiles.cueTokens),
      );
      if (tokens.existsSync()) {
        await tokens.copy(
          p.join(outDir, 'transcript_${variant.name}.tokens.jsonl'),
        );
      }
      // ignore: avoid_print
      print('[asr-e2e][out] $dst');
    }
    final List<AsrTranscribedSegment> segments =
        await AsrTranscribeJob.loadSegments(
      await service.jobDirFor(<String>[audio], _kLang),
    );
    final String text =
        segments.map((AsrTranscribedSegment s) => s.text).join();
    return (
      text: text,
      result: result!,
      resolution: running.encoderResolution,
      wall: sw.elapsed,
    );
  } finally {
    await running.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory jobsRoot;
  late AsrModelStore store;
  late String audio;

  setUpAll(() async {
    expect(
      _kSeed,
      isNotEmpty,
      reason: '需要 --dart-define=ASR_MODEL_SEED=<模型目录>',
    );
    store = AsrModelStore(Directory(_kSeed), asrModelPackFor(_kLang));
    expect(
      store.isReady(AsrEncoderVariant.int8) ||
          store.isReady(AsrEncoderVariant.fp32),
      isTrue,
      reason: '模型目录缺 int8 / fp32 任一变体的全套文件：${store.dir.path}',
    );
    audio = p.isAbsolute(_kAudio)
        ? _kAudio
        : p.join(Directory.current.path, _kAudio);
    expect(File(audio).existsSync(), isTrue, reason: '音频不存在：$audio');
    jobsRoot = await Directory.systemTemp.createTemp('fushi_asr_e2e_');
  });

  tearDownAll(() async {
    if (jobsRoot.existsSync()) await jobsRoot.delete(recursive: true);
  });

  /// ASR_ONLY=gpu 时跳过 CPU 与分阶段计时用例（整本 7 小时的音频只跑 GPU）；
  /// ASR_ONLY=cpu 只跑 CPU int8 用例（量 CPU 侧成批 / padding，不跑 200 s 的
  /// silero 分阶段计时）。
  final bool onlyGpu = _param('ASR_ONLY') == 'gpu';
  final bool onlyCpu = _param('ASR_ONLY') == 'cpu';

  testWidgets('CPU int8：真模型把话读出来并生成 SRT', (WidgetTester tester) async {
    if (onlyGpu) return;
    if (!store.isReady(AsrEncoderVariant.int8)) {
      // ignore: avoid_print
      print(
        '[asr-e2e][cpu-int8] skipped: int8 encoder not in ${store.dir.path}',
      );
      return;
    }
    final r = await _runOnce(
      store: store,
      jobsRoot: jobsRoot,
      audio: audio,
      preference: AsrAccelerationPreference.cpuOnly,
      variant: AsrEncoderVariant.int8,
    );
    // ignore: avoid_print
    print(
      '[asr-e2e][cpu-int8] text="${r.text}" cues=${r.result.cueCount} '
      'segments=${r.result.segmentCount} audioMs=${r.result.totalMs} '
      'wall=${r.wall.inMilliseconds}ms '
      'rtf=${(r.wall.inMilliseconds / r.result.totalMs).toStringAsFixed(3)} '
      'resolution=${r.resolution}',
    );
    expect(r.resolution.effective, OnnxExecutionProvider.cpu);
    _expectTranscript(r.text);
    expect(r.result.cueCount, greaterThan(0));
    final String srt = File(r.result.srtPath).readAsStringSync();
    expect(srt, contains('-->'));
    _expectTranscript(srt);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('GPU fp32（auto）：真加速 EP 跑通且文本一致', (WidgetTester tester) async {
    if (onlyCpu) return;
    if (!store.isReady(AsrEncoderVariant.fp32)) {
      // ignore: avoid_print
      print(
        '[asr-e2e][gpu-fp32] skipped: fp32 encoder not in ${store.dir.path}',
      );
      return;
    }
    final Set<OnnxExecutionProvider> available =
        await AsrEngineLoader().availableAcceleratedProviders();
    // ignore: avoid_print
    print('[asr-e2e][gpu-fp32] available accelerated EPs: $available');
    final r = await _runOnce(
      store: store,
      jobsRoot: jobsRoot,
      audio: audio,
      preference: AsrAccelerationPreference.auto,
      variant: AsrEncoderVariant.fp32,
    );
    // ignore: avoid_print
    print(
      '[asr-e2e][gpu-fp32] text="${r.text}" cues=${r.result.cueCount} '
      'segments=${r.result.segmentCount} audioMs=${r.result.totalMs} '
      'wall=${r.wall.inMilliseconds}ms '
      'rtf=${(r.wall.inMilliseconds / r.result.totalMs).toStringAsFixed(3)} '
      'resolution=${r.resolution}',
    );
    _expectTranscript(r.text);
    if (available.isNotEmpty) {
      // 有加速 EP 编译在运行时里：必须真落到它上，不允许静默退 CPU。
      expect(
        r.resolution.effective,
        isNot(OnnxExecutionProvider.cpu),
        reason: '有加速 EP 却退到 CPU：${r.resolution}',
      );
      expect(r.resolution.didFallBack, isFalse, reason: '$r.resolution');
    }
  }, timeout: const Timeout(Duration(minutes: 40)));

  testWidgets(
    '分阶段计时：ffmpeg / VAD / ASR（CPU int8 与 GPU fp32）',
    (WidgetTester tester) async {
      if (onlyGpu || onlyCpu) return;
      if (store.isReady(AsrEncoderVariant.int8)) {
        await _phaseBenchmark(
          store: store,
          audio: audio,
          preference: AsrAccelerationPreference.cpuOnly,
          variant: AsrEncoderVariant.int8,
          label: 'cpu-int8',
        );
      }
      if (store.isReady(AsrEncoderVariant.fp32)) {
        await _phaseBenchmark(
          store: store,
          audio: audio,
          preference: AsrAccelerationPreference.auto,
          variant: AsrEncoderVariant.fp32,
          label: 'gpu-fp32',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

/// 仅为拿数：把 VAD 与解码分开计时，回答「时间花在哪」。不做正确性断言以外的检查。
Future<void> _phaseBenchmark({
  required AsrModelStore store,
  required String audio,
  required AsrAccelerationPreference preference,
  required AsrEncoderVariant variant,
  required String label,
}) async {
  final AsrEngineSessions sessions = await AsrEngineLoader().load(
    store: store,
    variant: variant,
    preference: preference,
  );
  try {
    final FfmpegAsrPcmSource pcm = FfmpegAsrPcmSource();
    final Stopwatch decodeClock = Stopwatch()..start();
    final List<AsrPcmChunk> chunks =
        await pcm.decode(audio, chunkSeconds: 600).toList();
    decodeClock.stop();
    final int samples = chunks.fold<int>(
      0,
      (int a, AsrPcmChunk c) => a + c.samples.length,
    );
    // 能量切段（默认）与 silero 切段各量一次；后续 ASR 用能量切段的产物。
    final Stopwatch sileroClock = Stopwatch()..start();
    final AsrVadSegmenter silero = AsrVadSegmenter(session: sessions.vad);
    int sileroSegments = 0;
    for (final AsrPcmChunk c in chunks) {
      sileroSegments += (await silero.feed(c)).length;
    }
    sileroSegments += (await silero.flush()).length;
    sileroClock.stop();
    final AsrVadSegmenter vad = AsrVadSegmenter(scorer: EnergyVadScorer());
    final Stopwatch vadClock = Stopwatch()..start();
    final List<AsrSpeechSegment> segments = <AsrSpeechSegment>[];
    for (final AsrPcmChunk c in chunks) {
      segments.addAll(await vad.feed(c));
    }
    segments.addAll(await vad.flush());
    vadClock.stop();
    final AsrSegmentDecoder decoder = sessions.newDecoder();
    // ignore: avoid_print
    print(
      '[asr-e2e][bench][$label] greedyGraph=${decoder is AsrTransducerDecoder && decoder.usesGreedyGraph} '
      '${sessions.greedyUnavailableReason ?? ''}',
    );
    // 预热一次（DirectML 首次前向含着色器编译，不算进稳态）。
    if (segments.isNotEmpty) {
      await decoder.decodeBatch(<AsrSpeechSegment>[segments.first]);
    }
    final Stopwatch asrClock = Stopwatch()..start();
    int tokens = 0;
    final int batchSize = AsrTranscriptionService.defaultBatchSizeFor(
      sessions.encoderResolution.effective,
    );
    for (int i = 0; i < segments.length; i += batchSize) {
      final List<AsrSpeechSegment> batch = segments.sublist(
        i,
        i + batchSize > segments.length ? segments.length : i + batchSize,
      );
      for (final AsrDecodedSegment d in await decoder.decodeBatch(batch)) {
        tokens += d.tokens.length;
      }
    }
    asrClock.stop();
    // ignore: avoid_print
    print(
      '[asr-e2e][bench][$label] ${decoder.stats} '
      'staticUnavailable=${sessions.staticEncoders?.unavailableReasons}',
    );
    final int audioMs = samples * 1000 ~/ kAsrSampleRate;
    final int speechMs = segments.fold<int>(
      0,
      (int a, AsrSpeechSegment s) => a + s.lengthMs,
    );
    // ignore: avoid_print
    print(
      '[asr-e2e][bench][$label] resolution=${sessions.encoderResolution} '
      'audio=${audioMs}ms speech=${speechMs}ms segments=${segments.length} tokens=$tokens '
      'ffmpeg=${decodeClock.elapsedMilliseconds}ms '
      'vad(energy)=${vadClock.elapsedMilliseconds}ms '
      'vad(silero)=${sileroClock.elapsedMilliseconds}ms/${sileroSegments}seg '
      'batch=$batchSize '
      'asr(warm)=${asrClock.elapsedMilliseconds}ms '
      'rtf(asr)=${(asrClock.elapsedMilliseconds / audioMs).toStringAsFixed(3)} '
      'rtf(total)=${((decodeClock.elapsedMilliseconds + vadClock.elapsedMilliseconds + asrClock.elapsedMilliseconds) / audioMs).toStringAsFixed(3)}',
    );
  } finally {
    await sessions.close();
  }
}
