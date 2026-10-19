import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

/// 装进 `C:\Program Files\Fushi`（手动提权安装）后，普通权限的 app 写不进安装目录，
/// 应用内更新旧行为是直接报 `Cannot write to installation directory` 并要求用户
/// 「以管理员身份重开 Fushi」。现在改为只把**安装器**经 UAC 提权：
/// - app 给 launcher 下发 `--elevate`，launcher 用 `ShellExecuteExW runas` 拉起 Inno；
/// - Inno 带 `/FUSHINORELAUNCH` 跳过 `[Run]` 自启（否则 app 继承管理员令牌），
///   由仍是普通权限的 launcher 装完后把 app 拉回来。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fushi-update-elevate');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String join(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

  group('参数构造', () {
    test('suppressAppRelaunch 才带 /FUSHINORELAUNCH，默认不带', () {
      expect(
        windowsInstallerArgs(r'C:\u\setup.exe'),
        isNot(contains(kWindowsInstallerNoRelaunchSwitch)),
      );
      expect(
        windowsInstallerArgs(r'C:\u\setup.exe', suppressAppRelaunch: true),
        contains(kWindowsInstallerNoRelaunchSwitch),
      );
    });

    test('--elevate 是 launcher 自己的选项，必须落在 -- 之前', () {
      final List<String> args = windowsUpdateLauncherArgs(
        markerPath: r'C:\u\m.json',
        parentProcessId: 7,
        installerPath: r'C:\u\setup.exe',
        installerArgs: const <String>['/VERYSILENT'],
        elevateInstaller: true,
      );
      expect(args, contains(kWindowsUpdateLauncherElevateFlag));
      expect(
        args.indexOf(kWindowsUpdateLauncherElevateFlag),
        lessThan(args.indexOf('--')),
        reason: '-- 之后的参数全部原样转给 Inno，落到后面 launcher 就看不见它',
      );
      expect(
        windowsUpdateLauncherArgs(
          markerPath: r'C:\u\m.json',
          parentProcessId: 7,
          installerPath: r'C:\u\setup.exe',
          installerArgs: const <String>[],
        ),
        isNot(contains(kWindowsUpdateLauncherElevateFlag)),
      );
    });
  });

  group('WindowsInstaller.runAndExit', () {
    Future<({Directory installDir, File installer, File marker})>
    prepare() async {
      final Directory installDir = Directory(join('app'));
      await installDir.create(recursive: true);
      await File(
        '${installDir.path}${Platform.pathSeparator}fushi.exe',
      ).writeAsString('MZ-app');
      await File(
        '${installDir.path}${Platform.pathSeparator}'
        '$kWindowsUpdateLauncherExecutable',
      ).writeAsString('MZ-launcher');
      final Directory updatesDir = Directory(join('updates'));
      await updatesDir.create(recursive: true);
      final File installer = File(
        '${updatesDir.path}${Platform.pathSeparator}setup.exe',
      );
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);
      final File marker = File(
        '${updatesDir.path}${Platform.pathSeparator}handoff.json',
      );
      return (installDir: installDir, installer: installer, marker: marker);
    }

    test('安装目录不可写：交给 launcher 提权安装，而不是报错让用户以管理员重开', () async {
      final prepared = await prepare();
      List<String>? launchedArgs;
      var exitCalls = 0;
      await WindowsInstaller.runAndExit(
        prepared.installer.path,
        targetVersion: '3.0.1',
        handoffMarkerFile: prepared.marker,
        currentExecutablePath:
            '${prepared.installDir.path}${Platform.pathSeparator}fushi.exe',
        collectDiagnostics: () async => const WindowsInstallerDiagnostics(),
        probeInstallDirWritable: (Directory dir) async => false,
        startProcess: (String executable, List<String> args) async {
          launchedArgs = args;
          return const WindowsInstallerStartedProcess(pid: 42);
        },
        exitProcess: (int code) => exitCalls++,
      );

      expect(launchedArgs, isNotNull);
      final List<String> args = launchedArgs!;
      final int separator = args.indexOf('--');
      expect(
        args.sublist(0, separator),
        contains(kWindowsUpdateLauncherElevateFlag),
      );
      expect(
        args.sublist(separator + 1),
        contains(kWindowsInstallerNoRelaunchSwitch),
        reason: '提权的安装器自启 app 会把管理员令牌传给 app',
      );
      expect(exitCalls, 1);
    });

    test('安装目录可写：普通交接，不提权、不压制自启', () async {
      final prepared = await prepare();
      List<String>? launchedArgs;
      await WindowsInstaller.runAndExit(
        prepared.installer.path,
        targetVersion: '3.0.1',
        handoffMarkerFile: prepared.marker,
        currentExecutablePath:
            '${prepared.installDir.path}${Platform.pathSeparator}fushi.exe',
        collectDiagnostics: () async => const WindowsInstallerDiagnostics(),
        probeInstallDirWritable: (Directory dir) async => true,
        startProcess: (String executable, List<String> args) async {
          launchedArgs = args;
          return const WindowsInstallerStartedProcess(pid: 42);
        },
        exitProcess: (int code) {},
      );

      expect(launchedArgs, isNot(contains(kWindowsUpdateLauncherElevateFlag)));
      expect(launchedArgs, isNot(contains(kWindowsInstallerNoRelaunchSwitch)));
    });

    test('没有 launcher（无交接 marker）时无从提权，仍报错且不退出 app', () async {
      final prepared = await prepare();
      var exitCalls = 0;
      var startCalls = 0;
      await expectLater(
        WindowsInstaller.runAndExit(
          prepared.installer.path,
          currentExecutablePath:
              '${prepared.installDir.path}${Platform.pathSeparator}fushi.exe',
          collectDiagnostics: () async => const WindowsInstallerDiagnostics(),
          probeInstallDirWritable: (Directory dir) async => false,
          startProcess: (String executable, List<String> args) async {
            startCalls++;
            return const WindowsInstallerStartedProcess(pid: 42);
          },
          exitProcess: (int code) => exitCalls++,
        ),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(startCalls, 0);
      expect(exitCalls, 0);
    });
  });

  group('两侧接线', () {
    test('fushi.iss 的 [Run] 自启受 /FUSHINORELAUNCH 门控', () {
      final String script = File(
        'windows/installer/fushi.iss',
      ).readAsStringSync();
      expect(
        script,
        contains(
          'Flags: nowait postinstall; Check: ShouldLaunchAppAfterInstall',
        ),
      );
      expect(
        script,
        contains('function ShouldLaunchAppAfterInstall(): Boolean;'),
      );
      expect(script, contains("'$kWindowsInstallerNoRelaunchSwitch'"));
    });

    test('launcher 认 --elevate 并以 runas 拉起安装器、提权时不白等自启', () {
      final String launcher = File(
        'windows/runner/update_launcher.cpp',
      ).readAsStringSync();
      expect(
        launcher,
        contains('arg == L"$kWindowsUpdateLauncherElevateFlag"'),
      );
      expect(launcher, contains('info.lpVerb = L"runas";'));
      expect(launcher, contains('SEE_MASK_NOCLOSEPROCESS'));
      expect(launcher, contains('ERROR_CANCELLED'));
      expect(
        launcher,
        contains('args.elevate_installer ? SingleInstanceMutexHeld()'),
      );
    });
  });
}
