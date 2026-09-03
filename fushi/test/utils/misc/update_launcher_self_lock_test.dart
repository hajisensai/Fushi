import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_handoff.dart';

/// BUG-1786：应用内自更新永远装不上 `data\app.so`（全部 Dart 代码）。
///
/// 现场（用户机器，2026-08-23 14:58 的 Inno 日志 + 安装目录时间戳）：
/// `fushi_update_launcher.exe` 是拉起 Inno 的进程、且必须活到安装结束（BUG-1708 把
/// 「安装失败后把 app 拉回来」交给了它），可它自己就住在被重写的安装目录里 ⇒ 复制阶段
/// `DeleteFile failed; code 5` ⇒ `/SUPPRESSMSGBOXES` 对 Abort/Retry/Ignore 默认取
/// Abort ⇒ 整包回滚。字母序在它之前的 `fushi.exe` 已落地并保留，之后的 `data\app.so`
/// 一个字节没换 ⇒ 新 exe + 旧 Dart 代码，而版本号读自 exe，显示为新版。
void main() {
  group('stageWindowsUpdateLauncher', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fushi-launcher-stage');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('把 launcher 复制到 updates 目录下，路径落在安装目录之外', () async {
      final Directory installDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}app',
      );
      await installDir.create(recursive: true);
      final File launcher = File(
        '${installDir.path}'
        '${Platform.pathSeparator}$kWindowsUpdateLauncherExecutable',
      );
      await launcher.writeAsString('MZ-fake-launcher');
      final Directory updatesDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}updates',
      );
      await updatesDir.create(recursive: true);

      final String? staged = await stageWindowsUpdateLauncher(
        launcherPath: launcher.path,
        stageRoot: updatesDir,
      );

      expect(staged, isNotNull);
      // 关键不变式：副本不在安装目录里——否则等于没搬，Inno 照样撞占用。
      expect(staged, isNot(startsWith(installDir.path)));
      expect(staged, startsWith(updatesDir.path));
      expect(await File(staged!).readAsString(), 'MZ-fake-launcher');
    });

    test('固定名被占用时退让到带序号的名字，不放弃整次更新', () async {
      final File launcher = File(
        '${tempDir.path}${Platform.pathSeparator}$kWindowsUpdateLauncherExecutable',
      );
      await launcher.writeAsString('MZ-fake-launcher');
      final Directory updatesDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}updates',
      );
      await updatesDir.create(recursive: true);

      // 模拟「上一轮的副本仍被那次 launcher 持有」：固定名写入失败一次。
      int attempts = 0;
      final String? staged = await stageWindowsUpdateLauncher(
        launcherPath: launcher.path,
        stageRoot: updatesDir,
        copyFile: (File source, String destination) async {
          attempts++;
          if (attempts == 1) throw const FileSystemException('locked');
          await source.copy(destination);
        },
      );

      expect(staged, isNotNull);
      expect(staged, endsWith('fushi_update_launcher-1.exe'));
      expect(await File(staged!).exists(), isTrue);
    });

    test('launcher 不存在时返回 null（调用方回退到原地运行，不阻断更新）', () async {
      final String? staged = await stageWindowsUpdateLauncher(
        launcherPath: '${tempDir.path}${Platform.pathSeparator}nope.exe',
        stageRoot: tempDir,
      );
      expect(staged, isNull);
    });
  });

  group('windowsUpdateLauncherArgs', () {
    test('带上 --app-exe：副本同目录没有 fushi.exe，兜底拉回 app 必须靠显式路径', () {
      final List<String> args = windowsUpdateLauncherArgs(
        markerPath: r'C:\updates\marker.json',
        parentProcessId: 4242,
        installerPath: r'C:\updates\setup.exe',
        installerArgs: <String>['/VERYSILENT'],
        appExecutablePath: r'D:\APP\Hibiki\fushi.exe',
      );

      expect(
        args,
        containsAllInOrder(<String>['--app-exe', r'D:\APP\Hibiki\fushi.exe']),
      );
      // --app-exe 必须在 `--` 之前，否则会被当成安装器参数原样转发给 Inno。
      expect(args.indexOf('--app-exe'), lessThan(args.indexOf('--')));
      expect(args.sublist(args.indexOf('--') + 1), <String>['/VERYSILENT']);
    });

    test('没有 app 路径时不发 --app-exe（launcher 回退同目录判据）', () {
      final List<String> args = windowsUpdateLauncherArgs(
        markerPath: r'C:\updates\marker.json',
        parentProcessId: 4242,
        installerPath: r'C:\updates\setup.exe',
        installerArgs: const <String>[],
      );
      expect(args, isNot(contains('--app-exe')));
    });
  });

  group('windowsInnoLogReportsAbortedInstall', () {
    // 用户现场那次失败的真实日志尾巴（2026-08-23 14:58，12067 包）。
    const String abortedLog = '''
2026-08-23 14:58:28.319   Dest filename: D:\\APP\\Hibiki\\fushi_update_launcher.exe
2026-08-23 14:58:28.319   Installing the file.
2026-08-23 14:58:28.320   DeleteFile: The existing file appears to be in use (5). Retrying.
2026-08-23 14:58:32.352   Defaulting to Abort for suppressed message box (Abort/Retry/Ignore):
                          DeleteFile failed; code 5.
2026-08-23 14:58:32.352   User canceled the installation process.
2026-08-23 14:58:32.352   Rolling back changes.
2026-08-23 14:58:32.352   Starting the uninstallation process.
2026-08-23 14:58:32.353   Uninstallation process succeeded.
2026-08-23 14:58:32.353   Deinitializing Setup.
2026-08-23 14:58:32.358   Log closed.
''';

    test('回滚收场判为中止——「Uninstallation process succeeded」不算安装成功', () {
      // 这条正是最容易写错的地方：裸 contains 会让回滚自身的成功把结论翻成「装好了」。
      expect(windowsInnoLogReportsAbortedInstall(abortedLog), isTrue);
    });

    test('真正装完的日志判为成功', () {
      const String okLog = '''
2026-08-23 15:00:00.000   Dest filename: D:\\APP\\Hibiki\\data\\app.so
2026-08-23 15:00:01.000   Successfully installed the file.
2026-08-23 15:00:02.000   Installation process succeeded.
2026-08-23 15:00:02.000   Deinitializing Setup.
''';
      expect(windowsInnoLogReportsAbortedInstall(okLog), isFalse);
    });

    test('中途 DeleteFile 重试但最终装完 —— 不算失败', () {
      const String retriedLog = '''
2026-08-23 15:00:00.000   DeleteFile: The existing file appears to be in use (5). Retrying.
2026-08-23 15:00:01.000   Successfully installed the file.
2026-08-23 15:00:02.000   Installation process succeeded.
''';
      expect(windowsInnoLogReportsAbortedInstall(retriedLog), isFalse);
    });

    test('读不到日志时返回 false（不把成功的更新误报成失败）', () {
      expect(windowsInnoLogReportsAbortedInstall(null), isFalse);
      expect(windowsInnoLogReportsAbortedInstall(''), isFalse);
      expect(windowsInnoLogReportsAbortedInstall('   \n  '), isFalse);
    });
  });
}
