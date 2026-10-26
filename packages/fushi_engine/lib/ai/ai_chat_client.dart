/// AI 提供商的调用层：一次性问答 + 模型列表。
///
/// 三种 wire 协议（OpenAI 兼容 / Anthropic Messages / Gemini generateContent）在
/// 这里分派，上层只面对 [AiChatClient.complete]（一次性问答）与 [AiChatClient.chat]
/// （带原生 tool calling 的一轮对话，AI 助手的 agent loop 用）。**不做流式**：本仓
/// 当前的 AI 用途是「生成一条规则/一段配置」这种短请求，流式只会把 UI 状态机复杂化。
///
/// 出站一律经 `createAppHttpIoClient()`——裸 `http.Client()` 既绕过应用代理与连接
/// 超时（代理环境下会出现「浏览器能开、app 里连不上」这种自相矛盾的结果），也会被
/// `test/tools/outbound_http_discipline_guard_test.dart` 的登记制守卫判红。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

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

/// [AiChatClient.transcribeAudio] 一次请求的整体时限：上传一个音频分片（低码率
/// 十分钟约 2–3 MB，慢速移动网络要几十秒）再加服务端解码。
const Duration kAiTranscriptionRequestTimeout = Duration(minutes: 5);

/// 提供商协议没有语音转录端点（只有 OpenAI 兼容协议有 `/audio/transcriptions`）。
const String kAiTranscriptionUnsupportedProtocol = 'unsupported_protocol';

/// multipart 表单分隔串：随机 32 位十六进制，撞上音频字节的概率可忽略。
String aiMultipartBoundary() {
  final math.Random random = math.Random.secure();
  final StringBuffer sb = StringBuffer('----fushi');
  for (int i = 0; i < 32; i++) {
    sb.write(random.nextInt(16).toRadixString(16));
  }
  return sb.toString();
}

/// 手拼 `multipart/form-data` 请求体（RFC 7578）：普通字段按 [fields] 顺序（允许
/// 同名重复——`http.MultipartRequest.fields` 是 Map，装不下 OpenAI 的
/// `timestamp_granularities[]` 数组写法），最后一个文件字段。
List<int> encodeAiMultipartForm({
  required String boundary,
  required List<(String, String)> fields,
  required String fileField,
  required String fileName,
  required String fileContentType,
  required List<int> fileBytes,
}) {
  final BytesBuilder out = BytesBuilder(copy: false);
  void line(String text) => out.add(utf8.encode('$text\r\n'));
  String quote(String value) =>
      value.replaceAll('\r', ' ').replaceAll('\n', ' ').replaceAll('"', '%22');
  for (final (String name, String value) in fields) {
    line('--$boundary');
    line('Content-Disposition: form-data; name="${quote(name)}"');
    line('');
    line(value);
  }
  line('--$boundary');
  line(
    'Content-Disposition: form-data; name="${quote(fileField)}"; '
    'filename="${quote(fileName)}"',
  );
  line('Content-Type: $fileContentType');
  line('');
  out.add(fileBytes);
  out.add(utf8.encode('\r\n--$boundary--\r\n'));
  return out.takeBytes();
}

/// 一次应答报告的 token 用量。
///
/// 每个字段都可空：null = 这家没报这一项（**不是 0**）。四项互不重叠——
/// [inputTokens] 是**没走缓存**的输入：
/// - Anthropic：`input_tokens` / `output_tokens` / `cache_read_input_tokens` /
///   `cache_creation_input_tokens`，本来就分开报；
/// - OpenAI 兼容：`prompt_tokens` 含命中缓存的部分，有
///   `prompt_tokens_details.cached_tokens`（OpenAI）或 `prompt_cache_hit_tokens`
///   （DeepSeek）时减掉它记进 [cacheReadTokens]；都没有时 [inputTokens] 就是
///   `prompt_tokens`、[cacheReadTokens] 为 null。没有「缓存写入」的概念，
///   [cacheWriteTokens] 恒 null；
/// - Gemini：`usageMetadata.promptTokenCount` 同样含 `cachedContentTokenCount`，
///   照上面减；[outputTokens] = `candidatesTokenCount` + `thoughtsTokenCount`
///   （思考按输出计费）。
class AiChatUsage {
  const AiChatUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
  });

  factory AiChatUsage.fromJson(Map<String, Object?> json) => AiChatUsage(
    inputTokens: _jsonInt(json['input']),
    outputTokens: _jsonInt(json['output']),
    cacheReadTokens: _jsonInt(json['cacheRead']),
    cacheWriteTokens: _jsonInt(json['cacheWrite']),
  );

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  /// 四项全为 null（应答里有 usage 段但一个认得的字段都没有）。
  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      cacheReadTokens == null &&
      cacheWriteTokens == null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (inputTokens != null) 'input': inputTokens,
    if (outputTokens != null) 'output': outputTokens,
    if (cacheReadTokens != null) 'cacheRead': cacheReadTokens,
    if (cacheWriteTokens != null) 'cacheWrite': cacheWriteTokens,
  };

  @override
  bool operator ==(Object other) =>
      other is AiChatUsage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.cacheReadTokens == cacheReadTokens &&
      other.cacheWriteTokens == cacheWriteTokens;

  @override
  int get hashCode =>
      Object.hash(inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens);

  @override
  String toString() => 'AiChatUsage(${toJson()})';
}

