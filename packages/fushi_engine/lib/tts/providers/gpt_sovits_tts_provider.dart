/// GPT-SoVITS 官方 `api_v2.py` 的 `POST /tts`。
///
/// - 模型 / 权重由服务端预先加载，客户端不调全局切权重接口（会影响同一服务的其它用户）。
/// - `ref_audio_path` 是**服务端**路径，客户端不上传文件。
/// - 调用方已按句切好：`text_split_method=cut0`（不再切），非流式 WAV。整体播放倍速由
///   本地播放器控制，服务端 `speed_factor` 默认 1.0，只承载逐句语气的语速偏移。
/// - 逐句语气（[TtsDirectedSynthesis]）：api_v2 只有 `speed_factor` 一个能逐句调的
///   演出旋钮（音高 / 音量 / 情绪都没有请求参数），所以只声明语速；情绪由
///   [effectiveTtsDirection] 折成语速偏移。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class GptSovitsTtsDescriptor extends TtsProviderDescriptor {
  const GptSovitsTtsDescriptor();

  static const String providerId = 'gpt_sovits';

  static const String endpointKey = 'endpoint';
  static const String textLangKey = 'text_lang';
  static const String refAudioKey = 'ref_audio_path';
  static const String promptTextKey = 'prompt_text';
  static const String promptLangKey = 'prompt_lang';
  static const String apiKeyKey = 'api_key';

  /// api_v2 认的语言代码（v2 起）。
  static const List<String> languages = <String>[
    'ja', 'all_ja', 'zh', 'all_zh', 'en', 'ko', 'all_ko', 'yue', 'all_yue', //
    'auto', 'auto_yue',
  ];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 实测 api_v2 并发 2 路吞吐比串行高约 15%（RTX 4070 Ti，v5 Turbo），且一句长句
    // 不再挡住后面的短句；更高并发收益很小、显存压力大。
    maxConcurrency: 2,
    maxInputLength: 120,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(
      key: endpointKey,
      kind: TtsParamKind.url,
      required: true,
      defaultValue: 'http://127.0.0.1:9880',
      affectsAudio: false,
    ),
    TtsParamSpec(
      key: textLangKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: 'ja',
      choices: languages,
    ),
    TtsParamSpec(key: refAudioKey, kind: TtsParamKind.text, required: true),
    // v3 起（含 v5 Turbo）参考音频必须配参考文本，空着服务端直接 400。
    TtsParamSpec(key: promptTextKey, kind: TtsParamKind.text, required: true),
    TtsParamSpec(
      key: promptLangKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: 'ja',
      choices: languages,
    ),
    TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      affectsAudio: false,
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      GptSovitsTtsProvider(
        endpoint: preset.param(endpointKey, fallback: params[0].defaultValue),
        textLang: preset.param(textLangKey, fallback: 'ja'),
        refAudioPath: preset.param(refAudioKey),
        promptText: preset.param(promptTextKey),
        promptLang: preset.param(promptLangKey, fallback: 'ja'),
        apiKey: preset.param(apiKeyKey),
        host: host,
      );
}

class GptSovitsTtsProvider extends TtsProvider implements TtsDirectedSynthesis {
  GptSovitsTtsProvider({
    required String endpoint,
    required this.textLang,
    required this.refAudioPath,
    required this.promptText,
    required this.promptLang,
    required this.apiKey,
    required TtsHost host,
  }) : _uri = ttsEndpointUri(endpoint),
       _client = host.httpClientFactory();

  final String textLang;
  final String refAudioPath;
  final String promptText;
  final String promptLang;
  final String apiKey;
  final Uri? _uri;
  final HttpClient _client;

  /// 用户可以填根地址或完整 `/tts` 地址。
  static Uri? ttsEndpointUri(String raw) {
    final Uri? base = Uri.tryParse(raw.trim());
    if (base == null || base.host.isEmpty) return null;
    String path = base.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.endsWith('/tts')) path = '$path/tts';
    // Uri.replace(query: null) 保留原 query，无法清空，只能重建。
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
    );
  }

  @override
  TtsCapabilities get capabilities =>
      const GptSovitsTtsDescriptor().capabilities;

  /// 只有语速（`speed_factor`）能逐句调，见库注释。
  static const TtsDirectionSupport support = TtsDirectionSupport(rate: true);

  @override
  TtsDirectionSupport get directionSupport => support;

  /// 逐句语速偏移 → api_v2 的 `speed_factor`：`1 + rateOffset`，取两位小数（与
  /// [TtsDirection.cacheIdentity] 的精度一致），夹到 `CastLineLimits` 语速范围对应的 0.5..2.0。
  /// 没有语速偏移时就是原来的 1.0。
  static double speedFactorOf(TtsDirection direction) {
    final double? rate = direction.rateOffset;
    if (rate == null) return 1.0;
    final double factor = (1 + rate).clamp(0.5, 2.0).toDouble();
    return (factor * 100).round() / 100;
  }

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
    final Uri? uri = _uri;
    if (uri == null || refAudioPath.trim().isEmpty) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final List<int> body = utf8.encode(
      jsonEncode(<String, Object?>{
        'text': text,
        'text_lang': textLang,
        'ref_audio_path': refAudioPath.trim(),
        'prompt_text': promptText,
        'prompt_lang': promptLang,
        'media_type': 'wav',
        'streaming_mode': false,
        'text_split_method': 'cut0',
        'batch_size': 1,
        'speed_factor': speedFactorOf(direction),
      }),
    );
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: uri,
      outputPath: outputPath,
      cancel: cancel,
      body: body,
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'audio/wav',
        if (apiKey.trim().isNotEmpty)
          HttpHeaders.authorizationHeader: 'Bearer ${apiKey.trim()}',
      },
    );
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}
