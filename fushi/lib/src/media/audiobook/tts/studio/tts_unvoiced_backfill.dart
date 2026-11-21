/// 补回没配上音的句子（未配音账本里的行）。
///
/// 每句一种做法（[TtsBackfillStrategy]）：
/// - 换配置重试：候选声音（本书的 → 系列的，见 [CastVoiceAssignment.retryVoicesOver]）
///   里第一个没失败过、也不是当前声音的；
/// - 指定声音：用户选的声音；
/// - 手动填写：用户填的念法，声音不变。
///
/// 只重合成账本里的句子。成功：把这次用的声音 / 念法写进选角表那一行
/// （[TtsCast.setLineOverrides]，之后重新生成也保留），从账本删掉；失败：账本里追加
/// 一次尝试。有成功的句子时排一个与上次同参数的制作任务——键序没变的章直接沿用
/// 已入库成品（见 `tts_render_runner.dart`），只重编含补回句的章、重写 cue。
library;

import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/tts_silence.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_retry.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_unvoiced.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_voices.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

enum TtsBackfillStrategy {
  /// 换配置重试（下一个候选声音）。
  retryNext,

  /// 用户指定声音。
  voice,

  /// 用户手动填写念法。
  say,
}

/// 补回一句的请求。
class TtsBackfillRequest {
  const TtsBackfillRequest.retryNext(this.lineId)
    : strategy = TtsBackfillStrategy.retryNext,
      voice = null,
      say = null;

  const TtsBackfillRequest.voice(this.lineId, String this.voice)
    : strategy = TtsBackfillStrategy.voice,
      say = null;

  const TtsBackfillRequest.say(this.lineId, String this.say)
    : strategy = TtsBackfillStrategy.say,
      voice = null;

  final String lineId;
  final TtsBackfillStrategy strategy;
  final String? voice;
  final String? say;
}

/// 一句补回的具体做法。
class TtsBackfillAttempt {
  const TtsBackfillAttempt({
    required this.lineId,
    required this.sentence,
    required this.presetId,
    required this.text,
    required this.voiceOverride,
    required this.sayOverride,
  });

  final String lineId;
  final TtsPlanSentence sentence;

  /// 这次合成用的声音预设。
  final String presetId;

  /// 这次念的文字。
  final String text;

  /// 成功后写进选角表那一行的单句声音 / 念法（null = 不单独指定）。
  final String? voiceOverride;
  final String? sayOverride;
}

/// 补回计划：能试的句子，以及「换配置重试」候选已经用尽的句子。
typedef TtsBackfillPlan = ({
  List<TtsBackfillAttempt> attempts,
  List<String> exhausted,
});

/// 把请求落成具体做法（纯函数）。不在账本里、或计划里已经找不到的行忽略。
/// [defaultPresetId] = 任务默认声音（选角表没给声音的句子用它）。
TtsBackfillPlan planTtsBackfill({
  required TtsCast cast,
  required CastVoicingLedger ledger,
  required List<TtsPlanSentence> sentences,
  required List<TtsBackfillRequest> requests,
  required String defaultPresetId,
}) {
  final Map<String, TtsPlanSentence> byId = <String, TtsPlanSentence>{
    for (final TtsPlanSentence s in sentences) ttsSentenceLineId(s): s,
  };
  final List<String> candidates = cast.ownAssignment.retryVoicesOver(
    cast.series,
  );
  final List<TtsBackfillAttempt> attempts = <TtsBackfillAttempt>[];
  final List<String> exhausted = <String>[];
  for (final TtsBackfillRequest request in requests) {
    final CastVoicingEntry? entry = ledger.entries[request.lineId];
    final TtsPlanSentence? sentence = byId[request.lineId];
    if (entry == null || sentence == null) continue;
    final String? lineVoice =
        cast.lines[ttsLineKey(sentence.section, sentence.matchStart)]?.voice;
    final String? currentSay = cast.sayFor(
      sentence.section,
      sentence.matchStart,
    );
    final String assigned =
        cast.presetFor(sentence.section, sentence.matchStart) ??
        defaultPresetId;
    switch (request.strategy) {
      case TtsBackfillStrategy.retryNext:
        final String? next = entry.nextRetryVoice(assigned, candidates);
        if (next == null) {
          exhausted.add(request.lineId);
          continue;
        }
        attempts.add(
          TtsBackfillAttempt(
            lineId: request.lineId,
            sentence: sentence,
            presetId: next,
            text: currentSay ?? sentence.spokenText,
            voiceOverride: next,
            sayOverride: currentSay,
          ),
        );
      case TtsBackfillStrategy.voice:
        attempts.add(
          TtsBackfillAttempt(
            lineId: request.lineId,
            sentence: sentence,
            presetId: request.voice!,
            text: currentSay ?? sentence.spokenText,
            voiceOverride: request.voice,
            sayOverride: currentSay,
          ),
        );
      case TtsBackfillStrategy.say:
        final String say = request.say!.trim();
        if (say.isEmpty) continue;
        attempts.add(
          TtsBackfillAttempt(
            lineId: request.lineId,
            sentence: sentence,
            presetId: assigned,
            text: say,
            voiceOverride: lineVoice,
            sayOverride: say,
          ),
        );
    }
  }
  return (attempts: attempts, exhausted: exhausted);
}

/// 补回的结果。
class TtsBackfillResult {
  const TtsBackfillResult({
    required this.succeeded,
    required this.failed,
    required this.exhausted,
    required this.renderQueued,
    required this.renderBusy,
  });

