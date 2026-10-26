/// 用户自配的 AI（大语言模型）提供商条目。
///
/// 形状与 `OpdsServerConfig` / `TorznabIndexerConfig` 同构（用户自配、带 `enabled`
/// 自开关、整份列表存进一个偏好键的 JSON 数组），刻意不另发明一套——本仓已有的
/// Jellyfin / qBittorrent / Torznab / 互联对端 / OPDS 全是这个范式。
///
/// 与那几家的差别只有一处：AI 提供商之间**协议不同**（OpenAI 兼容 / Anthropic
/// Messages / Gemini generateContent），所以多一个 [AiWireProtocol] 字段，由
/// 调用层按它分派。绝大多数厂商都提供 OpenAI 兼容端点，只有 Anthropic 与 Gemini
/// 需要各自的 wire 形状。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 请求/响应的 wire 协议。
enum AiWireProtocol {
  /// `POST {baseUrl}/chat/completions`，OpenAI 的 Chat Completions 形状。
  /// 绝大多数厂商（含国内厂商的兼容端点）都走这个。
  openAiCompatible,

  /// `POST {baseUrl}/v1/messages`，Anthropic Messages API。
  anthropicMessages,

  /// `POST {baseUrl}/models/{model}:generateContent`，Google Gemini。
  geminiGenerateContent;

  String get storageKey => name;

  static AiWireProtocol fromStorageKey(String? key) {
    for (final AiWireProtocol p in AiWireProtocol.values) {
      if (p.storageKey == key) {
        return p;
      }
    }
    return AiWireProtocol.openAiCompatible;
  }
}

/// 推理档位。
///
/// 只有用户**显式**选了非 [none] 时才会往请求里塞推理字段：大量 OpenAI 兼容端点
/// 不认识 `reasoning_effort`，无条件发会让本来能用的服务直接 400。
enum AiReasoningEffort {
  none,
  low,
  medium,
  high;

  String get storageKey => name;

  static AiReasoningEffort fromStorageKey(String? key) {
    for (final AiReasoningEffort e in AiReasoningEffort.values) {
      if (e.storageKey == key) {
        return e;
      }
    }
    return AiReasoningEffort.none;
  }
}

/// 用户对「这家提供商能不能走原生 tool calling」的覆盖。
///
/// 预设的 [AiProviderPreset.supportsTools] 只是厂商公开能力的保守判断：本地模型、
/// 中转站、部分国产兼容端点的工具调用时好时坏，用户实测后可以强制开 / 关。
enum AiToolCallingOverride {
  /// 跟随预设（默认；旧数据没有这个字段时也是它）。
  followPreset,

  /// 强制走原生 tool calling。
  forceOn,

  /// 强制不走（降级为「只回一个 JSON 动作」的提示词约束）。
  forceOff;

  String get storageKey => name;

  static AiToolCallingOverride fromStorageKey(String? key) {
    for (final AiToolCallingOverride o in AiToolCallingOverride.values) {
      if (o.storageKey == key) {
        return o;
      }
    }
    return AiToolCallingOverride.followPreset;
  }
}

/// 一个内置提供商预设：把「地址 + 协议 + 一个能用的起点模型」打包好，用户加一家
/// 提供商时只需要填 API Key。
///
/// [suggestedModel] 只是**起点**，模型名随厂商迭代必然过时——所以配置界面同时提供
/// 「拉取模型列表」（各协议都有对应的列表端点）和自由输入，不把用户钉死在这个默认值上。
class AiProviderPreset {
  const AiProviderPreset({
    required this.id,
    required this.displayName,
    required this.protocol,
    required this.baseUrl,
    this.suggestedModel = '',
    this.requiresApiKey = true,
    this.isLocal = false,
    this.supportsTools = false,
  });

  /// 稳定身份，进持久化。
  final String id;
  final String displayName;
  final AiWireProtocol protocol;
  final String baseUrl;
  final String suggestedModel;

  /// 本地推理服务（Ollama / LM Studio）不需要 key。
  final bool requiresApiKey;

  /// 跑在本机、默认地址是 loopback HTTP。
  final bool isLocal;

