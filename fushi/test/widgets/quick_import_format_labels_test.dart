import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/import_carrier.dart'
    show kMangaCarrierFileExtensions;
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;

void main() {
  test('importFormatLabels strips dots, uppercases and dedupes in order', () {
    expect(
      importFormatLabels(<Iterable<String>>[
        <String>['.mp4', 'mkv'],
        <String>['MP4', '.m4a', ''],
      ]),
      <String>['MP4', 'MKV', 'M4A'],
    );
  });

  test(
    'manga chips cover every carrier and page image the importer accepts',
    () {
      final List<String> labels = importFormatLabels(<Iterable<String>>[
        kMangaCarrierFileExtensions,
        kMangaImageExtensions,
      ]);
      for (final String ext in <String>{
        ...kMangaCarrierFileExtensions,
        ...kMangaImageExtensions,
      }) {
        expect(labels, contains(ext.substring(1).toUpperCase()));
      }
      expect(labels, containsAll(<String>['CBR', 'CB7', 'EPUB', 'WEBP']));
    },
  );
}
