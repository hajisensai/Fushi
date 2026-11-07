/// 「互联主机」AI 提供商：本机把一次补全交给已配对的互联主机，由主机用**它自己**
/// 配置的提供商执行并回结果——API Key 不离开主机（反馈 M8KvhMTHVS）。
///
/// 分三块，都在这一个文件里，wire 形状只写一处：
/// - wire 编解码：[encodeAiRelayMessages] / [decodeAiRelayMessages] 等，消息、工具、
///   工具调用、用量与 [AiChatClient] 的数据类型一一对应；
/// - 客户端出口 [AiRelayTransport]（全局装配点 [aiRelayTransport]）：引擎不认识配对
///   表与证书钉扎，app 装配成「按 hostId 找到已配对主机、经它的鉴权通道 POST」；
///   [AiChatClient] 遇到 [AiProviderConfig.relay] 非 null 的提供商就走这里；
/// - 主机执行侧 [AiRelayHostService]：按请求挑主机上的一家提供商，用本机的
///   [AiChatClient] 发出去（限频、key 轮换、临时性失败退避都在主机上照常生效）。
///
/// 路由（鉴权由 `FushiSyncServer` 的 middleware 统一做，见 `sync/ai_relay_routes.dart`）：
///
/// ```
/// POST /api/ai/relay/providers  {}                        → {ok, providers: [...], defaultProvider?}
/// POST /api/ai/relay/chat       {provider?, mode, ...}    → {ok, text, toolCalls, usage?, stopReason?}
/// ```
///
/// 语义失败（主机关了开关 / 没配提供商 / 上游失败）一律 **200** `{ok: false, error}`：
/// 客户端的互联通道遇到非 2xx 会换同一台主机的下一条地址再发，那会把一次花钱的
/// 补全在主机上重跑一遍。非 2xx 只留给「这台主机没有这个端点」（老版本 404）与鉴权。
///
/// 不做流式：[AiChatClient] 本身就不做（见其文件头），转发层跟随。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';

/// 路由前缀。
const String kAiRelayPathPrefix = '/api/ai/relay/';

/// 列主机上可用的提供商。
const String kAiRelayProvidersPath = '${kAiRelayPathPrefix}providers';

/// 执行一次补全 / 一轮对话 / 测试连接。
const String kAiRelayChatPath = '${kAiRelayPathPrefix}chat';

/// `/api/capabilities` 的能力位：主机接了 AI 转发**且**开关开着。
const String kAiRelayCapability = 'aiRelayV1';

/// 单次请求输出上限的封顶：客户端填得再大，主机也只按这个发。
const int kAiRelayMaxTokensCap = 65536;

// 失败短码（[AiChatFailure.message]）。与上游提供商的短码（`unauthorized` 等）
// 同一套契约，界面经 `aiFailureText` 映射成文案。

/// 本机没有装配互联通道（无头服务端 / 单测）。
const String kAiRelayUnavailable = 'relay_unavailable';

/// 本机没有与这台主机的有效配对（被删 / 停用 / 凭据没了）。
const String kAiRelayHostNotPaired = 'relay_host_not_paired';

/// 主机的所有地址都连不上。
const String kAiRelayHostUnreachable = 'relay_host_unreachable';

/// 主机证书与配对时记下的指纹不符。
const String kAiRelayCertificateMismatch = 'relay_certificate_mismatch';

/// 主机拒绝了本机的配对凭据（已吊销）。
const String kAiRelayAuthRejected = 'relay_auth_rejected';

/// 主机版本太旧，没有 AI 转发端点。
const String kAiRelayHostUnsupported = 'relay_host_unsupported';

/// 主机关掉了「允许已配对设备使用本机 AI」。
const String kAiRelayDisabled = 'relay_disabled';

/// 主机上没有可用的提供商（或指定的那家不在 / 没配全）。
const String kAiRelayNoProvider = 'relay_no_provider';

/// 请求体不合规（客户端与主机版本不匹配）。
const String kAiRelayBadRequest = 'relay_bad_request';

