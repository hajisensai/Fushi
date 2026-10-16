import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3427 守卫：iOS Runner 必须链伞形 Rust 静态库 `native/fushi_ios_umbrella`
/// （互联 P2P 的 `fp2p_*` + SRS 排程内核的 `ffsrs_*` 合一），CI 出包后必须两组符号都核对。
///
/// 洞的形状：SRS 内核上线时 iOS 侧只做到「伞形库编得过」，Runner 仍只接 fushi_p2p
/// 单独那份。iOS 上 Dart 用 `DynamicLibrary.process()` 找 `ffsrs_*`，找不到就静默判
/// 「内核不可用」——包照常构建、CI 全绿、TestFlight 照发，用户打开复习页才看到
/// 「本机的排程内核不可用」。所以这里钉三处接线，任何一处被改回 p2p 单库都红：
///
/// - `Flutter/{Debug,Release}.xcconfig` include 伞形库生成的 xcconfig，不再 include
///   fushi_p2p 单独那份（两份单独 .a 同时 `-force_load` 会撞重复的 Rust std 符号）；
/// - Runner 的 `OTHER_LDFLAGS` 用 `$(FUSHI_IOS_NATIVE_LDFLAGS)`；
/// - 两条出 iOS 包的 workflow 在 Runner 上同时跑 fushi_p2p 与 fushi_fsrs 的 verify_abi.sh。
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
  });

  test('出 iOS 包的 workflow 编伞形库，并在 Runner 上核对 ffsrs_* 符号', () {
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
      // 同参数的 ffsrs_* 核对；参数是 fushi_p2p 自己 prebuilt 产物的那几条不算。
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
      }
    }
  });
}
