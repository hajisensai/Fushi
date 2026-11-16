/// 提供商模型列表（`GET …/models`）里的一条：模型名之外，上游给了什么就带什么。
///
/// 存在的理由：模型的显示名、能不能收图、单价都是**上游的事实**，此前
/// `listModels` 只留下 id，其余全扔掉，用户只能照着厂商网页逐项手填（还常填错 /
/// 过期）。各家给的字段不一样，这里只解析确有其字段的那几家，没有的留 null——
/// 「上游没说」与「上游说不支持」必须分得开，前者不能拿来覆盖用户的设置：
///
/// - Anthropic `/v1/models`：`display_name`，`capabilities.image_input.supported`；
/// - OpenRouter 一类聚合商（OpenAI 兼容）：`name`，`architecture.input_modalities`，
///   `pricing.{prompt,completion,input_cache_read,input_cache_write}`（美元 / token，
///   字符串）；
/// - Gemini `models`：`name`（带 `models/` 前缀）与 `displayName`；
/// - OpenAI 官方等只回 `id` 的：只有 id。
library;

import 'package:fushi_engine/ai/ai_model_pricing.dart';

class AiUpstreamModel {
  const AiUpstreamModel({
    required this.id,
    this.displayName,
    this.acceptsImages,
    this.pricing,
  });

  /// 请求里要用的模型名（Gemini 已剥掉 `models/` 前缀）。
  final String id;

  /// 上游给的人类可读名；没给或与 [id] 相同时为 null。
  final String? displayName;

  /// 上游明说的「能否收图」；上游没给这项时为 null（不是 false）。
  final bool? acceptsImages;

  /// 上游给的单价（已换算成每百万 token、币种 USD）；没给或给的是哨兵值
  /// （OpenRouter 动态路由的 `-1`）时为 null。
  final AiModelPricing? pricing;

  /// 菜单里显示的名字。
  String get label => displayName ?? id;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (displayName != null) 'name': displayName,
    if (acceptsImages != null) 'images': acceptsImages,
    if (pricing != null) 'pricing': pricing!.toJson(),
  };
}

/// 解析模型列表应答体；形状不对返回空表（是否算错误由调用方按 body 类型判）。
///
/// 结果按 id 排序。
List<AiUpstreamModel> parseAiUpstreamModels(Map<Object?, Object?> body) {
  final List<AiUpstreamModel> models = <AiUpstreamModel>[];
  final Object? data = body['data'] ?? body['models'];
  if (data is List) {
    for (final Object? entry in data) {
      if (entry is Map) {
        final AiUpstreamModel? model = _parseEntry(entry);
        if (model != null) models.add(model);
      }
    }
  }
  models.sort((AiUpstreamModel a, AiUpstreamModel b) => a.id.compareTo(b.id));
  return List<AiUpstreamModel>.unmodifiable(models);
}

AiUpstreamModel? _parseEntry(Map<Object?, Object?> entry) {
  final Object? rawId = entry['id'] ?? entry['name'];
  if (rawId is! String || rawId.isEmpty) return null;
  // Gemini 回的是 `models/gemini-...`，剥掉前缀才是请求里要用的模型名。
  final String id = rawId.startsWith('models/') ? rawId.substring(7) : rawId;
  // OpenRouter 的 `name` 是显示名（id 另有）；Gemini 的 `name` 就是 id。
  final Object? rawName =
      entry['display_name'] ??
      entry['displayName'] ??
      (entry['id'] != null ? entry['name'] : null);
  final String? name = rawName is String ? rawName.trim() : null;
  return AiUpstreamModel(
    id: id,
    displayName: name == null || name.isEmpty || name == id ? null : name,
    acceptsImages: _acceptsImages(entry),
    pricing: _pricing(entry['pricing']),
  );
}

bool? _acceptsImages(Map<Object?, Object?> entry) {
  final Object? capabilities = entry['capabilities'];
  if (capabilities is Map) {
    final Object? image = capabilities['image_input'];
    if (image is Map && image['supported'] is bool) {
      return image['supported'] as bool;
    }
  }
  final Object? architecture = entry['architecture'];
  if (architecture is Map) {
    final Object? modalities = architecture['input_modalities'];
    if (modalities is List) return modalities.contains('image');
  }
  return null;
}

/// OpenRouter 口径：美元 / token 的字符串。输入与输出都给齐才算有单价——只有一半
/// 的价目算不出费用，填进去反而让人以为费用统计生效了。
AiModelPricing? _pricing(Object? raw) {
  if (raw is! Map) return null;
  final double? input = _perMillion(raw['prompt']);
  final double? output = _perMillion(raw['completion']);
  if (input == null || output == null) return null;
  return AiModelPricing(
    inputPerMillion: input,
    outputPerMillion: output,
    cacheReadPerMillion: _perMillion(raw['input_cache_read']),
    cacheWritePerMillion: _perMillion(raw['input_cache_write']),
  );
}

double? _perMillion(Object? raw) {
  final double? perToken = switch (raw) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s.trim()),
    _ => null,
  };
  // 负数是哨兵（动态路由 `-1`），不是价格。
  if (perToken == null || perToken.isNaN || perToken.isInfinite) return null;
  if (perToken < 0) return null;
  // 0.0000001 × 1e6 在浮点里是 0.09999999999999999；按 6 位小数收口。
  return double.parse((perToken * 1000000).toStringAsFixed(6));
}
