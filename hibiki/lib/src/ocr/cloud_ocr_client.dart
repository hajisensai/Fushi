/// 云端 VLM 手写兜底客户端（设计 PR#377 §5.3 生产者 D，P4；默认关）。
///
/// Gemini REST `generateContent`：输入 = 裁框 PNG（base64 inline_data）+ 转写
/// 提示词；输出取第一候选文本、剥 markdown 围栏。
///
/// 红线（用户拍板）：默认关；关着时**零网络调用**（[CloudOcrService] 闸门在建
/// client 之前）；不做自动路由——只有用户手动点「云端重试」才发请求；自备 API
/// key；设置区有明示图片上云的隐私说明。
///
/// http 层经 [Dio] 构造注入（测试注 fake adapter，不发真请求）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 默认模型（可被设置区 `manga_cloud_ocr_model` 偏好覆盖）。
const String kCloudOcrDefaultModel = 'gemini-2.5-flash';

/// Gemini REST 端点前缀（`<base>/<model>:generateContent?key=<key>`）。
const String kCloudOcrEndpointBase =
    'https://generativelanguage.googleapis.com/v1beta/models';

/// 转写提示词：日语漫画气泡逐字转写、竖排右到左、只回原文不解释。
const String kCloudOcrPrompt = 'この画像は日本の漫画の吹き出しや手書き文字の切り抜きです。'
    '画像内の日本語テキストを一字一句そのまま書き起こしてください。'
    '縦書きの場合は右の列から左の列の順に読みます。'
    '説明・翻訳・注釈は一切不要です。書き起こした原文のみを出力してください。'
    'テキストが読み取れない場合は空文字を返してください。';

/// 云端识别错误（网络 / 非 200 / 空回），message 可直接展示。
class CloudOcrException implements Exception {
  const CloudOcrException(this.message);

  final String message;

  @override
  String toString() => 'CloudOcrException: $message';
}

/// 纯函数：配置的模型名 → 实际请求模型名（空/空白 → 默认档）。
String resolveCloudOcrModel(String? configured) {
  final String trimmed = configured?.trim() ?? '';
  return trimmed.isEmpty ? kCloudOcrDefaultModel : trimmed;
}

/// 纯函数：云端开关可用性闸门（开关开 + key 非空才可用）。
bool isCloudOcrAvailable({required bool enabled, required String apiKey}) {
  return enabled && apiKey.trim().isNotEmpty;
}

/// 纯函数：剥掉 ```/```json 之类的 markdown 围栏（模型偶尔包一层）。
String stripMarkdownFences(String raw) {
  final String trimmed = raw.trim();
  if (!trimmed.startsWith('```')) {
    return trimmed;
  }
  final List<String> lines = trimmed.split('\n');
  if (lines.length < 2) {
    return trimmed;
  }
  // 去掉首行 ```lang；若尾行是 ``` 也去掉。
  final List<String> body = lines.sublist(1);
  if (body.isNotEmpty && body.last.trim() == '```') {
    body.removeLast();
  }
  return body.join('\n').trim();
}

/// 纯函数：构造 generateContent 请求体（inline_data PNG + 提示词）。
Map<String, Object?> buildCloudOcrRequestBody(Uint8List pngBytes) {
  return <String, Object?>{
    'contents': <Object?>[
      <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{
            'inline_data': <String, Object?>{
              'mime_type': 'image/png',
              'data': base64Encode(pngBytes),
            },
          },
          <String, Object?>{'text': kCloudOcrPrompt},
        ],
      },
    ],
  };
}

/// 纯函数：generateContent 响应 → 第一候选文本（parts 内 text 串接、剥围栏、
/// trim）。无候选/畸形 → 空串（调用方判空报错）。
String parseCloudOcrResponseText(Object? body) {
  Object? decoded = body;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return '';
    }
  }
  if (decoded is! Map) return '';
  final Object? candidates = decoded['candidates'];
  if (candidates is! List || candidates.isEmpty) return '';
  final Object? first = candidates.first;
  if (first is! Map) return '';
  final Object? content = first['content'];
  if (content is! Map) return '';
  final Object? parts = content['parts'];
  if (parts is! List) return '';
  final StringBuffer buffer = StringBuffer();
  for (final Object? part in parts) {
    if (part is Map && part['text'] is String) {
      buffer.write(part['text'] as String);
    }
  }
  return stripMarkdownFences(buffer.toString());
}

