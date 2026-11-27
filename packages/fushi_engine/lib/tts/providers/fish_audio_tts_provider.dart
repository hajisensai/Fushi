/// Fish Audio 官方 REST TTS（用户自填 API key）：
/// - `POST https://api.fish.audio/v1/tts`，`Authorization: Bearer <key>`，请求头
///   `model` 选模型，JSON 体 `{text, reference_id, format, mp3_bitrate, latency,
///   prosody: {speed, volume}}` → 音频字节；
/// - `GET https://api.fish.audio/model?self=true` → 自己工作区的声音；不带 `self` 是
///   公共声音库（按热度取前一页，其余靠手填 id，见 [TtsParamSpec.allowsCustomValue]）。
///
/// 免费与付费是**同一个接口**，区别只在模型与账户余额：`s2.1-pro-free` 与 `s2.1-pro`
/// 是同一个模型，前者 0 元、按服务方的合理使用限制限流；余额为 0 时调付费模型回
/// 402（[TtsFailureCode.quotaExceeded]），并发超限回 429（无 `Retry-After`，按默认退避）。
/// 接口文档：https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech
///
/// 逐句语气：语速（`prosody.speed`，倍率 0.5–2）与音量（`prosody.volume`，dB）原生；
/// 情绪由 [effectiveTtsDirection] 折成这两项。音高接口不收。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class FishAudioTtsDescriptor extends TtsProviderDescriptor {
  const FishAudioTtsDescriptor();

  static const String providerId = 'fish_audio';
  static const String apiKeyKey = 'api_key';
  static const String modelKey = 'model';
  static const String voiceKey = 'voice';

  /// 付费主力模型（服务端默认值）。
  static const String defaultModel = 's2.1-pro';

  /// 免费模型（与 [defaultModel] 同一个模型，0 元、合理使用限流）。
  static const String freeModel = 's2.1-pro-free';

  /// 请求头 `model` 的取值（2026-11 文档枚举；`s1` 2026-12-31 退役，服务端届时改用
  /// s2.1-pro；没写进文档定价页的 `s3-pro` 不列）。
  static const List<String> models = <String>[
    defaultModel,
    freeModel,
    's2-pro',
    'drama-3',
    's1',
  ];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: true,
    // 最低一档（Starter）并发 5；免费模型的合理使用额度没公开，默认保守 2 路。
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
      key: modelKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: defaultModel,
      choices: models,
    ),
    // 自己的声音 + 公共库热门一页；公共库里别的声音从网页复制 id 手填。
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      allowsCustomValue: true,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      FishAudioTtsProvider(
        apiKey: preset.param(apiKeyKey),
        model: preset.param(modelKey, fallback: defaultModel),
        voice: preset.param(voiceKey),
        host: host,
      );
}

class FishAudioTtsProvider extends TtsProvider implements TtsDirectedSynthesis {
  FishAudioTtsProvider({
    required String apiKey,
    required String model,
    required String voice,
    required TtsHost host,
    Uri? apiBase,
  }) : _apiKey = apiKey.trim(),
       _model = model.trim(),
       _voice = voice.trim(),
       _base = apiBase ?? kFishAudioApiBase,
       _client = host.httpClientFactory();

  final String _apiKey;
  final String _model;
  final String _voice;
  final Uri _base;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const FishAudioTtsDescriptor().capabilities;

  @override
  TtsDirectionSupport get directionSupport =>
      const TtsDirectionSupport(rate: true, volume: true);

  Map<String, String> get _auth => <String, String>{
    HttpHeaders.authorizationHeader: 'Bearer $_apiKey',
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
      uri: _base.replace(path: '/v1/tts'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          fishAudioSpeechRequest(
            text: text,
            voice: _voice,
            direction: direction,
          ),
        ),
      ),
      headers: <String, String>{
        ..._auth,
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        'model': _model.isEmpty ? FishAudioTtsDescriptor.defaultModel : _model,
      },
    );
    return const TtsResult(format: TtsAudioFormat.mp3);
  }

  /// 自己工作区的声音在前，再接公共库按热度排的一页（同一个 id 只留一份）。
  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (_apiKey.isEmpty) throw const TtsFailure(TtsFailureCode.notConfigured);
    Future<List<TtsVoice>> page(Map<String, String> query) async =>
        parseFishAudioVoices(
          await ttsGetJson(
            client: _client,
            uri: _base.replace(path: '/model', queryParameters: query),
            headers: _auth,
            cancel: cancel,
          ),
        );
    final List<TtsVoice> own = await page(<String, String>{
      'self': 'true',
      'page_size': '$kFishAudioVoicePageSize',
      'sort_by': 'created_at',
    });
    final List<TtsVoice> library = await page(<String, String>{
      'page_size': '$kFishAudioVoicePageSize',
      'sort_by': 'task_count',
    });
    final Set<String> seen = <String>{};
    return <TtsVoice>[
      for (final TtsVoice v in <TtsVoice>[...own, ...library])
        if (seen.add(v.id)) v,
    ];
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// 官方接口根（测试换成本机假服务）。
final Uri kFishAudioApiBase = Uri.https('api.fish.audio');

/// 列声音每页条数（接口上限 100）。
const int kFishAudioVoicePageSize = 100;

/// `prosody.speed` 的合法范围（文档：倍率 0.5–2.0）。
const double kFishAudioMinSpeed = 0.5;
const double kFishAudioMaxSpeed = 2.0;

/// `POST /v1/tts` 的请求体（纯函数，测试直接调）。没有语气偏移时不带 `prosody`，
/// 用服务端默认（倍速 1、音量 0 dB、S2 系列自动响度归一）。
Map<String, Object?> fishAudioSpeechRequest({
  required String text,
  required String voice,
  TtsDirection direction = TtsDirection.none,
}) {
  final double? rate = direction.rateOffset;
  final double? volume = direction.volumeOffset;
  double round2(double v) => (v * 100).roundToDouble() / 100;
  return <String, Object?>{
    'text': text,
    'reference_id': voice,
    'format': 'mp3',
    'mp3_bitrate': 128,
    'latency': 'normal',
    if (rate != null || volume != null)
      'prosody': <String, Object?>{
        if (rate != null)
          'speed': round2(
            math.min(
              kFishAudioMaxSpeed,
              math.max(kFishAudioMinSpeed, 1 + rate),
            ),
          ),
        if (volume != null) 'volume': round2(volume),
      },
  };
}

/// `GET /model` → 声音（只收能合成的 `tts` 型、已训练好的条目；缺 id 跳过）。
/// [TtsVoice.locale] 取声音的第一种语言。
List<TtsVoice> parseFishAudioVoices(Object? raw) {
  final Object? items = raw is Map ? raw['items'] : null;
  if (items is! List) return const <TtsVoice>[];
  String str(Map<Object?, Object?> m, String key) =>
      m[key] is String ? (m[key] as String).trim() : '';
  return <TtsVoice>[
    for (final Object? item in items)
      if (item is Map &&
          str(item, '_id').isNotEmpty &&
          (str(item, 'type').isEmpty || str(item, 'type') == 'tts') &&
          (str(item, 'state').isEmpty || str(item, 'state') == 'trained'))
        TtsVoice(
          id: str(item, '_id'),
          displayName: str(item, 'title').isEmpty
              ? str(item, '_id')
              : str(item, 'title'),
          locale: switch (item['languages']) {
            final List<Object?> langs
                when langs.isNotEmpty && langs.first is String =>
              (langs.first as String).trim(),
            _ => '',
          },
        ),
  ];
}
