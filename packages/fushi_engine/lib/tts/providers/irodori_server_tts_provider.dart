/// 官方 Irodori-TTS-Server（`Aratako/Irodori-TTS-Server`，OpenAI 兼容）的朗读接口：
/// - `GET  /v1/audio/voices` → `{data: [{id, ref_wav, ..., no_ref}]}`；
/// - `POST /v1/audio/speech` `{model, input, voice, response_format, irodori}` → 音频；
/// - `POST /v1/audio/voices`（multipart `file` + `voice_id`）上传参考音频建声音，
///   `DELETE /v1/audio/voices/{id}` 删除上传过的声音（[IrodoriServerVoiceApi]）。
///
/// 逐句语气（[TtsDirectedSynthesis]）：情绪 + 语气说明拼进 `irodori.caption`，标注的
/// 语速偏移走顶层 `speed`（见 [irodoriServerSpeechRequest]）。
///
/// 与 [IrodoriTtsDescriptor]（所有者自己的有声书工作台，`/api/quick/*`、端口 7870）是
/// 两个引擎：接口、端口、声音来源都不同，两者并存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

class IrodoriServerTtsDescriptor extends TtsProviderDescriptor {
  const IrodoriServerTtsDescriptor();

  static const String providerId = 'irodori_server';
  static const String endpointKey = 'endpoint';
  static const String voiceKey = 'voice';
  static const String captionKey = 'caption';
  static const String apiKeyKey = 'api_key';

  /// 官方默认端口（`IRODORI_PORT`）。
  static const String defaultEndpoint = 'http://127.0.0.1:8088';

  /// 不用参考音频的内置声音（`IRODORI_ALLOW_NO_REF_VOICE`，官方默认开）：配合
  /// [captionKey] 就是 Voice Design。
  static const String noReferenceVoice = 'none';

  /// 请求里的 `model`（`IRODORI_MODEL_NAME` 默认值；服务端不认别的名字）。
  static const String modelName = 'irodori-tts';

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 官方默认 IRODORI_MAX_CONCURRENT_SYNTHESIS=1：多发也只是在服务端排队。
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
    TtsParamSpec(
      key: voiceKey,
      kind: TtsParamKind.voice,
      required: true,
      defaultValue: noReferenceVoice,
    ),
    TtsParamSpec(key: captionKey, kind: TtsParamKind.text),
    TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      affectsAudio: false,
    ),
  ];

  /// 声音 id 只在一台服务上有意义：端口进身份（与工作台引擎同一做法），换端口后
  /// 不复用另一台服务合成的缓存。
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
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      IrodoriServerTtsProvider(
        endpoint: preset.param(endpointKey, fallback: defaultEndpoint),
        voice: preset.param(voiceKey, fallback: noReferenceVoice),
        caption: preset.param(captionKey),
        apiKey: preset.param(apiKeyKey),
        host: host,
      );
}

/// 用户填的地址 → 服务根（只留 scheme / host / port；填成 `/v1` 或完整接口地址也认）。
Uri? irodoriServerBaseUri(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
}

Map<String, String> _authHeaders(String apiKey) => <String, String>{
  if (apiKey.trim().isNotEmpty)
    HttpHeaders.authorizationHeader: 'Bearer ${apiKey.trim()}',
};

/// 官方服务能逐句表达的演出字段（纯函数，测试直接调）：
/// - 情绪 + 语气说明：`irodori.caption`（Voice Design 描述）。上游 v4 系列（服务端
///   钉的 v4.1-Small / -MF、v4-Large）的 caption 与参考音频可以同时用，模型卡原话
///   「use the caption to guide emotion, style, or environment while keeping the base
///   voice characteristics aligned with the reference audio」；不带 caption 条件的旧
///   checkpoint 由运行时忽略 caption（`inference_runtime.py` 的 `has_caption_text`）。
/// - 语速：顶层 `speed`（OpenAI 字段，服务端 `SpeechRequest.speed`，0.25..4.0，按
///   `duration_scale / speed` 缩放预测时长，即真实的语速）。
/// - 音高 / 音量：接口没有，不声明（也就不会把情绪折成这两项）。
/// - 种子：接口有 `irodori.seed`，但这个引擎此前不收种子，声明它会让已有缓存全部
///   作废，不在这次范围内。
const TtsDirectionSupport kIrodoriServerDirectionSupport = TtsDirectionSupport(
  emotion: true,
  tone: true,
  rate: true,
);

