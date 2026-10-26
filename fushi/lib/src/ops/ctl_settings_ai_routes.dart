import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_wire.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 「设置 › 模型 › LLM」的控制通道路由（CLI 侧见
/// `packages/fushi_cli/lib/src/commands/settings_ai_commands.dart`）。
///
/// 读写与设置页同一对偏好口：提供商清单 `PreferencesRepository.aiProviders` /
/// `setAiProviders`，功能指派读**用户真实存的** `storedAiFeatureAssignments`（不是
/// 模块关着时投影成空的运行时口）、写 `setAiFeatureAssignments`。探测走同一个
/// [AiChatClient]（默认即统一出站装配点），失败短码经 [aiFailureText] 翻译。
///
/// 提供商 id 与设置页「添加提供商」同形（`ai-<微秒>`）；删一家同时
/// `withoutProvider` 清掉指向它的指派（含默认），与设置页 `_delete` 同一条纪律。
List<CtlRoute> buildSettingsAiCtlRoutes(OpContext context) => <CtlRoute>[
  CtlRoute.get('/api/admin/ai/presets', (CtlCall call) async => _listPresets()),
  CtlRoute.get(
    '/api/admin/ai/providers',
    (CtlCall call) async => _listProviders(context),
  ),
  CtlRoute.post(
    '/api/admin/ai/providers',
    (CtlCall call) => _addProvider(context, call),
  ),
  CtlRoute.put(
    '/api/admin/ai/providers/:id',
    (CtlCall call) => _updateProvider(context, call),
  ),
  CtlRoute.delete(
    '/api/admin/ai/providers/:id',
    (CtlCall call) => _deleteProvider(context, call),
  ),
  CtlRoute.post(
    '/api/admin/ai/providers/:id/probe',
    (CtlCall call) => _probeProvider(context, call),
  ),
  CtlRoute.get(
    '/api/admin/ai/features',
    (CtlCall call) async => _listFeatures(context),
  ),
  CtlRoute.put(
    '/api/admin/ai/features/:feature',
    (CtlCall call) => _assignFeature(context, call),
  ),
  CtlRoute.put(
    '/api/admin/ai/default',
    (CtlCall call) => _setDefault(context, call),
  ),
];

PreferencesRepository _prefs(OpContext context) => context.appModel.prefsRepo;

Map<String, Object?> _listPresets() => <String, Object?>{
  'presets': <Map<String, Object?>>[
    for (final AiProviderPreset preset in kAiProviderPresets)
      <String, Object?>{
        'id': preset.id,
        'name': preset.displayName,
        'protocol': preset.protocol.storageKey,
        'baseUrl': preset.baseUrl,
        'model': preset.suggestedModel,
        'requiresKey': preset.requiresApiKey,
        'local': preset.isLocal,
      },
  ],
};

Map<String, Object?> _listProviders(OpContext context) {
  final PreferencesRepository prefs = _prefs(context);
  final AiFeatureAssignments assignments = prefs.storedAiFeatureAssignments;
  return <String, Object?>{
    'moduleEnabled': context.appModel.moduleEnabled(ModuleId.ai),
    'defaultProviderId': assignments.defaultProviderId,
    'providers': <Map<String, Object?>>[
      for (final AiProviderConfig provider in prefs.aiProviders)
        <String, Object?>{
          ...ctlAiProviderJson(provider),
          'isDefault': provider.id == assignments.defaultProviderId,
        },
    ],
  };
}

/// API Key 只收 stdin / 环境变量（与 `config set` 机密项同一条纪律）。
String? _apiKeyOf(CtlCall call) {
  final String? key = call.optString('apiKey');
  if (key == null) return null;
  final String source = call.optString('apiKeySource') ?? 'argv';
  if (source != 'stdin' && source != 'env') {
    throw const CtlFailure.badRequest(
      'API Key 只能经 --key-stdin 或 --key-from-env 传入，不能写在命令行里',
    );
  }
  return key;
}

AiWireProtocol? _protocolOf(CtlCall call) {
  final String? raw = call.optString('protocol');
  return raw == null ? null : parseCtlAiProtocol(raw);
}

AiReasoningEffort? _reasoningOf(CtlCall call) {
  final String? raw = call.optString('reasoning');
  return raw == null ? null : parseCtlAiReasoning(raw);
}

