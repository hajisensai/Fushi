/// 微软 Azure AI Speech 官方 REST TTS（用户自填订阅 key + 区域）。
///
/// 短音频 REST 接口不返回词边界（官方文档：边界事件只经 Speech SDK），本期只用句级；
/// 输出 24kHz 16bit PCM WAV。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart'
    show parseMicrosoftVoiceList;
import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class AzureTtsDescriptor extends TtsProviderDescriptor {
  const AzureTtsDescriptor();

  static const String providerId = 'azure';
  static const String regionKey = 'region';
  static const String apiKeyKey = 'api_key';
  static const String voiceKey = 'voice';
  static const String defaultVoice = 'ja-JP-NanamiNeural';

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
      key: regionKey,
      kind: TtsParamKind.text,
      required: true,
      defaultValue: 'japaneast',
      affectsAudio: false,
    ),
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
  TtsProvider create(TtsVoicePreset preset, TtsHost host) => AzureTtsProvider(
    region: preset.param(regionKey, fallback: 'japaneast'),
    apiKey: preset.param(apiKeyKey),
    voice: preset.param(voiceKey, fallback: defaultVoice),
    host: host,
  );
}

class AzureTtsProvider extends TtsProvider {
  AzureTtsProvider({
    required this.region,
    required this.apiKey,
    required this.voice,
    required TtsHost host,
  }) : _client = host.httpClientFactory();

  final String region;
  final String apiKey;
  final String voice;
  final HttpClient _client;

  /// 区域只允许 Azure 区域名的字符集，防止拼进主机名的串改写目标域。
  static final RegExp _regionPattern = RegExp(r'^[a-z0-9]+$');

  bool get _configured =>
      apiKey.trim().isNotEmpty && _regionPattern.hasMatch(region.trim());

  String get _host => '${region.trim()}.tts.speech.microsoft.com';

  @override
  TtsCapabilities get capabilities => const AzureTtsDescriptor().capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    if (!_configured) throw const TtsFailure(TtsFailureCode.notConfigured);
    final String lang = voice.length >= 5 ? voice.substring(0, 5) : 'ja-JP';
    final String ssml =
        "<speak version='1.0' xml:lang='${ttsEscapeXml(lang)}'>"
        "<voice name='${ttsEscapeXml(voice)}'>${ttsEscapeXml(text)}</voice>"
        '</speak>';
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: Uri.https(_host, '/cognitiveservices/v1'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(ssml),
      headers: <String, String>{
        'Ocp-Apim-Subscription-Key': apiKey.trim(),
        HttpHeaders.contentTypeHeader: 'application/ssml+xml',
        'X-Microsoft-OutputFormat': 'riff-24khz-16bit-mono-pcm',
        HttpHeaders.userAgentHeader: 'Fushi',
      },
    );
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (!_configured) throw const TtsFailure(TtsFailureCode.notConfigured);
    final Object? raw = await ttsGetJson(
      client: _client,
      uri: Uri.https(_host, '/cognitiveservices/voices/list'),
      headers: <String, String>{'Ocp-Apim-Subscription-Key': apiKey.trim()},
      cancel: cancel,
    );
    return parseMicrosoftVoiceList(raw);
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}
