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
/// - 某句合成失败（重试用尽）不让整章失败：成品里放占位静音、记进这本书的未配音
///   账本（`tts_render_unvoiced.dart`），任务结果带上句数，之后在制作台补回。整个
///   引擎不可用（连续失败熔断）才让任务失败。
/// - 系列：选角表叠在系列声音指派上解析（`tts_series_cast.dart`）。
/// - 演出稿（设计 §8）：每句按选角表的种子合成（单句写下的 → 作品默认；只对声明支持
///   种子的引擎生效，缓存键只含生效的字段）；跑过选角标注的章按「转场基础值 + 一拍」
///   插句间停顿（`tts_cast_timing.dart`，与漫画共用转场判定）。
/// - 入库时每章的清单也存进持久目录（`<stem>.tts-chapter.json`）：之后的新任务里键序
///   没变的章直接沿用已入库的成品，只重编受影响的章（补回、换某个角色的声音时）。
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
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/tts_silence.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:fushi_engine/tts/tts_reject_split.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_chapter_sort.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_unvoiced.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_verify.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 入库后持久目录里的单时间轴字幕文件名。
const String kTtsRenderSrtFileName = 'tts_audiobook.srt';

/// 工作目录里「重新生成的缓存已丢弃」的标记：续跑同一任务时不再丢第二次（否则会把
/// 已经重新合成好的音频又删掉）。
const String _kRegeneratedMarker = 'regenerated.done';

/// 合成一句要用的引擎实例；[group] = 预设 id，同组共用一个并发上限；[gap] = 每个
/// 实际发出的请求之后再等多久（在线声音的「每句间隔」）。
typedef _SentenceVoice = ({
  TtsProvider provider,
  int maxConcurrency,
  Duration gap,
  String group,
});

/// 一份声音在这次制作里的并发与每句间隔。任务的限流参数（「同时请求数」「每句间隔」）
/// 只作用于在线引擎；本机 / 系统声音照声音预设自己的并发、不加间隔。
({int concurrency, Duration gap}) ttsRenderVoicePacing(
  TtsRenderJob job,
  TtsProviderDescriptor descriptor,
  TtsVoicePreset preset,
) {
  final int base = ttsEffectiveConcurrency(descriptor, preset);
  if (descriptor.category != TtsProviderCategory.online) {
    return (concurrency: base, gap: Duration.zero);
  }
  return (
    concurrency: (job.onlineConcurrency ?? base).clamp(1, kTtsMaxConcurrency),
    gap: Duration(milliseconds: job.sentenceGapMs),
  );
}

/// 这次制作的重试策略：429 怎么处理由任务的「被限流时」决定
/// （[TtsRateLimitAction]），其余临时失败照默认退避。
TtsRetryPolicy ttsRenderRetryPolicy(TtsRenderJob job) =>
    switch (job.rateLimitAction) {
      TtsRateLimitAction.waitRetry => TtsRetryPolicy.patientRateLimit,
      TtsRateLimitAction.pause => TtsRetryPolicy.pauseOnRateLimit,
    };

/// 合成失败 → 任务失败码。选了「被限流时暂停」的 429 记成 `rate_limited_paused`
/// （界面提示稍后重试会接着做），其余 `tts_<码>`。
String ttsRenderFailureCodeFor(TtsRenderJob job, TtsFailure failure) =>
    failure.code == TtsFailureCode.rateLimited &&
        job.rateLimitAction == TtsRateLimitAction.pause
    ? 'rate_limited_paused'
    : 'tts_${failure.code.name}';

class AppTtsRenderRunner implements TtsRenderRunner {
  AppTtsRenderRunner({required this.appModel});

  final AudioProductionHost appModel;

