import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';

/// TODO-1333: 纯函数——把 EPUB 的树状目录（[EpubTocItem]）压平成阅读器用的
/// [TtuTocEntry] 线性章节列表。每个节点用 [hrefToChapterIndex] 把 nav href 解析成
/// 章号（解析不到返回 <0 的项跳过），并递归压平子节点，父节点标签透传给子项的
/// [TtuTocEntry.parent]。
///
/// **刻意不隐藏任何章**。历史上（TODO-1128 图片合并方案 A）这里会把「被吸收进后续
/// 文本章的单图片章」（EpubSpreadMap.isAbsorbedImageChapter）从目录里过滤掉，理由是
/// 被吸收章没有自己的虚拟页、点目录会跳到不存在的页。但 TODO-1128 去重修复
/// (commit 7a2a85a95) 已给所有裸导航入口加了 `_resolveNavChapter`——包括目录点击
/// (`onJumpSection` → `_navigateToChapter(manual: true)`)——被吸收章的跳转会被重定向
/// 到宿主文本章章首（那张图内联在宿主正文顶部）。过滤的前提（跳到不存在的页）因此
/// 不再成立，过滤既冗余又有害：当一本书的目录项**大量/全部**指向会被吸收的图片章
/// （例如一长串插图/图片页被一个尾部文本章——奥付/后记——整段吸收）时，压平结果会
/// 变成空表，**整个章节列表消失**（TODO-1333）。所以这里保留所有解析得到的章，交给
/// 导航层重定向，永不因合并而清空目录。
List<TtuTocEntry> flattenTtuTocEntries(
  List<EpubTocItem> items,
  int Function(String? href) hrefToChapterIndex,
) {
  final List<TtuTocEntry> result = <TtuTocEntry>[];
  void walk(List<EpubTocItem> nodes, String? parentLabel) {
    for (final EpubTocItem item in nodes) {
      final int index = hrefToChapterIndex(item.href);
      if (index >= 0) {
        result.add(TtuTocEntry(
          index: index,
          label: item.label,
          parent: parentLabel,
        ));
      }
      walk(item.children, item.label);
    }
  }

  walk(items, null);
  return result;
}