class IrodoriServerTtsProvider extends TtsProvider
    implements TtsDirectedSynthesis {
  IrodoriServerTtsProvider({
    required String endpoint,
    required this.voice,
    required this.caption,
    required this.apiKey,
    required TtsHost host,
  }) : _base = irodoriServerBaseUri(endpoint),
       _client = host.httpClientFactory();

  final String voice;
  final String caption;
  final String apiKey;
  final Uri? _base;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const IrodoriServerTtsDescriptor().capabilities;

  @override
  TtsDirectionSupport get directionSupport => kIrodoriServerDirectionSupport;

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
    await ttsSendToFile(
      client: _client,
      method: 'POST',
      uri: base.replace(path: '/v1/audio/speech'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          irodoriServerSpeechRequest(
            text: text,
            voice: voice,
            caption: caption,
            direction: direction,
          ),
        ),
      ),
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.acceptHeader: 'audio/wav',
        ..._authHeaders(apiKey),
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
      uri: base.replace(path: '/v1/audio/voices'),
      headers: _authHeaders(apiKey),
      cancel: cancel,
    );
    return <TtsVoice>[
      for (final IrodoriServerVoice v in parseIrodoriServerVoices(raw))
        TtsVoice(id: v.id, displayName: v.id, locale: 'ja'),
    ];
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}

/// `POST /v1/audio/speech` 的请求体（纯函数，测试直接调）。整句已由调用方切好，服务端
/// 的长文本分块照默认；播放倍速由本地播放器控制。
///
/// [direction]（已按 [kIrodoriServerDirectionSupport] 过滤）：
/// - 情绪 / 语气说明 → [ttsDeliveryInstruction] 接在预设 caption 后面
///   （[irodoriCaptionWithDelivery]）；
/// - 语速偏移 → `speed = 1 + rateOffset`（夹到服务端的 0.25..4.0）。
/// 没有演出参数时请求体与以前逐字节相同（不发 `speed`，caption 只是预设的）。
Map<String, Object?> irodoriServerSpeechRequest({
  required String text,
  required String voice,
  String caption = '',
  TtsDirection direction = TtsDirection.none,
}) {
  final String fullCaption = irodoriCaptionWithDelivery(
    caption,
    ttsDeliveryInstruction(direction),
  );
  final double? speed = irodoriServerSpeed(direction.rateOffset);
  return <String, Object?>{
    'model': IrodoriServerTtsDescriptor.modelName,
    'input': text,
    'voice': voice.trim(),
    'response_format': 'wav',
    if (speed != null) 'speed': speed,
    if (fullCaption.isNotEmpty)
      'irodori': <String, Object?>{'caption': fullCaption},
  };
}

/// 服务端 `speed` 的合法范围（`SpeechRequest.speed: Field(ge=0.25, le=4.0)`）。
const double kIrodoriServerMinSpeed = 0.25;
const double kIrodoriServerMaxSpeed = 4.0;

/// 语速偏移（倍率增量）→ 服务端 `speed`（倍率，保留三位小数）；没给 / 为 0 返回 null
/// （不发这个字段，服务端按 1.0）。
double? irodoriServerSpeed(double? rateOffset) {
  if (rateOffset == null || rateOffset.abs() < 1e-9) return null;
  final double speed = (1 + rateOffset)
      .clamp(kIrodoriServerMinSpeed, kIrodoriServerMaxSpeed)
      .toDouble();
  return (speed * 1000).round() / 1000;
}

/// 预设 caption（声音设定）后面接上这一句的演技指令（[ttsDeliveryInstruction]）。
/// 指令为空返回去掉首尾空白的 caption；caption 为空只用指令；caption 没以句末标点
/// 结尾时补一个「。」再接，免得两段粘成一句。声音包批处理与官方服务共用。
String irodoriCaptionWithDelivery(String caption, String? instruction) {
  final String base = caption.trim();
  final String extra = instruction?.trim() ?? '';
  if (extra.isEmpty) return base;
  if (base.isEmpty) return extra;
  final bool closed = RegExp(r'[。．.！!？?」』）)]$').hasMatch(base);
  return closed ? '$base$extra' : '$base。$extra';
}