int? _jsonInt(Object? value) => switch (value) {
  final int v when v >= 0 => v,
  final double v when v.isFinite && v >= 0 => v.round(),
  _ => null,
};

/// [AiChatClient.completeWithUsage] 的结果：正文 + 用量（取不到为 null）。
class AiChatCompletion {
  const AiChatCompletion({required this.text, this.usage});

  final String text;
  final AiChatUsage? usage;
}

/// 一个给模型调用的工具。[parameters] 是 JSON Schema（object 类型）。
///
/// 三家协议共用这一份描述：OpenAI 包成 `{type: function, function: {...}}`、
/// Anthropic 叫 `input_schema`、Gemini 放进 `functionDeclarations` 并先经
/// [sanitizeGeminiToolSchema] 去掉它不认的关键字。
class AiChatToolSpec {
  const AiChatToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

/// 模型发起的一次工具调用。
class AiChatToolCall {
  const AiChatToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.providerMeta = const <String, Object?>{},
  });

  /// OpenAI / Anthropic 用服务端给的 id；Gemini 没给 id 时本地按本轮序号生成
  /// `call_<序号>`（Gemini 回传结果按 [name] 对应，不需要 id）。
  final String id;
  final String name;

  /// 解析好的参数。OpenAI 的 `arguments` 是 JSON 字符串，解析失败（或不是对象）
  /// 时给 `{'_raw': 原串}`——坏参数交给执行层当一次失败的工具调用回报给模型，
  /// 不在这里抛掉整轮。
  final Map<String, Object?> arguments;

  /// 回传给同一家时需要原样带回的不透明字段（如 Gemini 的 `thoughtSignature`）。
  final Map<String, Object?> providerMeta;
}

/// [AiChatClient.chat] 的结果：一轮应答的正文 + 工具调用 + 用量。
class AiChatTurn {
  const AiChatTurn({
    required this.text,
    required this.toolCalls,
    this.usage,
    this.stopReason,
  });

  /// 可为空串（只调工具时）。
  final String text;
  final List<AiChatToolCall> toolCalls;
  final AiChatUsage? usage;

