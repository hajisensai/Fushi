import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_library_page.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/media/sources/manga_hibiki_source.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/media_library_shell.dart';
import 'package:hibiki/src/pages/implementations/media_sources_page.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

/// BUG-1164：PR#474 让书架按 `mangaOnly` 分流（普通书架排除漫画，漫画只在独立
/// 漫画书架出现），但全仓 `git grep 'MangaLibraryPage\|mangaOnly' -- hibiki/test`
/// 零命中——这条用户直接可见的行为一条测试都没有。
///
/// 这里守两件事：
/// 1. 分流谓词本身（互补、无遗漏、无重复）；
/// 2. 漫画库页确实带 `mangaOnly: true` 接进同一个书架实现，没有接反。
MediaItem _item(String identifier, String sourceKey) => MediaItem(
      mediaIdentifier: identifier,
      title: identifier,
      mediaTypeIdentifier: 'reader',
      mediaSourceIdentifier: sourceKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );

void main() {
  final MediaItem manga1 = _item('m1', MangaHibikiSource.kUniqueKey);
  final MediaItem manga2 = _item('m2', MangaHibikiSource.kUniqueKey);
  final MediaItem novel = _item('n1', ReaderHibikiSource.instance.uniqueKey);
  final MediaItem other = _item('o1', 'some_other_source');
  final List<MediaItem> corpus = <MediaItem>[manga1, novel, manga2, other];

  group('书架/漫画书架条目分流', () {
    test('普通书架排除全部漫画条目，其余原样保留（含顺序）', () {
      expect(
        filterShelfEntriesByMangaSplit(corpus, mangaOnly: false),
        <MediaItem>[novel, other],
      );
    });

    test('漫画书架只保留漫画条目（含顺序）', () {
      expect(
        filterShelfEntriesByMangaSplit(corpus, mangaOnly: true),
        <MediaItem>[manga1, manga2],
      );
    });

    test('两个书架互补：并集 = 全集，交集为空，没有条目凭空消失', () {
      final List<MediaItem> normal =
          filterShelfEntriesByMangaSplit(corpus, mangaOnly: false);
      final List<MediaItem> mangaShelf =
          filterShelfEntriesByMangaSplit(corpus, mangaOnly: true);
      expect(normal.length + mangaShelf.length, corpus.length,
          reason: '分流不得吞条目，也不得让条目同时出现在两个书架');
      expect(<MediaItem>{...normal, ...mangaShelf}, corpus.toSet());
      expect(normal.toSet().intersection(mangaShelf.toSet()), isEmpty);
    });

    test('空输入两侧都是空列表', () {
      expect(
          filterShelfEntriesByMangaSplit(const <MediaItem>[], mangaOnly: false),
          isEmpty);
      expect(
          filterShelfEntriesByMangaSplit(const <MediaItem>[], mangaOnly: true),
          isEmpty);
    });

    testWidgets('漫画库页的书架视图接的是 mangaOnly: true 的书架实现（没接反）',
        (WidgetTester tester) async {
      // 只取 build 的产物，不真正挂载子树：整页依赖 DB / WebView / 一堆 provider，
      // 挂起来就成了「测环境」而不是测这条接线。漫画库页现在是三视图壳
      // （书架 / 浏览 / 来源），书架仍是其中一个视图——穿过壳取该视图的产物。
      Widget? built;
      await tester.pumpWidget(
        Builder(builder: (BuildContext context) {
          built = const MangaLibraryPage().build(context);
          return const SizedBox.shrink();
        }),
      );
      expect(built, isA<MediaLibraryShell>());
      final MediaLibraryShell shell = built! as MediaLibraryShell;
      // 三视图齐全且顺序固定：书架在最前（进 tab 的默认落点）。
      expect(
        shell.views.map((MediaLibraryViewSpec v) => v.kind).toList(),
        <MediaLibraryViewKind>[
          MediaLibraryViewKind.library,
          MediaLibraryViewKind.browse,
          MediaLibraryViewKind.sources,
        ],
      );
      final Widget shelf = shell.views.first.builder(
          tester.element(find.byType(SizedBox)), const SizedBox.shrink());
      expect(shelf, isA<ReaderHibikiHistoryPage>());
      expect((shelf as ReaderHibikiHistoryPage).mangaOnly, isTrue);
      // 「来源」视图必须是漫画种类，不能误接成 book（那会把书的扫描根显示在漫画域）。
      final Widget sources = shell.views.last.builder(
          tester.element(find.byType(SizedBox)), const SizedBox.shrink());
      expect(sources, isA<MediaSourcesPage>());
      expect((sources as MediaSourcesPage).mediaKind, 'manga');
      // 反向锚：普通书架的默认值必须仍是 false，否则漫画会在两边都出现。
      expect(const ReaderHibikiHistoryPage().mangaOnly, isFalse);
    });
  });
}
