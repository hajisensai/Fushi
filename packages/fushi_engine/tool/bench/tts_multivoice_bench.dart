/// 多声优实时朗读的真实引擎实测：吞吐（能撑几倍速）+ 倍速播放模拟（卡不卡）。
///
/// 用真实小说文本 + 真实引擎（默认微软 Edge）驱动 [TtsSynthesisScheduler.voices]：
/// - 旁白一个声音，台词（「」开头的段落）在两个角色声音间轮流（模拟两人对话；真实
///   朗读按制作台选角表分派，这里没有 LLM 标注，只求请求形态一致）；
/// - 分句：段落内按句末标点切，同一段落、同一声音内的短句合并（与朗读同口径）；
/// - 每轮用全新的临时缓存（冷启动，不吃上一轮的结果）。
///
/// 用法（在 packages/fushi_engine 下）：
///   dart run tool/bench/tts_multivoice_bench.dart --text <utf8 文本> \
///     [--sentences 100] [--concurrency 1,2,3] [--speeds 2,3,4] \
///     [--narrator ja-JP-NanamiNeural] [--voices ja-JP-KeitaNeural,ja-JP-AoiNeural]
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

Future<void> main(List<String> argv) async {
  final Map<String, String> args = _parseArgs(argv);
  final String? textPath = args['text'];
  if (textPath == null) {
    stderr.writeln('missing --text <file>');
    exitCode = 64;
    return;
  }
  final int sentenceCount = int.parse(args['sentences'] ?? '100');
  final List<int> concurrencies = _ints(args['concurrency'] ?? '1,2,3');
  final List<double> speeds = <double>[
    for (final String s in (args['speeds'] ?? '2,3,4').split(','))
      double.parse(s),
  ];
  final String narrator = args['narrator'] ?? 'ja-JP-NanamiNeural';
  final List<String> characters = (args['voices'] ?? 'ja-JP-KeitaNeural').split(
    ',',
  );

  final List<_Sentence> all = _split(
    File(textPath).readAsStringSync(),
    narratorVoice: narrator,
    characterVoices: characters,
  );
  final List<_Sentence> sentences = all.take(sentenceCount).toList();
  final int chars = sentences.fold(
    0,
    (int n, _Sentence s) => n + s.text.length,
  );
  final Map<String, int> perVoice = <String, int>{};
  for (final _Sentence s in sentences) {
    perVoice[s.voice] = (perVoice[s.voice] ?? 0) + 1;
  }
  stdout.writeln('# 文本：${sentences.length} 句 / $chars 字；按声音：$perVoice');

  if (args['skip-throughput'] != 'true') {
    stdout.writeln('\n## 吞吐（冷缓存一次合成完全部句子）');
    stdout.writeln(
      '| 每声音并发 | 总在途上限 | 耗时 s | 音频 s | 吞吐（×实时） | 单句延迟 p50 / p90 ms | 失败重试 |',
    );
    stdout.writeln('|---|---|---|---|---|---|---|');
    for (final int c in concurrencies) {
      final _Run run = await _Run.create(sentences, concurrency: c);
      final Stopwatch sw = Stopwatch()..start();
      run.scheduler
        ..setLookahead(sentences.length)
        ..setCursor(0);
      await run.allReady();
      sw.stop();
      final int audioMs = run.totalAudioMs();
      stdout.writeln(
        '| $c | ${c * run.voiceCount} | ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} '
        '| ${(audioMs / 1000).toStringAsFixed(1)} '
        '| ${(audioMs / sw.elapsedMilliseconds).toStringAsFixed(2)} '
        '| ${run.latencyPercentile(0.5)} / ${run.latencyPercentile(0.9)} '
        '| ${run.attemptFailures} |',
      );
      await run.dispose();
    }
  }

  final int playConcurrency = int.parse(args['play-concurrency'] ?? '2');
  stdout.writeln('\n## 倍速播放模拟（每声音并发 $playConcurrency，冷启动，按真实音频时长 ÷ 倍速消费）');
  stdout.writeln('| 倍速 | 预取 | 首句等待 ms | 卡顿次数 | 卡顿总时长 s | 最长一次 ms | 播放总时长 s |');
  stdout.writeln('|---|---|---|---|---|---|---|');
  for (final double speed in speeds) {
    for (final bool prerender in <bool>[true, false]) {
      final _Run run = await _Run.create(
        sentences,
        concurrency: playConcurrency,
      );
      final _PlayResult r = await _play(
        run,
        speed: speed,
        prerender: prerender,
      );
      stdout.writeln(
        '| $speed× | ${prerender ? '提前生成' : '60 秒窗口'} | ${r.firstWaitMs} '
        '| ${r.stalls} | ${(r.stallMs / 1000).toStringAsFixed(1)} '
        '| ${r.longestStallMs} | ${(r.wallMs / 1000).toStringAsFixed(1)} |',
      );
      await run.dispose();
    }
  }
  exit(0);
}

