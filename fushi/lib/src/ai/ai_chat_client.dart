/// AI 提供商的调用层：一次性问答 + 模型列表。
///
/// 三种 wire 协议（OpenAI 兼容 / Anthropic Messages / Gemini generateContent）在
/// 这里分派，上层只面对 [AiChatClient.complete]。**不做流式**：本仓当前的 AI 用途
/// 是「生成一条规则/一段配置」这种短请求，流式只会把 UI 状态机复杂化。
///
/// 出站一律经 `createAppHttpIoClient()`——裸 `http.Client()` 既绕过应用代理与连接
/// 超时（代理环境下会出现「浏览器能开、app 里连不上」这种自相矛盾的结果），也会被
/// `test/tools/outbound_http_discipline_guard_test.dart` 的登记制守卫判红。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 一次调用的整体时限。
///
/// 与连接超时（`kAppHttpConnectionTimeout`）是两回事：那个管握手，这个管「模型在
/// 思考但迟迟不吐字」。推理型模型确实会慢，所以给得比普通 API 往返宽。
const Duration kAiChatRequestTimeout = Duration(seconds: 90);

/// 调用失败。[message] 是**已脱敏**的短文案，可以直接进 UI——绝不含 API Key、
/// 完整 URL 或响应体原文（后两者都可能回显凭据）。
class AiChatFailure implements Exception {
  const AiChatFailure(this.message);

  final String message;

  @override
  String toString() => 'AiChatFailure: $message';
}

/// 一条对话消息。
class AiChatMessage {
  const AiChatMessage.system(this.content) : role = 'system';
  const AiChatMessage.user(this.content) : role = 'user';
  const AiChatMessage.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  bool get isSystem => role == 'system';
}