  /// 这家的 chat 端点稳定支持原生 tool calling（OpenAI `tools` / Anthropic
  /// `tool_use` / Gemini `functionDeclarations`）。
  ///
  /// 默认 false（保守）：只给主流云端、文档明确支持的厂商开；本地推理服务与拿不准的
  /// 兼容端点（工具调用依赖具体模型）关，用户可在提供商上覆盖
  /// （[AiProviderConfig.toolCallingOverride]）。
  final bool supportsTools;
}

/// 自定义提供商的预设 id——用户自己填地址和协议。
const String kAiCustomPresetId = 'custom';

/// 内置提供商清单。
///
/// 只收「有公开 API 且当前仍在服务」的主流厂商，按中文用户实际会用到的顺序排。
/// 新增一家只需要在这里加一条：配置界面、协议分派、持久化都从这份清单推导。
const List<AiProviderPreset> kAiProviderPresets = <AiProviderPreset>[
  AiProviderPreset(
    id: 'openai',
    displayName: 'OpenAI',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    suggestedModel: 'gpt-4o-mini',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'anthropic',
    displayName: 'Anthropic',
    protocol: AiWireProtocol.anthropicMessages,
    baseUrl: 'https://api.anthropic.com',
    suggestedModel: 'claude-sonnet-5',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'gemini',
    displayName: 'Google Gemini',
    protocol: AiWireProtocol.geminiGenerateContent,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    suggestedModel: 'gemini-2.5-flash',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'deepseek',
    displayName: 'DeepSeek',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.deepseek.com/v1',
    suggestedModel: 'deepseek-chat',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'qwen',
    displayName: '通义千问 Qwen',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    suggestedModel: 'qwen-plus',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'zhipu',
    displayName: '智谱 GLM',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    suggestedModel: 'glm-4-flash',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'moonshot',
    displayName: 'Moonshot Kimi',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.moonshot.cn/v1',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'volcengine',
    displayName: '火山方舟 豆包',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
  ),
  AiProviderPreset(
    id: 'siliconflow',
    displayName: '硅基流动 SiliconFlow',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.siliconflow.cn/v1',
  ),
  AiProviderPreset(
    id: 'minimax',
    displayName: 'MiniMax',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.minimax.chat/v1',
  ),
  AiProviderPreset(
    id: 'lingyiwanwu',
    displayName: '零一万物 Yi',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.lingyiwanwu.com/v1',
  ),
  AiProviderPreset(
    id: 'xai',
    displayName: 'xAI Grok',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.x.ai/v1',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'mistral',
    displayName: 'Mistral',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.mistral.ai/v1',
    suggestedModel: 'mistral-small-latest',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'groq',
    displayName: 'Groq',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://api.groq.com/openai/v1',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'openrouter',
    displayName: 'OpenRouter',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
    supportsTools: true,
  ),
  AiProviderPreset(
    id: 'ollama',
    displayName: 'Ollama（本地）',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'http://localhost:11434/v1',
    requiresApiKey: false,
    isLocal: true,
  ),
  AiProviderPreset(
    id: 'lmstudio',
    displayName: 'LM Studio（本地）',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: 'http://localhost:1234/v1',
    requiresApiKey: false,
    isLocal: true,
  ),
  AiProviderPreset(
    id: kAiCustomPresetId,
    displayName: '自定义（OpenAI 兼容）',
    protocol: AiWireProtocol.openAiCompatible,
    baseUrl: '',
  ),
];

/// 按 id 找内置预设；找不到返回 null（存档里的 presetId 可能来自更新的版本）。
AiProviderPreset? aiProviderPresetById(String? id) {
  if (id == null) {
    return null;
  }
  for (final AiProviderPreset preset in kAiProviderPresets) {
    if (preset.id == id) {
      return preset;
    }
  }
  return null;
}

/// 一家提供商名下的一把 API Key。
///
/// 同一家可以配多把（有序）：请求按顺序挑一把**没在冷却**的用，被拒 / 限流 /
/// 额度用尽就换下一把重试（见 `ai_key_rotation.dart`）。冷却状态是运行时健康
/// 记录，不在这里——这里只存用户的配置（值 + 启用开关）。
class AiApiKey {
  const AiApiKey(this.value, {this.enabled = true});

