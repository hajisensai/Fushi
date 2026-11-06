/// settings 域控制通道（快捷键 / Profile 绑定 / AI / TTS 声音）的纯函数：
/// 参数解析与应答形状。
///
/// 与路由文件分开是为了能直接单测（不需要 AppModel / WidgetRef）。这里**不做**
/// 任何业务写入。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

// ── 快捷键绑定 token ─────────────────────────────────────────────────────────

/// 键盘 / 滚轮 token 的友好写法 → 持久化写法：修饰键大小写与别名（`ctrl` /
/// `cmd` / `option` …）归一成 `Ctrl` / `Shift` / `Alt` / `Meta`；单个字母 `F` →
/// `KeyF`，单个数字 `1` → `Digit1`（持久化用 DOM code 风格，见
/// `InputBinding.serialize`）。其余部分原样保留。
String normalizeCtlKeyToken(String token) {
  final List<String> parts = token.split('+');
  return <String>[
    for (int i = 0; i < parts.length; i++)
      switch (parts[i].toLowerCase()) {
        'ctrl' || 'control' => 'Ctrl',
        'shift' => 'Shift',
        'alt' || 'option' || 'opt' => 'Alt',
        'meta' || 'cmd' || 'command' || 'win' || 'super' => 'Meta',
        _
            when i == parts.length - 1 &&
                RegExp(r'^[A-Za-z]$').hasMatch(parts[i]) =>
          'Key${parts[i].toUpperCase()}',
        _ when i == parts.length - 1 && RegExp(r'^[0-9]$').hasMatch(parts[i]) =>
          'Digit${parts[i]}',
        _ => parts[i],
      },
  ].join('+');
}

/// CLI 上一个绑定 token → 绑定对象（[InputBinding] / [GamepadBinding] /
/// [MouseBinding] / [WheelBinding]）。写法与持久化的 `serialize()` 同形
/// （`keys ls --json` 每行 `tokens` 字段就是它），键盘另接受友好写法
/// （`Ctrl+F` = `Ctrl+KeyF`，见 [normalizeCtlKeyToken]）：
///
/// - 键盘 `Ctrl+Shift+F`、`F12`；
/// - 鼠标 `MouseBack` / `MouseForward` / `MouseMiddle` / `MouseRight` / `Mouse5`；
/// - 滚轮 `Alt+WheelDown`；
/// - 手柄键名与键盘字母撞车（`A`），所以手柄必须带前缀 `pad:A`。
///
/// 也接受显式前缀 `key:` / `mouse:` / `wheel:`。认不出给 400。
Object parseCtlShortcutBinding(String raw) {
  final String token = raw.trim();
  final int colon = token.indexOf(':');
  final String prefix = colon > 0
      ? token.substring(0, colon).toLowerCase()
      : '';
  final String body = colon > 0 ? token.substring(colon + 1) : token;
  Object? parsed;
  switch (prefix) {
    case 'pad' || 'gamepad':
      parsed = GamepadBinding.deserialize(body);
    case 'key' || 'kb' || 'keyboard':
      parsed =
          InputBinding.deserialize(body) ??
          InputBinding.deserialize(normalizeCtlKeyToken(body));
    case 'mouse':
      parsed = MouseBinding.deserialize(body);
    case 'wheel':
      parsed =
          WheelBinding.deserialize(body) ??
          WheelBinding.deserialize(normalizeCtlKeyToken(body));
    case '':
      if (body.startsWith('Mouse')) {
        parsed = MouseBinding.deserialize(body);
      } else if (body.contains('Wheel')) {
        parsed = WheelBinding.deserialize(normalizeCtlKeyToken(body));
      }
      parsed ??=
          InputBinding.deserialize(body) ??
          InputBinding.deserialize(normalizeCtlKeyToken(body));
    default:
      throw CtlFailure.badRequest(
        '绑定「$raw」的前缀 $prefix: 不认识；可用 pad: / key: / mouse: / wheel:',
      );
  }
  if (parsed == null) {
    throw CtlFailure.badRequest(
      '认不出绑定「$raw」（写法同 keys ls --json 的 tokens 字段，如 Ctrl+F、'
      'MouseBack、Alt+WheelDown、pad:A）',
    );
  }
  return parsed;
}

