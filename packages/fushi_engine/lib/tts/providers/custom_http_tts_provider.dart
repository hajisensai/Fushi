/// 自定义 HTTP TTS：用户自己描述一个合成接口（地址、方法、请求模板、请求头、返回格式），
/// 接没有专门适配的自建服务（GPT-SoVITS 各下游分支、各类 WebUI 的 API）。
///
/// - 模板里的占位符：`{text}`（这一句）、`{lang}`、`{speed}`、`{api_key}`（凭据）。
///   query 模板按 URL 编码代入；JSON 模板先按 JSON 解析，再只在**字符串值**里代入，
///   最后整体重新编码——引号、换行、反斜杠都由编码器转义，模板写法不会被文本内容破坏。
///   整个字符串值恰好是 `"{speed}"` 时代入数字。
/// - 凭据只放 `api_key`（secret 参数，按凭据存）：请求头 / query 里的凭据型字段必须写
///   `{api_key}`，写明文的校验不过（[CustomHttpTtsDescriptor.validate]）。
/// - 失败只带错误码与 HTTP 状态，不带地址、模板、响应正文。
/// - 返回格式：直接音频字节；或 JSON 里按字段路径取 base64 / 音频地址（地址再 GET 一次，
///   只有与合成接口同源时才带上用户配的请求头，凭据不发给别的主机）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 返回格式。
enum CustomHttpTtsResponse {
  /// 响应体就是音频（WAV / MP3）。
  audio('audio'),

  /// JSON，字段路径处是 base64 音频（可带 `data:audio/...;base64,` 前缀）。
  jsonBase64('json_base64'),

  /// JSON，字段路径处是音频地址（相对地址按合成接口地址解析）。
  jsonUrl('json_url');

  const CustomHttpTtsResponse(this.id);

  /// 持久化值（写进预设，不可改名）。
  final String id;

  static CustomHttpTtsResponse parse(String raw) =>
      CustomHttpTtsResponse.values.firstWhere(
        (CustomHttpTtsResponse r) => r.id == raw.trim(),
        orElse: () => CustomHttpTtsResponse.audio,
      );
}

class CustomHttpTtsDescriptor extends TtsProviderDescriptor {
  const CustomHttpTtsDescriptor();

  static const String providerId = 'custom_http';

  static const String endpointKey = 'endpoint';
  static const String methodKey = 'method';
  static const String queryKey = 'query_template';
  static const String bodyKey = 'body_template';
  static const String headersKey = 'headers';
  static const String apiKeyKey = 'api_key';
  static const String langKey = 'lang';
  static const String speedKey = 'speed';
  static const String responseKey = 'response_format';
  static const String responsePathKey = 'response_path';

  static const List<String> methods = <String>['POST', 'GET'];

