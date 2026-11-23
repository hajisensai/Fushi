/// 通用 OpenAI 兼容语音接口（本机 VPTTS、各类自建 `/v1/audio/speech` 服务）：
/// - `POST /v1/audio/speech` `{model, input, voice, response_format: wav}` → 音频；
/// - `GET  /v1/audio/voices` → `{data: [{id, name?}]}`（非 OpenAI 官方接口，自建服务
///   普遍提供；没有时声音只能手填）；
/// - `GET  /v1/models` → `{data: [{id}]}`：model 留空时服务只提供一个模型就用它
///   （VPTTS 只有 `voicepeak`，且不认别的名字），否则用 OpenAI 的 `tts-1`。
///
/// 服务端倍速默认 1.0（播放倍速由本地播放器控制），整句已由调用方切好。
///
/// 逐句语气（[TtsDirectedSynthesis]）：情绪 + 语气说明拼成日语指令放进 `instructions`，
/// 语速偏移换成 `speed`。两个字段都是 OpenAI 官方参数（`instructions` 只有
/// gpt-4o-mini-tts 系认，tts-1 / tts-1-hd 不认；`speed` 0.25..4.0，见
/// https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create ），
/// 但不少兼容服务遇到不认识的字段会报错，所以 `instructions` 由预设开关
/// [OpenAiCompatibleTtsDescriptor.deliveryInstructionsKey] 控制（默认开）；关掉后不声明
/// 情绪 / 语气，情绪按 [effectiveTtsDirection] 折进语速。没有语气的句子请求体与以前完全一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class OpenAiCompatibleTtsDescriptor extends TtsProviderDescriptor {
  const OpenAiCompatibleTtsDescriptor();

  static const String providerId = 'openai_compatible';
  static const String endpointKey = 'endpoint';
  static const String modelKey = 'model';
  static const String voiceKey = 'voice';
  static const String apiKeyKey = 'api_key';

  /// 是否把逐句语气作为 `instructions` 发送（[deliveryOn] / [deliveryOff]）。
  static const String deliveryInstructionsKey = 'delivery_instructions';
  static const String deliveryOn = 'on';
  static const String deliveryOff = 'off';

  /// VPTTS 的默认地址。
  static const String defaultEndpoint = 'http://127.0.0.1:8000';

  /// model 留空、服务又列出多个（或不提供 `/v1/models`）时用的名字。
  static const String fallbackModel = 'tts-1';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 自建服务多半按声音串行合成；多声优时每个声音各自一路。可在预设里调高。
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
    TtsParamSpec(key: modelKey, kind: TtsParamKind.text),
    TtsParamSpec(key: voiceKey, kind: TtsParamKind.voice, required: true),
    TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      affectsAudio: false,
    ),
    // 不进缓存键：开关只改变逐句语气里实际生效的字段，那部分已由
    // [TtsDirection.cacheIdentity] 计入；没有语气的句子不受影响。
    TtsParamSpec(
      key: deliveryInstructionsKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: deliveryOn,
      choices: <String>[deliveryOn, deliveryOff],
      affectsAudio: false,
    ),
  ];

  /// 声音 id 只在一台服务上有意义：端口进身份，换一台服务不复用另一台的缓存。
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
      OpenAiCompatibleTtsProvider(
        endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
        model: preset.param(modelKey),
        voice: preset.param(voiceKey),
        apiKey: preset.param(apiKeyKey),
        deliveryInstructions:
            preset.param(deliveryInstructionsKey, fallback: deliveryOn) !=
            deliveryOff,
        host: host,
      );
}

/// 用户填的地址 → 服务根（只留 scheme / host / port；填成 `/v1` 或完整接口地址也认）。
Uri? openAiCompatibleBaseUri(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
}