  /// 原样的 `finish_reason`（OpenAI）/ `stop_reason`（Anthropic）/
  /// `finishReason`（Gemini）；应答里没有时为 null。
  final String? stopReason;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// Gemini `functionDeclarations[].parameters` 不认的 JSON Schema 关键字。
///
/// Gemini 只收 OpenAPI 3 schema 的一个子集，带上这些键整个请求 400。
const Set<String> _kGeminiUnsupportedSchemaKeys = <String>{
  'additionalProperties',
  r'$schema',
  r'$id',
  r'$comment',
  'default',
  'examples',
};

/// 把一份 JSON Schema 净化成 Gemini 认的形状：递归去掉
/// [_kGeminiUnsupportedSchemaKeys]。
///
/// 只剥 **schema 关键字**：`properties` 底下的键是参数名（参数完全可以叫
/// `default`），只递归它们的值；`items` / `anyOf` / `oneOf` / `allOf` 的元素按
/// 子 schema 递归。只对 Gemini 用，另两家原样发。
Map<String, Object?> sanitizeGeminiToolSchema(Map<Object?, Object?> schema) {
  Object? sub(Object? value) =>
      value is Map ? sanitizeGeminiToolSchema(value) : value;
  final Map<String, Object?> out = <String, Object?>{};
  for (final MapEntry<Object?, Object?> e in schema.entries) {
    final Object? key = e.key;
    if (key is! String || _kGeminiUnsupportedSchemaKeys.contains(key)) {
      continue;
    }
    final Object? value = e.value;
    out[key] = switch (key) {
      'properties' when value is Map => <String, Object?>{
        for (final MapEntry<Object?, Object?> p in value.entries)
          '${p.key}': sub(p.value),
      },
      'items' => value is List ? value.map(sub).toList() : sub(value),
      'anyOf' ||
      'oneOf' ||
      'allOf' when value is List => value.map(sub).toList(),
      _ => value,
    };
  }
  return out;
}

/// 按协议从应答体里取用量；没有 usage 段或一个认得的字段都没有时为 null。
AiChatUsage? parseAiChatUsage(
  AiWireProtocol protocol,
  Map<Object?, Object?> body,
) {
  final AiChatUsage usage;
  switch (protocol) {
    case AiWireProtocol.anthropicMessages:
      final Object? u = body['usage'];
      if (u is! Map) return null;
      usage = AiChatUsage(
        inputTokens: _jsonInt(u['input_tokens']),
        outputTokens: _jsonInt(u['output_tokens']),
        cacheReadTokens: _jsonInt(u['cache_read_input_tokens']),
        cacheWriteTokens: _jsonInt(u['cache_creation_input_tokens']),
      );
    case AiWireProtocol.openAiCompatible:
      final Object? u = body['usage'];
      if (u is! Map) return null;
      final int? prompt = _jsonInt(u['prompt_tokens']);
      final Object? details = u['prompt_tokens_details'];
      final int? cached =
          (details is Map ? _jsonInt(details['cached_tokens']) : null) ??
          _jsonInt(u['prompt_cache_hit_tokens']);
      usage = AiChatUsage(
        inputTokens: prompt == null
            ? _jsonInt(u['prompt_cache_miss_tokens'])
            : cached == null
            ? prompt
            : (prompt - cached).clamp(0, prompt),
        outputTokens: _jsonInt(u['completion_tokens']),
        cacheReadTokens: cached,
      );
    case AiWireProtocol.geminiGenerateContent:
      final Object? u = body['usageMetadata'];
      if (u is! Map) return null;
      final int? prompt = _jsonInt(u['promptTokenCount']);
      final int? cached = _jsonInt(u['cachedContentTokenCount']);
      final int? candidates = _jsonInt(u['candidatesTokenCount']);
      final int? thoughts = _jsonInt(u['thoughtsTokenCount']);
      usage = AiChatUsage(
        inputTokens: prompt == null
            ? null
            : cached == null
            ? prompt
            : (prompt - cached).clamp(0, prompt),
        outputTokens: candidates == null && thoughts == null
            ? null
            : (candidates ?? 0) + (thoughts ?? 0),
        cacheReadTokens: cached,
      );
  }
  return usage.isEmpty ? null : usage;
}

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
  /// [cacheable]：这段 system 是调用方保证**逐字稳定**的前缀（同一批任务的每次请求
  /// 都一样），值得让提供商缓存。Anthropic 协议据此给这一块挂
  /// `cache_control: {type: ephemeral}`（显式断点，Anthropic 不会自己缓存）；
  /// OpenAI 兼容 / DeepSeek / Gemini 按请求前缀自动缓存，不需要标记——只要前缀稳定。
  const AiChatMessage.system(this.content, {this.cacheable = false})
    : role = 'system',
      images = const <AiChatImage>[],
      toolCalls = const <AiChatToolCall>[],
      toolCallId = null,
      toolName = null,
      isError = false;

  /// [images] 只对 user 消息有意义：三家协议都只在用户回合收图。
  const AiChatMessage.user(this.content, {this.images = const <AiChatImage>[]})
    : role = 'user',
      cacheable = false,
      toolCalls = const <AiChatToolCall>[],
      toolCallId = null,
      toolName = null,
      isError = false;
  const AiChatMessage.assistant(this.content)
    : role = 'assistant',
      images = const <AiChatImage>[],
      cacheable = false,
      toolCalls = const <AiChatToolCall>[],
      toolCallId = null,
      toolName = null,
      isError = false;

