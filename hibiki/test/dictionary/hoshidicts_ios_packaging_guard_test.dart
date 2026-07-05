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

  test('iOS deployment targets stay within Xcode 27 supported floor', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final String podfile = read('ios/Podfile');
    final String script = read('ios/build_hoshidicts_ffi.sh');

    const double xcode27MinimumDeploymentTarget = 15.0;
    final List<double> runnerTargets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
    )
        .allMatches(project)
        .map((RegExpMatch match) => double.parse(match.group(1)!))
        .toList();

    expect(runnerTargets, isNotEmpty);
    for (final double target in runnerTargets) {
      expect(target, greaterThanOrEqualTo(xcode27MinimumDeploymentTarget));
    }

    expect(podfile, contains("platform :ios, '15.0'"));
    expect(
      podfile,
      contains("config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'"),
    );
    expect(script, contains(r'${IPHONEOS_DEPLOYMENT_TARGET:-15.0}'));
  });

  test('iOS Runner exports force-loaded HoshiDicts symbols for dlsym', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final List<String> hoshidictsLinkerBlocks = RegExp(
      r'OTHER_LDFLAGS = \(([\s\S]*?)\n\s*\);',
    )
        .allMatches(project)
        .map((RegExpMatch match) => match.group(1)!)
        .where((String block) => block.contains('HOSHIDICTS_MERGED_ARCHIVE'))
        .toList();

    expect(hoshidictsLinkerBlocks, hasLength(3),
        reason: 'Debug/Profile/Release must export the force-loaded static '
            'HoshiDicts FFI symbols. iOS release stripping otherwise leaves '
            'DynamicLibrary.process().lookup("hoshidicts_import") unable to '
            'resolve the symbol at startup.');
    for (final String block in hoshidictsLinkerBlocks) {
      expect(block, contains('"-Wl,-export_dynamic"'));
      expect(block, contains('"-force_load"'));
      expect(block, contains(r'"$(HOSHIDICTS_MERGED_ARCHIVE)"'));
      expect(block.indexOf('"-Wl,-export_dynamic"'),
          lessThan(block.indexOf('"-force_load"')));
    }
  });
}