Map<String, Object?> _providerResult(
  OpContext context,
  String action,
  AiProviderConfig provider,
) => <String, Object?>{
  'action': action,
  'provider': <String, Object?>{
    ...ctlAiProviderJson(provider),
    'isDefault':
        provider.id ==
        _prefs(context).storedAiFeatureAssignments.defaultProviderId,
  },
};

Future<Object?> _addProvider(OpContext context, CtlCall call) async {
  final String presetId = call.requireString('preset');
  final AiProviderPreset? preset = aiProviderPresetById(presetId);
  if (preset == null) {
    throw CtlFailure.badRequest(
      '没有预设「$presetId」；可选：'
      '${kAiProviderPresets.map((AiProviderPreset p) => p.id).join(' | ')}',
    );
  }
  final String? key = _apiKeyOf(call);
  final PreferencesRepository prefs = _prefs(context);
  final AiProviderConfig created = buildCtlAiProvider(
    preset,
    // 与设置页「添加提供商」同形的 id（`ai-<微秒>`），功能指派按它持久化。
    id: 'ai-${DateTime.now().microsecondsSinceEpoch}',
    name: call.optString('name'),
    baseUrl: call.optString('baseUrl'),
    model: call.optString('model'),
    protocol: _protocolOf(call),
    reasoning: _reasoningOf(call),
    enabled: call.optBool('enabled'),
    allowInsecureHttp: call.optBool('allowInsecureHttp'),
    rpm: call.optInt('rpm'),
    apiKeys: key == null
        ? const <AiApiKey>[]
        : <AiApiKey>[AiApiKey(key.trim())],
  );
  await prefs.setAiProviders(<AiProviderConfig>[...prefs.aiProviders, created]);
  if (call.optBool('makeDefault') == true) {
    await prefs.setAiFeatureAssignments(
      prefs.storedAiFeatureAssignments.withDefault(created.id),
    );
  }
  return _providerResult(context, '已添加', created);
}

Future<Object?> _updateProvider(OpContext context, CtlCall call) async {
  final PreferencesRepository prefs = _prefs(context);
  final List<AiProviderConfig> providers = prefs.aiProviders;
  final AiProviderConfig target = resolveCtlAiProvider(
    providers,
    call.params['id']!,
  );
  final String? key = _apiKeyOf(call);
  List<AiApiKey>? keys;
  if (call.optBool('clearKeys') == true) keys = const <AiApiKey>[];
  if (key != null) {
    keys = mergeCtlAiKeys(
      keys ?? target.apiKeys,
      key,
      append: call.optBool('appendKey') == true,
    );
  }
  final AiProviderConfig updated = updateCtlAiProvider(
    target,
    name: _clearableString(call, 'name'),
    baseUrl: call.optString('baseUrl'),
    model: _clearableString(call, 'model'),
    protocol: _protocolOf(call),
    reasoning: _reasoningOf(call),
    enabled: call.optBool('enabled'),
    allowInsecureHttp: call.optBool('allowInsecureHttp'),
    rpm: call.optInt('rpm'),
    apiKeys: keys,
  );
  await prefs.setAiProviders(<AiProviderConfig>[
    for (final AiProviderConfig provider in providers)
      provider.id == target.id ? updated : provider,
  ]);
  return _providerResult(context, '已更新', updated);
}

/// 可以清空的字符串字段：body 里显式给了空串 = 清空（[CtlCall.optString] 把空串当
/// 「没给」，那样原本为空的名称 / 模型一旦填过就再也写不回空——AI 撤销「改提供商」
/// 时要能原样写回）。没给这个键返回 null（不改）。
String? _clearableString(CtlCall call, String name) {
  final Object? raw = call.body[name];
  if (raw is String) return raw.trim();
  return call.optString(name);
}

Future<Object?> _deleteProvider(OpContext context, CtlCall call) async {
  if (call.optBool('confirm') != true) {
    throw const CtlFailure.badRequest('删除 AI 提供商需要 confirm=true');
  }
  final PreferencesRepository prefs = _prefs(context);
  final List<AiProviderConfig> providers = prefs.aiProviders;
  final AiProviderConfig target = resolveCtlAiProvider(
    providers,
    call.params['id']!,
  );
  await prefs.setAiProviders(<AiProviderConfig>[
    for (final AiProviderConfig provider in providers)
      if (provider.id != target.id) provider,
  ]);
  // 删一家必须同步清理指向它的功能指派（含默认），否则指派悬空。
  await prefs.setAiFeatureAssignments(
    prefs.storedAiFeatureAssignments.withoutProvider(target.id),
  );
  return <String, Object?>{
    'deleted': <String, Object?>{'id': target.id, 'name': target.displayName},
  };
}

