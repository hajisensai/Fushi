/// [MangaRenderBackend] 的 app 实现：TTS 缓存 + 引擎实例 + ffmpeg。
///
/// - 声音 = 声音预设 id；每份预设只解析一次。预设缺失 / 引擎不可用 / 参数不完整是
///   **这一句**的失败（`voice_missing` / `voice_unavailable` / `voice_incomplete`），
///   进未配音账本，可以换声音补回，不让整卷失败；
/// - 每个片段经 [TtsAudioCache] 合成（键 = 音色身份 + 生效的演出参数 + 片段文字），
///   在线引擎的临时失败走 [ttsWithRetry]；同一份预设同时在途的请求不超过它的并发上限；
/// - 一句的各片段用 ffmpeg 拼成一个 m4a，同时裁掉首尾静音（停顿只由时间表给，设计
///   §7），统一 44.1 kHz 单声道 AAC；有声书片段按 cue 边界剪，不裁静音；
/// - 占位静音直接写 PCM WAV（精确时长，不经 ffmpeg）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart'
    show buildTtsSilenceWav, kTtsOutputSampleRate;
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart'
    show readMp4PresentationDurationMs;
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart'
    show TtsRenderGate;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

/// 首尾静音判据：低于 −50 dB 持续 50 ms 以上算静音。
const String kMangaTrimFilter =
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse,'
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse';

/// 一句（[inputs] 是它的各片段，按顺序）编码成 m4a 的 ffmpeg 参数：每个输入先统一成
/// 44.1 kHz 单声道再拼接，拼完裁首尾静音。纯函数，单测覆盖。
List<String> buildMangaLineEncodeArgs({
  required List<String> inputs,
  required String outputPath,
}) {
  final StringBuffer graph = StringBuffer();
  for (int i = 0; i < inputs.length; i++) {
    graph.write(
      '[$i:a]aresample=$kTtsOutputSampleRate,'
      'aformat=sample_fmts=fltp:channel_layouts=mono[a$i];',
    );
  }
  for (int i = 0; i < inputs.length; i++) {
    graph.write('[a$i]');
  }
  graph.write('concat=n=${inputs.length}:v=0:a=1[c];[c]$kMangaTrimFilter[out]');
  return <String>[
    '-y',
    for (final String input in inputs) ...<String>['-i', input],
    '-filter_complex',
    graph.toString(),
    '-map',
    '[out]',
    '-vn',
    '-ac',
    '1',
    '-c:a',
    'aac',
    '-b:a',
    '96k',
    '-f',
    'mp4',
    outputPath,
  ];
}

/// 从有声书文件剪 `[startMs, endMs)` 的 ffmpeg 参数（`-ss` 放在 `-i` 前：音频按解码
/// 精确定位）。纯函数，单测覆盖。
List<String> buildMangaClipArgs({
  required String sourcePath,
  required int startMs,
  required int endMs,
  required String outputPath,
}) => <String>[
  '-y',
  '-ss',
  (startMs / 1000).toStringAsFixed(3),
  '-t',
  ((endMs - startMs) / 1000).toStringAsFixed(3),
  '-i',
  sourcePath,
  '-vn',
  '-af',
  'aresample=$kTtsOutputSampleRate',
  '-ac',
  '1',
  '-c:a',
  'aac',
  '-b:a',
  '96k',
  '-f',
  'mp4',
  outputPath,
];

/// 一次 ffmpeg 没进度多久算卡死。
const Duration kMangaEncodeStallTimeout = Duration(seconds: 60);

class _MangaVoice {
  const _MangaVoice({
    required this.provider,
    required this.identity,
    required this.gate,
  });

  final TtsProvider provider;
  final Map<String, Object?> identity;
  final TtsRenderGate gate;
}

class AppMangaRenderBackend implements MangaRenderBackend {
  AppMangaRenderBackend({
    required TtsServices tts,
    required TtsAudioCache cache,
    required FfmpegBackend ffmpeg,
    required void Function(String source, String summary) log,
    List<String>? clipSources,
  }) : _tts = tts,
       _cache = cache,
       _ffmpeg = ffmpeg,
       _log = log,
       _clipSources = clipSources;

  final TtsServices _tts;
  final TtsAudioCache _cache;
  final FfmpegBackend _ffmpeg;
  final void Function(String source, String summary) _log;

  /// 关联有声书的音频文件（绝对路径，`MangaAudiobookClip.fileIndex` 的含义）；null =
  /// 没关联或已不在。
  final List<String>? _clipSources;

  final Map<String, Future<_MangaVoice>> _voices =
      <String, Future<_MangaVoice>>{};

  /// 各引擎自己的并发上限在 [_MangaVoice.gate] 里管；这里只是同时在出的句数（含
  /// 编码），给 4 句足以让在线引擎跑满、又不至于同时起太多 ffmpeg。
  @override
  int get parallelism => 4;

  Future<_MangaVoice> _voice(String presetId) =>
      _voices[presetId] ??= _resolve(presetId);

