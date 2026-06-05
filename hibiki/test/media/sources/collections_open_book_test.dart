import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';

void main() {
  group('buildCollectionReaderMediaItem', () {
    test('generates hoshi URL matching bookshelf format', () {
      final MediaItem opened = buildCollectionReaderMediaItem(
        bookKey: 'MyBook',
        title: 'MyBook',
      );

      expect(
        opened.mediaIdentifier,
        'hoshi://book/MyBook',
      );
      expect(opened.title, 'MyBook');
      expect(
        opened.mediaSourceIdentifier,
        ReaderHibikiSource.instance.uniqueKey,
      );
    });
  });
}
