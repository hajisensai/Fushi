import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1786 守卫：应用内自更新必须能把整包装完。
///
/// 两条各自独立、缺一条就复发的不变式，都钉在 `fushi.iss` 上——因为**安装器的行为由
/// 新包决定**，这是存量旧版用户唯一能自愈的通道（他们跑的仍是旧 launcher）。
void main() {
  String readInstallerScript() {
    final File file = File('windows/installer/fushi.iss');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected Inno Setup script at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  test('运行中的 update launcher 由改名让路，而不是被杀掉', () {
    final String iss = readInstallerScript();

    // 断言字面量（勿改）: 'MakeWayForRunningLauncher'
    expect(
      iss,
      contains('procedure MakeWayForRunningLauncher('),
      reason: 'launcher 是拉起本安装器的进程，复制阶段必然撞 DeleteFile code 5；'
          '没有这一步，/SUPPRESSMSGBOXES 会默认 Abort 并整包回滚',
    );
    // 必须真的被 PrepareToInstall 调用，光定义不算。
    final int prepareAt = iss.indexOf('function PrepareToInstall(');
    expect(prepareAt, greaterThan(0));
    expect(
      iss.substring(prepareAt),
      contains('MakeWayForRunningLauncher(ExpandConstant('),
      reason: '必须在复制任何文件之前（PrepareToInstall）让路',
    );
    // 改名而不是删除：Windows 允许给运行中的 exe 改名，但删不掉；而且**不能**杀它
    // ——BUG-1708 把「安装失败后把 app 拉回来」交给了它。
    // 过程体取到下一个 procedure/function 为止，**不用固定字符窗口**：BUG-1831 补进来
    // 的注释一度把真正的让路语句挤出了 900 字符窗口，守卫于是改为被别处的 RenameFile
    // 蒙混通过——一条守卫因为无关的注释增删而悄悄失去覆盖，比没有守卫更坏。
    final int makeWayAt = iss.indexOf('procedure MakeWayForRunningLauncher(');
    final int makeWayEnd = iss.indexOf('function PrepareToInstall(', makeWayAt);
    expect(makeWayEnd, greaterThan(makeWayAt));
    final String body = iss.substring(makeWayAt, makeWayEnd);
    // 断言字面量（勿改）: 'RenameFile(Launcher, Stale)'
    // 方向要钉死：Launcher → Stale 才是让路，反过来是 BUG-1831 的恢复分支，
    // 两者都必须在，任一缺失都是一条独立的复发路径。
    expect(
      body,
      contains('RenameFile(Launcher, Stale)'),
      reason: '让路手段必须是改名（把占用中的原件改走），不能是删除、也不能是杀进程',
    );
    expect(
      body,
      contains('FileLockedForWrite('),
      reason: '只在真的被占用时才改名，别给正常路径平添残留文件',
    );
  });

  test('BUG-1831：launcher 已消失、只剩残留时，把残留改回去而不是删掉', () {
    final String iss = readInstallerScript();
    final int makeWayAt = iss.indexOf('procedure MakeWayForRunningLauncher(');
    expect(makeWayAt, greaterThan(0));
    final int endAt = iss.indexOf('function PrepareToInstall(', makeWayAt);
    expect(endAt, greaterThan(makeWayAt));
    final String body = iss.substring(makeWayAt, endAt);

    // 断言字面量（勿改）: 'RenameFile(Stale, Launcher)'
    //
    // 「改名让路」把 launcher 从「必然存在的文件」变成了「可以永久消失的文件」：改名后
    // 目标路径是空的，Inno 往里写的是**新建**文件，而回滚会删除本次新建的文件（只有被
    // 覆盖的文件才原样保留）。让路成功但本次安装仍然回滚 ⇒ 原件已改名 + 新件被删 ⇒
    // 安装目录里再没有 launcher，旧版 app 只认这一个路径，从此每次更新都止步
    // not found，安装器一次都起不来。残留是同一份映像，必须改回去。
    expect(
      body,
      contains('RenameFile(Stale, Launcher)'),
      reason: 'launcher 缺失时必须用残留把它恢复回去，否则这台机器永远发不出更新',
    );

    // 顺序不变式：先判「原件在不在」，再谈删残留。反过来（现状之前就是如此）会在
    // 最需要残留的那一刻把它删掉，把「还能自愈」变成「永久卡死」。
    final int missingCheckAt = body.indexOf('if not FileExists(Launcher) then');
    final int firstDeleteAt = body.indexOf('DeleteFile(Stale)');
    expect(missingCheckAt, greaterThan(0));
    expect(firstDeleteAt, greaterThan(0));
    expect(
      missingCheckAt,
      lessThan(firstDeleteAt),
      reason: '删残留必须发生在「原件在位」这个分支里；'
          '无条件先删会毁掉唯一的恢复材料',
    );
  });

  test('app 目录扫进程走 sysnative，且放过 launcher', () {
    final String iss = readInstallerScript();
    final int killAt = iss.indexOf('procedure KillProcessesUnderDir(');
    expect(killAt, greaterThan(0));
    final String body = iss.substring(killAt, killAt + 2200);

    // 断言字面量（勿改）: '{sysnative}'
    //
    // 本安装器是 32 位进程（[Setup] 里没有 ArchitecturesInstallIn64BitMode，
    // 安装日志写「64-bit install mode: No」）。{sys} 会被 WOW64 重定向到 SysWOW64 的
    // 32 位 PowerShell，而 32 位 PowerShell 读不到 64 位进程的 .Path（取到空串），
    // 于是过滤条件 `$_.Path -and ...` 对每一个 64 位进程恒假 —— 整个过程是发哑弹。
    // 实测同一命令同一 x64 目标：64 位 PS 杀得掉、32 位 PS 杀不掉且 Path 为空。
    expect(
      body,
      contains(r"ExpandConstant('{sysnative}\WindowsPowerShell"),
      reason: '32 位 Inno 经 {sys} 只能拿到 32 位 PowerShell，读不到 64 位进程的 Path，'
          '这个清扫就成了哑弹；必须用 {sysnative} 绕开 WOW64 重定向',
    );
    expect(
      body,
      isNot(contains(r"ExpandConstant('{sys}\WindowsPowerShell")),
      reason: '不得回退到 {sys}（WOW64 重定向 → 32 位 PowerShell → 哑弹）',
    );

    // 断言字面量（勿改）: 'fushi_update_launcher'
    // 清扫一旦真正生效，就必须显式放过 launcher：杀了它 = 安装失败时没人把 app
    // 拉回来（BUG-1708 复发）。它占住的文件由 MakeWayForRunningLauncher 处理。
    expect(
      body,
      contains(r"$_.ProcessName -ne ''fushi_update_launcher''"),
      reason: 'launcher 必须被排除，否则清扫生效之日就是 BUG-1708 复发之时',
    );
  });
}