  @override
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    // 漫画卷：演出稿 → 每句一段音频 + 成品清单（另一条流程，见
    // `manga_audio_render_service.dart`）。
    if (job.kind == TtsRenderJobKind.manga) {
      return runMangaRenderJob(
        appModel,
        job,
        onProgress: onProgress,
        cancel: cancel,
      );
    }
    onProgress(TtsRenderJobPhase.planning, 0, 0);
    final TtsServices tts = TtsServices.of(appModel.prefsRepo);
    final ({EpubBookRow row, EpubBook book})? loaded = await loadEpubForStudio(
      appModel.database,
      job.bookKey,
    );
    if (loaded == null) throw const TtsRenderFailure('book_missing');
    // 选角表 + 系列档案先读：系列用词替换表要改写这次实际念的文字与 cue 文本（文字
    // 变了缓存键 / 章清单键跟着变，受影响的章自然重做）。
    final TtsCastBundle bundle = await loadTtsCastBundle(appModel, job.bookKey);
    final TtsBookPlan plan = ttsPlanWithSubstitutions(
      await buildStudioPlan(loaded.book, tts),
      bundle.series?.substitutions ?? const <CastTextSubstitution>[],
    );
    final List<TtsRenderChapter> chapters = groupTtsRenderChapters(
      plan.sentences,
      sections: job.sections.toSet(),
    );
    if (chapters.isEmpty) throw const TtsRenderFailure('empty_book');

    // 每句的声音：单句指定 → 角色（本书 → 系列）→ 任务默认声音。用到的每份预设各
    // 解析一次。任务默认声音不可用如实失败；角色 / 单句的声音缺失 / 不可用 / 不完整
    // 时，那些句子占位记账（不悄悄换成别的声音），其余照常生成。
    final TtsCast cast = bundle.cast;
    final CastVoicingStore voicingStore = ttsVoicingStoreFor(appModel);
    final CastVoicingLedger ledger = await voicingStore.load(job.bookKey);
    final Map<int, String> presetOf = resolveTtsSentencePresets(
      sentences: plan.sentences,
      indices: <int>[
        for (final TtsRenderChapter c in chapters) ...c.planIndices,
      ],
      cast: cast,
      defaultPresetId: job.presetId,
    );
    // 声音预设 + 声音包（`pack:<packId>/<group>`）：选角表里两类 id 都可能出现。
    final List<TtsVoicePreset> productionPresets = ttsProductionPresets(
      tts,
      appModel,
    );
    final Map<String, TtsRenderVoice> voices = <String, TtsRenderVoice>{};
    final Map<String, TtsRenderFailure> unavailable =
        <String, TtsRenderFailure>{};
    for (final String presetId in presetOf.values.toSet()) {
      try {
        voices[presetId] = resolveTtsRenderVoice(
          tts,
          presetId,
          presets: productionPresets,
        );
      } on TtsRenderFailure catch (e) {
        if (presetId == job.presetId) rethrow;
        unavailable[presetId] = e;
      }
    }
    cancel.throwIfCancelled();

