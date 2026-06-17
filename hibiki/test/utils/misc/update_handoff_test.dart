import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_handoff.dart';

Future<File> _markerFile() async {
  final Directory dir =
      await Directory.systemTemp.createTemp('hibiki-update-handoff-test');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return WindowsUpdateHandoff.markerFile(dir);
}

void main() {
  group('WindowsUpdateHandoff marker', () {
    test('writes the target version, installer, Inno log, and launch result',
        () async {
      final File marker = await _markerFile();
      final DateTime startedAt = DateTime.utc(2026, 6, 17, 10, 30);

      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.2.3',
        installerPath: r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-1.2.3.install.log',
        startedAt: startedAt,
      );
      await WindowsUpdateHandoff.markLaunchSucceeded(
        markerFile: marker,
        launchedAt: startedAt.add(const Duration(seconds: 1)),
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record, isNotNull);
      expect(record!.targetVersion, '1.2.3');
      expect(record.installerPath, r'C:\tmp\hibiki-1.2.3-windows-setup.exe');
      expect(record.innoLogPath, r'C:\tmp\hibiki-1.2.3.install.log');
      expect(record.startedAt, startedAt);
      expect(record.installerLaunchSucceeded, isTrue);
      expect(record.installerLaunchedAt,
          startedAt.add(const Duration(seconds: 1)));
    });

    test('installer args use the exact log path persisted in the marker', () {
      final List<String> args = windowsInstallerArgs(
        r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        logPath: r'C:\logs\hibiki-update.install.log',
      );

      expect(args, contains(r'/LOG=C:\logs\hibiki-update.install.log'));
      expect(args.where((String arg) => arg.startsWith('/LOG=')), hasLength(1));
    });
  });

  group('WindowsUpdateHandoff reconcile', () {
    test('reports success and clears the marker when current version reached',
        () async {
      final File marker = await _markerFile();
      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.2.3',
        installerPath: r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-1.2.3.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 10, 30),
      );
      await WindowsUpdateHandoff.markLaunchSucceeded(
        markerFile: marker,
        launchedAt: DateTime.utc(2026, 6, 17, 10, 31),
      );

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.3',
        now: DateTime.utc(2026, 6, 17, 10, 32),
      );

      expect(result?.status, WindowsUpdateHandoffStatus.installed);
      expect(result?.record.targetVersion, '1.2.3');
      expect(await marker.exists(), isFalse);
    });

    test('reports an incomplete install once and keeps the log marker',
        () async {
      final File marker = await _markerFile();
      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.2.3',
        installerPath: r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-1.2.3.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 10, 30),
      );
      await WindowsUpdateHandoff.markLaunchSucceeded(
        markerFile: marker,
        launchedAt: DateTime.utc(2026, 6, 17, 10, 31),
      );

      final WindowsUpdateHandoffResult? first =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.2',
        now: DateTime.utc(2026, 6, 17, 10, 32),
      );
      final WindowsUpdateHandoffResult? second =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.2',
        now: DateTime.utc(2026, 6, 17, 10, 33),
      );
      final WindowsUpdateHandoffRecord? retained =
          await WindowsUpdateHandoff.read(marker);

      expect(first?.status, WindowsUpdateHandoffStatus.incomplete);
      expect(first?.record.innoLogPath, r'C:\tmp\hibiki-1.2.3.install.log');
      expect(second, isNull, reason: 'do not pop on every startup');
      expect(retained, isNotNull);
      expect(retained!.lastPromptedAppVersion, '1.2.2');
    });

    test('reports launch failure once and keeps the marker for diagnostics',
        () async {
      final File marker = await _markerFile();
      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.2.3',
        installerPath: r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-1.2.3.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 10, 30),
      );
      await WindowsUpdateHandoff.markLaunchFailed(
        markerFile: marker,
        error: 'access denied',
        failedAt: DateTime.utc(2026, 6, 17, 10, 31),
      );

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.2',
        now: DateTime.utc(2026, 6, 17, 10, 32),
      );

      expect(result?.status, WindowsUpdateHandoffStatus.launchFailed);
      expect(result?.record.launchError, contains('access denied'));
      expect(await marker.exists(), isTrue);
    });
  });

  group('WindowsInstaller.runAndExit handoff', () {
    test('writes marker, starts with marker log path, then exits', () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File installer = File(
          '${dir.path}${Platform.pathSeparator}hibiki-1.2.3-windows-setup.exe');
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);

      List<String>? startedArgs;
      int? exitCode;
      await WindowsInstaller.runAndExit(
        installer.path,
        targetVersion: '1.2.3',
        handoffMarkerFile: marker,
        now: () => DateTime.utc(2026, 6, 17, 10, 30),
        startProcess: (String executable, List<String> args) async {
          startedArgs = args;
        },
        exitProcess: (int code) {
          exitCode = code;
        },
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record?.installerLaunchSucceeded, isTrue);
      expect(record?.targetVersion, '1.2.3');
      expect(startedArgs, contains('/LOG=${record!.innoLogPath}'));
      expect(exitCode, 0);
    });

    test('records launch failure before surfacing the installer exception',
        () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File installer = File(
          '${dir.path}${Platform.pathSeparator}hibiki-1.2.3-windows-setup.exe');
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);

      await expectLater(
        WindowsInstaller.runAndExit(
          installer.path,
          targetVersion: '1.2.3',
          handoffMarkerFile: marker,
          startProcess: (String executable, List<String> args) async {
            throw const ProcessException('setup.exe', <String>[], 'boom');
          },
          exitProcess: (_) {},
        ),
        throwsA(isA<UpdateInstallerException>()),
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record?.installerLaunchSucceeded, isFalse);
      expect(record?.launchError, contains('boom'));
    });
  });

  group('startup reconcile guard', () {
    test('main triggers the Windows update handoff reconcile once after init',
        () {
      final String source = File('lib/main.dart').readAsStringSync();

      expect(source, contains('_windowsUpdateHandoffChecked'));
      expect(
        source,
        contains('UpdateChecker.reconcilePendingWindowsInstallerHandoff'),
      );
      expect(
        source,
        contains('WidgetsBinding.instance.addPostFrameCallback'),
      );
    });
  });
}