/// 服务上的一个声音。
class IrodoriServerVoice {
  const IrodoriServerVoice({required this.id, required this.noReference});

  final String id;

  /// 内置的 `none`（不用参考音频）：不能删。
  final bool noReference;
}

/// `{data: [{id, no_ref, ...}]}` → 声音列表（服务端已按 id 排好）。
List<IrodoriServerVoice> parseIrodoriServerVoices(Object? raw) {
  final Object? data = raw is Map ? raw['data'] : null;
  return <IrodoriServerVoice>[
    if (data is List)
      for (final Object? v in data)
        if (v is Map && v['id'] is String && (v['id'] as String).isNotEmpty)
          IrodoriServerVoice(
            id: v['id'] as String,
            noReference: v['no_ref'] == true,
          ),
  ];
}

/// 服务端认的声音 id：ASCII 字母数字、`_`、`-`（`VOICE_ID_PATTERN`）。
final RegExp kIrodoriVoiceIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// 服务端认的参考音频扩展名（`VOICE_EXTENSIONS` 里的音频部分）。
const Set<String> kIrodoriVoiceAudioExtensions = <String>{
  'wav',
  'flac',
  'mp3',
  'm4a',
  'ogg',
  'opus',
  'aac',
  'webm',
};

/// 参考音频上传上限：官方单个声音最多用 120 秒参考，WAV 也不到 30 MB。
const int kIrodoriVoiceUploadMaxBytes = 64 * 1024 * 1024;

/// 上传声音失败的原因（UI 翻译）。
enum IrodoriVoiceUploadFailure {
  /// 声音 id 不合法 / 扩展名不认 / 文件为空或太大。
  invalid,

  /// 同名声音已存在（服务端 409）。
  exists,

  /// 连不上 / 超时。
  network,

  /// 服务端拒绝（400 等，原因见 [IrodoriVoiceUploadException.detail]）。
  rejected,
}

class IrodoriVoiceUploadException implements Exception {
  const IrodoriVoiceUploadException(this.failure, [this.detail]);

  final IrodoriVoiceUploadFailure failure;
  final String? detail;

  @override
  String toString() => 'IrodoriVoiceUploadException(${failure.name}, $detail)';
}

/// 官方服务的声音管理（上传参考音频 / 删除）。地址与凭据同朗读预设。
class IrodoriServerVoiceApi {
  IrodoriServerVoiceApi({
    required String endpoint,
    required HttpClient Function() httpClientFactory,
    this.apiKey = '',
  }) : _base = irodoriServerBaseUri(endpoint),
       _httpClientFactory = httpClientFactory;

  final Uri? _base;
  final HttpClient Function() _httpClientFactory;
  final String apiKey;

