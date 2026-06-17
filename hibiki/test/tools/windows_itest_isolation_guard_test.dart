import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows integration test isolation contract', () {
    final String script = File('tool/run_windows_itest.ps1').readAsStringSync();

    test('does not kill or reject existing user Hibiki processes', () {
      expect(script, isNot(contains('Stop-Process')),
          reason: 'Windows itest must never terminate the user app.');
      expect(script, isNot(contains('taskkill')),
          reason: 'Windows itest must never terminate the user app.');
      expect(script, isNot(contains('close it first')),
          reason: 'A running user Hibiki instance is evidence, not a blocker.');
      expect(script, isNot(contains('hibiki.exe is running')),
          reason:
              'The script must not fail just because a user instance exists.');
    });

    test('records required process and runner evidence files', () {
      for (final String marker in <String>[
        'process-before.json',
        'process-after.json',
        'paths.json',
        'command.log',
        'runner-info.json',
        'exit-code.txt',
      ]) {
        expect(script, contains(marker), reason: 'Missing evidence: $marker');
      }
      expect(script, contains('Get-CimInstance Win32_Process'),
          reason: 'Evidence must include process Path and CommandLine.');
      expect(script, contains('MainWindowTitle'),
          reason: 'Evidence must include window title when available.');
    });

    test('runs with isolated test root, app data, logs, and WebView2 profile',
        () {
      expect(script, contains('HIBIKI_TEST_ROOT'));
      expect(script, contains('HIBIKI_TEST_RUN_ID'));
      expect(script, contains('HIBIKI_WEBVIEW2_USER_DATA_FOLDER'));
      expect(script, contains('--dart-define=HIBIKI_TEST_ROOT='));
      expect(script, contains('--dart-define=HIBIKI_TEST_RUN_ID='));
      expect(script, contains('APPDATA'));
      expect(script, contains('LOCALAPPDATA'));
      expect(script, contains('TEMP'));
      expect(script, contains('TMP'));
      expect(script, contains('USERPROFILE'));
    });

    test('app startup honors the isolated test root for app data and logs', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final String errorLog =
          File('lib/src/utils/misc/error_log_service.dart').readAsStringSync();

      expect(appModel, contains("hibikiTestDirectory('temp'"));
      expect(appModel, contains("hibikiTestDirectory('app-documents'"));
      expect(appModel, contains("hibikiTestDirectory('app-support'"));
      expect(errorLog, contains("hibikiTestDirectory('app-documents'"));
    });

    test('native logs and WebView2 profile use test-only isolation env vars',
        () {
      final String crashDump =
          File('windows/runner/crash_dump.cpp').readAsStringSync();
      final String wgcLog = File(
        '../packages/flutter_inappwebview_windows/windows/utils/wgc_log.cpp',
      ).readAsStringSync();
      final String inAppWebView = File(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      ).readAsStringSync();
      final String webViewEnvironment = File(
        '../packages/flutter_inappwebview_windows/windows/webview_environment/webview_environment.cpp',
      ).readAsStringSync();

      expect(crashDump, contains('HIBIKI_TEST_ROOT'));
      expect(wgcLog, contains('HIBIKI_TEST_ROOT'));
      expect(inAppWebView, contains('HIBIKI_WEBVIEW2_USER_DATA_FOLDER'));
      expect(webViewEnvironment, contains('HIBIKI_WEBVIEW2_USER_DATA_FOLDER'));
    });
  });
}