class _PlayResult {
  _PlayResult(
    this.firstWaitMs,
    this.stalls,
    this.stallMs,
    this.longestStallMs,
    this.wallMs,
  );
  final int firstWaitMs;
  final int stalls;
  final int stallMs;
  final int longestStallMs;
  final int wallMs;
}

/// 模拟播放器：要第 i 句 → 等它合成好（等待即卡顿，首句单记）→ 按时长 ÷ 倍速播完。
/// 预取窗口：提前生成 = 全部句子（相当于「本章剩余 + 下一章」覆盖整段测试文本）；
/// 60 秒窗口 = 旧逻辑（当前句后 60 秒 × 倍速的估计时长，最少 3 句、最多 60 句）。
Future<_PlayResult> _play(
  _Run run, {
  required double speed,
  required bool prerender,
}) async {
  final TtsSynthesisScheduler s = run.scheduler;
  final int n = run.sentences.length;
  int windowFor(int i) {
    if (prerender) return n;
    final int targetMs = (60000 * speed).round();
    int sum = 0;
    int count = 0;
    for (int j = i + 1; j < n && sum < targetMs; j++) {
      sum += 300 + run.sentences[j].text.length * 140;
      count++;
    }
    return count.clamp(3, 60);
  }

  // 重试用尽的失败：记下并继续（真实朗读会停下提示用户，这里只统计）。
  final StreamSubscription<TtsSegmentEvent> sub = s.events.listen((
    TtsSegmentEvent e,
  ) {
    if (e is TtsSegmentFailed) {
      stderr.writeln('play failed #${e.index}: ${e.failure}');
      s.resume();
    }
  });
  final Stopwatch wall = Stopwatch()..start();
  int firstWait = 0;
  int stalls = 0;
  int stallMs = 0;
  int longest = 0;
  for (int i = 0; i < n; i++) {
    s
      ..setLookahead(windowFor(i))
      ..setCursor(i);
    final Stopwatch wait = Stopwatch()..start();
    final TtsCachedAudio audio = await s.ensure(i);
    wait.stop();
    final int waited = wait.elapsedMilliseconds;
    if (i == 0) {
      firstWait = waited;
    } else if (waited > 50) {
      stalls++;
      stallMs += waited;
      if (waited > longest) longest = waited;
    }
    await Future<void>.delayed(
      Duration(milliseconds: (audio.durationMs / speed).round()),
    );
  }
  wall.stop();
  await sub.cancel();
  return _PlayResult(
    firstWait,
    stalls,
    stallMs,
    longest,
    wall.elapsedMilliseconds,
  );
}

class _Run {
  _Run._(
    this.sentences,
    this.scheduler,
    this.root,
    this.providers,
    this.voiceCount,
  );

  static Future<_Run> create(
    List<_Sentence> sentences, {
    required int concurrency,
  }) async {
    final Directory root = await Directory.systemTemp.createTemp('tts_bench_');
    final TtsAudioCache cache = TtsAudioCache(root: root);
    const EdgeTtsDescriptor descriptor = EdgeTtsDescriptor();
    final List<String> voiceNames = <String>[];
    final List<int> voiceOf = <int>[
      for (final _Sentence s in sentences)
        () {
          final int at = voiceNames.indexOf(s.voice);
          if (at >= 0) return at;
          voiceNames.add(s.voice);
          return voiceNames.length - 1;
        }(),
    ];
    final List<_TimedProvider> providers = <_TimedProvider>[];
    final List<TtsSchedulerVoice> voices = <TtsSchedulerVoice>[];
    for (final String name in voiceNames) {
      final TtsVoicePreset preset = TtsVoicePreset(
        id: name,
        providerId: EdgeTtsDescriptor.providerId,
        name: name,
        params: <String, String>{EdgeTtsDescriptor.voiceKey: name},
      );
      final _TimedProvider p = _TimedProvider(
        descriptor.create(preset, const TtsHost()),
      );
      providers.add(p);
      voices.add(
        TtsSchedulerVoice(
          provider: p,
          audioIdentity: descriptor.audioIdentity(preset),
          concurrency: concurrency,
        ),
      );
    }
    final TtsSynthesisScheduler scheduler = TtsSynthesisScheduler.voices(
      voices: voices,
      voiceOf: voiceOf,
      cache: cache,
      texts: <String>[for (final _Sentence s in sentences) s.text],
      keepPinned: sentences.length,
    );
    return _Run._(sentences, scheduler, root, providers, voiceNames.length);
  }

