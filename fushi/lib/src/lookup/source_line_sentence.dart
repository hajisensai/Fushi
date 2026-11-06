/// 「查词出自外部一行原文」时制卡 `{sentence}` 的补全规则（BUG-2900 / 反馈 1Mwaro8UTC）。
///
/// 截屏识字、拍照查词、悬浮字幕点字这些入口都是「整行原文 + 被点的字」：查的是从被点
/// 字起扫出来的词，弹窗 JS 制卡时不带 `sentence`，例句只能由宿主补。两个宿主共用本规则：
///
/// - app 外独立查词窗（[PopupDictionaryPage]，Android 系统球的截屏识字）；
/// - 主窗常驻查词宿主（[FloatingLyricLookupHost]，悬浮球拍照查词 / iOS 截屏识字 /
///   悬浮字幕点字）。
///
/// 只补**基础层**（index 0）且基础层当前查询串**等于**出自这一行的查询串：嵌套层查的是
/// 释义里的词，原地跳到释义里别的词（链接 / 词头 / 汉字）后当前词条也不再出自这行，
/// 这两种都不补。不能用「是这行的子串」判——跳到的词（如「天」）恰好也是行的子串时会把
/// 整行误填进无关词条。
library;

import 'package:fushi/src/lookup/overlay_bridge_handlers.dart'
    show resolveMineSentence;

/// 给第 [layerIndex] 层的制卡 / 覆写字段补上出自原文那一行的例句 [sentence]。
///
/// [baseTerm] 是基础层当前的查询串，[sourceQuery] 是最近一次出自这一行的查询串；两者
/// 不等、[sentence] 为空或不是基础层时原样返回 [fields]。JS 送来的非空 `sentence` 仍
/// 优先（[resolveMineSentence]）。
Map<String, String> withSourceLineSentence(
  Map<String, String> fields, {
  required int layerIndex,
  required String baseTerm,
  required String sourceQuery,
  required String sentence,
}) {
  if (layerIndex != 0) return fields;
  final String query = sourceQuery.trim();
  if (sentence.isEmpty || query.isEmpty) return fields;
  if (baseTerm.trim() != query) return fields;
  return <String, String>{
    ...fields,
    'sentence': resolveMineSentence(fields, sentence),
  };
}
