import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String readWorkflow() {
    final File file = File('../.github/workflows/build-multiplatform.yml');
    expect(file.existsSync(), isTrue,
        reason: 'expected workflow at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  String readHoshidictsCmake() {
    final File file = File('../native/hoshidicts/CMakeLists.txt');
    expect(file.existsSync(), isTrue,
        reason: 'expected hoshidicts CMake at ${file.absolute.path}');
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
    expect(linuxJob, contains('flutter build linux --debug --verbose'));
    expect(linuxJob, contains('::group::Linux CMake/Ninja diagnostics'));
    expect(linuxJob, contains('ninja -C build/linux/x64/debug -v install'));
    expect(linuxJob, contains('::endgroup::'));
    expect(linuxJob, contains('exit 1'));
  });

  test('Linux hoshidicts static archives are PIC before shared FFI link', () {
    final String cmake = readHoshidictsCmake();
    final int linuxGuardStart =
        cmake.indexOf('if(CMAKE_SYSTEM_NAME STREQUAL "Linux")');
    final int picSetting =
        cmake.indexOf('set(CMAKE_POSITION_INDEPENDENT_CODE ON)');
    final int bundledDepsStart =
        cmake.indexOf('add_subdirectory(hoshidicts_external/glaze');
    final int staticTargetStart =
        cmake.indexOf('add_library(hoshidicts STATIC');
    final int sharedTargetStart =
        cmake.indexOf('add_library(hoshidicts_ffi SHARED');

    expect(linuxGuardStart, isNonNegative);
    expect(picSetting, greaterThan(linuxGuardStart));
    expect(bundledDepsStart, greaterThan(picSetting));
    expect(staticTargetStart, isNonNegative);
    expect(picSetting, lessThan(staticTargetStart));
    expect(sharedTargetStart, greaterThan(staticTargetStart));

    expect(
      picSetting,
      lessThan(bundledDepsStart),
      reason: 'Linux links hoshidicts.a plus bundled static dependencies into '
          'libhoshidicts_ffi.so; PIC must be enabled before those static '
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
