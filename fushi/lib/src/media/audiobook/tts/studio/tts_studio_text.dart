/// 制作台的纯文案 / 判据（无状态，单测直接覆盖）。
library;

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_provider.dart' show kTtsMaxConcurrency;
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_annotator.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart'
    show mangaLineKindLabel;
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart'
    show kMangaAudioDramaFailure;
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 任务失败码 → 文案（码由制作流程写进任务清单）。
String ttsRenderFailureText(String? code) {
  switch (code) {
    case 'voice_missing':
      return t.audiobook_studio_failure_voice_missing;
    case 'voice_unavailable':
      return t.audiobook_studio_failure_voice_unavailable;
    case 'book_missing':
      return t.audiobook_studio_failure_book_missing;
    case 'encode_failed':
      return t.audiobook_studio_failure_encode_failed;
    case 'voice_incomplete':
      return t.audiobook_tts_voice_incomplete;
    case 'empty_book':
      return t.audiobook_tts_empty_book;
    case 'cache_busy':
      return t.audiobook_studio_failure_cache_busy;
    case 'verify_failed':
      return t.audiobook_studio_failure_verify_failed;
    case 'rate_limited_paused':
      return t.audiobook_studio_failure_rate_limited_paused;
    // 漫画有声（任务级与一句级失败码，见 `manga_audio_render_service.dart` /
    // `manga_audio_renderer.dart`）。
    case 'manga_script_empty':
      return t.manga_audio_failure_script_empty;
    case 'manga_package_importing':
      return t.manga_audio_package_error_importing;
    case 'manga_script_stale':
      return t.manga_audio_failure_script_stale;
    case 'manga_no_pages':
      return t.manga_audio_failure_no_pages;
    case 'manga_not_rendered':
      return t.manga_audio_failure_not_rendered;
    case kMangaAudioDramaFailure:
      return t.manga_audio_failure_drama_registered;
    case 'ffmpeg_missing':
      return t.manga_audio_failure_ffmpeg_missing;
    case 'empty_text':
      return t.manga_audio_failure_empty_text;
    case 'silent_output':
      return t.manga_audio_failure_silent_output;
    case 'clip_source_missing':
      return t.manga_audio_failure_clip_missing;
    case 'line_not_read':
      return t.manga_audio_failure_line_not_read;
  }
  if (code != null && code.startsWith('tts_')) {
    final String name = code.substring(4);
    for (final TtsFailureCode value in TtsFailureCode.values) {
      if (value.name == name) return ttsFailureText(TtsFailure(value));
    }
  }
  return t.audiobook_studio_failure_internal;
}

/// 限流面板「每句间隔」滑块的步长（毫秒）。
const int kTtsStudioGapStepMs = 100;

/// 估算用的在线单句请求耗时（毫秒）：只用于面板上「约 N 分钟」的粗估，不参与调度。
const int kTtsStudioAssumedRequestMs = 1500;

/// 整本书在线合成的粗估分钟数：每路串行发 `ceil(句数 / 并发)` 个请求，每个请求
/// 按 [kTtsStudioAssumedRequestMs] 加上每句间隔。至少 1 分钟（有句子时）。
int ttsStudioEstimateMinutes({
  required int sentences,
  required int concurrency,
  required int gapMs,
}) {
  if (sentences <= 0) return 0;
  final int lanes = concurrency < 1 ? 1 : concurrency;
  final int perLane = (sentences + lanes - 1) ~/ lanes;
  final int ms = perLane * (kTtsStudioAssumedRequestMs + gapMs);
  final int minutes = (ms + 59999) ~/ 60000;
  return minutes < 1 ? 1 : minutes;
}

/// 「同时请求」分段的档位：固定档（[kTtsRenderOnlineConcurrencyChoices]）再加上当前
/// 生效的并发。声音预设自定义了 3 / 8 这类不在固定档里的值时，它作为额外一档出现并被
/// 选中，界面高亮的就是实际执行的并发，不会显示 2 却按 3 跑。
List<int> ttsStudioConcurrencySegments(int concurrency) {
  final int current = concurrency.clamp(1, kTtsMaxConcurrency);
  return <int>{...kTtsRenderOnlineConcurrencyChoices, current}.toList()..sort();
}

