import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/media/sources/reader_ttu_source.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';

void main() {
  group('buildCollectionReaderMediaItem', () {
    test('preserves the shelf media identifier when the shelf item exists', () {
      final MediaItem shelfItem = MediaItem(
        mediaIdentifier: 'http://localhost:52059/b.html?id=42&?title=Shelf',
        title: 'Shelf',
        mediaTypeIdentifier: ReaderTtuSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: ReaderTtuSource.instance.uniqueKey,
        position: 12,
        duration: 100,
        canDelete: false,
        canEdit: true,
      );

      final MediaItem opened = buildCollectionReaderMediaItem(
        ttuId: 42,
        port: 52059,
        title: 'Favorite',
        original: shelfItem,
      );

      expect(opened.mediaIdentifier, shelfItem.mediaIdentifier);
      expect(opened.uniqueKey, shelfItem.uniqueKey);
      expect(opened.title, 'Favorite');
    });
  });
}
