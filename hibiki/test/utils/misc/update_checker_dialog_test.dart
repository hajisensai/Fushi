import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
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

  testWidgets('installer handoff success dialog shows the target version', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 260);
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
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_install_incomplete_title), findsOneWidget);
    expect(find.textContaining(r'C:\tmp\hibiki-9.9.9.install.log'),
        findsOneWidget);
  });
}
