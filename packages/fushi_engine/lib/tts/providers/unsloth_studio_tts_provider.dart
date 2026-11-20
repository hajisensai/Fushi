/// 本机 Unsloth Studio 的语音合成（声音克隆）：
/// - `GET  /v1/models` → `{data: [{id, task, loaded}]}`：只列 `task == text-to-speech`；
/// - `GET  /v1/audio/voices` → `{voices: [{id, name, transcript, language}]}`：
///   Studio 里存好的克隆声音（参考音频 + 文字稿 + 参考语言）；
/// - `POST /v1/audio/speech`：`{model, input, language, reference: {voice_id},
///   reference_text, response_format: wav, audio_options: {template_name}}` → WAV。
///
/// 只填 OpenAI 那几个字段（`voice`）时 CosyVoice 不知道文本语言、也不用参考文字稿，
/// 中文句子会读成乱码（2026-11-19 实测）。所以每句按文字判语言，再按「文本语言 ==
/// 参考语言」选 `zero_shot`，否则 `cross_lingual`（选反了参考文字稿会混进句首）。
///
/// 服务端倍速恒 1.0（播放倍速由本地播放器控制），整句已由调用方切好。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class UnslothStudioTtsDescriptor extends TtsProviderDescriptor {
  const UnslothStudioTtsDescriptor();

  static const String providerId = 'unsloth_studio';
  static const String endpointKey = 'endpoint';
  static const String apiKeyKey = 'api_key';
  static const String modelKey = 'model';
  static const String voiceKey = 'voice';
  static const String languageKey = 'language';

  /// Studio 默认地址。
  static const String defaultEndpoint = 'http://127.0.0.1:8888';

  /// 「按每句文字自动判断」。
  static const String autoLanguage = 'auto';

  /// CosyVoice3 认的文本语言。
  static const List<String> languages = <String>[
    autoLanguage,
    'zh',
    'ja',
    'en',
    'es',
  ];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    // Studio 的接口全部要 Bearer key（Settings → API 里建）。
    needsCredential: true,
    // 一张显卡一路；Studio 的 parallel_slots 也是 1。
    maxConcurrency: 1,
    maxInputLength: 200,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: endpointKey,
      kind: TtsParamKind.url,
      required: true,
      defaultValue: defaultEndpoint,
      affectsAudio: false,
    ),
    TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      required: true,
      affectsAudio: false,
    ),
    // 选择列表从服务拉（[TtsProvider.listParamOptions]），所以用 voice 形态。
    // 不选 = Studio 当前载入的模型。
    TtsParamSpec(key: modelKey, kind: TtsParamKind.voice),
    TtsParamSpec(key: voiceKey, kind: TtsParamKind.voice, required: true),
    TtsParamSpec(
      key: languageKey,
      kind: TtsParamKind.choice,
      defaultValue: autoLanguage,
      choices: languages,
    ),
  ];

  /// 声音 id 只在一台 Studio 上有意义：地址进身份，换一台不复用另一台的缓存。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) {
    final Uri? uri = Uri.tryParse(
      preset.param(endpointKey, fallback: defaultEndpoint).trim(),
    );
    return <String, Object?>{
      ...super.audioIdentity(preset),
      'host': uri?.host ?? '',
      'port': uri?.port ?? 0,
    };
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      UnslothStudioTtsProvider(
        endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
        apiKey: preset.param(apiKeyKey),
        model: preset.param(modelKey),
        voice: preset.param(voiceKey),
        language: preset.param(languageKey, fallback: autoLanguage),
        host: host,
      );
}

/// Studio 存的一个克隆声音（合成时要它的文字稿与参考语言）。
typedef UnslothVoice = ({
  String id,
  String name,
  String transcript,
  String language,
});

/// 用户填的地址 → 服务根（只留 scheme / host / port；填成 `/v1` 也认）。
Uri? unslothBaseUri(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
}

class UnslothStudioTtsProvider extends TtsProvider {
  UnslothStudioTtsProvider({
    required String endpoint,
    required String apiKey,
    required String model,
    required String voice,
    required String language,
    required TtsHost host,
  }) : _apiKey = apiKey.trim(),
       _model = model.trim(),
       _voice = voice.trim(),
       _language = language.trim(),
       _base = unslothBaseUri(endpoint),
       _client = host.httpClientFactory();

  final String _apiKey;
  final String _model;
  final String _voice;
  final String _language;
  final Uri? _base;
  final HttpClient _client;

  /// 选中声音的文字稿 / 参考语言（一个实例只取一次）。
  Future<UnslothVoice>? _voiceInfo;

  @override
  TtsCapabilities get capabilities =>
      const UnslothStudioTtsDescriptor().capabilities;

