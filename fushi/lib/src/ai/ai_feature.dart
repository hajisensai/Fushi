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
/// 枚举而不是裸字符串，是为了让「新增一个 AI 功能」必须同时面对映射 UI、默认值
/// 和持久化三处，不会漏。所有功能共守一条边界：**AI 只产出配置或在已取回的候选里
/// 做排序/选择，热路径永远是本地确定性代码**；没指派提供商时行为与没有 AI 完全一致。
enum AiFeature {
  /// galgame 文本处理：让 AI 按自然语言描述生成正则替换规则。
  galgameTextProcess,

  /// 词典弹窗样式：按自然语言描述生成可视化规则 + 补充 CSS（进草稿，不直接保存）。
  dictStyle,

  /// Lapis 卡片样式：按自然语言描述生成可视化规则 + 用户区段 CSS（进编辑器草稿）。
  lapisStyle,

  /// 视频刮削身份消解：在线源给出多个候选时由 AI 在候选里选唯一命中，低置信仍进
  /// 「待确认」。
  videoIdentify,

  /// 视频搜索辅助：后台补字幕重排（`aiSubtitleBackfillReorder`）；页面上的排序 /
  /// 补词按钮已于 2026-09-22 移除。
  videoSearch,

  /// 自定义主题：按自然语言描述生成一组角色配色（进编辑页草稿，不直接应用）。
  customTheme,

  /// AI 下视频：把用户一句话解析成结构化意图 + 多义作品选择 + 版本 tie-break，
  /// 三处共用这一个指派。热路径（搜作品 / 搜资源 / 选版本 / 入队 / 建订阅）仍是
  /// 本地确定性代码，AI 输出里没有自由文本字段。
  videoAcquire;

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
