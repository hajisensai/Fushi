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

import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 一次调用的整体时限。
///
/// 与连接超时（`kAppHttpConnectionTimeout`）是两回事：那个管握手，这个管「模型在
/// 思考但迟迟不吐字」。推理型模型确实会慢，所以给得比普通 API 往返宽。
const Duration kAiChatRequestTimeout = Duration(seconds: 90);

/// OpenAI 官方 API 的 host：只有它要求 `max_completion_tokens`（见
/// [AiChatClient] 的 OpenAI 载荷构造）。
const String kOpenAiOfficialHost = 'api.openai.com';

/// [AiChatClient.ping] 的输出上限：够任何模型吐出第一个 token，也给推理模型的
/// 思考留了余量；正文被截断无所谓——测的是通路，不是回答。
const int _kPingMaxTokens = 32;

/// 调用失败。[message] 是**已脱敏**的短文案，可以直接进 UI——绝不含 API Key、
/// 完整 URL 或响应体原文（后两者都可能回显凭据）。
class AiChatFailure implements Exception {
  const AiChatFailure(this.message);

  final String message;

  /// 原样重试可能成功的失败：网络 / 超时（都报 `network_error`）、限流、5xx。
  /// 鉴权失败、4xx、坏回复、空回复、未配置都是配置或模型的问题，重试也一样。
  bool get isTransient =>
      message == 'network_error' ||
      message == 'rate_limited' ||
      message.startsWith('http_5');

  @override
  String toString() => 'AiChatFailure: $message';
}

/// 随消息一起发的一张图（视觉模型用）。
///
/// 只收已编码的位图字节——三家协议都按 base64 内联，不走 URL：本仓的图都在本机
/// （漫画页 / 截图），给外链等于先把图传到别处。
class AiChatImage {
  const AiChatImage({required this.bytes, this.mimeType = 'image/png'});

  final List<int> bytes;

  /// `image/png` / `image/jpeg` / `image/webp`（三家共同支持的集合）。
  final String mimeType;

  String get base64Data => base64Encode(bytes);
}

/// 一条对话消息。
class AiChatMessage {
  const AiChatMessage.system(this.content)
    : role = 'system',
      images = const <AiChatImage>[];

  /// [images] 只对 user 消息有意义：三家协议都只在用户回合收图。
  const AiChatMessage.user(this.content, {this.images = const <AiChatImage>[]})
    : role = 'user';
  const AiChatMessage.assistant(this.content)
    : role = 'assistant',
      images = const <AiChatImage>[];

  final String role;
  final String content;