  final int succeeded;
  final int failed;

  /// 候选声音用尽、没试的句子数。
  final int exhausted;

  /// 排了重新生成的任务。
  final bool renderQueued;

  /// 这本书已有任务在跑 / 排队，没再排（它跑完后再生成一次才能带上补回的句子）。
  final bool renderBusy;
}

/// 补回失败（整体性的：书不在 / 没有可用的默认声音）。
class TtsBackfillFailure implements Exception {
  const TtsBackfillFailure(this.code);
  final String code;

  @override
  String toString() => 'TtsBackfillFailure($code)';
}

/// 补回 [requests]，见库注释。[onProgress] = 已试句数 / 待试句数。
Future<TtsBackfillResult> backfillTtsUnvoiced({
  required AudioProductionHost appModel,
  required String bookKey,
  required List<TtsBackfillRequest> requests,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final TtsServices tts = TtsServices.of(appModel.prefsRepo);
  final ({EpubBookRow row, EpubBook book})? loaded = await loadEpubForStudio(
    appModel.database,
    bookKey,
  );
  if (loaded == null) throw const TtsBackfillFailure('book_missing');
  final TtsRenderQueue queue = ttsRenderQueueFor(appModel);
  await queue.load();
  final TtsRenderJob? last = queue.latestFor(bookKey);
  final String? defaultPresetId =
      last?.presetId ?? tts.store.activePreset()?.id;
  if (defaultPresetId == null) throw const TtsBackfillFailure('no_voice');

  final TtsCastBundle bundle = await loadTtsCastBundle(appModel, bookKey);
  // 与制作流程同一口径：念的文字过系列用词替换表（手动填写的念法不过）。
  final TtsBookPlan plan = ttsPlanWithSubstitutions(
    await buildStudioPlan(loaded.book, tts),
    bundle.series?.substitutions ?? const <CastTextSubstitution>[],
  );
  final TtsCast cast = bundle.cast;
  final CastVoicingStore voicingStore = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicingStore.load(bookKey);
  final TtsBackfillPlan backfill = planTtsBackfill(
    cast: cast,
    ledger: ledger,
    sentences: plan.sentences,
    requests: requests,
    defaultPresetId: defaultPresetId,
  );

  final TtsAudioCache cache = await tts.cache();
  final Map<String, TtsProvider> providers = <String, TtsProvider>{};
  final List<TtsVoicePreset> productionPresets = ttsProductionPresets(
    tts,
    appModel,
  );
  final Map<String, TtsRenderVoice> voices = <String, TtsRenderVoice>{};
  final TtsCancelToken cancel = TtsCancelToken();
  int succeeded = 0;
  int failed = 0;
  try {
    for (int i = 0; i < backfill.attempts.length; i++) {
      if (isCancelled?.call() ?? false) break;
      onProgress?.call(i, backfill.attempts.length);
      final TtsBackfillAttempt attempt = backfill.attempts[i];
      try {
        // 纯标点句（「！」）没有要念的内容：不送引擎，制作时按停顿处理，直接销账。
        if (!ttsTextIsSilent(attempt.text)) {
          final TtsRenderVoice voice = voices[attempt.presetId] ??=
              resolveTtsRenderVoice(
                tts,
                attempt.presetId,
                presets: productionPresets,
              );
          final TtsProvider provider = providers[attempt.presetId] ??= voice
              .descriptor
              .create(voice.preset, tts.host);
          final String key = TtsAudioCache.keyFor(voice.identity, attempt.text);
          await ttsWithRetry(
            () => cache.obtain(
              key,
              (String outputPath) => provider.synthesize(
                attempt.text,
                outputPath: outputPath,
                cancel: cancel,
              ),
            ),
            cancel: cancel,
          );
        }
        cast.setLineOverrides(
          attempt.sentence.section,
          attempt.sentence.matchStart,
          voice: attempt.voiceOverride,
          say: attempt.sayOverride,
        );
        ledger.resolve(attempt.lineId);
        succeeded++;
      } catch (e) {
        if (e is! TtsRenderFailure && !ttsFailureIsPerLine(e)) rethrow;
        ledger.recordFailure(
          lineId: attempt.lineId,
          text: attempt.text,
          voice: attempt.presetId,
          code: ttsUnvoicedCode(e),
          detail: ttsUnvoicedDetail(e),
        );
        failed++;
      }
    }
    onProgress?.call(backfill.attempts.length, backfill.attempts.length);
  } finally {
    for (final TtsProvider provider in providers.values) {
      await provider.dispose();
    }
    // 成功写进选角表的覆盖和账本要一起落盘，中途出错也不丢已补回的句子。
    await ttsCastStoreFor(appModel).save(bookKey, cast);
    await voicingStore.save(bookKey, ledger);
  }

  bool queued = false;
  bool busy = false;
  if (succeeded > 0) {
    if (last != null && !last.isTerminal) {
      busy = true;
    } else {
      await queue.enqueue(
        bookKey: bookKey,
        title: last?.title ?? loaded.row.title,
        presetId: defaultPresetId,
        sections: last?.sections ?? const <int>[],
        verify: last?.verify ?? false,
        pausePreset: last?.pausePreset ?? 'standard',
        normalizeLoudness: last?.normalizeLoudness ?? true,
      );
      queued = true;
    }
  }
  return TtsBackfillResult(
    succeeded: succeeded,
    failed: failed,
    exhausted: backfill.exhausted.length,
    renderQueued: queued,
    renderBusy: busy,
  );
}