    // 引擎实例先建：每句实际下发的演出参数（种子）取决于引擎声明的能力，缓存键要
    // 跟着它算。
    final Map<String, TtsProvider> providers = <String, TtsProvider>{};
    try {
      voices.forEach((String presetId, TtsRenderVoice voice) {
        providers[presetId] = voice.descriptor.create(voice.preset, tts.host);
      });
      return await _runWithProviders(
        job: job,
        loaded: loaded,
        plan: plan,
        chapters: chapters,
        cast: cast,
        ledger: ledger,
        voicingStore: voicingStore,
        presetOf: presetOf,
        voices: voices,
        unavailable: unavailable,
        providers: providers,
        tts: tts,
        onProgress: onProgress,
        cancel: cancel,
      );
    } finally {
      await _disposeProviders(providers);
    }
  }

  /// 释放并清空引擎实例（可重复调用：合成完就释放，不占着本地引擎跑校对 / 入库）。
  Future<void> _disposeProviders(Map<String, TtsProvider> providers) async {
    final List<TtsProvider> all = providers.values.toList();
    providers.clear();
    for (final TtsProvider provider in all) {
      await provider.dispose();
    }
  }

  /// 引擎实例建好之后的整段流程（调用方兜底释放 [providers]；合成一结束这里就先
  /// 释放）。
  Future<({bool verified, List<TtsRenderFlag> flags})> _runWithProviders({
    required TtsRenderJob job,
    required ({EpubBookRow row, EpubBook book}) loaded,
    required TtsBookPlan plan,
    required List<TtsRenderChapter> chapters,
    required TtsCast cast,
    required CastVoicingLedger ledger,
    required CastVoicingStore voicingStore,
    required Map<int, String> presetOf,
    required Map<String, TtsRenderVoice> voices,
    required Map<String, TtsRenderFailure> unavailable,
    required Map<String, TtsProvider> providers,
    required TtsServices tts,
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    String textOf(int planIndex) =>
        ttsSentenceSpokenText(cast, plan.sentences[planIndex]);
    // 这句实际下发的演出参数：种子按选角表（单句 → 作品默认），只留引擎支持的字段。
    TtsDirection directionOf(int planIndex) {
      final TtsProvider? provider = providers[presetOf[planIndex]!];
      if (provider == null) return TtsDirection.none;
      return ttsSentenceDirection(
        support: ttsDirectionSupportOf(provider),
        cast: cast,
        sentence: plan.sentences[planIndex],
      );
    }

    String keyOf(int planIndex) {
      final String presetId = presetOf[planIndex]!;
      return TtsAudioCache.keyFor(<String, Object?>{
        ...voices[presetId]?.identity ??
            <String, Object?>{'unavailable': presetId},
        ...directionOf(planIndex).cacheIdentity,
      }, textOf(planIndex));
    }

    final Directory persistDir = await AudiobookStorage.ensurePersistDir(
      job.bookKey,
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

    final ({
      List<List<AudioCue>> cues,
      List<int> fileDurationsMs,
      List<TtsUnvoicedLine> unvoiced,
    })
    rendered = await _renderChapters(
      job: job,
      plan: plan,
      cast: cast,
      chapters: chapters,
      keyOf: keyOf,
      textOf: textOf,
      directionOf: directionOf,
      presetIdOf: (int planIndex) => presetOf[planIndex]!,
      unavailableOf: (int planIndex) => unavailable[presetOf[planIndex]],
      persistDir: persistDir,
      voiceOf: (int planIndex) {
        final String presetId = presetOf[planIndex]!;
        if (!voices.containsKey(presetId)) return null;
        final ({int concurrency, Duration gap}) pacing = ttsRenderVoicePacing(
          job,
          voices[presetId]!.descriptor,
          voices[presetId]!.preset,
        );
        return (
          provider: providers[presetId]!,
          maxConcurrency: pacing.concurrency,
          gap: pacing.gap,
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
    // 合成结束：本地引擎（Irodori 等）别占着显存 / 进程跑后面的语音识别校对。
    await _disposeProviders(providers);
    final List<List<AudioCue>> chapterCues = rendered.cues;

    final ({bool verified, List<TtsRenderFlag> flags}) check = await _verify(
      job: job,
      row: loaded.row,
      plan: plan,
      chapters: chapters,
      chapterCues: chapterCues,
      // 占位句与纯标点句都是静音，不拿去和识别结果对。
      placeholders: <int>{
        for (final TtsUnvoicedLine line in rendered.unvoiced) line.planIndex,
        for (final TtsRenderChapter chapter in chapters)
          for (final int i in chapter.planIndices)
            if (ttsTextIsSilent(textOf(i))) i,
      },
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
      persistDir: persistDir,
      check: check,
    );
    // 账本在入库成功后才落盘：入库失败时旧成品还在，账本得和它对得上。
    reconcileTtsVoicingLedger(
      ledger: ledger,
      renderedLineIds: <String>{
        for (final TtsRenderChapter c in chapters)
          for (final int i in c.planIndices)
            ttsSentenceLineId(plan.sentences[i]),
      },
      liveLineIds: <String>{
        for (final TtsPlanSentence s in plan.sentences) ttsSentenceLineId(s),
      },
      failures: rendered.unvoiced,
    );
    await voicingStore.save(job.bookKey, ledger);
    job.unvoiced = rendered.unvoiced.length;
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

  Future<
    ({
      List<List<AudioCue>> cues,
      List<int> fileDurationsMs,
      List<TtsUnvoicedLine> unvoiced,
    })
  >
  _renderChapters({
    required TtsRenderJob job,
    required TtsBookPlan plan,
    required TtsCast cast,
    required List<TtsRenderChapter> chapters,
    required String Function(int planIndex) keyOf,
    required String Function(int planIndex) textOf,
    required TtsDirection Function(int planIndex) directionOf,
    required String Function(int planIndex) presetIdOf,
    required TtsRenderFailure? Function(int planIndex) unavailableOf,
    required _SentenceVoice? Function(int planIndex) voiceOf,
    required Directory persistDir,
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
    final List<TtsUnvoicedLine> unvoiced = <TtsUnvoicedLine>[];
    final TtsUnvoicedBreaker breaker = TtsUnvoicedBreaker();
    final Set<int> regenerate = job.regenerate.toSet();
    for (final TtsRenderChapter chapter in chapters) {
      cancel.throwIfCancelled();
      final List<String> keys = <String>[
        for (final int i in chapter.planIndices) keyOf(i),
      ];
      final String outputPath = p.join(workDir.path, '${chapter.stem}.m4a');
      final List<int> gaps = ttsChapterGapsMs(
        sentences: plan.sentences,
        chapter: chapter,
        preset: pause,
        cast: cast,
      );
      // 旧 sidecar 没记停顿：它编码时插的是只按预设算的那一份。
      final List<int> legacyGaps = ttsChapterGapsMs(
        sentences: plan.sentences,
        chapter: chapter,
        preset: pause,
      );
      bool reusable(TtsChapterManifest? m) =>
          m != null &&
          m.matches(
            chapter.section,
            keys,
            pausePreset: pause.name,
            loudnorm: loudnorm,
            gapsMs: gaps,
            legacyGapsMs: legacyGaps,
          );
      TtsChapterManifest? manifest = await readTtsChapterManifest(
        workDir,
        chapter,
      );
      // 本任务还没编过这章：键序没变（且没被要求重新生成）就沿用已入库的成品。
      if (!reusable(manifest) &&
          !chapter.planIndices.any(regenerate.contains)) {
        final TtsChapterManifest? persisted = await readTtsPersistedChapter(
          persistDir,
          chapter,
        );
        if (reusable(persisted)) {
          await adoptTtsPersistedChapter(persistDir, workDir, chapter);
          manifest = persisted;
        }
      }
      final List<int> durations;
      if (manifest != null && reusable(manifest)) {
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
          final ({
            Map<String, TtsCachedAudio> audio,
            Map<String, Object> failures,
            Set<String> silent,
          })
          synth = await _synthesizeChapter(
            job: job,
            chapter: chapter,
            keys: keys,
            textOf: textOf,
            directionOf: directionOf,
            cache: cache,
            voiceOf: voiceOf,
            unavailableOf: unavailableOf,
            breaker: breaker,
            gate: gate,
            cancel: cancel,
            ttsCancel: ttsCancel,
            onSentencesDone: (int count) {
              done += count;
              onProgress(TtsRenderJobPhase.synthesizing, done, totalSentences);
            },
          );
          // 没配上的句：成品里占位静音，记下来交给账本。纯标点句同样放一段静音，
          // 但不进账本、章清单里记真键（它没有要念的内容，不算失败）。
          final List<bool> placeholder = ttsChapterPlaceholderMask(
            keys: keys,
            failures: synth.failures.keys.toSet(),
            silent: synth.silent,
          );
          final List<String> texts = <String>[
            for (final int i in chapter.planIndices) textOf(i),
          ];
          for (int k = 0; k < keys.length; k++) {
            if (!synth.failures.containsKey(keys[k])) continue;
            final int planIndex = chapter.planIndices[k];
            final Object error = synth.failures[keys[k]]!;
            unvoiced.add(
              TtsUnvoicedLine(
                planIndex: planIndex,
                lineId: ttsSentenceLineId(plan.sentences[planIndex]),
                text: texts[k],
                voice: presetIdOf(planIndex),
                code: ttsUnvoicedCode(error),
                detail: ttsUnvoicedDetail(error),
              ),
            );
          }
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
            // 占位静音也是 16-bit PCM，整章得统一到 PCM 才拼得上。
            requirePcm16:
                gaps.any((int g) => g > 0) || placeholder.contains(true),
            sentences: <({String key, String path, int durationMs})>[
              for (int k = 0; k < keys.length; k++)
                if (!placeholder[k])
                  (
                    key: keys[k],
                    path: synth.audio[keys[k]]!.path,
                    durationMs: synth.audio[keys[k]]!.durationMs,
                  ),
            ],
            mixDir: Directory(p.join(workDir.path, 'mix')),
            cancel: cancel,
            onFailure: logFailure,
          );
          // cue 时长 = 实际拼进去的那份文件的时长（转码过的句取中间文件实测值；
          // 占位句取估计的静音长度）。
          durations = ttsChapterDurationsWithPlaceholders(
            placeholder: placeholder,
            voicedDurationsMs: <int>[
              for (final ({String path, int durationMs}) e in prepared.entries)
                e.durationMs,
            ],
            texts: texts,
          );
          // 停顿 / 占位 = 与本章拼接流同参数的 PCM 静音；清单里每段都带
          // `duration`，时间轴严格按毫秒累加。
          final TtsAudioStreamInfo target = prepared.target;
          final List<({String path, int durationMs})> sentenceEntries =
              <({String path, int durationMs})>[];
          int voiced = 0;
          for (int k = 0; k < keys.length; k++) {
            sentenceEntries.add(
              placeholder[k]
                  ? (
                      path: ttsSilenceFile(
                        silenceDir,
                        ms: durations[k],
                        sampleRate: target.sampleRate,
                        channels: target.channels,
                      ),
                      durationMs: durations[k],
                    )
                  : prepared.entries[voiced++],
            );
          }
          await encodeTtsChapterAudio(
            backend: resolveFfmpegBackend(),
            entries: interleaveTtsPauses(
              sentences: sentenceEntries,
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
              keys: ttsChapterManifestKeys(
                keys: keys,
                failures: synth.failures.keys.toSet(),
              ),
              durationsMs: durations,
              pausePreset: pause.name,
              loudnorm: loudnorm,
              gapsMs: gaps,
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
    return (cues: cues, fileDurationsMs: fileDurations, unvoiced: unvoiced);
  }

  /// 合成一章（同键只合成一次）。每种声音各自一个工作池、不超过它引擎的并发上限，
  /// 所有声音共用一道总闸 [gate]。
  ///
  /// 一句在重试用尽后仍失败（[ttsFailureIsPerLine]）或声音解析不到：记进返回的
  /// `failures`（键 → 失败），其余句子照常合成。熔断（[breaker]）、取消或其它异常：
  /// 停止派发新句、取消同章在途请求，抛第一个失败。
  ///
  /// 纯标点 / 符号句（[ttsTextIsSilent]，如「！」）不送引擎：记进返回的 `silent`，
  /// 由调用方放一段停顿。
  Future<
    ({
      Map<String, TtsCachedAudio> audio,
      Map<String, Object> failures,
      Set<String> silent,
    })
  >
  _synthesizeChapter({
    required TtsRenderJob job,
    required TtsRenderChapter chapter,
    required List<String> keys,
    required String Function(int planIndex) textOf,
    required TtsDirection Function(int planIndex) directionOf,
    required TtsAudioCache cache,
    required _SentenceVoice? Function(int planIndex) voiceOf,
    required TtsRenderFailure? Function(int planIndex) unavailableOf,
    required TtsUnvoicedBreaker breaker,
    required TtsRenderGate gate,
    required TtsRenderCancelToken cancel,
    required TtsCancelToken ttsCancel,
    required void Function(int count) onSentencesDone,
  }) async {
    final TtsChapterSorting<_SentenceVoice> sorted = sortTtsChapterSentences(
      keys: keys,
      planIndices: chapter.planIndices,
      textOf: textOf,
      directionOf: directionOf,
      voiceOf: voiceOf,
      unavailableOf: (int planIndex) => unavailableOf(planIndex)!,
    );
    final LinkedHashMap<String, TtsChapterSentence<_SentenceVoice>> byKey =
        sorted.byKey;
    final Map<String, int> occurrences = sorted.occurrences;
    final Map<String, Object> failures = sorted.failures;
    final Set<String> silent = sorted.silent;
    // 纯标点句与声音解析不到的句子不进合成池，直接算处理完（停顿 / 占位）。
    for (final String key in <String>{...silent, ...failures.keys}) {
      onSentencesDone(occurrences[key]!);
    }
    // 按声音分组（同一份预设 = 同一个引擎实例 = 同一个并发上限）。
    final Map<String, List<String>> keysByVoice = <String, List<String>>{};
    byKey.forEach((String key, TtsChapterSentence<_SentenceVoice> item) {
      keysByVoice.putIfAbsent(item.voice.group, () => <String>[]).add(key);
    });
    final Map<String, TtsCachedAudio> results = <String, TtsCachedAudio>{};
    final TtsCancelToken chapterCancel = TtsCancelToken();
    final void Function() unlink = ttsCancel.onCancel(chapterCancel.cancel);
    Object? firstError;
    StackTrace? firstStack;

    final TtsRetryPolicy retryPolicy = ttsRenderRetryPolicy(job);

    Future<void> pool(List<String> voiceKeys) async {
      final _SentenceVoice voice = byKey[voiceKeys.first]!.voice;
      int next = 0;
      // 同一份声音被限流后的冷却截止时刻：一路拿到 429，同池其它路在发下一个请求前
      // 也等到这里（按服务端 Retry-After / 退避算出），不在冷却期里继续打服务端。
      DateTime? cooldownUntil;
      Future<void> worker() async {
        bool pendingGap = false;
        while (firstError == null && !chapterCancel.isCancelled) {
          if (next >= voiceKeys.length) return;
          // 每句间隔：上一个请求真的发出去了（不是命中缓存）才等。
          if (pendingGap) {
            pendingGap = false;
            try {
              await ttsCancellableDelay(voice.gap, chapterCancel);
            } on TtsFailure {
              return;
            }
          }
          final DateTime? until = cooldownUntil;
          if (until != null) {
            final Duration wait = until.difference(DateTime.now());
            if (wait > Duration.zero) {
              try {
                await ttsCancellableDelay(wait, chapterCancel);
              } on TtsFailure {
                return;
              }
            }
          }
          if (firstError != null || chapterCancel.isCancelled) return;
          if (next >= voiceKeys.length) return;
          final String key = voiceKeys[next++];
          await gate.acquire();
          try {
            if (firstError != null || chapterCancel.isCancelled) return;
            // 在线引擎的临时失败（断连 / 超时 / 429 / 5xx）先有限次退避重试，
            // 与朗读调度共用 ttsWithRetry；429 的处理按任务的「被限流时」
            // （[ttsRenderRetryPolicy]）。用尽仍失败才判整章失败。
            results[key] = await ttsWithRetry(
              () => cache.obtain(key, (String outputPath) {
                pendingGap = voice.gap > Duration.zero;
                return ttsSynthesizeSplittingOnReject(
                  voice.provider,
                  byKey[key]!.text,
                  outputPath: outputPath,
                  cancel: chapterCancel,
                  direction: byKey[key]!.direction,
                );
              }),
              cancel: chapterCancel,
              policy: retryPolicy,
              onRetry: (int retry, TtsFailure failure, Duration delay) {
                if (failure.code != TtsFailureCode.rateLimited) return;
                final DateTime end = DateTime.now().add(delay);
                final DateTime? current = cooldownUntil;
                if (current == null || end.isAfter(current)) {
                  cooldownUntil = end;
                }
              },
            );
            breaker.recordSuccess();
            onSentencesDone(occurrences[key]!);
          } catch (e, stack) {
            // 这一句没配上：占位记账，接着做别的句子；连续失败到熔断线才判
            // 引擎不可用、整章失败。
            if (!chapterCancel.isCancelled &&
                ttsFailureIsPerLine(e) &&
                !breaker.recordFailure()) {
              failures[key] = e;
              onSentencesDone(occurrences[key]!);
              continue;
            }
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
        throw TtsRenderFailure(
          ttsRenderFailureCodeFor(job, error),
          error.detail,
        );
      }
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
    return (audio: results, failures: failures, silent: silent);
  }

  /// 语音识别校对。没开、平台不支持、识别模型没下载时跳过（verified = false，
  /// 不替用户下载几百 MB 模型）。
  Future<({bool verified, List<TtsRenderFlag> flags})> _verify({
    required TtsRenderJob job,
    required EpubBookRow row,
    required TtsBookPlan plan,
    required List<TtsRenderChapter> chapters,
    required List<List<AudioCue>> chapterCues,
    required Set<int> placeholders,
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
    // 识别后替换：与设置页 / 制作台同一份规则，开始校对时读一次。
    final List<TtsPronunciationRule> heardRewrites = TtsServices.of(
      appModel.prefsRepo,
    ).textRules.load(TtsTextRuleKind.postRecognition);
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
              // 占位句是静音，已经记在未配音账本里，不再算校对问题。
              for (final AudioCue cue in chapterCues[c])
                if (!placeholders.contains(cue.sentenceIndex))
                  TtsVerifySentence(
                    planIndex: cue.sentenceIndex,
                    text: plan.sentences[cue.sentenceIndex].text,
                    spokenText: plan.sentences[cue.sentenceIndex].spokenText,
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                  ),
            ],
            heard: ttsHeardTokensFromAsr(asrCues, timings),
            heardRewrites: heardRewrites,
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
    required Directory persistDir,
    required ({bool verified, List<TtsRenderFlag> flags}) check,
  }) async {
    final FushiDatabase db = appModel.database;
    // 渲染期间书被删了：不给不存在的书落一本有声书。
    final EpubBookRow? row = await db.getEpubBook(job.bookKey);
    if (row == null) throw const TtsRenderFailure('book_missing');

    // 先停掉这本书的播放：句柄不放，持久目录里的旧音频删不掉 / 换不掉。
    await appModel.audiobookSession.stopIfPlayingAny(<String>[job.bookKey]);
    // 同步语义：持久目录里不在这组里的音频（这本书之前的有声书）一并清掉。
    final List<String> persistedAudio = await AudiobookStorage.syncAudioFiles(
      persistDir,
      <String>[
        for (final TtsRenderChapter c in chapters)
          p.join(workDir.path, '${c.stem}.m4a'),
      ],
    );

    await persistTtsChapterManifests(
      workDir: workDir,
      persistDir: persistDir,
      chapters: chapters,
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
