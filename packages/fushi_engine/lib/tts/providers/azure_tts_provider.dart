/// 微软 Azure AI Speech 官方 REST TTS（用户自填订阅 key + 区域）。
///
/// 短音频 REST 接口不返回词边界（官方文档：边界事件只经 Speech SDK），本期只用句级；
/// 输出 24kHz 16bit PCM WAV。
///
/// 逐句语气：情绪用 SSML `mstts:express-as` 的 `style` + `styledegree`（只在这个声音
/// `voices/list` 的 `StyleList` 里有对应风格时发，否则折成语速 / 音高 / 音量），
/// 偏移用 `<prosody>`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart'
    show MicrosoftProsody, microsoftProsodyOf, parseMicrosoftVoiceList;
import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
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

class AzureTtsProvider extends TtsProvider implements TtsDirectedSynthesis {
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

  /// 本实例声音的风格表（一个实例只取一次；临时失败不记住）。
  Future<Set<String>>? _styles;

  /// 区域只允许 Azure 区域名的字符集，防止拼进主机名的串改写目标域。
  static final RegExp _regionPattern = RegExp(r'^[a-z0-9]+$');

  bool get _configured =>
      apiKey.trim().isNotEmpty && _regionPattern.hasMatch(region.trim());

  String get _host => '${region.trim()}.tts.speech.microsoft.com';

  @override
  TtsCapabilities get capabilities => const AzureTtsDescriptor().capabilities;

  /// 情绪原生表达（声音有对应风格时；没有就在 [azureTtsSsml] 里折成偏移），语速 /
  /// 音高 / 音量走 `<prosody>`。REST 接口不收自然语言指令，不声明 tone。
  @override
  TtsDirectionSupport get directionSupport => const TtsDirectionSupport(
    emotion: true,
    rate: true,
    pitch: true,
    volume: true,
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
    if (!_configured) throw const TtsFailure(TtsFailureCode.notConfigured);
    final Set<String> styles = direction.emotion == null
        ? const <String>{}
        : await (_styles ??= _fetchVoiceStyles());
    cancel.throwIfCancelled();
    final String ssml = azureTtsSsml(
      voice: voice,
      text: text,
      direction: direction,
      voiceStyles: styles,
    );
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

  /// 不挂某一句的取消令牌：多句并发共用这一次请求，一句被取消不该让别的句子失败。
  Future<Set<String>> _fetchVoiceStyles() async {
    try {
      return parseMicrosoftVoiceStyles(
        await ttsGetJson(
          client: _client,
          uri: Uri.https(_host, '/cognitiveservices/voices/list'),
          headers: <String, String>{'Ocp-Apim-Subscription-Key': apiKey.trim()},
        ),
        voice,
      );
    } on TtsFailure catch (f) {
      // 临时失败（网络 / 限流 / 5xx）不记住、交给重试层——否则一次断网整本书都按
      // 「没有风格」合成；其余（坏数据等）按没有风格折算，记住结果。
      if (f.isTransient) {
        _styles = null;
        rethrow;
      }
      return const <String>{};
    }
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

/// 各情绪按优先级可用的 Azure 风格（风格名与含义见
/// https://learn.microsoft.com/azure/ai-services/speech-service/speech-synthesis-markup-voice#use-speaking-styles-and-roles ）。
/// 惊讶、紧张没有含义贴合的风格（`excited` 是「期待好事」、`serious` 是「严厉」），
/// 不在表里，一律折成语速 / 音高 / 音量。
const Map<CastEmotion, List<String>> kAzureEmotionStyles =
    <CastEmotion, List<String>>{
      CastEmotion.joy: <String>['cheerful', 'excited', 'friendly'],
      CastEmotion.sadness: <String>['sad', 'depressed'],
      CastEmotion.anger: <String>['angry', 'disgruntled'],
      CastEmotion.fear: <String>['fearful', 'terrified'],
      CastEmotion.disgust: <String>['disgruntled', 'unfriendly'],
      CastEmotion.embarrassment: <String>['embarrassed'],
      CastEmotion.tenderness: <String>['affectionate', 'gentle', 'empathetic'],
    };

/// [emotion] 在这个声音上可用的风格（[voiceStyles] 里没有对应风格返回 null——风格
/// 名无效时整个 `express-as` 会被服务端忽略，所以不发声音没有的风格，改为折算）。
String? azureStyleFor(CastEmotion emotion, Set<String> voiceStyles) {
  for (final String style in kAzureEmotionStyles[emotion] ?? const <String>[]) {
    if (voiceStyles.contains(style)) return style;
  }
  return null;
}

/// 强度 0..100 → `styledegree`（文档范围 0.01..2，1 = 风格的预设强度）：中等 50
/// 对应 1，线性缩放、按 0.01 取整。不支持强度的声音服务端会忽略这个属性。
double azureStyleDegree(int intensity) =>
    ((intensity / 50).clamp(0.01, 2.0) * 100).round() / 100;

/// 一句的 SSML。没有演出字段时与历来发送的完全一致。情绪在 [voiceStyles] 里有
/// 对应风格时套 `mstts:express-as`，否则按 [ttsEmotionProsody] 折进语速 / 音高 /
/// 音量（与 [effectiveTtsDirection] 对不支持情绪的引擎的折算同一套）。
String azureTtsSsml({
  required String voice,
  required String text,
  required TtsDirection direction,
  required Set<String> voiceStyles,
}) {
  final String lang = voice.length >= 5 ? voice.substring(0, 5) : 'ja-JP';
  final CastEmotion? emotion = direction.emotion;
  final String? style = emotion == null
      ? null
      : azureStyleFor(emotion, voiceStyles);
  final TtsDirection prosodyDirection = style == null
      ? effectiveTtsDirection(
          const TtsDirectionSupport(rate: true, pitch: true, volume: true),
          direction,
        )
      : direction;
  final MicrosoftProsody? prosody = microsoftProsodyOf(prosodyDirection);
  if (style == null && prosody == null) {
    return "<speak version='1.0' xml:lang='${ttsEscapeXml(lang)}'>"
        "<voice name='${ttsEscapeXml(voice)}'>${ttsEscapeXml(text)}</voice>"
        '</speak>';
  }
  String body = ttsEscapeXml(text);
  if (prosody != null) {
    body =
        "<prosody rate='${prosody.rate}' pitch='${prosody.pitch}' "
        "volume='${prosody.volume}'>$body</prosody>";
  }
  if (style != null) {
    final double degree = azureStyleDegree(direction.effectiveIntensity);
    final String degreeAttr = degree == 1 ? '' : " styledegree='$degree'";
    body =
        "<mstts:express-as style='$style'$degreeAttr>$body</mstts:express-as>";
  }
  return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
      "xmlns:mstts='https://www.w3.org/2001/mstts' "
      "xml:lang='${ttsEscapeXml(lang)}'>"
      "<voice name='${ttsEscapeXml(voice)}'>$body</voice></speak>";
}

/// Azure `voices/list` 里 [voice]（`ShortName`）的 `StyleList`；没有这个声音或它没有
/// 风格返回空集。
Set<String> parseMicrosoftVoiceStyles(Object? raw, String voice) {
  if (raw is! List) return const <String>{};
  for (final Object? v in raw) {
    if (v is Map && v['ShortName'] == voice) {
      final Object? styles = v['StyleList'];
      return <String>{
        if (styles is List)
          for (final Object? s in styles)
            if (s is String && s.isNotEmpty) s,
      };
    }
  }
  return const <String>{};
}
