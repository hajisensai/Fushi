/// 官方 Irodori-TTS-Server（`Aratako/Irodori-TTS-Server`，OpenAI 兼容）的朗读接口：
/// - `GET  /v1/audio/voices` → `{data: [{id, ref_wav, ..., no_ref}]}`；
/// - `POST /v1/audio/speech` `{model, input, voice, response_format, irodori}` → 音频；
/// - `POST /v1/audio/voices`（multipart `file` + `voice_id`）上传参考音频建声音，
///   `DELETE /v1/audio/voices/{id}` 删除上传过的声音（[IrodoriServerVoiceApi]）。
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

class IrodoriServerTtsProvider extends TtsProvider {
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
      uri: base.replace(path: '/v1/audio/speech'),
      outputPath: outputPath,
      cancel: cancel,
      body: utf8.encode(
        jsonEncode(
          irodoriServerSpeechRequest(
            text: text,
            voice: voice,
            caption: caption,
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

/// `POST /v1/audio/speech` 的请求体（纯函数，测试直接调）。服务端倍速恒 1.0，播放
/// 倍速由本地播放器控制；整句已由调用方切好，服务端的长文本分块照默认。
Map<String, Object?> irodoriServerSpeechRequest({
  required String text,
  required String voice,
  String caption = '',
}) => <String, Object?>{
  'model': IrodoriServerTtsDescriptor.modelName,
  'input': text,
  'voice': voice.trim(),
  'response_format': 'wav',
  if (caption.trim().isNotEmpty)
    'irodori': <String, Object?>{'caption': caption.trim()},
};

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
