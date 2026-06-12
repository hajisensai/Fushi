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
    expect(linuxJob, contains('Flutter Linux CMake toolchain shim'));
    expect(linuxJob, contains(r'exec gcc-14 "$@"'));
    expect(linuxJob, contains(r'exec g++-14 "$@"'));
    expect(
      linuxJob,
      contains(r'PATH="$RUNNER_TEMP/hibiki-linux-toolchain:$PATH"'),
    );
    expect(linuxJob, contains('flutter build linux --debug --config-only'));
    expect(linuxJob, contains('CMAKE_CXX_COMPILER:FILEPATH='));
    expect(linuxJob, contains('CMakeCXXCompiler.cmake'));
    expect(linuxJob, contains(r'set(CMAKE_CXX_COMPILER_ID "GNU")'));
    expect(linuxJob,
        contains(r'"$RUNNER_TEMP/hibiki-linux-toolchain/clang++" -std=c++23'));
    expect(linuxJob, isNot(contains('CMAKE_CXX_COMPILER_ID:INTERNAL=GNU')));
    expect(
      linuxJob.indexOf('Verify Linux C++23 compiler'),
      lessThan(linuxJob.indexOf('Build Linux (debug)')),
      reason: 'fail fast before Flutter configures CMake with the toolchain.',
    );
    expect(
      linuxJob.indexOf('Flutter Linux CMake toolchain shim'),
      lessThan(linuxJob.indexOf('Build Linux (debug)')),
      reason:
          'Flutter hardcodes CC=clang/CXX=clang++; shim must exist before build.',
    );
  });
}
