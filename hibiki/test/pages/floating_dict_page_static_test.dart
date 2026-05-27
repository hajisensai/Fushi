import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/floating_dict_page.dart';

void main() {
  test('floating dictionary page compiles with shared popup chrome', () {
    expect(
      const FloatingDictPage(channel: MethodChannel('hibiki.test/floating')),
      isA<FloatingDictPage>(),
    );
  });
}
