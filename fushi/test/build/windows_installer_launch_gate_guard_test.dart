import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-4007 回归守卫：安装器替换安装目录期间，新启动的 fushi.exe 必须立即退出。
///
/// 现场（反馈 umcyzpaebn）：旧实例为更新退出后，安装器的清场（`InitializeSetup` 关实例、
/// `PrepareToInstall` 的 `KillProcessesUnderDir`）是**一次性快照**；之后一个由 explorer
/// 拉起的新 fushi.exe 把 `fbdaom.dll` 映射进来，复制阶段 `DeleteFile` code 5 →
/// `/SUPPRESSMSGBOXES` 默认 Abort → 整包回滚，留下「新 exe + 旧 app.so」半更新态。
///
/// 修复是一道两侧共享的命名互斥量门：安装器在清场**之前**建、全部文件落地
/// （ssPostInstall）时放；fushi.exe 启动第一步、以及等完退出中的旧实例之后各看一次，
/// 门在就立即退出。Inno 脚本与 C++ runner 都没有可跑的单测框架，沿用本目录的源码守卫。
void main() {
  late String iss;
  late String runner;

  setUpAll(() {
    final File issFile = File('windows/installer/fushi.iss');
    final File runnerFile = File('windows/runner/main.cpp');
    expect(issFile.existsSync(), isTrue, reason: '安装脚本路径变了要同步改守卫');
    expect(runnerFile.existsSync(), isTrue, reason: 'runner 路径变了要同步改守卫');
    iss = issFile.readAsStringSync();
    runner = runnerFile.readAsStringSync();
  });

  /// [source] 里从 [start] 起到 [end]（不含）的切片；锚不到就 fail。
  String slice(String source, String start, String end) {
    final int from = source.indexOf(start);
    expect(from, greaterThanOrEqualTo(0), reason: '锚不到 `$start`');
    final int to = source.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: '锚不到终点 `$end`');
    return source.substring(from, to);
  }

  test('安装器与 runner 用同一个门名', () {
    final RegExp issName = RegExp(r"FushiInstallGateMutexName = '([^']+)';");
    final RegExp runnerName = RegExp(
      r'kInstallInProgressMutex\[\] = L"([^"]+)";',
    );
    final String? fromIss = issName.firstMatch(iss)?.group(1);
    final String? fromRunner = runnerName.firstMatch(runner)?.group(1);
    expect(fromIss, isNotNull);
    expect(fromRunner, isNotNull);
    expect(fromRunner, fromIss, reason: '两侧名字不一致 = 门形同虚设');
  });

  test('PrepareToInstall 先建门、再清场', () {
    final String body = slice(
      iss,
      'function PrepareToInstall(var NeedsRestart: Boolean): String;',
      '\nend;',
    );
    final int gate = body.indexOf('OpenFushiInstallGate();');
    final int sweep = body.indexOf('KillProcessesUnderDir(');
    expect(gate, greaterThan(0), reason: 'PrepareToInstall 必须建门');
    expect(sweep, greaterThan(0));
    expect(gate, lessThan(sweep), reason: '门晚于清场建 = 清场与建门之间启动的实例两头都漏');
    expect(
      slice(iss, 'procedure OpenFushiInstallGate();', '\nend;'),
      contains('CreateMutexW(0, False, FushiInstallGateMutexName)'),
    );
  });

  test('全部文件落地（ssPostInstall）后放门，[Run] 拉起的新版不被挡', () {
    final String body = slice(
      iss,
      'procedure CurStepChanged(CurStep: TSetupStep);',
      '\nend;',
    );
    final int postInstall = body.indexOf('if CurStep <> ssPostInstall then');
    final int close = body.indexOf('CloseFushiInstallGate();');
    expect(postInstall, greaterThan(0));
    expect(close, greaterThan(postInstall), reason: '门只能在复制成功之后放');
    expect(
      iss,
      contains('Filename: "{app}\\fushi.exe"; Description:'),
      reason: '[Run] 自启条目仍在（它在 ssPostInstall 之后执行）',
    );
  });

  test('runner 启动第一步与等完旧实例后各看一次门，门在就立即退出', () {
    final String main = slice(
      runner,
      'int APIENTRY wWinMain(',
      'EnsureWritableWebView2UserDataFolder();',
    );
    final int firstCheck = main.indexOf(
      'if (!test_runner && InstallInProgress()) {',
    );
    final int mutex = main.indexOf(
      'SingleInstanceMutex single_instance_mutex(',
    );
    final int secondCheck = main.lastIndexOf(
      'if (!test_runner && InstallInProgress()) {',
    );
    final int handoff = main.indexOf('if (another_instance) {');
    expect(firstCheck, greaterThan(0), reason: '启动第一步必须看门');
    expect(firstCheck, lessThan(mutex), reason: '门要在抢单实例互斥量之前判');
    expect(secondCheck, greaterThan(handoff), reason: '等完退出中的旧实例后、建引擎前必须再看一次门');
    for (final int at in <int>[firstCheck, secondCheck]) {
      final String branch = main.substring(at, at + 200);
      expect(branch, contains('return EXIT_SUCCESS;'), reason: '门在就立即退出');
      expect(
        branch.contains('Wait('),
        isFalse,
        reason: '不能等门放开：等待期间进程映像与插件 DLL 一直被映射，安装照样失败',
      );
    }
  });

  test('提权安装建的门对普通权限进程是「拒绝访问」，同样算门在', () {
    final String probe = slice(runner, 'bool InstallInProgress() {', '\n}\n');
    expect(
      probe,
      contains('OpenMutexW(SYNCHRONIZE, FALSE, kInstallInProgressMutex)'),
    );
    expect(probe, contains('ERROR_ACCESS_DENIED'));
  });
}
