/// 漫画有声的「改一句」：演出稿复核页（[MangaAudioScriptPage]）与阅读页气泡右键 /
/// 长按「编辑这句配音」共用同一份对话框与改法，单句换种子重生成的「试听 → 保留 /
/// 撤回」也与制作台同一份流程。
///
/// 阅读页入口（拍板 bnAC_eferQ：「直接在右键里面标记」）就地弹对话框改，不离开阅读页、
/// 不跳到复核页：右键命中的气泡 → 用到这些块的那一句 → 改说话人 / 类型 / 一拍 / 念法；
/// 这句已经生成过时，改了会影响读法的字段（说话人 / 类型 / 念法）就只重新生成这一句，
/// 候选可试听、保留或撤回，其它句子不动。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 改一句的动作。[regenerate] 不改演出稿，只在调用方允许时列出（这句已生成过）。
enum MangaLineEditAction {
  speaker,
  kind,
  beat,
  say,
  clearSay,
  up,
  down,
  regenerate;

  /// 改了会影响这一句读出来的声音（换人 / 换类型 / 换念法）；一拍与调序只动时间表。
  bool get changesVoice => switch (this) {
    speaker || kind || say || clearSay => true,
    beat || up || down || regenerate => false,
  };
}

/// 页 [page] 上用到 [blocks] 任一块的那一句（按块的先后找第一句）；没有返回 null。
MangaScriptLine? mangaScriptLineForBlocks(
  MangaAudioScript script,
  int page,
  List<int> blocks,
) {
  for (final int block in blocks) {
    for (final MangaScriptLine l in script.lines) {
      if (l.page == page && l.blocks.contains(block)) return l;
    }
  }
  return null;
}

/// 输入毫秒数；取消 → null，清空 → -1（用默认值）。
Future<int?> askMangaAudioMs(
  BuildContext context, {
  required String title,
  int? current,
}) async {
  final String? typed = await showFushiTextInputDialog(
    context: context,
    title: title,
    message: t.manga_audio_ms_hint,
    initialValue: current?.toString() ?? '',
    keyboardType: TextInputType.number,
    allowEmpty: true,
    icon: FushiIcons.timer,
  );
  if (typed == null) return null;
  return typed.isEmpty ? -1 : int.tryParse(typed);
}

