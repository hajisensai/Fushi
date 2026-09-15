import 'package:fushi_engine/epub/epub_book.dart';
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
          fragment: tocHrefFragment(item.href),
        ));
      }
      walk(item.children, item.label);
    }
  }

  walk(items, null);
  return result;
}

/// 目录 href 的 `#fragment`（章内锚），没有 / 为空时 null。
///
/// 口径与 [EpubBook.resolveInternalLink] 一致：那里取 `Uri.fragment`（percent
/// 已解码），锚点最终喂给 WebView 的 `getElementById`，两条路径必须给出同一个
/// id，否则目录跳转和点书里的内链会落在不同地方。href 是不可信输入，
/// percent 转义坏了就退回原文，绝不因此丢掉整条目录项。
String? tocHrefFragment(String? href) {
  if (href == null) return null;
  final int hash = href.indexOf('#');
  if (hash < 0 || hash + 1 >= href.length) return null;
  final String raw = href.substring(hash + 1);
  if (raw.isEmpty) return null;
  try {
    final String decoded = Uri.decodeComponent(raw);
    return decoded.isEmpty ? null : decoded;
  } on ArgumentError {
    return raw;
  }
}

/// 阅读位置（spine 章号 [currentChapter]）落在目录的哪一章上：返回该目录项的
/// [TtuTocEntry.index]，目录里没有任何一项在当前位置之前时返回 null。
///
/// **目录是 spine 的稀疏映射**，不是一对一：真实 EPUB 里同一章常常横跨多个
/// xhtml（`part0008` + `part0009` + …只有第一个进目录），章间的插图页 / 扉页
/// 更是根本不在目录里。实测一本 35 项 spine 的文库本，NCX 只指向 12 个 spine
/// 位置——读在剩下 23 个位置上的任何时刻，「当前章 == 目录项 index」都不成立。
///
/// 所以判据是**最后一个不晚于当前位置的目录项**（floor），与
/// `ReaderFushiPage._currentChapterLabelFor`（页脚 / 收藏写入用的章名）和
/// `ReaderAudiobookPanel` 「章节」tab 的当前章标注同一口径；此前目录列表用的是
/// 精确相等，于是绝大多数阅读位置一行都不标（BUG-2545）。
///
/// 同一 spine 章有多条目录项（一个 xhtml 装整卷、目录靠 `#anchor` 分节）时，本
/// 函数返回的 index 会同时命中那几条 —— 与精确相等时代的行为一致（调用方据此
/// 把它们全部标成当前章，滚动锚点取其中第一条）。
int? resolveCurrentTocChapter(List<TtuTocEntry> toc, int? currentChapter) {
  if (currentChapter == null) return null;
  int? resolved;
  for (final TtuTocEntry entry in toc) {
    if (entry.isHeader || entry.index > currentChapter) continue;
    if (resolved == null || entry.index > resolved) resolved = entry.index;
  }
  return resolved;
}
