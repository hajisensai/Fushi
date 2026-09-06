import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 导入 / 书架加载路径的「全列全表读」与 N+1 守卫（性能三轮优化第一轮）。
///
/// 根因：`epub_books` 的 `chaptersJson` / `tocJson` 是每本几十到几百 KB 的大列，
/// 而 `getAllEpubBooks()` 把整库全列拉出来。只要 title / uid / importedAt 的调用方
/// （三个导入器的重复检查、书架映射、统计事实面、远端去重、来源库扫描）此前全走它，
/// 每导入一本书就把整个库的章节 JSON 从 SQLite 读一遍再丢掉。这些调用方必须走瘦
/// 投影 `getEpubBookMetas()`；`watchEpubBookKeys` 只投影 key 列。
///
/// 书架列书曾对每本各查一次阅读位置（`findByBookUid`，Drift 单连接串行，
/// `Future.wait` 重叠不了 SQL），现在一次 `findAllByBookUid()` 取完；有声书健康度
/// 同理走 `resolveAllHealth`。源码级守卫是这些私有方法的最强可落地层。
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  group('metadata-only callers do not pull chaptersJson', () {
    const List<String> thinCallers = <String>[
      'lib/src/epub/epub_importer.dart',
      'lib/src/pdf/pdf_importer.dart',
      'lib/src/media/manga/manga_importer.dart',
      'lib/src/media/source_library/source_library_scanner.dart',
      'lib/src/stats/stat_facts.dart',
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
      'lib/src/pages/implementations/reader_history/books.part.dart',
      'lib/src/pages/implementations/reader_history/remote.part.dart',
      'lib/src/media/collections/collection_one_key_sort.dart',
      'lib/src/media/tracking/media_tracking_repository.dart',
      'lib/src/pages/implementations/collections_page.dart',
      'lib/src/media/manga/online/mokuro_moe_catalog_view.dart',
    ];
    for (final String rel in thinCallers) {
      test(rel, () {
        final String src = read(rel);
        expect(src.contains('getAllEpubBooks()'), isFalse,
            reason: '$rel 只要元数据列，必须走 getEpubBookMetas()');
        expect(src.contains('getEpubBookMetas()'), isTrue);
      });
    }

    test('reader_fushi_source: only the shelf materialiser reads full rows',
        () {
      final String src = read('lib/src/media/sources/reader_fushi_source.dart');
      // getBooksFromDb 需要 chaptersJson 算进度：允许恰好一处全行读。
      expect('getAllEpubBooks()'.allMatches(src).length, 1,
          reason: 'epubBookUidByKeyProvider 等只要 uid 的口径走瘦投影');
      expect(src.contains('getEpubBookMetas()'), isTrue);
    });
  });

  group('watchEpubBookKeys projects only the key column', () {
    test('no full-row select behind the key stream', () {
      final String src = read(
          '../packages/fushi_core/lib/src/database/database_content_misc.part.dart');
      final int start = src.indexOf('Stream<List<String>> watchEpubBookKeys()');
      expect(start, greaterThan(0));
      final String body = src.substring(start, src.indexOf(';', start));
      expect(body.contains('selectOnly(epubBooks)'), isTrue,
          reason: '流在每次写入时重跑，全列 select 会把整库大列读一遍只为取 key');
      expect(body.contains('select(epubBooks).map'), isFalse);
    });
  });

  group('shelf load has no per-book query', () {
    test('reader positions are read once for the whole shelf', () {
      final String src = read('lib/src/media/sources/reader_fushi_source.dart');
      expect(src.contains('findAllByBookUid()'), isTrue);
      final int start = src.indexOf('Future<MediaItem> _bookToMediaItem(');
      expect(start, greaterThan(0));
      final String body = src.substring(start, src.indexOf('\n  }\n', start));
      expect(body.contains('findByBookUid('), isFalse,
          reason: '_bookToMediaItem 不得再按本查位置（N+1）');
    });

    test('audiobook health is resolved in one prefix query', () {
      final String src =
          read('lib/src/pages/implementations/reader_fushi_history_page.dart');
      final int start = src.indexOf('_loadAllAudiobookInfo()');
      expect(start, greaterThan(0));
      final String body = src.substring(start, src.indexOf('\n  }\n', start));
      expect(body.contains('resolveAllHealth('), isTrue);
      expect(body.contains('resolveHealth(entry'), isFalse,
          reason: '每本一条 getPref 是 N+1');
    });

    test('local source listing does not stat every file', () {
      final String src =
          read('lib/src/media/source_library/source_file_system.dart');
      final int start = src.indexOf('class LocalSourceFileSystem');
      final int end = src.indexOf('listSiblingNames', start);
      final String body = src.substring(start, end);
      expect(body.contains('.length()'), isFalse,
          reason: 'sizeBytes 无消费方；递归枚举时每文件一次 length() 是纯浪费');
    });
  });
}