/// 互联主机提供商不支持的调用（云端转录、拉模型列表）。
const String kAiRelayOperationUnsupported = 'relay_operation_unsupported';

// ---------------------------------------------------------------------------
// 客户端出口
// ---------------------------------------------------------------------------

/// 把一个 JSON 请求发给已配对的主机 [hostId] 的 [path]，返回主机回的 JSON 对象。
///
/// 连接层失败一律抛 [AiChatFailure]（`relay_*` 短码）；主机回了 JSON 就原样返回，
/// `{ok: false}` 由调用方解释。
abstract interface class AiRelayTransport {
  Future<Map<String, Object?>> post(
    String hostId,
    String path,
    Map<String, Object?> body,
  );
}

/// 全局装配点：app 在偏好与配对表可读之后装成真实实现；null（无头服务端 / 单测）时
/// 互联主机提供商的请求抛 [kAiRelayUnavailable]。
AiRelayTransport? aiRelayTransport;

/// 主机上的一家提供商（列表项，绝不含 key 与地址）。
class AiRelayProviderInfo {
  const AiRelayProviderInfo({
    required this.id,
    required this.name,
    required this.model,
    required this.supportsTools,
    required this.acceptsImages,
  });

  factory AiRelayProviderInfo.fromJson(Map<String, Object?> json) =>
      AiRelayProviderInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        model: json['model'] as String? ?? '',
        supportsTools: json['tools'] as bool? ?? false,
        acceptsImages: json['images'] as bool? ?? false,
      );

  factory AiRelayProviderInfo.of(AiProviderConfig provider) =>
      AiRelayProviderInfo(
        id: provider.id,
        name: provider.displayName,
        model: provider.model,
        supportsTools: provider.supportsToolCalling,
        acceptsImages: provider.acceptsImages,
      );

  final String id;
  final String name;
  final String model;
  final bool supportsTools;
  final bool acceptsImages;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'model': model,
    'tools': supportsTools,
    'images': acceptsImages,
  };
}

/// 主机上可用的提供商清单。
class AiRelayProviderList {
  const AiRelayProviderList({required this.providers, this.defaultProviderId});

  final List<AiRelayProviderInfo> providers;

  /// 主机的默认提供商（在 [providers] 里）；主机没设默认时 null。
  final String? defaultProviderId;

