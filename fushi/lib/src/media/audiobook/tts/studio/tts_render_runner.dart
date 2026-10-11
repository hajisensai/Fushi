/// 有声书制作流程（[TtsRenderRunner] 的 app 实现）。
///
/// 规划 → 按章逐句合成 → 按章编码 m4a → （可选）语音识别校对 → 作为普通有声书
/// 入库。
///
/// - 计划一律走 [buildStudioPlan]：校对结果与「单句重新生成」按计划下标指认句子，
///   与制作台同一口径。
/// - 逐句音频在 TTS 缓存里，缓存上限 512 MB，整本书可能超过：只在一章合成到编码
///   完成之间 pin 住这一章的键，绝不 pin 整本书。
/// - 已编码的章落在任务工作目录（`<tts_render>/<job.id>/tts_NNN.m4a` + 同名
///   `.json` 记录按序键与每句时长），重跑时键序一致的章直接跳过合成与编码。
/// - 入库只收本次渲染的章：`job.sections` 只选了部分章时，成品有声书就只含这些章
///   （替换这本书原有的有声书音频与 cue），没选的章没有音频。
/// - 工作目录保留到入库成功，成功后删除。
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
    show resolveFfmpegBackend;
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_verify.dart';
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
    final TtsVoicePreset? preset = _presetById(tts, job.presetId);
    if (preset == null) throw const TtsRenderFailure('voice_missing');
    final TtsProviderDescriptor? descriptor = tts.registry[preset.providerId];
    if (descriptor == null || !descriptor.isAvailable) {
      throw const TtsRenderFailure('voice_unavailable');
    }
    if (descriptor.validate(preset).isNotEmpty) {
      throw const TtsRenderFailure('voice_incomplete');
    }
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
    cancel.throwIfCancelled();

    final Map<String, Object?> identity = descriptor.audioIdentity(preset);
    String keyOf(int planIndex) =>
        TtsAudioCache.keyFor(identity, plan.sentences[planIndex].spokenText);
    final TtsAudioCache cache = await tts.cache();
    final Directory workDir = Directory(
      p.join(ttsRenderWorkRoot(appModel).path, job.id),
    );
    await workDir.create(recursive: true);
    await _dropRegenerated(job, plan, keyOf, cache, workDir);

    final TtsCancelToken ttsCancel = TtsCancelToken();
    cancel.onCancel(ttsCancel.cancel);
    final TtsProvider provider = descriptor.create(preset, tts.host);
    final List<List<AudioCue>> chapterCues;
    try {
      chapterCues = await _renderChapters(
        job: job,
        plan: plan,
        chapters: chapters,
        keyOf: keyOf,
        cache: cache,
        provider: provider,
        concurrency: descriptor.capabilities.maxConcurrency,
        workDir: workDir,
        onProgress: onProgress,
        cancel: cancel,
        ttsCancel: ttsCancel,
      );
    } finally {
      await provider.dispose();
    }

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

  TtsVoicePreset? _presetById(TtsServices tts, String id) {
    for (final TtsVoicePreset preset in tts.store.loadPresets()) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 「重新生成」：开始前丢掉这些句的缓存音频。被朗读会话 pin 住的删不掉，如实失败
  /// （静默跳过等于没重新生成，用户却以为换过了）。
  Future<void> _dropRegenerated(
    TtsRenderJob job,
    TtsBookPlan plan,
    String Function(int planIndex) keyOf,
    TtsAudioCache cache,
    Directory workDir,
  ) async {
    if (job.regenerate.isEmpty) return;
    final File marker = File(p.join(workDir.path, _kRegeneratedMarker));
    if (await marker.exists()) return;
    for (final int index in job.regenerate) {
      if (index < 0 || index >= plan.length) continue;
      if (!await cache.remove(keyOf(index))) {
        throw const TtsRenderFailure('cache_busy');
      }
    }
    await marker.writeAsString('', flush: true);
  }

  Future<List<List<AudioCue>>> _renderChapters({
    required TtsRenderJob job,
    required TtsBookPlan plan,
    required List<TtsRenderChapter> chapters,
    required String Function(int planIndex) keyOf,
    required TtsAudioCache cache,
    required TtsProvider provider,
    required int concurrency,
    required Directory workDir,
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
    required TtsCancelToken ttsCancel,
  }) async {
    int totalSentences = 0;
    for (final TtsRenderChapter c in chapters) {
      totalSentences += c.planIndices.length;
    }
    int done = 0;
    final List<List<AudioCue>> out = <List<AudioCue>>[];
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
      final List<int> durations;
      if (manifest != null && manifest.matches(chapter.section, keys)) {
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
            provider: provider,
            concurrency: concurrency,
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
          durations = <int>[
            for (final TtsCachedAudio a in ordered) a.durationMs,
          ];
          onProgress(
            TtsRenderJobPhase.encoding,
            chapter.fileIndex,
            chapters.length,
          );
          await encodeTtsChapterAudio(
            backend: resolveFfmpegBackend(),
            entries: <({String path, int durationMs})>[
              for (final TtsCachedAudio a in ordered)
                (path: a.path, durationMs: a.durationMs),
            ],
            outputPath: outputPath,
            cancel: cancel,
            onFailure: (String summary) => ErrorLogService.instance.log(
              'TtsRender.encode(${job.bookKey}#${chapter.section})',
              summary,
              StackTrace.current,
            ),
          );
          await File(
            p.join(workDir.path, '${chapter.stem}.json'),
          ).writeAsString(
            TtsChapterManifest(
              section: chapter.section,
              keys: keys,
              durationsMs: durations,
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
      out.add(
        buildTtsChapterCues(
          bookKey: job.bookKey,
          sentences: plan.sentences,
          chapter: chapter,
          durationsMs: durations,
        ),
      );
    }
    return out;
  }

  /// 合成一章（同键只合成一次），并发不超过引擎上限。任一句失败：停止派发新句、
  /// 取消同章在途请求，抛第一个失败。
  Future<Map<String, TtsCachedAudio>> _synthesizeChapter({
    required TtsBookPlan plan,
    required TtsRenderChapter chapter,
    required List<String> keys,
    required TtsAudioCache cache,
    required TtsProvider provider,
    required int concurrency,
    required TtsRenderCancelToken cancel,
    required TtsCancelToken ttsCancel,
    required void Function(int count) onSentencesDone,
  }) async {
    final LinkedHashMap<String, String> textByKey =
        LinkedHashMap<String, String>();
    final Map<String, int> occurrences = <String, int>{};
    for (int k = 0; k < keys.length; k++) {
      textByKey.putIfAbsent(
        keys[k],
        () => plan.sentences[chapter.planIndices[k]].spokenText,
      );
      occurrences[keys[k]] = (occurrences[keys[k]] ?? 0) + 1;
    }
    final List<String> unique = textByKey.keys.toList();
    final Map<String, TtsCachedAudio> results = <String, TtsCachedAudio>{};
    final TtsCancelToken chapterCancel = TtsCancelToken();
    final void Function() unlink = ttsCancel.onCancel(chapterCancel.cancel);
    Object? firstError;
    StackTrace? firstStack;
    int next = 0;

    Future<void> worker() async {
      while (firstError == null && !chapterCancel.isCancelled) {
        if (next >= unique.length) return;
        final String key = unique[next++];
        try {
          results[key] = await cache.obtain(
            key,
            (String outputPath) => provider.synthesize(
              textByKey[key]!,
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
        }
      }
    }

    try {
      final int workers = concurrency.clamp(
        1,
        unique.isEmpty ? 1 : unique.length,
      );
      await Future.wait(<Future<void>>[
        for (int i = 0; i < workers; i++) worker(),
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
      serializeAudioCuesToSrt(ttsCuesOnSingleTimeline(cues)),
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
