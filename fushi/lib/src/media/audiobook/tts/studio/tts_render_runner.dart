/// 有声书制作流程（[TtsRenderRunner] 的 app 实现）。
///
/// 规划 → 按章逐句合成 → 按章编码 m4a → （可选）语音识别校对 → 作为普通有声书
/// 入库。
///
/// - 计划一律走 [buildStudioPlan]：校对结果与「单句重新生成」按计划下标指认句子，
///   与制作台同一口径。
/// - 多声优配音：每句的声音按选角表（`ttsCastStoreFor`）取，没分配的用任务默认
///   声音；缓存键按各句自己的声音算，所以章清单里的键序已含声音——给某个角色换
///   声音只让含它台词的章失效。一章混了不同引擎的音频时先转成统一 PCM 再拼
///   （`tts_render_mix.dart`）。
/// - 逐句音频在 TTS 缓存里，缓存上限 512 MB，整本书可能超过：只在一章合成到编码
///   完成之间 pin 住这一章的键，绝不 pin 整本书。
/// - 已编码的章落在任务工作目录（`<tts_render>/<job.id>/tts_NNN.m4a` + 同名
///   `.json` 记录按序键与每句时长），重跑时键序一致的章直接跳过合成与编码。
/// - 入库只收本次渲染的章：`job.sections` 只选了部分章时，成品有声书就只含这些章
///   （替换这本书原有的有声书音频与 cue），没选的章没有音频。
/// - 工作目录保留到入库成功，成功后删除；失败 / 取消的任务目录归队列管（被同一本书
///   的新任务取代或被移除时删，启动时清孤儿，见 [TtsRenderQueue]）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrAccelerationPreference,
        AsrCueTokenTiming,
        AsrLanguage,
        AsrRunningTranscription,
        AsrTranscribeEvent,
        AsrTranscribeFinishedEvent,
        AsrTranscribePausedEvent,
        AsrTranscribePlan,
        AsrTranscribeProgressEvent,
        AsrTranscribeResult,
        AsrTranscriptionService;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show serializeAudioCuesToSrt;
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart'
    show FfmpegBackend, FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_verify.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 入库后持久目录里的单时间轴字幕文件名。
const String kTtsRenderSrtFileName = 'tts_audiobook.srt';

/// 工作目录里「重新生成的缓存已丢弃」的标记：续跑同一任务时不再丢第二次（否则会把
/// 已经重新合成好的音频又删掉）。
const String _kRegeneratedMarker = 'regenerated.done';

/// 解析好的一份声音预设（每份预设只解析一次）。
class _RenderVoice {
  const _RenderVoice({
    required this.preset,
    required this.descriptor,
    required this.identity,
  });

  final TtsVoicePreset preset;
  final TtsProviderDescriptor descriptor;

  /// 进缓存键的音色身份。
  final Map<String, Object?> identity;
}

/// 合成一句要用的引擎实例；[group] = 预设 id，同组共用一个并发上限。
typedef _SentenceVoice = ({
  TtsProvider provider,
  int maxConcurrency,
  String group,
});

class AppTtsRenderRunner implements TtsRenderRunner {
  AppTtsRenderRunner({required this.appModel});

  final AppModel appModel;

  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    onProgress(TtsRenderJobPhase.planning, 0, 0);
    final TtsServices tts = TtsServices.of(appModel.prefsRepo);
    final ({EpubBookRow row, EpubBook book})? loaded = await loadEpubForStudio(
      appModel.database,
      job.bookKey,
    );
    if (loaded == null) throw const TtsRenderFailure('book_missing');
    final TtsBookPlan plan = await buildStudioPlan(loaded.book, tts);
    final List<TtsRenderChapter> chapters = groupTtsRenderChapters(
      plan.sentences,
      sections: job.sections.toSet(),
    );
    if (chapters.isEmpty) throw const TtsRenderFailure('empty_book');

    // 每句的声音：选角表 → 否则任务默认声音。用到的每份预设各解析一次；选角里的
    // 声音缺失 / 不可用 / 不完整一律如实失败，不悄悄换成别的声音。
    final TtsCast cast = await ttsCastStoreFor(appModel).load(job.bookKey);
    final Map<int, String> presetOf = resolveTtsSentencePresets(
      sentences: plan.sentences,
      indices: <int>[
        for (final TtsRenderChapter c in chapters) ...c.planIndices,
      ],
      cast: cast,
      defaultPresetId: job.presetId,
    );
    final Map<String, _RenderVoice> voices = <String, _RenderVoice>{};
    for (final String presetId in presetOf.values.toSet()) {
      voices[presetId] = _resolveVoice(tts, presetId);
    }
    cancel.throwIfCancelled();

