/// TTS 引擎 / 参数 / 失败码的界面文案（引擎层只给稳定 id，文案在这里翻译）。
library;

import 'package:fushi_engine/tts/local/local_service_support.dart'
    show LocalInstallRemoveException;
import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/providers/voicepeak_tts_provider.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/onboarding/onboarding_sample_text.dart';
import 'package:fushi/src/utils/misc/system_tts.dart';

/// 「删除本机引擎」删不掉时的提示（路径 + 系统给的原因）。
String localInstallRemoveFailureText(LocalInstallRemoveException error) =>
    t.audiobook_tts_local_delete_failed(
      path: error.path,
      reason: error.cause.osError?.message ?? error.cause.message,
    );

String ttsProviderLabel(String providerId) => switch (providerId) {
  GptSovitsTtsDescriptor.providerId => t.audiobook_tts_provider_gpt_sovits,
  IrodoriTtsDescriptor.providerId => t.audiobook_tts_provider_irodori,
  IrodoriServerTtsDescriptor.providerId =>
    t.audiobook_tts_provider_irodori_server,
  EdgeTtsDescriptor.providerId => t.audiobook_tts_provider_edge,
  MicrosoftTranslatorTtsDescriptor.providerId =>
    t.audiobook_tts_provider_ms_translator,
  GoogleTranslateTtsDescriptor.providerId =>
    t.audiobook_tts_provider_google_translate,
  AzureTtsDescriptor.providerId => t.audiobook_tts_provider_azure,
  GoogleCloudTtsDescriptor.providerId => t.audiobook_tts_provider_google_cloud,
  SystemTtsDescriptor.providerId => t.audiobook_tts_provider_system,
  VoicevoxTtsDescriptor.providerId => t.audiobook_tts_provider_voicevox,
  AivisSpeechTtsDescriptor.providerId => t.audiobook_tts_provider_aivis_speech,
  SharevoxTtsDescriptor.providerId => t.audiobook_tts_provider_sharevox,
  VoicepeakTtsDescriptor.providerId => t.audiobook_tts_provider_voicepeak,
  _ => providerId,
};

/// 服务类型切换菜单里每个引擎的说明（免费 / 需密钥）。
String? ttsProviderHint(String providerId) => switch (providerId) {
  EdgeTtsDescriptor.providerId ||
  MicrosoftTranslatorTtsDescriptor.providerId ||
  GoogleTranslateTtsDescriptor.providerId =>
    t.audiobook_tts_unofficial_free_hint,
  AzureTtsDescriptor.providerId ||
  GoogleCloudTtsDescriptor.providerId => t.audiobook_tts_key_required_hint,
  VoicevoxTtsDescriptor.providerId ||
  AivisSpeechTtsDescriptor.providerId ||
  SharevoxTtsDescriptor.providerId => t.audiobook_tts_provider_voicevox_hint,
  VoicepeakTtsDescriptor.providerId => t.audiobook_tts_provider_voicepeak_hint,
  _ => null,
};

String ttsCategoryLabel(TtsProviderCategory category) => switch (category) {
  TtsProviderCategory.external => t.audiobook_tts_category_external,
  TtsProviderCategory.online => t.audiobook_tts_category_online,
  TtsProviderCategory.system => t.audiobook_tts_category_system,
};

String ttsCategoryHint(TtsProviderCategory category) => switch (category) {
  TtsProviderCategory.external => t.audiobook_tts_category_external_hint,
  TtsProviderCategory.online => t.audiobook_tts_category_online_hint,
  TtsProviderCategory.system => t.audiobook_tts_category_system_hint,
};

String ttsParamLabel(String key) => switch (key) {
  GptSovitsTtsDescriptor.endpointKey => t.audiobook_tts_param_endpoint,
  GptSovitsTtsDescriptor.textLangKey => t.audiobook_tts_param_text_lang,
  GptSovitsTtsDescriptor.refAudioKey => t.audiobook_tts_param_ref_audio,
  GptSovitsTtsDescriptor.promptTextKey => t.audiobook_tts_param_prompt_text,
  GptSovitsTtsDescriptor.promptLangKey => t.audiobook_tts_param_prompt_lang,
  AzureTtsDescriptor.regionKey => t.audiobook_tts_param_region,
  IrodoriServerTtsDescriptor.captionKey => t.audiobook_tts_param_caption,
  'api_key' => t.audiobook_tts_param_api_key,
  'voice' => t.audiobook_tts_param_voice,
  SystemTtsDescriptor.engineKey => t.audiobook_tts_param_engine,
  VoicevoxCompatibleTtsDescriptor.speakerKey => t.audiobook_tts_param_speaker,
  VoicevoxCompatibleTtsDescriptor.speedScaleKey ||
  VoicepeakTtsDescriptor.speedKey => t.audiobook_tts_param_speed,
  VoicevoxCompatibleTtsDescriptor.pitchScaleKey ||
  VoicepeakTtsDescriptor.pitchKey => t.audiobook_tts_param_pitch,
  VoicevoxCompatibleTtsDescriptor.intonationScaleKey =>
    t.audiobook_tts_param_intonation,
  VoicevoxCompatibleTtsDescriptor.volumeScaleKey =>
    t.audiobook_tts_param_volume,
  VoicepeakTtsDescriptor.executableKey => t.audiobook_tts_param_executable,
  VoicepeakTtsDescriptor.narratorKey => t.audiobook_tts_param_narrator,
  VoicepeakTtsDescriptor.emotionKey => t.audiobook_tts_param_emotion,
  _ => key,
};

