/// TTS 引擎 / 参数 / 失败码的界面文案（引擎层只给稳定 id，文案在这里翻译）。
library;

import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';

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
  _ => key,
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
String? ttsParamHint(String providerId, String key) =>
    switch ((providerId, key)) {
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
      _ => null,
    };

/// 失败码的文案。给了 [descriptor] 且该引擎不需要凭据（微软 Edge / 翻译接口等免费
/// 接口）时，「拒绝了请求」不提示去检查密钥——用户根本没有密钥可查，那是服务端
/// 拒绝（例如 Edge 旧主机对各地出口一律 403）。
String ttsFailureText(
  TtsFailure failure, {
  TtsProviderDescriptor? descriptor,
}) => switch (failure.code) {
  TtsFailureCode.notConfigured => t.audiobook_tts_failure_not_configured,
  TtsFailureCode.network => t.audiobook_tts_failure_network,
  TtsFailureCode.timeout => t.audiobook_tts_failure_timeout,
  TtsFailureCode.unauthorized
      when descriptor != null && !descriptor.capabilities.needsCredential =>
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
