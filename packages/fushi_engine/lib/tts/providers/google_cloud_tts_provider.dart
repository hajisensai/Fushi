/// Google Cloud Text-to-Speech 官方 REST（用户自填 API key）。
///
/// `LINEAR16` 编码的 `audioContent` 自带 WAV 头。本期只用句级时间；词级需 v1beta1 +
/// SSML `<mark>`（Chirp3 HD 不支持 mark），留给后续。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class GoogleCloudTtsDescriptor extends TtsProviderDescriptor {
  const GoogleCloudTtsDescriptor();

  static const String providerId = 'google_cloud';
  static const String apiKeyKey = 'api_key';
  static const String voiceKey = 'voice';
  static const String defaultVoice = 'ja-JP-Neural2-B';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: true,
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
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      defaultValue: defaultVoice,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      GoogleCloudTtsProvider(
        apiKey: preset.param(apiKeyKey),
        voice: preset.param(voiceKey, fallback: defaultVoice),
        host: host,
      );
}

class GoogleCloudTtsProvider extends TtsProvider {
  GoogleCloudTtsProvider({
    required this.apiKey,
    required this.voice,
    required TtsHost host,
  }) : _client = host.httpClientFactory();

  final String apiKey;
  final String voice;
  final HttpClient _client;

  static const String _host = 'texttospeech.googleapis.com';

  @override
  TtsCapabilities get capabilities =>
      const GoogleCloudTtsDescriptor().capabilities;

  /// 声音名形如 `ja-JP-Neural2-B`：前两段是语言代码。
  static String languageOf(String voice) {
    final List<String> parts = voice.split('-');
    return parts.length >= 2 ? '${parts[0]}-${parts[1]}' : 'ja-JP';
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final Object? raw = await ttsPostJson(
      client: _client,
      uri: Uri.https(_host, '/v1/text:synthesize'),
      headers: <String, String>{'X-Goog-Api-Key': apiKey.trim()},
      cancel: cancel,
      body: <String, Object?>{
        'input': <String, Object?>{'text': text},
        'voice': <String, Object?>{
          'languageCode': languageOf(voice),
          'name': voice,
        },
        'audioConfig': <String, Object?>{
          'audioEncoding': 'LINEAR16',
          'sampleRateHertz': 24000,
        },
      },
    );
    final Object? content = raw is Map ? raw['audioContent'] : null;
    if (content is! String || content.isEmpty) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'no audioContent');
    }
    try {
      await File(outputPath).writeAsBytes(base64Decode(content), flush: true);
    } on FormatException {
      throw const TtsFailure(TtsFailureCode.badResponse, 'base64');
    }
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (apiKey.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final Object? raw = await ttsGetJson(
      client: _client,
      uri: Uri.https(_host, '/v1/voices'),
      headers: <String, String>{'X-Goog-Api-Key': apiKey.trim()},
      cancel: cancel,
    );
    final Object? voices = raw is Map ? raw['voices'] : null;
    return <TtsVoice>[
      if (voices is List)
        for (final Object? v in voices)
          if (v is Map && v['name'] is String)
            TtsVoice(
              id: v['name'] as String,
              displayName: v['name'] as String,
              locale: languageOf(v['name'] as String),
              gender: v['ssmlGender'] is String
                  ? v['ssmlGender'] as String
                  : null,
            ),
    ];
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}