  Map<String, String> get _auth => <String, String>{
    if (_apiKey.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
  };

  Future<List<UnslothVoice>> _fetchVoices(
    Uri base,
    TtsCancelToken? cancel,
  ) async => parseUnslothVoices(
    await ttsGetJson(
      client: _client,
      uri: base.replace(path: '/v1/audio/voices'),
      headers: _auth,
      cancel: cancel,
    ),
  );

  Future<UnslothVoice> _voiceFor(Uri base, TtsCancelToken cancel) =>
      _voiceInfo ??= () async {
        try {
          for (final UnslothVoice v in await _fetchVoices(base, cancel)) {
            if (v.id == _voice) return v;
          }
          // Studio 里删掉了这个声音：与服务端 404 / 422 同一个结论。
          throw const TtsFailure(TtsFailureCode.rejected, 'voice missing');
        } on TtsFailure {
          // 不记住失败（断网、Studio 还没开、刚在 Studio 里重建了声音）。
          _voiceInfo = null;
          rethrow;
        }
      }();

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final Uri? base = _base;
    if (base == null || _voice.isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final UnslothVoice voice = await _voiceFor(base, cancel);
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: base.replace(path: '/v1/audio/speech'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          unslothSpeechRequest(
            text: text,
            voice: voice,
            model: _model,
            language: _language,
          ),
        ),
      ),
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'audio/wav',
        ..._auth,
      },
    );
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    final Uri? base = _base;
    if (base == null) throw const TtsFailure(TtsFailureCode.notConfigured);
    return <TtsVoice>[
      for (final UnslothVoice v in await _fetchVoices(base, cancel))
        TtsVoice(id: v.id, displayName: v.name, locale: v.language),
    ];
  }

  @override
  Future<List<TtsVoice>> listParamOptions(
    String paramKey, {
    TtsCancelToken? cancel,
  }) async {
    if (paramKey != UnslothStudioTtsDescriptor.modelKey) {
      return listVoices(cancel: cancel);
    }
    final Uri? base = _base;
    if (base == null) throw const TtsFailure(TtsFailureCode.notConfigured);
    return <TtsVoice>[
      for (final String id in parseUnslothTtsModels(
        await ttsGetJson(
          client: _client,
          uri: base.replace(path: '/v1/models'),
          headers: _auth,
          cancel: cancel,
        ),
      ))
        TtsVoice(id: id, displayName: id, locale: ''),
    ];
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// `/v1/models` → 语音合成模型 id（已载入的排前面，其余保持服务端顺序）。
List<String> parseUnslothTtsModels(Object? raw) {
  final Object? data = raw is Map ? raw['data'] : null;
  if (data is! List) return const <String>[];
  final List<Map<Object?, Object?>> tts = <Map<Object?, Object?>>[
    for (final Object? m in data)
      if (m is Map &&
          m['task'] == 'text-to-speech' &&
          m['id'] is String &&
          (m['id'] as String).isNotEmpty)
        m,
  ];
  return <String>[
    for (final Map<Object?, Object?> m in tts)
      if (m['loaded'] == true) m['id'] as String,
    for (final Map<Object?, Object?> m in tts)
      if (m['loaded'] != true) m['id'] as String,
  ];
}

/// `/v1/audio/voices` → 声音列表（缺 id 的条目跳过；没名字时用 id）。
List<UnslothVoice> parseUnslothVoices(Object? raw) {
  final Object? voices = raw is Map ? raw['voices'] : null;
  if (voices is! List) return const <UnslothVoice>[];
  String str(Map<Object?, Object?> m, String key) =>
      m[key] is String ? (m[key] as String).trim() : '';
  return <UnslothVoice>[
    for (final Object? v in voices)
      if (v is Map && str(v, 'id').isNotEmpty)
        (
          id: str(v, 'id'),
          name: str(v, 'name').isEmpty ? str(v, 'id') : str(v, 'name'),
          transcript: str(v, 'transcript'),
          language: str(v, 'language'),
        ),
  ];
}

final RegExp _kKana = RegExp(r'[぀-ヿㇰ-ㇿｦ-ﾟ]');
final RegExp _kHan = RegExp(r'[㐀-䶿一-鿿豈-﫿]');

/// 一句话的文本语言：有假名 → ja；有汉字没假名 → zh；否则 en。
/// （西班牙语从文字上与英语分不可靠，要读西语就在预设里固定选 es。）
String unslothDetectLanguage(String text) {
  if (_kKana.hasMatch(text)) return 'ja';
  if (_kHan.hasMatch(text)) return 'zh';
  return 'en';
}

/// 文本语言与声音的参考语言相同 → `zero_shot`，否则 `cross_lingual`。参考语言
/// 不明时按跨语言处理（选错 zero_shot 会把参考文字稿读进句首，跨语言只是音色稍远）。
String unslothTemplateFor({
  required String textLanguage,
  required String voiceLanguage,
}) {
  final String ref = voiceLanguage.split(RegExp('[-_]')).first.toLowerCase();
  return ref.isNotEmpty && ref == textLanguage ? 'zero_shot' : 'cross_lingual';
}

/// 合成模板是 CosyVoice 的概念：明确选了别的模型（Qwen3-TTS 等）就不发；
/// 不选模型时用 Studio 当前载入的模型，按 CosyVoice 发（Studio 对不认的模板不报错）。
bool unslothUsesTemplates(String model) =>
    model.isEmpty || model.toLowerCase().contains('cosyvoice');

/// `POST /v1/audio/speech` 的请求体（纯函数，测试直接调）。
Map<String, Object?> unslothSpeechRequest({
  required String text,
  required UnslothVoice voice,
  required String model,
  required String language,
}) {
  final String textLanguage =
      language.isEmpty || language == UnslothStudioTtsDescriptor.autoLanguage
      ? unslothDetectLanguage(text)
      : language;
  return <String, Object?>{
    if (model.isNotEmpty) 'model': model,
    'input': text,
    'language': textLanguage,
    'reference': <String, Object?>{'voice_id': voice.id},
    if (voice.transcript.isNotEmpty) 'reference_text': voice.transcript,
    'response_format': 'wav',
    if (unslothUsesTemplates(model))
      'audio_options': <String, Object?>{
        'template_name': unslothTemplateFor(
          textLanguage: textLanguage,
          voiceLanguage: voice.language,
        ),
      },
  };
}