  final String value;

  /// 用户手动停用的 key 不参与请求，但留在列表里（不必删了再重新粘贴）。
  final bool enabled;

  /// 请求里真正发出去的值：两端空白一律去掉（粘贴常带换行）。
  String get trimmed => value.trim();

  /// 参与请求：启用且非空。
  bool get isActive => enabled && trimmed.isNotEmpty;

  /// 界面上辨认这把 key 用的末 4 位（不足 4 位就全是它自己）。
  String get tail {
    final String v = trimmed;
    return v.length <= 4 ? v : v.substring(v.length - 4);
  }

  AiApiKey copyWith({String? value, bool? enabled}) =>
      AiApiKey(value ?? this.value, enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is AiApiKey && other.value == value && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(value, enabled);
}

/// 一家已配置的 AI 提供商。
class AiProviderConfig {
  AiProviderConfig({
    required this.id,
    required this.presetId,
    required this.name,
    required this.baseUrl,
    String apiKey = '',
    List<AiApiKey>? apiKeys,
    this.model = '',
    this.protocol = AiWireProtocol.openAiCompatible,
    this.reasoningEffort = AiReasoningEffort.none,
    this.enabled = true,
    this.allowInsecureHttp = false,
    this.requestsPerMinute = 0,
    this.toolCallingOverride = AiToolCallingOverride.followPreset,
  }) : apiKeys = List<AiApiKey>.unmodifiable(
         apiKeys ??
             (apiKey.isEmpty
                 ? const <AiApiKey>[]
                 : <AiApiKey>[AiApiKey(apiKey)]),
       ) {
    assert(
      apiKeys == null || apiKey.isEmpty,
      'pass either apiKey (single) or apiKeys (list), not both',
    );
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'AI provider id must not be empty');
    }
    if (baseUrl.scheme != 'http' && baseUrl.scheme != 'https') {
      throw ArgumentError('AI provider base URL must use HTTP or HTTPS');
    }
    if (baseUrl.host.isEmpty || baseUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'AI provider base URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      baseUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'AI provider base URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
  }

  /// 从预设建一条新配置（用户在「添加提供商」里选了一家内置的）。
  factory AiProviderConfig.fromPreset(
    AiProviderPreset preset, {
    required String id,
    String? name,
  }) => AiProviderConfig(
    id: id,
    presetId: preset.id,
    name: name ?? preset.displayName,
    baseUrl: Uri.parse(preset.baseUrl),
    model: preset.suggestedModel,
    protocol: preset.protocol,
    // 本地服务默认地址是 loopback HTTP，不勾这个开关就连构造都过不去。
    allowInsecureHttp: preset.isLocal,
  );

