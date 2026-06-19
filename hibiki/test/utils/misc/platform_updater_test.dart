import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';

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
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
        'hibiki-0.4.2-linux-x86_64.AppImage',
      ])));
      expect(url, 'https://example.com/hibiki-0.4.2-windows-setup.exe');
    });

    test('returns null when no windows asset present', () async {
      final WindowsUpdater u = WindowsUpdater();
      final UpdateAsset? url =
          await u.selectAsset(_assets(<String>['hibiki-0.4.2-arm64-v8a.apk']));
      expect(url, isNull);
    });

    test('debug channel selects a debug Windows setup asset', () async {
      final WindowsUpdater u = WindowsUpdater();
      final String? url = await _urlOf(u.selectAsset(
        _assets(<String>[
          'hibiki-0.5.1-windows-setup.exe',
          'hibiki-0.5.1-debug.412-windows-setup.exe',
        ]),
        channel: UpdateChannel.debug,
      ));
      expect(
        url,
        'https://example.com/hibiki-0.5.1-debug.412-windows-setup.exe',
      );
    });

    test('preserves release asset size and digest metadata', () async {
      final WindowsUpdater u = WindowsUpdater();
      const String digest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final UpdateAsset? asset = await u.selectAsset(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'hibiki-0.4.2-windows-setup.exe',
          'browser_download_url':
              'https://example.com/hibiki-0.4.2-windows-setup.exe',
          'size': 12345,
          'digest': 'sha256:$digest',
        },
      ]);

      expect(asset?.url, 'https://example.com/hibiki-0.4.2-windows-setup.exe');
      expect(asset?.sizeBytes, 12345);
      expect(asset?.sha256Digest, digest);
    });

    test('stable and beta ignore debug Windows setup assets', () async {
      final WindowsUpdater u = WindowsUpdater();
      final List<Map<String, dynamic>> assets = _assets(<String>[
        'hibiki-0.5.1-debug.412-windows-setup.exe',
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
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
        'hibiki-0.4.2-windows-setup.exe',
      ])));
      expect(url, 'https://example.com/hibiki-0.4.2-arm64-v8a.apk');
    });

    test('stable and beta ignore debug APK assets', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );
      final List<Map<String, dynamic>> assets = _assets(<String>[
        'hibiki-0.5.1-debug.412-abc1234-debug.apk',
        'hibiki-0.5.1-arm64-v8a.apk',
      ]);

      expect(
        await _urlOf(u.selectAsset(assets, channel: UpdateChannel.stable)),
        'https://example.com/hibiki-0.5.1-arm64-v8a.apk',
      );
      expect(
        await _urlOf(u.selectAsset(assets, channel: UpdateChannel.beta)),
        'https://example.com/hibiki-0.5.1-arm64-v8a.apk',
      );
    });

    test('debug channel only selects debug APK assets', () async {
      final AndroidUpdater u = AndroidUpdater(
        abiProvider: () async => <String>['arm64-v8a'],
      );

      expect(
        await _urlOf(u.selectAsset(
          _assets(<String>[
            'hibiki-0.5.1-arm64-v8a.apk',
            'hibiki-0.5.1-debug.412-abc1234-debug.apk',
          ]),
          channel: UpdateChannel.debug,
        )),
        'https://example.com/hibiki-0.5.1-debug.412-abc1234-debug.apk',
      );
      expect(
        await u.selectAsset(
          _assets(<String>['hibiki-0.5.1-arm64-v8a.apk']),
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
        'hibiki-0.4.2-armeabi-v7a.apk',
        'hibiki-0.4.2-arm64-v8a.apk',
      ])));
      expect(url, 'https://example.com/hibiki-0.4.2-armeabi-v7a.apk');
    });

    test('returns null when no apk asset', () async {
      final AndroidUpdater u =
          AndroidUpdater(abiProvider: () async => <String>[]);
      final UpdateAsset? url = await u
          .selectAsset(_assets(<String>['hibiki-0.4.2-windows-setup.exe']));
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

    test('in-app install capability is android or windows in phase 1', () {
      final bool expected = Platform.isAndroid || Platform.isWindows;
      expect(platformSupportsInAppInstall(), expected);
    });
  });

  group('windowsInstallerArgs', () {
    test('runs installer very-silently and skips initial prompt', () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');
      expect(args, contains('/VERYSILENT'));
      expect(args, contains('/SP-'));
    });

    test('does not ask Inno to close, force-close, or restart applications',
        () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');

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
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');

      expect(args, contains('/SUPPRESSMSGBOXES'));

      final Iterable<String> logArgs =
          args.where((String arg) => arg.startsWith('/LOG='));
      expect(logArgs, hasLength(1));
      expect(
          logArgs.single, contains('hibiki-0.4.2-windows-setup.install.log'));
    });

    test('pins the installer target to the current executable directory', () {
      final List<String> args = windowsInstallerArgs(
        r'C:\tmp\hibiki-0.4.2-windows-setup.exe',
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
        'windows/installer/hibiki.iss',
      ).readAsStringSync();

      expect(script, contains('CloseApplications=no'));
      expect(script, contains('RestartApplications=no'));
      expect(script, contains('AppMutex=HibikiSingleInstanceMutex'));
      expect(script, contains('CloseApplicationsFilter=*.exe,*.dll'));
      expect(script, contains('hibiki_update_launcher.exe'));
    });

    test(
        '[Code] InitializeSetup kills Hibiki and polls the mutex before '
        'Inno does its AppMutex check', () {
      // TODO-549 root-cause layer. Inno runs the [Code] InitializeSetup
      // event BEFORE the built-in AppMutex CheckForMutexes loop (see Inno
      // source Setup.MainFunc.pas), so this is the only layer that can
      // clear the mutex before the "is currently running" abort fires.
      final String script = File(
        'windows/installer/hibiki.iss',
      ).readAsStringSync();

      expect(script, contains('[Code]'));
      expect(script, contains('function InitializeSetup(): Boolean'));
      // Probes the single-instance mutex via OpenMutexW (not CreateMutex).
      expect(script, contains('OpenMutexW'));
      expect(script, contains('@kernel32.dll stdcall'));
      expect(script, contains('HibikiSingleInstanceMutex'));
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

      expect(main, contains('HibikiSingleInstanceMutex'));
      expect(main, contains('CreateMutexW'));
      // The launcher never CREATES or holds the single-instance mutex (that is
      // the Flutter runner's job). It MAY probe it read-only via OpenMutexW to
      // wait (bounded) for the mutex to be released after the parent PID exits,
      // closing the "only waited on the parent PID" blind spot (TODO-549).
      expect(launcher, isNot(contains('CreateMutex')));
      expect(launcher, contains('OpenMutexW'));
      expect(launcher, contains('HibikiSingleInstanceMutex'));
      expect(launcher, contains('WaitForMutexReleased'));
      expect(cmake, contains('add_executable(hibiki_update_launcher WIN32'));
      expect(cmake, contains('"update_launcher.cpp"'));
      expect(
        cmake,
        isNot(contains('hibiki_update_launcher WIN32\n  "main.cpp"')),
      );
      expect(
          cmake,
          contains('target_link_libraries(hibiki_update_launcher '
              'PRIVATE shell32)'));
      expect(rootCmake, contains('hibiki_update_launcher'));
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
      final File bogus = File('${tmp.path}/hibiki-0.4.2-windows-setup.exe');
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

    test('parses tasklist module holders without terminating them', () {
      final List<WindowsProcessInfo> holders =
          parseWindowsTasklistModuleHolders(
        [
          '"hibiki.exe","4321","Console","1","120,000 K"',
          '"mpv-helper.exe","8765","Console","1","80,000 K"',
        ].join('\n'),
      );

      expect(holders.map((WindowsProcessInfo p) => p.pid), <int>[4321, 8765]);
      final String source =
          File('lib/src/utils/misc/platform_updater.dart').readAsStringSync();
      expect(source, isNot(contains('kill')));
      expect(source, isNot(contains('taskkill')));
      expect(source, isNot(contains('TerminateProcess')));
    });
  });
}