/// 测试连接 / 拉模型列表，与设置页 `_probe` 同一套判据：`models=true` 拉列表；
/// 否则填了模型就 `ping`（真打 chat 端点），没填退回 `listModels`。
Future<Object?> _probeProvider(OpContext context, CtlCall call) async {
  final AiProviderConfig target = resolveCtlAiProvider(
    _prefs(context).aiProviders,
    call.params['id']!,
  );
  final bool collectModels = call.optBool('models') ?? false;
  final AiChatClient client = AiChatClient();
  try {
    if (collectModels || target.model.trim().isEmpty) {
      final List<String> models = await client.listModels(target);
      return <String, Object?>{
        'id': target.id,
        'ok': true,
        'checked': 'models',
        'models': models,
      };
    }
    await client.ping(target);
    return <String, Object?>{
      'id': target.id,
      'ok': true,
      'checked': 'chat',
      'model': target.model,
    };
  } on AiChatFailure catch (failure) {
    // failure.message 已是脱敏短码（不含 key / 完整 URL / 响应体原文）。
    throw CtlFailure(
      422,
      'probe_failed',
      '${target.displayName}：${aiFailureText(failure.message)}'
          '（${failure.message}）',
    );
  } finally {
    client.close();
  }
}

Map<String, Object?> _listFeatures(OpContext context) {
  final PreferencesRepository prefs = _prefs(context);
  final List<AiProviderConfig> providers = prefs.aiProviders;
  final AiFeatureAssignments assignments = prefs.storedAiFeatureAssignments;
  String? nameOf(String? id) {
    if (id == null) return null;
    for (final AiProviderConfig provider in providers) {
      if (provider.id == id) return provider.displayName;
    }
    return null;
  }

  return <String, Object?>{
    'moduleEnabled': context.appModel.moduleEnabled(ModuleId.ai),
    'defaultProviderId': assignments.defaultProviderId,
    'defaultProvider': nameOf(assignments.defaultProviderId),
    'features': <Map<String, Object?>>[
      for (final AiFeature feature in AiFeature.values)
        () {
          final String? explicit = assignments.providerIdFor(feature);
          final String? effective = assignments.effectiveProviderIdFor(feature);
          final AiProviderConfig? resolved = assignments.resolve(
            feature,
            providers,
          );
          return <String, Object?>{
            'feature': feature.name,
            'storageKey': feature.storageKey,
            'assignment': switch (explicit) {
              null => 'default',
              kAiFeatureDisabled => 'off',
              _ => explicit,
            },
            'effectiveProviderId': effective,
            'effectiveProvider': nameOf(effective),
            // 设置页同一判据：指派的那家被删 / 没配全时为 null（功能不发请求）。
            'usable': resolved != null,
          };
        }(),
    ],
  };
}

/// `default`（跟随默认）/ `off`（不用 AI）/ 提供商 id 或名字。
Future<Object?> _assignFeature(OpContext context, CtlCall call) async {
  final String raw = call.params['feature']!;
  final AiFeature? feature = parseCtlAiFeature(raw);
  if (feature == null) {
    throw CtlFailure.notFound(
      '没有 AI 功能「$raw」；可选：'
      '${AiFeature.values.map((AiFeature f) => f.name).join(' | ')}',
    );
  }
  final String target = call.requireString('provider');
  final PreferencesRepository prefs = _prefs(context);
  final String? providerId = switch (target.toLowerCase()) {
    'default' => null,
    'off' => kAiFeatureDisabled,
    _ => resolveCtlAiProvider(prefs.aiProviders, target).id,
  };
  await prefs.setAiFeatureAssignments(
    prefs.storedAiFeatureAssignments.withAssignment(feature, providerId),
  );
  return _listFeatures(context);
}

/// `none` 清掉默认；否则提供商 id 或名字。
Future<Object?> _setDefault(OpContext context, CtlCall call) async {
  final String target = call.requireString('provider');
  final PreferencesRepository prefs = _prefs(context);
  final String? providerId = isCtlNoneToken(target)
      ? null
      : resolveCtlAiProvider(prefs.aiProviders, target).id;
  await prefs.setAiFeatureAssignments(
    prefs.storedAiFeatureAssignments.withDefault(providerId),
  );
  return _listFeatures(context);
}
