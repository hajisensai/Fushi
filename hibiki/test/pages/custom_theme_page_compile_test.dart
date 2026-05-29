import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/custom_theme_page.dart';

void main() {
  test('custom theme page compiles after dialog refactor', () {
    expect(const CustomThemePage(), isA<CustomThemePage>());
  });
}
