/// 「哪个功能用哪家 AI」的映射。
///
/// 与提供商清单分开存：一家提供商可以被多个功能选中，删掉一家提供商时映射要能
/// 优雅退化成「未指派」而不是指向一个不存在的 id（[AiFeatureAssignments.resolve]
/// 负责这层校验）。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_provider_config.dart';

/// 可以指派 AI 提供商的功能。
///
/// 现在只有一个——游戏文本处理。枚举而不是裸字符串，是为了让「新增一个 AI 功能」
/// 必须同时面对映射 UI、默认值和持久化三处，不会漏。
enum AiFeature {
  /// galgame 文本处理：让 AI 按自然语言描述生成正则替换规则。
  galgameTextProcess;

  String get storageKey => name;

  static AiFeature? fromStorageKey(String? key) {
    if (key == null) {
      return null;
    }
    for (final AiFeature feature in AiFeature.values) {
      if (feature.storageKey == key) {
        return feature;
      }
    }
    return null;
  }
}

/// 功能 → 提供商 id 的映射。不可变。
class AiFeatureAssignments {
  const AiFeatureAssignments({
    this.providerIdByFeature = const <AiFeature, String>{},
  });

  factory AiFeatureAssignments.fromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const AiFeatureAssignments();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const AiFeatureAssignments();
    }
    if (decoded is! Map) {
      return const AiFeatureAssignments();
    }
    final Map<AiFeature, String> map = <AiFeature, String>{};
    decoded.forEach((Object? key, Object? value) {
      final AiFeature? feature = AiFeature.fromStorageKey(
        key is String ? key : null,
      );
      if (feature != null && value is String && value.trim().isNotEmpty) {
        map[feature] = value;
      }
    });
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(map),
    );
  }

  final Map<AiFeature, String> providerIdByFeature;

  String? providerIdFor(AiFeature feature) => providerIdByFeature[feature];

  /// 解析出这个功能**当前真能用**的提供商。
  ///
  /// 三种情况都退化成 null，由调用方统一提示「先去设置里配一家 AI」：
  /// 没指派、指派的那家已被删掉、指派的那家没配全（[AiProviderConfig.isUsable]）。
  /// 刻意**不**自动回退到「列表里第一家可用的」——静默换一家 AI 跑，用户既不知情
  /// 也没法解释为什么结果变了。
  AiProviderConfig? resolve(
    AiFeature feature,
    Iterable<AiProviderConfig> providers,
  ) {
    final String? id = providerIdByFeature[feature];
    if (id == null) {
      return null;
    }
    for (final AiProviderConfig provider in providers) {
      if (provider.id == id) {
        return provider.isUsable ? provider : null;
      }
    }
    return null;
  }

  AiFeatureAssignments withAssignment(AiFeature feature, String? providerId) {
    final Map<AiFeature, String> next = Map<AiFeature, String>.of(
      providerIdByFeature,
    );
    if (providerId == null || providerId.trim().isEmpty) {
      next.remove(feature);
    } else {
      next[feature] = providerId;
    }
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(next),
    );
  }

  /// 删掉一家提供商后清理指向它的映射。
  AiFeatureAssignments withoutProvider(String providerId) {
    final Map<AiFeature, String> next = <AiFeature, String>{
      for (final MapEntry<AiFeature, String> e in providerIdByFeature.entries)
        if (e.value != providerId) e.key: e.value,
    };
    return AiFeatureAssignments(
      providerIdByFeature: Map<AiFeature, String>.unmodifiable(next),
    );
  }

  String toJson() => jsonEncode(<String, String>{
    for (final MapEntry<AiFeature, String> e in providerIdByFeature.entries)
      e.key.storageKey: e.value,
  });
}
