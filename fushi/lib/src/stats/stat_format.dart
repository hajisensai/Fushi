/// 统计页的时长 / 词数外显（只依赖 i18n 与 [formatStatCharsAxis]）。
///
/// 从 `stat_shared.dart` 挪下来：统计层（目标标签 `study_goals.dart` 等）要用同一份
/// 文案，而 `stat_shared` 是读 AppModel 的 UI 件，统计层 import 它会被拖进大 import 环。
/// `stat_shared` 原样 re-export，既有调用点不变。
library;

import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/pages/implementations/stat_charts.dart'
    show formatStatCharsAxis;

/// 统计页时长外显：不足 1 小时套 i18n 分钟文案，否则套 i18n 时+分文案。
String formatStatTime(int ms) {
  final int totalMin = ms ~/ 60000;
  if (totalMin < 60) return t.stat_format_minutes(n: totalMin);
  final int h = totalMin ~/ 60;
  final int m = totalMin % 60;
  return t.stat_format_hours_minutes(h: h, m: m);
}

/// `formatStatChars` 的「词」版：目标语言用空格分词时（`StudyGoalUnit.words`）
/// 目标数值的外显。计数口径相同，只换单位文案。
String formatStatWords(int words) =>
    t.stat_format_words(n: formatStatCharsAxis(words));

/// 热力图气泡日期标签：`M-dd`；跨年补年份成 `Y-M-dd`。[dateKey] 形如 `2026-07-18`
/// （`statDateKey` 格式）；无法解析时原样返回。
String formatStatHeatmapDay(String dateKey) {
  final DateTime? d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final DateTime now = DateTime.now();
  final String dd = d.day.toString().padLeft(2, '0');
  if (d.year == now.year) return '${d.month}-$dd';
  return '${d.year}-${d.month}-$dd';
}