/// 弹「改一句」对话框，把选中的改动原地写进 [session] 的演出稿（记为手改），不落盘。
/// 返回做了的动作；取消 / 没改返回 null。选 [MangaLineEditAction.regenerate] 时演出稿
/// 不动，由调用方去重生成。[canRegenerate] 为 false 时不列「换种子」。
Future<MangaLineEditAction?> showMangaLineEditDialog(
  BuildContext context, {
  required MangaAudioAnnotateSession session,
  required MangaScriptLine line,
  bool canRegenerate = false,
}) async {
  final MangaAudioScript script = session.script;
  final List<MangaScriptLine> onPage = script.linesOnPage(line.page);
  final int pos = onPage.indexWhere(
    (MangaScriptLine l) => l.lineId == line.lineId,
  );
  final String text = session.textOf(line);
  final MangaLineEditAction? action =
      await showFushiChoiceDialog<MangaLineEditAction>(
        context: context,
        title: t.manga_audio_page(page: line.page + 1),
        message: text,
        options: <FushiChoiceOption<MangaLineEditAction>>[
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.speaker,
            label: t.manga_audio_line_speaker,
            subtitle: ttsCastSpeakerLabel(line.speaker),
            icon: FushiIcons.person,
          ),
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.kind,
            label: t.manga_audio_line_kind,
            subtitle: mangaLineKindLabel(line.kind),
            icon: FushiIcons.textFields,
          ),
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.beat,
            label: t.manga_audio_line_beat,
            subtitle: t.manga_audio_ms_value(ms: line.beatMs),
            icon: FushiIcons.timer,
          ),
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.say,
            label: t.manga_audio_line_say,
            icon: FushiIcons.edit,
          ),
          if (line.say != null)
            FushiChoiceOption<MangaLineEditAction>(
              value: MangaLineEditAction.clearSay,
              label: t.manga_audio_line_say_clear,
              icon: FushiIcons.undo,
            ),
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.up,
            label: t.manga_audio_line_move_up,
            icon: FushiIcons.arrowUp,
            enabled: pos > 0,
          ),
          FushiChoiceOption<MangaLineEditAction>(
            value: MangaLineEditAction.down,
            label: t.manga_audio_line_move_down,
            icon: FushiIcons.arrowDown,
            enabled: pos >= 0 && pos < onPage.length - 1,
          ),
          if (canRegenerate)
            FushiChoiceOption<MangaLineEditAction>(
              value: MangaLineEditAction.regenerate,
              label: t.manga_audio_regenerate,
              icon: FushiIcons.shuffle,
            ),
        ],
      );
  if (action == null || !context.mounted) return null;

  void replace(MangaScriptLine next) {
    script.replaceLine(line.lineId, (MangaScriptLine _) => next);
  }

  switch (action) {
    case MangaLineEditAction.speaker:
      final String? speaker = await _pickSpeaker(context, session, line);
      if (speaker == null || speaker == line.speaker) return null;
      replace(line.copyWith(speaker: speaker, source: TtsCastSource.user));
    case MangaLineEditAction.kind:
      final CastLineKind? kind = await showFushiChoiceDialog<CastLineKind>(
        context: context,
        title: t.manga_audio_line_kind,
        message: text,
        selected: line.kind,
        options: <FushiChoiceOption<CastLineKind>>[
          for (final CastLineKind k in CastLineKind.values)
            FushiChoiceOption<CastLineKind>(
              value: k,
              label: mangaLineKindLabel(k),
            ),
        ],
      );
      if (kind == null || kind == line.kind) return null;
      replace(line.copyWith(kind: kind, source: TtsCastSource.user));
    case MangaLineEditAction.beat:
      final int? ms = await askMangaAudioMs(
        context,
        title: t.manga_audio_line_beat,
        current: line.beatMs,
      );
      if (ms == null) return null;
      replace(
        line.copyWith(
          beatMs: ms < 0 ? 0 : ms.clamp(0, MangaScriptLimits.maxBeatMs),
          source: TtsCastSource.user,
        ),
      );
    case MangaLineEditAction.say:
      final String? typed = await showFushiTextInputDialog(
        context: context,
        title: t.manga_audio_line_say,
        initialValue: text,
        maxLines: 4,
        icon: FushiIcons.edit,
      );
      if (typed == null || typed.isEmpty) return null;
      replace(line.copyWith(say: typed, source: TtsCastSource.user));
    case MangaLineEditAction.clearSay:
      replace(line.copyWith(clearSay: true, source: TtsCastSource.user));
    case MangaLineEditAction.up:
    case MangaLineEditAction.down:
      final MangaScriptLine other =
          onPage[action == MangaLineEditAction.up ? pos - 1 : pos + 1];
      final List<MangaScriptLine> lines = script.lines;
      final int a = lines.indexWhere(
        (MangaScriptLine l) => l.lineId == line.lineId,
      );
      final int b = lines.indexWhere(
        (MangaScriptLine l) => l.lineId == other.lineId,
      );
      if (a < 0 || b < 0) return null;
      // 调序也是用户的判断：两行都记为手改，重标时保留顺序。
      lines[a] = other.copyWith(source: TtsCastSource.user);
      lines[b] = line.copyWith(source: TtsCastSource.user);
    case MangaLineEditAction.regenerate:
      break;
  }
  return action;
}

Future<String?> _pickSpeaker(
  BuildContext context,
  MangaAudioAnnotateSession session,
  MangaScriptLine line,
) async {
  const String newSpeaker = '\u0000new';
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: t.manga_audio_line_speaker,
    message: session.textOf(line),
    selected: line.speaker,
    options: <FushiChoiceOption<String>>[
      FushiChoiceOption<String>(
        value: kTtsNarrator,
        label: t.audiobook_studio_cast_narrator,
      ),
      for (final TtsCastCharacter c in session.roster.values)
        FushiChoiceOption<String>(
          value: c.name,
          label: c.name,
          subtitle: c.aliases.isEmpty ? null : c.aliases.join('、'),
        ),
      FushiChoiceOption<String>(
        value: kTtsUnknown,
        label: t.audiobook_studio_cast_unknown,
      ),
      FushiChoiceOption<String>(
        value: newSpeaker,
        label: t.audiobook_studio_cast_new_speaker,
        icon: FushiIcons.add,
      ),
    ],
  );
  if (picked != newSpeaker || !context.mounted) return picked;
  final String? typed = await showFushiTextInputDialog(
    context: context,
    title: t.audiobook_studio_cast_new_speaker,
    labelText: t.manga_audio_line_speaker,
    icon: FushiIcons.personAdd,
  );
  final String name = typed?.trim() ?? '';
  if (name.isEmpty) return null;
  session.addCharacter(name);
  return name;
}

// -----------------------------------------------------------------------------
// 单句换种子：重生成 → 试听 → 保留 / 撤回（制作台与阅读页同一份）
// -----------------------------------------------------------------------------

