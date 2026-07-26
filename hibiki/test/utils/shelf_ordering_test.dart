import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// shelf_ordering 纯函数守卫（widget-free）。
/// UI v2 Phase E：旧 groupAndSortShelfEntries 已删（分组唯一真相源 =
/// collection_grouping.groupByCollections，另有专测），本文件只余选择键解码守卫。
void main() {
  group('shelfSelectionToEntry', () {
    test('books surface: srt_ 前缀 → (srt, uid)', () {
      final ShelfEntryRef? ref =
          shelfSelectionToEntry('srt_abc-123', ShelfSelectionSurface.books);
      expect(ref, isNotNull);
      expect(ref!.mediaType, MediaKind.srt);
      expect(ref.entryKey, 'abc-123');
    });

    test('books surface: hoshi://book/<bookKey> → (epub, bookKey)', () {
      final ShelfEntryRef? ref = shelfSelectionToEntry(
          'hoshi://book/mybook_key', ShelfSelectionSurface.books);
      expect(ref, isNotNull);
      expect(ref!.mediaType, MediaKind.epub);
      expect(ref.entryKey, 'mybook_key');
    });

    test(
        'books surface: %-escaped bookKey 保留字面 %XX（BUG-658 / TODO-1344，'
        '不 percent-decode 才与存库主键一致）', () {
      // sanitizeTtuFilename encodes forbidden chars, so a real key can contain
      // literal `%3F`/`%3C`/`%2F`. The old Uri-based parse decoded these,
      // producing an entryKey that no longer matched epub_books.bookKey (shelf
      // ordering / 组合成系列 for these books would silently target the wrong
      // key). The raw slice must keep them verbatim.
      const String key = '業物語 %3C物語%3E (講談社ＢＯＸ)';
      final ShelfEntryRef? ref = shelfSelectionToEntry(
          'hoshi://book/$key', ShelfSelectionSurface.books);
      expect(ref, isNotNull);
      expect(ref!.mediaType, MediaKind.epub);
      expect(ref.entryKey, key,
          reason: '%3C/%3E must NOT be decoded back to </>');

      final ShelfEntryRef? ref2 = shelfSelectionToEntry(
          'hoshi://book/Do Androids Dream of Electric Sheep%3F',
          ShelfSelectionSurface.books);
      expect(ref2!.entryKey, 'Do Androids Dream of Electric Sheep%3F');
    });

    test('books surface: 无法识别的键 → null', () {
      expect(shelfSelectionToEntry('garbage', ShelfSelectionSurface.books),
          isNull);
      expect(shelfSelectionToEntry('srt_', ShelfSelectionSurface.books), isNull,
          reason: '空 uid 视为无效');
    });

    test('video surface: 裸 bookUid → (video, bookUid)', () {
      final ShelfEntryRef? ref =
          shelfSelectionToEntry('video-uid-9', ShelfSelectionSurface.video);
      expect(ref, isNotNull);
      expect(ref!.mediaType, MediaKind.video);
      expect(ref.entryKey, 'video-uid-9');
    });

    test('video surface: 即便键看着像 srt_ 也按裸 uid（不串到 books 解析）', () {
      final ShelfEntryRef? ref =
          shelfSelectionToEntry('srt_looking', ShelfSelectionSurface.video);
      expect(ref, isNotNull);
      expect(ref!.mediaType, MediaKind.video);
      expect(ref.entryKey, 'srt_looking');
    });

    test('空键 → null（两表面）', () {
      expect(shelfSelectionToEntry('', ShelfSelectionSurface.books), isNull);
      expect(shelfSelectionToEntry('', ShelfSelectionSurface.video), isNull);
    });

    test('ShelfEntryRef 值相等性', () {
      expect(
        const ShelfEntryRef(mediaType: MediaKind.epub, entryKey: 'k'),
        const ShelfEntryRef(mediaType: MediaKind.epub, entryKey: 'k'),
      );
    });
  });
}