  Future<List<IrodoriServerVoice>> list() async {
    final Uri? base = _base;
    if (base == null) throw const TtsFailure(TtsFailureCode.notConfigured);
    final HttpClient client = _httpClientFactory();
    try {
      return parseIrodoriServerVoices(
        await ttsGetJson(
          client: client,
          uri: base.replace(path: '/v1/audio/voices'),
          headers: _authHeaders(apiKey),
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 把 [file] 上传成声音 [voiceId]（服务端存进 `IRODORI_VOICES_DIR`）。返回声音 id。
  Future<String> upload({required File file, required String voiceId}) async {
    final Uri? base = _base;
    final String id = voiceId.trim();
    final String name = file.uri.pathSegments.isEmpty
        ? ''
        : file.uri.pathSegments.last;
    final String ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    if (base == null ||
        !kIrodoriVoiceIdPattern.hasMatch(id) ||
        !kIrodoriVoiceAudioExtensions.contains(ext)) {
      throw const IrodoriVoiceUploadException(
        IrodoriVoiceUploadFailure.invalid,
      );
    }
    final List<int> bytes;
    try {
      final int length = await file.length();
      if (length == 0 || length > kIrodoriVoiceUploadMaxBytes) {
        throw IrodoriVoiceUploadException(
          IrodoriVoiceUploadFailure.invalid,
          'size $length',
        );
      }
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw IrodoriVoiceUploadException(
        IrodoriVoiceUploadFailure.invalid,
        e.message,
      );
    }
    final ({String contentType, List<int> body}) form = irodoriVoiceUploadForm(
      voiceId: id,
      // 服务端只看扩展名，原文件名里的非 ASCII 字符不必带过去。
      fileName: '$id.$ext',
      bytes: bytes,
    );
    final HttpClient client = _httpClientFactory();
    try {
      final HttpClientRequest req = await client
          .postUrl(base.replace(path: '/v1/audio/voices'))
          .timeout(const Duration(seconds: 30));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.contentTypeHeader, form.contentType);
      _authHeaders(apiKey).forEach(req.headers.set);
      req.contentLength = form.body.length;
      req.add(form.body);
      final HttpClientResponse response = await req.close().timeout(
        const Duration(minutes: 2),
      );
      final String text = await utf8.decodeStream(
        response.timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode == HttpStatus.conflict) {
        throw IrodoriVoiceUploadException(
          IrodoriVoiceUploadFailure.exists,
          _errorMessage(text),
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw IrodoriVoiceUploadException(
          IrodoriVoiceUploadFailure.rejected,
          'HTTP ${response.statusCode} ${_errorMessage(text) ?? ''}'.trim(),
        );
      }
      final Object? json = jsonDecode(text);
      final Object? returned = json is Map ? json['id'] : null;
      return returned is String && returned.isNotEmpty ? returned : id;
    } on IrodoriVoiceUploadException {
      rethrow;
    } on FormatException {
      return id;
    } on TimeoutException catch (e) {
      throw IrodoriVoiceUploadException(
        IrodoriVoiceUploadFailure.network,
        '$e',
      );
    } on IOException catch (e) {
      throw IrodoriVoiceUploadException(
        IrodoriVoiceUploadFailure.network,
        '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 删除上传过的声音。没有这个声音（或它不是上传的文件）返回 false。
  Future<bool> delete(String voiceId) async {
    final Uri? base = _base;
    if (base == null || !kIrodoriVoiceIdPattern.hasMatch(voiceId)) {
      throw const TtsFailure(TtsFailureCode.notConfigured);
    }
    final HttpClient client = _httpClientFactory();
    try {
      final HttpClientRequest req = await client
          .deleteUrl(base.replace(path: '/v1/audio/voices/$voiceId'))
          .timeout(const Duration(seconds: 30));
      _authHeaders(apiKey).forEach(req.headers.set);
      final HttpClientResponse response = await req.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>().catchError((Object _) {});
      if (response.statusCode == HttpStatus.notFound) return false;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ttsFailureForStatus(response.statusCode);
      }
      return true;
    } on TtsFailure {
      rethrow;
    } on TimeoutException {
      throw const TtsFailure(TtsFailureCode.timeout);
    } on IOException {
      throw const TtsFailure(TtsFailureCode.network);
    } finally {
      client.close(force: true);
    }
  }

  /// OpenAI 风格错误体 `{error: {message}}` 里的说明。
  static String? _errorMessage(String body) {
    try {
      final Object? json = jsonDecode(body);
      final Object? error = json is Map ? json['error'] : null;
      final Object? message = error is Map ? error['message'] : null;
      return message is String ? message : null;
    } on FormatException {
      return null;
    }
  }
}

/// 上传声音的 multipart 体（纯函数，测试直接调）。
({String contentType, List<int> body}) irodoriVoiceUploadForm({
  required String voiceId,
  required String fileName,
  required List<int> bytes,
  Random? random,
}) {
  final Random rng = random ?? Random.secure();
  final String boundary =
      'fushi-${List<String>.generate(16, (int _) => rng.nextInt(16).toRadixString(16)).join()}';
  final BytesBuilder body = BytesBuilder(copy: false)
    ..add(
      utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="voice_id"\r\n\r\n'
        '$voiceId\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n',
      ),
    )
    ..add(bytes)
    ..add(utf8.encode('\r\n--$boundary--\r\n'));
  return (
    contentType: 'multipart/form-data; boundary=$boundary',
    body: body.takeBytes(),
  );
}
