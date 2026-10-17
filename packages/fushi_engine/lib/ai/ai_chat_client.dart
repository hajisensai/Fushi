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
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
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

/// [AiChatClient.complete] 遇到临时性失败（[AiChatFailure.isTransient]：网络抖动 /
/// 超时、429、5xx）时最多尝试几次（含第一次）。2026-10-13 用户拍板：网络波动、
/// 偶发限流不能让一批 OCR 纠错直接作废。
const int kAiChatMaxAttempts = 3;

/// 重试的指数退避基数：第 n 次重试前等 base × 2^(n-1)（2 秒、4 秒）。提供商给了
/// `Retry-After` 就按它的。
const Duration kAiChatRetryBaseDelay = Duration(seconds: 2);

/// 提供商要求等得比这还久（`Retry-After` 动辄几分钟的额度耗尽）就不在后台干等，
/// 直接报失败——那不是抖动，是额度没了。
const Duration kAiChatMaxRetryWait = Duration(seconds: 60);

/// 调用失败。[message] 是**已脱敏**的短文案，可以直接进 UI——绝不含 API Key、
/// 完整 URL 或响应体原文（后两者都可能回显凭据）。
class AiChatFailure implements Exception {
  const AiChatFailure(this.message, {this.retryAfter});

  final String message;

  /// 服务端在限流应答里给的 `Retry-After`（没有就是 null）：决定这把 key 冷却多久；
  /// 所有 key 都被限流时也是整家提供商退避多久（[AiRateLimiter.backOff]）。
  final Duration? retryAfter;

  /// 换一把 key 重试可能成功：鉴权被拒、限流、余额 / 额度不足（见
  /// [aiFailureRotatesKey]）。
  bool get rotatesKey => aiFailureRotatesKey(message);

