import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

void main() {
  test('home tab count constant is four', () {
    expect(kHomeTabCount, 4);
  });

  test('settings tab index constant is three', () {
    expect(kHomeSettingsTabIndex, 3);
  });
}
