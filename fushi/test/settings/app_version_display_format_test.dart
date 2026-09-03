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

  /// 原生版本资源是代码版本的一种**有损渲染**：Apple 的
  /// `CFBundleShortVersionString` 只收「至多三段非负整数」，所以
  /// `release-desktop.yml` 给 iOS/IPA 的 `--build-name` 传的是剥掉预发布段的
  /// `apple_build_version_name`，而 `--dart-define=FUSHI_BUILD_VERSION` 仍是完整
  /// 版本名（`build_version_define_guard_test.dart` 把这两条一起钉死）。
  ///
  /// 逐字比较会因此在**每一个** iOS debug/beta 包的关于页上常驻一句
  /// `2.2.1-beta.30 (30) ≠ exe 2.2.1` —— 一个恒为真的「你的安装坏了」告警，正是
  /// BUG-1786 想避开的「警告退化成噪音」。判据必须吃下这层有损渲染。
  group('版本资源的有损渲染（Apple 只收数字段）', () {
    PackageInfo appleInfo(String version, String buildNumber) => PackageInfo(
          appName: 'Fushi',
          packageName: 'app.hibiki.reader',
          version: version,
          buildNumber: buildNumber,
        );

    test('iOS beta：Info.plist 剥了预发布段，不是半更新态 ⇒ 不告警', () {
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1', '30'),
          runningCodeVersion: '2.2.1-beta.30',
        ),
        '2.2.1-beta.30 (30)',
      );
    });

    test('iOS debug：同样静默', () {
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1', '12215'),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        isNot(contains('≠')),
      );
    });

    test('Windows 半更新态仍照常告警（剥段后 ≠ exe）', () {
      // 回归钉子：宽松化判据时最容易顺手把这条一起放过去。
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1-debug.12216', '12216'),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        contains('≠ exe 2.2.1-debug.12216'),
      );
    });

    test('Windows 正常包：两侧逐字相等 ⇒ 静默', () {
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1-debug.12215', '12215'),
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        isNot(contains('≠')),
      );
    });

    test('基版本不同 ⇒ 剥段也救不了，照常告警', () {
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.0', '29'),
          runningCodeVersion: '2.2.1-beta.30',
        ),
        contains('≠ exe 2.2.0'),
      );
    });

    test('反方向（exe 有预发布段、代码没有）不被剥段规则放过', () {
      // 剥段只允许发生在**代码版本**一侧（版本资源才是有损的那个）。
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1-beta.30', '30'),
          runningCodeVersion: '2.2.1',
        ),
        contains('≠ exe 2.2.1-beta.30'),
      );
    });

    test('已知边界：Windows 正式版 exe + 同 base 预发布 app.so 会被静默', () {
      // 这是**当前行为**，不是期望值：跨通道半更新态（正式版 exe `2.2.1` 配
      // `2.2.1-beta.31` 的 app.so）与 Apple 的正常态在字符串层面完全同形，分开
      // 只能靠平台特例分支。记录在案，别当成没有。
      //
      // 影响有界：更新检查侧走 `resolveCurrentAppVersion` 吃的是代码版本，这种
      // 机器仍会照常收到新版本提示，不会被困住。
      expect(
        formatAppVersionDisplay(
          appleInfo('2.2.1', '31'),
          runningCodeVersion: '2.2.1-beta.31',
        ),
        isNot(contains('≠')),
        reason: '已知残留假阴性——行为变了就该重新评估这条取舍，而不是默默改掉',
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
