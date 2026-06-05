import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';

void main() {
  test('tag picker page library compiles', () {
    expect(const TagPickerPage(bookKey: 'book-1'), isA<TagPickerPage>());
  });

  test('accepts video book uid variant (shared tag pool)', () {
    expect(const TagPickerPage(videoBookUid: 'video/1'), isA<TagPickerPage>());
  });

  test('accepts srt book variant', () {
    expect(
      const TagPickerPage(srtBookId: 7, isSrtBook: true),
      isA<TagPickerPage>(),
    );
  });
}
