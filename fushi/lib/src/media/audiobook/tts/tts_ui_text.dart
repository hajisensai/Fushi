/// TTS 引擎 / 参数 / 失败码的界面文案（引擎层只给稳定 id，文案在这里翻译）。
library;

import 'package:fushi_engine/tts/providers/azure_tts_provider.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/google_cloud_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';

String ttsProviderLabel(String providerId) => switch (providerId) {
  GptSovitsTtsDescriptor.providerId => t.audiobook_tts_provider_gpt_sovits,
  EdgeTtsDescriptor.providerId => t.audiobook_tts_provider_edge,
  AzureTtsDescriptor.providerId => t.audiobook_tts_provider_azure,
  GoogleCloudTtsDescriptor.providerId => t.audiobook_tts_provider_google_cloud,
  SystemTtsDescriptor.providerId => t.audiobook_tts_provider_system,
  _ => providerId,
};

String ttsParamLabel(String key) => switch (key) {
  GptSovitsTtsDescriptor.endpointKey => t.audiobook_tts_param_endpoint,
  GptSovitsTtsDescriptor.textLangKey => t.audiobook_tts_param_text_lang,
  GptSovitsTtsDescriptor.refAudioKey => t.audiobook_tts_param_ref_audio,
  GptSovitsTtsDescriptor.promptTextKey => t.audiobook_tts_param_prompt_text,
  GptSovitsTtsDescriptor.promptLangKey => t.audiobook_tts_param_prompt_lang,
  AzureTtsDescriptor.regionKey => t.audiobook_tts_param_region,
  'api_key' => t.audiobook_tts_param_api_key,
  'voice' => t.audiobook_tts_param_voice,
  _ => key,
};

/// 参数下方的说明（没有返回 null）。
String? ttsParamHint(String providerId, String key) =>
    switch ((providerId, key)) {
      (GptSovitsTtsDescriptor.providerId, GptSovitsTtsDescriptor.refAudioKey) =>
        t.audiobook_tts_param_ref_audio_hint,
      (GptSovitsTtsDescriptor.providerId, GptSovitsTtsDescriptor.apiKeyKey) =>
        t.audiobook_tts_param_bearer_hint,
      _ => null,
    };

String ttsFailureText(TtsFailure failure) => switch (failure.code) {
  TtsFailureCode.notConfigured => t.audiobook_tts_failure_not_configured,
  TtsFailureCode.network => t.audiobook_tts_failure_network,
  TtsFailureCode.timeout => t.audiobook_tts_failure_timeout,
  TtsFailureCode.unauthorized => t.audiobook_tts_failure_unauthorized,
  TtsFailureCode.rateLimited => t.audiobook_tts_failure_rate_limited,
  TtsFailureCode.serverError => t.audiobook_tts_failure_server,
  TtsFailureCode.badResponse => t.audiobook_tts_failure_bad_response,
  TtsFailureCode.unsupported => t.audiobook_tts_failure_unsupported,
  TtsFailureCode.cancelled => t.audiobook_tts_failure_cancelled,
};
