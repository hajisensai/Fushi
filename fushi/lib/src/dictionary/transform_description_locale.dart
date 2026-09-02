import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 词形变化语法说明译文资产的目录（`assets/transforms/i18n/<localeTag>.json`）。
///
/// 每个文件是一张扁平的「英文原文 → 译文」表，键就是 `assets/transforms/<lang>.json`
/// 里 `description` 字段的原文（逐字，含换行）。为什么按原文作键见
/// [TransformDescriptionCatalog] 的类注释。
const String kTransformDescriptionI18nDir = 'assets/transforms/i18n';

/// 把界面语言 [localeTag] 对应的语法说明译文装载进 [TransformDescriptionCatalog]。
///
/// 解析顺序是「完整标签 → 仅语言」：`zh-CN` 先找 `zh-CN.json`，没有再找 `zh.json`。
/// 两个都没有（英文界面、或这门界面语言还没人翻）就 [TransformDescriptionCatalog.clear]
/// 回落英文原文——**不保留上一次装载的表**，否则从中文切到德语会留着中文译文。
///
/// 只改一张内存表，不碰词典引擎里那份 JSON（引擎里始终是英文原文），所以换界面语言
/// 可以即时生效，不需要重新初始化引擎、也不需要重启（BUG-2038）。
Future<void> applyTransformDescriptionLocale(String localeTag) async {
  for (final String candidate in transformDescriptionLocaleCandidates(
    localeTag,
  )) {
    final Map<String, String>? table = await _loadTable(candidate);
    if (table == null) continue;
    TransformDescriptionCatalog.apply(
      localeTag: candidate,
      translations: table,
    );
    return;
  }
  TransformDescriptionCatalog.clear();
}

/// `zh-CN` → `['zh-CN', 'zh']`；`zh` → `['zh']`。分隔符按 BCP-47 的 `-`，同时容忍
/// Dart `Locale.toString()` 那种下划线写法（`zh_CN`）。
List<String> transformDescriptionLocaleCandidates(String localeTag) {
  final String tag = localeTag.trim();
  if (tag.isEmpty) return const <String>[];
  final String normalized = tag.replaceAll('_', '-');
  final int cut = normalized.indexOf('-');
  if (cut <= 0) return <String>[normalized];
  return <String>[normalized, normalized.substring(0, cut)];
}

Future<Map<String, String>?> _loadTable(String tag) async {
  final String raw;
  try {
    raw = await rootBundle.loadString(
      '$kTransformDescriptionI18nDir/$tag.json',
    );
  } catch (_) {
    // 资产不存在 = 这门界面语言没有译文，属正常回落，不记错误日志。
    return null;
  }
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        if (e.key is String &&
            e.value is String &&
            (e.value as String).isNotEmpty)
          e.key as String: e.value as String,
    };
  } catch (e) {
    debugPrint('[transformDescriptionLocale] bad asset $tag.json: $e');
    return null;
  }
}
