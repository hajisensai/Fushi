import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';

List<Map<String, dynamic>> _assets(List<String> names) => names
    .map((String n) => <String, dynamic>{
          'name': n,
          'browser_download_url': 'https://example.com/$n',
        })
    .toList();

Future<String?> _urlOf(Future<UpdateAsset?> selection) async =>
    (await selection)?.url;

void main() {
  group('WindowsUpdater.selectAsset', () {
    test('picks the -windows-setup.exe asset', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await _urlOf(u.selectAsset(_assets(<String>[
        'fushi-0.4.2-arm64-v8a.apk',
        'fushi-0.4.2-windows-setup.exe',
        'fushi-0.4.2-linux-x86_64.AppImage',
      ])));
      expect(url, 'https://example.com/fushi-0.4.2-windows-setup.exe');
    });

    test('returns null when no windows asset present', () async {
      final WindowsUpdater u = WindowsUpdater();
      final UpdateAsset? url =
          await u.selectAsset(_assets(<String>['fushi-0.4.2-arm64-v8a.apk']));
      expect(url, isNull);
    });

    test('debug channel selects a debug Windows setup asset', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await _urlOf(u.selectAsset(
        _assets(<String>[
          'fushi-0.5.1-windows-setup.exe',
          'fushi-0.5.1-debug.412-windows-setup.exe',
        ]),
        channel: UpdateChannel.debug,
      ));
      expect(
        url,
        'https://example.com/fushi-0.5.1-debug.412-windows-setup.exe',
      );
    });

    test('preserves release asset size and digest metadata', () async {
      final WindowsUpdater u = WindowsUpdater();
      const String digest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final UpdateAsset? asset = await u.selectAsset(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'fushi-0.4.2-windows-setup.exe',
          'browser_download_url':
              'https://example.com/fushi-0.4.2-windows-setup.exe',
          'size': 12345,
          'digest': 'sha256:$digest',
        },
      ]);

      expect(asset?.url, 'https://example.com/fushi-0.4.2-windows-setup.exe');
      expect(asset?.sizeBytes, 12345);
      expect(asset?.sha256Digest, digest);
    });

    test('stable and beta ignore debug Windows setup assets', () async {
      final WindowsUpdater u = WindowsUpdater();
      final List<Map<String, dynamic>> assets = _assets(<String>[
        'fushi-0.5.1-debug.412-windows-setup.exe',
      ]);

      expect(
        await u.selectAsset(assets, channel: UpdateChannel.stable),
        isNull,
      );
      expect(
        await u.selectAsset(assets, channel: UpdateChannel.beta),
        isNull,
      );
    });

    test('supports update check and in-app install', () {
      final WindowsUpdater u = WindowsUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isTrue);
    });
  });

  group('AndroidUpdater.selectAsset', () {
    test('matches device ABI', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final String? url = await _urlOf(u.selectAsset(_assets(<String>[
        'fushi-0.4.2-armeabi-v7a.apk',
        'fushi-0.4.2-arm64-v8a.apk',
        'fushi-0.4.2-windows-setup.exe',
      ])));
      expect(url, 'https://example.com/fushi-0.4.2-arm64-v8a.apk');
    });

    test('stable and beta ignore debug APK assets', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final List<Map<String, dynamic>> assets = _assets(<String>[
        'fushi-0.5.1-debug.412-abc1234-debug.apk',
        'fushi-0.5.1-arm64-v8a.apk',
      ]);

      expect(
        await _urlOf(u.selectAsset(assets, channel: UpdateChannel.stable)),
        'https://example.com/fushi-0.5.1-arm64-v8a.apk',
      );
      expect(
        await _urlOf(u.selectAsset(assets, channel: UpdateChannel.beta)),
        'https://example.com/fushi-0.5.1-arm64-v8a.apk',
      );
    });

    test('debug channel only selects debug APK assets', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );

      expect(
        await _urlOf(u.selectAsset(
          _assets(<String>[
            'fushi-0.5.1-arm64-v8a.apk',
            'fushi-0.5.1-debug.412-abc1234-debug.apk',
          ]),
          channel: UpdateChannel.debug,
        )),
        'https://example.com/fushi-0.5.1-debug.412-abc1234-debug.apk',
      );
      expect(
        await u.selectAsset(
          _assets(<String>['fushi-0.5.1-arm64-v8a.apk']),
          channel: UpdateChannel.debug,
        ),
        isNull,
      );
    });

    test('falls back to first apk when no ABI match', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['x86_64'],
      );
      final String? url = await _urlOf(u.selectAsset(_assets(<String>[
        'fushi-0.4.2-armeabi-v7a.apk',
        'fushi-0.4.2-arm64-v8a.apk',
      ])));
      expect(url, 'https://example.com/fushi-0.4.2-armeabi-v7a.apk');
    });

    test('returns null when no apk asset', () async {
      final AndroidUpdater u =
          AndroidUpdater(abiProvider: () async => <String>[]);
      final UpdateAsset? url = await u
          .selectAsset(_assets(<String>['fushi-0.4.2-windows-setup.exe']));
      expect(url, isNull);
    });
  });

  group('UnsupportedUpdater', () {
    test('checks but cannot install; selectAsset always null', () async {
      final UnsupportedUpdater u = UnsupportedUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isFalse);
      expect(await u.selectAsset(_assets(<String>['x.zip'])), isNull);
    });
  });

  group('factory + capability helpers', () {
    test('updaterForCurrentPlatform returns a supported-check updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(u.supportsUpdateCheck, isTrue);
    });

    test('capability helpers agree with the current updater', () {
      final PlatformUpdater u = updaterForCurrentPlatform();
      expect(platformSupportsUpdateCheck(), u.supportsUpdateCheck);
      expect(platformSupportsInAppInstall(), u.supportsInAppInstall);
    });

    test('in-app install capability is android, windows or macos', () {
      // 195fbd320 起 macOS 也支持应用内自更新（MacUpdater）；iOS/Linux 仍只
      // 检查版本后跳转发布页。
      final bool expected =
          Platform.isAndroid || Platform.isWindows || Platform.isMacOS;
      expect(platformSupportsInAppInstall(), expected);
    });
  });

  group('windowsInstallerArgs', () {
    test('runs installer very-silently and skips initial prompt', () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\fushi-0.4.2-windows-setup.exe');
      expect(args, contains('/VERYSILENT'));
      expect(args, contains('/SP-'));
    });

    test('does not ask Inno to close, force-close, or restart applications',
        () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\fushi-0.4.2-windows-setup.exe');

      expect(args, isNot(contains('/CLOSEAPPLICATIONS')));
      expect(args, isNot(contains('/FORCECLOSEAPPLICATIONS')));
      expect(args, isNot(contains('/RESTARTAPPLICATIONS')));
      expect(args, contains('/NOCLOSEAPPLICATIONS'));
      expect(args, contains('/NOFORCECLOSEAPPLICATIONS'));
      expect(args, contains('/NORESTARTAPPLICATIONS'));
      expect(args, contains('/NORESTART'));
    });

    test('suppresses Inno action dialogs and writes one install log', () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\fushi-0.4.2-windows-setup.exe');

      expect(args, contains('/SUPPRESSMSGBOXES'));

      final Iterable<String> logArgs =
          args.where((String arg) => arg.startsWith('/LOG='));
      expect(logArgs, hasLength(1));
      expect(logArgs.single, contains('fushi-0.4.2-windows-setup.install.log'));
    });

    test('pins the installer target to the current executable directory', () {
      final List<String> args = windowsInstallerArgs(
        r'C:\tmp\fushi-0.4.2-windows-setup.exe',
        targetInstallDir: r'D:\Portable\Hibiki',
      );

      expect(args, contains(r'/DIR=D:\Portable\Hibiki'));
    });

    test('builds structured launcher argv without shell command strings', () {
      final List<String> installerArgs = windowsInstallerArgs(
        r'C:\Users\wrds\Downloads\new "folder"&x\hibiki setup.exe',
        logPath: r'C:\Users\wrds\Downloads\logs & notes\install "1".log',
        targetInstallDir: r'D:\APP\Hibiki & Tools',
      );
      final List<String> launcherArgs = windowsUpdateLauncherArgs(
        markerPath: r'C:\Users\wrds\Downloads\marker & one.json',
        parentProcessId: 1234,
        installerPath:
            r'C:\Users\wrds\Downloads\new "folder"&x\hibiki setup.exe',
        installerArgs: installerArgs,
      );

      expect(
        launcherArgs,
        <String>[
          '--marker',
          r'C:\Users\wrds\Downloads\marker & one.json',
          '--parent-pid',
          '1234',
          '--installer',
          r'C:\Users\wrds\Downloads\new "folder"&x\hibiki setup.exe',
          '--',
          ...installerArgs,
        ],
      );
      expect(launcherArgs.join(' '), isNot(contains('powershell')));
      expect(launcherArgs.join(' '), isNot(contains('cmd.exe')));
      expect(launcherArgs.join(' '), isNot(contains('/c ')));
    });

    test('preflights installation directory write access before app exit', () {
      final String source = File(
        'lib/src/utils/misc/platform_updater.dart',
      ).readAsStringSync();

      expect(source, contains('ensureWindowsInstallTargetWritable'));
      expect(source, contains('administrator'));
      expect(source, contains('user-writable'));
    });
  });

  group('Windows installer script guards', () {
    test('does not let Inno auto-close or auto-restart applications', () {
      final String script = File(
        'windows/installer/fushi.iss',
      ).readAsStringSync();

      expect(script, contains('CloseApplications=no'));
      expect(script, contains('RestartApplications=no'));
      expect(script, contains('AppMutex=FushiSingleInstanceMutex'));
      expect(script, contains('CloseApplicationsFilter=*.exe,*.dll'));
      expect(script, contains('fushi_update_launcher.exe'));
    });

    test(
        '[Code] InitializeSetup kills Hibiki and polls the mutex before '
        'Inno does its AppMutex check', () {
      // TODO-549 root-cause layer. Inno runs the [Code] InitializeSetup
      // event BEFORE the built-in AppMutex CheckForMutexes loop (see Inno
      // source Setup.MainFunc.pas), so this is the only layer that can
      // clear the mutex before the "is currently running" abort fires.
      final String script = File(
        'windows/installer/fushi.iss',
      ).readAsStringSync();

      expect(script, contains('[Code]'));
      expect(script, contains('function InitializeSetup(): Boolean'));
      // Probes the single-instance mutex via OpenMutexW (not CreateMutex).
      expect(script, contains('OpenMutexW'));
      expect(script, contains('@kernel32.dll stdcall'));
      expect(script, contains('FushiSingleInstanceMutex'));
      // Terminates hibiki.exe and its WebView2 child tree before the check.
      expect(script, contains('taskkill'));
      expect(script, contains('hibiki.exe'));
      expect(script, contains('msedgewebview2.exe'));
      // Bounded poll until the mutex is actually released (no infinite wait).
      expect(script, contains('MutexReleasePollAttempts'));
      expect(script, contains('Sleep(MutexReleasePollIntervalMs)'));
    });

    test('update launcher is not the Flutter runner and does not take mutex',
        () {
      final String main = File('windows/runner/main.cpp').readAsStringSync();
      final String launcher =
          File('windows/runner/update_launcher.cpp').readAsStringSync();
      final String cmake =
          File('windows/runner/CMakeLists.txt').readAsStringSync();
      final String rootCmake =
          File('windows/CMakeLists.txt').readAsStringSync();

      expect(main, contains('FushiSingleInstanceMutex'));
      expect(main, contains('CreateMutexW'));
      // The launcher never CREATES or holds the single-instance mutex (that is
      // the Flutter runner's job). It MAY probe it read-only via OpenMutexW to
      // wait (bounded) for the mutex to be released after the parent PID exits,
      // closing the "only waited on the parent PID" blind spot (TODO-549).
      expect(launcher, isNot(contains('CreateMutex')));
      expect(launcher, contains('OpenMutexW'));
      expect(launcher, contains('FushiSingleInstanceMutex'));
      expect(launcher, contains('WaitForMutexReleased'));
      expect(cmake, contains('add_executable(fushi_update_launcher WIN32'));
      expect(cmake, contains('"update_launcher.cpp"'));
      expect(
        cmake,
        isNot(contains('fushi_update_launcher WIN32\n  "main.cpp"')),
      );
      expect(
          cmake,
          contains('target_link_libraries(fushi_update_launcher '
              'PRIVATE shell32)'));
      expect(rootCmake, contains('fushi_update_launcher'));
    });

    test(
        'update launcher never abandons the install on an OpenProcess(parent) '
        'failure (TODO-600)', () {
      // Root cause (TODO-600, 551 audit): WaitForParentExit only tolerated
      // ERROR_INVALID_PARAMETER and treated every other OpenProcess failure as
      // fatal (MarkLaunchFailed + return false -> wWinMain return 3), so a
      // recoverable failure (access denied / transient / already-exited)
      // silently abandoned an already-downloaded update. OpenProcess here only
      // provides a wait handle; the launcher is detached and its exit code is
      // unread, so the install must proceed regardless and let the downstream
      // mutex-release poll + AppMutex-guarded installer be the real gate.
      final String launcher =
          File('windows/runner/update_launcher.cpp').readAsStringSync();

      // The failure-classification policy is a named, pure function.
      expect(
        launcher.contains('ParentOpenFailureProvesExit') ||
            launcher.contains('ClassifyParentOpenFailure'),
        isTrue,
      );
      // ERROR_INVALID_PARAMETER remains the one code that PROVES prior exit.
      expect(launcher, contains('ERROR_INVALID_PARAMETER'));

      // WaitForParentExit no longer reports a fatal outcome: it returns void and
      // the call site no longer abandons the install (no `return 3`). The only
      // genuinely fatal path left is CreateProcess Inno failing to start.
      expect(launcher, contains('void WaitForParentExit'));
      expect(launcher, isNot(contains('return 3;')));
      expect(launcher, isNot(contains('if (!WaitForParentExit')));

      // MarkLaunchFailed is no longer wired into the parent-wait path; it stays
      // only for the real fatal failure (the installer refusing to spawn).
      expect(
        launcher,
        contains('MarkLaunchFailed(args.marker_path, '
            'LastErrorMessage("CreateProcess Inno"))'),
      );
      expect(
        launcher,
        isNot(contains('MarkLaunchFailed(args.marker_path, '
            'LastErrorMessage("OpenProcess parent"))')),
      );

      // Non-fatal failures are recorded as diagnostics, not as a launch failure.
      expect(launcher, contains('parentOpenFailed'));
      expect(launcher, contains('parentExitTimedOut'));
    });
  });

  group('isWindowsExecutableHeader', () {
    test('accepts a PE/MZ header', () {
      // Real Windows executables start with the DOS "MZ" magic (0x4D 0x5A).
      expect(isWindowsExecutableHeader(<int>[0x4D, 0x5A, 0x90, 0x00]), isTrue);
    });

    test('rejects an HTML page (proxy error served with HTTP 200)', () {
      // The app falls back to GitHub proxies (ghfast.top / ghproxy) under the
      // GFW; those can answer 200 with an HTML notice that gets written to the
      // .exe. Such bytes must never be treated as a runnable installer.
      final List<int> html = '<!DOCTYPE html><html>'.codeUnits;
      expect(isWindowsExecutableHeader(html), isFalse);
    });

    test('rejects an empty / truncated download', () {
      expect(isWindowsExecutableHeader(<int>[]), isFalse);
      expect(isWindowsExecutableHeader(<int>[0x4D]), isFalse);
    });
  });

  group('WindowsInstaller.runAndExit validation', () {
    test('throws instead of launching when the file is not an executable',
        () async {
      // Regression for "Windows auto-update crash": a corrupt / proxy-HTML
      // download must surface an error (caught upstream -> SnackBar) rather
      // than being fed to Process.start (and then exit(0) vanishing the app).
      final Directory tmp =
          await Directory.systemTemp.createTemp('hibiki-update-test');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final File bogus = File('${tmp.path}/fushi-0.4.2-windows-setup.exe');
      await bogus.writeAsString('<html>rate limited</html>');

      await expectLater(
        WindowsInstaller.runAndExit(bogus.path),
        throwsA(isA<UpdateInstallerException>()),
      );
      // The corrupt download is cleaned up so it can't be re-run later, and
      // crucially the process is still alive here -- exit(0) was NOT reached
      // (otherwise this assertion would never run).
      expect(bogus.existsSync(), isFalse);
    });

    test('throws when the installer file is missing', () async {
      await expectLater(
        WindowsInstaller.runAndExit('Z:/nope/does-not-exist-installer.exe'),
        throwsA(isA<UpdateInstallerException>()),
      );
    });

    test('never collects diagnostics for a download that fails validation',
        () async {
      // BUG-1179: diagnostics shell out to `reg`, `powershell Get-CimInstance`
      // and `tasklist /M libmpv-2.dll` (a whole-machine module enumeration that
      // costs seconds). Running that BEFORE the exists/MZ-header checks made
      // real users wait ~10s just to be told the download was corrupt, and made
      // the two tests above race the 30s default test timeout on a busy box.
      // Validation must come first, so diagnostics are never collected at all.
      final Directory tmp =
          await Directory.systemTemp.createTemp('hibiki-update-nodiag');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final File bogus = File('${tmp.path}/fushi-0.4.2-windows-setup.exe');
      await bogus.writeAsString('<html>rate limited</html>');

      var diagnosticsCalls = 0;
      Future<WindowsInstallerDiagnostics> collect() async {
        diagnosticsCalls++;
        return const WindowsInstallerDiagnostics();
      }

      await expectLater(
        WindowsInstaller.runAndExit(bogus.path, collectDiagnostics: collect),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(diagnosticsCalls, 0,
          reason: 'a corrupt download must be rejected before any '
              'whole-machine process enumeration');

      await expectLater(
        WindowsInstaller.runAndExit(
          'Z:/nope/does-not-exist-installer.exe',
          collectDiagnostics: collect,
        ),
        throwsA(isA<UpdateInstallerException>()),
      );
      expect(diagnosticsCalls, 0);
    });
  });

  group('Windows installer diagnostics parsers', () {
    test('parses Inno DeleteFile code 5 failures from installer logs', () {
      final List<WindowsInnoDeleteFileFailure> failures =
          parseWindowsInnoDeleteFileFailures(
        [
          r'2026-06-18 10:00:00.000   DeleteFile failed; code 5.',
          r'2026-06-18 10:00:00.001   C:\Program Files\Hibiki\libmpv-2.dll',
        ].join('\n'),
      );

      expect(failures, hasLength(1));
      expect(failures.single.code, 5);
      expect(failures.single.path, r'C:\Program Files\Hibiki\libmpv-2.dll');
    });

    // 原用例还断言了 `tasklist /M` 的 CSV 解析。占用者查询已改走 Restart Manager
    // （直接问系统「谁持有目标目录里那个 libmpv-2.dll」，不再扫全机模块表，见
    // `windows_process_query.dart`），那个解析器随之删除，用例也不再有对象。
    // 但同一个用例里搭着的**不变式**依然要守：更新器只观察占用者，永不杀进程。
    test('更新器只观察占用者，永不终结任何进程', () {
      final String source =
          File('lib/src/utils/misc/platform_updater.dart').readAsStringSync();
      expect(source, isNot(contains('kill')));
      expect(source, isNot(contains('taskkill')));
      expect(source, isNot(contains('TerminateProcess')));
      // 占用者查询本身也不得越权：RM 只做只读查询，不注册 restart/shutdown。
      final String query =
          File('lib/src/platform/desktop/windows_process_query.dart')
              .readAsStringSync();
      expect(query, isNot(contains('RmShutdown')));
      expect(query, isNot(contains('RmRestart')));
      expect(query, isNot(contains('TerminateProcess')));
    });
  });

  group('MacUpdater.selectAsset', () {
    test('picks the -macos.zip asset (stable)', () async {
      final MacUpdater u = MacUpdater();
      final String? url = await _urlOf(u.selectAsset(_assets(<String>[
        'fushi-0.4.2-arm64-v8a.apk',
        'fushi-0.4.2-windows-setup.exe',
        'fushi-0.4.2-macos.zip',
        'fushi-0.4.2-ios.ipa',
      ])));
      expect(url, 'https://example.com/fushi-0.4.2-macos.zip');
    });

    test('returns null when no macOS asset present', () async {
      final MacUpdater u = MacUpdater();
      final UpdateAsset? asset = await u.selectAsset(_assets(<String>[
        'fushi-0.4.2-arm64-v8a.apk',
        'fushi-0.4.2-windows-setup.exe',
      ]));
      expect(asset, isNull);
    });

    test('debug channel selects the debug macOS zip', () async {
      final MacUpdater u = MacUpdater();
      final String? url = await _urlOf(u.selectAsset(
        _assets(<String>[
          'fushi-0.5.1-macos.zip',
          'fushi-0.5.1-debug.412-macos.zip',
        ]),
        channel: UpdateChannel.debug,
      ));
      expect(url, 'https://example.com/fushi-0.5.1-debug.412-macos.zip');
    });

    test('stable channel ignores the debug macOS zip', () async {
      final MacUpdater u = MacUpdater();
      final String? url = await _urlOf(u.selectAsset(
        _assets(<String>[
          'fushi-0.5.1-debug.412-macos.zip',
          'fushi-0.5.1-macos.zip',
        ]),
      ));
      expect(url, 'https://example.com/fushi-0.5.1-macos.zip');
    });

    test('macOS updater advertises in-app install support', () {
      final MacUpdater u = MacUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isTrue);
    });
  });

  group('IosUpdater', () {
    test('never selects an asset (info-only, opens release page)', () async {
      final IosUpdater u = IosUpdater();
      final UpdateAsset? asset = await u.selectAsset(_assets(<String>[
        'fushi-0.4.2-ios.ipa',
        'fushi-0.4.2-macos.zip',
      ]));
      expect(asset, isNull);
    });

    test('checks updates but cannot install in-app', () {
      final IosUpdater u = IosUpdater();
      expect(u.supportsUpdateCheck, isTrue);
      expect(u.supportsInAppInstall, isFalse);
    });

    test('apply must not be called on iOS', () {
      final IosUpdater u = IosUpdater();
      expect(u.apply(File('x'), '1.0.0'), throwsA(isA<StateError>()));
    });
  });

  group('platform capability helpers include macOS in-app install', () {
    test('synthesizeStableAssetNames lists the macOS zip', () {
      final List<String> names = synthesizeStableAssetNames('0.4.2');
      // macOS/Windows 均已切 fushi（Windows 更新桥已落，Phase 5）；Android APK 保持旧名。
      expect(names, contains('fushi-0.4.2-macos.zip'));
      expect(names, contains('fushi-0.4.2-windows-setup.exe'));
    });
  });

  group('macAppBundlePathForExecutable', () {
    test('resolves the .app bundle from a Contents/MacOS executable', () {
      expect(
        macAppBundlePathForExecutable(
          '/Applications/fushi.app/Contents/MacOS/fushi',
        ),
        '/Applications/fushi.app',
      );
    });

    test('handles a nested user path', () {
      expect(
        macAppBundlePathForExecutable(
          '/Users/me/Applications/fushi.app/Contents/MacOS/fushi',
        ),
        '/Users/me/Applications/fushi.app',
      );
    });

    test('returns null when no .app segment is present', () {
      expect(macAppBundlePathForExecutable('/usr/local/bin/hibiki'), isNull);
    });
  });

  group('isZipHeader', () {
    test('accepts the PK zip magic', () {
      expect(isZipHeader(<int>[0x50, 0x4B, 0x03, 0x04]), isTrue);
    });

    test('rejects HTML/other bytes (proxy limit pages)', () {
      expect(isZipHeader(<int>[0x3C, 0x21, 0x44, 0x4F]), isFalse); // <!DO
      expect(isZipHeader(<int>[0x50]), isFalse);
      expect(isZipHeader(<int>[]), isFalse);
    });
  });

  group('buildMacSwapScript', () {
    String script() => buildMacSwapScript(
          parentPid: 4321,
          newAppPath: '/tmp/updates/mac-update-1.2.0.extracted/hibiki.app',
          targetAppPath: '/Applications/fushi.app',
          backupPath: '/tmp/updates/mac-update-1.2.0.backup',
          extractDir: '/tmp/updates/mac-update-1.2.0.extracted',
          resultPath: '/tmp/updates/mac-update-result.json',
          logPath: '/tmp/updates/mac-update-1.2.0.log',
        );

    test('waits for the parent pid via a non-terminating ps probe', () {
      final String s = script();
      expect(s, contains('PARENT_PID=4321'));
      expect(s, contains(r'ps -p "$PARENT_PID"'));
      // Never terminates any process (mirrors the Windows HBK-AUDIT invariant).
      expect(s, isNot(contains('kill')));
    });

    test('moves the old bundle aside before copying (reversible swap)', () {
      final String s = script();
      final int moveAside = s.indexOf(r'mv "$TARGET_APP" "$BACKUP"');
      final int ditto = s.indexOf(r'/usr/bin/ditto "$NEW_APP" "$TARGET_APP"');
      expect(moveAside, isNonNegative);
      expect(ditto, isNonNegative);
      expect(moveAside, lessThan(ditto), reason: '必须先把旧包移到备份再拷新包，失败可回滚，绝不留坏档');
    });

    test('restores the previous bundle when the copy fails', () {
      final String s = script();
      expect(s, contains(r'mv "$BACKUP" "$TARGET_APP"'));
      expect(s, contains('restored previous version'));
    });

    test('clears quarantine and relaunches on success', () {
      final String s = script();
      expect(s, contains('xattr -dr com.apple.quarantine'));
      expect(s, contains(r'open "$TARGET_APP"'));
      expect(s, contains('write_result installed'));
    });

    test('single-quotes paths so spaces do not split arguments', () {
      final String withSpace = buildMacSwapScript(
        parentPid: 1,
        newAppPath: '/tmp/a b/new.app',
        targetAppPath: '/Applications/My App.app',
        backupPath: '/tmp/a b/bak',
        extractDir: '/tmp/a b',
        resultPath: '/tmp/a b/r.json',
        logPath: '/tmp/a b/l.log',
      );
      expect(withSpace, contains("TARGET_APP='/Applications/My App.app'"));
    });
  });
}
