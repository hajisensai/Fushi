import 'dart:convert';
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
        installerPid: 4242,
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
      expect(record.installerPid, 4242);
    });

    test(
        'writePending starts a fresh marker so a previous launch attempt '
        'does not leak into the next', () async {
      final File marker = await _markerFile();

      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.0.0',
        installerPath: r'C:\tmp\hibiki-1.0.0-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-1.0.0.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 10, 0),
      );
      await WindowsUpdateHandoff.markLauncherStarted(
        markerFile: marker,
        startedAt: DateTime.utc(2026, 6, 17, 10, 0, 1),
        parentProcessId: 1111,
        launcherPid: 2222,
      );
      await WindowsUpdateHandoff.markParentExitObserved(
        markerFile: marker,
        observedAt: DateTime.utc(2026, 6, 17, 10, 0, 2),
        observed: true,
      );
      await WindowsUpdateHandoff.markLaunchSucceeded(
        markerFile: marker,
        installerPid: 3333,
        launchedAt: DateTime.utc(2026, 6, 17, 10, 0, 3),
      );

      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '2.0.0',
        installerPath: r'C:\tmp\hibiki-2.0.0-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-2.0.0.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 11, 0),
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record!.targetVersion, '2.0.0');
      expect(record.launcherPid, isNull);
      expect(record.parentProcessId, isNull);
      expect(record.parentExitObserved, isNull);
      expect(record.installerPid, isNull);
      expect(record.installerLaunchSucceeded, isNull);
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

    test('a successful reconcile records the prompted app version', () async {
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

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.3',
        now: DateTime.utc(2026, 6, 17, 10, 32),
      );

      expect(result?.status, WindowsUpdateHandoffStatus.installed);
      expect(result?.record.lastPromptedAppVersion, '1.2.3');
    });

    test(
        'does not pop the success dialog on every startup when the marker '
        'survives (delete failed last time)', () async {
      // Reproduces TODO-1035 / BUG-483: on real machines the updates dir marker
      // can fail to delete (antivirus/indexer lock, permission error) and that
      // failure is swallowed. The marker then persists with lastPromptedAppVersion
      // already set to the current version, and reconcile must stay silent.
      final File marker = await _markerFile();
      final WindowsUpdateHandoffRecord persisted =
          WindowsUpdateHandoffRecord.fromJson(<String, dynamic>{
        'targetVersion': '1.2.3',
        'installerPath': r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        'innoLogPath': r'C:\tmp\hibiki-1.2.3.install.log',
        'startedAt': '2026-06-17T10:30:00Z',
        'installerLaunchSucceeded': true,
        'lastPromptedAppVersion': '1.2.3',
      });
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        const JsonEncoder.withIndent('  ').convert(persisted.toJson()),
        flush: true,
      );

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.3',
        now: DateTime.utc(2026, 6, 17, 10, 32),
      );

      expect(result, isNull, reason: 'do not pop on every startup');
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

    test('reports the same app version again when failure fingerprint changes',
        () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File log = File('${dir.path}${Platform.pathSeparator}inno.log');
      await log.writeAsString('Got EAbort exception.');
      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '1.2.3',
        installerPath: r'C:\tmp\hibiki-1.2.3-windows-setup.exe',
        innoLogPath: log.path,
        startedAt: DateTime.utc(2026, 6, 17, 10, 30),
      );
      await WindowsUpdateHandoff.markLaunchSucceeded(
        markerFile: marker,
        installerPid: 4242,
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
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await log.writeAsString(
        [
          r'2026-06-18 10:00:00.000   DeleteFile failed; code 5.',
          r'2026-06-18 10:00:00.001   C:\Program Files\Hibiki\libmpv-2.dll',
        ].join('\n'),
      );
      final WindowsUpdateHandoffResult? third =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '1.2.2',
        now: DateTime.utc(2026, 6, 17, 10, 34),
      );

      expect(first?.record.installerFailureType, 'silent_cancel');
      expect(second, isNull);
      expect(third?.record.installerFailureType, 'deletefile_code_5');
      expect(
        third?.record.failureFingerprint,
        isNot(equals(first?.record.failureFingerprint)),
      );
    });

    test('debug versions reconcile as installed when current debug is newer',
        () async {
      final File marker = await _markerFile();
      await WindowsUpdateHandoff.writePending(
        markerFile: marker,
        targetVersion: '0.5.1-debug.19',
        installerPath: r'C:\tmp\hibiki-0.5.1-debug.19-windows-setup.exe',
        innoLogPath: r'C:\tmp\hibiki-debug.install.log',
        startedAt: DateTime.utc(2026, 6, 17, 10, 30),
      );

      final WindowsUpdateHandoffResult? result =
          await WindowsUpdateHandoff.reconcile(
        markerFile: marker,
        currentVersion: '0.5.1-debug.20',
      );

      expect(result?.status, WindowsUpdateHandoffStatus.installed);
      expect(await marker.exists(), isFalse);
    });

    test('summarizes Inno currently-running and missing-log failures', () {
      final WindowsInstallerFailureSummary running =
          summarizeWindowsInstallerFailure(
        record: WindowsUpdateHandoffRecord(
          targetVersion: '1.2.3',
          installerPath: r'C:\tmp\setup.exe',
          innoLogPath: r'C:\tmp\setup.log',
          startedAt: DateTime.utc(2026, 6, 17),
          innoLogExists: true,
        ),
        innoLogContents: 'Setup detected that Hibiki is currently running.\n'
            'Got EAbort exception.',
      );
      final WindowsInstallerFailureSummary missing =
          summarizeWindowsInstallerFailure(
        record: WindowsUpdateHandoffRecord(
          targetVersion: '1.2.3',
          installerPath: r'C:\tmp\setup.exe',
          innoLogPath: r'C:\tmp\missing.log',
          startedAt: DateTime.utc(2026, 6, 17),
          innoLogExists: false,
        ),
      );

      expect(running.type, 'app_mutex_running');
      expect(running.message, contains('HibikiSingleInstanceMutex'));
      expect(missing.type, 'missing_log');
    });
  });

  group('WindowsInstaller.runAndExit handoff', () {
    test(
        'writes marker, starts delayed launcher with marker log path, then exits',
        () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File installer = File(
          '${dir.path}${Platform.pathSeparator}hibiki-1.2.3-windows-setup.exe');
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);

      String? startedExecutable;
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
          startedExecutable = executable;
          startedArgs = args;
          return const WindowsInstallerStartedProcess(pid: 4242);
        },
        exitProcess: (int code) {
          exitCode = code;
        },
      );

      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record?.targetVersion, '1.2.3');
      expect(record?.installerLaunchSucceeded, isNull,
          reason:
              'the helper writes installer launch outcome after parent exit');
      expect(startedExecutable, endsWith('hibiki_update_launcher.exe'));
      expect(
          startedArgs,
          containsAllInOrder(<String>[
            '--marker',
            marker.path,
            '--parent-pid',
            '$pid',
            '--installer',
            installer.path,
            '--',
          ]));
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
            throw const ProcessException(
              'hibiki_update_launcher.exe',
              <String>[],
              'boom',
            );
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

    test('blocks any active hibiki.exe even outside the target directory',
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
            runningHibikiProcesses: const <WindowsProcessInfo>[
              WindowsProcessInfo(
                pid: 6789,
                name: 'hibiki.exe',
                path: r'C:\Users\wrds\AppData\Local\Hibiki\hibiki.exe',
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
      expect(record?.runningHibikiProcesses.single.pid, 6789);
      expect(record?.launchError, contains('HibikiSingleInstanceMutex'));
    });

    test('does not block on historical install locations without a process',
        () async {
      final File marker = await _markerFile();
      final Directory dir = marker.parent;
      final File installer = File(
          '${dir.path}${Platform.pathSeparator}hibiki-1.2.3-windows-setup.exe');
      await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00]);

      var startCalled = false;
      await WindowsInstaller.runAndExit(
        installer.path,
        targetVersion: '1.2.3',
        handoffMarkerFile: marker,
        collectDiagnostics: () async => WindowsInstallerDiagnostics(
          currentExecutablePath:
              '${dir.path}${Platform.pathSeparator}hibiki.exe',
          currentInstallDir: dir.path,
          targetInstallDir: dir.path,
          detectedInstallLocations: const <WindowsDetectedInstallLocation>[
            WindowsDetectedInstallLocation(
                source: 'current', path: r'D:\APP\Hibiki'),
            WindowsDetectedInstallLocation(
              source: 'historical',
              path: r'C:\Users\wrds\AppData\Local\Hibiki',
            ),
          ],
          pathMismatchWarning: 'historical location differs',
        ),
        startProcess: (String executable, List<String> args) async {
          startCalled = true;
          return const WindowsInstallerStartedProcess(pid: 4242);
        },
        exitProcess: (_) {},
      );

      expect(startCalled, isTrue);
      final WindowsUpdateHandoffRecord? record =
          await WindowsUpdateHandoff.read(marker);
      expect(record?.pathMismatchWarning, contains('historical'));
      expect(record?.installerLaunchSucceeded, isNull);
    });
  });

  group('startup reconcile guard', () {
    test('main schedules Windows update handoff through navigatorKey context',
        () {
      final String source = File('lib/main.dart').readAsStringSync();
      final int navigatorContext =
          source.indexOf('appModel.navigatorKey.currentContext');
      final int contextGuard =
          source.indexOf('UpdateChecker.canShowDialogFromContext');
      final int reconcile = source
          .indexOf('UpdateChecker.reconcilePendingWindowsInstallerHandoff');

      expect(source, contains('_windowsUpdateHandoffChecked'));
      expect(source, contains('_windowsUpdateHandoffScheduled'));
      expect(source, contains('_scheduleWindowsUpdateHandoffReconcile();'));
      expect(
        source,
        isNot(contains('_scheduleWindowsUpdateHandoffReconcile(context)')),
      );
      expect(navigatorContext, isNonNegative);
      expect(contextGuard, isNonNegative);
      expect(reconcile, isNonNegative);
      expect(
        navigatorContext,
        lessThan(reconcile),
        reason: 'Do not pass MaterialApp.builder context into handoff '
            'reconcile; it is outside the Navigator host.',
      );
      expect(
        contextGuard,
        lessThan(reconcile),
        reason: 'The handoff marker must not be read or consumed until a real '
            'Navigator context is available.',
      );
    });

    test(
        'source guard: UpdateChecker validates Navigator before handoff '
        'marker reconcile', () {
      final String source =
          File('lib/src/utils/misc/update_checker_release.dart')
              .readAsStringSync();
      final int method = source.indexOf(
          'static Future<void> reconcilePendingWindowsInstallerHandoff');
      final int guard =
          source.indexOf('canShowDialogFromContext(context)', method);
      final int markerRead =
          source.indexOf('WindowsUpdateHandoff.reconcile', method);

      expect(method, isNonNegative);
      expect(guard, isNonNegative);
      expect(markerRead, isNonNegative);
      expect(
        guard,
        lessThan(markerRead),
        reason: 'A bad startup BuildContext must not consume the handoff '
            'marker before a later Navigator-backed retry can show the dialog.',
      );
    });

    test('source guard: dialog context validator is production-callable', () {
      final String source =
          File('lib/src/utils/misc/update_checker_release.dart')
              .readAsStringSync();
      final int helper = source.indexOf(
        'static bool canShowDialogFromContext(BuildContext context)',
      );
      final int previousAnnotation =
          source.lastIndexOf('@visibleForTesting', helper);
      final int previousMember = source.lastIndexOf('\n  static ', helper - 1);

      expect(helper, isNonNegative);
      expect(
        previousAnnotation,
        lessThan(previousMember),
        reason: 'main.dart calls this helper in production startup code, so it '
            'must not be marked visibleForTesting.',
      );
    });

    test(
        'source guard: injected installer diagnostics are not hidden behind '
        'Platform.isWindows', () {
      final String source =
          File('lib/src/utils/misc/platform_updater.dart').readAsStringSync();
      final int injectedFlag = source.indexOf(
          'final bool hasInjectedDiagnostics = collectDiagnostics != null;');
      final int injectedDiagnostics = source.indexOf(
          'collectDiagnostics != null\n            ? await collectDiagnostics()');
      final int platformFallback =
          source.indexOf('Platform.isWindows\n                ? await '
              'collectWindowsInstallerDiagnostics');
      final int injectedBlockerCheck =
          source.indexOf('if (Platform.isWindows || hasInjectedDiagnostics) {\n'
              '        _throwIfWindowsInstallBlocked');

      expect(injectedFlag, isNonNegative);
      expect(injectedDiagnostics, isNonNegative);
      expect(platformFallback, isNonNegative);
      expect(
        injectedDiagnostics,
        lessThan(platformFallback),
        reason: 'CI runs these tests on Linux; explicit diagnostics must be '
            'honored before the real-platform fallback.',
      );
      expect(
        injectedBlockerCheck,
        isNonNegative,
        reason: 'Injected diagnostics must still exercise the held-libmpv '
            'blocker path on non-Windows hosts.',
      );
    });
  });
}
