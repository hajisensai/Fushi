/// Irodori 有声书工作台（本机 `launch_studios.py` 起的 FastAPI，Irodori-TTS 默认
/// `:7870`，GPT-SoVITS 工作台 `:7871`）的快速朗读接口：
/// - `GET  /api/quick/voices` → `{items: [{id, name, trained, language}]}`；
/// - `POST /api/quick/speech` `{text, voice}` → WAV。
///
/// 声音（素材库条目 / 训练好的数据集）由工作台管理，客户端只选 id。工作台有整书任务
/// 在跑时返回 409（[TtsFailureCode.busy]）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class IrodoriTtsDescriptor extends TtsProviderDescriptor {
  const IrodoriTtsDescriptor();

  static const String providerId = 'irodori';
  static const String endpointKey = 'endpoint';
  static const String voiceKey = 'voice';
  static const String defaultEndpoint = 'http://127.0.0.1:7870';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
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
    TtsParamSpec(key: voiceKey, kind: TtsParamKind.voice, required: true),
  ];

  /// 同一个声音 id 在两个工作台（Irodori / GPT-SoVITS 端口）上是两种引擎：端口进身份，
  /// 免得换端口后复用另一个引擎合成的缓存。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) {
    final Uri? uri = Uri.tryParse(
      preset.param(endpointKey, fallback: defaultEndpoint).trim(),
    );
    return <String, Object?>{
      ...super.audioIdentity(preset),
      'port': uri?.port ?? 0,
    };
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) => IrodoriTtsProvider(
    endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
    voice: preset.param(voiceKey),
    host: host,
  );
}

class IrodoriTtsProvider extends TtsProvider {
  IrodoriTtsProvider({
    required String endpoint,
    required this.voice,
    required TtsHost host,
  }) : _base = _baseUri(endpoint),
       _client = host.httpClientFactory();

  final String voice;
  final Uri? _base;
  final HttpClient _client;

  static Uri? _baseUri(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return null;
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
  }

  @override
  TtsCapabilities get capabilities => const IrodoriTtsDescriptor().capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final Uri? base = _base;
    if (base == null || voice.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: base.replace(path: '/api/quick/speech'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(<String, Object?>{'text': text, 'voice': voice.trim()}),
      ),
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'audio/wav',
      },
    );
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    final Uri? base = _base;
    if (base == null) throw const TtsFailure(TtsFailureCode.notConfigured);
    final Object? raw = await ttsGetJson(
      client: _client,
      uri: base.replace(path: '/api/quick/voices'),
      cancel: cancel,
    );
    return parseIrodoriVoiceList(raw);
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// `{items: [{id, name, trained, language}]}` → 声音列表（训练过的在前，工作台已排好）。
List<TtsVoice> parseIrodoriVoiceList(Object? raw) {
  final Object? items = raw is Map ? raw['items'] : null;
  return <TtsVoice>[
    if (items is List)
      for (final Object? v in items)
        if (v is Map && v['id'] is String)
          TtsVoice(
            id: v['id'] as String,
            displayName: (v['name'] ?? v['id']).toString(),
            locale: v['language'] is String ? v['language'] as String : 'ja',
            gender: v['trained'] == true ? 'trained' : null,
          ),
  ];
}