  /// 模型上一轮发起了工具调用的那条 assistant 消息（原样回放进历史）。
  /// [content] 是同一轮的正文，可为空串。
  const AiChatMessage.assistantToolCalls(this.content, this.toolCalls)
    : role = 'assistant',
      images = const <AiChatImage>[],
      cacheable = false,
      toolCallId = null,
      toolName = null,
      isError = false;

  /// 一次工具调用的执行结果。[toolCallId] 对应 [AiChatToolCall.id]（OpenAI /
  /// Anthropic 按它配对），[toolName] 对应 [AiChatToolCall.name]（Gemini 按名配对）。
  /// [isError]：执行失败，Anthropic 发 `is_error: true`，Gemini 在 response 里带
  /// `error: true`；OpenAI 协议没有对应字段，失败信息只在 [content] 里。
  const AiChatMessage.toolResult({
    required String this.toolCallId,
    required String this.toolName,
    required this.content,
    this.isError = false,
  }) : role = 'tool',
       images = const <AiChatImage>[],
       cacheable = false,
       toolCalls = const <AiChatToolCall>[];

  /// `system` / `user` / `assistant` / `tool`。
  final String role;
  final String content;

  /// 附图；非空时按各协议的多模态形状发（文字段在图之后）。
  final List<AiChatImage> images;

  /// 只对 system 消息有意义，见 [AiChatMessage.system]。
  final bool cacheable;

  /// 只对 [AiChatMessage.assistantToolCalls] 非空。
  final List<AiChatToolCall> toolCalls;

  /// 以下三项只对 [AiChatMessage.toolResult] 有意义。
  final String? toolCallId;
  final String? toolName;
  final bool isError;

  bool get isSystem => role == 'system';

  bool get isToolResult => role == 'tool';

  bool get hasToolCalls => toolCalls.isNotEmpty;
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
  ///
  /// 只要正文的调用方用这个；要记账（token 用量）的用 [completeWithUsage]。
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async => (await completeWithUsage(
    provider: provider,
    messages: messages,
    maxTokens: maxTokens,
  )).text;

