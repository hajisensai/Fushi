import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows integration test isolation contract', () {
    final String script = File('tool/run_windows_itest.ps1').readAsStringSync();

    test('does not kill or reject existing user Hibiki processes', () {
      // TODO-980: the runner MAY reap stale TEST-RUNNER processes left by a
      // previous crashed run of THIS runner (a stuck prior runner locks the
      // build/debug port -> "Unable to start the app"). That reap is scoped
      // strictly to this worktree's build\windows\x64\runner path via the
      // isTestRunner flag, so it never touches the user's installed Hibiki or
      // IDE processes. The contract is therefore "never hand-kill by name and
      // never kill an unscoped process", NOT "never call Stop-Process at all".
      expect(script, isNot(contains('taskkill')),
          reason: 'Windows itest must never terminate processes by name.');
      expect(script, isNot(contains('Stop-Process -Name')),
          reason:
              'Windows itest must never kill by process name (could match the '
              'user app).');
      expect(script, isNot(contains('close it first')),
          reason: 'A running user Hibiki instance is evidence, not a blocker.');
      expect(script, isNot(contains('hibiki.exe is running')),
          reason:
              'The script must not fail just because a user instance exists.');
      // Any Stop-Process must be gated by the isTestRunner scope check, so it
      // only ever reaps stale test-runner processes under this worktree's
      // runner path.
      if (script.contains('Stop-Process')) {
        expect(script, contains('isTestRunner'),
            reason:
                'Stop-Process is only allowed when scoped to stale test-runner '
                'processes (isTestRunner path-prefix match).');
      }
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
      // TODO-935 E0：三个数据根的 hibikiTestDirectory 隔离判定收敛到唯一入口
      // AppPaths（lib/src/storage/app_paths.dart）；app_model 不再各自直连，改在启动期
      // 经 AppPaths.resolve() 委托解析。守卫据此校验「隔离契约仍在、且走单一入口」。
      final String appPaths =
          File('lib/src/storage/app_paths.dart').readAsStringSync();
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final String errorLog =
          File('lib/src/utils/misc/error_log_service.dart').readAsStringSync();

      // 三根的测试隔离判定落在 AppPaths 单一入口。
      expect(appPaths, contains("hibikiTestDirectory('temp'"));
      expect(appPaths, contains("hibikiTestDirectory('app-documents'"));
      expect(appPaths, contains("hibikiTestDirectory('app-support'"));
      // 启动期 app_model 经 AppPaths.resolve() 接上隔离根（不绕过单一入口）。
      expect(appModel, contains('AppPaths.resolve('));
      // 日志服务仍独立 honor 隔离的 documents 根。
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
