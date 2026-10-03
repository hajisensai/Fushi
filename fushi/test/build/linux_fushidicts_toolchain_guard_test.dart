import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-09-30：Linux app 不再在 CI 构建，fushidicts 的 gcc-14 ctest 从
  // build-multiplatform.yml 的 linux job 搬到 native-fushidicts-gate.yml 的 ctest-gcc。
  String readWorkflow() {
    final File file = File('../.github/workflows/native-fushidicts-gate.yml');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readFushidictsCmake() {
    final File file = File('../native/fushidicts/CMakeLists.txt');
    expect(file.existsSync(), isTrue,
        reason: 'expected fushidicts CMake at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readLinuxCmake() {
    final File file = File('linux/CMakeLists.txt');
    expect(file.existsSync(), isTrue,
        reason: 'expected Linux CMake at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readLinuxRunnerCmake() {
    final File file = File('linux/runner/CMakeLists.txt');
    expect(file.existsSync(), isTrue,
        reason: 'expected Linux runner CMake at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('Linux CI pins a C++23 std::expected-capable fushidicts toolchain', () {
    final String workflow = readWorkflow();
    const String header = '\n  ctest-gcc:\n';
    final int linuxJobStart = workflow.indexOf(header);

    expect(linuxJobStart, isNonNegative,
        reason: 'native-fushidicts-gate.yml must keep the gcc-14 ctest job');

    // 窗口截到下一个 job 头（没有就到文件尾）。
    final Iterable<RegExpMatch> laterJobs =
        RegExp(r'^  [A-Za-z0-9_-]+:\s*$', multiLine: true)
            .allMatches(workflow, linuxJobStart + header.length);
    final String linuxJob = workflow.substring(linuxJobStart,
        laterJobs.isEmpty ? workflow.length : laterJobs.first.start);

    expect(linuxJob, contains('gcc-14 g++-14 libstdc++-14-dev'));
    expect(linuxJob, contains('CC: gcc-14'));
    expect(linuxJob, contains('CXX: g++-14'));
    expect(linuxJob, contains('Verify Linux C++23 compiler'));
    expect(linuxJob, contains('#include <expected>'));
    expect(linuxJob, contains('__cpp_lib_expected'));
    expect(linuxJob, contains(r'"$CXX" -std=c++23'));
    expect(
      linuxJob.indexOf('Verify Linux C++23 compiler'),
      lessThan(linuxJob.indexOf('Run fushidicts native tests (ctest)')),
      reason: 'fail fast on the toolchain before building the native suite.',
    );
  });

  test('Linux fushidicts static archives are PIC before shared FFI link', () {
    final String cmake = readFushidictsCmake();
    final int linuxGuardStart =
        cmake.indexOf('if(CMAKE_SYSTEM_NAME STREQUAL "Linux")');
    final int picSetting =
        cmake.indexOf('set(CMAKE_POSITION_INDEPENDENT_CODE ON)');
    final int bundledDepsStart =
        cmake.indexOf('add_subdirectory(fushidicts_external/glaze');
    final int staticTargetStart =
        cmake.indexOf('add_library(fushidicts STATIC');
    final int sharedTargetStart =
        cmake.indexOf('add_library(fushidicts_ffi SHARED');

    expect(linuxGuardStart, isNonNegative);
    expect(picSetting, greaterThan(linuxGuardStart));
    expect(bundledDepsStart, greaterThan(picSetting));
    expect(staticTargetStart, isNonNegative);
    expect(picSetting, lessThan(staticTargetStart));
    expect(sharedTargetStart, greaterThan(staticTargetStart));

    expect(
      picSetting,
      lessThan(bundledDepsStart),
      reason: 'Linux links fushidicts.a plus bundled static dependencies into '
          'libfushidicts_ffi.so; PIC must be enabled before those static '
          'targets are created or ld fails during the Flutter Linux link step.',
    );
  });

  test('Linux warnings-as-errors stay on the app runner target only', () {
    final String linuxCmake = readLinuxCmake();
    final String runnerCmake = readLinuxRunnerCmake();

    final int standardSettingsStart =
        linuxCmake.indexOf('function(APPLY_STANDARD_SETTINGS TARGET)');
    final int standardSettingsEnd = linuxCmake.indexOf(
      'endfunction()',
      standardSettingsStart,
    );
    final int runnerSubdirectory =
        linuxCmake.indexOf('add_subdirectory("runner")');
    final int generatedPlugins =
        linuxCmake.indexOf('include(flutter/generated_plugins.cmake)');

    expect(standardSettingsStart, isNonNegative);
    expect(standardSettingsEnd, greaterThan(standardSettingsStart));
    expect(runnerSubdirectory, greaterThan(standardSettingsEnd));
    expect(generatedPlugins, greaterThan(runnerSubdirectory));

    final String standardSettings = linuxCmake.substring(
      standardSettingsStart,
      standardSettingsEnd,
    );

    expect(standardSettings, contains('-Wall'));
    expect(
      standardSettings,
      isNot(contains('-Werror')),
      reason: 'Flutter Linux pub-cache plugins call APPLY_STANDARD_SETTINGS; '
          'their warnings must not be promoted to CI build failures.',
    );
    expect(
      runnerCmake,
      contains(r'target_compile_options(${BINARY_NAME} PRIVATE -Werror)'),
      reason: 'The app runner still owns warnings-as-errors for project code.',
    );
  });
}
