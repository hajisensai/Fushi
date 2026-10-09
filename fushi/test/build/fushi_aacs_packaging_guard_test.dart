// Guards the Blu-ray libaacs ABI module wiring (native/fushi_aacs).
//
// libbluray inside the bundled libmpv opens "libaacs" by a fixed per-platform
// name; when the file is missing or misnamed nothing fails at build time and
// every AACS disc menu simply never opens (2026-10-09: "进入原盘菜单纯黑").
// Each link of name → build → bundle → Dart preload is pinned here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativeToFushi) {
  final File file = File(relativeToFushi);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'expected file at ${file.absolute.path}',
  );
  return file.readAsStringSync();
}

void main() {
  test('native CMake names the module the way libbluray opens it', () {
    final String cmake = _read('../native/fushi_aacs/CMakeLists.txt');
    // Windows: LoadLibraryExW("libaacs.dll", APPLICATION_DIR | SYSTEM32).
    expect(cmake, contains('PREFIX "" OUTPUT_NAME "libaacs"'));
    // Android: dlopen("libaacs.so.0") resolved by soname of the preloaded lib.
    expect(cmake, contains('OUTPUT_NAME "fushi_aacs" NO_SONAME ON'));
    expect(cmake, contains('-Wl,-soname,libaacs.so.0'));
    expect(cmake, contains('-Wl,-z,max-page-size=16384'));
    // macOS: dlopen("@rpath/libaacs.dylib").
    expect(cmake, contains('OUTPUT_NAME "aacs"'));
    expect(cmake, contains('INSTALL_NAME_DIR "@rpath"'));
  });

  test('the module exports the libaacs ABI libbluray resolves', () {
    final String source = _read('../native/fushi_aacs/src/fushi_aacs.c');
    for (final String symbol in <String>[
      'aacs_open2',
      'aacs_open',
      'aacs_close',
      'aacs_decrypt_unit',
      'aacs_decrypt_bus',
      'aacs_select_title',
      'aacs_get_mkb_version',
      'aacs_get_disc_id',
      'aacs_get_content_cert_id',
      'aacs_get_bdj_root_cert_hash',
      'aacs_get_bus_encryption',
      'fushi_aacs_set_disc_key',
      'fushi_aacs_abi_version',
    ]) {
      expect(
        RegExp('FUSHI_AACS_API [^;{]*\\b$symbol\\(').hasMatch(source),
        isTrue,
        reason: '$symbol must be exported',
      );
    }
    // With aacs_init + aacs_open_device libbluray would switch to its UDF
    // callback contract, which this module does not implement.
    expect(source, isNot(contains('FUSHI_AACS_API AACS *aacs_init(')));
    expect(source, isNot(contains(' aacs_open_device(')));
  });

  test('Dart preloads the same file names and ABI version', () {
    final String dart = _read('lib/src/media/video/bluray_aacs_module.dart');
    final String source = _read('../native/fushi_aacs/src/fushi_aacs.c');
    expect(dart, contains("if (Platform.isWindows) return 'libaacs.dll';"));
    expect(
      dart,
      contains("if (Platform.isAndroid) return 'libfushi_aacs.so';"),
    );
    expect(dart, contains("if (Platform.isMacOS) return 'libaacs.dylib';"));
    final RegExpMatch native = RegExp(
      r'#define FUSHI_AACS_ABI_VERSION (\d+)',
    ).firstMatch(source)!;
    expect(
      dart,
      contains('const int kFushiAacsAbiVersion = ${native.group(1)};'),
    );
  });

  test('Windows installs libaacs.dll next to fushi.exe', () {
    final String cmake = _read('windows/CMakeLists.txt');
    expect(cmake, contains('/../../native/fushi_aacs"'));
    expect(
      cmake,
      contains(
        'install(TARGETS fushi_aacs RUNTIME DESTINATION '
        '"\${INSTALL_BUNDLE_LIB_DIR}"',
      ),
    );
  });

  test('the bundle install prefix is settled before plugins configure', () {
    // media_kit_libs_windows_video installs bluray/bdj with the prefix it sees
    // at configure time; a later prefix left bluray/ out of shipped bundles.
    final String cmake = _read('windows/CMakeLists.txt');
    final int prefix = cmake.indexOf(
      'set(CMAKE_INSTALL_PREFIX "\${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)',
    );
    expect(prefix, greaterThanOrEqualTo(0));
    expect(prefix, lessThan(cmake.indexOf('add_subdirectory(\${FLUTTER_MANAGED_DIR})')));
    expect(prefix, lessThan(cmake.indexOf('include(flutter/generated_plugins.cmake)')));
  });

  test('Android builds the module in the app native build', () {
    final String gradle = _read('android/app/build.gradle');
    expect(
      gradle,
      contains('path "../../../native/fushidicts/CMakeLists.txt"'),
    );
    final String cmake = _read('../native/fushidicts/CMakeLists.txt');
    final int android = cmake.lastIndexOf('if(ANDROID)');
    expect(android, greaterThanOrEqualTo(0));
    expect(
      cmake.substring(android),
      contains('add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../fushi_aacs"'),
    );
  });

  test('macOS Runner bundles libaacs.dylib into Frameworks', () {
    final String project = _read('macos/Runner.xcodeproj/project.pbxproj');
    final int phases = project.indexOf(
      'B20100000000000000000003 /* Bundle '
      'fushi_torrent dylib */,',
    );
    expect(phases, greaterThanOrEqualTo(0));
    expect(
      project,
      contains('B20100000000000000000004 /* Bundle fushi_aacs dylib */,'),
    );
    expect(
      project,
      contains(
        r'shellScript = "/bin/bash \"$PROJECT_DIR/bundle_fushi_aacs.sh\"\n";',
      ),
    );
    final String script = _read('macos/bundle_fushi_aacs.sh');
    expect(script, contains('name="libaacs.dylib"'));
    expect(script, contains(r'install_name_tool -id "@rpath/${name}"'));
    expect(script, contains('--target fushi_aacs'));
  });

  test('the disc menu registers keys before libbluray opens the disc', () {
    final String part = _read('lib/src/media/video/video_disc_menu.part.dart');
    final int prepare = part.indexOf('await prepareBlurayMenuAacs(');
    final int device = part.indexOf("'bluray-device',");
    expect(prepare, greaterThanOrEqualTo(0));
    expect(prepare, lessThan(device));
    final String controller = _read(
      'lib/src/media/video/video_player_controller.dart',
    );
    expect(controller, contains('_onDiscNativeLog(player, log);'));
    final String page = _read(
      'lib/src/pages/implementations/video_fushi/disc_menu.part.dart',
    );
    expect(page, contains("error == 'navigation-open-failed'"));
    expect(page, contains('t.video_disc_menu_open_failed'));
  });
}
