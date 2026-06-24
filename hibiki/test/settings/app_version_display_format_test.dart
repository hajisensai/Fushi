import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_schema_system.dart';
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
        packageName: 'app.hibiki.reader',
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
        packageName: 'app.hibiki.reader',
        version: '0.11.1',
        buildNumber: '187',
      );

      expect(formatAppVersionDisplay(info), '0.11.1 (187)');
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
