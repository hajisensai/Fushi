/// 漫画演出标注的界面闸门：页图上传同意（每台设备一次，与 Google Lens 同款）、发起前
/// 的预估请求数确认、错误短码 → 文案。
library;

import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 同意书版本；同意书内容实质变化时加一，所有设备重新问一次。
const int kMangaAudioUploadConsentVersion = 1;

/// 设备本地键（SharedPreferences，不进 Profile / 备份 / 同步：同意要在每台上传页图的
/// 设备上单独取得，理由同 `google_lens_disclosure.dart`）。
const String kMangaAudioUploadConsentKey =
    'manga_audio_ai_upload_consent_version';

Future<bool> hasMangaAudioUploadConsent() async =>
    (await SharedPreferences.getInstance()).getInt(
      kMangaAudioUploadConsentKey,
    ) ==
    kMangaAudioUploadConsentVersion;

/// 首次使用时问一次是否同意把页图发给 AI 服务商；拒绝则不发请求。
Future<bool> ensureMangaAudioUploadConsent(BuildContext context) async {
  if (await hasMangaAudioUploadConsent()) return true;
  if (!context.mounted) return false;
  final bool accepted = await showFushiConfirmDialog(
    context: context,
    title: t.manga_audio_upload_consent_title,
    message: t.manga_audio_upload_consent_body,
    icon: FushiIcons.cloudUpload,
    cancelLabel: t.manga_audio_upload_consent_decline,
    confirmLabel: t.manga_audio_upload_consent_accept,
  );
  if (!accepted) return false;
  await (await SharedPreferences.getInstance()).setInt(
    kMangaAudioUploadConsentKey,
    kMangaAudioUploadConsentVersion,
  );
  return true;
}

/// 「提供商名 · 模型」。
String mangaAudioProviderLabel(AiProviderConfig provider) {
  final String model = provider.model.trim();
  return model.isEmpty ? provider.name : '${provider.name} · $model';
}

/// 发起前确认预估请求数；没有要标的页时直接提示并返回 false。
Future<bool> confirmMangaAnnotationEstimate(
  BuildContext context, {
  required MangaAnnotationEstimate estimate,
  required AiProviderConfig provider,
}) async {
  if (estimate.pageRequests == 0) {
    await showFushiConfirmDialog(
      context: context,
      title: t.manga_audio_estimate_title,
      message: t.manga_audio_estimate_nothing,
      icon: FushiIcons.ai,
    );
    return false;
  }
  if (!context.mounted) return false;
  return showFushiConfirmDialog(
    context: context,
    title: t.manga_audio_estimate_title,
    message: t.manga_audio_estimate_body(
      provider: mangaAudioProviderLabel(provider),
      pages: estimate.pageRequests,
      requests: estimate.total,
      images: estimate.imageRequests,
    ),
    icon: FushiIcons.ai,
  );
}

/// 开不了标注的原因（`MangaAudioAnnotateError.code`）→ 文案。
String mangaAudioErrorText(String code) => switch (code) {
  'no_ai_provider' => t.manga_audio_error_no_provider,
  'online_unsupported' => t.manga_audio_error_online,
  'no_ocr' => t.manga_audio_error_no_ocr,
  'not_found' || 'unreadable' => t.manga_audio_error_unreadable,
  _ => aiFailureText(code),
};

/// 账本里一次失败的原因 → 文案。
String mangaAnnotateFailureText(MangaAnnotateAttempt attempt) =>
    switch (attempt.code) {
      MangaAnnotateFailureCode.network => t.manga_audio_failure_network,
      MangaAnnotateFailureCode.badOutput => t.manga_audio_failure_bad_output,
      MangaAnnotateFailureCode.validation => t.manga_audio_failure_validation,
      MangaAnnotateFailureCode.image => t.manga_audio_failure_image,
      _ => aiFailureText(attempt.detail ?? attempt.code),
    };

/// 失败条目的标题。
String mangaAnnotateFailureTitle(MangaAnnotateFailure failure) =>
    switch (failure.stage) {
      MangaAnnotateStage.roster => t.manga_audio_failure_roster,
      MangaAnnotateStage.page => t.manga_audio_page(page: failure.page + 1),
      MangaAnnotateStage.review => t.manga_audio_failure_review(
        page: failure.page + 1,
      ),
    };

/// 句子类型 → 文案。
String mangaLineKindLabel(CastLineKind kind) => switch (kind) {
  CastLineKind.narration => t.manga_audio_kind_narration,
  CastLineKind.monologue => t.manga_audio_kind_monologue,
  CastLineKind.thought => t.manga_audio_kind_thought,
  CastLineKind.spoken => t.manga_audio_kind_spoken,
  CastLineKind.shout => t.manga_audio_kind_shout,
  CastLineKind.mutter => t.manga_audio_kind_mutter,
  CastLineKind.skip => t.manga_audio_kind_skip,
};

/// 语气（情绪）→ 文案；null = 不标。
String mangaEmotionLabel(CastEmotion? emotion) => switch (emotion) {
  null => t.manga_audio_emotion_none,
  CastEmotion.neutral => t.manga_audio_emotion_neutral,
  CastEmotion.joy => t.manga_audio_emotion_joy,
  CastEmotion.sadness => t.manga_audio_emotion_sadness,
  CastEmotion.anger => t.manga_audio_emotion_anger,
  CastEmotion.surprise => t.manga_audio_emotion_surprise,
  CastEmotion.fear => t.manga_audio_emotion_fear,
  CastEmotion.disgust => t.manga_audio_emotion_disgust,
  CastEmotion.embarrassment => t.manga_audio_emotion_embarrassment,
  CastEmotion.tenderness => t.manga_audio_emotion_tenderness,
  CastEmotion.tension => t.manga_audio_emotion_tension,
};

/// 一句的语气摘要：「愤怒 80」；没标语气返回 null。
String? mangaLineToneLabel(MangaScriptLine line) {
  final CastEmotion? emotion = line.emotion;
  if (emotion == null) return null;
  final int? intensity = line.intensity;
  return intensity == null
      ? mangaEmotionLabel(emotion)
      : '${mangaEmotionLabel(emotion)} $intensity';
}

/// 复核界面优先列出的行：说话人不明，或 AI 自评把握低于此值。
const double kMangaReviewConfidence = 0.6;

/// 这句是否需要人看一眼（AI 标的、说话人不明或把握低）。
bool mangaLineNeedsReview(MangaScriptLine line) =>
    line.source == TtsCastSource.llm &&
    line.kind.isAudible &&
    (line.speaker == kTtsUnknown ||
        (line.confidence != null && line.confidence! < kMangaReviewConfidence));