  @override
  String get id => providerId;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
    // 不知道对面是什么服务：默认串行，用户可在预设里调高并发。
    maxConcurrency: 1,
    maxInputLength: 200,
  );

  @override
  List<TtsParamSpec> get params => <TtsParamSpec>[
    // 不预置任何第三方服务地址：用户必须自己填。
    const TtsParamSpec(
      key: endpointKey,
      kind: TtsParamKind.url,
      required: true,
      affectsAudio: false,
    ),
    const TtsParamSpec(
      key: methodKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: 'POST',
      choices: methods,
      affectsAudio: false,
    ),
    const TtsParamSpec(key: queryKey, kind: TtsParamKind.text),
    const TtsParamSpec(key: bodyKey, kind: TtsParamKind.multiline),
    const TtsParamSpec(
      key: headersKey,
      kind: TtsParamKind.multiline,
      affectsAudio: false,
    ),
    const TtsParamSpec(
      key: apiKeyKey,
      kind: TtsParamKind.secret,
      affectsAudio: false,
    ),
    const TtsParamSpec(key: langKey, kind: TtsParamKind.text),
    const TtsParamSpec(key: speedKey, kind: TtsParamKind.text),
    TtsParamSpec(
      key: responseKey,
      kind: TtsParamKind.choice,
      required: true,
      defaultValue: CustomHttpTtsResponse.audio.id,
      choices: <String>[
        for (final CustomHttpTtsResponse r in CustomHttpTtsResponse.values)
          r.id,
      ],
      affectsAudio: false,
    ),
    const TtsParamSpec(
      key: responsePathKey,
      kind: TtsParamKind.text,
      affectsAudio: false,
    ),
  ];

  @override
  List<String> validate(TtsVoicePreset preset) {
    final List<String> problems = super.validate(preset);
    void add(String key) {
      if (!problems.contains(key)) problems.add(key);
    }

    final CustomHttpTtsConfig config = CustomHttpTtsConfig.fromPreset(preset);
    if (!methods.contains(config.method)) add(methodKey);
    if (customHttpTtsParseQuery(config.queryTemplate) == null) add(queryKey);
    if (config.bodyTemplate.trim().isNotEmpty) {
      // GET 不带请求体；JSON 模板本身必须是合法 JSON。
      final Object? tree = customHttpTtsParseBody(config.bodyTemplate);
      if (config.method == 'GET' ||
          tree == null ||
          customHttpTtsBodyHasCredentialLiteral(tree)) {
        add(bodyKey);
      }
    }
    final List<(String, String)>? headers = customHttpTtsParseHeaders(
      config.headersTemplate,
    );
    if (headers == null ||
        headers.any(
          ((String, String) h) => customHttpTtsCredentialLiteral(h.$1, h.$2),
        )) {
      add(headersKey);
    }
    final List<(String, String)>? query = customHttpTtsParseQuery(
      config.queryTemplate,
    );
    if (query != null &&
        query.any(
          ((String, String) q) => customHttpTtsCredentialLiteral(q.$1, q.$2),
        )) {
      add(queryKey);
    }
    if (config.response != CustomHttpTtsResponse.audio &&
        customHttpTtsParsePath(config.responsePath) == null) {
      add(responsePathKey);
    }
    return problems;
  }

  /// 声音由对面服务的模型 / 说话人决定：地址（主机 + 端口 + 路径 + 固定 query）进身份，
  /// 换一台服务、或地址里写死的 `?speaker=` / `?model=` 变了，都不复用旧缓存；
  /// 方法与返回格式不改变声音，不进身份。
  @override
  Map<String, Object?> audioIdentity(TtsVoicePreset preset) {
    final Uri? uri = Uri.tryParse(preset.param(endpointKey).trim());
    return <String, Object?>{
      ...super.audioIdentity(preset),
      'host': uri?.host ?? '',
      'port': uri?.port ?? 0,
      'path': uri?.path ?? '',
      'query': uri?.query ?? '',
    };
  }

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      CustomHttpTtsProvider(
        config: CustomHttpTtsConfig.fromPreset(preset),
        host: host,
      );
}

/// 一份预设解析出的请求配置（纯数据，测试直接构造）。
class CustomHttpTtsConfig {
  const CustomHttpTtsConfig({
    required this.endpoint,
    this.method = 'POST',
    this.queryTemplate = '',
    this.bodyTemplate = '',
    this.headersTemplate = '',
    this.apiKey = '',
    this.lang = '',
    this.speed = '',
    this.response = CustomHttpTtsResponse.audio,
    this.responsePath = '',
  });

  factory CustomHttpTtsConfig.fromPreset(TtsVoicePreset preset) {
    String p(String key) => preset.param(key);
    return CustomHttpTtsConfig(
      endpoint: p(CustomHttpTtsDescriptor.endpointKey).trim(),
      method: preset
          .param(CustomHttpTtsDescriptor.methodKey, fallback: 'POST')
          .trim()
          .toUpperCase(),
      queryTemplate: p(CustomHttpTtsDescriptor.queryKey),
      bodyTemplate: p(CustomHttpTtsDescriptor.bodyKey),
      headersTemplate: p(CustomHttpTtsDescriptor.headersKey),
      apiKey: p(CustomHttpTtsDescriptor.apiKeyKey).trim(),
      lang: p(CustomHttpTtsDescriptor.langKey).trim(),
      speed: p(CustomHttpTtsDescriptor.speedKey).trim(),
      response: CustomHttpTtsResponse.parse(
        p(CustomHttpTtsDescriptor.responseKey),
      ),
      responsePath: p(CustomHttpTtsDescriptor.responsePathKey).trim(),
    );
  }