  /// 解析一条配置；字段畸形就抛，由列表层逐条丢弃——一条坏记录不该让整份清单消失。
  factory AiProviderConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse((json['baseUrl'] as String? ?? '').trim());
    if (url == null) {
      throw const FormatException('AI provider entry has no usable base URL');
    }
    return AiProviderConfig(
      id: (json['id'] as String? ?? '').trim(),
      presetId: json['presetId'] as String? ?? kAiCustomPresetId,
      name: json['name'] as String? ?? '',
      baseUrl: url,
      apiKeys: _decodeApiKeys(json),
      model: json['model'] as String? ?? '',
      protocol: AiWireProtocol.fromStorageKey(json['protocol'] as String?),
      reasoningEffort: AiReasoningEffort.fromStorageKey(
        json['reasoningEffort'] as String?,
      ),
      enabled: json['enabled'] as bool? ?? true,
      allowInsecureHttp: json['allowInsecureHttp'] as bool? ?? false,
      requestsPerMinute: math.max(0, (json['rpm'] as num?)?.toInt() ?? 0),
      toolCallingOverride: AiToolCallingOverride.fromStorageKey(
        json['toolCalling'] as String?,
      ),
    );
  }

  /// 稳定身份：功能→提供商的映射按它持久化，改 id 等于换了一家。
  final String id;

  /// 来自哪个内置预设（[kAiCustomPresetId] = 用户自填）。只用于 UI 显示与
  /// 「恢复默认地址」，**不参与调用分派**——分派只认 [protocol]。
  final String presetId;

  final String name;
  final Uri baseUrl;

  /// 这家的全部 key（有序，含停用的与空白草稿）。
  final List<AiApiKey> apiKeys;

  /// 参与请求的 key（启用且非空），按用户排的顺序，值已去空白。
  List<String> get activeApiKeys => <String>[
    for (final AiApiKey key in apiKeys)
      if (key.isActive) key.trimmed,
  ];

  /// 第一把参与请求的 key；一把都没有时为空串。
  ///
  /// 单 key 时代的读口（服务端配置、旧调用方）。多 key 轮换只在调用层
  /// （`AiChatClient`）里做，别处要「这家能不能发请求」一律问 [isUsable]。
  String get apiKey {
    final List<String> active = activeApiKeys;
    return active.isEmpty ? '' : active.first;
  }

  final String model;
  final AiWireProtocol protocol;
  final AiReasoningEffort reasoningEffort;
  final bool enabled;

  /// 明文 HTTP 的显式放行。本地推理服务（Ollama / LM Studio）跑在
  /// `http://localhost`，不给这个开关等于把本地模型挡在门外。
  final bool allowInsecureHttp;

  /// 每分钟最多发几次请求（这家所有功能合计，见 `AiRateLimiter`）；0 = 不限。
  /// 免费档 / 低档 API 有速率上限，超了会被 429 拦下、整批作废。
  final int requestsPerMinute;

  /// 用户对原生 tool calling 的覆盖；判据一律问 [supportsToolCalling]。
  final AiToolCallingOverride toolCallingOverride;

  /// 这家实际走不走原生 tool calling：用户强制开 / 关优先，否则跟随预设
  /// （[AiProviderPreset.supportsTools]）。presetId 认不出（来自更新的版本）时
  /// 按不支持处理——宁可降级成 JSON 动作，也不往不认识 `tools` 的端点上发。
  bool get supportsToolCalling => switch (toolCallingOverride) {
    AiToolCallingOverride.forceOn => true,
    AiToolCallingOverride.forceOff => false,
    AiToolCallingOverride.followPreset => preset?.supportsTools ?? false,
  };

  String get displayName => name.trim().isNotEmpty ? name.trim() : baseUrl.host;

  AiProviderPreset? get preset => aiProviderPresetById(presetId);

  /// 这家是否已经配到「能真的发一次请求」的程度。
  ///
  /// 判据只写这一处：UI 的状态标、功能映射的可选性、调用前的门都问它，
  /// 各处再抄一份判据必然漂移（既有的
  /// `createConfiguredVideoSubtitleProviders` 也是这个纪律）。
  bool get isUsable {
    if (!enabled || model.trim().isEmpty) {
      return false;
    }
    final bool needsKey = preset?.requiresApiKey ?? true;
    return !needsKey || activeApiKeys.isNotEmpty;
  }

  /// [apiKey] 是单 key 时代的写口：给了就把整份列表换成这一把（空串 = 清空）；
  /// 与 [apiKeys] 二选一。
  AiProviderConfig copyWith({
    String? name,
    Uri? baseUrl,
    String? apiKey,
    List<AiApiKey>? apiKeys,
    String? model,
    AiWireProtocol? protocol,
    AiReasoningEffort? reasoningEffort,
    bool? enabled,
    bool? allowInsecureHttp,
    int? requestsPerMinute,
    AiToolCallingOverride? toolCallingOverride,
  }) => AiProviderConfig(
    id: id,
    presetId: presetId,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKeys:
        apiKeys ??
        (apiKey == null
            ? this.apiKeys
            : <AiApiKey>[if (apiKey.isNotEmpty) AiApiKey(apiKey)]),
    model: model ?? this.model,
    protocol: protocol ?? this.protocol,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
    requestsPerMinute: requestsPerMinute ?? this.requestsPerMinute,
    toolCallingOverride: toolCallingOverride ?? this.toolCallingOverride,
  );

  /// API Key 在 JSON 里 base64 存放：`apiKeys` 是完整有序列表（空白草稿不落盘），
  /// 另把第一把参与请求的 key 照旧写进单 key 时代的 `apiKeyB64`——降级回旧版本时
  /// 旧解码器只认那一个字段，这样旧版至少还能用第一把 key 继续工作。
  ///
  /// 说清楚：这是**遮蔽不是加密**——能解码回来的东西挡不住拿到设备的人。本仓没有
  /// secure storage，既有做法（OPDS 密码、同步服务器密码）同样是 base64。真正被
  /// 执行的纪律不在编码强度，而在**隔离**：本键登记进 `kCredentialPreferenceKeys`
  /// （绝不写日志、绝不进明文导出）与 device-local 清单（绝不随备份/同步出设备）。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'presetId': presetId,
    'name': name,
    'baseUrl': baseUrl.toString(),
    if (apiKey.isNotEmpty) 'apiKeyB64': _b64(apiKey),
    if (apiKeys.any((AiApiKey k) => k.trimmed.isNotEmpty))
      'apiKeys': <Map<String, Object?>>[
        for (final AiApiKey key in apiKeys)
          if (key.trimmed.isNotEmpty)
            <String, Object?>{
              'keyB64': _b64(key.trimmed),
              if (!key.enabled) 'enabled': false,
            },
      ],
    'model': model,
    'protocol': protocol.storageKey,
    if (reasoningEffort != AiReasoningEffort.none)
      'reasoningEffort': reasoningEffort.storageKey,
    'enabled': enabled,
    if (allowInsecureHttp) 'allowInsecureHttp': true,
    if (requestsPerMinute > 0) 'rpm': requestsPerMinute,
    // 跟随预设时不落盘：旧数据缺字段 = 跟随预设，两者同一口径。
    if (toolCallingOverride != AiToolCallingOverride.followPreset)
      'toolCalling': toolCallingOverride.storageKey,
  };
}

