// BUG-4955：Android 发布包的 Dart 调试信息必须留下来。
//
// 反馈 ICF67eBY57 里十几次 ANR 的 main 线程栈全是 `base.apk (offset …) (???)` 的 libapp.so 裸 pc，
// 发布流程没留 AGP strip 前的 ELF，pc 对不上源码，根因无从定位。修法：每次 release 出包后把
// `build/app/intermediates/flutter/release/<abi>/app.so`（gen_snapshot 在 Android 上不 strip）
// 收进 artifact `android-dart-symbols-<序号>`，并核对 build-id 与 APK 一致。
//
// 本守卫钉三件事：
//   * release.yml 每条 `flutter build apk --release` 后都收符号（逐 ABI 出包在循环里逐次收）；
//   * 核对 / 上传步骤的条件、保留期、不挡发版；Android 出包不许改用 --split-debug-info
//     （会把 app 内 Dart 栈变成 DWARF，诊断归因退化）；
//   * 脚本依赖的 Flutter SDK 契约：Android 上 gen_snapshot 不 strip、中间产物目录是
//     `intermediates/flutter/<variant>/<abi>/app.so`——升级 Flutter 改了这两条就红。
import 'dart:io';

import 'package:test/test.dart';

/// 从测试宿主可执行文件往上找 Flutter SDK 根（含 `packages/flutter_tools` 的目录）。
Directory? _findFlutterRoot() {
  final String? env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory('$env/packages/flutter_tools').existsSync()) {
    return Directory(env);
  }
  Directory dir = File(Platform.resolvedExecutable).parent;
  while (true) {
    if (Directory('${dir.path}/packages/flutter_tools').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

void main() {
  final String release = File(
    '../.github/workflows/release.yml',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String script = File(
    'tool/android_dart_symbols.sh',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  String step(String name) {
    final int at = release.indexOf('- name: $name\n');
    expect(at, isNonNegative, reason: '缺少步骤「$name」');
    final int next = release.indexOf('\n    - name: ', at + 1);
    return release.substring(at, next < 0 ? release.length : next);
  }

  int at(String name) => release.indexOf('- name: $name\n');

  group('BUG-4955 release.yml 收 Android Dart 符号', () {
    test('release 签名的 debug 通道包出包后收 arm64 符号', () {
      final String s = step('Build release-signed debug-channel APK');
      final int build = s.indexOf(
        'flutter --verbose build apk --release --target-platform android-arm64',
      );
      final int stash = s.indexOf(
        'bash tool/android_dart_symbols.sh stash android-arm64',
      );
      expect(build, isNonNegative);
      expect(stash, greaterThan(build), reason: '要在 flutter build 之后收');
    });

    test('逐 ABI 出包在循环里每次 build 之后收本次 platform 的符号', () {
      final String s = step('Build release APK (split per ABI)');
      final int loop = s.indexOf(
        'for platform in android-arm android-arm64 android-x64; do',
      );
      final int build = s.indexOf(
        'flutter --verbose build apk --split-per-abi --release --target-platform "\$platform"',
      );
      final int stash = s.indexOf(
        'bash tool/android_dart_symbols.sh stash "\$platform"',
      );
      final int done = s.indexOf('\n        done\n', loop);
      expect(loop, isNonNegative);
      expect(build, greaterThan(loop));
      // 换 target-platform 重编会清掉上一个 ABI 的中间产物：放到循环外只剩最后一个 ABI。
      expect(stash, greaterThan(build));
      expect(stash, lessThan(done), reason: 'stash 必须在 for 循环体内');
    });

    test('每条 release 出包命令都有对应 stash（新增出包命令别漏）', () {
      final RegExp releaseBuild = RegExp(
        r'flutter --verbose build apk[^\n]*--release',
      );
      final int builds = releaseBuild.allMatches(release).length;
      final int stashes = RegExp(
        r'bash tool/android_dart_symbols\.sh stash ',
      ).allMatches(release).length;
      expect(builds, 2);
      expect(stashes, builds);
    });

    test('Android 出包不用 --split-debug-info / --obfuscate', () {
      // --split-debug-info 连带 --dwarf-stack-traces：app 内 Dart 栈变 DWARF，
      // ui_activity_probe 的 who= / fcb= 归因与反馈里的符号化栈全部退化。
      for (final RegExpMatch m in RegExp(
        r'flutter --verbose build apk[^\n]*(\\\n[^\n]*)*',
      ).allMatches(release)) {
        final String cmd = m.group(0)!;
        expect(cmd, isNot(contains('--split-debug-info')), reason: cmd);
        expect(cmd, isNot(contains('--obfuscate')), reason: cmd);
      }
    });

    test('核对步骤：两种 release 出包都跑、在出包之后、不挡发版', () {
      final String s = step('Verify Android Dart symbols match APKs');
      expect(
        s,
        contains("steps.channel.outputs.build_debug_channel_apk == 'true'"),
      );
      expect(
        s,
        contains("steps.channel.outputs.build_split_release_apk == 'true'"),
      );
      expect(s, contains('continue-on-error: true'));
      expect(s, contains('working-directory: fushi'));
      expect(s, contains('bash tool/android_dart_symbols.sh verify'));
      expect(
        at('Verify Android Dart symbols match APKs'),
        greaterThan(at('Build release APK (split per ABI)')),
      );
    });

    test('上传步骤：按序号命名、正式 / 测试版 90 天、不进 Release 资产', () {
      final String s = step('Upload Android Dart symbols');
      expect(s, contains('actions/upload-artifact@'));
      expect(
        s,
        contains(
          r'name: android-dart-symbols-${{ steps.channel.outputs.release_sequence }}',
        ),
      );
      expect(s, contains('path: fushi/build/android-dart-symbols/'));
      expect(s, contains('continue-on-error: true'));
      expect(
        s,
        contains(
          // 只有 debug 通道短留；手动发 GitHub Release（channel=github-release）是正式版
          // 一等路径，不能落进 14 天。
          "retention-days: \${{ steps.channel.outputs.channel == 'debug' && 14 || 90 }}",
        ),
      );
      expect(
        s,
        contains("steps.channel.outputs.build_debug_channel_apk == 'true'"),
      );
      expect(
        s,
        contains("steps.channel.outputs.build_split_release_apk == 'true'"),
      );
      expect(
        at('Upload Android Dart symbols'),
        greaterThan(at('Verify Android Dart symbols match APKs')),
      );
      expect(
        RegExp(r'FILES="[^"]*android-dart-symbols').hasMatch(release),
        isFalse,
        reason: '符号是诊断件，不进 Release 资产',
      );
    });
  });

  group('BUG-4955 脚本', () {
    test('ABI 映射与 FlutterPluginConstants.PLATFORM_ARCH_MAP 一致', () {
      expect(script, contains('android-arm) echo armeabi-v7a ;;'));
      expect(script, contains('android-arm64) echo arm64-v8a ;;'));
      expect(script, contains('android-x64) echo x86_64 ;;'));
    });

    test('收的是未 strip 的中间产物，verify 核 build-id 与 .symtab / .debug_line', () {
      expect(
        script,
        contains('INTERMEDIATE_DIR=build/app/intermediates/flutter/release'),
      );
      expect(script, contains(r'src="$INTERMEDIATE_DIR/$abi/app.so"'));
      expect(script, contains('OUT_DIR=build/android-dart-symbols'));
      expect(script, contains(r"grep -E '^lib/[^/]+/libapp\.so$'"));
      expect(script, contains(r'[ "$want" != "$got" ]'));
      expect(script, contains('for section in .symtab .debug_line; do'));
      expect(script, contains('set -euo pipefail'));
    });
  });

  group('BUG-4955 Flutter SDK 契约', () {
    final Directory? root = _findFlutterRoot();

    test('能找到 Flutter SDK', () {
      expect(root, isNotNull, reason: Platform.resolvedExecutable);
    });

    test('Android 上 gen_snapshot 不 strip（交给 AGP），中间产物才带调试信息', () {
      if (root == null) return;
      final String build = File(
        '${root.path}/packages/flutter_tools/lib/src/base/build.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int android = build.indexOf(
        '} else if (targetingAndroidPlatform) {',
      );
      expect(android, isNonNegative);
      final int end = build.indexOf('} else {', android);
      final String branch = build.substring(android, end);
      expect(branch, contains('stripAfterBuild = false;'));
      expect(branch, isNot(contains("'--strip'")));
    });

    test('Flutter gradle 插件的中间产物目录是 intermediates/flutter/<variant>/', () {
      if (root == null) return;
      final String plugin = File(
        '${root.path}/packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt',
      ).readAsStringSync();
      expect(
        plugin,
        contains(
          r'"${FlutterPluginConstants.INTERMEDIATES_DIR}/flutter/${variant.name}/"',
        ),
      );
      final String helper = File(
        '${root.path}/packages/flutter_tools/gradle/src/main/kotlin/tasks/FlutterTaskHelper.kt',
      ).readAsStringSync();
      expect(helper, contains(r'${File.separator}app.so'));
    });
  });
}
