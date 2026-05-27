import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';

void main() {
  test('tag picker page library compiles', () {
    expect(const TagPickerPage(bookId: 1), isA<TagPickerPage>());
  });
}