  /// 同 [complete]，另外带回这次应答报告的 token 用量（[AiChatCompletion.usage]）。
  ///
  /// 失败语义与 [complete] 完全一致（空正文同样抛 `empty_response`）。应答里没有
  /// 用量字段时 `usage` 为 null——**不是 0**：费用统计要把它当「未知」单独计数。
  Future<AiChatCompletion> completeWithUsage({
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
    return AiChatCompletion(
      text: text,
      usage: parseAiChatUsage(provider.protocol, body),
    );
  }

  /// 一轮带工具的对话：发 [messages]（可含 [AiChatMessage.assistantToolCalls] /
  /// [AiChatMessage.toolResult] 回放的历史）与 [tools]，拿回正文 + 工具调用。
  ///
  /// 发送路径与 [completeWithUsage] 完全同一条（限频、key 轮换、临时性失败退避）。
  /// [tools] 为空时请求体与 [complete] 逐字相同。不发 `tool_choice`，由模型自己决定
  /// 调不调工具。
  ///
  /// 只调工具、没有正文是合法的一轮；正文为空（或只有空白）**且**没有工具调用时抛
  /// `empty_response`。是否该给这家发 [tools] 由调用方问
  /// [AiProviderConfig.supportsToolCalling]，这里不拦。
  Future<AiChatTurn> chat({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    List<AiChatToolSpec> tools = const <AiChatToolSpec>[],
    int maxTokens = 4096,
  }) async {
    if (!provider.isUsable) {
      throw const AiChatFailure('provider_not_configured');
    }
    final Map<Object?, Object?> body = await _withRetry(
      provider,
      (String key) => _postChat(provider, key, messages, maxTokens, tools),
    );
    final (
      String? text,
      List<AiChatToolCall> calls,
      String? stop,
    ) = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => (
        _openAiText(body),
        _openAiToolCalls(body),
        _openAiStopReason(body),
      ),
      AiWireProtocol.anthropicMessages => (
        _anthropicText(body),
        _anthropicToolCalls(body),
        body['stop_reason'] is String ? body['stop_reason'] as String : null,
      ),
      AiWireProtocol.geminiGenerateContent => (
        _geminiText(body),
        _geminiToolCalls(body),
        _geminiStopReason(body),
      ),
    };
    final String content = text ?? '';
    if (content.trim().isEmpty && calls.isEmpty) {
      throw const AiChatFailure('empty_response');
    }
    return AiChatTurn(
      text: content,
      toolCalls: List<AiChatToolCall>.unmodifiable(calls),
      usage: parseAiChatUsage(provider.protocol, body),
      stopReason: stop,
    );
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

  /// 云端语音转录：一段音频发到 OpenAI 兼容的 `POST {baseUrl}/audio/transcriptions`
  /// （OpenAI Whisper、Groq 等），返回解码后的 `verbose_json` 应答（含 `segments`，
  /// 端点支持时还有逐词 `words`）。模型名取 [AiProviderConfig.model]——给转录用的
  /// 那家提供商填的就是 Whisper 模型（如 Groq 的 `whisper-large-v3`）。
  ///
  /// 与 [completeWithUsage] 同一套 key 轮换、限频与临时性失败退避（[_withRetry]），
  /// 失败同样只抛脱敏短码。只有 OpenAI 兼容协议有这个端点，其余协议抛
  /// `unsupported_protocol`。单次上传大小由调用方控制（Groq 免费档 25 MB）。
  ///
  /// [language]：ISO-639 语言码（`ja` / `en` …），不传由服务端自动识别。
  /// [prompt]：Whisper 的提示文本（专名 / 文风示例），不传就不发。
  Future<Map<Object?, Object?>> transcribeAudio({
    required AiProviderConfig provider,
    required List<int> audioBytes,
    required String fileName,
    required String contentType,
    String? language,
    String? prompt,
  }) async {
    if (provider.protocol != AiWireProtocol.openAiCompatible) {
      throw const AiChatFailure(kAiTranscriptionUnsupportedProtocol);
    }
    if (!provider.isUsable) {
      throw const AiChatFailure('provider_not_configured');
    }
    return _withRetry(
      provider,
      (String key) => _postTranscription(
        provider,
        key,
        audioBytes: audioBytes,
        fileName: fileName,
        contentType: contentType,
        language: language,
        prompt: prompt,
      ),
    );
  }

  Future<Map<Object?, Object?>> _postTranscription(
    AiProviderConfig provider,
    String key, {
    required List<int> audioBytes,
    required String fileName,
    required String contentType,
    String? language,
    String? prompt,
  }) async {
    final String boundary = aiMultipartBoundary();
    final List<int> body = encodeAiMultipartForm(
      boundary: boundary,
      fields: <(String, String)>[
        ('model', provider.model.trim()),
        ('response_format', 'verbose_json'),
        // 同名字段要发两次（OpenAI 的数组写法）：Map 装不下，所以表单手拼。
        ('timestamp_granularities[]', 'segment'),
        ('timestamp_granularities[]', 'word'),
        ('temperature', '0'),
        if (language != null && language.trim().isNotEmpty)
          ('language', language.trim()),
        if (prompt != null && prompt.trim().isNotEmpty)
          ('prompt', prompt.trim()),
      ],
      fileField: 'file',
      fileName: fileName,
      fileContentType: contentType,
      fileBytes: audioBytes,
    );
    final Map<String, String> headers = _headers(provider, key)
      ..['content-type'] = 'multipart/form-data; boundary=$boundary';
    final http.Response response = await _send(
      () => _client.post(
        _resolve(provider.baseUrl, 'audio/transcriptions'),
        headers: headers,
        body: body,
      ),
      timeout: kAiTranscriptionRequestTimeout,
    );
    final Object? decoded = _decodeBody(response);
    if (decoded is! Map) {
      throw const AiChatFailure('bad_response');
    }
    return decoded;
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
  ///
  /// [tools] 为空时三家的请求体都不带工具字段，与没有 tool calling 之前逐字相同。
  Future<Map<Object?, Object?>> _postChat(
    AiProviderConfig provider,
    String key,
    List<AiChatMessage> messages,
    int maxTokens, [
    List<AiChatToolSpec> tools = const <AiChatToolSpec>[],
  ]) async {
    final (Uri uri, Map<String, Object?> payload) = switch (provider.protocol) {
      AiWireProtocol.openAiCompatible => (
        _resolve(provider.baseUrl, 'chat/completions'),
        _openAiPayload(provider, messages, maxTokens, tools),
      ),
      AiWireProtocol.anthropicMessages => (
        _resolve(provider.baseUrl, 'v1/messages'),
        _anthropicPayload(provider, messages, maxTokens, tools),
      ),
      AiWireProtocol.geminiGenerateContent => (
        _resolve(
          provider.baseUrl,
          'models/${provider.model}:generateContent',
        ).replace(queryParameters: <String, String>{'key': key}),
        _geminiPayload(messages, maxTokens, tools),
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
    List<AiChatToolSpec> tools,
  ) => <String, Object?>{
    'model': provider.model,
    'messages': <Map<String, Object?>>[
      for (final AiChatMessage m in messages)
        if (m.isToolResult)
          <String, Object?>{
            'role': 'tool',
            'tool_call_id': m.toolCallId,
            'content': m.content,
          }
        else if (m.hasToolCalls)
          <String, Object?>{
            'role': 'assistant',
            // 只调工具时正文发 null：部分兼容端点不收空串 content 的 assistant 消息。
            'content': m.content.isEmpty ? null : m.content,
            'tool_calls': <Map<String, Object?>>[
              for (final AiChatToolCall call in m.toolCalls)
                <String, Object?>{
                  'id': call.id,
                  'type': 'function',
                  'function': <String, Object?>{
                    'name': call.name,
                    'arguments': jsonEncode(call.arguments),
                  },
                },
            ],
          }
        else
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
    // 不发 tool_choice：默认 auto，由模型决定调不调工具。
    if (tools.isNotEmpty)
      'tools': <Map<String, Object?>>[
        for (final AiChatToolSpec tool in tools)
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
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
    List<AiChatToolSpec> tools,
  ) {
    // Anthropic 把 system 提到顶层，不放进 messages 数组。
    final String system = _systemText(messages);
    return <String, Object?>{
      'model': provider.model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': _anthropicSystem(messages, system),
      'messages': _anthropicMessages(messages),
      if (tools.isNotEmpty)
        'tools': <Map<String, Object?>>[
          for (int i = 0; i < tools.length; i++)
            <String, Object?>{
              'name': tools[i].name,
              'description': tools[i].description,
              'input_schema': tools[i].parameters,
              // 工具定义是逐字稳定的前缀（排在 system 之前），断点挂在最后一个
              // 工具上，整份工具表进缓存。
              if (i == tools.length - 1)
                'cache_control': const <String, String>{'type': 'ephemeral'},
            },
        ],
    };
  }

  /// Anthropic 的 messages 数组：普通消息形状与以往逐字相同；工具调用回放成
  /// `tool_use` 块；**连续的** tool result 合进同一条 user 消息（Anthropic 要求
  /// user / assistant 严格交替，一轮多个工具调用的结果必须在同一条里回）。
  static List<Map<String, Object?>> _anthropicMessages(
    List<AiChatMessage> messages,
  ) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    List<Map<String, Object?>>? pendingResults;
    for (final AiChatMessage m in messages) {
      if (m.isSystem) continue;
      if (m.isToolResult) {
        if (pendingResults == null) {
          pendingResults = <Map<String, Object?>>[];
          out.add(<String, Object?>{'role': 'user', 'content': pendingResults});
        }
        pendingResults.add(<String, Object?>{
          'type': 'tool_result',
          'tool_use_id': m.toolCallId,
          'content': m.content,
          if (m.isError) 'is_error': true,
        });
        continue;
      }
      pendingResults = null;
      if (m.hasToolCalls) {
        out.add(<String, Object?>{
          'role': 'assistant',
          'content': <Map<String, Object?>>[
            // Anthropic 拒收空文本块，只调工具时不带 text 块。
            if (m.content.isNotEmpty)
              <String, Object?>{'type': 'text', 'text': m.content},
            for (final AiChatToolCall call in m.toolCalls)
              <String, Object?>{
                'type': 'tool_use',
                'id': call.id,
                'name': call.name,
                'input': call.arguments,
              },
          ],
        });
        continue;
      }
      out.add(<String, Object?>{
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
      });
    }
    return out;
  }

  Map<String, Object?> _geminiPayload(
    List<AiChatMessage> messages,
    int maxTokens,
    List<AiChatToolSpec> tools,
  ) {
    final String system = _systemText(messages);
    return <String, Object?>{
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <Map<String, String>>[
            <String, String>{'text': system},
          ],
        },
      'contents': _geminiContents(messages),
      if (tools.isNotEmpty)
        'tools': <Map<String, Object?>>[
          <String, Object?>{
            'functionDeclarations': <Map<String, Object?>>[
              for (final AiChatToolSpec tool in tools)
                <String, Object?>{
                  'name': tool.name,
                  'description': tool.description,
                  'parameters': sanitizeGeminiToolSchema(tool.parameters),
                },
            ],
          },
        ],
      'generationConfig': <String, Object?>{'maxOutputTokens': maxTokens},
    };
  }

  /// Gemini 的 contents：普通消息形状与以往逐字相同；工具调用回放成 model 回合的
  /// `functionCall` part（带回 `thoughtSignature`——Gemini 思考模型缺了它会拒收
  /// 回放的工具调用）；连续的 tool result 合进同一条 user 回合的
  /// `functionResponse` part（按 name 配对）。
  static List<Map<String, Object?>> _geminiContents(
    List<AiChatMessage> messages,
  ) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    List<Map<String, Object?>>? pendingResults;
    for (final AiChatMessage m in messages) {
      if (m.isSystem) continue;
      if (m.isToolResult) {
        if (pendingResults == null) {
          pendingResults = <Map<String, Object?>>[];
          out.add(<String, Object?>{'role': 'user', 'parts': pendingResults});
        }
        pendingResults.add(<String, Object?>{
          'functionResponse': <String, Object?>{
            'name': m.toolName,
            'response': <String, Object?>{
              'content': m.content,
              if (m.isError) 'error': true,
            },
          },
        });
        continue;
      }
      pendingResults = null;
      if (m.hasToolCalls) {
        out.add(<String, Object?>{
          'role': 'model',
          'parts': <Map<String, Object?>>[
            if (m.content.isNotEmpty) <String, Object?>{'text': m.content},
            for (final AiChatToolCall call in m.toolCalls)
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': call.name,
                  'args': call.arguments,
                },
                if (call.providerMeta['thoughtSignature'] != null)
                  'thoughtSignature': call.providerMeta['thoughtSignature'],
              },
          ],
        });
        continue;
      }
      out.add(<String, Object?>{
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
      });
    }
    return out;
  }

  /// Anthropic 的顶层 `system`：没有 [AiChatMessage.cacheable] 段时仍是纯字符串
  /// （与以往逐字相同）；有时改成文本块数组，每条 system 一块，**最后一个**可缓存块
  /// 挂 `cache_control: {type: ephemeral}`——缓存命中按前缀算，最后一个断点之前的
  /// 全部内容都在缓存里，多挂只会占掉每次请求 4 个断点的名额。
  ///
  /// 低于模型的最小可缓存长度（512~4096 token，按模型）时 Anthropic 静默不缓存、
  /// 不报错，所以这里不必判长度。
  static Object _anthropicSystem(List<AiChatMessage> messages, String joined) {
    final List<AiChatMessage> parts = <AiChatMessage>[
      for (final AiChatMessage m in messages)
        if (m.isSystem && m.content.isNotEmpty) m,
    ];
    final int lastCacheable = parts.lastIndexWhere(
      (AiChatMessage m) => m.cacheable,
    );
    if (lastCacheable < 0) return joined;
    return <Map<String, Object?>>[
      for (int i = 0; i < parts.length; i++)
        <String, Object?>{
          'type': 'text',
          // 与纯字符串形态同一口径：块之间原本以空行相接。
          'text': i + 1 < parts.length
              ? '${parts[i].content}\n\n'
              : parts[i].content,
          if (i == lastCacheable)
            'cache_control': const <String, String>{'type': 'ephemeral'},
        },
    ];
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

  /// `choices[0]`；形状不对为 null。
  static Map<Object?, Object?>? _openAiFirstChoice(Map<Object?, Object?> body) {
    final Object? choices = body['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final Object? first = choices.first;
    return first is Map ? first : null;
  }

  static String? _openAiStopReason(Map<Object?, Object?> body) {
    final Object? reason = _openAiFirstChoice(body)?['finish_reason'];
    return reason is String ? reason : null;
  }

  /// `choices[0].message.tool_calls`；`arguments` 是 JSON 字符串（个别兼容端点
  /// 直接给对象，也认）。
  static List<AiChatToolCall> _openAiToolCalls(Map<Object?, Object?> body) {
    final Object? message = _openAiFirstChoice(body)?['message'];
    if (message is! Map) return const <AiChatToolCall>[];
    final Object? raw = message['tool_calls'];
    if (raw is! List) return const <AiChatToolCall>[];
    final List<AiChatToolCall> calls = <AiChatToolCall>[];
    for (final Object? entry in raw) {
      if (entry is! Map) continue;
      final Object? function = entry['function'];
      if (function is! Map) continue;
      final Object? name = function['name'];
      if (name is! String || name.isEmpty) continue;
      final Object? id = entry['id'];
      calls.add(
        AiChatToolCall(
          id: id is String && id.isNotEmpty ? id : 'call_${calls.length}',
          name: name,
          arguments: _decodeToolArguments(function['arguments']),
        ),
      );
    }
    return calls;
  }

  /// OpenAI 的 `arguments`：空串 / 缺失 = 无参数；不是 JSON 对象时给
  /// `{'_raw': 原串}`，不抛。
  static Map<String, Object?> _decodeToolArguments(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is! String || raw.trim().isEmpty) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // 落到下面的 _raw。
    }
    return <String, Object?>{'_raw': raw};
  }

  static List<AiChatToolCall> _anthropicToolCalls(Map<Object?, Object?> body) {
    final Object? content = body['content'];
    if (content is! List) return const <AiChatToolCall>[];
    final List<AiChatToolCall> calls = <AiChatToolCall>[];
    for (final Object? block in content) {
      if (block is! Map || block['type'] != 'tool_use') continue;
      final Object? name = block['name'];
      if (name is! String || name.isEmpty) continue;
      final Object? id = block['id'];
      final Object? input = block['input'];
      calls.add(
        AiChatToolCall(
          id: id is String && id.isNotEmpty ? id : 'call_${calls.length}',
          name: name,
          arguments: input is Map
              ? input.cast<String, Object?>()
              : <String, Object?>{},
        ),
      );
    }
    return calls;
  }

  static Map<Object?, Object?>? _geminiFirstCandidate(
    Map<Object?, Object?> body,
  ) {
    final Object? candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final Object? first = candidates.first;
    return first is Map ? first : null;
  }

  static String? _geminiStopReason(Map<Object?, Object?> body) {
    final Object? reason = _geminiFirstCandidate(body)?['finishReason'];
    return reason is String ? reason : null;
  }

  /// `candidates[0].content.parts[*].functionCall`；同一 part 上的
  /// `thoughtSignature` 记进 [AiChatToolCall.providerMeta]，回放时原样带回。
  /// Gemini 不一定给 id（新版本才有 `functionCall.id`），没有就按本轮序号生成。
  static List<AiChatToolCall> _geminiToolCalls(Map<Object?, Object?> body) {
    final Object? content = _geminiFirstCandidate(body)?['content'];
    if (content is! Map) return const <AiChatToolCall>[];
    final Object? parts = content['parts'];
    if (parts is! List) return const <AiChatToolCall>[];
    final List<AiChatToolCall> calls = <AiChatToolCall>[];
    for (final Object? part in parts) {
      if (part is! Map) continue;
      final Object? call = part['functionCall'];
      if (call is! Map) continue;
      final Object? name = call['name'];
      if (name is! String || name.isEmpty) continue;
      final Object? id = call['id'];
      final Object? args = call['args'];
      final Object? signature = part['thoughtSignature'];
      calls.add(
        AiChatToolCall(
          id: id is String && id.isNotEmpty ? id : 'call_${calls.length}',
          name: name,
          arguments: args is Map
              ? args.cast<String, Object?>()
              : <String, Object?>{},
          providerMeta: <String, Object?>{
            if (signature != null) 'thoughtSignature': signature,
          },
        ),
      );
    }
    return calls;
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

  Future<http.Response> _send(
    Future<http.Response> Function() send, {
    Duration timeout = kAiChatRequestTimeout,
  }) async {
    final http.Response response;
    try {
      response = await send().timeout(timeout);
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
