import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// TODO-772: 设置页「应用版本」行曾把 versionName 与 Android versionCode 用
/// semver 的 `+` build-metadata 硬拼，渲染出畸形的
/// `0.11.1-debug.5613+1000561300`（`1000561300` 是 versionCode，不是乱码）。
/// 修复后改成括号并列展示，且展示层不得再出现 `version+buildNumber` 形态。
void main() {
  group('formatAppVersionDisplay (display layer)', () {
    test('debug build: versionCode shown in parens, not semver-plus', () {
      final PackageInfo info = PackageInfo(
        appName: 'Hibiki',
        packageName: 'app.fushi.reader',
        version: '0.11.1-debug.5613',
        buildNumber: '1000561300',
      );

      final String subtitle = formatAppVersionDisplay(info);

      expect(
        subtitle,
        isNot('0.11.1-debug.5613+1000561300'),
        reason: '不得再用 semver 的 + 把 versionCode 拼进 versionName',
      );
      expect(subtitle, '0.11.1-debug.5613 (1000561300)');
    });

    test('stable build: same parenthesized shape', () {
      final PackageInfo info = PackageInfo(
        appName: 'Hibiki',
        packageName: 'app.fushi.reader',
        version: '0.11.1',
        buildNumber: '187',
      );

      expect(formatAppVersionDisplay(info), '0.11.1 (187)');
    });
  });

  /// BUG-1836 / BUG-1786：Windows 的 exe 版本资源丢 `-debug.N`，关于页只显示
  /// `2.2.1`，用户看不出自己跑在哪个构建上；「新 exe + 旧 app.so」的半更新态更是
  /// 完全不可见。有了编译进 `app.so` 的构建版本，这两件事都能在关于页直接看出来。
  group('运行中代码版本优先展示', () {
    PackageInfo windowsInfo() => PackageInfo(
          appName: 'Fushi',
          packageName: 'app.hibiki.reader',
          // Windows 上 package_info 读 exe VERSIONINFO，必然只有基版本。
          version: '2.2.1',
          buildNumber: '12215',
        );

    test('注入了代码版本就显示带后缀的真值', () {
      expect(
        formatAppVersionDisplay(
          windowsInfo(),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        '2.2.1-debug.12215 (12215)',
      );
    });

    test('没注入时退回 exe 版本资源，形状不变', () {
      expect(formatAppVersionDisplay(windowsInfo()), '2.2.1 (12215)');
    });

    test('基版本不一致时并排显示 exe 版本（半更新态的可见症状）', () {
      final PackageInfo info = PackageInfo(
        appName: 'Fushi',
        packageName: 'app.hibiki.reader',
        version: '2.3.0',
        buildNumber: '12300',
      );

      expect(
        formatAppVersionDisplay(
          info,
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        '2.2.1-debug.12215 (12300) ≠ exe 2.3.0',
      );
    });

    test('只有后缀不同不算不一致（否则每个 debug 构建都会报警）', () {
      expect(
        formatAppVersionDisplay(
          windowsInfo(),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        isNot(contains('≠')),
      );
    });
  });

  group('source guard', () {
    test(
        'settings_schema_system.dart no longer concatenates version+buildNumber',
        () {
      final File source = File('lib/src/settings/settings_schema_system.dart');
      expect(source.existsSync(), isTrue,
          reason: 'source path resolved relative to package root');
      final String contents = source.readAsStringSync();

      // 守住根因：禁止 `${packageInfo.version}+${packageInfo.buildNumber}`
      // 这种把 versionCode 拼进 semver `+` build-metadata 的展示形态。
      expect(
        contents
            .contains(r"'${packageInfo.version}+${packageInfo.buildNumber}'"),
        isFalse,
        reason: '不得把 versionCode 拼进 semver 的 + build-metadata 段',
      );
      // 任意把这两个字段直接 `+` 串接的写法都拦下（防止变量改名后绕过）。
      expect(
        RegExp(r'\.version[^\n]*\}\+\$\{[^\n]*\.buildNumber')
            .hasMatch(contents),
        isFalse,
        reason: 'version 与 buildNumber 不得用 + 直接串接',
      );
    });
  });
}