/// 按 [AiProviderConfig.protocol] 分派的调用客户端。
///
/// [client] 可注入，测试用假客户端断言 wire 形状，不打真网。
class AiChatClient {
  AiChatClient({http.Client? client})
    : _client = client ?? createAppHttpIoClient(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// 发一次问答，拿回模型的纯文本回复。
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    if (!provider.isUsable) {
      throw const AiChatFailure('provider_not_configured');
    }
    return switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => _completeOpenAi(
        provider,
        messages,
        maxTokens,
      ),
      AiWireProtocol.anthropicMessages => _completeAnthropic(
        provider,
        messages,
        maxTokens,
      ),
      AiWireProtocol.geminiGenerateContent => _completeGemini(
        provider,
        messages,
        maxTokens,
      ),
    };
  }

  /// 拉这家提供商可用的模型名。
  ///
  /// 存在的理由：内置预设里的默认模型名**必然过时**（厂商迭代比本 app 发版快），
  /// 把用户钉死在一个写死的字符串上迟早变成「开箱即 404」。
  Future<List<String>> listModels(AiProviderConfig provider) async {
    final Uri uri = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => _resolve(provider.baseUrl, 'models'),
      AiWireProtocol.anthropicMessages => _resolve(
        provider.baseUrl,
        'v1/models',
      ),
      AiWireProtocol.geminiGenerateContent => _resolve(
        provider.baseUrl,
        'models',
      ).replace(queryParameters: <String, String>{'key': provider.apiKey}),
    };
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(provider)),
    );
    final Object? body = _decodeBody(response);
    if (body is! Map) {
      throw const AiChatFailure('bad_response');
    }
    final List<String> models = <String>[];
    final Object? data = body['data'] ?? body['models'];
    if (data is List) {
      for (final Object? entry in data) {
        if (entry is! Map) {
          continue;
        }
        final Object? id = entry['id'] ?? entry['name'];
        if (id is String && id.isNotEmpty) {
          // Gemini 回的是 `models/gemini-...`，剥掉前缀才是请求里要用的模型名。
          models.add(id.startsWith('models/') ? id.substring(7) : id);
        }
      }
    }
    models.sort();
    return List<String>.unmodifiable(models);
  }

  // -------------------------------------------------------------------------
  // 各协议实现
  // -------------------------------------------------------------------------

  Future<String> _completeOpenAi(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) async {
    final Map<String, Object?> payload = <String, Object?>{
      'model': provider.model,
      'messages': <Map<String, Object?>>[
        for (final AiChatMessage m in messages)
          <String, Object?>{'role': m.role, 'content': m.content},
      ],
      'max_tokens': maxTokens,
      // 只有用户显式选了推理档位才发这个字段：大量兼容端点不认识它，
      // 无条件发会让本来能用的服务直接 400。
      if (provider.reasoningEffort != AiReasoningEffort.none)
        'reasoning_effort': provider.reasoningEffort.storageKey,
    };
    final http.Response response = await _send(
      () => _client.post(
        _resolve(provider.baseUrl, 'chat/completions'),
        headers: _headers(provider),
        body: jsonEncode(payload),
      ),
    );
    final Object? body = _decodeBody(response);
    if (body is! Map) {
      throw const AiChatFailure('bad_response');
    }
    final Object? choices = body['choices'];
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map) {
        final Object? message = first['message'];
        if (message is Map) {
          final Object? content = message['content'];
          if (content is String) {
            return content;
          }
        }
      }
    }
    throw const AiChatFailure('empty_response');
  }

  Future<String> _completeAnthropic(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) async {
    // Anthropic 把 system 提到顶层，不放进 messages 数组。
    final String system = messages
        .where((AiChatMessage m) => m.isSystem)
        .map((AiChatMessage m) => m.content)
        .join('\n\n');
    final Map<String, Object?> payload = <String, Object?>{
      'model': provider.model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': <Map<String, Object?>>[
        for (final AiChatMessage m in messages)
          if (!m.isSystem)
            <String, Object?>{'role': m.role, 'content': m.content},
      ],
    };
    final http.Response response = await _send(
      () => _client.post(
        _resolve(provider.baseUrl, 'v1/messages'),
        headers: _headers(provider),
        body: jsonEncode(payload),
      ),
    );
    final Object? body = _decodeBody(response);
    if (body is! Map) {
      throw const AiChatFailure('bad_response');
    }
    final Object? content = body['content'];
    if (content is List) {
      final StringBuffer text = StringBuffer();
      for (final Object? block in content) {
        if (block is Map &&
            block['type'] == 'text' &&
            block['text'] is String) {
          text.write(block['text'] as String);
        }
      }
      if (text.isNotEmpty) {
        return text.toString();
      }
    }
    throw const AiChatFailure('empty_response');
  }

  Future<String> _completeGemini(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) async {
    final String system = messages
        .where((AiChatMessage m) => m.isSystem)
        .map((AiChatMessage m) => m.content)
        .join('\n\n');
    final Map<String, Object?> payload = <String, Object?>{
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <Map<String, String>>[
            <String, String>{'text': system},
          ],
        },
      'contents': <Map<String, Object?>>[
        for (final AiChatMessage m in messages)
          if (!m.isSystem)
            <String, Object?>{
              // Gemini 管 assistant 叫 model。
              'role': m.role == 'assistant' ? 'model' : 'user',
              'parts': <Map<String, String>>[
                <String, String>{'text': m.content},
              ],
            },
      ],
      'generationConfig': <String, Object?>{'maxOutputTokens': maxTokens},
    };
    final Uri uri = _resolve(
      provider.baseUrl,
      'models/${provider.model}:generateContent',
    ).replace(queryParameters: <String, String>{'key': provider.apiKey});
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: _headers(provider),
        body: jsonEncode(payload),
      ),
    );
    final Object? body = _decodeBody(response);
    if (body is! Map) {
      throw const AiChatFailure('bad_response');
    }
    final Object? candidates = body['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final Object? first = candidates.first;
      if (first is Map) {
        final Object? content = first['content'];
        if (content is Map) {
          final Object? parts = content['parts'];
          if (parts is List) {
            final StringBuffer text = StringBuffer();
            for (final Object? part in parts) {
              if (part is Map && part['text'] is String) {
                text.write(part['text'] as String);
              }
            }
            if (text.isNotEmpty) {
              return text.toString();
            }
          }
        }
      }
    }
    throw const AiChatFailure('empty_response');
  }

  // -------------------------------------------------------------------------
  // 共用
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AiProviderConfig provider) {
    final Map<String, String> headers = <String, String>{
      'content-type': 'application/json',
    };
    switch (provider.protocol) {
      case AiWireProtocol.openAiCompatible:
        if (provider.apiKey.isNotEmpty) {
          headers['authorization'] = 'Bearer ${provider.apiKey}';
        }
      case AiWireProtocol.anthropicMessages:
        headers['x-api-key'] = provider.apiKey;
        headers['anthropic-version'] = '2023-06-01';
      case AiWireProtocol.geminiGenerateContent:
        // key 走 query 参数，不进 header。
        break;
    }
    return headers;
  }

  Future<http.Response> _send(Future<http.Response> Function() send) async {
    final http.Response response;
    try {
      response = await send().timeout(kAiChatRequestTimeout);
    } catch (_) {
      // 原始异常可能带完整 URL（含 Gemini 的 ?key=），绝不透出。
      throw const AiChatFailure('network_error');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AiChatFailure('unauthorized');
    }
    if (response.statusCode == 429) {
      throw const AiChatFailure('rate_limited');
    }
    if (response.statusCode >= 400) {
      throw AiChatFailure('http_${response.statusCode}');
    }
    return response;
  }

  Object? _decodeBody(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const AiChatFailure('bad_response');
    }
  }

  /// 把相对路径接到 base 上，容忍 base 带不带尾斜杠。
  static Uri _resolve(Uri base, String path) {
    final String basePath = base.path.endsWith('/')
        ? base.path
        : '${base.path}/';
    return base.replace(path: '$basePath$path');
  }
}
