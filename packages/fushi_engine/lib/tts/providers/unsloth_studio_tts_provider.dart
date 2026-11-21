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
/// 缓存键要看得到请求体里的每一项：模型必须明确选（「用 Studio 当前载入的」是服务端
/// 状态，换了模型缓存键不变就会拿旧模型的音频）；声音的文字稿 / 参考语言在设置页选
/// 声音时快照进预设（[UnslothStudioTtsDescriptor.paramsForPickedOption]），合成只用
/// 快照、不再按次去问 Studio。Studio 里改了声音，在设置页重选一次即可。
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

  /// 选声音时快照的参考文字稿 / 参考语言（不在 [params] 里，界面不显示；进缓存键）。
  static const String voiceTranscriptKey = 'voice_transcript';
  static const String voiceLanguageKey = 'voice_language';

  /// [TtsVoice.attributes] 里放文字稿的键。
  static const String transcriptAttribute = 'transcript';

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
    // 必选：模型进缓存键，也决定发不发 CosyVoice 模板。
    TtsParamSpec(key: modelKey, kind: TtsParamKind.voice, required: true),
    TtsParamSpec(key: voiceKey, kind: TtsParamKind.voice, required: true),
    TtsParamSpec(
      key: languageKey,
      kind: TtsParamKind.choice,
      defaultValue: autoLanguage,
      choices: languages,
    ),
  ];

  /// 选了声音却没有文字稿 / 参考语言快照（不是经设置页选的）：声音算没配好，
  /// 让用户在设置页重选一次。
  @override
  List<String> validate(TtsVoicePreset preset) {
    final List<String> problems = super.validate(preset);
    if (!problems.contains(voiceKey) && voiceSnapshotOf(preset) == null) {
      problems.add(voiceKey);
    }
    return problems;
  }

  /// 声音 id 只在一台 Studio 上有意义：地址进身份，换一台不复用另一台的缓存。
  /// 文字稿与参考语言决定请求体（`reference_text` / 模板 / 纯汉字句的语言），也进身份。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) {
    final Uri? uri = Uri.tryParse(
      preset.param(endpointKey, fallback: defaultEndpoint).trim(),
    );
    return <String, Object?>{
      ...super.audioIdentity(preset),
      'host': uri?.host ?? '',
      'port': uri?.port ?? 0,
      voiceTranscriptKey: preset.param(voiceTranscriptKey).trim(),
      voiceLanguageKey: preset.param(voiceLanguageKey).trim(),
    };
  }

  @override
  Map<String, String?> paramsForPickedOption(
    String paramKey,
    TtsVoice? option,
  ) => paramKey != voiceKey
      ? const <String, String?>{}
      : <String, String?>{
          voiceTranscriptKey: option == null
              ? null
              : (option.attributes[transcriptAttribute] ?? '').trim(),
          voiceLanguageKey: option?.locale.trim(),
        };

  /// 预设里的声音快照；缺任一项返回 null（文字稿 / 参考语言本身可以是空串）。
  static ({String transcript, String language})? voiceSnapshotOf(
    TtsVoicePreset preset,
  ) {
    final String? transcript = preset.params[voiceTranscriptKey];
    final String? language = preset.params[voiceLanguageKey];
    if (transcript == null || language == null) return null;
    return (transcript: transcript.trim(), language: language.trim());
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) {
    final ({String transcript, String language})? snapshot = voiceSnapshotOf(
      preset,
    );
    return UnslothStudioTtsProvider(
      endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
      apiKey: preset.param(apiKeyKey),
      model: preset.param(modelKey),
      voice: preset.param(voiceKey),
      voiceTranscript: snapshot?.transcript,
      voiceLanguage: snapshot?.language,
      language: preset.param(languageKey, fallback: autoLanguage),
      host: host,
    );
  }
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
    required String? voiceTranscript,
    required String? voiceLanguage,
    required String language,
    required TtsHost host,
  }) : _apiKey = apiKey.trim(),
       _model = model.trim(),
       _voice = voice.trim(),
       _voiceTranscript = voiceTranscript?.trim(),
       _voiceLanguage = voiceLanguage?.trim(),
       _language = language.trim(),
       _base = unslothBaseUri(endpoint),
       _client = host.httpClientFactory();

  final String _apiKey;
  final String _model;
  final String _voice;

  /// 选声音时快照的文字稿 / 参考语言；null = 没快照（预设不是经设置页选的声音）。
  final String? _voiceTranscript;
  final String? _voiceLanguage;
  final String _language;
  final Uri? _base;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const UnslothStudioTtsDescriptor().capabilities;

  Map<String, String> get _auth => <String, String>{
    if (_apiKey.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
  };

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final Uri? base = _base;
    final String? transcript = _voiceTranscript;
    final String? voiceLanguage = _voiceLanguage;
    if (base == null ||
        _model.isEmpty ||
        _voice.isEmpty ||
        transcript == null ||
        voiceLanguage == null) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    // Studio 里删掉了这个声音时服务端回 404 / 422，ttsSendToFile 报 rejected。
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
            voice: (
              id: _voice,
              name: _voice,
              transcript: transcript,
              language: voiceLanguage,
            ),
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
      for (final UnslothVoice v in parseUnslothVoices(
        await ttsGetJson(
          client: _client,
          uri: base.replace(path: '/v1/audio/voices'),
          headers: _auth,
          cancel: cancel,
        ),
      ))
        TtsVoice(
          id: v.id,
          displayName: v.name,
          locale: v.language,
          attributes: <String, String>{
            UnslothStudioTtsDescriptor.transcriptAttribute: v.transcript,
          },
        ),
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

/// 只有日语用的字符：平假名 / 片假名的字母与叠字符号、片假名音标扩展、半角片假名、
/// 「々」。不含中文里也常见的「・」（U+30FB）「ー」（U+30FC / U+FF70）与单独的浊点。
final RegExp _kJapaneseOnly = RegExp(
  '[々ぁ-ゖゝ-ゟァ-ヺヽ-ヿ'
  'ㇰ-ㇿｦ-ｯｱ-ﾝ]',
);
final RegExp _kHan = RegExp('[㐀-䶿一-鿿豈-﫿]');

/// 中文句子常见、日语文本里几乎不出现的字（简繁体的虚词、代词、语气词）。只收
/// 日语复合词里也不用的：「的」「了」「個」「給」「還」等日语也常用，不收。
final RegExp _kChineseOnly = RegExp('[们們这這吗嗎呢吧啊么麼没沒说說个给让还你她很什怎哪喔呀嘛哦啦咱裡]');

/// 声音参考语言的主语言码（`ja-JP` → `ja`）。
String _unslothLanguageBase(String tag) =>
    tag.trim().split(RegExp('[-_]')).first.toLowerCase();

/// 一句话的文本语言：
/// - 有日语专用字符（假名等）→ ja；
/// - 有汉字、没有假名：有中文专用字 → zh；否则中日都可能（「東京駅。」），声音的
///   参考语言是 ja 就按 ja，否则 zh；
/// - 没有汉字 → 参考语言是 es 就按 es，否则 en（西班牙语从文字上与英语分不可靠）。
/// 要固定一种语言就在预设里选。
String unslothDetectLanguage(String text, {String voiceLanguage = ''}) {
  if (_kJapaneseOnly.hasMatch(text)) return 'ja';
  final String ref = _unslothLanguageBase(voiceLanguage);
  if (_kHan.hasMatch(text)) {
    if (_kChineseOnly.hasMatch(text)) return 'zh';
    return ref == 'ja' ? 'ja' : 'zh';
  }
  return ref == 'es' ? 'es' : 'en';
}

/// 文本语言与声音的参考语言相同 → `zero_shot`，否则 `cross_lingual`。参考语言
/// 不明时按跨语言处理（选错 zero_shot 会把参考文字稿读进句首，跨语言只是音色稍远）。
String unslothTemplateFor({
  required String textLanguage,
  required String voiceLanguage,
}) {
  final String ref = _unslothLanguageBase(voiceLanguage);
  return ref.isNotEmpty && ref == textLanguage ? 'zero_shot' : 'cross_lingual';
}

/// 合成模板是 CosyVoice 的概念：别的模型（Qwen3-TTS、Breeze 等）不发。
bool unslothUsesTemplates(String model) =>
    model.toLowerCase().contains('cosyvoice');

/// `POST /v1/audio/speech` 的请求体（纯函数，测试直接调）。
Map<String, Object?> unslothSpeechRequest({
  required String text,
  required UnslothVoice voice,
  required String model,
  required String language,
}) {
  final String textLanguage =
      language.isEmpty || language == UnslothStudioTtsDescriptor.autoLanguage
      ? unslothDetectLanguage(text, voiceLanguage: voice.language)
      : language;
  return <String, Object?>{
    'model': model,
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