  AiRelayProviderInfo? byId(String? id) {
    for (final AiRelayProviderInfo p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 问主机 [hostId] 有哪些可用的提供商。失败抛 [AiChatFailure]。
Future<AiRelayProviderList> fetchAiRelayProviders(
  String hostId, {
  AiRelayTransport? transport,
}) async {
  final Map<String, Object?> reply = _unwrap(
    await _transportOrThrow(
      transport,
    ).post(hostId, kAiRelayProvidersPath, const <String, Object?>{}),
  );
  final Object? raw = reply['providers'];
  final List<AiRelayProviderInfo> providers = <AiRelayProviderInfo>[
    if (raw is List)
      for (final Object? entry in raw)
        if (entry is Map)
          AiRelayProviderInfo.fromJson(entry.cast<String, Object?>()),
  ];
  final Object? def = reply['defaultProvider'];
  return AiRelayProviderList(
    providers: List<AiRelayProviderInfo>.unmodifiable(providers),
    defaultProviderId: def is String && def.isNotEmpty ? def : null,
  );
}

AiRelayTransport _transportOrThrow(AiRelayTransport? injected) {
  final AiRelayTransport? transport = injected ?? aiRelayTransport;
  if (transport == null) throw const AiChatFailure(kAiRelayUnavailable);
  return transport;
}

/// `{ok: false, error}` → 抛对应短码；`ok` 缺失视为坏应答。
Map<String, Object?> _unwrap(Map<String, Object?> reply) {
  if (reply['ok'] == true) return reply;
  final Object? error = reply['error'];
  if (reply['ok'] == false && error is String && error.isNotEmpty) {
    throw AiChatFailure(error);
  }
  throw const AiChatFailure('bad_response');
}

/// [AiChatClient] 对互联主机提供商的三种调用。
enum AiRelayMode {
  /// 一次问答（[AiChatClient.completeWithUsage]）。
  complete,

  /// 一轮带工具的对话（[AiChatClient.chat]）。
  chat,

  /// 测试连接（[AiChatClient.ping]）：主机对所选提供商真发一次最小请求。
  ping;

  static AiRelayMode? fromName(Object? name) {
    for (final AiRelayMode m in AiRelayMode.values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// 客户端：把一次调用发给 [provider] 指向的主机，回主机执行的结果。
Future<AiChatTurn> sendAiRelayRequest({
  required AiProviderConfig provider,
  required AiRelayMode mode,
  List<AiChatMessage> messages = const <AiChatMessage>[],
  List<AiChatToolSpec> tools = const <AiChatToolSpec>[],
  int maxTokens = 2048,
  AiRelayTransport? transport,
}) async {
  final AiRelayTarget? relay = provider.relay;
  if (relay == null) {
    throw ArgumentError.value(provider.id, 'provider', 'not a relay provider');
  }
  final Map<String, Object?> reply = _unwrap(
    await _transportOrThrow(
      transport,
    ).post(relay.hostId, kAiRelayChatPath, <String, Object?>{
      'mode': mode.name,
      if (relay.providerId != null) 'provider': relay.providerId,
      'maxTokens': maxTokens,
      'messages': encodeAiRelayMessages(messages),
      if (tools.isNotEmpty) 'tools': encodeAiRelayTools(tools),
    }),
  );
  return decodeAiRelayTurn(reply);
}

// ---------------------------------------------------------------------------
// wire 编解码
// ---------------------------------------------------------------------------

List<Map<String, Object?>> encodeAiRelayMessages(
  List<AiChatMessage> messages,
) => <Map<String, Object?>>[
  for (final AiChatMessage m in messages)
    <String, Object?>{
      'role': m.role,
      'content': m.content,
      if (m.cacheable) 'cacheable': true,
      if (m.images.isNotEmpty)
        'images': <Map<String, Object?>>[
          for (final AiChatImage image in m.images)
            <String, Object?>{'mime': image.mimeType, 'b64': image.base64Data},
        ],
      if (m.toolCalls.isNotEmpty)
        'toolCalls': <Map<String, Object?>>[
          for (final AiChatToolCall call in m.toolCalls) _encodeToolCall(call),
        ],
      if (m.toolCallId != null) 'toolCallId': m.toolCallId,
      if (m.toolName != null) 'toolName': m.toolName,
      if (m.isError) 'isError': true,
    },
];

/// 解码消息列表；形状不对抛 [FormatException]（路由回 [kAiRelayBadRequest]）。
List<AiChatMessage> decodeAiRelayMessages(Object? raw) {
  if (raw is! List) throw const FormatException('messages must be a list');
  return <AiChatMessage>[
    for (final Object? entry in raw) _decodeMessage(entry),
  ];
}

AiChatMessage _decodeMessage(Object? entry) {
  if (entry is! Map) throw const FormatException('message must be an object');
  final Object? content = entry['content'];
  if (content is! String) {
    throw const FormatException('message content must be a string');
  }
  switch (entry['role']) {
    case 'system':
      return AiChatMessage.system(
        content,
        cacheable: entry['cacheable'] == true,
      );
    case 'user':
      final Object? images = entry['images'];
      return AiChatMessage.user(
        content,
        images: <AiChatImage>[
          if (images is List)
            for (final Object? image in images) _decodeImage(image),
        ],
      );
    case 'assistant':
      final Object? calls = entry['toolCalls'];
      if (calls is List && calls.isNotEmpty) {
        return AiChatMessage.assistantToolCalls(content, <AiChatToolCall>[
          for (final Object? call in calls) _decodeToolCall(call),
        ]);
      }
      return AiChatMessage.assistant(content);
    case 'tool':
      final Object? callId = entry['toolCallId'];
      final Object? name = entry['toolName'];
      if (callId is! String || name is! String) {
        throw const FormatException(
          'tool result needs toolCallId and toolName',
        );
      }
      return AiChatMessage.toolResult(
        toolCallId: callId,
        toolName: name,
        content: content,
        isError: entry['isError'] == true,
      );
    default:
      throw const FormatException('unknown message role');
  }
}

AiChatImage _decodeImage(Object? raw) {
  if (raw is! Map || raw['b64'] is! String) {
    throw const FormatException('image must carry b64');
  }
  return AiChatImage(
    bytes: base64Decode(raw['b64'] as String),
    mimeType: raw['mime'] as String? ?? 'image/png',
  );
}

Map<String, Object?> _encodeToolCall(AiChatToolCall call) => <String, Object?>{
  'id': call.id,
  'name': call.name,
  'arguments': call.arguments,
  if (call.providerMeta.isNotEmpty) 'meta': call.providerMeta,
};

AiChatToolCall _decodeToolCall(Object? raw) {
  if (raw is! Map || raw['id'] is! String || raw['name'] is! String) {
    throw const FormatException('tool call needs id and name');
  }
  final Object? args = raw['arguments'];
  final Object? meta = raw['meta'];
  return AiChatToolCall(
    id: raw['id'] as String,
    name: raw['name'] as String,
    arguments: args is Map
        ? args.cast<String, Object?>()
        : const <String, Object?>{},
    providerMeta: meta is Map
        ? meta.cast<String, Object?>()
        : const <String, Object?>{},
  );
}

List<Map<String, Object?>> encodeAiRelayTools(List<AiChatToolSpec> tools) =>
    <Map<String, Object?>>[
      for (final AiChatToolSpec tool in tools)
        <String, Object?>{
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
    ];

List<AiChatToolSpec> decodeAiRelayTools(Object? raw) {
  if (raw == null) return const <AiChatToolSpec>[];
  if (raw is! List) throw const FormatException('tools must be a list');
  return <AiChatToolSpec>[for (final Object? entry in raw) _decodeTool(entry)];
}

AiChatToolSpec _decodeTool(Object? entry) {
  if (entry is! Map ||
      entry['name'] is! String ||
      entry['parameters'] is! Map) {
    throw const FormatException('tool needs name and parameters');
  }
  return AiChatToolSpec(
    name: entry['name'] as String,
    description: entry['description'] as String? ?? '',
    parameters: (entry['parameters'] as Map).cast<String, Object?>(),
  );
}

Map<String, Object?> encodeAiRelayTurn(AiChatTurn turn) => <String, Object?>{
  'ok': true,
  'text': turn.text,
  'toolCalls': <Map<String, Object?>>[
    for (final AiChatToolCall call in turn.toolCalls) _encodeToolCall(call),
  ],
  if (turn.usage != null) 'usage': turn.usage!.toJson(),
  if (turn.stopReason != null) 'stopReason': turn.stopReason,
};

/// 主机应答 → [AiChatTurn]；形状不对抛 `bad_response`。
AiChatTurn decodeAiRelayTurn(Map<String, Object?> reply) {
  final Object? calls = reply['toolCalls'];
  final Object? usage = reply['usage'];
  final Object? text = reply['text'];
  final Object? stop = reply['stopReason'];
  if ((text != null && text is! String) || (stop != null && stop is! String)) {
    throw const AiChatFailure('bad_response');
  }
  try {
    return AiChatTurn(
      text: text as String? ?? '',
      toolCalls: List<AiChatToolCall>.unmodifiable(<AiChatToolCall>[
        if (calls is List)
          for (final Object? call in calls) _decodeToolCall(call),
      ]),
      usage: usage is Map
          ? AiChatUsage.fromJson(usage.cast<String, Object?>())
          : null,
      stopReason: stop as String?,
    );
  } on FormatException {
    throw const AiChatFailure('bad_response');
  }
}

// ---------------------------------------------------------------------------
// 主机执行侧
// ---------------------------------------------------------------------------

/// 主机：替已配对设备执行补全。每个请求现读 [settings]，主机改了提供商立即生效。
class AiRelayHostService {
  AiRelayHostService({
    required AiSettingsSource Function() settings,
    AiChatClient Function()? clientFactory,
  }) : _settings = settings,
       _clientFactory = clientFactory ?? AiChatClient.new;

  final AiSettingsSource Function() _settings;
  final AiChatClient Function() _clientFactory;

  /// 主机上能替别人执行的提供商：可用（[AiProviderConfig.isUsable]）且**不是**
  /// 互联主机提供商——主机再转给别的主机会形成转发链，key 的归属与费用都说不清，
  /// 两台互相指着还会死循环。
  List<AiProviderConfig> relayableProviders() => <AiProviderConfig>[
    for (final AiProviderConfig p in _settings().aiProviders)
      if (p.isUsable && !p.isInterconnectHost) p,
  ];

  /// `providers` 路由的应答体。
  Map<String, Object?> providersReply() {
    final List<AiProviderConfig> providers = relayableProviders();
    final String? def = _settings().aiFeatureAssignments.defaultProviderId;
    return <String, Object?>{
      'ok': true,
      'providers': <Map<String, Object?>>[
        for (final AiProviderConfig p in providers)
          AiRelayProviderInfo.of(p).toJson(),
      ],
      if (providers.any((AiProviderConfig p) => p.id == def))
        'defaultProvider': def,
    };
  }

  /// 按请求挑提供商：指定了 id 就只认那家；没指定用主机的默认提供商。
  AiProviderConfig? _pick(String? providerId) {
    final String? id =
        providerId ?? _settings().aiFeatureAssignments.defaultProviderId;
    for (final AiProviderConfig p in relayableProviders()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// `chat` 路由的应答体。请求体形状不对抛 [FormatException]（路由回
  /// [kAiRelayBadRequest]），上游失败回 `{ok: false, error: <短码>}`。
  Future<Map<String, Object?>> chatReply(Map<String, Object?> body) async {
    final AiRelayMode? mode = AiRelayMode.fromName(body['mode']);
    if (mode == null) throw const FormatException('unknown mode');
    final Object? rawProvider = body['provider'];
    if (rawProvider != null && rawProvider is! String) {
      throw const FormatException('provider must be a string');
    }
    final Object? rawMax = body['maxTokens'];
    final int maxTokens = rawMax is int && rawMax > 0
        ? (rawMax > kAiRelayMaxTokensCap ? kAiRelayMaxTokensCap : rawMax)
        : 2048;
    final List<AiChatMessage> messages = mode == AiRelayMode.ping
        ? const <AiChatMessage>[]
        : decodeAiRelayMessages(body['messages']);
    final List<AiChatToolSpec> tools = decodeAiRelayTools(body['tools']);
    final AiProviderConfig? provider = _pick(rawProvider as String?);
    if (provider == null) {
      return const <String, Object?>{'ok': false, 'error': kAiRelayNoProvider};
    }
    final AiChatClient client = _clientFactory();
    try {
      switch (mode) {
        case AiRelayMode.ping:
          await client.ping(provider);
          return encodeAiRelayTurn(
            const AiChatTurn(text: '', toolCalls: <AiChatToolCall>[]),
          );
        case AiRelayMode.complete:
          final AiChatCompletion done = await client.completeWithUsage(
            provider: provider,
            messages: messages,
            maxTokens: maxTokens,
          );
          return encodeAiRelayTurn(
            AiChatTurn(
              text: done.text,
              toolCalls: const <AiChatToolCall>[],
              usage: done.usage,
              stopReason: done.stopReason,
            ),
          );
        case AiRelayMode.chat:
          return encodeAiRelayTurn(
            await client.chat(
              provider: provider,
              messages: messages,
              tools: tools,
              maxTokens: maxTokens,
            ),
          );
      }
    } on AiChatFailure catch (failure) {
      // 短码已脱敏（不含 key / 地址 / 响应体），原样交给对端界面解释。
      return <String, Object?>{'ok': false, 'error': failure.message};
    } finally {
      client.close();
    }
  }
}
