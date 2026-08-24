import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/update_handoff.dart';

/// BUG-1836 根因修复：「这次更新到底装上了没有」的三源证据表。
///
/// 现场（2026-08-24）：用户照 BUG-1786 / BUG-1831 的指引**手动双击**装完
/// `fushi-2.2.1-debug.12215-windows-setup.exe`，磁盘证据显示整包换新成功，重启后
/// app 仍弹「更新失败」。原因是判据只认 Inno 日志，而手动装包时 Inno 一个字都不写。
///
/// 新证据源 [kFushiBuildVersionDefine] 编译在 `app.so` 里，与被替换的产物同体：
/// `app.so` 没被换掉它就报旧值。有它就不需要日志背书。
void main() {
  const String target = '2.2.1-debug.12215';
  const String oldCode = '2.2.1-debug.12067';
  // 版本资源里只剩基版本的那种包。**不是**因为 Windows VERSIONINFO 丢后缀
  // （字符串字段保留完整 build-name，package_info 读的正是它）——而是版本名本身
  // 就没带后缀：修复前的 beta 包（`--build-name` 只给 debug tag 派生）、以及
  // Apple 包（`CFBundleShortVersionString` 只收至多三段数字）都是这个形状。
  const String exeVersion = '2.2.1';

  group('三源证据判定表', () {
    test('无日志 + 代码版本已是目标 ⇒ 成功（手动装包救援，BUG-1836）', () {
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.unknown,
          targetVersion: target,
          executableVersion: exeVersion,
          runningCodeVersion: target,
        ),
        isTrue,
      );
    });

    test('无日志 + 代码版本仍是旧的 ⇒ 失败（安装器根本没跑起来）', () {
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.unknown,
          targetVersion: target,
          executableVersion: exeVersion,
          runningCodeVersion: oldCode,
        ),
        isFalse,
      );
    });

    test('回滚 + 代码版本已是目标 ⇒ 仍判失败（整包半更新态）', () {
      // Inno 的回滚**保留**被覆盖的文件、只删本次新建的文件，所以回滚之后
      // `app.so` 完全可能已经是新版，而别的文件还是旧的。此时代码版本达标也不能
      // 判成功——这正是 BUG-1786 现场「新 exe + 旧插件 dll」的形状。
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.aborted,
          targetVersion: target,
          executableVersion: exeVersion,
          runningCodeVersion: target,
        ),
        isFalse,
      );
    });

    test('日志说成功 + 代码版本仍是旧的 ⇒ 判失败（日志不能给旧代码背书）', () {
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.succeeded,
          targetVersion: target,
          executableVersion: exeVersion,
          runningCodeVersion: oldCode,
        ),
        isFalse,
      );
    });

    test('代码版本比目标还新 ⇒ 成功（用户手动装了更新的包）', () {
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.unknown,
          targetVersion: target,
          executableVersion: exeVersion,
          runningCodeVersion: '2.2.1-debug.12216',
        ),
        isTrue,
      );
    });

    group('拿不到代码版本时逐行退化成 BUG-1786 的旧判据', () {
      test('日志成功 + exe 版本达标 ⇒ 成功', () {
        expect(
          isWindowsUpdateInstalled(
            verdict: WindowsInnoInstallVerdict.succeeded,
            targetVersion: target,
            executableVersion: exeVersion,
            runningCodeVersion: null,
          ),
          isTrue,
        );
      });

      test('无日志 ⇒ 失败（旧行为，不因新判据放宽）', () {
        expect(
          isWindowsUpdateInstalled(
            verdict: WindowsInnoInstallVerdict.unknown,
            targetVersion: target,
            executableVersion: exeVersion,
            runningCodeVersion: null,
          ),
          isFalse,
        );
      });

      test('日志回滚 ⇒ 失败（旧行为）', () {
        expect(
          isWindowsUpdateInstalled(
            verdict: WindowsInnoInstallVerdict.aborted,
            targetVersion: target,
            executableVersion: exeVersion,
            runningCodeVersion: null,
          ),
          isFalse,
        );
      });
    });
  });

  group('代码版本并不总是可比', () {
    test('跨通道不可比 ⇒ 退回日志判据，不能硬判成功', () {
      // 用户从 debug 通道切到 beta，target 是 `2.2.1-beta.30`，安装失败且没留日志，
      // 跑的仍是 `2.2.1-debug.12215`。SemVer 会把 `debug` 排在 `beta` 之后，于是
      // 「代码版本 >= 目标」为真——纯属字符串巧合。硬信它就是把失败报成成功。
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-debug.12215',
          targetVersion: '2.2.1-beta.30',
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.unknown,
          targetVersion: '2.2.1-beta.30',
          executableVersion: exeVersion,
          runningCodeVersion: '2.2.1-debug.12215',
        ),
        isFalse,
      );
    });

    test('beta → 正式版：不可比，失败的安装不得被判成成功', () {
      // beta 包升同 base 的正式版（`2.2.1-beta.30` → `2.2.1`），安装彻底失败且没
      // 留日志。若把 beta 的代码版本误当成裸 `2.2.1`（修复前 workflow 就是这么注入
      // 的），两边都成了「无预发布段且相等」⇒ 判成功，实际还跑着 beta 的代码。
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-beta.30',
          targetVersion: '2.2.1',
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
      expect(
        isWindowsUpdateInstalled(
          verdict: WindowsInnoInstallVerdict.unknown,
          targetVersion: '2.2.1',
          executableVersion: '2.2.1-beta.30',
          runningCodeVersion: '2.2.1-beta.30',
        ),
        isFalse,
      );
    });

    test('beta → 更新的 beta：同通道，按序号比得出来', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-beta.31',
          targetVersion: '2.2.1-beta.31',
        ),
        RunningCodeVersionEvidence.atLeastTarget,
      );
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-beta.30',
          targetVersion: '2.2.1-beta.31',
        ),
        RunningCodeVersionEvidence.belowTarget,
      );
    });

    test('正式版 vs 同号预发布版不可比（BUG-1786 抱怨的「恒为真」）', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1',
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
    });

    test('基版本不同一律可比，与通道无关', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.3.0',
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.atLeastTarget,
      );
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.1.9-beta.4',
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.belowTarget,
      );
    });

    test('同通道按序号比，前导 v 与 +metadata 不影响', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: 'v$target+abc1234',
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.atLeastTarget,
      );
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: oldCode,
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.belowTarget,
      );
    });

    test('两边都是正式版且同号 ⇒ 达标', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1',
          targetVersion: '2.2.1',
        ),
        RunningCodeVersionEvidence.atLeastTarget,
      );
    });

    test('畸形版本串不得抛异常（marker 是磁盘 JSON，可能被手改或损坏）', () {
      // `2.2.1-.1` 的预发布段首个 token 为空：光比「通道标签」会把它和「无预发布
      // 段」判成同通道，随后拿 null 去比较就抛 TypeError。reconcile 跑在启动路径
      // 上，这里抛异常等于开机崩。
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1',
          targetVersion: '2.2.1-.1',
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-.1',
          targetVersion: '2.2.1',
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: '2.2.1-',
          targetVersion: '2.2.1-debug.1',
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
    });

    test('未注入 ⇒ 不可比（不是「未达标」）', () {
      expect(
        classifyRunningCodeVersion(
          runningCodeVersion: null,
          targetVersion: target,
        ),
        RunningCodeVersionEvidence.inconclusive,
      );
    });
  });

  /// BUG-1836：半更新态下 exe 版本资源与 `buildNumber` **都**报新值，只看它们的话
  /// 客户端会认为自己已是最新 ⇒ 不再提示更新 ⇒ 用户被困在旧代码里且没有出路。
  group('更新检查的「本机当前版本」', () {
    test('有代码版本就用它，哪怕 exe 报的是更新的版本', () {
      expect(
        resolveCurrentAppVersion(
          '2.2.1-debug.12216',
          runningCodeVersionDefine: '2.2.1-debug.12215',
        ),
        '2.2.1-debug.12215',
      );
    });

    test('未注入时退回 exe 版本资源', () {
      expect(
        resolveCurrentAppVersion(
          '2.2.1-debug.12216',
          runningCodeVersionDefine: '',
        ),
        '2.2.1-debug.12216',
      );
    });

    test('两个更新检查入口都必须走这里（源码守卫）', () {
      // 绕过任一入口，那条路径就在半更新态下永判「已是最新」。
      const List<String> sources = <String>[
        'lib/src/pages/implementations/home_page.dart',
        'lib/src/settings/settings_schema_system.dart',
      ];
      for (final String path in sources) {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: path);
        // 先剔掉注释再断言。`settings_schema_system.dart` 是几千行的大文件，光是
        // 解释这条规矩的注释里就出现了 `resolveCurrentAppVersion`；裸 `contains`
        // 会被散文喂饱，把「删掉真实调用、只留注释」的改动放行。
        final String code = stripDartLineComments(file.readAsStringSync());
        // 断言布尔而不是把整份源码丢给 `contains` matcher：这两个文件都是几千行，
        // 失败时 matcher 会把全文当 `Actual` 打出来，真正的失败原因被埋掉。
        expect(
          code.contains('resolveCurrentAppVersion('),
          isTrue,
          reason: '$path 的更新检查绕开了「本机当前版本」的真值入口',
        );

        // 负向断言：喂给 `scheduleCheck` 的**位置参数**里不得出现裸的
        // `packageInfo.version`（那是 exe 版本资源，半更新态下它谎报新版本）。
        // 正向断言只证明文件里还有这个函数名，证明不了它的结果真流进了更新检查。
        const String callToken = 'UpdateChecker.scheduleCheck(';
        int at = code.indexOf(callToken);
        expect(at, isNot(-1), reason: '$path 里扫不到 $callToken，守卫扫空了（调用被改名/删除？）');
        while (at >= 0) {
          final int argsStart = at + callToken.length;
          // 位置参数止于第一个命名参数。`currentBuildNumber:` 两个调用点都传，
          // 它要是没了，下面的 isNot(-1) 会把守卫变红而不是悄悄放行。
          final int argsEnd = code.indexOf('currentBuildNumber:', argsStart);
          expect(
            argsEnd,
            isNot(-1),
            reason:
                '$path 的 scheduleCheck 不再传 currentBuildNumber，'
                '位置参数边界没法定位了',
          );
          final String positionalArgs = code.substring(argsStart, argsEnd);
          if (positionalArgs.contains('packageInfo.version')) {
            expect(
              positionalArgs.contains('resolveCurrentAppVersion('),
              isTrue,
              reason:
                  '$path 把 exe 版本资源直接喂给了更新检查（位置参数 '
                  '`${positionalArgs.trim()}`）；半更新态下 exe 版本资源谎报新版本，'
                  '客户端会据它永判「已是最新」',
            );
          }
          at = code.indexOf(callToken, argsStart);
        }
      }
    });
  });

  group('normalizeFushiBuildVersion', () {
    test('未注入（空串 / 空白）折叠成 null，绝不当版本号参与比较', () {
      expect(normalizeFushiBuildVersion(''), isNull);
      expect(normalizeFushiBuildVersion('   '), isNull);
    });

    test('注入值去空白后原样保留', () {
      expect(normalizeFushiBuildVersion('  $target\n'), target);
    });
  });

  group('reconcile 端到端', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fushi-install-evidence');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    File markerWithoutInnoLog() {
      final File marker = WindowsUpdateHandoff.markerFile(tempDir);
      marker.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'targetVersion': target,
          'installerPath': '${tempDir.path}${Platform.pathSeparator}setup.exe',
          // 手动双击安装包时 Inno 不写日志：这个路径**故意**指向不存在的文件。
          'innoLogPath':
              '${tempDir.path}${Platform.pathSeparator}never-written.log',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'installerLaunchSucceeded': false,
          'launchError': 'UpdateInstallerException: update launcher not found',
        }),
      );
      return marker;
    }

    test('手动装包救援成功后判 installed，而不是再报一次失败', () async {
      final File marker = markerWithoutInnoLog();

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
            markerFile: marker,
            currentVersion: exeVersion,
            runningCodeVersionDefine: target,
          );

      expect(result, isNotNull);
      expect(
        result!.status,
        WindowsUpdateHandoffStatus.installed,
        reason: '现场：磁盘上整包已换新，判据却因为拿不到 Inno 日志报了失败',
      );
      expect(
        result.record.lastPromptedAppVersion,
        target,
        reason:
            '幂等键要用带 -debug.N 的代码版本，exe 版本资源的 `2.2.1` '
            '在同 base 的两个构建之间无法区分',
      );
    });

    test('同样没有日志、但跑的还是旧代码 ⇒ 仍报失败', () async {
      final File marker = markerWithoutInnoLog();

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
            markerFile: marker,
            currentVersion: exeVersion,
            runningCodeVersionDefine: oldCode,
          );

      expect(result, isNotNull);
      expect(result!.status, WindowsUpdateHandoffStatus.launchFailed);
    });

    test('未注入代码版本时，无日志仍报失败（历史版本行为不变）', () async {
      final File marker = markerWithoutInnoLog();

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
            markerFile: marker,
            currentVersion: exeVersion,
            runningCodeVersionDefine: '',
          );

      expect(result, isNotNull);
      expect(result!.status, WindowsUpdateHandoffStatus.launchFailed);
    });
  });
}

/// 剔除 Dart 行注释（`//` 与 `///`），只留代码。
///
/// 只处理行注释：本守卫的目标文件里没有 `/* */` 块注释，多一层状态机只是多一个
/// 出错面。也不识别字符串字面量——会被误剔的只有字面量里的 `//`（如 URL），而本
/// 守卫断言的 token 都不会出现在 URL 里。
String stripDartLineComments(String source) {
  final StringBuffer out = StringBuffer();
  for (final String line in const LineSplitter().convert(source)) {
    final int idx = line.indexOf('//');
    out.writeln(idx < 0 ? line : line.substring(0, idx));
  }
  return out.toString();
}
