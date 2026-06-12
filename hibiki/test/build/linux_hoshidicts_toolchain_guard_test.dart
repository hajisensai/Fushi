import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readWorkflow() {
    final File file = File('../.github/workflows/build-multiplatform.yml');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('Linux CI pins a C++23 std::expected-capable hoshidicts toolchain', () {
    final String workflow = readWorkflow();
    final int linuxJobStart = workflow.indexOf('  linux:');
    final int macosJobStart = workflow.indexOf('  macos:');

    expect(linuxJobStart, isNonNegative);
    expect(macosJobStart, greaterThan(linuxJobStart));

    final String linuxJob = workflow.substring(linuxJobStart, macosJobStart);

    expect(linuxJob, contains('gcc-14 g++-14 libstdc++-14-dev'));
    expect(linuxJob, contains('CC: gcc-14'));
    expect(linuxJob, contains('CXX: g++-14'));
    expect(linuxJob, contains('Verify Linux C++23 compiler'));
    expect(linuxJob, contains('#include <expected>'));
    expect(linuxJob, contains('__cpp_lib_expected'));
    expect(linuxJob, contains(r'"$CXX" -std=c++23'));
    expect(
      linuxJob.indexOf('Verify Linux C++23 compiler'),
      lessThan(linuxJob.indexOf('Build Linux (debug)')),
      reason: 'fail fast before Flutter configures CMake with the toolchain.',
    );
  });
}
