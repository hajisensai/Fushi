import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki/src/utils/misc/update_handoff.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(child: MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets('update available dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        UpdateAvailableDialog(
          version: '9.9.9',
          releaseNotes: [
            '## Changes',
            '',
            '- Very long release note item that wraps in a compact dialog.',
            '- Another item with [a link](https://example.com).',
          ].join('\n'),
          primaryLabel: t.update_download,
          onPrimary: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_available), findsOneWidget);
    expect(find.text(t.update_download), findsOneWidget);
  });

  testWidgets('download diagnostics overlay fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    final ValueNotifier<double> progress = ValueNotifier<double>(0.42);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_downloading);
    final ValueNotifier<UpdateDownloadDiagnostics?> diagnostics =
        ValueNotifier<UpdateDownloadDiagnostics?>(
      const UpdateDownloadDiagnostics(
        sourceUrl:
            'https://ghproxy.net/https://github.com/hdjsadgfwtg/hibiki/releases/download/v9.9.9/hibiki-9.9.9-windows-setup.exe',
        sourceHost: 'ghproxy.net',
        receivedBytes: 1234567,
        totalBytes: 987654321,
        bytesPerSecond: 123456,
        resumed: false,
        restartedFromZero: false,
      ),
    );
    addTearDown(progress.dispose);
    addTearDown(status.dispose);
    addTearDown(diagnostics.dispose);

    await tester.pumpWidget(
      buildApp(
        Stack(
          children: <Widget>[
            buildUpdateDownloadOverlayForTest(
              progress: progress,
              status: status,
              diagnostics: diagnostics,
              onHide: () {},
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('ghproxy.net'), findsOneWidget);
    expect(find.textContaining('1.2 MB'), findsOneWidget);
    expect(find.textContaining('120.6 KB/s'), findsOneWidget);
    expect(find.textContaining(t.update_download_not_resumed), findsOneWidget);
  });

  // TODO-738: the download overlay exposes a Cancel escape hatch that fires the
  // onCancel callback (lets the user abort the multi-minute connecting hang).
  testWidgets('download overlay shows a cancel button wired to onCancel', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 520);
    addTearDown(tester.view.reset);

    final ValueNotifier<double> progress = ValueNotifier<double>(0);
    final ValueNotifier<String> status =
        ValueNotifier<String>(t.update_connecting);
    final ValueNotifier<UpdateDownloadDiagnostics?> diagnostics =
        ValueNotifier<UpdateDownloadDiagnostics?>(null);
    addTearDown(progress.dispose);
    addTearDown(status.dispose);
    addTearDown(diagnostics.dispose);

    var cancelled = false;
    await tester.pumpWidget(
      buildApp(
        Stack(
          children: <Widget>[
            buildUpdateDownloadOverlayForTest(
              progress: progress,
              status: status,
              diagnostics: diagnostics,
              onHide: () {},
              onCancel: () => cancelled = true,
            ),
          ],
        ),
      ),
    );

    expect(find.text(t.update_cancel), findsOneWidget);
    await tester.tap(find.text(t.update_cancel));
    await tester.pump();
    expect(cancelled, isTrue, reason: 'tapping Cancel must fire onCancel');
  });

  testWidgets('installer handoff success dialog shows the target version', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 520);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        WindowsUpdateHandoffResultDialog(
          result: WindowsUpdateHandoffResult(
            status: WindowsUpdateHandoffStatus.installed,
            record: WindowsUpdateHandoffRecord(
              targetVersion: '9.9.9',
              installerPath: r'C:\tmp\hibiki-9.9.9-windows-setup.exe',
              innoLogPath: r'C:\tmp\hibiki-9.9.9.install.log',
              startedAt: DateTime.utc(2026, 6, 17, 10, 30),
              installerLaunchSucceeded: true,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_install_success_title), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsOneWidget);
  });

  testWidgets('installer handoff dialog opens from navigatorKey context', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    BuildContext? builderContext;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
          builder: (BuildContext context, Widget? child) {
            builderContext = context;
            return child!;
          },
        ),
      ),
    );

    expect(builderContext, isNotNull);
    expect(
      UpdateChecker.canShowDialogFromContext(builderContext!),
      isFalse,
      reason: 'MaterialApp.builder context is above the Navigator.',
    );

    final BuildContext? navigatorContext = navigatorKey.currentContext;
    expect(navigatorContext, isNotNull);
    expect(
      UpdateChecker.canShowDialogFromContext(navigatorContext!),
      isTrue,
      reason: 'Startup handoff must use the Navigator-backed app context.',
    );

    final Future<void> dialogFuture = showAppDialog<void>(
      context: navigatorContext,
      builder: (_) => WindowsUpdateHandoffResultDialog(
        result: WindowsUpdateHandoffResult(
          status: WindowsUpdateHandoffStatus.installed,
          record: WindowsUpdateHandoffRecord(
            targetVersion: '9.9.9',
            installerPath: r'C:\tmp\hibiki-9.9.9-windows-setup.exe',
            innoLogPath: r'C:\tmp\hibiki-9.9.9.install.log',
            startedAt: DateTime.utc(2026, 6, 17, 10, 30),
            installerLaunchSucceeded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_install_success_title), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsOneWidget);

    Navigator.of(navigatorContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    await dialogFuture;
  });

  testWidgets('installer handoff failure dialog keeps the Inno log visible', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 260);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        WindowsUpdateHandoffResultDialog(
          result: WindowsUpdateHandoffResult(
            status: WindowsUpdateHandoffStatus.incomplete,
            record: WindowsUpdateHandoffRecord(
              targetVersion: '9.9.9',
              installerPath: r'C:\tmp\hibiki-9.9.9-windows-setup.exe',
              innoLogPath: r'C:\tmp\hibiki-9.9.9.install.log',
              startedAt: DateTime.utc(2026, 6, 17, 10, 30),
              installerLaunchSucceeded: true,
              launcherPid: 3131,
              parentExitObserved: true,
              installerFailureSummary:
                  'Inno Setup reported that Hibiki was still running.',
              installerPid: 4242,
              innoLogExists: false,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_install_incomplete_title), findsOneWidget);
    expect(find.textContaining(r'C:\tmp\hibiki-9.9.9.install.log'),
        findsOneWidget);
    expect(
      find.text(
        t.update_install_launcher_pid(pid: 3131),
        findRichText: true,
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.text(t.update_install_parent_exit_observed, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Inno Setup reported that Hibiki was still running',
        findRichText: true,
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
        find.text(t.update_install_installer_pid(pid: 4242)), findsOneWidget);
    expect(find.text(t.update_install_log_not_observed), findsOneWidget);
  });

  testWidgets(
      'installer handoff failure dialog shows holder diagnostics and restart '
      'only with lock evidence', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);

    final WindowsUpdateHandoffRecord record =
        WindowsUpdateHandoffRecord.fromJson(<String, dynamic>{
      'targetVersion': '9.9.9',
      'installerPath': r'C:\tmp\hibiki-9.9.9-windows-setup.exe',
      'innoLogPath': r'C:\tmp\hibiki-9.9.9.install.log',
      'startedAt': '2026-06-17T10:30:00Z',
      'installerLaunchSucceeded': true,
      'installerPid': 4242,
      'innoLogExists': true,
      'currentExecutablePath': r'D:\Portable\Hibiki\hibiki.exe',
      'currentInstallDir': r'D:\Portable\Hibiki',
      'targetInstallDir': r'D:\Portable\Hibiki',
      'detectedInstallLocations': <Map<String, dynamic>>[
        <String, dynamic>{
          'source': 'registered',
          'path': r'D:\Program\Hibiki',
        },
        <String, dynamic>{
          'source': 'legacy',
          'path': r'D:\APP\Hibiki',
        },
      ],
      'pathMismatchWarning':
          r'Registered install location D:\Program\Hibiki differs from current D:\Portable\Hibiki. Do not delete it automatically; clean old shortcuts manually if needed.',
      'runningHibikiProcesses': <Map<String, dynamic>>[
        <String, dynamic>{
          'pid': 5678,
          'path': r'D:\Portable\Hibiki\hibiki.exe',
        },
      ],
      'libmpvModuleHolders': <Map<String, dynamic>>[
        <String, dynamic>{
          'pid': 5678,
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

    await tester.pumpWidget(
      buildApp(
        WindowsUpdateHandoffResultDialog(
          result: WindowsUpdateHandoffResult(
            status: WindowsUpdateHandoffStatus.incomplete,
            record: record,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining(r'D:\Portable\Hibiki'), findsWidgets);
    expect(find.textContaining(r'D:\Program\Hibiki'), findsWidgets);
    expect(find.textContaining(r'D:\APP\Hibiki'), findsWidgets);
    expect(find.textContaining('5678'), findsWidgets);
    expect(find.textContaining('libmpv-2.dll'), findsWidgets);
    expect(find.textContaining('code 5'), findsWidgets);
    expect(find.textContaining('Close Hibiki'), findsOneWidget);
    expect(find.textContaining('retry'), findsOneWidget);
    expect(find.textContaining('restart Windows'), findsOneWidget);
  });

  testWidgets(
      'installer handoff launch failure does not suggest reboot without lock '
      'evidence', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 320);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        WindowsUpdateHandoffResultDialog(
          result: WindowsUpdateHandoffResult(
            status: WindowsUpdateHandoffStatus.launchFailed,
            record: WindowsUpdateHandoffRecord(
              targetVersion: '9.9.9',
              installerPath: r'C:\tmp\hibiki-9.9.9-windows-setup.exe',
              innoLogPath: r'C:\tmp\hibiki-9.9.9.install.log',
              startedAt: DateTime.utc(2026, 6, 17, 10, 30),
              installerLaunchSucceeded: false,
              launchError: 'access denied',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('access denied'), findsOneWidget);
    expect(find.textContaining('restart Windows'), findsNothing);
  });
}