/// 一个绑定对象的持久化 token（[parseCtlShortcutBinding] 的逆）。手柄带 `pad:`
/// 前缀，保证从 `tokens` 抄回去能原样解析。
String ctlShortcutBindingToken(Object binding) => switch (binding) {
  InputBinding() => binding.serialize(),
  GamepadBinding() => 'pad:${binding.serialize()}',
  MouseBinding() => binding.serialize(),
  WheelBinding() => binding.serialize(),
  _ => throw ArgumentError.value(binding, 'binding', 'unknown binding'),
};

/// 绑定对象落在哪条通道。
ShortcutChannel ctlShortcutChannelOf(Object binding) => switch (binding) {
  InputBinding() => ShortcutChannel.keyboard,
  GamepadBinding() => ShortcutChannel.gamepad,
  MouseBinding() => ShortcutChannel.mouse,
  WheelBinding() => ShortcutChannel.wheel,
  _ => throw ArgumentError.value(binding, 'binding', 'unknown binding'),
};

/// [set] 在 [channel] 上的绑定。
List<Object> ctlShortcutChannelBindings(
  ShortcutBindingSet set,
  ShortcutChannel channel,
) => switch (channel) {
  ShortcutChannel.keyboard => List<Object>.of(set.keyboardBindings),
  ShortcutChannel.gamepad => List<Object>.of(set.gamepadBindings),
  ShortcutChannel.mouse => List<Object>.of(set.mouseBindings),
  ShortcutChannel.wheel => List<Object>.of(set.wheelBindings),
};

/// 把 [set] 的 [channel] 通道整体换成 [bindings]，其余通道原样保留。
ShortcutBindingSet ctlShortcutWithChannel(
  ShortcutBindingSet set,
  ShortcutChannel channel,
  List<Object> bindings,
) => switch (channel) {
  ShortcutChannel.keyboard => set.copyWith(
    keyboardBindings: List<InputBinding>.unmodifiable(
      bindings.whereType<InputBinding>(),
    ),
  ),
  ShortcutChannel.gamepad => set.copyWith(
    gamepadBindings: List<GamepadBinding>.unmodifiable(
      bindings.whereType<GamepadBinding>(),
    ),
  ),
  ShortcutChannel.mouse => set.copyWith(
    mouseBindings: List<MouseBinding>.unmodifiable(
      bindings.whereType<MouseBinding>(),
    ),
  ),
  ShortcutChannel.wheel => set.copyWith(
    wheelBindings: List<WheelBinding>.unmodifiable(
      bindings.whereType<WheelBinding>(),
    ),
  ),
};

/// `keys set` 的新绑定集：[replace] 时被提到的通道整体换成新绑定（没提到的
/// 通道不动），否则追加到已有绑定之后（去重）。
ShortcutBindingSet ctlShortcutMergedBindings(
  ShortcutBindingSet before,
  List<Object> added, {
  required bool replace,
}) {
  ShortcutBindingSet next = before;
  for (final ShortcutChannel channel in ShortcutChannel.values) {
    final List<Object> incoming = <Object>[
      for (final Object binding in added)
        if (ctlShortcutChannelOf(binding) == channel) binding,
    ];
    if (incoming.isEmpty) continue;
    final List<Object> merged = <Object>[
      if (!replace) ...ctlShortcutChannelBindings(before, channel),
    ];
    for (final Object binding in incoming) {
      if (!merged.contains(binding)) merged.add(binding);
    }
    next = ctlShortcutWithChannel(next, channel, merged);
  }
  return next;
}

/// 从 [before] 里去掉 [removed]（不在里面的给 400，避免「以为解绑了」）。
ShortcutBindingSet ctlShortcutWithout(
  ShortcutBindingSet before,
  List<Object> removed,
) {
  ShortcutBindingSet next = before;
  for (final Object binding in removed) {
    final ShortcutChannel channel = ctlShortcutChannelOf(binding);
    final List<Object> current = ctlShortcutChannelBindings(next, channel);
    if (!current.contains(binding)) {
      throw CtlFailure.badRequest(
        '该动作没有绑定 ${ctlShortcutBindingToken(binding)}',
      );
    }
    next = ctlShortcutWithChannel(
      next,
      channel,
      current.where((Object b) => b != binding).toList(),
    );
  }
  return next;
}

