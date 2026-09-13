/// 在线漫画来源的**用户可见名**：`名字 (语言码)`。
///
/// 一个 Mihon 扩展常常按语言拆成十几个同名来源（MyReadingManga 的 en/ja/zh/…
/// 各是一条 `MangaOnlineSourceRow`，只有 `language` 不同）。凡是只显示裸
/// `name` 的地方——发现页的来源下拉、每源「热门」行标题——用户看到的就是一
/// 列一模一样的名字，根本分不清选的是哪一条。语言码是唯一的区分维度，所以
/// 展示名固定把它带上；语言为空（个别扩展不声明）时退回裸名。
library;

/// 把来源名与语言码拼成展示名；[language] 为空时原样返回 [name]。
String mangaSourceDisplayName({
  required String name,
  required String language,
}) {
  final String trimmed = language.trim();
  if (trimmed.isEmpty) return name;
  return '$name (${trimmed.toUpperCase()})';
}
