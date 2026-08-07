/// 收藏句 / 制卡句「跳回原文」的**阅读器路由**契约（BUG-1316）。
///
/// 此前本文件断言 `mediaSourceIdentifier` 恒等于 `reader_ttu`——那正是缺陷本身：
/// 收藏页手工伪造 `MediaItem` 时写死 EPUB 源，漫画 / PDF 书从收藏页跳回原文永远
/// 打开 EPUB 阅读器（漫画行的 `epubPath` 是 `manga.json`、`chaptersJson` 是 `'[]'`，
/// 落进 EPUB 阅读器直接在解析路径出错）。契约已改为「按当前 `EpubBooks.format`
/// 派生」，故那条旧断言必红——是契约变更，不是回归。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  group('buildCollectionReaderMediaItem', () {
    test('mediaIdentifier 与书架同构，且与 format 无关', () {
      for (final BookFormat format in BookFormat.values) {
        final MediaItem opened = buildCollectionReaderMediaItem(
          bookKey: 'MyBook',
          title: 'MyBook',
          format: format,
        );
        expect(opened.mediaIdentifier, 'fushi://book/MyBook',
            reason: '身份是 bookKey，转化前后必须一致（$format）');
        expect(opened.title, 'MyBook');
      }
    });

    test('阅读器源按当前 format 三态分流（漫画/PDF 不得落进 EPUB 阅读器）', () {
      expect(
        buildCollectionReaderMediaItem(
          bookKey: 'k',
          title: 't',
          format: BookFormat.epub,
        ).mediaSourceIdentifier,
        ReaderHibikiSource.instance.uniqueKey,
      );
      expect(
        buildCollectionReaderMediaItem(
          bookKey: 'k',
          title: 't',
          format: BookFormat.manga,
        ).mediaSourceIdentifier,
        MangaHibikiSource.kUniqueKey,
      );
      expect(
        buildCollectionReaderMediaItem(
          bookKey: 'k',
          title: 't',
          format: BookFormat.pdf,
        ).mediaSourceIdentifier,
        ReaderPdfSource.kUniqueKey,
      );
    });

    test('与书架列书共用同一派生点 ReaderHibikiSource.mediaSourceKeyFor', () {
      for (final BookFormat format in BookFormat.values) {
        expect(
          buildCollectionReaderMediaItem(
            bookKey: 'k',
            title: 't',
            format: format,
          ).mediaSourceIdentifier,
          ReaderHibikiSource.mediaSourceKeyFor(format),
          reason: '两条入口一旦各写各的，漫画/PDF 就会在其中一条上永远错（$format）',
        );
      }
    });
  });

  group('ReaderHibikiSource.mediaSourceKeyFor', () {
    test('三种 format 各自映射到不同的源键（不得出现两态合并）', () {
      final Set<String> keys =
          BookFormat.values.map(ReaderHibikiSource.mediaSourceKeyFor).toSet();
      expect(keys.length, BookFormat.values.length,
          reason: '任意两种 format 共用一个源键 = 其中一种被用错阅读器打开');
    });
  });
}
