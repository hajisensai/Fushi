import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-578 fast (source-scan) gate of the native fushidicts test layer.
///
/// The deep gate is the native ctest suite itself (only runnable where a C++23
/// toolchain is present). This Dart test runs in `flutter test` everywhere and
/// guards that the harness + CI wiring stay in place so the deep gate can never
/// silently fall out of CI:
///   * tests/CMakeLists.txt aggregates every native test into ctest;
///   * each P0/P1/P2 e2e source file exists;
///   * the Linux CI job actually builds + runs the suite via ctest;
///   * the existing macOS ctypes create/destroy dylib smoke is NOT touched
///     (so the deep-gate addition is not mistaken for a regression of it).
void main() {
  String read(String relativeToHibiki) {
    final File file = File(relativeToHibiki);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('tests/CMakeLists.txt aggregates the native suite into ctest', () {
    final String cmake = read('../native/fushidicts/tests/CMakeLists.txt');

    // Reuses the real engine static lib (production link path).
    expect(
        cmake, contains('add_subdirectory(\${FUSHI_ROOT} fushidicts_build)'));
    expect(cmake, contains('enable_testing()'));
    expect(cmake, contains('add_test(NAME \${name} COMMAND \${name})'));
    // Every test we expect ctest to drive must be registered.
    for (final String testName in <String>[
      'word_scan_test',
      'text_processor_test',
      'zip64_central_dir_test',
      'kanji_import_query_test',
      'dict_name_uaf_e2e_test',
      'media_import_query_test',
      'freq_pitch_import_query_test',
      // FFI 边界闸门的覆盖守卫。它守的是「异常逃出 extern "C" → 进程静默消失」
      // 这条唯一无日志、无错误屏的死法，掉出 ctest 等于这层防护没有了。
      'ffi_guard_coverage_test',
    ]) {
      expect(cmake, contains('add_fushi_test($testName'),
          reason: '$testName must be registered as a ctest case');
    }
    // MSVC needs /utf-8 so UTF-8 fixture bytes survive code page 936 on Windows.
    expect(cmake, contains('/utf-8'));
  });

  test('the P0/P1/P2 native e2e sources exist', () {
    for (final String src in <String>[
      'zip_fixture.hpp',
      'dict_name_uaf_e2e_test.cpp',
      'media_import_query_test.cpp',
      'freq_pitch_import_query_test.cpp',
      'kanji_import_query_test.cpp',
      'ffi_guard_coverage_test.cpp',
    ]) {
      final File file = File('../native/fushidicts/tests/$src');
      expect(file.existsSync(), isTrue,
          reason: 'expected native test source at ${file.absolute.path}');
    }
  });

  test('CI builds + runs the native ctest suite on Linux', () {
    // 2026-09-30：Linux app 不再在 CI 构建；gcc-14 ctest 从 build-multiplatform.yml
    // 的 linux job 搬到 native-fushidicts-gate.yml 的 ctest-gcc job。
    final String workflow =
        read('../.github/workflows/native-fushidicts-gate.yml');

    expect(workflow, contains('Run fushidicts native tests (ctest)'));
    expect(workflow, contains('cmake -S native/fushidicts/tests'));
    expect(workflow, contains(r'ctest --test-dir "$RUNNER_TEMP/fushi-tests"'));
    expect(workflow, contains('--no-tests=error'));

    // The native ctest step must live inside the gcc-14 job (which installs
    // g++-14 + cmake + ninja), after the C++23 toolchain check.
    final int jobIdx = workflow.indexOf('\n  ctest-gcc:\n');
    final int verifyIdx = workflow.indexOf('Verify Linux C++23 compiler');
    final int ctestIdx =
        workflow.indexOf('Run fushidicts native tests (ctest)');
    expect(jobIdx, greaterThan(0), reason: 'ctest-gcc job missing');
    expect(verifyIdx, greaterThan(jobIdx));
    expect(ctestIdx, greaterThan(verifyIdx),
        reason: 'native ctest belongs in ctest-gcc after the C++23 check.');

    // 触发面必须覆盖 ctest 真正读到的输入：fushidicts 源码 + 它当 fixture 读的
    // fushi/assets/transforms/（tests/CMakeLists.txt）。
    expect(workflow, contains("- 'native/fushidicts/**'"));
    expect(workflow, contains("- 'fushi/assets/transforms/**'"));

    // 不许有人以为 Linux app 构建还在跑这套 ctest。
    expect(read('../.github/workflows/build-multiplatform.yml'),
        isNot(contains('Run fushidicts native tests (ctest)')));
  });

  test('the existing macOS ctypes dylib smoke stays intact (not regressed)',
      () {
    // The deep native gate is additive: it must NOT remove or replace the
    // pre-existing macOS create/destroy ctypes smoke in the macos job.
    final String workflow =
        read('../.github/workflows/build-multiplatform.yml');

    expect(workflow, contains('Verify macOS fushidicts dylib bundle'));
    expect(workflow, contains('ctypes.CDLL'));
    expect(workflow, contains('fushidicts_create'));
    expect(workflow, contains('fushidicts_destroy'));
  });
}
