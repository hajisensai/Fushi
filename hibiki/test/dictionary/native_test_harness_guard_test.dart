import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-578 fast (source-scan) gate of the native hoshidicts test layer.
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
    final String cmake = read('../native/hoshidicts/tests/CMakeLists.txt');

    // Reuses the real engine static lib (production link path).
    expect(cmake, contains('add_subdirectory(\${HOSHI_ROOT} hoshidicts_build)'));
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
    ]) {
      expect(cmake, contains('add_hoshi_test($testName'),
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
    ]) {
      final File file = File('../native/hoshidicts/tests/$src');
      expect(file.existsSync(), isTrue,
          reason: 'expected native test source at ${file.absolute.path}');
    }
  });

  test('CI builds + runs the native ctest suite on Linux', () {
    final String workflow =
        read('../.github/workflows/build-multiplatform.yml');

    expect(workflow, contains('Run hoshidicts native tests (ctest)'));
    expect(workflow, contains('cmake -S native/hoshidicts/tests'));
    expect(workflow, contains(r'ctest --test-dir "$RUNNER_TEMP/hoshi-tests"'));

    // The native ctest step must live inside the Linux job (which installs
    // g++-14 + cmake + ninja) and run before the Flutter Linux build so a
    // native break fails fast.
    final int ctestIdx = workflow.indexOf('Run hoshidicts native tests (ctest)');
    final int verifyIdx = workflow.indexOf('Verify Linux C++23 compiler');
    final int flutterBuildIdx = workflow.indexOf('Build Linux (debug)');
    expect(verifyIdx, greaterThan(0));
    expect(ctestIdx, greaterThan(verifyIdx),
        reason: 'native ctest belongs in the Linux job after the C++23 check.');
    expect(ctestIdx, lessThan(flutterBuildIdx),
        reason: 'run native ctest before the Flutter Linux build (fail fast).');
  });

  test('the existing macOS ctypes dylib smoke stays intact (not regressed)', () {
    // The deep native gate is additive: it must NOT remove or replace the
    // pre-existing macOS create/destroy ctypes smoke in the macos job.
    final String workflow =
        read('../.github/workflows/build-multiplatform.yml');

    expect(workflow, contains('Verify macOS hoshidicts dylib bundle'));
    expect(workflow, contains('ctypes.CDLL'));
    expect(workflow, contains('hoshidicts_create'));
    expect(workflow, contains('hoshidicts_destroy'));
  });
}