/// 全部绑定的持久化 token（`keys ls` 每行的 `tokens`）。
List<String> ctlShortcutTokens(ShortcutBindingSet set) => <String>[
  for (final ShortcutChannel channel in ShortcutChannel.values)
    for (final Object binding in ctlShortcutChannelBindings(set, channel))
      ctlShortcutBindingToken(binding),
];

/// 动作名：持久化键（`ShortcutAction.key`）或枚举名，大小写无关。
ShortcutAction? parseCtlShortcutAction(String raw) {
  final String needle = raw.trim();
  final ShortcutAction? byKey = ShortcutAction.fromKey(needle);
  if (byKey != null) return byKey;
  final String lower = needle.toLowerCase();
  for (final ShortcutAction action in ShortcutAction.values) {
    if (action.key.toLowerCase() == lower ||
        action.name.toLowerCase() == lower) {
      return action;
    }
  }
  return null;
}

/// 作用域名（枚举名，大小写无关）。
ShortcutScope? parseCtlShortcutScope(String raw) {
  final String lower = raw.trim().toLowerCase();
  for (final ShortcutScope scope in ShortcutScope.values) {
    if (scope.name.toLowerCase() == lower) return scope;
  }
  return null;
}

// ── Profile 绑定 ─────────────────────────────────────────────────────────────

/// 媒体类型名（`ProfileMediaKind.dbValue` / 枚举名，大小写无关）。
ProfileMediaKind? parseCtlProfileMediaKind(String raw) {
  final String lower = raw.trim().toLowerCase();
  for (final ProfileMediaKind kind in ProfileMediaKind.values) {
    if (kind.dbValue == lower || kind.name.toLowerCase() == lower) return kind;
  }
  return null;
}

/// 「解绑 / 不指定」的几种写法。
bool isCtlNoneToken(String raw) => switch (raw.trim().toLowerCase()) {
  'none' || 'unbind' || '-' => true,
  _ => false,
};

// ── AI ──────────────────────────────────────────────────────────────────────

/// 功能名：枚举名或持久化键（`videoAcquire`），大小写与 `-` / `_` 无关。
AiFeature? parseCtlAiFeature(String raw) {
  final String folded = raw
      .trim()
      .replaceAll(RegExp(r'[-_]'), '')
      .toLowerCase();
  for (final AiFeature feature in AiFeature.values) {
    if (feature.name.toLowerCase() == folded ||
        feature.storageKey.toLowerCase() == folded) {
      return feature;
    }
  }
  return null;
}

/// 协议名：`openai` / `anthropic` / `gemini`（也接受完整枚举名）。
AiWireProtocol parseCtlAiProtocol(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'openai' || 'openaicompatible':
      return AiWireProtocol.openAiCompatible;
    case 'anthropic' || 'anthropicmessages':
      return AiWireProtocol.anthropicMessages;
    case 'gemini' || 'geminigeneratecontent':
      return AiWireProtocol.geminiGenerateContent;
  }
  throw CtlFailure.badRequest('协议只能是 openai / anthropic / gemini，收到「$raw」');
}

/// 推理档位名。
AiReasoningEffort parseCtlAiReasoning(String raw) {
  final String lower = raw.trim().toLowerCase();
  for (final AiReasoningEffort effort in AiReasoningEffort.values) {
    if (effort.name == lower) return effort;
  }
  throw CtlFailure.badRequest(
    '推理档位只能是 '
    '${AiReasoningEffort.values.map((AiReasoningEffort e) => e.name).join(' / ')}'
    '，收到「$raw」',
  );
}

/// 一家提供商在应答里的形状。API Key **一律不回显**，只给末 4 位（与设置页
/// 框下辨认 key 用的同一个 [AiApiKey.tail]）与启用状态。
Map<String, Object?> ctlAiProviderJson(AiProviderConfig provider) =>
    <String, Object?>{
      'id': provider.id,
      'name': provider.displayName,
      'preset': provider.presetId,
      'baseUrl': provider.baseUrl.toString(),
      'model': provider.model,
      'protocol': provider.protocol.storageKey,
      'reasoning': provider.reasoningEffort.storageKey,
      'enabled': provider.enabled,
      'allowInsecureHttp': provider.allowInsecureHttp,
      'rpm': provider.requestsPerMinute,
      'usable': provider.isUsable,
      'keys': <Map<String, Object?>>[
        for (final AiApiKey key in provider.apiKeys)
          if (key.trimmed.isNotEmpty)
            <String, Object?>{'tail': '…${key.tail}', 'enabled': key.enabled},
      ],
      'keyCount': provider.activeApiKeys.length,
    };

