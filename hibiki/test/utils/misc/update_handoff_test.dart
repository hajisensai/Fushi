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
    test(
        'writes the target version, installer, Inno log, launch result, '
        'and post-launch observation', () async {
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
        installerPid: 4242,
        launchedAt: startedAt.add(const Duration(seconds: 1)),
      );
      await WindowsUpdateHandoff.markPostLaunchObserved(
        markerFile: marker,
        observedAt: startedAt.add(const Duration(seconds: 2)),
        installerProcessRunning: false,
        innoLogExists: false,
        innoLogSizeBytes: null,
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
      expect(record.installerPid, 4242);
      expect(record.postLaunchObservedAt,
          startedAt.add(const Duration(seconds: 2)));
      expect(record.installerProcessRunning, isFalse);
      expect(record.innoLogExists, isFalse);
      expect(record.innoLogSizeBytes, isNull);
    });

    test('installer args use the exact log path persisted in the marker', () {
      final List<String> args = windowsInstallerArgs(
        r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        logPath: r'C:\logs\hibiki-update.install.log',
      );

      expect(args, contains(r'/LOG=C:\logs\hibiki-update.install.log'));
      expect(args.where((String arg) => arg.startsWith('/LOG=')), hasLength(1));
    });

    test('preserves Windows install diagnostics in marker JSON', () {
      final WindowsUpdateHandoffRecord record =
          WindowsUpdateHandoffRecord.fromJson(<String, dynamic>{
        'targetVersion': '1.2.3',
        'installerPath': r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        'innoLogPath': r'C:\tmp\hibiki-1.2.3.install.log',
        'startedAt': '2026-06-17T10:30:00Z',
        'currentExecutablePath': r'D:\Portable\Hibiki\hibiki.exe',
        'currentInstallDir': r'D:\Portable\Hibiki',
        'targetInstallDir': r'D:\Portable\Hibiki',
        'detectedInstallLocations': <Map<String, dynamic>>[
          <String, dynamic>{
            'source': 'registered',
            'path': r'D:\Program\Hibiki',
          },
          <String, dynamic>{
            'source': 'current',
            'path': r'D:\Portable\Hibiki',
          },
        ],
        'pathMismatchWarning':
            r'Registered install location D:\Program\Hibiki differs from current D:\Portable\Hibiki.',
        'runningHibikiProcesses': <Map<String, dynamic>>[
          <String, dynamic>{
            'pid': 4321,
            'path': r'D:\Portable\Hibiki\hibiki.exe',
          },
        ],
        'libmpvModuleHolders': <Map<String, dynamic>>[
          <String, dynamic>{
            'pid': 4321,
            'path': r'D:\Portable\Hibiki\hibiki.exe',
          },
        ],
        'innoLogDeleteFileFailures': <Map<String, dynamic>>[
          <String, dynamic>{
            'path': r'D:\Portable\Hibiki\libmpv-2.dll',
            'code': 5,
          },
        ],
      });

      final Map<String, dynamic> json = record.toJson();
      expect(json['currentExecutablePath'], r'D:\Portable\Hibiki\hibiki.exe');
      expect(json['currentInstallDir'], r'D:\Portable\Hibiki');
      expect(json['targetInstallDir'], r'D:\Portable\Hibiki');
      expect(json['detectedInstallLocations'], isA<List<dynamic>>());
      expect(json['pathMismatchWarning'], contains(r'D:\Program\Hibiki'));
      expect(json['runningHibikiProcesses'], isA<List<dynamic>>());
      expect(json['libmpvModuleHolders'], isA<List<dynamic>>());
      expect(json['innoLogDeleteFileFailures'], isA<List<dynamic>>());
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
        installerPid: 4242,
        launchedAt: DateTime.utc(2026, 6, 17, 10, 31),
      );
      await WindowsUpdateHandoff.markPostLaunchObserved(
        markerFile: marker,
        observedAt: DateTime.utc(2026, 6, 17, 10, 31, 1),
        installerProcessRunning: false,
        innoLogExists: false,
        innoLogSizeBytes: null,
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
        installerPid: 4242,
        launchedAt: DateTime.utc(2026, 6, 17, 10, 31),
      );
      await WindowsUpdateHandoff.markPostLaunchObserved(
        markerFile: marker,
        observedAt: DateTime.utc(2026, 6, 17, 10, 31, 1),
        installerProcessRunning: false,
        innoLogExists: false,
        innoLogSizeBytes: null,
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
      expect(first?.record.installerPid, 4242);
      expect(first?.record.installerProcessRunning, isFalse);
      expect(first?.record.innoLogExists, isFalse);
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
        collectDiagnostics: () async => WindowsInstallerDiagnostics(
          currentExecutablePath:
              '${dir.path}${Platform.pathSeparator}hibiki.exe',
          currentInstallDir: dir.path,
          targetInstallDir: dir.path,
        ),
        startProcess: (String executable, List<String> args) async {
          startedArgs = args;
          return const WindowsInstallerStartedProcess(pid: 4242);
        },
        observePostLaunch: (int? installerPid, String innoLogPath) async {
          expect(installerPid, 4242);
          return WindowsInstallerPostLaunchObservation(
            observedAt: DateTime.utc(2026, 6, 17, 10, 30, 2),
            installerProcessRunning: false,
            innoLogExists: false,
            innoLogSizeBytes: null,
          );
        },
        exitProcess: (int code) {
          exitCode = code;
        },
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record?.installerLaunchSucceeded, isTrue);
      expect(record?.targetVersion, '1.2.3');
      expect(record?.installerPid, 4242);
      expect(
          record?.postLaunchObservedAt, DateTime.utc(2026, 6, 17, 10, 30, 2));
      expect(record?.installerProcessRunning, isFalse);
      expect(record?.innoLogExists, isFalse);
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
          collectDiagnostics: () async => WindowsInstallerDiagnostics(
            currentExecutablePath:
                '${dir.path}${Platform.pathSeparator}hibiki.exe',
            currentInstallDir: dir.path,
            targetInstallDir: dir.path,
          ),
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

    test('records holders and does not launch when target libmpv is held',
        () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File installer = File(
          '${dir.path}${Platform.pathSeparator}hibiki-1.2.3-windows-setup.exe');
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);

      var startCalled = false;
      await expectLater(
        WindowsInstaller.runAndExit(
          installer.path,
          targetVersion: '1.2.3',
          handoffMarkerFile: marker,
          collectDiagnostics: () async => WindowsInstallerDiagnostics(
            currentExecutablePath:
                '${dir.path}${Platform.pathSeparator}hibiki.exe',
            currentInstallDir: dir.path,
            targetInstallDir: dir.path,
            runningHibikiProcesses: <WindowsProcessInfo>[
              WindowsProcessInfo(
                pid: 5678,
                path: '${dir.path}${Platform.pathSeparator}hibiki.exe',
              ),
            ],
            libmpvModuleHolders: <WindowsProcessInfo>[
              WindowsProcessInfo(
                pid: 5678,
                path: '${dir.path}${Platform.pathSeparator}hibiki.exe',
              ),
            ],
          ),
          startProcess: (String executable, List<String> args) async {
            startCalled = true;
            return const WindowsInstallerStartedProcess(pid: 4242);
          },
          exitProcess: (_) {},
        ),
        throwsA(isA<UpdateInstallerException>()),
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(startCalled, isFalse);
      expect(record?.installerLaunchSucceeded, isFalse);
      expect(record?.runningHibikiProcesses.single.pid, 5678);
      expect(record?.libmpvModuleHolders.single.pid, 5678);
      expect(
          record?.launchError, contains('Close the listed process manually'));
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
