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

    test('silently closes and auto-restarts the app without a confirm dialog',
        () {
      // TODO-431: a bare /VERYSILENT still pops the "application is running,
      // close it?" dialog because the .iss sets CloseApplications=yes. Passing
      // /CLOSEAPPLICATIONS lets RestartManager close Hibiki silently, and
      // /RESTARTAPPLICATIONS relaunches it once the install finishes; /NORESTART
      // makes sure only the app (not the OS) is restarted.
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');
      expect(args, contains('/CLOSEAPPLICATIONS'));
      expect(args, contains('/RESTARTAPPLICATIONS'));
      expect(args, contains('/NORESTART'));
    });

    test('suppresses Inno action dialogs and records close diagnostics', () {
      final List<String> args =
          windowsInstallerArgs(r'C:\tmp\hibiki-0.4.2-windows-setup.exe');

      expect(args, contains('/SUPPRESSMSGBOXES'));
      expect(args, contains('/FORCECLOSEAPPLICATIONS'));
      expect(args, contains('/LOGCLOSEAPPLICATIONS'));

      final Iterable<String> logArgs =
          args.where((String arg) => arg.startsWith('/LOG='));
      expect(logArgs, hasLength(1));
      expect(
          logArgs.single, contains('hibiki-0.4.2-windows-setup.install.log'));
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
    test('keeps Restart Manager coverage for exe and dll locks', () {
      final String script = File(
        'windows/installer/hibiki.iss',
      ).readAsStringSync();

      expect(script, contains('CloseApplications=yes'));
      expect(script, contains('RestartApplications=yes'));
      expect(script, contains('AppMutex=HibikiSingleInstanceMutex'));
      expect(script, contains('CloseApplicationsFilter=*.exe,*.dll'));
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
}