/// 按 [ref]（id 或名字，名字精确匹配）找提供商。
AiProviderConfig resolveCtlAiProvider(
  List<AiProviderConfig> providers,
  String ref,
) {
  final String needle = ref.trim();
  for (final AiProviderConfig provider in providers) {
    if (provider.id == needle) return provider;
  }
  final List<AiProviderConfig> byName = <AiProviderConfig>[
    for (final AiProviderConfig provider in providers)
      if (provider.displayName == needle || provider.name == needle) provider,
  ];
  if (byName.length == 1) return byName.single;
  if (byName.length > 1) {
    throw CtlFailure.conflict('有 ${byName.length} 家名为「$ref」的提供商，请用 id');
  }
  throw CtlFailure.notFound('没有 AI 提供商「$ref」（ai ls 查看）');
}

/// 新建一家提供商：预设给起点，显式字段覆盖。地址 / 明文 HTTP 不合法时
/// [AiProviderConfig] 构造会抛 [ArgumentError]，这里转成 400。
AiProviderConfig buildCtlAiProvider(
  AiProviderPreset preset, {
  required String id,
  String? name,
  String? baseUrl,
  String? model,
  AiWireProtocol? protocol,
  AiReasoningEffort? reasoning,
  bool? enabled,
  bool? allowInsecureHttp,
  int? rpm,
  List<AiApiKey> apiKeys = const <AiApiKey>[],
}) {
  final String url = (baseUrl ?? preset.baseUrl).trim();
  if (url.isEmpty) {
    throw const CtlFailure.badRequest('自定义提供商必须给 --base-url');
  }
  if (rpm != null && rpm < 0) {
    throw const CtlFailure.badRequest('--rpm 不能是负数（0 = 不限）');
  }
  try {
    return AiProviderConfig(
      id: id,
      presetId: preset.id,
      name: name ?? preset.displayName,
      baseUrl: Uri.parse(url),
      apiKeys: apiKeys,
      model: model ?? preset.suggestedModel,
      protocol: protocol ?? preset.protocol,
      reasoningEffort: reasoning ?? AiReasoningEffort.none,
      enabled: enabled ?? true,
      allowInsecureHttp: allowInsecureHttp ?? preset.isLocal,
      requestsPerMinute: rpm ?? 0,
    );
  } on ArgumentError catch (e) {
    throw CtlFailure.badRequest('提供商配置无效：${e.message}');
  } on FormatException catch (e) {
    throw CtlFailure.badRequest('地址无效：${e.message}');
  }
}

/// 改一家提供商（copyWith 走同一个构造校验）。
AiProviderConfig updateCtlAiProvider(
  AiProviderConfig provider, {
  String? name,
  String? baseUrl,
  String? model,
  AiWireProtocol? protocol,
  AiReasoningEffort? reasoning,
  bool? enabled,
  bool? allowInsecureHttp,
  int? rpm,
  List<AiApiKey>? apiKeys,
}) {
  if (rpm != null && rpm < 0) {
    throw const CtlFailure.badRequest('--rpm 不能是负数（0 = 不限）');
  }
  try {
    return provider.copyWith(
      name: name,
      baseUrl: baseUrl == null ? null : Uri.parse(baseUrl.trim()),
      model: model,
      protocol: protocol,
      reasoningEffort: reasoning,
      enabled: enabled,
      allowInsecureHttp: allowInsecureHttp,
      requestsPerMinute: rpm,
      apiKeys: apiKeys,
    );
  } on ArgumentError catch (e) {
    throw CtlFailure.badRequest('提供商配置无效：${e.message}');
  } on FormatException catch (e) {
    throw CtlFailure.badRequest('地址无效：${e.message}');
  }
}

/// 新 key 并进已有列表：[append] 时追加（同值去重），否则整份换成这一把。
List<AiApiKey> mergeCtlAiKeys(
  List<AiApiKey> current,
  String key, {
  required bool append,
}) {
  final String trimmed = key.trim();
  if (trimmed.isEmpty) throw const CtlFailure.badRequest('API Key 为空');
  if (!append) return <AiApiKey>[AiApiKey(trimmed)];
  return <AiApiKey>[
    for (final AiApiKey existing in current)
      if (existing.trimmed != trimmed) existing,
    AiApiKey(trimmed),
  ];
}