  final List<_Sentence> sentences;
  final TtsSynthesisScheduler scheduler;
  final Directory root;
  final List<_TimedProvider> providers;
  final int voiceCount;

  /// 全部句子登记为「播放器要的」并等齐：重试用尽的失败会停下调度，记下后 resume
  /// 重新请求（后台预取失败的句子不会自己重来，必须经 ensure）。
  Future<void> allReady() async {
    final StreamSubscription<TtsSegmentEvent> sub = scheduler.events.listen((
      TtsSegmentEvent e,
    ) {
      if (e is TtsSegmentFailed) {
        stderr.writeln('failed #${e.index}: ${e.failure}');
        if (e.blocking) scheduler.resume();
      }
    });
    await Future.wait(<Future<TtsCachedAudio>>[
      for (int i = 0; i < sentences.length; i++) scheduler.ensure(i),
    ]);
    await sub.cancel();
  }

  int totalAudioMs() {
    int sum = 0;
    for (int i = 0; i < sentences.length; i++) {
      sum += scheduler.readyAudio(i)?.durationMs ?? 0;
    }
    return sum;
  }

  int get attemptFailures =>
      providers.fold(0, (int n, _TimedProvider p) => n + p.failures);

  int latencyPercentile(double q) {
    final List<int> all = <int>[
      for (final _TimedProvider p in providers) ...p.latencies,
    ]..sort();
    if (all.isEmpty) return 0;
    return all[((all.length - 1) * q).round()];
  }

  Future<void> dispose() async {
    await scheduler.dispose();
    for (final _TimedProvider p in providers) {
      await p.dispose();
    }
    await root.delete(recursive: true);
  }
}

/// 给每次合成请求计时（含重试的每一次尝试）。
class _TimedProvider extends TtsProvider {
  _TimedProvider(this.inner);

  final TtsProvider inner;
  final List<int> latencies = <int>[];
  int failures = 0;

  @override
  TtsCapabilities get capabilities => inner.capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      final TtsResult r = await inner.synthesize(
        text,
        outputPath: outputPath,
        cancel: cancel,
      );
      latencies.add(sw.elapsedMilliseconds);
      return r;
    } on TtsFailure catch (f) {
      if (f.code != TtsFailureCode.cancelled) failures++;
      rethrow;
    }
  }

  @override
  Future<void> dispose() => inner.dispose();
}

class _Sentence {
  _Sentence(this.text, this.voice);
  final String text;
  final String voice;
}

final RegExp _sentenceEnd = RegExp(r'[^。！？!?]*[。！？!?]+[」』）)]*|[^。！？!?]+$');

/// 段落 → 句子；台词段落在角色声音间轮流，其余旁白。同段同声音的短句（<16 字）合并，
/// 合并后不超过 300 字（Edge 单次上限）。
List<_Sentence> _split(
  String text, {
  required String narratorVoice,
  required List<String> characterVoices,
}) {
  final List<_Sentence> out = <_Sentence>[];
  int turn = 0;
  for (final String raw in text.split('\n')) {
    final String para = raw.trim();
    if (para.isEmpty) continue;
    final bool dialogue = para.startsWith('「') || para.startsWith('『');
    final String voice = dialogue
        ? characterVoices[turn++ % characterVoices.length]
        : narratorVoice;
    final List<String> parts = <String>[
      for (final RegExpMatch m in _sentenceEnd.allMatches(para))
        if (m.group(0)!.trim().isNotEmpty) m.group(0)!.trim(),
    ];
    final List<String> merged = <String>[];
    for (final String part in parts) {
      if (merged.isNotEmpty &&
          (merged.last.length < 16 || part.length < 16) &&
          merged.last.length + part.length <= 300) {
        merged[merged.length - 1] = merged.last + part;
      } else {
        merged.add(part);
      }
    }
    for (final String s in merged) {
      out.add(_Sentence(s, voice));
    }
  }
  return out;
}

Map<String, String> _parseArgs(List<String> argv) {
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < argv.length; i++) {
    final String a = argv[i];
    if (!a.startsWith('--')) continue;
    final String key = a.substring(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

List<int> _ints(String csv) => <int>[
  for (final String s in csv.split(',')) int.parse(s.trim()),
];
