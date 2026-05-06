import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';

void main() {
  group('buildCollectionReaderMediaItem', () {
    test('generates URL matching bookshelf format', () {
      final MediaItem opened = buildCollectionReaderMediaItem(
        ttuId: 42,
        port: 52059,
        title: 'MyBook',
      );

      expect(
        opened.mediaIdentifier,
        'http://localhost:52059/b.html?id=42&?title=MyBook',
      );
      expect(opened.title, 'MyBook');
      expect(
        opened.mediaSourceIdentifier,
        ReaderTtuSource.instance.uniqueKey,
      );
    });
  });
}