/// 任务状态行文案（运行中按阶段带进度）。
String ttsRenderJobStatusText(TtsRenderJob job) => switch (job.status) {
  TtsRenderJobStatus.queued => t.audiobook_studio_status_queued,
  TtsRenderJobStatus.done => t.audiobook_studio_status_done,
  TtsRenderJobStatus.cancelled => t.audiobook_studio_status_cancelled,
  TtsRenderJobStatus.failed => t.audiobook_studio_status_failed(
    reason: ttsRenderFailureText(job.error),
  ),
  TtsRenderJobStatus.running => switch (job.phase) {
    null || TtsRenderJobPhase.planning => t.audiobook_studio_phase_planning,
    TtsRenderJobPhase.synthesizing => t.audiobook_studio_phase_synthesizing(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.encoding => t.audiobook_studio_phase_encoding(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.verifying => t.audiobook_studio_phase_verifying(
      done: job.done,
      total: job.total,
    ),
    TtsRenderJobPhase.importing => t.audiobook_studio_phase_importing,
  },
};

/// 进度条取值：null = 不定进度；任务结束不显示进度条时调用方不用它。
double? ttsRenderJobProgress(TtsRenderJob job) {
  if (job.status == TtsRenderJobStatus.done) return 1;
  if (job.status != TtsRenderJobStatus.running || job.total <= 0) return null;
  return (job.done / job.total).clamp(0.0, 1.0);
}

/// 角色标注失败 → 文案；取消返回 null（不提示）。
String? ttsCastAnnotateFailureText(TtsCastAnnotateFailure failure) =>
    switch (failure.code) {
      'cancelled' => null,
      'no_ai_provider' => t.audiobook_studio_cast_no_ai,
      // 带上原因（哪一遍、哪章、怎么坏的），原始回复在错误日志（BUG-5366）。
      'bad_output' => t.audiobook_studio_cast_failure_bad_output_reason(
        reason: failure.detail ?? t.audiobook_studio_failure_internal,
      ),
      // 块拆到最小仍被截断：思考把输出额度用光（BUG-5369）。
      kTtsCastFailureOutputLimit =>
        t.audiobook_studio_cast_failure_output_limit,
      'ai_failed' => t.audiobook_studio_cast_failed(
        reason: failure.detail == null
            ? t.audiobook_studio_failure_internal
            : aiFailureText(failure.detail!),
      ),
      _ => t.audiobook_studio_cast_failed(
        reason: t.audiobook_studio_failure_internal,
      ),
    };

/// 标注进度：第一遍（[kTtsCastPhaseRoster]）抽角色表，其余按逐句归属算。
String ttsCastAnnotateProgressText(String? phase, int done, int total) =>
    phase == kTtsCastPhaseRoster
    ? t.audiobook_studio_cast_phase_roster(done: done, total: total)
    : t.audiobook_studio_cast_progress(done: done, total: total);

/// [chapters] 里已经过 LLM 标注的章数。
int ttsCastAnnotatedCount(TtsCast cast, Iterable<int> chapters) =>
    chapters.where(cast.annotatedSections.contains).length;

/// 逐句核对页列哪些句子：已有角色记录的，或带台词引号的；[reviewOnly] 时只列
/// 需要复核的行。
bool ttsCastIsReviewLine(
  TtsCast cast,
  TtsPlanSentence sentence, {
  bool reviewOnly = false,
}) {
  final TtsCastLine? line =
      cast.lines[ttsLineKey(sentence.section, sentence.matchStart)];
  if (reviewOnly) return line != null && line.needsReview;
  return line != null ||
      sentence.text.contains('「') ||
      sentence.text.contains('『') ||
      sentence.text.contains('“');
}

/// 「不明」的台词数（[speakers] 取自 [TtsCast.speakers]）。
int ttsCastUnknownCount(List<({String speaker, int count})> speakers) {
  for (final ({String speaker, int count}) s in speakers) {
    if (s.speaker == kTtsUnknown) return s.count;
  }
  return 0;
}

/// 角色列表的行：有台词的角色按台词数，再接角色表里还没分到台词的人（先配好
/// 声音也行）。不含旁白与「不明」。
List<({String speaker, int count})> ttsCastCharacterRows(
  TtsCast cast,
  List<({String speaker, int count})> speakers,
) {
  final List<({String speaker, int count})> rows =
      <({String speaker, int count})>[
        for (final ({String speaker, int count}) s in speakers)
          if (s.speaker != kTtsUnknown) s,
      ];
  final Set<String> seen = <String>{
    for (final ({String speaker, int count}) s in rows) s.speaker,
  };
  for (final String name in cast.roster.keys) {
    if (name == kTtsUnknown || name == kTtsNarrator || !seen.add(name)) {
      continue;
    }
    rows.add((speaker: name, count: 0));
  }
  return rows;
}

/// 角色名的显示（旁白 / 不明是固定角色，其余原样）。
String ttsCastSpeakerLabel(String speaker) => switch (speaker) {
  kTtsNarrator => t.audiobook_studio_cast_narrator,
  kTtsUnknown => t.audiobook_studio_cast_unknown,
  _ => speaker,
};

String? _genderLabel(String? gender) => switch (gender) {
  'female' => t.audiobook_studio_cast_gender_female,
  'male' => t.audiobook_studio_cast_gender_male,
  _ => null,
};

String? _ageLabel(String? age) => switch (age) {
  'child' => t.audiobook_studio_cast_age_child,
  'teen' => t.audiobook_studio_cast_age_teen,
  'adult' => t.audiobook_studio_cast_age_adult,
  'elderly' => t.audiobook_studio_cast_age_elderly,
  _ => null,
};

/// 角色特征一行（性别 · 年龄 · 别名 · 人设）；什么都没有返回 null。
String? ttsCastCharacterTraits(TtsCastCharacter? character) {
  if (character == null) return null;
  final String? description = character.description?.trim();
  final List<String> parts = <String>[
    ?_genderLabel(character.gender),
    ?_ageLabel(character.age),
    if (character.aliases.isNotEmpty)
      t.audiobook_studio_cast_aliases(names: character.aliases.join('、')),
    if (description != null && description.isNotEmpty) description,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String? ttsCastEvidenceText(TtsCastEvidence? evidence) => switch (evidence) {
  TtsCastEvidence.explicit => t.audiobook_studio_cast_evidence_explicit,
  TtsCastEvidence.anaphoric => t.audiobook_studio_cast_evidence_anaphoric,
  TtsCastEvidence.implicit => t.audiobook_studio_cast_evidence_implicit,
  null => null,
};

/// 核对页一句的副标题：说话人，LLM 标的行再带把握 / 依据，有演出字段 / 语气提示也带上。
String ttsCastLineSubtitle(TtsCastLine? line) {
  if (line == null) return ttsCastSpeakerLabel(kTtsNarrator);
  final double? confidence = line.confidence;
  return <String>[
    ttsCastSpeakerLabel(line.speaker),
    if (line.source == TtsCastSource.llm && confidence != null)
      t.audiobook_studio_cast_confidence(pct: (confidence * 100).round()),
    if (line.source == TtsCastSource.llm) ?ttsCastEvidenceText(line.evidence),
    // 演出字段：标了且不是默认「说出口」的类型、情绪（词表名 + 强度）、旧版语气提示。
    if (line.kind case final CastLineKind kind when kind != CastLineKind.spoken)
      mangaLineKindLabel(kind),
    if (line.emotion case final CastEmotion emotion)
      line.intensity == null
          ? emotion.wire
          : '${emotion.wire} ${line.intensity}',
    if (line.tone case final String tone when tone.trim().isNotEmpty)
      tone.trim(),
  ].join(' · ');
}

String ttsPausePresetLabel(TtsPausePreset preset) => switch (preset) {
  TtsPausePreset.none => t.audiobook_studio_pause_none,
  TtsPausePreset.standard => t.audiobook_studio_pause_standard,
  TtsPausePreset.literary => t.audiobook_studio_pause_literary,
  TtsPausePreset.brisk => t.audiobook_studio_pause_brisk,
};

/// 导出失败码 → 文案。`export_unsupported` 的 [detail] 列出本机 ffmpeg 缺的能力，
/// 附在说明后面。
String ttsAudiobookExportFailureText(String code, [String? detail]) =>
    code == 'export_unsupported'
    ? (detail == null || detail.trim().isEmpty
          ? t.audiobook_studio_export_unsupported
          : '${t.audiobook_studio_export_unsupported}\n${detail.trim()}')
    : t.audiobook_studio_export_failed(
        reason: detail == null || detail.trim().isEmpty
            ? t.audiobook_studio_failure_internal
            : detail.trim(),
      );

/// 导出默认文件名：`<书名>.m4b`（非法字符换成 `_`，空书名回落 `audiobook`）。
String ttsAudiobookExportFileName(String title) {
  final String safe = safeWindowsFileName(title.trim()).trim();
  return '${safe.isEmpty ? 'audiobook' : safe}.m4b';
}
