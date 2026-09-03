import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

/// BUG-1831：安装目录里的 `fushi_update_launcher.exe` **消失**之后，应用内更新永久卡死。
///
/// 现场（用户机器，2026-08-24）：`{app}` 下只有 `fushi_update_launcher.old.exe`，
/// 原件不见了；`data\app.so` 停在 8-19（比 BUG-1786 的修复还早），三次更新全部止步于
/// `update launcher not found`，`updates\` 里一条 Inno 日志都没有——安装器一次都没起来。
///
/// 成因是 BUG-1786「改名让路」的后半段：改名之后 `fushi_update_launcher.exe` 这个路径
/// 是空的，Inno 往里写的是**新建**文件，而 Inno 的回滚会删除本次新建的文件（只有被
/// 覆盖的文件才原样保留）。于是「让路成功但本次安装仍然回滚」= 原件已改名 + 新件被删
/// ⇒ 安装目录里再没有 launcher，BUG-1786 备注里「下一次应用内更新即自愈」的通道被
/// 自己切断。
///
/// 不变式：只要磁盘上还有**任何一份** launcher 映像（`.old` 残留也算），更新就必须发得出去。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fushi-launcher-vanished');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String join(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

  group('resolveWindowsUpdateLauncherSource', () {
    test('原件在位时用原件（不因为存在残留就改用残留）', () async {
      await File(
        join(kWindowsUpdateLauncherExecutable),
      ).writeAsString('MZ-new');
      await File(
        join(kWindowsUpdateLauncherStaleExecutable),
      ).writeAsString('MZ-old');

      expect(
        resolveWindowsUpdateLauncherSource(
          installedLauncherPath: join(kWindowsUpdateLauncherExecutable),
        ),
        join(kWindowsUpdateLauncherExecutable),
      );
    });

    test('原件消失、只剩 .old 残留时用残留 —— 正是用户现场，卡死与自愈的分界', () async {
      await File(
        join(kWindowsUpdateLauncherStaleExecutable),
      ).writeAsString('MZ-old');

      expect(
        resolveWindowsUpdateLauncherSource(
          installedLauncherPath: join(kWindowsUpdateLauncherExecutable),
        ),
        join(kWindowsUpdateLauncherStaleExecutable),
        reason: '.old 与原件是同一份映像；不认它就等于这台机器永远发不出更新',
      );
    });

    test('残留退让到带序号的名字时照样认（两侧靠命名约定对齐，不靠硬编码清单）', () async {
      await File(
        join('fushi_update_launcher.old3.exe'),
      ).writeAsString('MZ-old3');

      expect(
        resolveWindowsUpdateLauncherSource(
          installedLauncherPath: join(kWindowsUpdateLauncherExecutable),
        ),
        join('fushi_update_launcher.old3.exe'),
      );
    });

    test('一份映像都没有时返回 null（调用方照旧抛 not found，不静默假装成功）', () {
      expect(
        resolveWindowsUpdateLauncherSource(
          installedLauncherPath: join(kWindowsUpdateLauncherExecutable),
        ),
        isNull,
      );
    });

    test('同名前缀的无关文件不会被误当成 launcher', () async {
      await File(
        join('fushi_update_launcher.old.exe.bak'),
      ).writeAsString('not-an-exe');
      await File(join('fushi_update_launcher_notes.txt')).writeAsString('nope');

      expect(
        resolveWindowsUpdateLauncherSource(
          installedLauncherPath: join(kWindowsUpdateLauncherExecutable),
        ),
        isNull,
      );
    });
  });

  group('WindowsInstaller.runAndExit', () {
    test('只剩 .old 残留时照样把更新发出去，拉起的是残留而不是不存在的原件', () async {
      // 安装目录：exe 在、launcher 只剩 .old（用户现场的磁盘状态）。
      final Directory installDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}app',
      );
      await installDir.create(recursive: true);
      String inApp(String name) =>
          '${installDir.path}${Platform.pathSeparator}$name';
      await File(inApp('fushi.exe')).writeAsString('MZ-app');
      await File(
        inApp(kWindowsUpdateLauncherStaleExecutable),
      ).writeAsString('MZ-old-launcher');

      final Directory updatesDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}updates',
      );
      await updatesDir.create(recursive: true);
      final File installer = File(
        '${updatesDir.path}${Platform.pathSeparator}setup.exe',
      );
      // MZ 头：runAndExit 会先校验下载的确实是个 Windows 可执行文件。
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);
      final File marker = File(
        '${updatesDir.path}${Platform.pathSeparator}handoff.json',
      );

      String? launched;
      var exitCalls = 0;
      await WindowsInstaller.runAndExit(
        installer.path,
        targetVersion: '2.2.1-debug.12215',
        handoffMarkerFile: marker,
        currentExecutablePath: inApp('fushi.exe'),
        collectDiagnostics: () async => const WindowsInstallerDiagnostics(),
        startProcess: (String executable, List<String> args) async {
          launched = executable;
          return const WindowsInstallerStartedProcess(pid: 1234);
        },
        exitProcess: (int code) => exitCalls++,
      );

      // 按**内容**判定源，而不是按路径：Windows 上还会把它 stage 成安装目录外的副本
      // （BUG-1786），路径因此不固定，但那份字节必须来自 `.old` 残留。
      expect(launched, isNotNull);
      final String launchedPath = launched!;
      expect(
        File(launchedPath).existsSync(),
        isTrue,
        reason: '拉起的必须是磁盘上真实存在的映像，而不是一个不存在的路径',
      );
      expect(
        await File(launchedPath).readAsString(),
        'MZ-old-launcher',
        reason:
            '原件不在磁盘上，拿它当 executable 只会得到 not found；'
            '残留是同一份映像，必须接着用它把这次安装跑完',
      );
      expect(
        launchedPath,
        isNot(inApp(kWindowsUpdateLauncherExecutable)),
        reason: '绝不能回退到那个已经消失的原件路径',
      );
      expect(exitCalls, 1, reason: 'launcher 起来之后当前实例必须让出文件锁');
    });
  });
}