  /// 附图；非空时按各协议的多模态形状发（文字段在图之后）。
  final List<AiChatImage> images;

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
  ///
  /// 三种协议同一口径：回复为空或只有空白一律抛 `empty_response`——空串对每个
  /// 调用方都是「AI 什么也没给」，当成功返回只会把失败推迟成下游的解析错误。
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    if (!provider.isUsable) {
      throw const AiChatFailure('provider_not_configured');
    }
    final Map<Object?, Object?> body = await _postChat(
      provider,
      messages,
      maxTokens,
    );
    final String? text = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => _openAiText(body),
      AiWireProtocol.anthropicMessages => _anthropicText(body),
      AiWireProtocol.geminiGenerateContent => _geminiText(body),
    };
    if (text == null || text.trim().isEmpty) {
      throw const AiChatFailure('empty_response');
    }
    return text;
  }

  /// 「测试连接」：对**所配模型**发一次最小 chat 请求。
  ///
  /// 验证的是功能真正要走的那条路（chat 端点 + 鉴权 + 模型名）——listModels 只能
  /// 证明 key 和地址对，模型名拼错、账号没开通该模型、端点不支持 chat 都照样
  /// 「连接正常」，然后在功能里第一次真用时才失败。
  ///
  /// 成功判据是「这家按协议回了一份形状正确的应答」，**不要求有正文**：上限只给
  /// [_kPingMaxTokens]，推理模型（o 系列 / Gemini thinking）可能把额度全花在思考
  /// 上、正文为空并以长度截断收尾——那恰恰说明端点、鉴权、模型都是通的。
  ///
  /// 与 [complete] 不同，这里不问 [AiProviderConfig.isUsable]：停用的提供商也允许
  /// 先测再启用，缺 key 由服务端回 401 给出更具体的结论；没填模型则无从测起。
  Future<void> ping(AiProviderConfig provider) async {
    if (provider.model.trim().isEmpty) {
      throw const AiChatFailure('provider_not_configured');
    }
    final Map<Object?, Object?> body = await _postChat(
      provider,
      const <AiChatMessage>[AiChatMessage.user('ping')],
      _kPingMaxTokens,
    );
    final String topKey = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => 'choices',
      AiWireProtocol.anthropicMessages => 'content',
      AiWireProtocol.geminiGenerateContent => 'candidates',
    };
    if (body[topKey] is! List) {
      throw const AiChatFailure('bad_response');
    }
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

  /// 按协议发一次 chat 请求，返回解码后的应答对象（不解释正文）。
  Future<Map<Object?, Object?>> _postChat(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) async {
    final (Uri uri, Map<String, Object?> payload) = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => (
        _resolve(provider.baseUrl, 'chat/completions'),
        _openAiPayload(provider, messages, maxTokens),
      ),
      AiWireProtocol.anthropicMessages => (
        _resolve(provider.baseUrl, 'v1/messages'),
        _anthropicPayload(provider, messages, maxTokens),
      ),
      AiWireProtocol.geminiGenerateContent => (
        _resolve(
          provider.baseUrl,
          'models/${provider.model}:generateContent',
        ).replace(queryParameters: <String, String>{'key': provider.apiKey}),
        _geminiPayload(messages, maxTokens),
      ),
    };
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
    return body;
  }

  Map<String, Object?> _openAiPayload(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) => <String, Object?>{
    'model': provider.model,
    'messages': <Map<String, Object?>>[
      for (final AiChatMessage m in messages)
        <String, Object?>{
          'role': m.role,
          // 无图时仍发纯字符串：大量兼容端点（含部分本地服务）不认 content 数组。
          'content': m.images.isEmpty
              ? m.content
              : <Map<String, Object?>>[
                  for (final AiChatImage image in m.images)
                    <String, Object?>{
                      'type': 'image_url',
                      'image_url': <String, String>{
                        'url':
                            'data:${image.mimeType};base64,${image.base64Data}',
                      },
                    },
                  <String, Object?>{'type': 'text', 'text': m.content},
                ],
        },
    ],
    // OpenAI 官方的推理模型（o 系列 / gpt-5 系列）拒收 `max_tokens`、只认
    // `max_completion_tokens`（官方其余模型两者都认）；大量兼容端点却只认前者。
    _usesMaxCompletionTokens(provider.baseUrl)
            ? 'max_completion_tokens'
            : 'max_tokens':
        maxTokens,
    // 只有用户显式选了推理档位才发这个字段：大量兼容端点不认识它，
    // 无条件发会让本来能用的服务直接 400。
    if (provider.reasoningEffort != AiReasoningEffort.none)
      'reasoning_effort': provider.reasoningEffort.storageKey,
  };

  /// 判据是端点 host 而不是 presetId：presetId 只管 UI 显示（见
  /// [AiProviderConfig.presetId]），「自定义」里填官方地址照样要按官方规矩发，
  /// 「OpenAI」预设改指第三方中转则要按中转的规矩发。
  static bool _usesMaxCompletionTokens(Uri baseUrl) =>
      baseUrl.host.toLowerCase() == kOpenAiOfficialHost;

  Map<String, Object?> _anthropicPayload(
    AiProviderConfig provider,
    List<AiChatMessage> messages,
    int maxTokens,
  ) {
    // Anthropic 把 system 提到顶层，不放进 messages 数组。
    final String system = _systemText(messages);
    return <String, Object?>{
      'model': provider.model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': <Map<String, Object?>>[
        for (final AiChatMessage m in messages)
          if (!m.isSystem)
            <String, Object?>{
              'role': m.role,
              'content': m.images.isEmpty
                  ? m.content
                  : <Map<String, Object?>>[
                      for (final AiChatImage image in m.images)
                        <String, Object?>{
                          'type': 'image',
                          'source': <String, String>{
                            'type': 'base64',
                            'media_type': image.mimeType,
                            'data': image.base64Data,
                          },
                        },
                      <String, Object?>{'type': 'text', 'text': m.content},
                    ],
            },
      ],
    };
  }

  Map<String, Object?> _geminiPayload(
    List<AiChatMessage> messages,
    int maxTokens,
  ) {
    final String system = _systemText(messages);
    return <String, Object?>{
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
              'parts': <Map<String, Object?>>[
                for (final AiChatImage image in m.images)
                  <String, Object?>{
                    'inline_data': <String, String>{
                      'mime_type': image.mimeType,
                      'data': image.base64Data,
                    },
                  },
                <String, Object?>{'text': m.content},
              ],
            },
      ],
      'generationConfig': <String, Object?>{'maxOutputTokens': maxTokens},
    };
  }

  static String _systemText(List<AiChatMessage> messages) => messages
      .where((AiChatMessage m) => m.isSystem)
      .map((AiChatMessage m) => m.content)
      .join('\n\n');

  /// 各协议的正文抽取：形状不对返回 null，空与否由 [complete] 统一判。
  static String? _openAiText(Map<Object?, Object?> body) {
    final Object? choices = body['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final Object? first = choices.first;
    if (first is! Map) return null;
    final Object? message = first['message'];
    if (message is! Map) return null;
    final Object? content = message['content'];
    return content is String ? content : null;
  }

  static String? _anthropicText(Map<Object?, Object?> body) {
    final Object? content = body['content'];
    if (content is! List) return null;
    final StringBuffer text = StringBuffer();
    for (final Object? block in content) {
      if (block is Map && block['type'] == 'text' && block['text'] is String) {
        text.write(block['text'] as String);
      }
    }
    return text.toString();
  }

  static String? _geminiText(Map<Object?, Object?> body) {
    final Object? candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final Object? first = candidates.first;
    if (first is! Map) return null;
    final Object? content = first['content'];
    if (content is! Map) return null;
    final Object? parts = content['parts'];
    if (parts is! List) return null;
    final StringBuffer text = StringBuffer();
    for (final Object? part in parts) {
      if (part is Map && part['text'] is String) {
        text.write(part['text'] as String);
      }
    }
    return text.toString();
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
