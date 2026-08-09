import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToHibiki) {
    final File file = File(relativeToHibiki);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('native CMake gives the macOS dylib an @rpath install name', () {
    final String cmake = read('../native/fushidicts/CMakeLists.txt');

    expect(cmake, contains('add_library(fushidicts_ffi SHARED'));
    expect(cmake, contains('if(APPLE AND NOT FUSHIDICTS_IOS)'),
        reason: 'macOS (non-iOS) needs an @rpath dylib id for app-bundle '
            'loading; iOS switched to a force_loaded merged static archive.');
    expect(cmake, contains('INSTALL_NAME_DIR "@rpath"'));
    expect(cmake, contains('BUILD_WITH_INSTALL_NAME_DIR TRUE'));
  });

  test('native CMake requires C++23 std::expected for fushidicts targets', () {
    final String cmake = read('../native/fushidicts/CMakeLists.txt');

    expect(cmake, contains('include(CheckCXXSourceCompiles)'));
    expect(cmake, contains('__cpp_lib_expected'));
    expect(cmake, contains('std::expected<int, int>'));
    expect(cmake, contains('std::unexpected(1)'));
    expect(cmake, contains('target_compile_features(fushidicts PUBLIC'));
    expect(cmake, contains('cxx_std_23'));
    expect(cmake, contains('target_compile_features(fushidicts_ffi PRIVATE'));
    expect(cmake, contains('target_compile_features(fushidicts_jni PRIVATE'));
  });

  test('macOS Runner builds fushidicts and copies the dylib into Frameworks',
      () {
    final String project = read('macos/Runner.xcodeproj/project.pbxproj');
    final String config = read('macos/Runner/Configs/AppInfo.xcconfig');

    expect(config, contains('FUSHIDICTS_SOURCE_DIR'));
    expect(config, contains('../../native/fushidicts'));
    expect(config, contains('FUSHIDICTS_DYLIB_NAME = libfushidicts_ffi.dylib'));

    expect(project, contains('Build FushiDicts FFI'));
    expect(project, contains('cmake -S'));
    expect(project, contains('FUSHIDICTS_SOURCE_DIR'));
    expect(project, contains('--target fushidicts_ffi'));
    expect(project, contains(r'$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH'));
    expect(project, contains('libfushidicts_ffi.dylib'));
    expect(project, contains(r'@rpath/$FUSHIDICTS_DYLIB_NAME'));
    expect(project, contains('install_name_tool -id'));

    final RegExp runnerPhases = RegExp(
      r'33CC10EC2044A3C60003C045 /\* Runner \*/ = \{[\s\S]*?buildPhases = \(([\s\S]*?)\);',
    );
    final String phases = runnerPhases.firstMatch(project)!.group(1)!;
    expect(phases.indexOf('3399D490228B24CF009A79C7 /* ShellScript */'),
        lessThan(phases.indexOf('Build FushiDicts FFI')),
        reason: 'copy the dylib after Flutter embeds the macOS app bundle.');
  });

  test('Runner runpath can load dylibs from Contents/Frameworks', () {
    final String project = read('macos/Runner.xcodeproj/project.pbxproj');

    expect('@executable_path/../Frameworks'.allMatches(project).length,
        greaterThanOrEqualTo(3),
        reason:
            'Debug/Profile/Release must all keep the app Frameworks rpath.');
  });

  test('CI verifies the bundled macOS fushidicts dylib', () {
    final String workflow =
        read('../.github/workflows/build-multiplatform.yml');

    expect(workflow, contains('Verify macOS fushidicts dylib bundle'));
    expect(workflow, contains(r'find "$app_dir/Contents/Frameworks"'));
    expect(workflow, contains('libfushidicts_ffi.dylib'));
    expect(workflow, contains(r'otool -D "$dylib"'));
    expect(workflow, contains(r'otool -L "$dylib"'));
    expect(workflow, contains('@executable_path/../Frameworks'));
    expect(workflow, contains('ctypes.CDLL'));
    expect(workflow, contains('fushidicts_create'));

    expect(
      workflow.indexOf('Verify macOS fushidicts dylib bundle'),
      greaterThan(workflow.indexOf('Build macOS (debug)')),
      reason: 'the dylib check must inspect the app produced by flutter build.',
    );
    expect(
      workflow.indexOf('Verify macOS fushidicts dylib bundle'),
      lessThan(workflow.indexOf('Run macOS comprehensive automation contract')),
      reason: 'fail the packaging check before the broader smoke contract.',
    );
  });
}
