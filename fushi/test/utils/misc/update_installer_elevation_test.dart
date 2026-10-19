import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

/// 装进 `C:\Program Files\Fushi`（手动提权安装）后，普通权限的 app 写不进安装目录，
/// 应用内更新旧行为是直接报 `Cannot write to installation directory` 并要求用户
/// 「以管理员身份重开 Fushi」。现在改为只把**安装器**经 UAC 提权（BUG-3567）：
/// - app 给 launcher 下发 `--elevate` + 发布方公布的 `--installer-sha256`，launcher
///   锁住安装包、复核哈希后用 `ShellExecuteExW runas` 拉起 Inno（BUG-3567）；
/// - Inno 带 `/FUSHINORELAUNCH` 跳过 `[Run]` 自启（否则 app 继承管理员令牌），
///   由仍是普通权限的 launcher 装完后把 app 拉回来。
void main() {
  late Directory tempDir;

  const String digest =
      '23240ef9f8b0a9a324110b1c2331de31dc1b0e08f5359cb707e51a939af56cd3';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fushi-update-elevate');
    UpdateDownloadTrust.debugReset();
  });

  tearDown(() async {
    UpdateDownloadTrust.debugReset();
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

    test('--elevate 与 --installer-sha256 是 launcher 自己的选项，必须落在 -- 之前', () {
      final List<String> args = windowsUpdateLauncherArgs(
        markerPath: r'C:\u\m.json',
        parentProcessId: 7,
        installerPath: r'C:\u\setup.exe',
        installerArgs: const <String>['/VERYSILENT'],
        elevatedInstallerSha256: digest.toUpperCase(),
      );
      final int separator = args.indexOf('--');
      expect(args, contains(kWindowsUpdateLauncherElevateFlag));
      expect(
        args.indexOf(kWindowsUpdateLauncherElevateFlag),
        lessThan(separator),
        reason: '-- 之后的参数全部原样转给 Inno，落到后面 launcher 就看不见它',
      );
      final int hashFlag = args.indexOf(
        kWindowsUpdateLauncherInstallerSha256Flag,
      );
      expect(hashFlag, greaterThanOrEqualTo(0));
      expect(hashFlag, lessThan(separator));
      expect(args[hashFlag + 1], digest, reason: 'launcher 只认小写十六进制');
      expect(
        windowsUpdateLauncherArgs(
          markerPath: r'C:\u\m.json',
          parentProcessId: 7,
          installerPath: r'C:\u\setup.exe',
          installerArgs: const <String>[],
        ),
        allOf(
          isNot(contains(kWindowsUpdateLauncherElevateFlag)),
          isNot(contains(kWindowsUpdateLauncherInstallerSha256Flag)),
        ),
      );
    });

    test('提权哈希不是 64 位十六进制时拒绝构造参数', () {
      expect(
        () => windowsUpdateLauncherArgs(
          markerPath: r'C:\u\m.json',
          parentProcessId: 7,
          installerPath: r'C:\u\setup.exe',
          installerArgs: const <String>[],
          elevatedInstallerSha256: 'not-a-digest',
        ),
        throwsArgumentError,
      );
    });
  });

  group('UpdateDownloadTrust', () {
    test('只认本进程登记过的路径，大小写 / 相对路径归一', () {
      final File file = File(join('setup.exe'));
      expect(UpdateDownloadTrust.verifiedSha256For(file), isNull);
      UpdateDownloadTrust.recordVerified(file, 'sha256:$digest');
      expect(
        UpdateDownloadTrust.verifiedSha256For(file),
        isNull,
        reason: '带前缀 / 非法格式的值不登记',
      );
      UpdateDownloadTrust.recordVerified(file, digest.toUpperCase());
      expect(UpdateDownloadTrust.verifiedSha256For(file), digest);
      expect(
        UpdateDownloadTrust.verifiedSha256For(File(file.path.toUpperCase())),
        digest,
        reason: 'Windows 路径大小写不敏感',
      );
      expect(
        UpdateDownloadTrust.verifiedSha256For(File(join('other.exe'))),
        isNull,
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

    Future<List<String>?> run(
      ({Directory installDir, File installer, File marker}) prepared, {
      required WindowsInstallDirWriteProbe probe,
      String? expectedSha256,
      String actualSha256 = digest,
      bool withLauncher = true,
      void Function()? onExit,
      void Function()? onStart,
    }) async {
      List<String>? launchedArgs;
      await WindowsInstaller.runAndExit(
        prepared.installer.path,
        targetVersion: withLauncher ? '3.0.1' : null,
        handoffMarkerFile: withLauncher ? prepared.marker : null,
        currentExecutablePath:
            '${prepared.installDir.path}${Platform.pathSeparator}fushi.exe',
        collectDiagnostics: () async => const WindowsInstallerDiagnostics(),
        probeInstallDirWritable: (Directory dir) async => probe,
        expectedSha256: expectedSha256,
        hashFile: (File file) async => actualSha256,
        startProcess: (String executable, List<String> args) async {
          onStart?.call();
          launchedArgs = args;
          return const WindowsInstallerStartedProcess(pid: 42);
        },
        exitProcess: (int code) => onExit?.call(),
      );
      return launchedArgs;
    }

    test('拒绝访问 + 有公布哈希：交给 launcher 提权安装，并把哈希交给它复核', () async {
      final prepared = await prepare();
      var exitCalls = 0;
      final List<String>? launchedArgs = await run(
        prepared,
        probe: WindowsInstallDirWriteProbe.accessDenied,
        expectedSha256: digest,
        onExit: () => exitCalls++,
      );

      expect(launchedArgs, isNotNull);
      final List<String> args = launchedArgs!;
      final int separator = args.indexOf('--');
      final List<String> launcherOwn = args.sublist(0, separator);
      expect(launcherOwn, contains(kWindowsUpdateLauncherElevateFlag));
      expect(
        launcherOwn[launcherOwn.indexOf(
              kWindowsUpdateLauncherInstallerSha256Flag,
            ) +
            1],
        digest,
      );
      expect(
        args.sublist(separator + 1),
        contains(kWindowsInstallerNoRelaunchSwitch),
        reason: '提权的安装器自启 app 会把管理员令牌传给 app',
      );
      expect(exitCalls, 1);
    });

    test('拒绝访问但发布方没公布哈希：不提权执行未校验的安装包，报错且不退出', () async {
      final prepared = await prepare();
      var exitCalls = 0;
      var startCalls = 0;
      await expectLater(
        run(
          prepared,
          probe: WindowsInstallDirWriteProbe.accessDenied,
          onExit: () => exitCalls++,
          onStart: () => startCalls++,
        ),
        throwsA(
          isA<UpdateInstallerException>().having(
            (UpdateInstallerException e) => e.toString(),
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(startCalls, 0);
      expect(exitCalls, 0);
    });

    test('写失败但不是权限问题（磁盘满等）：提权救不了，报错不弹 UAC', () async {
      final prepared = await prepare();
      var startCalls = 0;
      await expectLater(
        run(
          prepared,
          probe: WindowsInstallDirWriteProbe.failed,
          expectedSha256: digest,
          onStart: () => startCalls++,
        ),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(startCalls, 0);
    });

    test('安装包与公布哈希不符：删掉安装包、不交接、不退出', () async {
      final prepared = await prepare();
      var exitCalls = 0;
      var startCalls = 0;
      await expectLater(
        run(
          prepared,
          probe: WindowsInstallDirWriteProbe.writable,
          expectedSha256: digest,
          actualSha256: 'f' * 64,
          onExit: () => exitCalls++,
          onStart: () => startCalls++,
        ),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(startCalls, 0);
      expect(exitCalls, 0);
      expect(prepared.installer.existsSync(), isFalse);
    });

    test('安装目录可写：普通交接，不提权、不压制自启', () async {
      final prepared = await prepare();
      final List<String>? launchedArgs = await run(
        prepared,
        probe: WindowsInstallDirWriteProbe.writable,
        expectedSha256: digest,
      );

      expect(launchedArgs, isNot(contains(kWindowsUpdateLauncherElevateFlag)));
      expect(
        launchedArgs,
        isNot(contains(kWindowsUpdateLauncherInstallerSha256Flag)),
      );
      expect(launchedArgs, isNot(contains(kWindowsInstallerNoRelaunchSwitch)));
    });

    test('没有 launcher（无交接 marker）时无从提权，仍报错且不退出 app', () async {
      final prepared = await prepare();
      var exitCalls = 0;
      var startCalls = 0;
      await expectLater(
        run(
          prepared,
          probe: WindowsInstallDirWriteProbe.accessDenied,
          expectedSha256: digest,
          withLauncher: false,
          onExit: () => exitCalls++,
          onStart: () => startCalls++,
        ),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(startCalls, 0);
      expect(exitCalls, 0);
    });
  });

  group('probeWindowsInstallTargetWritable', () {
    test('可写目录判 writable，且不留探针文件', () async {
      final Directory dir = Directory(join('writable'));
      expect(
        await probeWindowsInstallTargetWritable(dir),
        WindowsInstallDirWriteProbe.writable,
      );
      expect(dir.listSync(), isEmpty);
    });

    test('Windows 下系统目录（ACL 拒写）判 accessDenied', () async {
      final String systemRoot =
          Platform.environment['SystemRoot'] ?? r'C:\Windows';
      expect(
        await probeWindowsInstallTargetWritable(
          Directory('$systemRoot\\System32'),
        ),
        WindowsInstallDirWriteProbe.accessDenied,
      );
    }, skip: !Platform.isWindows ? '只在 Windows 上有 ACL 语义' : false);
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

    test('launcher 提权前锁住安装包、按公布哈希复核、用锁出的真实路径启动（BUG-3567）', () {
      final String launcher = File(
        'windows/runner/update_launcher.cpp',
      ).readAsStringSync();
      expect(
        launcher,
        contains('arg == L"$kWindowsUpdateLauncherInstallerSha256Flag"'),
      );
      // 共享模式只给读：校验后别人既写不了、也删 / 改名不了这个文件。
      expect(
        launcher,
        contains(
          'lock->handle = ::CreateFileW(args.installer_path.c_str(), '
          'GENERIC_READ,\n                               FILE_SHARE_READ, ',
        ),
      );
      expect(launcher, contains('GetFinalPathNameByHandleW'));
      expect(launcher, contains('info.lpFile = lock->final_path.c_str();'));
      expect(
        launcher,
        contains('if (!LockAndVerifyInstaller(args, lock)) return false;'),
      );
      // 锁的生命周期跨过等待安装器结束：在 main 里声明、析构放开。
      expect(launcher, contains('InstallerFileLock installer_lock;'));
      expect(
        launcher,
        contains('LaunchInstaller(args, &run, &installer_lock)'),
      );
    });
  });
}