    String keyOf(int planIndex) => TtsAudioCache.keyFor(
      voices[presetOf[planIndex]]!.identity,
      plan.sentences[planIndex].spokenText,
    );
    final TtsAudioCache cache = await tts.cache();
    final Directory workDir = ttsRenderJobWorkDir(
      ttsRenderWorkRoot(appModel),
      job.id,
    );
    await workDir.create(recursive: true);
    await _dropRegenerated(job, presetOf, keyOf, cache, workDir);

    final TtsCancelToken ttsCancel = TtsCancelToken();
    cancel.onCancel(ttsCancel.cancel);
    // 响度归一化：本机 ffmpeg 没有 loudnorm（桌面捆绑的精简版可能没编进去）时
    // 如实记下跳过，不算失败。
    final bool loudnorm =
        job.normalizeLoudness &&
        await _ffmpegHasLoudnorm(resolveFfmpegBackend());
    job.loudnessSkipped = job.normalizeLoudness && !loudnorm;

    final Map<String, TtsProvider> providers = <String, TtsProvider>{};
    final ({List<List<AudioCue>> cues, List<int> fileDurationsMs}) rendered;
    try {
      voices.forEach((String presetId, _RenderVoice voice) {
        providers[presetId] = voice.descriptor.create(voice.preset, tts.host);
      });
      rendered = await _renderChapters(
        job: job,
        plan: plan,
        chapters: chapters,
        keyOf: keyOf,
        voiceOf: (int planIndex) {
          final String presetId = presetOf[planIndex]!;
          return (
            provider: providers[presetId]!,
            maxConcurrency: ttsEffectiveConcurrency(
              voices[presetId]!.descriptor,
              voices[presetId]!.preset,
            ),
            group: presetId,
          );
        },
        cache: cache,
        workDir: workDir,
        loudnorm: loudnorm,
        onProgress: onProgress,
        cancel: cancel,
        ttsCancel: ttsCancel,
      );
    } finally {
      for (final TtsProvider provider in providers.values) {
        await provider.dispose();
      }
    }
    final List<List<AudioCue>> chapterCues = rendered.cues;

    final ({bool verified, List<TtsRenderFlag> flags}) check = await _verify(
      job: job,
      row: loaded.row,
      plan: plan,
      chapters: chapters,
      chapterCues: chapterCues,
      workDir: workDir,
      onProgress: onProgress,
      cancel: cancel,
    );
    cancel.throwIfCancelled();

    onProgress(TtsRenderJobPhase.importing, 0, 1);
    await _import(
      job: job,
      chapters: chapters,
      chapterCues: chapterCues,
      fileDurationsMs: rendered.fileDurationsMs,
      workDir: workDir,
      check: check,
    );
    onProgress(TtsRenderJobPhase.importing, 1, 1);

