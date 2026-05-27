import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/debug_log_page.dart';
import 'package:hibiki/src/pages/implementations/error_log_page.dart';

void main() {
  test('log pages compile with the shared MD3 log panel', () {
    expect(const DebugLogPage(), isA<DebugLogPage>());
    expect(const ErrorLogPage(), isA<ErrorLogPage>());
  });
}
