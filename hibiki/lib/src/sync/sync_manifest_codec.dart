/// 同步清单共享编解码骨架（代码收敛：合集清单与云视频清单的公共部分，此前两处
/// 逐字重复）。
///
/// 仓库里的同步载荷有**两种刻意不同的契约**，勿混为一谈：
///
/// - **严格清单**（合集 / 云视频）：结构非法或版本过新一律抛 [FormatException]。
///   调用方把该文件当损坏跳过、且**不推进同步基线**——绝不能按旧语义误读新字段
///   后把降级结果写回远端毒害新端数据（与 DB 降级保护同一律）。本文件服务这类。
/// - **宽松快照**（`AggregateSnapshot` 聚合统计+收藏）：单调并集语义（MAX/并集
///   折叠），读不懂降级为空快照即安全无损，永不 abort 整轮 sweep。它**不走**本
///   文件的严格入口，见其类注释的版本策略说明。
library;

import 'dart:convert';

/// 校验 [json] 是 JSON object，返回类型化 Map；否则抛 [FormatException]
/// （文案 `<label>: not a JSON object`，与收敛前逐字一致）。
Map<String, dynamic> requireManifestObject(Object? json, String label) {
  if (json is! Map<String, dynamic>) {
    throw FormatException('$label: not a JSON object');
  }
  return json;
}

/// 校验并返回清单 `version`：非 int / <1 抛 `bad version`；严格大于
/// [currentVersion]（更新版 app 写的清单）抛 `newer than supported`——宁可跳过
/// 本轮该维度同步，也不能按旧语义误读新字段后把降级结果写回破坏新端数据。
int requireManifestVersion(
  Map<String, dynamic> json, {
  required int currentVersion,
  required String label,
}) {
  final Object? version = json['version'];
  if (version is! int || version < 1) {
    throw FormatException('$label: bad version');
  }
  if (version > currentVersion) {
    throw FormatException(
        '$label: version $version is newer than supported $currentVersion');
  }
  return version;
}

/// 校验 [json] 的 [key] 字段是 List 并返回；否则抛 [FormatException]
/// （文案 `<label>: bad <key>`，与收敛前逐字一致）。
List<Object?> requireManifestList(
  Map<String, dynamic> json,
  String key,
  String label,
) {
  final Object? raw = json[key];
  if (raw is! List) throw FormatException('$label: bad $key');
  return raw;
}

/// 「内容相等 ⇒ 字节相等」的规范化 JSON 契约（接口而非 mixin——带 mixin 的类
/// 不能有 const 构造器，而清单类型都要 `const empty`；canonicalJson 也不做成
/// 扩展方法——扩展要求每个调用点额外导入本文件，为一行 jsonEncode 不值得）。
///
/// 实现方保证 [contentJson] 输出**确定性排序**，并把 [canonicalJson] 实现为
/// `jsonEncode(contentJson())`（[canonicalManifestJson] 供直接复用）。它是变更
/// 检测 / 回写门槛的唯一判据——编排器靠它决定要不要回写远端，避免反复同步产生
/// 写放大。文件级元数据（如 `CollectionManifest.lastWrittenAt` 写盘时戳）
/// **不进** [contentJson]，否则每轮重盖时戳会让门槛永远误判「内容变了」。
abstract interface class CanonicalJsonManifest {
  /// 完整写盘 JSON（可含文件级元数据）。
  Map<String, dynamic> toJson();

  /// 内容身份 JSON（确定性排序）。无文件级元数据的类型直接 `=> toJson()`。
  Map<String, dynamic> contentJson();

  /// 规范化 JSON 字符串（供变更检测；实现 = [canonicalManifestJson]）。
  String canonicalJson();
}

/// [CanonicalJsonManifest.canonicalJson] 的标准实现。
String canonicalManifestJson(CanonicalJsonManifest manifest) =>
    jsonEncode(manifest.contentJson());
