import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/pages/implementations/tag_picker_page.dart';

void main() {
  test('tag picker page library compiles', () {
    expect(
      const TagPickerPage(
        media: MediaRef(kind: MediaKind.epub, entryKey: 'book-1'),
      ),
      isA<TagPickerPage>(),
    );
  });

  test('accepts video media ref variant (shared tag pool)', () {
    expect(
      const TagPickerPage(
        media: MediaRef(kind: MediaKind.video, entryKey: 'video/1'),
      ),
      isA<TagPickerPage>(),
    );
  });

  test('accepts srt media ref variant (entryKey = SrtBooks.uid)', () {
    expect(
      const TagPickerPage(
        media: MediaRef(kind: MediaKind.srt, entryKey: 'srt-uid-7'),
      ),
      isA<TagPickerPage>(),
    );
  });

  test('accepts collection variant', () {
    expect(const TagPickerPage(collectionId: 3), isA<TagPickerPage>());
  });
}
