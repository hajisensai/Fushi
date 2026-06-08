import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CI full Flutter tests use the failure-only wrapper', () {
    final String mainWorkflow =
        File('../.github/workflows/main.yml').readAsStringSync();
    final String releaseWorkflow =
        File('../.github/workflows/release.yml').readAsStringSync();

    expect(
      mainWorkflow,
      contains('dart run tool/flutter_test_failures.dart '
          '--coverage --exclude-tags golden'),
    );
    expect(
      releaseWorkflow,
      contains('dart run tool/flutter_test_failures.dart'),
    );
    expect(
      mainWorkflow,
      isNot(contains('run: flutter test --coverage --exclude-tags golden')),
    );
    expect(releaseWorkflow, isNot(contains('run: flutter test')));
    expect(
      mainWorkflow,
      contains('dart ../../hibiki/tool/flutter_test_failures.dart'),
    );
    expect(
      releaseWorkflow,
      contains('dart ../../hibiki/tool/flutter_test_failures.dart'),
    );
  });
}
