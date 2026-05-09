import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';

void main() {
  group('buildCollectionReaderMediaItem', () {
    test('generates hoshi URL matching bookshelf format', () {
      final MediaItem opened = buildCollectionReaderMediaItem(
        ttuId: 42,
        title: 'MyBook',
      );

      expect(
        opened.mediaIdentifier,
        'hoshi://book/42',
      );
      expect(opened.title, 'MyBook');
      expect(
        opened.mediaSourceIdentifier,
        ReaderHoshiSource.instance.uniqueKey,
      );
    });
  });
}
