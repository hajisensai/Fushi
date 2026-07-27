import 'package:flutter/widgets.dart';

import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

/// 顶层漫画库页（中文按域叫「漫画书架」）。
///
/// 数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异是只展示
/// `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
///
/// 命名：`shelf` 在本仓命名术语表里已冻结给 `ShelfEntries`（条目排序/归属映射
/// 层），页面统称 library page，因此这里叫 `MangaLibraryPage` 而不是
/// `MangaShelfPage`（BUG-1164）。
class MangaLibraryPage extends StatelessWidget {
  const MangaLibraryPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const ReaderHibikiHistoryPage(mangaOnly: true);
}
