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

  /// BUG-1786：exe 版本资源与 `app.so` 是**两个文件**，Inno 回滚保留被覆盖的文件、
  /// 只删本次新建的文件，所以「新 exe + 旧 app.so」的半更新态完全可能落地，而版本
  /// 资源照样报新版本。关于页是用户唯一能自查这件事的地方。
  group('运行中代码版本优先展示', () {
    PackageInfo windowsInfo(String version) => PackageInfo(
          appName: 'Fushi',
          packageName: 'app.hibiki.reader',
          // Windows 的 VERSIONINFO **字符串**字段保留完整 build-name（丢后缀的只是
          // FILEVERSION 那四段数字），package_info 读的正是字符串字段。实测本机
          // fushi.exe: ProductVersion = 2.2.1-debug.12215+12215。
          version: version,
          buildNumber: '12215',
        );

    test('同一次构建：显示代码版本，不加警告', () {
      expect(
        formatAppVersionDisplay(
          windowsInfo('2.2.1-debug.12215'),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        '2.2.1-debug.12215 (12215)',
      );
    });

    test('半更新态：exe 比 app.so 新一位序号，必须报出来', () {
      // BUG-1786 现场的真实形状。基版本相同、只差预发布序号一位——只比基版本
      // 的实现会对这个输入完全沉默。
      expect(
        formatAppVersionDisplay(
          windowsInfo('2.2.1-debug.12216'),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        '2.2.1-debug.12215 (12215) ≠ exe 2.2.1-debug.12216',
      );
    });

    test('前导 v 与 +metadata 不算不一致', () {
      expect(
        formatAppVersionDisplay(
          windowsInfo('2.2.1-debug.12215'),
          runningCodeVersion: 'v2.2.1-debug.12215+abc1234',
        ),
        isNot(contains('≠')),
      );
    });

    test('没注入时退回 exe 版本资源，形状不变', () {
      expect(
        formatAppVersionDisplay(windowsInfo('2.2.1-debug.12215')),
        '2.2.1-debug.12215 (12215)',
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