/// 非必填的声音类参数「不选」时显示什么（系统语音：默认引擎 / 按文字语言自动挑）。
String ttsParamEmptyLabel(String key) => switch (key) {
  SystemTtsDescriptor.engineKey => t.audiobook_tts_param_engine_default,
  _ => t.audiobook_tts_param_voice_auto,
};

/// GPT-SoVITS 语言代码的可读名称（`ja` 是「日语，夹杂的英文按英文读」，
/// `all_ja` 是「整句都按日语读」——只显示代码的话用户分不清）。未知代码原样返回。
String ttsLanguageLabel(String code) => switch (code) {
  'ja' => t.audiobook_tts_lang_ja,
  'all_ja' => t.audiobook_tts_lang_all_ja,
  'zh' => t.audiobook_tts_lang_zh,
  'all_zh' => t.audiobook_tts_lang_all_zh,
  'en' => t.audiobook_tts_lang_en,
  'ko' => t.audiobook_tts_lang_ko,
  'all_ko' => t.audiobook_tts_lang_all_ko,
  'yue' => t.audiobook_tts_lang_yue,
  'all_yue' => t.audiobook_tts_lang_all_yue,
  'auto' => t.audiobook_tts_lang_auto,
  'auto_yue' => t.audiobook_tts_lang_auto_yue,
  _ => code,
};

/// 参数下方的说明（没有返回 null）。
String? ttsParamHint(String providerId, String key) => switch ((
  providerId,
  key,
)) {
  (GptSovitsTtsDescriptor.providerId, GptSovitsTtsDescriptor.refAudioKey) =>
    t.audiobook_tts_param_ref_audio_hint,
  (GptSovitsTtsDescriptor.providerId, GptSovitsTtsDescriptor.apiKeyKey) =>
    t.audiobook_tts_param_bearer_hint,
  (IrodoriTtsDescriptor.providerId, IrodoriTtsDescriptor.endpointKey) =>
    t.audiobook_tts_param_irodori_endpoint_hint,
  (
    IrodoriServerTtsDescriptor.providerId,
    IrodoriServerTtsDescriptor.endpointKey,
  ) =>
    t.audiobook_tts_param_irodori_server_endpoint_hint,
  (
    IrodoriServerTtsDescriptor.providerId,
    IrodoriServerTtsDescriptor.captionKey,
  ) =>
    t.audiobook_tts_param_caption_hint,
  (
    IrodoriServerTtsDescriptor.providerId,
    IrodoriServerTtsDescriptor.apiKeyKey,
  ) =>
    t.audiobook_tts_param_bearer_hint,
  (
    VoicevoxTtsDescriptor.providerId ||
        AivisSpeechTtsDescriptor.providerId ||
        SharevoxTtsDescriptor.providerId,
    VoicevoxCompatibleTtsDescriptor.endpointKey,
  ) =>
    t.audiobook_tts_param_voicevox_endpoint_hint,
  (
    VoicevoxTtsDescriptor.providerId ||
        AivisSpeechTtsDescriptor.providerId ||
        SharevoxTtsDescriptor.providerId,
    VoicevoxCompatibleTtsDescriptor.speedScaleKey ||
        VoicevoxCompatibleTtsDescriptor.pitchScaleKey ||
        VoicevoxCompatibleTtsDescriptor.intonationScaleKey ||
        VoicevoxCompatibleTtsDescriptor.volumeScaleKey,
  ) =>
    t.audiobook_tts_param_voicevox_scale_hint,
  (VoicepeakTtsDescriptor.providerId, VoicepeakTtsDescriptor.executableKey) =>
    t.audiobook_tts_param_voicepeak_executable_hint,
  (VoicepeakTtsDescriptor.providerId, VoicepeakTtsDescriptor.emotionKey) =>
    t.audiobook_tts_param_voicepeak_emotion_hint,
  (VoicepeakTtsDescriptor.providerId, VoicepeakTtsDescriptor.speedKey) =>
    t.audiobook_tts_param_voicepeak_speed_hint,
  (VoicepeakTtsDescriptor.providerId, VoicepeakTtsDescriptor.pitchKey) =>
    t.audiobook_tts_param_voicepeak_pitch_hint,
  _ => null,
};