/// 单句重生成用的声音：这卷最近一次任务的声音 → 当前朗读声音 → 第一个可选声音
/// （制作台的默认顺序），不在可选声音里的跳过。都没有返回 null。
String? mangaRegenerateVoiceFor(AudioProductionHost host, String bookKey) {
  final TtsServices tts = TtsServices.of(host.prefsRepo);
  final List<TtsVoicePreset> presets = ttsProductionPresets(tts, host);
  bool known(String? id) =>
      id != null && presets.any((TtsVoicePreset p) => p.id == id);
  final String? job = ttsRenderQueueFor(host).latestFor(bookKey)?.presetId;
  if (known(job)) return job;
  final String? active = tts.store.activePreset()?.id;
  if (known(active)) return active;
  return presets.firstOrNull?.id;
}

/// 这卷有没有未结束的生成任务（期间不做单句重生成：任务结束时会重写清单）。
bool mangaRenderBusy(AudioProductionHost host, String bookKey) {
  final TtsRenderJob? job = ttsRenderQueueFor(host).latestFor(bookKey);
  return job != null && !job.isTerminal;
}

/// 以 [seed]（不给 = 随机）重生成 [lineId] 并让用户试听、保留或撤回。返回 true = 保留了。
/// 失败弹提示返回 false。[voice] 是没有更细指派时用的声音。
Future<bool> regenerateMangaLineWithReview(
  BuildContext context, {
  required AudioProductionHost host,
  required MangaAudioVolume volume,
  required String lineId,
  required String voice,
  int? seed,
}) async {
  final int useSeed = seed ?? math.Random().nextInt(MangaScriptLimits.maxSeed);
  MangaRegenerateCandidate? candidate;
  try {
    candidate = await regenerateMangaLine(
      host,
      volume: volume,
      lineId: lineId,
      seed: useSeed,
      defaultVoice: voice,
      cancel: TtsRenderCancelToken(),
    );
  } on MangaLineFailure catch (e) {
    FushiToast.show(
      msg: t.manga_audio_regenerate_failed(
        reason: ttsRenderFailureText(e.code),
      ),
      severity: ToastSeverity.error,
    );
  } on TtsRenderFailure catch (e) {
    FushiToast.show(
      msg: t.manga_audio_regenerate_failed(
        reason: ttsRenderFailureText(e.code),
      ),
      severity: ToastSeverity.error,
    );
  }
  if (candidate == null) return false;
  if (!context.mounted) {
    await discardMangaCandidate(host, volume.bookKey, candidate);
    return false;
  }
  return _reviewCandidate(context, host, volume, candidate);
}

/// 试听候选，直到用户选保留或撤回（关掉对话框 = 撤回）。试听前暂停正在播的有声书，
/// 免得两路声音叠在一起。
Future<bool> _reviewCandidate(
  BuildContext context,
  AudioProductionHost host,
  MangaAudioVolume volume,
  MangaRegenerateCandidate candidate,
) async {
  final AudiobookPlayerController? playing = host.audiobookSession.controller;
  if (playing != null && playing.isPlaying) await playing.pause();
  final String path = mangaCandidatePath(host, volume.bookKey, candidate);
  final AudioPlayer player = AudioPlayer();
  Future<void> play() async {
    try {
      await player.stop();
      await player.setFilePath(path);
      await player.play();
    } on Exception catch (e, stack) {
      ErrorLogService.instance.log('MangaAudioLine.preview', e, stack);
    }
  }

  bool kept = false;
  try {
    unawaited(play());
    while (true) {
      if (!context.mounted) {
        await discardMangaCandidate(host, volume.bookKey, candidate);
        return false;
      }
      final String? action = await showFushiChoiceDialog<String>(
        context: context,
        title: t.manga_audio_candidate_title(seed: candidate.seed),
        message: candidate.text,
        options: <FushiChoiceOption<String>>[
          FushiChoiceOption<String>(
            value: 'play',
            label: t.manga_audio_preview,
            icon: FushiIcons.play,
          ),
          FushiChoiceOption<String>(
            value: 'keep',
            label: t.manga_audio_candidate_keep,
            icon: FushiIcons.success,
          ),
          FushiChoiceOption<String>(
            value: 'revert',
            label: t.manga_audio_candidate_revert,
            icon: FushiIcons.undo,
          ),
        ],
      );
      if (action == 'play') {
        unawaited(play());
        continue;
      }
      await player.stop();
      if (action == 'keep') {
        kept = await keepMangaCandidate(
          host,
          volume: volume,
          candidate: candidate,
        );
      } else {
        await discardMangaCandidate(host, volume.bookKey, candidate);
      }
      return kept;
    }
  } finally {
    unawaited(player.dispose());
  }
}

// -----------------------------------------------------------------------------
// 阅读页入口
// -----------------------------------------------------------------------------