  final String endpoint;
  final String method;
  final String queryTemplate;
  final String bodyTemplate;
  final String headersTemplate;
  final String apiKey;
  final String lang;
  final String speed;
  final CustomHttpTtsResponse response;
  final String responsePath;

  /// 占位符 → 值。
  Map<String, String> valuesFor(String text) => <String, String>{
    'text': text,
    'lang': lang,
    'speed': speed.isEmpty ? '1.0' : speed,
    'api_key': apiKey,
  };
}

/// 一次合成要发的请求（纯函数 [buildCustomHttpTtsRequest] 的产物，测试直接断言）。
class CustomHttpTtsRequest {
  const CustomHttpTtsRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

final RegExp _kPlaceholder = RegExp(r'\{(text|lang|speed|api_key)\}');

/// 把字符串里的已知占位符原样替换（转义由调用方按目标格式负责）。未知的 `{…}` 不动。
String customHttpTtsSubstitute(String template, Map<String, String> values) =>
    template.replaceAllMapped(
      _kPlaceholder,
      (Match m) => values[m.group(1)!] ?? m.group(0)!,
    );

/// query 模板 `a=1&b={text}` → 键值对（代入前）。格式不对（有段缺键名）返回 null；
/// 空模板返回空列表。
List<(String, String)>? customHttpTtsParseQuery(String template) {
  final String trimmed = template.trim();
  if (trimmed.isEmpty) return const <(String, String)>[];
  final List<(String, String)> pairs = <(String, String)>[];
  for (final String part in trimmed.split('&')) {
    if (part.isEmpty) continue;
    final int eq = part.indexOf('=');
    final String key = (eq < 0 ? part : part.substring(0, eq)).trim();
    if (key.isEmpty) return null;
    pairs.add((key, eq < 0 ? '' : part.substring(eq + 1)));
  }
  return pairs;
}

/// JSON 请求体模板 → 解析后的树（代入前）。不是合法 JSON 返回 null。
Object? customHttpTtsParseBody(String template) {
  try {
    return jsonDecode(template);
  } on FormatException {
    return null;
  }
}

final RegExp _kHeaderName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// 请求头模板：每行 `Name: value`，空行忽略。有一行不合法（缺冒号、名字含非法字符）
/// 返回 null。
List<(String, String)>? customHttpTtsParseHeaders(String template) {
  final List<(String, String)> headers = <(String, String)>[];
  for (final String raw in const LineSplitter().convert(template)) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final int colon = line.indexOf(':');
    if (colon <= 0) return null;
    final String name = line.substring(0, colon).trim();
    if (!_kHeaderName.hasMatch(name)) return null;
    headers.add((name, line.substring(colon + 1).trim()));
  }
  return headers;
}

final RegExp _kCredentialName = RegExp(
  r'(authorization|cookie|token|secret|password|passwd|api[-_]?key|app[-_]?key|access[-_]?key|auth)',
  caseSensitive: false,
);

/// 凭据型字段（`Authorization`、`X-Api-Key`、`token`……）写了明文值、没有用
/// `{api_key}`：凭据只能放进 `api_key`（按凭据存），模板是普通参数。
bool customHttpTtsCredentialLiteral(String name, String value) =>
    _kCredentialName.hasMatch(name) &&
    value.trim().isNotEmpty &&
    !value.contains('{api_key}');

/// JSON 模板里有没有凭据型键（`app_key`、`token`……）写了明文字符串值。
bool customHttpTtsBodyHasCredentialLiteral(Object? node) {
  if (node is List) return node.any(customHttpTtsBodyHasCredentialLiteral);
  if (node is! Map) return false;
  for (final MapEntry<Object?, Object?> e in node.entries) {
    final Object? value = e.value;
    if (value is String && customHttpTtsCredentialLiteral('${e.key}', value)) {
      return true;
    }
    if (customHttpTtsBodyHasCredentialLiteral(value)) return true;
  }
  return false;
}

