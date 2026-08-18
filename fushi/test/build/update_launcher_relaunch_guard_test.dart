import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1708 第三面：**安装失败后必须有人把 app 拉回来**。
///
/// 更新链上原本没有任何一环对「app 还活着」负责：app 为让出文件锁主动 `exit(0)`，
/// 只要安装器没走到成功路径（PrepareToInstall 中止、复制阶段 DeleteFile 失败后回滚、
/// 用户取消、setup 自己崩溃），`.iss` 的 `[Run]` 就不会执行，Fushi 从桌面上静默消失，
/// 而 `/SUPPRESSMSGBOXES` 连原因都吞掉。用户现场：连续五次更新如此，版本卡了三天。
///
/// launcher 是唯一横跨全程的进程，这份守卫钉住它确实承担了这个责任。C++ 侧没有单测
/// 框架，故与仓库其它 native 行为一样走源码扫描。
void main() {
  late String source;

  setUpAll(() {
    final File file = File('windows/runner/update_launcher.cpp');
    expect(file.existsSync(), isTrue, reason: 'launcher 源码路径变了就要同步改这份守卫');
    source = file.readAsStringSync();
  });

  test('安装器结束后会检查 app 是否回来', () {
    // 断言字面量（勿改）: 'EnsureAppBack'
    expect(source, contains('void EnsureAppBack('));
    // 断言字面量（勿改）: 'WaitForAppAlive'
    expect(source, contains('bool WaitForAppAlive('));
  });

  test('判据是「还有没有 Fushi 活着」，不是 Inno 的退出码', () {
    // 退出码语义随 Inno 版本和失败类型漂移；按退出码分支等于给每种失败加一条特例。
    // EnsureAppBack 必须先问互斥体，再决定要不要拉起。
    final int ensureIndex = source.indexOf('void EnsureAppBack(');
    expect(ensureIndex, greaterThan(0));
    final String body = source.substring(ensureIndex);
    final int waitIndex = body.indexOf('WaitForAppAlive(kAppRelaunchWaitMs)');
    expect(waitIndex, greaterThan(0),
        reason: 'EnsureAppBack 必须以「app 是否已回来」为判据');
    // 已经回来就直接返回，绝不重复拉起（安装成功时 [Run] 已经拉起新版）。
    expect(body.substring(waitIndex, waitIndex + 400), contains('return;'));
  });

  test('安装器根本没起来时也要把 app 拉回来', () {
    // CreateProcess 失败原本直接 return 4：launcher 是分离进程，没人读这个返回码，
    // 于是 app 就这么没了。
    final int failIndex = source.indexOf('if (!LaunchInstaller(args, &run))');
    expect(failIndex, greaterThan(0));
    final String branch = source.substring(failIndex, failIndex + 500);
    expect(branch, contains('EnsureAppBack('), reason: '启动安装器失败必须先恢复 app 再返回');
  });

  test('会等安装器退出后再判断，而不是发起后立刻收工', () {
    expect(source, contains('WaitForSingleObject(run.process'));
    // 断言字面量（勿改）: 'kInstallerExitTimeoutMs'
    expect(source, contains('kInstallerExitTimeoutMs'));
  });

  test('重启目标是与 launcher 同目录的 fushi.exe', () {
    final int index = source.indexOf('std::wstring AppExecutablePath()');
    expect(index, greaterThan(0));
    expect(source.substring(index, index + 600), contains('fushi.exe'));
  });

  test('恢复结果写进 handoff marker，供 app 起来后向用户交代', () {
    // 失败原因不能只躺在被 /SUPPRESSMSGBOXES 吞掉的消息框里。
    expect(source, contains('appRelaunchedByLauncher'));
    expect(source, contains('installerExitCode'));
  });
}