// ── TTS 声音 ─────────────────────────────────────────────────────────────────

/// `k=v` 参数。
({String key, String value}) parseCtlKeyValue(String raw) {
  final int eq = raw.indexOf('=');
  if (eq <= 0) throw CtlFailure.badRequest('参数必须写成 key=value，收到「$raw」');
  return (key: raw.substring(0, eq).trim(), value: raw.substring(eq + 1));
}

/// 把一组参数写进预设：引擎声明为 secret 的参数进 [TtsVoicePreset.secrets]，
/// 其余进 params；空值 = 删掉这一项。引擎没声明的键给 400（拼错的键会被静默
/// 忽略，用户以为配上了）——通用并发参数 [kTtsConcurrencyParam] 除外。
///
/// [secretSources] 标出哪些键的值来自 stdin / 环境变量：secret 参数**只**收这两
/// 个来源，不收命令行明文。
TtsVoicePreset applyCtlTtsParams(
  TtsVoicePreset preset,
  TtsProviderDescriptor descriptor,
  Map<String, String> values, {
  Set<String> secretSources = const <String>{},
}) {
  final Map<String, TtsParamSpec> specs = <String, TtsParamSpec>{
    for (final TtsParamSpec spec in descriptor.params) spec.key: spec,
  };
  final Map<String, String> params = Map<String, String>.of(preset.params);
  final Map<String, String> secrets = Map<String, String>.of(preset.secrets);
  for (final MapEntry<String, String> entry in values.entries) {
    final TtsParamSpec? spec = specs[entry.key];
    if (spec == null && entry.key != kTtsConcurrencyParam) {
      throw CtlFailure.badRequest(
        '引擎 ${descriptor.id} 没有参数「${entry.key}」；可选：'
        '${<String>[...specs.keys, kTtsConcurrencyParam].join(' | ')}',
      );
    }
    if (spec != null && spec.kind == TtsParamKind.choice) {
      if (entry.value.isNotEmpty &&
          spec.choices.isNotEmpty &&
          !spec.choices.contains(entry.value)) {
        throw CtlFailure.badRequest(
          '参数「${entry.key}」只能是 ${spec.choices.join(' | ')}',
        );
      }
    }
    final bool secret = spec?.kind == TtsParamKind.secret;
    if (secret && !secretSources.contains(entry.key)) {
      throw CtlFailure.badRequest(
        '「${entry.key}」是凭据，只能经 --secret-stdin / --secret-from-env 传入',
      );
    }
    final Map<String, String> target = secret ? secrets : params;
    if (entry.value.isEmpty) {
      target.remove(entry.key);
    } else {
      target[entry.key] = entry.value;
    }
  }
  return preset.copyWith(params: params, secrets: secrets);
}

/// 一份声音预设在应答里的形状：凭据只报「已设」不回显值。
Map<String, Object?> ctlTtsPresetJson(
  TtsVoicePreset preset, {
  required bool active,
  TtsProviderDescriptor? descriptor,
}) => <String, Object?>{
  'id': preset.id,
  'name': preset.name,
  'engine': preset.providerId,
  'active': active,
  'available': descriptor?.isAvailable ?? false,
  'params': preset.params,
  'secrets': <String>[
    for (final MapEntry<String, String> e in preset.secrets.entries)
      if (e.value.isNotEmpty) e.key,
  ],
  'problems': descriptor == null
      ? <String>['engine_missing']
      : descriptor.validate(preset),
  'revision': preset.revision,
};

/// 按 id 或名字（精确）找声音预设。
TtsVoicePreset resolveCtlTtsPreset(List<TtsVoicePreset> presets, String ref) {
  final String needle = ref.trim();
  for (final TtsVoicePreset preset in presets) {
    if (preset.id == needle) return preset;
  }
  final List<TtsVoicePreset> byName = <TtsVoicePreset>[
    for (final TtsVoicePreset preset in presets)
      if (preset.name == needle) preset,
  ];
  if (byName.length == 1) return byName.single;
  if (byName.length > 1) {
    throw CtlFailure.conflict('有 ${byName.length} 个名为「$ref」的声音，请用 id');
  }
  throw CtlFailure.notFound('没有声音「$ref」（voice ls 查看）');
}