/// 从错误响应体里挖 `error.message`（Gemini 标准错误结构），拼进异常文案。
String _apiErrorSuffix(Object? body) {
  Object? decoded = body;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return '';
    }
  }
  if (decoded is Map) {
    final Object? error = decoded['error'];
    if (error is Map && error['message'] is String) {
      return ': ${error['message']}';
    }
  }
  return '';
}

/// Gemini REST 客户端（薄层：一图一提示词进、一段文本出）。
class CloudOcrClient {
  CloudOcrClient({
    required String apiKey,
    String? model,
    Dio? dio,
    String endpointBase = kCloudOcrEndpointBase,
  })  : _apiKey = apiKey,
        _model = resolveCloudOcrModel(model),
        _endpointBase = endpointBase,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ));

  final String _apiKey;
  final String _model;
  final String _endpointBase;
  final Dio _dio;

  /// 转写一张裁框 PNG。抛 [CloudOcrException]（超时/非 200/空回均含可读信息）。
  Future<String> transcribePng(Uint8List pngBytes) async {
    if (_apiKey.trim().isEmpty) {
      throw const CloudOcrException('API key is empty');
    }
    final String url = '$_endpointBase/$_model:generateContent'
        '?key=${Uri.encodeQueryComponent(_apiKey)}';
    Response<Object?> response;
    try {
      response = await _dio.post<Object?>(
        url,
        data: buildCloudOcrRequestBody(pngBytes),
        options: Options(
          headers: <String, Object?>{'Content-Type': 'application/json'},
          responseType: ResponseType.json,
          // 非 200 自行判读，拼出含 API error.message 的可读错误。
          validateStatus: (int? _) => true,
        ),
      );
    } on DioError catch (e) {
      // 树内钉的是 dio 5.1.x：错误类型还叫 DioError（5.3+ 才更名 DioException）。
      final String detail = e.message == null ? '' : ' (${e.message})';
      throw CloudOcrException('network error: ${e.type.name}$detail');
    }
    final int status = response.statusCode ?? 0;
    if (status != 200) {
      throw CloudOcrException('HTTP $status${_apiErrorSuffix(response.data)}');
    }
    final String text = parseCloudOcrResponseText(response.data);
    if (text.isEmpty) {
      throw const CloudOcrException('empty response');
    }
    return text;
  }
}

/// 带偏好闸门的服务层：开关关 / key 空时 [transcribePng] 直接抛 [StateError]，
/// **连 client 都不建**——零网络调用（红线）。
class CloudOcrService {
  CloudOcrService({
    required bool enabled,
    required String apiKey,
    String? model,
    Dio? dio,
    String endpointBase = kCloudOcrEndpointBase,
  })  : _enabled = enabled,
        _apiKey = apiKey,
        _model = model,
        _dio = dio,
        _endpointBase = endpointBase;

  final bool _enabled;
  final String _apiKey;
  final String? _model;
  final Dio? _dio;
  final String _endpointBase;

  CloudOcrClient? _client;

  /// 开关开 + key 非空才可用（决定「云端重试」按钮显隐与请求闸门）。
  bool get isAvailable =>
      isCloudOcrAvailable(enabled: _enabled, apiKey: _apiKey);

  Future<String> transcribePng(Uint8List pngBytes) {
    if (!isAvailable) {
      // 闸门在建 client 之前：关着时零网络调用。
      throw StateError('cloud OCR is disabled or API key is empty');
    }
    _client ??= CloudOcrClient(
      apiKey: _apiKey,
      model: _model,
      dio: _dio,
      endpointBase: _endpointBase,
    );
    return _client!.transcribePng(pngBytes);
  }
}
