/// ElevenLabs 官方 REST TTS（用户自填 API key）：
/// - `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128`，
///   请求头 `xi-api-key`，JSON 体 `{text, model_id, language_code?, seed?}` → MP3；
/// - `GET /v1/models` → 能合成的模型（`can_do_text_to_speech`）；
/// - `GET /v2/voices` → 账户里的声音（预置 / 自己克隆的 / 从声音库收藏的）。
///
/// 免费与付费是**同一个接口**：区别在每月字符额度、并发与声音库权限。免费账户不能经
/// 接口用声音库（Voice Library）里的声音，只能用预置声音与自己的声音；额度用完时
/// 服务端回 402，或旧形状的 401 + `detail.status: quota_exceeded`，都按
/// [TtsFailureCode.quotaExceeded] 报（而不是「key 错了」）。错误形状见
/// https://elevenlabs.io/docs/eleven-api/resources/errors 。
///
/// 不发 `voice_settings`：只发其中一项会把声音在网页上保存的其余设置换成接口默认值。
/// 播放倍速由本地播放器控制。逐句语气只收种子（`seed`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class ElevenLabsTtsDescriptor extends TtsProviderDescriptor {
  const ElevenLabsTtsDescriptor();

  static const String providerId = 'elevenlabs';
  static const String apiKeyKey = 'api_key';
  static const String modelKey = 'model';
  static const String voiceKey = 'voice';
  static const String languageKey = 'language';

  /// 免费账户可用、29 种语言、读日语稳定的默认模型。
  static const String defaultModel = 'eleven_multilingual_v2';

  /// 「不指定，交给模型自己判断」。
  static const String autoLanguage = 'auto';

  /// `language_code`（ISO 639-1）。只列本应用常见的学习语言；别的语言交给模型自动判断。
  static const List<String> languages = <String>[
    autoLanguage,
    'ja',
    'zh',
    'ko',
    'en',
    'es',
    'fr',
    'de',
    'it',
    'pt',
    'ru',
  ];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: true,
    // 免费档 multilingual v2 并发 2（flash 4）；付费档可在预设里调高。
    maxConcurrency: 2,
    maxInputLength: 300,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      required: true,
      affectsAudio: false,
    ),
    // 模型列表从服务拉（新模型不用改代码），也能手填。
    TtsParamSpec(
      key: modelKey,
      kind: TtsParamKind.voice,
      required: true,
      defaultValue: defaultModel,
      allowsCustomValue: true,
    ),
    // 账户里的声音；声音库里的声音先在网页上加进账户，或手填 id（需付费档）。
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      allowsCustomValue: true,
    ),
    TtsParamSpec(
      key: languageKey,
      kind: TtsParamKind.choice,
      defaultValue: autoLanguage,
      choices: languages,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      ElevenLabsTtsProvider(
        apiKey: preset.param(apiKeyKey),
        model: preset.param(modelKey, fallback: defaultModel),
        voice: preset.param(voiceKey),
        language: preset.param(languageKey, fallback: autoLanguage),
        host: host,
      );
}

