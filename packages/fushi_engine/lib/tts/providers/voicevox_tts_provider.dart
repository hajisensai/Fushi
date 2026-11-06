/// VOICEVOX 兼容 HTTP API 的引擎（VOICEVOX ENGINE / AivisSpeech Engine / SHAREVOX ……）：
/// - `GET  /speakers` → `[{name, speaker_uuid, styles: [{name, id, type?}]}]`；
/// - `POST /audio_query?text=&speaker=` → 合成参数 JSON（AudioQuery）；
/// - `POST /synthesis?speaker=`，请求体是（可能改过语速等字段的）AudioQuery → WAV。
///
/// 三家只是默认端口不同（各自独立 providerId，缓存键互不串）；LMROID、ITVOICE 等
/// 其它兼容引擎改地址即可。声音选的是「风格」：style id 才是 `speaker` 参数。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 三个 VOICEVOX 兼容引擎共用的描述符：参数表、校验、缓存键、实例构造都一样，
/// 派生类只给 id 与默认地址。
abstract class VoicevoxCompatibleTtsDescriptor extends TtsProviderDescriptor {
  const VoicevoxCompatibleTtsDescriptor();

  static const String endpointKey = 'endpoint';
  static const String speakerKey = 'speaker';
  static const String speedScaleKey = 'speed_scale';
  static const String pitchScaleKey = 'pitch_scale';
  static const String intonationScaleKey = 'intonation_scale';
  static const String volumeScaleKey = 'volume_scale';

  /// 可选覆盖参数 → AudioQuery 里的同名字段。空 = 用引擎（与所选风格）的默认值。
  static const Map<String, String> scaleFields = <String, String>{
    speedScaleKey: 'speedScale',
    pitchScaleKey: 'pitchScale',
    intonationScaleKey: 'intonationScale',
    volumeScaleKey: 'volumeScale',
  };

  /// 引擎默认地址（`http://127.0.0.1:<默认端口>`）。
  String get defaultEndpoint;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 引擎内部串行推理；并发 2 让下一句的 audio_query 与本句合成重叠，不再更高。
    maxConcurrency: 2,
    maxInputLength: 200,
  );

  @override
  List<TtsParamSpec> get params => <TtsParamSpec>[
    TtsParamSpec(
      key: endpointKey,
      kind: TtsParamKind.url,
      required: true,
      defaultValue: defaultEndpoint,
      affectsAudio: false,
    ),
    const TtsParamSpec(
      key: speakerKey,
      kind: TtsParamKind.voice,
      required: true,
    ),
    for (final String key in scaleFields.keys)
      TtsParamSpec(key: key, kind: TtsParamKind.text),
  ];

  @override
  List<String> validate(TtsVoicePreset preset) {
    final List<String> problems = super.validate(preset);
    final String speaker = preset.param(speakerKey).trim();
    if (speaker.isNotEmpty &&
        int.tryParse(speaker) == null &&
        !problems.contains(speakerKey)) {
      problems.add(speakerKey);
    }
    for (final String key in scaleFields.keys) {
      final String raw = preset.param(key).trim();
      if (raw.isEmpty) continue;
      final double? value = double.tryParse(raw);
      if (value == null || !value.isFinite) problems.add(key);
    }
    return problems;
  }

  /// 同一个 style id 在不同兼容引擎上是不同的声音：用户把地址改到别的引擎（端口
  /// 不同）时不能复用缓存。只记端口不记主机（换局域网 IP 不失效）。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) {
    final Uri? uri = Uri.tryParse(
      preset.param(endpointKey, fallback: defaultEndpoint).trim(),
    );
    return <String, Object?>{
      ...super.audioIdentity(preset),
      'port': uri == null || uri.host.isEmpty ? 0 : uri.port,
    };
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      VoicevoxCompatibleTtsProvider(
        endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
        speaker: preset.param(speakerKey),
        overrides: <String, String>{
          for (final MapEntry<String, String> e in scaleFields.entries)
            if (preset.param(e.key).trim().isNotEmpty)
              e.value: preset.param(e.key).trim(),
        },
        capabilities: capabilities,
        host: host,
      );
}

class VoicevoxTtsDescriptor extends VoicevoxCompatibleTtsDescriptor {
  const VoicevoxTtsDescriptor();

