import 'package:flutter/widgets.dart';

import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

/// 顶层漫画书架。
///
/// 数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异是只展示
/// `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
class MangaShelfPage extends StatelessWidget {
  const MangaShelfPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const ReaderHibikiHistoryPage(mangaOnly: true);
}