  Future<_MangaVoice> _resolve(String presetId) async {
    TtsVoicePreset? preset;
    for (final TtsVoicePreset candidate in _tts.store.loadPresets()) {
      if (candidate.id == presetId) preset = candidate;
    }
    if (preset == null) throw const MangaLineFailure('voice_missing');
    final TtsProviderDescriptor? descriptor = _tts.registry[preset.providerId];
    if (descriptor == null || !descriptor.isAvailable) {
      throw const MangaLineFailure('voice_unavailable');
    }
    if (descriptor.validate(preset).isNotEmpty) {
      throw const MangaLineFailure('voice_incomplete');
    }
    return _MangaVoice(
      provider: descriptor.create(preset, _tts.host),
      identity: descriptor.audioIdentity(preset),
      gate: TtsRenderGate(ttsEffectiveConcurrency(descriptor, preset)),
    );
  }

  /// 释放引擎实例（任务结束时调用）。
  Future<void> dispose() async {
    for (final Future<_MangaVoice> f in _voices.values) {
      try {
        await (await f).provider.dispose();
      } on MangaLineFailure {
        // 解析失败的声音没有实例可放。
      }
    }
    _voices.clear();
  }

  @override
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    final _MangaVoice v = await _voice(voice);
    final TtsDirectionSupport support = ttsDirectionSupportOf(v.provider);
    final TtsCancelToken ttsCancel = TtsCancelToken();
    cancel.onCancel(ttsCancel.cancel);
    final List<String> keys = <String>[];
    final List<String> paths = <String>[];
    try {
      for (final String segment in segments) {
        final TtsDirection direction = effectiveTtsDirection(
          support,
          TtsDirection(
            seed: seed,
            // 短句定长只给不挂 LoRA 的声音（handoff：挂 LoRA 的时长预测可靠）。
            durationSeconds: support.adapter
                ? null
                : mangaShortLineDurationSeconds(segment),
          ),
        );
        final String key = TtsAudioCache.keyFor(<String, Object?>{
          ...v.identity,
          ...direction.cacheIdentity,
        }, segment);
        // 先 pin 再合成：obtain 发布新文件时会顺手淘汰，未 pin 的前一片段可能被挤掉。
        _cache.pin(key);
        keys.add(key);
        await v.gate.acquire();
        try {
          final TtsCachedAudio audio = await ttsWithRetry(
            () => _cache.obtain(
              key,
              (String out) => synthesizeWithDirection(
                v.provider,
                segment,
                outputPath: out,
                cancel: ttsCancel,
                direction: direction,
              ),
            ),
            cancel: ttsCancel,
          );
          paths.add(audio.path);
        } finally {
          v.gate.release();
        }
      }
      cancel.throwIfCancelled();
      await _runFfmpeg(
        buildMangaLineEncodeArgs(inputs: paths, outputPath: outputPath),
        outputPath: outputPath,
        cancel: cancel,
        source: 'MangaRender.encode',
      );
    } on TtsFailure catch (e) {
      if (cancel.isCancelled || e.code == TtsFailureCode.cancelled) {
        cancel.throwIfCancelled();
      }
      rethrow;
    } finally {
      for (final String key in keys) {
        _cache.unpin(key);
      }
    }
    return await readMp4PresentationDurationMs(outputPath) ??
        (throw const MangaLineFailure('encode_failed', 'no duration'));
  }

  @override
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    final List<String>? sources = _clipSources;
    if (sources == null ||
        clip.fileIndex >= sources.length ||
        !await File(sources[clip.fileIndex]).exists()) {
      throw const MangaLineFailure('clip_source_missing');
    }
    await _runFfmpeg(
      buildMangaClipArgs(
        sourcePath: sources[clip.fileIndex],
        startMs: clip.startMs,
        endMs: clip.endMs,
        outputPath: outputPath,
      ),
      outputPath: outputPath,
      cancel: cancel,
      source: 'MangaRender.clip',
    );
    return await readMp4PresentationDurationMs(outputPath) ??
        (throw const MangaLineFailure('encode_failed', 'no duration'));
  }

  @override
  Future<int> writeSilence({
    required int ms,
    required String outputPath,
  }) async {
    final File f = File(outputPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(
      buildTtsSilenceWav(ms: ms, sampleRate: kTtsOutputSampleRate, channels: 1),
      flush: true,
    );
    return ms;
  }

  Future<void> _runFfmpeg(
    List<String> args, {
    required String outputPath,
    required TtsRenderCancelToken cancel,
    required String source,
  }) async {
    cancel.throwIfCancelled();
    final Completer<void> cancelled = Completer<void>();
    cancel.onCancel(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    final FfmpegRunResult result = switch (_ffmpeg) {
      final FfmpegWatchedRunner watched => await watched.runWatched(
        args,
        FfmpegWatch(
          stallTimeout: kMangaEncodeStallTimeout,
          cancel: cancelled.future,
        ),
      ),
      final FfmpegBackend plain => await plain.run(
        args,
        kMangaEncodeStallTimeout,
      ),
    };
    cancel.throwIfCancelled();
    final File out = File(outputPath);
    if (!result.isSuccess || !await out.exists() || await out.length() == 0) {
      _log(source, result.failureSummary);
      throw const MangaLineFailure('encode_failed');
    }
  }
}
