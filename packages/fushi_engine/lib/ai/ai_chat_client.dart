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

import 'package:fushi_engine/ai/ai_key_rotation.dart';
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
  const AiChatFailure(this.message, {this.retryAfter});

  final String message;

  /// 服务端在限流应答里给的 `Retry-After`（没有就是 null），决定这把 key 冷却多久。
  final Duration? retryAfter;

  /// 换一把 key 重试可能成功：鉴权被拒、限流、余额 / 额度不足（见
  /// [aiFailureRotatesKey]）。
  bool get rotatesKey => aiFailureRotatesKey(message);

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
///
/// 一家配了多把 key 时，每次请求都经 [_withKeyRotation]：挑一把没在冷却的 key，
/// 遇到鉴权被拒 / 限流 / 额度不足就把它记进冷却、换下一把**重试当前请求**；全部
/// 失败时抛最后一把的真实错误。例外是 [ping]（用户点「测试连接」）：它逐把真打，
/// 冷却中的也打。健康记录存在 `healthStore`（默认全局 [aiKeyHealthStore]，app
/// 装配成持久化实现）。
class AiChatClient {
  AiChatClient({
    http.Client? client,
    AiKeyHealthStore? healthStore,
    DateTime Function()? clock,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _healthStore = healthStore,
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final AiKeyHealthStore? _healthStore;
  final DateTime Function() _clock;

  /// 每次现取全局装配点：app 在偏好可读之后才换成持久化实现，客户端可能比那更早建。
  AiKeyHealthStore get _health => _healthStore ?? aiKeyHealthStore;

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
    final Map<Object?, Object?> body = await _withKeyRotation(
      provider,
      (String key) => _postChat(provider, key, messages, maxTokens),
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
  ///
  /// 配了多把 key 时**每一把启用的 key 都真打一次**（按用户排的顺序，冷却中的也
  /// 打）：这是用户的显式自检，不是功能请求——余额不足被退避到几小时后的 key，
  /// 用户充值后点「测试连接」就该被重新验证、成功即清掉冷却；按轮换顺序只测第一把
  /// 能用的，会让它一直冷却到期。每把的结果照常落进健康记录（设置页框下的状态随之
  /// 刷新）。至少一把通过即成功；全部是换 key 类失败时抛最后一个真实错误；与 key
  /// 无关的失败（网络 / 5xx / 坏回复 / 模型不对）立即原样抛出。
  Future<void> ping(AiProviderConfig provider) async {
    if (provider.model.trim().isEmpty) {
      throw const AiChatFailure('provider_not_configured');
    }
    final String topKey = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => 'choices',
      AiWireProtocol.anthropicMessages => 'content',
      AiWireProtocol.geminiGenerateContent => 'candidates',
    };
    final List<String> keys = provider.activeApiKeys;
    final List<String> probes = keys.isEmpty ? const <String>[''] : keys;
    AiChatFailure? last;
    bool anyOk = false;
    for (final String key in probes) {
      try {
        await _attemptKey(provider, key, (String probeKey) async {
          final Map<Object?, Object?> body = await _postChat(
            provider,
            probeKey,
            const <AiChatMessage>[AiChatMessage.user('ping')],
            _kPingMaxTokens,
          );
          if (body[topKey] is! List) {
            throw const AiChatFailure('bad_response');
          }
        });
        anyOk = true;
      } on AiChatFailure catch (failure) {
        if (!failure.rotatesKey) {
          rethrow;
        }
        last = failure;
      }
    }
    if (!anyOk) {
      throw last!;
    }
  }

  /// 拉这家提供商可用的模型名。
  ///
  /// 存在的理由：内置预设里的默认模型名**必然过时**（厂商迭代比本 app 发版快），
  /// 把用户钉死在一个写死的字符串上迟早变成「开箱即 404」。
  Future<List<String>> listModels(AiProviderConfig provider) =>
      _withKeyRotation(provider, (String key) => _listModels(provider, key));

  Future<List<String>> _listModels(
    AiProviderConfig provider,
    String key,
  ) async {
    final Uri uri = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => _resolve(provider.baseUrl, 'models'),
      AiWireProtocol.anthropicMessages => _resolve(
        provider.baseUrl,
        'v1/models',
      ),
      AiWireProtocol.geminiGenerateContent => _resolve(
        provider.baseUrl,
        'models',
      ).replace(queryParameters: <String, String>{'key': key}),
    };
    final http.Response response = await _send(
      () => _client.get(uri, headers: _headers(provider, key)),
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
  // 多 key 轮换
  // -------------------------------------------------------------------------

  /// 用 [provider] 的 key 依次执行 [attempt]，直到成功或 key 用完。
  ///
  /// - 没有任何 key（本地推理服务）：以空 key 执行一次，不记健康。
  /// - 失败码不属于「换 key 可能就好」（网络 / 5xx / 坏回复…）：原样抛出，不换 key
  ///   ——那与 key 无关，换了也是同一个错误。
  /// - 属于：把这把 key 记进冷却（`Retry-After` 优先，否则指数退避），换下一把；
  ///   全部试完仍失败就抛**最后一个真实错误**。每把 key 至多试一次，不会无限重试。
  /// - 成功：清掉这把 key 的冷却记录（除非发出之后别的请求刚给它记了失败）。
  Future<T> _withKeyRotation<T>(
    AiProviderConfig provider,
    Future<T> Function(String key) attempt,
  ) async {
    final List<String> keys = provider.activeApiKeys;
    if (keys.isEmpty) {
      return attempt('');
    }
    final List<String> order = orderAiKeysForRequest(
      providerId: provider.id,
      keys: keys,
      store: _health,
      now: _clock(),
    );
    AiChatFailure? last;
    for (final String key in order) {
      try {
        return await _attemptKey(provider, key, attempt);
      } on AiChatFailure catch (failure) {
        if (!failure.rotatesKey) {
          rethrow;
        }
        last = failure;
      }
    }
    // keys 非空时 orderAiKeysForRequest 至少给一把，走到这里 last 必有值。
    throw last!;
  }

  /// 用一把具体的 key 执行一次 [attempt]，并把结果落进健康记录；失败原样抛出。
  ///
  /// 发出前先记下这把 key 的记录（`seen`），落账走 [AiKeyHealthStore.update]，由
  /// [aiKeyHealthAfterSuccess] / [aiKeyHealthAfterFailure] 拿 `seen` 与落账时的
  /// 当前值比较：同一把 key 上并发的请求不会把一阵限流记成多次失败，按旧视图
  /// 发出的成功也不会抹掉别处刚记的冷却。只有换 key 类失败（[aiFailureRotatesKey]）
  /// 才记冷却。[key] 为空（本地推理服务没有 key）时不记健康。
  Future<T> _attemptKey<T>(
    AiProviderConfig provider,
    String key,
    Future<T> Function(String key) attempt,
  ) async {
    if (key.isEmpty) {
      return attempt(key);
    }
    final AiKeyHealthStore store = _health;
    final String fingerprint = aiKeyFingerprint(provider.id, key);
    final AiKeyHealth? seen = store.read(fingerprint);
    try {
      final T result = await attempt(key);
      store.update(
        fingerprint,
        (AiKeyHealth? current) =>
            aiKeyHealthAfterSuccess(seen: seen, current: current),
      );
      return result;
    } on AiChatFailure catch (failure) {
      if (failure.rotatesKey) {
        final DateTime now = _clock();
        store.update(
          fingerprint,
          (AiKeyHealth? current) => aiKeyHealthAfterFailure(
            seen: seen,
            current: current,
            reason: failure.message,
            retryAfter: failure.retryAfter,
            now: now,
          ),
        );
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // 各协议实现
  // -------------------------------------------------------------------------

  /// 按协议发一次 chat 请求，返回解码后的应答对象（不解释正文）。
  Future<Map<Object?, Object?>> _postChat(
    AiProviderConfig provider,
    String key,
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
        ).replace(queryParameters: <String, String>{'key': key}),
        _geminiPayload(messages, maxTokens),
      ),
    };
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: _headers(provider, key),
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

  Map<String, String> _headers(AiProviderConfig provider, String key) {
    final Map<String, String> headers = <String, String>{
      'content-type': 'application/json',
    };
    switch (provider.protocol) {
      case AiWireProtocol.openAiCompatible:
        if (key.isNotEmpty) {
          headers['authorization'] = 'Bearer $key';
        }
      case AiWireProtocol.anthropicMessages:
        headers['x-api-key'] = key;
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
    if (response.statusCode >= 400) {
      throw classifyAiHttpFailure(
        statusCode: response.statusCode,
        bodyBytes: response.bodyBytes,
        retryAfterHeader: response.headers['retry-after'],
        now: _clock(),
      );
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

/// 应答体里只看开头这么多字节找特征词：错误体都很短，没必要整份解码。
const int _kFailureBodyScanBytes = 4096;

/// 余额 / 额度用尽的特征词（各家错误体里的 code 或 message 片段，小写比较）：
/// - OpenAI：`insufficient_quota`、`billing_hard_limit_reached`、`billing_not_active`；
/// - DeepSeek 等：`Insufficient Balance` / 「余额不足」；SiliconFlow：「balance is
///   insufficient」；
/// - Anthropic：「credit balance is too low」；OpenRouter：「requires more credits」；
/// - Moonshot：`exceeded_current_quota_error`；阿里云百炼：`Arrearage`；智谱：「欠费」。
///
/// **只收明确的错误码 / 短语**，不收裸词 `billing`：Gemini 的**普通限流** 429
/// （RESOURCE_EXHAUSTED）正文就写着「check your plan and billing details」，裸词
/// 命中会把一次过几十秒就好的限流当成余额耗尽——丢掉限流语义、按失败次数指数
/// 退避；任何正文里提到 billing 的无关 400 也会被误判。
const List<String> _kQuotaMarkers = <String>[
  'insufficient_quota',
  'insufficient quota',
  'insufficient_balance',
  'insufficient balance',
  'balance is insufficient',
  'credit balance',
  'more credits',
  'billing_hard_limit_reached',
  'billing_not_active',
  'exceeded_current_quota_error',
  'arrearage',
  '余额不足',
  '欠费',
];

/// key 本身无效的特征词：Gemini 对坏 key 回的是 **400** `API_KEY_INVALID`
/// （「API key not valid」），只看状态码认不出是鉴权问题。
const List<String> _kInvalidKeyMarkers = <String>[
  'api_key_invalid',
  'api key not valid',
  'invalid_api_key',
  'invalid api key',
  'incorrect api key',
];

/// 把一个 ≥400 的应答归成脱敏短码（绝不带出响应体原文）。
///
/// - 402，或 400/403/429 且体里有余额特征词 → `quota_exhausted`（换 key 重试）；
/// - 401 / 403，或 400 且体里有坏 key 特征词 → `unauthorized`（换 key 重试）；
/// - 429 → `rate_limited`，带上 `Retry-After`（换 key 重试，这把按它冷却）；
/// - 其余 → `http_<状态码>`（与 key 无关，不换 key）。
///
/// 余额判据排在限流之前：OpenAI 额度用尽回的是 429 `insufficient_quota`，按限流
/// 处理会把它当成「过一会儿就好」。
AiChatFailure classifyAiHttpFailure({
  required int statusCode,
  required List<int> bodyBytes,
  required String? retryAfterHeader,
  required DateTime now,
}) {
  final String body = utf8
      .decode(
        bodyBytes.length > _kFailureBodyScanBytes
            ? bodyBytes.sublist(0, _kFailureBodyScanBytes)
            : bodyBytes,
        allowMalformed: true,
      )
      .toLowerCase();
  bool has(List<String> markers) => markers.any(body.contains);
  if (statusCode == 402 ||
      ((statusCode == 400 || statusCode == 403 || statusCode == 429) &&
          has(_kQuotaMarkers))) {
    return const AiChatFailure('quota_exhausted');
  }
  if (statusCode == 401 ||
      statusCode == 403 ||
      (statusCode == 400 && has(_kInvalidKeyMarkers))) {
    return const AiChatFailure('unauthorized');
  }
  if (statusCode == 429) {
    return AiChatFailure(
      'rate_limited',
      retryAfter: parseRetryAfter(retryAfterHeader, now),
    );
  }
  return AiChatFailure('http_$statusCode');
}
