import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToHibiki) {
    final File file = File(relativeToHibiki);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('iOS Runner delegates HoshiDicts build to a cache-safe script', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final String script = read('ios/build_hoshidicts_ffi.sh');

    expect(project, contains('Build HoshiDicts FFI'));
    expect(project, contains('build_hoshidicts_ffi.sh'));

    expect(script, contains(r'case ";$cmake_archs;"'),
        reason: 'Xcode can feed duplicate ARCHS values; CMake 4.x then keeps '
            'two internal sysroots for one de-duplicated architecture.');
    expect(script, contains(r'cmake_sysroot="${SDKROOT:-}"'));
    expect(script, contains(r'xcrun --sdk "${PLATFORM_NAME:-iphoneos}"'));
    expect(script, contains('cached_archs'));
    expect(script, contains('cached_sysroot'));
    expect(script, contains(r'rm -rf "$HOSHIDICTS_BUILD_DIR"'));
    expect(script, contains(r'-DCMAKE_OSX_ARCHITECTURES="$cmake_archs"'));
    expect(script, contains(r'-DCMAKE_OSX_SYSROOT="$cmake_sysroot"'));
  });
}