/// 失败码的文案。给了 [descriptor] 且该引擎不需要凭据（微软 Edge / 翻译接口等免费
/// 接口）时，「拒绝了请求」不提示去检查密钥——用户根本没有密钥可查，那是服务端
/// 拒绝（例如 Edge 旧主机对各地出口一律 403）。
///
/// 系统语音的失败（[SystemTtsFailure]）带具体原因与语言，用它自己的文案
/// （「系统语音不支持 xx，可以……」），不落成笼统的「不支持」（BUG-3669）。
String ttsFailureText(
  TtsFailure failure, {
  TtsProviderDescriptor? descriptor,
}) => failure is SystemTtsFailure
    ? systemTtsFailureText(failure)
    : switch (failure.code) {
        TtsFailureCode.notConfigured => t.audiobook_tts_failure_not_configured,
        TtsFailureCode.network => t.audiobook_tts_failure_network,
        TtsFailureCode.timeout => t.audiobook_tts_failure_timeout,
        TtsFailureCode.unauthorized
            when descriptor != null &&
                !descriptor.capabilities.needsCredential =>
          t.audiobook_tts_failure_server,
        TtsFailureCode.unauthorized => t.audiobook_tts_failure_unauthorized,
        TtsFailureCode.rateLimited => t.audiobook_tts_failure_rate_limited,
        TtsFailureCode.serverError => t.audiobook_tts_failure_server,
        TtsFailureCode.badResponse => t.audiobook_tts_failure_bad_response,
        TtsFailureCode.rejected => t.audiobook_tts_failure_rejected,
        TtsFailureCode.busy => t.audiobook_tts_failure_busy,
        TtsFailureCode.unsupported => t.audiobook_tts_failure_unsupported,
        TtsFailureCode.cancelled => t.audiobook_tts_failure_cancelled,
      };

/// 日语试听文本（日语声音 / 认不出语言时的默认）。
const String kTtsDefaultSampleText = 'こんにちは。これは朗読のテストです。';

/// 声音配置的试听文本：按 [languageTag]（BCP 47，取主语言子标签）给一句该语言的
/// 日常短句（与新手引导练习句同一份数据）；日语、认不出或没有该语言的句子时用
/// [kTtsDefaultSampleText]。
String ttsSampleTextFor(String? languageTag) {
  final String? primary = onboardingPrimaryLanguageSubtag(languageTag);
  if (primary == null || primary == 'ja') return kTtsDefaultSampleText;
  return kOnboardingSampleSentences[primary] ?? kTtsDefaultSampleText;
}

/// GPT-SoVITS 语言代码 → BCP 47 主语言（`all_ja` → `ja`，`yue` → `zh`）；
/// `auto` / `auto_yue` 按文字自动判，没有确定语言，返回 null。
String? ttsLanguageCodeToTag(String code) {
  final String bare = code.startsWith('all_') ? code.substring(4) : code;
  return switch (bare) {
    'ja' || 'zh' || 'en' || 'ko' => bare,
    'yue' => 'zh',
    _ => null,
  };
}

final RegExp _kVoiceLocalePrefix = RegExp(r'^([a-z]{2,3})-[A-Z]{2}');

/// 从声音配置推断它要读的语言（试听文本跟着换）：GPT-SoVITS 看「文本语言」；
/// 其余提供商看声音 id 前缀的地区代码（Edge / Azure / Google 的 `en-US-…`）。
/// 推不出返回 null（VOICEVOX / VOICEPEAK / Irodori 等日语引擎也落到这里，用日语）。
String? ttsPresetLanguage(TtsVoicePreset preset) {
  if (preset.providerId == GptSovitsTtsDescriptor.providerId) {
    return ttsLanguageCodeToTag(
      preset.param(GptSovitsTtsDescriptor.textLangKey, fallback: 'ja'),
    );
  }
  final String voice = preset.params['voice'] ?? '';
  return _kVoiceLocalePrefix.firstMatch(voice)?.group(1);
}
