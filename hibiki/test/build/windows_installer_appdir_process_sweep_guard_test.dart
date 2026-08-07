import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1459 回归守卫：Windows 安装器必须在文件复制前清扫安装目录下的残留进程。
///
/// 根因：`InitializeSetup` 的互斥体层只能证明主程序 `hibiki.exe`/`fushi.exe`
/// 已退出；从安装目录启动的辅助进程（Anki 音频的 `ffmpeg.exe`、galgame helper）
/// 可以比主程序活得久并锁住自己的镜像文件，文件复制阶段随即死于
/// "could not replace ...\ffmpeg.exe (DeleteFile code 5)"。
///
/// 修复：`PrepareToInstall`（用户确认后、复制前的最后钩子）调用
/// `KillProcessesUnderDir`，按「可执行文件路径位于目标目录之下」清扫——
/// 按路径而非进程名过滤，机器上其它同名进程（用户自己的 ffmpeg）不受波及。
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

  test('PrepareToInstall sweeps app-dir processes before file copy', () {
    final String iss = readInstallerScript();

    expect(
      iss,
      contains('function PrepareToInstall(var NeedsRestart: Boolean): String;'),
      reason: 'BUG-1459：必须存在 PrepareToInstall 钩子（复制前最后清锁点）',
    );
    expect(
      iss,
      contains('KillProcessesUnderDir(ExpandConstant(\'{app}\'));'),
      reason: 'BUG-1459：PrepareToInstall 必须对 {app} 做残留进程清扫',
    );
  });

  test('sweep filters by image path under the target dir, not by name', () {
    final String iss = readInstallerScript();

    expect(
      iss,
      contains('StartsWith(\$d, [System.StringComparison]::OrdinalIgnoreCase)'),
      reason: 'BUG-1459：必须按可执行路径前缀过滤（大小写不敏感），'
          '不得按进程名全局杀（会误伤用户自己的同名进程）',
    );
    expect(
      iss,
      contains(r'Stop-Process -Force'),
      reason: 'BUG-1459：路径命中的残留进程必须强制终止，否则文件仍被锁',
    );
  });
}