class OpenAiCompatibleTtsProvider extends TtsProvider
    implements TtsDirectedSynthesis {
  OpenAiCompatibleTtsProvider({
    required String endpoint,
    required String model,
    required this.voice,
    required this.apiKey,
    required TtsHost host,
    this.deliveryInstructions = true,
  }) : _model = model.trim(),
       _base = openAiCompatibleBaseUri(endpoint),
       _client = host.httpClientFactory();

  final String voice;
  final String apiKey;

  /// 发不发 `instructions`（预设开关）。
  final bool deliveryInstructions;
  final String _model;
  final Uri? _base;
  final HttpClient _client;

  /// model 留空时探到的名字（一个实例只探一次）。
  Future<String>? _resolvedModel;

  @override
  TtsCapabilities get capabilities =>
      const OpenAiCompatibleTtsDescriptor().capabilities;

  Map<String, String> get _auth => <String, String>{
    if (apiKey.trim().isNotEmpty)
      HttpHeaders.authorizationHeader: 'Bearer ${apiKey.trim()}',
  };

  Future<String> _modelFor(Uri base, TtsCancelToken cancel) {
    if (_model.isNotEmpty) return Future<String>.value(_model);
    return _resolvedModel ??= () async {
      try {
        return openAiCompatibleSoleModel(
              await ttsGetJson(
                client: _client,
                uri: base.replace(path: '/v1/models'),
                headers: _auth,
                cancel: cancel,
              ),
            ) ??
            OpenAiCompatibleTtsDescriptor.fallbackModel;
      } on TtsFailure catch (f) {
        // 取消 / 连不上：不记住结果，下次重新探（否则一次断网就永远用错模型名）。
        _resolvedModel = null;
        if (f.code == TtsFailureCode.cancelled ||
            f.code == TtsFailureCode.network ||
            f.code == TtsFailureCode.timeout) {
          rethrow;
        }
        // 服务没有 /v1/models（404 等）：按 OpenAI 默认名请求。
        return OpenAiCompatibleTtsDescriptor.fallbackModel;
      }
    }();
  }

  @override
  TtsDirectionSupport get directionSupport => TtsDirectionSupport(
    emotion: deliveryInstructions,
    tone: deliveryInstructions,
    rate: true,
  );

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
    final Uri? base = _base;
    if (base == null || voice.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final String model = await _modelFor(base, cancel);
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: base.replace(path: '/v1/audio/speech'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          openAiCompatibleSpeechRequest(
            text: text,
            voice: voice,
            model: model,
            direction: direction,
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
    return parseOpenAiCompatibleVoices(
      await ttsGetJson(
        client: _client,
        uri: base.replace(path: '/v1/audio/voices'),
        headers: _auth,
        cancel: cancel,
      ),
    );
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// `POST /v1/audio/speech` 的请求体（纯函数，测试直接调）。[direction] 为空时与
/// 以前完全一致；有情绪 / 语气说明时加 `instructions`（[ttsDeliveryInstruction]），
/// 有语速偏移时加 `speed` = `1 + rateOffset`（夹到官方范围 0.25..4.0，取两位小数）。
Map<String, Object?> openAiCompatibleSpeechRequest({
  required String text,
  required String voice,
  required String model,
  TtsDirection direction = TtsDirection.none,
}) {
  final String? instructions = ttsDeliveryInstruction(direction);
  final double? rate = direction.rateOffset;
  return <String, Object?>{
    'model': model,
    'input': text,
    'voice': voice.trim(),
    'response_format': 'wav',
    if (instructions != null) 'instructions': instructions,
    if (rate != null)
      'speed': ((1 + rate).clamp(0.25, 4.0) * 100).round() / 100,
  };
}

/// `/v1/models` 只列出一个模型时返回它的 id，否则 null。
String? openAiCompatibleSoleModel(Object? raw) {
  final Object? data = raw is Map ? raw['data'] : null;
  if (data is! List || data.length != 1) return null;
  final Object? only = data.single;
  final Object? id = only is Map ? only['id'] : null;
  return id is String && id.isNotEmpty ? id : null;
}

/// `{data: [{id, name?, language?}]}` → 声音列表；有 `name` 时显示「名字（id）」。
List<TtsVoice> parseOpenAiCompatibleVoices(Object? raw) {
  final Object? data = raw is Map ? raw['data'] : null;
  return <TtsVoice>[
    if (data is List)
      for (final Object? v in data)
        if (v is Map && v['id'] is String && (v['id'] as String).isNotEmpty)
          TtsVoice(
            id: v['id'] as String,
            displayName: v['name'] is String && (v['name'] as String).isNotEmpty
                ? '${v['name']}（${v['id']}）'
                : v['id'] as String,
            locale: v['language'] is String ? v['language'] as String : '',
          ),
  ];
}
