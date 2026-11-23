/// VOICEVOX 兼容 HTTP API 的引擎（VOICEVOX ENGINE / AivisSpeech Engine / SHAREVOX ……）：
/// - `GET  /speakers` → `[{name, speaker_uuid, styles: [{name, id, type?}]}]`；
/// - `POST /audio_query?text=&speaker=` → 合成参数 JSON（AudioQuery）；
/// - `POST /synthesis?speaker=`，请求体是（可能改过语速等字段的）AudioQuery → WAV。
///
/// 三家只是默认端口不同（各自独立 providerId，缓存键互不串）；LMROID、ITVOICE 等
/// 其它兼容引擎改地址即可。声音选的是「风格」：style id 才是 `speaker` 参数。
///
/// 逐句语气（[TtsDirectedSynthesis]）：在 `/audio_query` 拿回的 AudioQuery 上改
/// `speedScale` / `pitchScale` / `volumeScale` / `intonationScale` 再交给
/// `/synthesis`（换算见 [VoicevoxCompatibleTtsProvider.applyDirection]）。
/// - VOICEVOX / SHAREVOX：声明原生情绪——情绪自己译成「抑揚」（intonationScale）+
///   [ttsEmotionProsody] 的语速 / 音高 / 音量。只声明语速 / 音高 / 音量让框架折算会
///   丢掉抑揚这一维，而抑揚恰是这类引擎最能听出「高兴 / 低落」的旋钮。
/// - AivisSpeech：`intonationScale` 是「所选风格的感情强弱」、不是抑揚，`pitchScale`
///   偏离 0 会劣化音质（引擎文档原话），所以只声明语速 + 音量，情绪由框架折算。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
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

  /// 逐句语气能表达的字段（见库注释）。VOICEVOX ENGINE 语义（`pitchScale` 乘在
  /// log-F0 上、`intonationScale` 放大音高起伏）：情绪原生 + 语速 / 音高 / 音量。
  /// SHAREVOX 引擎由 VOICEVOX ENGINE 分叉，这几个字段语义相同。
  TtsDirectionSupport get directionSupport => const TtsDirectionSupport(
    emotion: true,
    rate: true,
    pitch: true,
    volume: true,
  );

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
        directionSupport: directionSupport,
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

  /// AivisSpeech Engine 的 AudioQuery（`voicevox_engine/model.py`）：
  /// `intonationScale` 是「選択した話者スタイルの感情表現の強弱」而非抑揚，`pitchScale`
  /// 「0.0 から変更すると音質が劣化する」。所以只调语速 / 音量，情绪由框架折算进这两项。
  @override
  TtsDirectionSupport get directionSupport =>
      const TtsDirectionSupport(rate: true, volume: true);
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

