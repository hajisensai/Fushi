import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';

void main() {
  test('illustrations viewer page library compiles', () {
    expect(
      const IllustrationsViewerPage(bookTitle: 'Book', bookId: 1),
      isA<IllustrationsViewerPage>(),
    );
  });
}