String _b64(String value) => base64Encode(utf8.encode(value));

String _unb64(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return '';
  }
  try {
    return utf8.decode(base64Decode(raw));
  } on FormatException {
    return '';
  }
}

/// 读 key 列表：有 `apiKeys` 就以它为准；没有（单 key 时代写下的记录）就把
/// `apiKeyB64` 无损迁移成一元素列表。同值的 key 只留第一把（重复的 key 轮换时
/// 只会把同一个失败多吃一遍）。
List<AiApiKey> _decodeApiKeys(Map<String, Object?> json) {
  final Object? list = json['apiKeys'];
  final List<AiApiKey> keys = <AiApiKey>[];
  if (list is List) {
    for (final Object? entry in list) {
      if (entry is! Map) {
        continue;
      }
      final String value = _unb64(entry['keyB64']).trim();
      if (value.isEmpty) {
        continue;
      }
      keys.add(AiApiKey(value, enabled: entry['enabled'] as bool? ?? true));
    }
  } else {
    final String legacy = _unb64(json['apiKeyB64']);
    if (legacy.isNotEmpty) {
      keys.add(AiApiKey(legacy));
    }
  }
  final Set<String> seen = <String>{};
  return <AiApiKey>[
    for (final AiApiKey key in keys)
      if (seen.add(key.trimmed)) key,
  ];
}

/// 整份清单编码成一个偏好值。
String encodeAiProviderConfigs(Iterable<AiProviderConfig> providers) =>
    jsonEncode(
      providers.map((AiProviderConfig p) => p.toJson()).toList(growable: false),
    );

/// 逐条容错解析：坏一条只丢一条，id 撞车丢后来者。
List<AiProviderConfig> decodeAiProviderConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const <AiProviderConfig>[];
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <AiProviderConfig>[];
  }
  if (decoded is! List) {
    return const <AiProviderConfig>[];
  }
  final List<AiProviderConfig> providers = <AiProviderConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? entry in decoded) {
    if (entry is! Map) {
      continue;
    }
    try {
      final AiProviderConfig config = AiProviderConfig.fromJson(
        entry.cast<String, Object?>(),
      );
      if (!seenIds.add(config.id)) {
        continue;
      }
      providers.add(config);
    } on ArgumentError {
      continue;
    } on FormatException {
      continue;
    }
  }
  return List<AiProviderConfig>.unmodifiable(providers);
}