class VoicevoxCompatibleTtsProvider extends TtsProvider
    implements TtsDirectedSynthesis {
  VoicevoxCompatibleTtsProvider({
    required String endpoint,
    required this.speaker,
    required this.overrides,
    required this.capabilities,
    required this.directionSupport,
    required TtsHost host,
  }) : _base = voicevoxBaseUri(endpoint),
       _client = host.httpClientFactory();

  /// style id（字符串形态，合成前解析）。
  final String speaker;

  /// AudioQuery 字段名 → 用户填的数值文本（已去空白、非空）。
  final Map<String, String> overrides;

  @override
  final TtsCapabilities capabilities;

  @override
  final TtsDirectionSupport directionSupport;

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

  /// GUI 与 AivisSpeech 文档给的合法范围（VOICEVOX ENGINE 本身不校验，超出会失真）。
  static const double minSpeedScale = 0.5;
  static const double maxSpeedScale = 2.0;
  static const double minPitchScale = -0.15;
  static const double maxPitchScale = 0.15;
  static const double maxIntonationScale = 2.0;
  static const double maxVolumeScale = 2.0;

  /// 每种情绪在强度 100 时对 `intonationScale` 的倍率增量（按强度线性缩放）：高兴 /
  /// 生气 / 惊讶时起伏更大，悲伤 / 温柔 / 嫌恶时更平。只在声明了原生情绪时用。
  static const Map<CastEmotion, double> emotionIntonation =
      <CastEmotion, double>{
        CastEmotion.neutral: 0,
        CastEmotion.joy: 0.25,
        CastEmotion.sadness: -0.30,
        CastEmotion.anger: 0.30,
        CastEmotion.surprise: 0.40,
        CastEmotion.fear: 0.10,
        CastEmotion.disgust: -0.10,
        CastEmotion.embarrassment: 0.10,
        CastEmotion.tenderness: -0.15,
        CastEmotion.tension: 0.05,
      };

  /// 没有有声 mora 可量时假定的平均 ln(F0)（约 245 Hz）。没有有声 mora 时音高也
  /// 无从可调，这个值只防止除零。
  static const double _fallbackLogF0 = 5.5;

  /// 把逐句语气写进 AudioQuery（纯函数，测试直接调；[query] 已套过 [applyOverrides]，
  /// 预设里的倍率作为基准、这里乘 / 加在上面而非替换）。[direction] 为空原样返回。
  ///
  /// - 语速：`speedScale × (1 + rateOffset)`（引擎把每个音素时长除以 speedScale）。
  /// - 音量：`volumeScale × 10^(dB / 20)`（引擎按 volumeScale 线性缩放波形幅度）。
  /// - 音高：VOICEVOX ENGINE `tts_engine._apply_pitch_scale` 是
  ///   `mora.pitch *= 2 ** pitchScale`，而 mora.pitch 是 ln(F0)，所以 pitchScale 不是
  ///   「每半音固定若干」。升 s 个半音要让 ln(F0) 加 `s·ln2/12`：取这句有声 mora 的
  ///   平均 ln(F0) = L、原 pitchScale = p0，新值 `p = log2(2^p0 + s·ln2/12 / L)`
  ///   （对平均音高精确；女声 L≈5.5 时 1 半音 ≈ 0.015）。
  /// - 抑揚：`intonationScale × (1 + [emotionIntonation] × 强度/100)`。
  ///
  /// [direction] 带情绪（只有声明了原生情绪才会带）时，情绪除了抑揚，还按
  /// [ttsEmotionProsody] 叠进语速 / 音高 / 音量（同框架折算，夹到 [CastLineLimits]）。
  /// 结果都夹到引擎合法范围；预设本身已在范围外的，不被往回拉。
  static Map<String, Object?> applyDirection(
    Map<String, Object?> query,
    TtsDirection direction,
  ) {
    if (direction.isEmpty) return query;
    final CastEmotion? emotion = direction.emotion;
    final int intensity = direction.effectiveIntensity;
    final TtsProsodyOffsets folded = emotion == null
        ? (rate: 0, pitch: 0, volume: 0)
        : ttsEmotionProsody(emotion, intensity);
    double? total(double? given, double add, double lo, double hi) {
      if (given == null && add == 0) return null;
      final double v = ((given ?? 0) + add).clamp(lo, hi).toDouble();
      return v.abs() < 1e-9 ? null : v;
    }

    final double? rate = total(
      direction.rateOffset,
      folded.rate,
      CastLineLimits.minRateOffset,
      CastLineLimits.maxRateOffset,
    );
    final double? semitones = total(
      direction.pitchOffset,
      folded.pitch,
      -CastLineLimits.maxPitchSemitones,
      CastLineLimits.maxPitchSemitones,
    );
    final double? decibels = total(
      direction.volumeOffset,
      folded.volume,
      -CastLineLimits.maxVolumeDb,
      CastLineLimits.maxVolumeDb,
    );
    final double intonation = emotion == null
        ? 0
        : emotionIntonation[emotion]! *
              intensity.clamp(0, CastLineLimits.maxIntensity) /
              100;

    final Map<String, Object?> next = <String, Object?>{...query};
    double numberOf(String field, double fallback) => switch (next[field]) {
      final num v when v.isFinite => v.toDouble(),
      _ => fallback,
    };
    // 夹到 [lo, hi]，但范围向基准值放宽（用户自己设的越界值不被往回拉）。
    double within(double v, double base, double lo, double hi) =>
        v.clamp(math.min(lo, base), math.max(hi, base)).toDouble();

    if (rate != null) {
      final double base = numberOf('speedScale', 1);
      next['speedScale'] = _round(
        within(base * (1 + rate), base, minSpeedScale, maxSpeedScale),
      );
    }
    if (semitones != null) {
      final double logF0 =
          _meanVoicedLogF0(next['accent_phrases']) ?? _fallbackLogF0;
      final double base = numberOf('pitchScale', 0);
      final double factor =
          math.pow(2, base).toDouble() + semitones * math.ln2 / 12 / logF0;
      if (factor > 0) {
        next['pitchScale'] = _round(
          within(
            math.log(factor) / math.ln2,
            base,
            minPitchScale,
            maxPitchScale,
          ),
        );
      }
    }
    if (decibels != null) {
      final double base = numberOf('volumeScale', 1);
      next['volumeScale'] = _round(
        within(
          base * math.pow(10, decibels / 20).toDouble(),
          base,
          0,
          maxVolumeScale,
        ),
      );
    }
    if (intonation != 0) {
      final double base = numberOf('intonationScale', 1);
      next['intonationScale'] = _round(
        within(base * (1 + intonation), base, 0, maxIntonationScale),
      );
    }
    return next;
  }

  /// 去浮点噪声（引擎能分辨的精度远低于 1e-4）。
  static double _round(double v) => (v * 10000).round() / 10000;

  /// AudioQuery 里有声 mora（pitch > 0）的平均 ln(F0)；一个都没有返回 null。
  static double? _meanVoicedLogF0(Object? accentPhrases) {
    double sum = 0;
    int count = 0;
    if (accentPhrases is List) {
      for (final Object? phrase in accentPhrases) {
        if (phrase is! Map || phrase['moras'] is! List) continue;
        for (final Object? mora in phrase['moras'] as List) {
          if (mora is! Map) continue;
          final Object? pitch = mora['pitch'];
          if (pitch is num && pitch.isFinite && pitch > 0) {
            sum += pitch;
            count++;
          }
        }
      }
    }
    return count == 0 ? null : sum / count;
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
      body: utf8.encode(
        jsonEncode(applyDirection(applyOverrides(query, overrides), direction)),
      ),
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

/// VOICEVOX engine `StyleType` 里能走 `/audio_query` + `/synthesis` 的「talk 系」
/// 风格，与引擎 `metas_store._TALK_STYLE_TYPES` 同一集合。`streaming_talk` 是
/// 0.25+ 引擎给支持流式合成的风格报的类型（0.26 起默认角色全是它），同样能
/// 普通合成。歌唱（`singing_teacher` / `frame_decode` / `sing`）与哼唱
/// （`humming`）走的是另一套接口，选了也合成不出来。
const Set<String> voicevoxTalkStyleTypes = <String>{'talk', 'streaming_talk'};

/// `/speakers` → 「角色 / 风格」列表，id 是 style id。只收朗读用的风格：`type`
/// 缺省（旧引擎 / AivisSpeech）或属于 [voicevoxTalkStyleTypes]。
List<TtsVoice> parseVoicevoxSpeakers(Object? raw) => <TtsVoice>[
  if (raw is List)
    for (final Object? speaker in raw)
      if (speaker is Map && speaker['styles'] is List)
        for (final Object? style in speaker['styles'] as List)
          if (style is Map &&
              style['id'] is int &&
              (style['type'] == null ||
                  voicevoxTalkStyleTypes.contains(style['type'])))
            TtsVoice(
              id: '${style['id']}',
              displayName:
                  '${speaker['name'] ?? '?'} / ${style['name'] ?? style['id']}',
              locale: 'ja-JP',
            ),
];
