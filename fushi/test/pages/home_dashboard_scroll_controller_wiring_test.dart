import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home dashboard owns, wires and disposes its wheel controller', () {
    final String source = File(
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ).readAsStringSync();

    expect(source, contains('DesktopWheelScrollController()'));
    expect(source, contains('controller: _dashboardScrollController'));
    expect(source, contains('_dashboardScrollController.dispose();'));
  });
}