/// 字段路径 `data.items.0.url` → 段列表。空或有空段返回 null。
List<String>? customHttpTtsParsePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  final List<String> segments = trimmed.split('.');
  if (segments.any((String s) => s.trim().isEmpty)) return null;
  return <String>[for (final String s in segments) s.trim()];
}

/// 按字段路径取值：Map 按键，List 按下标。取不到返回 null。
Object? customHttpTtsPick(Object? json, List<String> path) {
  Object? node = json;
  for (final String segment in path) {
    if (node is Map) {
      node = node[segment];
    } else if (node is List) {
      final int? index = int.tryParse(segment);
      if (index == null || index < 0 || index >= node.length) return null;
      node = node[index];
    } else {
      return null;
    }
  }
  return node;
}

Object? _substituteJson(Object? node, Map<String, String> values) {
  if (node is String) {
    // 整个值就是 {speed}：代入数字（服务端多半要 float）。
    if (node == '{speed}') {
      final String speed = values['speed'] ?? '';
      return num.tryParse(speed) ?? speed;
    }
    return customHttpTtsSubstitute(node, values);
  }
  if (node is List) {
    return <Object?>[for (final Object? v in node) _substituteJson(v, values)];
  }
  if (node is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in node.entries)
        '${e.key}': _substituteJson(e.value, values),
    };
  }
  return node;
}

/// 按配置与这一句造出请求。配置不完整 / 不合法抛 [TtsFailureCode.notConfigured]。
CustomHttpTtsRequest buildCustomHttpTtsRequest(
  CustomHttpTtsConfig config,
  String text,
) {
  const TtsFailure notConfigured = TtsFailure(TtsFailureCode.notConfigured);
  final Uri? base = Uri.tryParse(config.endpoint);
  if (base == null ||
      !(base.isScheme('http') || base.isScheme('https')) ||
      base.host.isEmpty) {
    throw notConfigured;
  }
  if (!CustomHttpTtsDescriptor.methods.contains(config.method)) {
    throw notConfigured;
  }
  final Map<String, String> values = config.valuesFor(text);

  final List<(String, String)>? query = customHttpTtsParseQuery(
    config.queryTemplate,
  );
  if (query == null) throw notConfigured;
  final String encodedQuery = <String>[
    if (base.query.isNotEmpty) base.query,
    for (final (String key, String value) in query)
      '${Uri.encodeQueryComponent(customHttpTtsSubstitute(key, values))}='
          '${Uri.encodeQueryComponent(customHttpTtsSubstitute(value, values))}',
  ].join('&');
  final Uri uri = Uri(
    scheme: base.scheme,
    userInfo: base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: base.path,
    query: encodedQuery.isEmpty ? null : encodedQuery,
  );

  final List<(String, String)>? headerLines = customHttpTtsParseHeaders(
    config.headersTemplate,
  );
  if (headerLines == null) throw notConfigured;
  final Map<String, String> headers = <String, String>{};
  for (final (String name, String value) in headerLines) {
    if (customHttpTtsCredentialLiteral(name, value)) throw notConfigured;
    final String resolved = customHttpTtsSubstitute(value, values);
    // 代入后带换行就是请求头注入：拒绝（不截断、不替换）。
    if (resolved.contains('\r') || resolved.contains('\n')) {
      throw notConfigured;
    }
    headers[name] = resolved;
  }
  for (final (String name, String value) in query) {
    if (customHttpTtsCredentialLiteral(name, value)) throw notConfigured;
  }

  List<int>? body;
  if (config.bodyTemplate.trim().isNotEmpty) {
    if (config.method == 'GET') throw notConfigured;
    final Object? tree = customHttpTtsParseBody(config.bodyTemplate);
    if (tree == null || customHttpTtsBodyHasCredentialLiteral(tree)) {
      throw notConfigured;
    }
    body = utf8.encode(jsonEncode(_substituteJson(tree, values)));
    if (!headers.keys.any(
      (String k) => k.toLowerCase() == HttpHeaders.contentTypeHeader,
    )) {
      headers[HttpHeaders.contentTypeHeader] =
          'application/json; charset=utf-8';
    }
  } else if (config.method == 'POST') {
    body = const <int>[];
  }
  return CustomHttpTtsRequest(
    method: config.method,
    uri: uri,
    headers: headers,
    body: body,
  );
}

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.host == b.host && a.port == b.port;

