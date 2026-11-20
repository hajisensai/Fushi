/// 显示名清洗：去掉文件名标题末尾的 `[8 位十六进制]` 哈希后缀（BUG-4898）。
///
/// 没刮到元数据的书 / 漫画以文件名当标题入库，下载工具常在文件名末尾带一段
/// 内容哈希（「十歳の最強魔導師 第16話 前編 [679fb7c9]」）。哈希对读者没有意义，
/// 还把书架卡的标题挤掉一截。
///
/// **只改显示，不改存储**：`epub_books.title` 仍是带哈希的原始文件名标题——它是
/// 身份（`bookKey = sanitizeTtuFilename(title)`、统计聚合键、同步资产键），绝不能
/// 经本函数改写。调用点只在书族的显示出口（`ReaderMediaSource
/// .getDisplayTitleFromMediaItem` 与 `displayTitleForBook` 的原名回退），用户自己
/// 改过的显示名（override）原样显示、不清洗。
library;

/// 末尾的 `[0-9a-f]{8}` 哈希段（连同它前面的空白、后面的尾随空白）。只认小写
/// 十六进制、恰好 8 位、方括号包住且在字符串末尾：卷号「[上]」、年份「[2024]」、
/// 中段的方括号都不动。
final RegExp _kTrailingHashSuffix = RegExp(r'\s*\[[0-9a-f]{8}\]\s*$');

/// 去掉 [title] 末尾的 `[8 位十六进制]` 哈希后缀；没有后缀原样返回。
///
/// 整个标题只有哈希（去掉后为空）时原样返回：宁可显示哈希也不显示空标题。
String stripTitleHashSuffix(String title) {
  final String stripped = title.replaceFirst(_kTrailingHashSuffix, '');
  return stripped.isEmpty ? title : stripped;
}