/// 阅读页右键 / 长按命中的气泡在不在这卷演出稿里（菜单据此决定列不列「编辑这句配音」）。
/// 只读演出稿文件，不解析整卷 OCR。
Future<bool> mangaAudioHasLineAt(
  AudioProductionHost host, {
  required String bookKey,
  required int page,
  required List<int> blocks,
}) async {
  if (blocks.isEmpty) return false;
  final MangaAudioScript script = await mangaAudioScriptStoreFor(
    host,
  ).load(bookKey);
  return mangaScriptLineForBlocks(script, page, blocks) != null;
}

/// 阅读页「编辑这句配音」：就地改命中气泡那一句（不离开阅读页），存盘；这句已经生成过
/// 时，改了说话人 / 类型 / 念法就只重新生成这一句（试听 → 保留 / 撤回），也可以直接
/// 换种子重生成。标注任务在跑、OCR 重跑过（要重新标注）、或读盘后被别处改过时不写，
/// 提示用户。
Future<void> editMangaAudioLineInPlace(
  BuildContext context, {
  required AudioProductionHost host,
  required String bookKey,
  required int page,
  required List<int> blocks,
}) async {
  if (mangaAnnotateTasksFor(host).runningFor(bookKey) != null) {
    FushiToast.show(
      msg: t.manga_audio_review_locked,
      severity: ToastSeverity.warning,
    );
    return;
  }
  final MangaAudioAnnotateSession session;
  try {
    session = await MangaAudioAnnotateSession.open(host, bookKey);
  } on MangaAudioAnnotateError catch (e) {
    FushiToast.show(
      msg: mangaAudioErrorText(e.code),
      severity: ToastSeverity.warning,
    );
    return;
  }
  // OCR 重跑过：演出稿里的块下标指的是旧 OCR，按当前落点的块找到的那句可能是别的气泡，
  // 改了也会在整卷重新标注时被覆盖。不按块匹配，直接提示要重新标注。
  if (session.isStale) {
    FushiToast.show(msg: t.manga_audio_stale, severity: ToastSeverity.warning);
    return;
  }
  final MangaScriptLine? line = mangaScriptLineForBlocks(
    session.script,
    page,
    blocks,
  );
  if (line == null) {
    FushiToast.show(msg: t.manga_audio_line_not_in_script);
    return;
  }
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    mangaRenderManifestFile(host, bookKey),
  );
  final bool rendered =
      manifest?.lines.any((MangaRenderedLine l) => l.lineId == line.lineId) ??
      false;
  if (!context.mounted) return;
  final MangaLineEditAction? action = await showMangaLineEditDialog(
    context,
    session: session,
    line: line,
    canRegenerate: rendered,
  );
  if (action == null || !context.mounted) return;
  if (action != MangaLineEditAction.regenerate) {
    // 对话框开着时标注任务可能开始：任务用自己的会话落盘，这里不写。
    final bool written =
        mangaAnnotateTasksFor(host).runningFor(bookKey) == null &&
        await session.saveReviewEdits();
    if (!written) {
      FushiToast.show(
        msg: t.manga_audio_review_conflict,
        severity: ToastSeverity.warning,
      );
      return;
    }
    if (!rendered || !action.changesVoice) {
      FushiToast.show(msg: t.manga_audio_line_saved);
      return;
    }
  }
  // 这句是「不读」类型（刚改成的，或早就是、清单还没跟上）：不再出声，从成品里拿掉，
  // 不重新合成（与整卷生成同一判据，HBK-AUDIT-214）。这卷正在生成时由那个任务持有
  // 清单，这里不写，提示等它结束。
  final MangaScriptLine? edited = session.script.lineById(line.lineId);
  if (!(edited?.kind.isAudible ?? false)) {
    if (mangaRenderBusy(host, bookKey)) {
      FushiToast.show(msg: t.manga_audio_line_not_read_render_busy);
      return;
    }
    await dropMangaUnreadLines(
      host,
      bookKey: bookKey,
      script: session.script,
      lineIds: <String>[line.lineId],
    );
    FushiToast.show(msg: t.manga_audio_line_not_read_dropped);
    return;
  }
  if (!context.mounted) return;
  if (mangaRenderBusy(host, bookKey)) {
    FushiToast.show(msg: t.manga_audio_line_saved_render_busy);
    return;
  }
  final String? voice = mangaRegenerateVoiceFor(host, bookKey);
  if (voice == null) {
    FushiToast.show(
      msg: t.manga_audio_line_no_voice,
      severity: ToastSeverity.warning,
    );
    return;
  }
  final MangaAudioVolume? volume = await loadMangaAudioVolume(host, bookKey);
  if (volume == null || !context.mounted) return;
  FushiToast.show(msg: t.manga_audio_line_regenerating);
  await regenerateMangaLineWithReview(
    context,
    host: host,
    volume: volume,
    lineId: line.lineId,
    voice: voice,
  );
}