    try {
      await workDir.delete(recursive: true);
    } on FileSystemException catch (e, stack) {
      // 有声书已经入库；工作目录删不掉（Windows 上被占用）只占盘，下次同 id 不会
      // 再出现，留日志供排查。
      ErrorLogService.instance.log('TtsRender.cleanup', e, stack);
    }
    return check;
  }

  Future<bool> _ffmpegHasLoudnorm(FfmpegBackend backend) async {
    final FfmpegRunResult result = await backend.runQuery(const <String>[
      '-hide_banner',
      '-filters',
    ], const Duration(seconds: 20));
    return result.isSuccess && ffmpegFiltersListHas(result.output, 'loudnorm');
  }

  _RenderVoice _resolveVoice(TtsServices tts, String presetId) {
    TtsVoicePreset? preset;
    for (final TtsVoicePreset candidate in tts.store.loadPresets()) {
      if (candidate.id == presetId) preset = candidate;
    }
    if (preset == null) throw const TtsRenderFailure('voice_missing');
    final TtsProviderDescriptor? descriptor = tts.registry[preset.providerId];
    if (descriptor == null || !descriptor.isAvailable) {
      throw const TtsRenderFailure('voice_unavailable');
    }
    if (descriptor.validate(preset).isNotEmpty) {
      throw const TtsRenderFailure('voice_incomplete');
    }
    return _RenderVoice(
      preset: preset,
      descriptor: descriptor,
      identity: descriptor.audioIdentity(preset),
    );
  }

  /// 「重新生成」：开始前丢掉这些句的缓存音频（按各句自己的声音算键；不在本次渲染
  /// 范围内的句不处理——丢了也不会被重新合成）。被朗读会话 pin 住的删不掉，如实
  /// 失败（静默跳过等于没重新生成，用户却以为换过了）。
  Future<void> _dropRegenerated(
    TtsRenderJob job,
    Map<int, String> presetOf,
    String Function(int planIndex) keyOf,
    TtsAudioCache cache,
    Directory workDir,
  ) async {
    if (job.regenerate.isEmpty) return;
    final File marker = File(p.join(workDir.path, _kRegeneratedMarker));
    if (await marker.exists()) return;
    for (final int index in job.regenerate) {
      if (!presetOf.containsKey(index)) continue;
      if (!await cache.remove(keyOf(index))) {
        throw const TtsRenderFailure('cache_busy');
      }
    }
    await marker.writeAsString('', flush: true);
  }

  Future<({List<List<AudioCue>> cues, List<int> fileDurationsMs})>
  _renderChapters({
    required TtsRenderJob job,
    required TtsBookPlan plan,
    required List<TtsRenderChapter> chapters,
    required String Function(int planIndex) keyOf,
    required _SentenceVoice Function(int planIndex) voiceOf,
    required TtsAudioCache cache,
    required Directory workDir,
    required bool loudnorm,
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
    required TtsCancelToken ttsCancel,
  }) async {
    final TtsRenderGate gate = TtsRenderGate(kTtsRenderMaxParallel);
    final TtsPausePreset pause = TtsPausePreset.parse(job.pausePreset);
    final Directory silenceDir = Directory(p.join(workDir.path, 'silence'));
    int totalSentences = 0;
    for (final TtsRenderChapter c in chapters) {
      totalSentences += c.planIndices.length;
    }
    int done = 0;
    final List<List<AudioCue>> cues = <List<AudioCue>>[];
    final List<int> fileDurations = <int>[];
    for (final TtsRenderChapter chapter in chapters) {
      cancel.throwIfCancelled();
      final List<String> keys = <String>[
        for (final int i in chapter.planIndices) keyOf(i),
      ];
      final String outputPath = p.join(workDir.path, '${chapter.stem}.m4a');
      final TtsChapterManifest? manifest = await readTtsChapterManifest(
        workDir,
        chapter,
      );
      final List<int> gaps = ttsChapterGapsMs(
        sentences: plan.sentences,
        chapter: chapter,
        preset: pause,
      );
      final List<int> durations;
      if (manifest != null &&
          manifest.matches(
            chapter.section,
            keys,
            pausePreset: pause.name,
            loudnorm: loudnorm,
          )) {
        durations = manifest.durationsMs;
        done += keys.length;
        onProgress(TtsRenderJobPhase.synthesizing, done, totalSentences);
      } else {
        // 先 pin 再合成：obtain 发布新文件时会顺手淘汰，未 pin 的同章旧句可能被挤掉。
        for (final String key in keys) {
          cache.pin(key);
        }
        try {
          onProgress(TtsRenderJobPhase.synthesizing, done, totalSentences);
          final Map<String, TtsCachedAudio> audio = await _synthesizeChapter(
            plan: plan,
            chapter: chapter,
            keys: keys,
            cache: cache,
            voiceOf: voiceOf,
            gate: gate,
            cancel: cancel,
            ttsCancel: ttsCancel,
            onSentencesDone: (int count) {
              done += count;
              onProgress(TtsRenderJobPhase.synthesizing, done, totalSentences);
            },
          );
          final List<TtsCachedAudio> ordered = <TtsCachedAudio>[
            for (final String key in keys) audio[key]!,
          ];
          onProgress(
            TtsRenderJobPhase.encoding,
            chapter.fileIndex,
            chapters.length,
          );
          void logFailure(String summary) => ErrorLogService.instance.log(
            'TtsRender.encode(${job.bookKey}#${chapter.section})',
            summary,
            StackTrace.current,
          );
          final ({
            List<({String path, int durationMs})> entries,
            TtsAudioStreamInfo target,
          })
          prepared = await prepareTtsUniformEntries(
            backend: resolveFfmpegBackend(),
            requirePcm16: gaps.any((int g) => g > 0),
            sentences: <({String key, String path, int durationMs})>[
              for (int k = 0; k < keys.length; k++)
                (
                  key: keys[k],
                  path: ordered[k].path,
                  durationMs: ordered[k].durationMs,
                ),
            ],
            mixDir: Directory(p.join(workDir.path, 'mix')),
            cancel: cancel,
            onFailure: logFailure,
          );
          // cue 时长 = 实际拼进去的那份文件的时长（转码过的句取中间文件实测值）。
          durations = <int>[
            for (final ({String path, int durationMs}) e in prepared.entries)
              e.durationMs,
          ];
          // 停顿 = 与本章拼接流同参数的 PCM 静音；清单里每段都带 `duration`，
          // 时间轴严格按毫秒累加。
          final TtsAudioStreamInfo target = prepared.target;
          await encodeTtsChapterAudio(
            backend: resolveFfmpegBackend(),
            entries: interleaveTtsPauses(
              sentences: prepared.entries,
              gapsMs: gaps,
              silenceFor: (int ms) => ttsSilenceFile(
                silenceDir,
                ms: ms,
                sampleRate: target.sampleRate,
                channels: target.channels,
              ),
            ),
            outputPath: outputPath,
            cancel: cancel,
            onFailure: logFailure,
            loudnorm: loudnorm,
          );
          await File(
            p.join(workDir.path, '${chapter.stem}.json'),
          ).writeAsString(
            TtsChapterManifest(
              section: chapter.section,
              keys: keys,
              durationsMs: durations,
              pausePreset: pause.name,
              loudnorm: loudnorm,
            ).encode(),
            flush: true,
          );
        } finally {
          for (final String key in keys) {
            cache.unpin(key);
          }
        }
      }
      onProgress(
        TtsRenderJobPhase.encoding,
        chapter.fileIndex + 1,
        chapters.length,
      );
      cues.add(
        buildTtsChapterCues(
          bookKey: job.bookKey,
          sentences: plan.sentences,
          chapter: chapter,
          durationsMs: durations,
          gapsMs: gaps,
        ),
      );
      fileDurations.add(ttsChapterFileDurationMs(durations, gaps));
    }
    return (cues: cues, fileDurationsMs: fileDurations);
  }

  /// 合成一章（同键只合成一次）。每种声音各自一个工作池、不超过它引擎的并发上限，
  /// 所有声音共用一道总闸 [gate]。任一句失败：停止派发新句、取消同章在途请求，抛
  /// 第一个失败。
  Future<Map<String, TtsCachedAudio>> _synthesizeChapter({
    required TtsBookPlan plan,
    required TtsRenderChapter chapter,
    required List<String> keys,
    required TtsAudioCache cache,
    required _SentenceVoice Function(int planIndex) voiceOf,
    required TtsRenderGate gate,
    required TtsRenderCancelToken cancel,
    required TtsCancelToken ttsCancel,
    required void Function(int count) onSentencesDone,
  }) async {
    final LinkedHashMap<String, ({String text, _SentenceVoice voice})> byKey =
        LinkedHashMap<String, ({String text, _SentenceVoice voice})>();
    final Map<String, int> occurrences = <String, int>{};
    for (int k = 0; k < keys.length; k++) {
      final int planIndex = chapter.planIndices[k];
      byKey.putIfAbsent(
        keys[k],
        () => (
          text: plan.sentences[planIndex].spokenText,
          voice: voiceOf(planIndex),
        ),
      );
      occurrences[keys[k]] = (occurrences[keys[k]] ?? 0) + 1;
    }
    // 按声音分组（同一份预设 = 同一个引擎实例 = 同一个并发上限）。
    final Map<String, List<String>> keysByVoice = <String, List<String>>{};
    byKey.forEach((String key, ({String text, _SentenceVoice voice}) item) {
      keysByVoice.putIfAbsent(item.voice.group, () => <String>[]).add(key);
    });
    final Map<String, TtsCachedAudio> results = <String, TtsCachedAudio>{};
    final TtsCancelToken chapterCancel = TtsCancelToken();
    final void Function() unlink = ttsCancel.onCancel(chapterCancel.cancel);
    Object? firstError;
    StackTrace? firstStack;

    Future<void> pool(List<String> voiceKeys) async {
      final _SentenceVoice voice = byKey[voiceKeys.first]!.voice;
      int next = 0;
      Future<void> worker() async {
        while (firstError == null && !chapterCancel.isCancelled) {
          if (next >= voiceKeys.length) return;
          final String key = voiceKeys[next++];
          await gate.acquire();
          try {
            if (firstError != null || chapterCancel.isCancelled) return;
            results[key] = await cache.obtain(
              key,
              (String outputPath) => voice.provider.synthesize(
                byKey[key]!.text,
                outputPath: outputPath,
                cancel: chapterCancel,
              ),
            );
            onSentencesDone(occurrences[key]!);
          } catch (e, stack) {
            if (firstError == null) {
              firstError = e;
              firstStack = stack;
              chapterCancel.cancel();
            }
            return;
          } finally {
            gate.release();
          }
        }
      }

      final int workers = voice.maxConcurrency.clamp(1, voiceKeys.length);
      await Future.wait(<Future<void>>[
        for (int i = 0; i < workers; i++) worker(),
      ]);
    }

    try {
      await Future.wait(<Future<void>>[
        for (final List<String> voiceKeys in keysByVoice.values)
          pool(voiceKeys),
      ]);
    } finally {
      unlink();
    }
    cancel.throwIfCancelled();
    final Object? error = firstError;
    if (error != null) {
      if (error is TtsFailure) {
        throw TtsRenderFailure('tts_${error.code.name}', error.detail);
      }
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
    return results;
  }

  /// 语音识别校对。没开、平台不支持、识别模型没下载时跳过（verified = false，
  /// 不替用户下载几百 MB 模型）。
  Future<({bool verified, List<TtsRenderFlag> flags})> _verify({
    required TtsRenderJob job,
    required EpubBookRow row,
    required TtsBookPlan plan,
    required List<TtsRenderChapter> chapters,
    required List<List<AudioCue>> chapterCues,
    required Directory workDir,
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    const ({bool verified, List<TtsRenderFlag> flags}) skipped = (
      verified: false,
      flags: <TtsRenderFlag>[],
    );
    if (!job.verify || !isAsrSupported) return skipped;
    const AsrAccelerationPreference preference = AsrAccelerationPreference.auto;
    final AsrLanguage language =
        AsrLanguage.fromBookLanguage(row.language) ??
        AsrLanguage.fromTag(appModel.prefsRepo.asrTranscribeLanguage) ??
        AsrLanguage.japanese;
    final AsrTranscriptionService service = createAsrTranscriptionService();
    final AsrTranscribePlan asrPlan = await service.plan(
      language: language,
      preference: preference,
    );
    if (!asrPlan.modelReady) return skipped;

    final List<TtsRenderFlag> flags = <TtsRenderFlag>[];
    onProgress(TtsRenderJobPhase.verifying, 0, chapters.length);
    for (int c = 0; c < chapters.length; c++) {
      cancel.throwIfCancelled();
      final TtsRenderChapter chapter = chapters[c];
      final String audioPath = p.join(workDir.path, '${chapter.stem}.m4a');
      try {
        final String srtPath = await _transcribe(
          service: service,
          audioPath: audioPath,
          language: language,
          plan: asrPlan,
          preference: preference,
          cancel: cancel,
        );
        final List<AudioCue> asrCues = await SrtParser.parse(
          srtFile: File(srtPath),
          bookKey: job.bookKey,
        );
        final List<AsrCueTokenTiming>? timings =
            await AsrTranscriptionService.readCueTokenTimings(
              srtPath,
              expectedCount: asrCues.length,
            );
        flags.addAll(
          flagTtsChapterSentences(
            sentences: <TtsVerifySentence>[
              for (final AudioCue cue in chapterCues[c])
                TtsVerifySentence(
                  planIndex: cue.sentenceIndex,
                  text: plan.sentences[cue.sentenceIndex].text,
                  spokenText: plan.sentences[cue.sentenceIndex].spokenText,
                  startMs: cue.startMs,
                  endMs: cue.endMs,
                ),
            ],
            heard: ttsHeardTokensFromAsr(asrCues, timings),
          ),
        );
        // 识别任务目录只为这次校对存在（断点续跑靠它），用完即删。
        await service.discard(<String>[audioPath], language);
      } on TtsRenderCancelled {
        rethrow;
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'TtsRender.verify(${job.bookKey}#${chapter.section})',
          e,
          stack,
        );
        throw TtsRenderFailure('verify_failed', e.runtimeType.toString());
      }
      onProgress(TtsRenderJobPhase.verifying, c + 1, chapters.length);
    }
    return (verified: true, flags: flags);
  }

  Future<String> _transcribe({
    required AsrTranscriptionService service,
    required String audioPath,
    required AsrLanguage language,
    required AsrTranscribePlan plan,
    required AsrAccelerationPreference preference,
    required TtsRenderCancelToken cancel,
  }) async {
    final AsrRunningTranscription running = await service.start(
      audioPaths: <String>[audioPath],
      language: language,
      variant: plan.variant,
      preference: preference,
    );
    bool live = true;
    cancel.onCancel(() {
      if (live) running.requestPause();
    });
    AsrTranscribeResult? result;
    try {
      await for (final AsrTranscribeEvent event in running.run()) {
        switch (event) {
          case AsrTranscribeProgressEvent():
            break;
          case AsrTranscribePausedEvent():
            // 只有取消会请求暂停；进度留在识别任务目录，重试从断点接着跑。
            throw const TtsRenderCancelled();
          case AsrTranscribeFinishedEvent(
            result: final AsrTranscribeResult done,
          ):
            result = done;
        }
      }
    } finally {
      live = false;
      await running.dispose();
    }
    final AsrTranscribeResult done =
        result ?? (throw StateError('ASR ended without a result'));
    return done.srtPath;
  }

  Future<void> _import({
    required TtsRenderJob job,
    required List<TtsRenderChapter> chapters,
    required List<List<AudioCue>> chapterCues,
    required List<int> fileDurationsMs,
    required Directory workDir,
    required ({bool verified, List<TtsRenderFlag> flags}) check,
  }) async {
    final FushiDatabase db = appModel.database;
    // 渲染期间书被删了：不给不存在的书落一本有声书。
    final EpubBookRow? row = await db.getEpubBook(job.bookKey);
    if (row == null) throw const TtsRenderFailure('book_missing');

    // 先停掉这本书的播放：句柄不放，持久目录里的旧音频删不掉 / 换不掉。
    await appModel.audiobookSession.stopIfPlayingAny(<String>[job.bookKey]);
    final Directory persistDir = await AudiobookStorage.ensurePersistDir(
      job.bookKey,
    );
    // 同步语义：持久目录里不在这组里的音频（这本书之前的有声书）一并清掉。
    final List<String> persistedAudio = await AudiobookStorage.syncAudioFiles(
      persistDir,
      <String>[
        for (final TtsRenderChapter c in chapters)
          p.join(workDir.path, '${c.stem}.m4a'),
      ],
    );

    final List<AudioCue> cues = <AudioCue>[
      for (final List<AudioCue> list in chapterCues) ...list,
    ];
    final String srtPath = p.join(persistDir.path, kTtsRenderSrtFileName);
    final File srtPart = File('$srtPath.part');
    await srtPart.writeAsString(
      serializeAudioCuesToSrt(
        // 文件起点按真实文件时长（含章尾静音）累加，与音频对得上。
        ttsCuesOnSingleTimeline(cues, fileDurationsMs: fileDurationsMs),
      ),
      flush: true,
    );
    final File srt = File(srtPath);
    if (await srt.exists()) await srt.delete();
    await srtPart.rename(srtPath);

    final int total = cues.length;
    final AudiobookHealth health = check.verified
        ? AudiobookHealth.fromRatePct(
            ratePct: total == 0
                ? 0
                : ((total - check.flags.length) * 100 / total).round(),
            reason:
                '${total - check.flags.length}/$total sentences passed '
                'ASR check (tts render)',
          )
        : AudiobookHealth.fromRatePct(
            ratePct: 100,
            reason: 'tts render, not verified',
          );

    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.ensureAudiobook(job.bookKey);
    await repo.replaceAlignment(
      bookKey: job.bookKey,
      format: 'srt',
      path: srtPath,
    );
    await repo.replaceAudio(bookKey: job.bookKey, audioPaths: persistedAudio);
    await repo.writeHealth(bookKey: job.bookKey, health: health);
    await writeEpubBackedSrtBook(
      repo: SrtBookRepository(db),
      bookKey: job.bookKey,
      title: row.title,
      author: row.author,
      srtPath: srtPath,
      audioPaths: persistedAudio,
    );
    await repo.saveCues(bookKey: job.bookKey, cues: cues);
    await repo.updateHealthOverlay(bookKey: job.bookKey, health: health);
  }
}