class CustomHttpTtsProvider extends TtsProvider {
  CustomHttpTtsProvider({required this.config, required TtsHost host})
    : _client = host.httpClientFactory();

  final CustomHttpTtsConfig config;
  final HttpClient _client;

  @override
  TtsCapabilities get capabilities =>
      const CustomHttpTtsDescriptor().capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    final CustomHttpTtsRequest request = buildCustomHttpTtsRequest(
      config,
      text,
    );
    switch (config.response) {
      case CustomHttpTtsResponse.audio:
        await ttsSendToFile(
          client: _client,
          method: request.method,
          uri: request.uri,
          outputPath: outputPath,
          cancel: cancel,
          headers: request.headers,
          body: request.body,
        );
      case CustomHttpTtsResponse.jsonBase64:
      case CustomHttpTtsResponse.jsonUrl:
        final List<String>? path = customHttpTtsParsePath(config.responsePath);
        if (path == null) throw const TtsFailure(TtsFailureCode.notConfigured);
        final Object? json = await ttsSendForJson(
          client: _client,
          method: request.method,
          uri: request.uri,
          cancel: cancel,
          headers: request.headers,
          body: request.body,
        );
        final Object? value = customHttpTtsPick(json, path);
        // 有的服务失败时也回 200，只是音频字段为空（错误写在别的字段里）。
        if (value is! String || value.trim().isEmpty) {
          throw const TtsFailure(TtsFailureCode.badResponse, 'missing field');
        }
        if (config.response == CustomHttpTtsResponse.jsonBase64) {
          await _writeBase64(value.trim(), outputPath);
        } else {
          await _download(value.trim(), request, outputPath, cancel);
        }
    }
    cancel.throwIfCancelled();
    return TtsResult(format: await _sniff(outputPath));
  }

  Future<void> _writeBase64(String value, String outputPath) async {
    // `data:audio/wav;base64,....` 也认。
    final int comma = value.startsWith('data:') ? value.indexOf(',') : -1;
    final String payload = comma >= 0 ? value.substring(comma + 1) : value;
    final Uint8List bytes;
    try {
      bytes = base64Decode(payload.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const TtsFailure(TtsFailureCode.badResponse, 'base64');
    }
    if (bytes.isEmpty) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'empty');
    }
    await File(outputPath).writeAsBytes(bytes, flush: true);
  }

  Future<void> _download(
    String value,
    CustomHttpTtsRequest request,
    String outputPath,
    TtsCancelToken cancel,
  ) async {
    final Uri? ref = Uri.tryParse(value);
    final Uri? audio = ref == null ? null : request.uri.resolveUri(ref);
    if (audio == null ||
        !(audio.isScheme('http') || audio.isScheme('https')) ||
        audio.host.isEmpty) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'audio url');
    }
    await ttsSendToFile(
      client: _client,
      method: 'GET',
      uri: audio,
      outputPath: outputPath,
      cancel: cancel,
      // 用户配的请求头可能带凭据：只发给合成接口同源的地址。
      headers: _sameOrigin(audio, request.uri)
          ? <String, String>{
              for (final MapEntry<String, String> e in request.headers.entries)
                if (e.key.toLowerCase() != HttpHeaders.contentTypeHeader)
                  e.key: e.value,
            }
          : const <String, String>{},
    );
  }

  /// 按内容判断格式（不信 Content-Type）；不是 WAV / MP3 的一律当坏响应。
  Future<TtsAudioFormat> _sniff(String outputPath) async {
    final RandomAccessFile file = await File(outputPath).open();
    final Uint8List head;
    try {
      head = await file.read(16);
    } finally {
      await file.close();
    }
    final TtsAudioFormat? format = sniffTtsAudioFormat(head);
    if (format == null) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'not audio');
    }
    return format;
  }

  @override
  Future<void> dispose() async => _client.close(force: true);
}
