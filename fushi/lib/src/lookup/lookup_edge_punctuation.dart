// 查词串「首尾标点 / 符号剥离」的单一真相。
//
// 查词前 `normalizeSearchTerm`（app_model.dart）用 [lookupEdgePunctuationRegex]
// 剥掉查询串句首 / 句尾的标点与符号（『「"（ 等），引擎从剥离串的 0 位匹配，回报的
// 匹配长度也以剥离串为坐标系。任何要把匹配长度画回**原始**文本的界面（剪贴板面板
// BUG-773、视频字幕查词高亮 BUG-2091）都必须先跳过这段被剥掉的句首前缀，否则高亮
// 落在括号上、尾部少一截。
//
// 独立成文件是为了让不依赖 AppModel 的取词层（`subtitleTranscriptLookupSpan`）与
// AppModel 的查词清洗共用同一条正则，不各写一份。
library;

/// 查询串首尾标点 / 符号（Unicode `\p{P}` + `\p{S}`）。
final RegExp lookupEdgePunctuationRegex = RegExp(
  r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$',
  unicode: true,
);

/// [punctuationRegex]（`^[\p{P}\p{S}]+|[\p{P}\p{S}]+$`）在查词前会剥掉 [raw] 的
/// **句首**标点 / 符号；返回被剥掉的 UTF-16 code unit 数（无句首标点 = 0）。
///
/// 只取句首分支（`match.start == 0` 的命中）；只有句尾标点时命中不在句首，返回 0。
/// 整串都是标点时返回整串长度。
int leadingPunctuationStripUnits(String raw, RegExp punctuationRegex) {
  if (raw.isEmpty) return 0;
  final Match? m = punctuationRegex.firstMatch(raw);
  return (m != null && m.start == 0) ? m.end : 0;
}
