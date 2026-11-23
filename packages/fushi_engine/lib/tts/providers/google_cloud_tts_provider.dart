/// Google Cloud Text-to-Speech 官方 REST（用户自填 API key）。
///
/// `LINEAR16` 编码的 `audioContent` 自带 WAV 头。本期只用句级时间；词级需 v1beta1 +
/// SSML `<mark>`（Chirp3 HD 不支持 mark），留给后续。
///
/// 逐句语气：REST 没有情绪 / 风格参数，只用 `audioConfig` 的 `speakingRate` /
/// `pitch` / `volumeGainDb`（情绪由 [effectiveTtsDirection] 折成这三项）。取值范围见
/// https://cloud.google.com/text-to-speech/docs/reference/rest/v1/AudioConfig 。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
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

class GoogleCloudTtsProvider extends TtsProvider
    implements TtsDirectedSynthesis {
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
  TtsDirectionSupport get directionSupport =>
      googleCloudDirectionSupport(voice);

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
    if (apiKey.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final Object? raw = await ttsPostJson(
      client: _client,
      uri: Uri.https(_host, '/v1/text:synthesize'),
      headers: <String, String>{'X-Goog-Api-Key': apiKey.trim()},
      cancel: cancel,
      body: googleCloudSynthesizeRequest(
        text: text,
        voice: voice,
        direction: direction,
      ),
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

/// 声音族（名字第三段起，如 `Neural2` / `Wavenet` / `Chirp3-HD`）能逐句调的项。
/// 语速对所有声音都有文档（Chirp 3 HD 的 pace control 用同一个 `speakingRate`）；
/// 音高 / 音量只对经典的 Standard / WaveNet / Neural2 声音声明——Chirp / Journey /
/// Studio 等新声音的文档没写支持音高与音量，不猜。
TtsDirectionSupport googleCloudDirectionSupport(String voice) {
  final List<String> parts = voice.split('-');
  final String family = parts.length >= 3 ? parts[2].toLowerCase() : '';
  final bool classic =
      family == 'standard' || family == 'wavenet' || family == 'neural2';
  return TtsDirectionSupport(rate: true, pitch: classic, volume: classic);
}

/// `text:synthesize` 的请求体（纯函数，测试直接调）。没有偏移时与历来发送的一致；
/// 有偏移时（文档的合法范围）：
/// - `speakingRate` = `1 + rateOffset`，夹到 0.25..2.0（越界服务端报错）；
/// - `pitch` 直接是半音，夹到 -20..20；
/// - `volumeGainDb` 直接是 dB，夹到 -96..10（文档允许到 +16，但强烈建议不超过 +10，
///   再大响度也不会增加）。
Map<String, Object?> googleCloudSynthesizeRequest({
  required String text,
  required String voice,
  required TtsDirection direction,
}) {
  final double? rate = direction.rateOffset;
  final double? pitch = direction.pitchOffset;
  final double? volume = direction.volumeOffset;
  double round2(num v) => (v * 100).round() / 100;
  return <String, Object?>{
    'input': <String, Object?>{'text': text},
    'voice': <String, Object?>{
      'languageCode': GoogleCloudTtsProvider.languageOf(voice),
      'name': voice,
    },
    'audioConfig': <String, Object?>{
      'audioEncoding': 'LINEAR16',
      'sampleRateHertz': 24000,
      if (rate != null) 'speakingRate': round2((1 + rate).clamp(0.25, 2.0)),
      if (pitch != null) 'pitch': round2(pitch.clamp(-20.0, 20.0)),
      if (volume != null) 'volumeGainDb': round2(volume.clamp(-96.0, 10.0)),
    },
  };
}