class ElevenLabsTtsProvider extends TtsProvider
    implements TtsDirectedSynthesis {
  ElevenLabsTtsProvider({
    required String apiKey,
    required String model,
    required String voice,
    required String language,
    required TtsHost host,
    Uri? apiBase,
  }) : _apiKey = apiKey.trim(),
       _model = model.trim(),
       _voice = voice.trim(),
       _language = language.trim(),
       _base = apiBase ?? kElevenLabsApiBase,
       _client = host.httpClientFactory();

  final String _apiKey;
  final String _model;
  final String _voice;
  final String _language;
  final Uri _base;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const ElevenLabsTtsDescriptor().capabilities;

  @override
  TtsDirectionSupport get directionSupport =>
      const TtsDirectionSupport(seed: true);

  Map<String, String> get _auth => <String, String>{
    'xi-api-key': _apiKey,
    HttpHeaders.userAgentHeader: 'Fushi',
  };

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) => synthesizeDirected(
    text,
    outputPath: outputPath,
    cancel: cancel,
    direction: TtsDirection.none,
  );

  @override
  Future<TtsResult> synthesizeDirected(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
    required TtsDirection direction,
  }) async {
    if (_apiKey.isEmpty || _voice.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: _base.replace(
        path: '/v1/text-to-speech/${Uri.encodeComponent(_voice)}',
        queryParameters: <String, String>{'output_format': 'mp3_44100_128'},
      ),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          elevenLabsSpeechRequest(
            text: text,
            model: _model.isEmpty
                ? ElevenLabsTtsDescriptor.defaultModel
                : _model,
            language: _language,
            seed: direction.seed,
          ),
        ),
      ),
      headers: <String, String>{
        ..._auth,
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'audio/mpeg',
      },
      classifyError: elevenLabsFailureFor,
    );
    return const TtsResult(format: TtsAudioFormat.mp3);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (_apiKey.isEmpty) throw const TtsFailure(TtsFailureCode.notConfigured);
    final List<TtsVoice> voices = <TtsVoice>[];
    String? token;
    // 账户里的声音一般几十个；翻页设上限，防止服务端一直给 next_page_token。
    for (int page = 0; page < kElevenLabsMaxVoicePages; page++) {
      final Object? raw = await ttsGetJson(
        client: _client,
        uri: _base.replace(
          path: '/v2/voices',
          queryParameters: <String, String>{
            'page_size': '100',
            if (token != null) 'next_page_token': token,
          },
        ),
        headers: _auth,
        cancel: cancel,
        classifyError: elevenLabsFailureFor,
      );
      voices.addAll(parseElevenLabsVoices(raw));
      token = raw is Map && raw['has_more'] == true
          ? raw['next_page_token'] as String?
          : null;
      if (token == null || token.isEmpty) break;
    }
    return voices;
  }

  @override
  Future<List<TtsVoice>> listParamOptions(
    String paramKey, {
    TtsCancelToken? cancel,
  }) async {
    if (paramKey != ElevenLabsTtsDescriptor.modelKey) {
      return listVoices(cancel: cancel);
    }
    if (_apiKey.isEmpty) throw const TtsFailure(TtsFailureCode.notConfigured);
    return parseElevenLabsModels(
      await ttsGetJson(
        client: _client,
        uri: _base.replace(path: '/v1/models'),
        headers: _auth,
        cancel: cancel,
        classifyError: elevenLabsFailureFor,
      ),
    );
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// 官方接口根（测试换成本机假服务）。
final Uri kElevenLabsApiBase = Uri.https('api.elevenlabs.io');

/// 列声音最多翻几页（每页 100）。
const int kElevenLabsMaxVoicePages = 5;

/// 不收 `language_code` 的模型（文档：multilingual v2 不支持该字段）。
bool elevenLabsModelTakesLanguage(String model) =>
    !model.contains('multilingual_v2');

/// 合成请求体（纯函数，测试直接调）。
Map<String, Object?> elevenLabsSpeechRequest({
  required String text,
  required String model,
  String language = ElevenLabsTtsDescriptor.autoLanguage,
  int? seed,
}) => <String, Object?>{
  'text': text,
  'model_id': model,
  if (language.isNotEmpty &&
      language != ElevenLabsTtsDescriptor.autoLanguage &&
      elevenLabsModelTakesLanguage(model))
    'language_code': language,
  // 文档范围 0..4294967295。
  if (seed != null) 'seed': seed & 0xFFFFFFFF,
};

/// ElevenLabs 错误正文 → 失败码。新形状 `{detail: {type, code, status, ...}}` 认
/// `code`，旧形状只有 `detail.status`；都没有返回 null（按 HTTP 状态归一）。
/// - 额度 / 余额：`insufficient_credits`、`quota_exceeded`（旧形状配 401）、
///   `daily_generation_limit_reached`（429，但等几分钟没用）；
/// - 套餐不含：`subscription_required` / `feature_not_available`（如免费账户用声音库
///   声音、付费档才有的输出格式）也按额度类报——换 key 没用，要升级套餐。
TtsFailure? elevenLabsFailureFor(
  int status,
  Object? body,
  Duration? retryAfter,
) {
  final Object? detail = body is Map ? body['detail'] : null;
  if (detail is! Map) return null;
  final String code = '${detail['code'] ?? detail['status'] ?? ''}'.trim();
  return switch (code) {
    'insufficient_credits' ||
    'quota_exceeded' ||
    'daily_generation_limit_reached' ||
    'subscription_required' ||
    'feature_not_available' => TtsFailure(
      TtsFailureCode.quotaExceeded,
      'HTTP $status $code',
    ),
    'voice_not_found' || 'model_not_found' => TtsFailure(
      TtsFailureCode.rejected,
      'HTTP $status $code',
    ),
    _ => null,
  };
}

/// `GET /v1/models` → 能合成的模型（[TtsVoice.locale] 留空：一个模型多种语言）。
List<TtsVoice> parseElevenLabsModels(Object? raw) {
  if (raw is! List) return const <TtsVoice>[];
  return <TtsVoice>[
    for (final Object? m in raw)
      if (m is Map &&
          m['can_do_text_to_speech'] != false &&
          m['model_id'] is String &&
          (m['model_id'] as String).trim().isNotEmpty)
        TtsVoice(
          id: (m['model_id'] as String).trim(),
          displayName: m['name'] is String && (m['name'] as String).isNotEmpty
              ? (m['name'] as String).trim()
              : (m['model_id'] as String).trim(),
          locale: '',
        ),
  ];
}

/// `GET /v2/voices` → 声音。语言取第一条 `verified_languages` 的 locale / language，
/// 再退到 `labels.language`；性别取 `labels.gender`。
List<TtsVoice> parseElevenLabsVoices(Object? raw) {
  final Object? voices = raw is Map ? raw['voices'] : null;
  if (voices is! List) return const <TtsVoice>[];
  String str(Object? m, String key) =>
      m is Map && m[key] is String ? (m[key] as String).trim() : '';
  String localeOf(Map<Object?, Object?> v) {
    final Object? verified = v['verified_languages'];
    if (verified is List && verified.isNotEmpty) {
      final String locale = str(verified.first, 'locale');
      if (locale.isNotEmpty) return locale;
      final String language = str(verified.first, 'language');
      if (language.isNotEmpty) return language;
    }
    return str(v['labels'], 'language');
  }

  return <TtsVoice>[
    for (final Object? v in voices)
      if (v is Map && str(v, 'voice_id').isNotEmpty)
        TtsVoice(
          id: str(v, 'voice_id'),
          displayName: str(v, 'name').isEmpty
              ? str(v, 'voice_id')
              : str(v, 'name'),
          locale: localeOf(v),
          gender: str(v['labels'], 'gender').isEmpty
              ? null
              : str(v['labels'], 'gender'),
        ),
  ];
}