  /// 原样重试可能成功的失败：网络 / 超时（都报 `network_error`）、限流、5xx。
  /// 鉴权失败、4xx、坏回复、空回复、未配置都是配置或模型的问题，重试也一样；
  /// `cancelled`（客户端已 `close`，排队中的请求被放弃）是调用方不要了，不重试。
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
/// 一家配了多把 key 时，每次请求都经 [_rotateKeys]：挑一把没在冷却的 key，
/// 遇到鉴权被拒 / 限流 / 额度不足就把它记进冷却、换下一把**重试当前请求**；全部
/// 失败时抛最有信息量的真实错误（[_KeyRoundFailure.reported]）。例外是 [ping]（用户点「测试连接」）：它逐把真打，
/// 冷却中的也打。健康记录存在 `healthStore`（默认全局 [aiKeyHealthStore]，app
/// 装配成持久化实现）。
class AiChatClient {
  AiChatClient({
    http.Client? client,
    AiKeyHealthStore? healthStore,
    DateTime Function()? clock,
    AiRateLimiter? rateLimiter,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _healthStore = healthStore,
       _clock = clock ?? DateTime.now,
       _rateLimiter = rateLimiter ?? AiRateLimiter.shared;

  final http.Client _client;
  final bool _ownsClient;
  final AiKeyHealthStore? _healthStore;
  final DateTime Function() _clock;

  /// 每次现取全局装配点：app 在偏好可读之后才换成持久化实现，客户端可能比那更早建。
  AiKeyHealthStore get _health => _healthStore ?? aiKeyHealthStore;

  /// 按提供商排队（[AiProviderConfig.requestsPerMinute] 与 `Retry-After`）。
  final AiRateLimiter _rateLimiter;

  /// 调用方已不要结果（[close]）：在途请求失败后不再重试。
  bool _closed = false;

  /// 本客户端在限频器里排队的请求共用的取消信号，[close] 时触发。
  final AiRateLimitCancellation _cancellation = AiRateLimitCancellation();

  /// 调用方不再要结果：还在限频器里排队的请求立即放弃（抛 `cancelled`，不占
  /// 空位），之后的 [complete] 也不再发出；在途请求失败后不再重试。
  void close() {
    _closed = true;
    _cancellation.cancel();
    if (_ownsClient) {
      _client.close();
    }
  }

  /// 发一次问答，拿回模型的纯文本回复。
  ///
  /// 三种协议同一口径：回复为空或只有空白一律抛 `empty_response`——空串对每个
  /// 调用方都是「AI 什么也没给」，当成功返回只会把失败推迟成下游的解析错误。
  ///
  /// 临时性失败（网络 / 超时、429、5xx）最多试 [kAiChatMaxAttempts] 轮，等待取指数
  /// 退避与 key 冷却到期中更晚者；退避写进限频器（[AiRateLimiter.backOff]），这家
  /// 并发在途的其它请求一起避让，不接着撞墙。要等超过 [kAiChatMaxRetryWait]、或
  /// 客户端已 [close]，不再重试、原样抛出（还在排队时被关抛 `cancelled`）。
  /// 鉴权 / 4xx / 坏回复重试也一样，直接抛。
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    if (!provider.isUsable) {
      throw const AiChatFailure('provider_not_configured');
    }
    final Map<Object?, Object?> body = await _withRetry(
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

  /// 一轮换 key（[_rotateKeys]），不重试；全部失败时抛 [_KeyRoundFailure.reported]。
  Future<T> _withKeyRotation<T>(
    AiProviderConfig provider,
    Future<T> Function(String key) attempt,
  ) async {
    try {
      return await _rotateKeys(provider, attempt);
    } on _KeyRoundFailure catch (round) {
      throw round.reported;
    }
  }

  /// 用 [provider] 的 key 依次执行 [attempt]，直到成功或这一轮没有 key 可试。
  ///
  /// - 候选是 [among]（null = 全部启用的 key）；没有任何 key（本地推理服务）时
  ///   候选只有空 key，不记健康。
  /// - **每一把**都是先 [beforeEach]（限频排队）、再按排完队那一刻的健康记录
  ///   （[orderAiKeysForRequest]）挑下一把：排队期间别的请求刚让某把 key 冷却，
  ///   这一把就不会被选中。
  /// - 冷却中的 key 只在本轮第一把、且没有别的可用 key 时真打一次（「宁可真打
  ///   一次拿回真实错误」，见 [orderAiKeysForRequest]），打完本轮结束；本轮已经有
  ///   key 失败之后，剩下的都在冷却就不再去撞。
  /// - 换 key 类失败（鉴权 / 限流 / 额度，[aiFailureRotatesKey]）：记进冷却
  ///   （[_attemptKey]），换下一把；与 key 无关的临时性失败（网络 / 5xx）：换了
  ///   也一样，本轮结束；与 key 无关的非临时性失败（4xx / 坏回复）：原样抛出。
  /// - 本轮结束仍没成功：抛 [_KeyRoundFailure]，带每把试过的 key 各自的失败原因，
  ///   由调用方决定重不重试、重试时只在哪些 key 里选。
  Future<T> _rotateKeys<T>(
    AiProviderConfig provider,
    Future<T> Function(String key) attempt, {
    Set<String>? among,
    Future<void> Function()? beforeEach,
  }) async {
    final List<String> keys = provider.activeApiKeys;
    final List<String> pool = keys.isEmpty
        ? const <String>['']
        : keys.where((String k) => among?.contains(k) ?? true).toList();
    final Map<String, AiChatFailure> failures = <String, AiChatFailure>{};
    while (true) {
      final List<String> left = pool
          .where((String k) => !failures.containsKey(k))
          .toList();
      if (left.isEmpty) break;
      await beforeEach?.call();
      final DateTime now = _clock();
      final String key = orderAiKeysForRequest(
        providerId: provider.id,
        keys: left,
        store: _health,
        now: now,
      ).first;
      final bool cooling =
          _health.read(aiKeyFingerprint(provider.id, key))?.isCoolingAt(now) ??
          false;
      if (cooling && failures.isNotEmpty) break;
      try {
        return await _attemptKey(provider, key, attempt);
      } on AiChatFailure catch (failure) {
        if (!failure.rotatesKey && !failure.isTransient) rethrow;
        failures[key] = failure;
        if (!failure.rotatesKey || cooling) break;
      }
    }
    throw _KeyRoundFailure(failures);
  }

  /// 用一把具体的 key 执行一次 [attempt]，并把结果落进健康记录；失败原样抛出。
  ///
  /// 发出前先记下这把 key 的记录（`seen`），落账走 [AiKeyHealthStore.update]，由
  /// [aiKeyHealthAfterSuccess] / [aiKeyHealthAfterFailure] 拿 `seen` 与落账时的
  /// 当前值比较：同一把 key 上并发的请求不会把一阵限流记成多次失败，按旧视图
  /// 发出的成功也不会抹掉别处刚记的冷却。只有换 key 类失败（[aiFailureRotatesKey]）
  /// 才记冷却。[key] 为空（本地推理服务没有 key）时不记健康。
  ///
  /// 限频排队必须在调用本函数**之前**完成（[_rotateKeys] 的 `beforeEach`）：`seen`
  /// 若在排队前读，排队期间别处记下的失败会被当成「同一阵限流」，不再累加。
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

  /// 一次 [complete] 的完整发送：外层是临时性失败的退避重试，内层每一轮都经
  /// [_rotateKeys] 换 key，每把 key 真正发出前先在限频器排队（[_acquire]）。
  ///
  /// 某把 key 被限流只让**这把 key** 冷却（[_attemptKey]），轮换照常换下一把，不把
  /// 整家提供商拖进 `Retry-After`；只有一轮里所有候选 key 都失败、其中又有临时性
  /// 失败（限流、网络、5xx）时，才按 [_retryDelay] 让整家退避——这时并发在途的其它
  /// 请求本来也会撞同一堵墙。下一轮只在上一轮**因临时性原因**失败的 key 里选：
  /// 鉴权被拒 / 额度用尽的 key 在这次请求里不再试，最终报错也不会被它们顶替。
  Future<T> _withRetry<T>(
    AiProviderConfig provider,
    Future<T> Function(String key) send,
  ) async {
    Set<String>? among;
    for (int round = 1; ; round++) {
      try {
        return await _rotateKeys(
          provider,
          send,
          among: among,
          beforeEach: () => _acquire(provider),
        );
      } on _KeyRoundFailure catch (failed) {
        final Duration? wait = _retryDelay(provider, failed, round);
        if (wait == null) {
          // 放弃这次请求也要让整家先停一会儿：否则下一个请求立刻拿到空位、再撞同
          // 一堵墙（单 key 时冷却拦不住它，见 [orderAiKeysForRequest]）——漫画 AI
          // OCR 曾因此一页接一页地吃 429。暂停封顶 [kAiChatMaxRetryWait]：之后的
          // 请求仍然真的发出去（不凭本地冷却编失败），只是不再挤成一串。
          final Duration? cooling = _untilSoonestReady(provider, failed);
          if (cooling != null) {
            _rateLimiter.backOff(
              provider,
              cooling > kAiChatMaxRetryWait ? kAiChatMaxRetryWait : cooling,
            );
          }
          throw failed.reported;
        }
        _rateLimiter.backOff(provider, wait);
        among = failed.transientKeys;
      }
    }
  }

  /// 在限频器排到这家的空位；[close] 之后（含排队途中被关）抛 `cancelled`。
  Future<void> _acquire(AiProviderConfig provider) async {
    if (!await _rateLimiter.acquire(provider, cancellation: _cancellation)) {
      throw const AiChatFailure('cancelled');
    }
  }

  /// 第 [round] 轮失败后还要不要再试、等多久；null = 不再试。
  ///
  /// 等待取「指数退避」与「上一轮因临时性原因失败的 key 里最早能再试的时刻」中
  /// 更晚的那个：一把 429 没带 `Retry-After` 的 key 冷却一分钟，2 秒后重打只会
  /// 撞在冷却上、把冷却越推越长。要等超过 [kAiChatMaxRetryWait] 就不在后台干等。
  Duration? _retryDelay(
    AiProviderConfig provider,
    _KeyRoundFailure failed,
    int round,
  ) {
    if (_closed || round >= kAiChatMaxAttempts) return null;
    final Duration? untilReady = _untilSoonestReady(provider, failed);
    if (untilReady == null) return null;
    final Duration backoff = kAiChatRetryBaseDelay * (1 << (round - 1));
    final Duration wait = untilReady > backoff ? untilReady : backoff;
    return wait > kAiChatMaxRetryWait ? null : wait;
  }

  /// 上一轮因临时性原因失败的 key 里，最早那把还要多久能再试；没有临时性失败
  /// （全是鉴权被拒 / 额度用尽）为 null。
  Duration? _untilSoonestReady(
    AiProviderConfig provider,
    _KeyRoundFailure failed,
  ) {
    DateTime? soonest;
    for (final String key in failed.transientKeys) {
      final DateTime ready = _keyReadyAt(provider, key, failed.failures[key]!);
      if (soonest == null || ready.isBefore(soonest)) soonest = ready;
    }
    return soonest?.difference(_clock());
  }

  /// 这把 key 刚以 [failure] 失败，何时能再试：冷却记录与应答里 `Retry-After`
  /// 两者更晚的那个（没有 key 的本地服务没有冷却记录，只看后者）。
  DateTime _keyReadyAt(
    AiProviderConfig provider,
    String key,
    AiChatFailure failure,
  ) {
    final DateTime now = _clock();
    final DateTime byReply = now.add(failure.retryAfter ?? Duration.zero);
    final DateTime? byHealth = _health
        .read(aiKeyFingerprint(provider.id, key))
        ?.cooldownUntil;
    return byHealth != null && byHealth.isAfter(byReply) ? byHealth : byReply;
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

/// 一轮换 key 没有成功（[AiChatClient._rotateKeys]）：每把试过的 key 各自因什么
/// 失败，按尝试顺序（没有 key 的本地服务记在空串下）。至少有一条。
class _KeyRoundFailure implements Exception {
  _KeyRoundFailure(this.failures) : assert(failures.isNotEmpty);

  final Map<String, AiChatFailure> failures;

  /// 因临时性原因（限流 / 网络 / 5xx）失败、过一会儿可能就好的 key。
  Set<String> get transientKeys => <String>{
    for (final MapEntry<String, AiChatFailure> e in failures.entries)
      if (e.value.isTransient) e.key,
  };

  /// 这次请求最终报给调用方的错误：有临时性失败时报最后一个临时性失败——请求
  /// 是被它挡住的（「限流了，稍后再试」），某把失效 key 的 `unauthorized` 只说明
  /// 那一把的问题，不能顶替它；全是 key 本身的问题时报最后一个。
  AiChatFailure get reported => failures.values.lastWhere(
    (AiChatFailure f) => f.isTransient,
    orElse: () => failures.values.last,
  );
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
