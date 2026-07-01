import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows integration test isolation contract', () {
    final String script = File('tool/run_windows_itest.ps1').readAsStringSync();

    test('only reaps isolated stale test-runner processes', () {
      final List<RegExpMatch> stopProcessMatches =
          RegExp(r'\bStop-Process\b').allMatches(script).toList();
      expect(stopProcessMatches, hasLength(1),
          reason:
              'Only the scoped stale test-runner cleanup may terminate a process.');
      final int killIndex = stopProcessMatches.single.start;
      final int cleanupStart =
          script.lastIndexOf(r'foreach ($proc in $before)', killIndex);
      final int cleanupEnd = script.indexOf(r'$runnerRecords', killIndex);
      expect(cleanupStart, isNot(-1),
          reason: 'Stop-Process must live inside the stale runner loop.');
      expect(cleanupEnd, isNot(-1),
          reason: 'Stop-Process must not leak past runner startup setup.');

      final String cleanupBlock = script.substring(cleanupStart, cleanupEnd);
      expect(
          RegExp(
            r'if\s*\(\$proc\.isTestRunner\)\s*\{\s*try\s*\{[^}]*\bStop-Process\b',
            dotAll: true,
          ).hasMatch(cleanupBlock),
          isTrue,
          reason: 'Windows itest must never terminate the user app.');

      final int snapshotStart =
          script.indexOf('function Get-HibikiProcessSnapshot');
      final int snapshotEnd = script.indexOf('function Add-RunnerSnapshot');
      expect(snapshotStart, isNot(-1),
          reason: 'Process classification helper must exist.');
      expect(snapshotEnd, isNot(-1),
          reason: 'Process classification helper must have a bounded body.');
      final String snapshotBlock = script.substring(snapshotStart, snapshotEnd);
      expect(snapshotBlock, contains(r'$path = [string]$cim.ExecutablePath'),
          reason: 'The test-runner scope must be based on executable path.');
      expect(snapshotBlock, contains(r'$path.StartsWith($RunnerPathPrefix,'),
          reason: 'The stale runner check must be scoped to this worktree.');
      expect(snapshotBlock,
          contains('[System.StringComparison]::OrdinalIgnoreCase'),
          reason:
              'The test-runner scope must stay path based, not name based.');
      expect(snapshotBlock, contains(r'isTestRunner = $isRunner'),
          reason: 'The guarded cleanup must use the path-derived marker.');
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
