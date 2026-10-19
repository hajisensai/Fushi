import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3427 守卫：iOS Runner 必须链伞形 Rust 静态库 `native/fushi_ios_umbrella`
/// （互联 P2P 的 `fp2p_*` + SRS 排程内核的 `ffsrs_*` + 计算内核的 `ffc_*` 合一），CI 出包后
/// 必须三组符号都核对。
///
/// 洞的形状：SRS 内核上线时 iOS 侧只做到「伞形库编得过」，Runner 仍只接 fushi_p2p
/// 单独那份。iOS 上 Dart 用 `DynamicLibrary.process()` 找 `ffsrs_*`，找不到就静默判
/// 「内核不可用」——包照常构建、CI 全绿、TestFlight 照发，用户打开复习页才看到
/// 「本机的排程内核不可用」。所以这里钉三处接线，任何一处被改回 p2p 单库都红：
///
/// - `Flutter/{Debug,Release}.xcconfig` include 伞形库生成的 xcconfig，不再 include
///   fushi_p2p 单独那份（两份单独 .a 同时 `-force_load` 会撞重复的 Rust std 符号）；
/// - Runner 的 `OTHER_LDFLAGS` 用 `$(FUSHI_IOS_NATIVE_LDFLAGS)`；
/// - 两条出 iOS 包的 workflow 在 Runner 上同时跑 fushi_p2p / fushi_fsrs / fushi_compute 的
///   verify_abi.sh；
/// - fushi_compute 是硬依赖：Runner 有一个在编译前跑 `check_fushi_compute.sh` 的构建阶段，
///   伞形库缺失（`#include?` 静默缺席）或是不含 `ffc_*` 的旧件时让构建失败。
void main() {
  // 测试 cwd 是 `fushi/`。
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  /// 去掉整行注释（xcconfig 的 `//`、YAML 的 `#`）：注释里本就会提到这些名字，
  /// 拿散文当接线会让守卫在没接线时照样绿。
  String stripComments(String text, String marker) => text
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith(marker))
      .join('\n');

  for (final String config in <String>['Debug', 'Release']) {
    test('ios/Flutter/$config.xcconfig 接伞形库、不接 p2p 单库', () {
      final String xc = stripComments(
        read('ios/Flutter/$config.xcconfig'),
        '//',
      );
      expect(
        xc,
        contains(
          '#include? "../../../native/fushi_ios_umbrella/prebuilt/ios/'
          'fushi_ios_umbrella.xcconfig"',
        ),
      );
      expect(xc, isNot(contains('native/fushi_p2p/prebuilt/ios')));
      expect(xc, isNot(contains('native/fushi_fsrs/prebuilt/ios')));
      expect(xc, isNot(contains('native/fushi_web_core/prebuilt/ios')));
    });
  }

  test('Runner 三个配置的 OTHER_LDFLAGS 都用 FUSHI_IOS_NATIVE_LDFLAGS', () {
    final String pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      RegExp(r'"\$\(FUSHI_IOS_NATIVE_LDFLAGS\)"').allMatches(pbx).length,
      3,
    );
    expect(pbx, isNot(contains('FUSHI_P2P_LDFLAGS')));
    expect(pbx, isNot(contains('FUSHI_FSRS_LDFLAGS')));
    expect(pbx, isNot(contains('FUSHI_WEB_CORE_LDFLAGS')));
  });

  test('出 iOS 包的 workflow 编伞形库，并在 Runner 上核对 ffsrs_* / fwc_* 符号', () {
    for (final String path in <String>[
      '../.github/workflows/build-multiplatform.yml',
      '../.github/workflows/release-desktop.yml',
    ]) {
      final String workflow = stripComments(read(path), '#');
      expect(
        workflow,
        contains(
          'bash native/fushi_ios_umbrella/build_ios_staticlib.sh device',
        ),
        reason: path,
      );
      expect(
        workflow,
        isNot(contains('native/fushi_p2p/build_ios_staticlib.sh')),
        reason: '$path：iOS 不能再链 fushi_p2p 单库',
      );
      // 凡是核对「app 产物」（iOS Runner、macOS bundle 里的 dylib）的 fp2p_* 步骤，都必须有
      // 同参数的 ffsrs_* 与 ffc_* 核对；参数是 fushi_p2p 自己 prebuilt 产物的那几条不算。
      final List<String> p2pChecks = <String>[
        for (final String line in workflow.split('\n'))
          if (line.contains('native/fushi_p2p/verify_abi.sh') &&
              !line.contains('fushi_p2p.') &&
              !line.contains('libfushi_p2p'))
            line.trim(),
      ];
      expect(p2pChecks, isNotEmpty, reason: '$path：没找到 Runner 符号核对');
      for (final String check in p2pChecks) {
        expect(
          workflow,
          contains(check.replaceFirst('fushi_p2p/', 'fushi_fsrs/')),
          reason: '$path：「$check」只核对了 fp2p_*，缺 ffsrs_*',
        );
        expect(
          workflow,
          contains(check.replaceFirst('fushi_p2p/', 'fushi_compute/')),
          reason: '$path：「$check」只核对了 fp2p_*，缺 ffc_*',
        );
      }
      // 网页广告拦截内核（fwc_*）同样静态链进 iOS Runner：只核对「iOS 产物」那几条
      // （Runner 主二进制 / xcarchive 里的 Runner），macOS dylib 的核对不在此列。
      final List<String> iosRunnerChecks = <String>[
        for (final String line in workflow.split('\n'))
          if (line.contains('native/fushi_fsrs/verify_abi.sh') &&
              (line.contains('Runner.app/Runner') ||
                  line.contains('"\$runner"') ||
                  line.contains('"\$bin"')))
            line.trim(),
      ];
      expect(iosRunnerChecks, isNotEmpty, reason: '$path：没找到 iOS Runner 符号核对');
      for (final String check in iosRunnerChecks) {
        expect(
          workflow,
          contains(check.replaceFirst('fushi_fsrs/', 'fushi_web_core/')),
          reason: '$path：「$check」只核对了 ffsrs_*，缺 fwc_*',
        );
      }
    }
  });

  test('Runner 在编译前硬检查伞形库里有 fushi_compute（ffc_*）', () {
    final String pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      pbx,
      contains(r'shellScript = "/bin/bash \"$PROJECT_DIR/check_fushi_compute.sh\"\n";'),
    );
    // 必须挂在 Runner 的 buildPhases 里、且排在 Sources 之前（编译 / 链接之前就失败）。
    final int target = pbx.indexOf('/* Runner */ = {\n\t\t\tisa = PBXNativeTarget;');
    expect(target, greaterThanOrEqualTo(0), reason: '找不到 Runner 的 PBXNativeTarget');
    final int phases = pbx.indexOf('buildPhases = (', target);
    final int check = pbx.indexOf(
      '/* Check fushi_compute (iOS umbrella) */,',
      phases,
    );
    final int sources = pbx.indexOf('/* Sources */,', phases);
    expect(phases, greaterThanOrEqualTo(0));
    expect(check, greaterThan(phases), reason: '构建阶段没挂进 Runner');
    expect(check, lessThan(sources), reason: '检查阶段必须在 Sources 之前');

    final String script = read('ios/check_fushi_compute.sh');
    expect(script, contains(r'prebuilt/ios/${sdk}/libfushi_ios_umbrella.a'));
    expect(script, contains('FUSHI_IOS_NATIVE_LDFLAGS'));
    expect(script, contains('_ffc_abi_version'));
    expect(script, contains('exit 1'));
  });
}