  static const String providerId = 'voicevox';
  static const String defaultUrl = 'http://127.0.0.1:50021';

  @override
  String get id => providerId;

  @override
  String get defaultEndpoint => defaultUrl;
}

class AivisSpeechTtsDescriptor extends VoicevoxCompatibleTtsDescriptor {
  const AivisSpeechTtsDescriptor();

  static const String providerId = 'aivis_speech';
  static const String defaultUrl = 'http://127.0.0.1:10101';

  @override
  String get id => providerId;

  @override
  String get defaultEndpoint => defaultUrl;
}

class SharevoxTtsDescriptor extends VoicevoxCompatibleTtsDescriptor {
  const SharevoxTtsDescriptor();

  static const String providerId = 'sharevox';
  static const String defaultUrl = 'http://127.0.0.1:50025';

  @override
  String get id => providerId;

  @override
  String get defaultEndpoint => defaultUrl;
}

class VoicevoxCompatibleTtsProvider extends TtsProvider {
  VoicevoxCompatibleTtsProvider({
    required String endpoint,
    required this.speaker,
    required this.overrides,
    required this.capabilities,
    required TtsHost host,
  }) : _base = voicevoxBaseUri(endpoint),
       _client = host.httpClientFactory();

  /// style id（字符串形态，合成前解析）。
  final String speaker;

  /// AudioQuery 字段名 → 用户填的数值文本（已去空白、非空）。
  final Map<String, String> overrides;

  @override
  final TtsCapabilities capabilities;

  final Uri? _base;
  final HttpClient _client;

  /// 根地址（可带子路径，便于放在反向代理后面）；去掉末尾斜杠、query 与 fragment。
  static Uri? voicevoxBaseUri(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (!(uri.isScheme('http') || uri.isScheme('https'))) return null;
    String path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  Uri _at(Uri base, String path, [Map<String, String>? query]) => Uri(
    scheme: base.scheme,
    userInfo: base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '${base.path}$path',
    queryParameters: query,
  );

  /// 把 [overrides] 写进 AudioQuery（纯函数，测试直接调）。数值解析不了的跳过
  /// （描述符的校验已经拦过一道）。
  static Map<String, Object?> applyOverrides(
    Map<String, Object?> query,
    Map<String, String> overrides,
  ) {
    final Map<String, Object?> next = <String, Object?>{...query};
    overrides.forEach((String field, String raw) {
      final double? value = double.tryParse(raw);
      if (value != null && value.isFinite) next[field] = value;
    });
    return next;
  }

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final Uri? base = _base;
    final int? style = int.tryParse(speaker.trim());
    if (base == null || style == null) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final Object? query = await ttsPostJson(
      client: _client,
      uri: _at(base, '/audio_query', <String, String>{
        'text': text,
        'speaker': '$style',
      }),
      body: null,
      sendBody: false,
      cancel: cancel,
      headers: const <String, String>{
        HttpHeaders.acceptHeader: 'application/json',
      },
    );
    if (query is! Map<String, Object?>) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'audio_query');
    }
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: _at(base, '/synthesis', <String, String>{'speaker': '$style'}),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(jsonEncode(applyOverrides(query, overrides))),
      headers: const <String, String>{
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
      uri: _at(base, '/speakers'),
      cancel: cancel,
    );
    return parseVoicevoxSpeakers(raw);
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// `/speakers` → 「角色 / 风格」列表，id 是 style id。只收朗读用的风格：`type`
/// 缺省（旧引擎 / AivisSpeech）或 `talk`；歌唱（`sing` / `frame_decode`）与哼唱
/// （`humming`）走的是另一套接口，选了也合成不出来。
List<TtsVoice> parseVoicevoxSpeakers(Object? raw) => <TtsVoice>[
  if (raw is List)
    for (final Object? speaker in raw)
      if (speaker is Map && speaker['styles'] is List)
        for (final Object? style in speaker['styles'] as List)
          if (style is Map &&
              style['id'] is int &&
              (style['type'] == null || style['type'] == 'talk'))
            TtsVoice(
              id: '${style['id']}',
              displayName:
                  '${speaker['name'] ?? '?'} / ${style['name'] ?? style['id']}',
              locale: 'ja-JP',
            ),
];
