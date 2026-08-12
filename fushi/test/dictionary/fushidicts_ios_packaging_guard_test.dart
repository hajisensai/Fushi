import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToHibiki) {
    final File file = File(relativeToHibiki);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('iOS Runner delegates FushiDicts build to a cache-safe script', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final String script = read('ios/build_fushidicts_ffi.sh');

    expect(project, contains('Build FushiDicts FFI'));
    expect(project, contains('build_fushidicts_ffi.sh'));

    expect(script, contains(r'case ";$cmake_archs;"'),
        reason: 'Xcode can feed duplicate ARCHS values; CMake 4.x then keeps '
            'two internal sysroots for one de-duplicated architecture.');
    expect(script, contains(r'cmake_sysroot="${SDKROOT:-}"'));
    expect(script, contains(r'xcrun --sdk "${PLATFORM_NAME:-iphoneos}"'));
    expect(script, contains('cached_archs'));
    expect(script, contains('cached_sysroot'));
    expect(script, contains(r'rm -rf "$FUSHIDICTS_BUILD_DIR"'));
    expect(script, contains(r'-DCMAKE_OSX_ARCHITECTURES="$cmake_archs"'));
    expect(script, contains(r'-DCMAKE_OSX_SYSROOT="$cmake_sysroot"'));
  });

  test('iOS deployment targets stay within Xcode 27 supported floor', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final String podfile = read('ios/Podfile');
    final String script = read('ios/build_fushidicts_ffi.sh');

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

  test('iOS Runner exports force-loaded FushiDicts symbols for dlsym', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');
    final List<String> fushidictsLinkerBlocks = RegExp(
      r'OTHER_LDFLAGS = \(([\s\S]*?)\n\s*\);',
    )
        .allMatches(project)
        .map((RegExpMatch match) => match.group(1)!)
        .where((String block) => block.contains('FUSHIDICTS_MERGED_ARCHIVE'))
        .toList();

    expect(fushidictsLinkerBlocks, hasLength(3),
        reason: 'Debug/Profile/Release must export the force-loaded static '
            'FushiDicts FFI symbols. iOS release stripping otherwise leaves '
            'DynamicLibrary.process().lookup("fushidicts_import") unable to '
            'resolve the symbol at startup.');
    for (final String block in fushidictsLinkerBlocks) {
      expect(block, contains('"-Wl,-export_dynamic"'));
      expect(block, contains('"-force_load"'));
      expect(block, contains(r'"$(FUSHIDICTS_MERGED_ARCHIVE)"'));
      expect(block.indexOf('"-Wl,-export_dynamic"'),
          lessThan(block.indexOf('"-force_load"')));
    }
  });

  test('iOS Runner keeps global symbols through the archive strip pass', () {
    final String project = read('ios/Runner.xcodeproj/project.pbxproj');

    // Runner 目标的三套配置 = 唯一 force_load FushiDicts 归档的 buildSettings 块。
    final List<String> runnerSettingsBlocks = RegExp(
      r'buildSettings = \{([\s\S]*?)\n\t\t\t\};',
    )
        .allMatches(project)
        .map((RegExpMatch match) => match.group(1)!)
        .where((String block) => block.contains('FUSHIDICTS_MERGED_ARCHIVE'))
        .toList();

    expect(runnerSettingsBlocks, hasLength(3));
    for (final String block in runnerSettingsBlocks) {
      expect(block, contains('STRIP_STYLE = "non-global";'),
          reason: 'BUG-1584：`flutter build ios --release` 用 ACTION=build，'
              'DEPLOYMENT_POSTPROCESSING=NO，不跑 Strip 阶段，所以符号还在；但'
              '`xcodebuild archive`（Xcode 的 Product > Archive，也就是 '
              'TestFlight / App Store 包的真实产出路径）会置 '
              'DEPLOYMENT_POSTPROCESSING=YES + STRIP_INSTALLED_PRODUCT=YES，'
              '默认 STRIP_STYLE=all 跑 `strip -D` 把主可执行的全局符号连同导出 '
              'trie 一起抹掉。-Wl,-export_dynamic 只管链接期，拦不住链接后的 '
              'strip。于是上架包一启动就 dlsym(RTLD_DEFAULT, "fushidicts_import") '
              '失败 → Initialisation failed。non-global 只剥局部/调试符号，保留 '
              '全局导出（实测代价 +30KB）。');
    }
  });
}
