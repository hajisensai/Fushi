import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1079 守卫（源码扫描）：扩展自更新失败不再永久静默，且版本感知双向闭环。
///
/// 旧行为两处断裂：
/// ① background.js 对某 remote build reload 过一次就永不重试（latch 永久静默）——自更新
///    失败（磁盘副本没刷成 / 用户从别的目录加载 / 浏览器拒绝 reload）后永久停在旧版零提示；
/// ② 扩展状态请求写死 '{}'，app 端对浏览器里实际加载的版本零感知，扩展管理页只显示
///    app 内置指纹，无从提示「浏览器里那份已过期」。
///
/// 修复链路：self-update.js 纯状态机（reload 一次 → 仍不一致落 fushiUpdateStale →
/// 恢复一致清除）+ action-popup 提示 + 图标角标（录制角标优先）+ 状态请求自报
/// build/version + server 解析回调 + app_model 记录 + 扩展管理页双行版本卡与警示条。
///
/// flutter test cwd is the hibiki package root.
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  group('BUG-1079 extension self-update stale detection', () {
    mirrors.forEach((String name, String root) {
      test(
          '[$name] background uses the self-update state machine (no permanent latch)',
          () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(
            src.contains(
                "importScripts('fushi-defaults.js', 'connection-diagnostics.js', 'self-update.js')"),
            isTrue,
            reason: '$root background.js must load self-update.js');
        expect(src.contains('FUSHI_SELF_UPDATE.decide('), isTrue,
            reason:
                '$root background.js must decide via the pure state machine '
                'instead of an early-return latch');
        expect(src.contains('fushiUpdateStale: decision.stale'), isTrue,
            reason: '$root background.js must persist the stale marker when a '
                'reload already happened but builds still mismatch');
        expect(
            src.contains("chrome.storage.local.remove(['fushiUpdateStale'])"),
            isTrue,
            reason: '$root background.js must clear the stale marker once '
                'builds match again');
      });

      test(
          '[$name] status requests self-report build/version (no hardcoded {})',
          () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(src.contains('statusRequestBody()'), isTrue,
            reason: '$root background.js must send the self-reported '
                'build/version body on /api/extension/status');
        expect(src.contains('chrome.runtime.getManifest().version'), isTrue,
            reason: '$root background.js must include the manifest version');
      });

      test('[$name] update badge yields to the recording badge', () {
        final String src = File('$root/background.js').readAsStringSync();
        final int fn = src.indexOf('async function refreshUpdateBadge()');
        expect(fn >= 0, isTrue,
            reason: '$root background.js must define refreshUpdateBadge()');
        final String body = src.substring(fn, fn + 600);
        expect(
            body.contains('if (await isOffscreenRecording()) return;'), isTrue,
            reason: '$root refreshUpdateBadge must skip while recording '
                '(recording badge has priority)');
        expect(src.contains('if (!on) refreshUpdateBadge();'), isTrue,
            reason: '$root setRecordingBadge(false) must restore the update '
                'badge after recording ends');
      });

      test('[$name] action-popup surfaces the manual-reload notice', () {
        final String html =
            File('$root/vendor/action-popup.html').readAsStringSync();
        final String js =
            File('$root/vendor/action-popup.js').readAsStringSync();
        expect(html.contains('id="hp-update"'), isTrue,
            reason: '$root action-popup.html missing the update notice row');
        expect(js.contains('fushiUpdateNotice'), isTrue,
            reason: '$root action-popup.js missing the notice copy function');
        expect(js.contains("chrome.storage.local.get(['fushiUpdateStale']"),
            isTrue,
            reason: '$root action-popup.js must read fushiUpdateStale');
        expect(js.contains('changes.fushiUpdateStale'), isTrue,
            reason: '$root action-popup.js must react to stale changes live');
      });
    });

    test('self-update.js mirrors stay byte-identical', () {
      final List<int> tools =
          File('../tools/browser-extension/self-update.js').readAsBytesSync();
      final List<int> assets =
          File('assets/browser_extension/self-update.js').readAsBytesSync();
      expect(assets, tools,
          reason:
              'assets/browser_extension/self-update.js out of sync with tools/');
    });

    test('server parses the reported build from the status body (tolerant)',
        () {
      final String src =
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync();
      expect(src.contains('onExtensionReport'), isTrue,
          reason: 'yomitan_api_server.dart must expose the report callback');
      expect(src.contains('_handleExtensionStatus'), isTrue,
          reason: 'status endpoint must go through the body-parsing handler');
      expect(
          src.contains('reportedBuild is String && reportedBuild.isNotEmpty'),
          isTrue,
          reason: 'server must only report a non-empty string build '
              "(old extensions sending '{}' keep current behavior)");
    });

    test('app model records the reported build for the extension page', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src.contains('browserExtensionReportedBuild'), isTrue,
          reason: 'app_model.dart must hold the reported-build notifier');
      expect(src.contains('onExtensionReport:'), isTrue,
          reason: 'app_model.dart must wire onExtensionReport into the '
              'yomitan server manager');
    });

    test('extension page shows both builds and a mismatch warning', () {
      final String src =
          File('lib/src/pages/implementations/browser_extension_page.dart')
              .readAsStringSync();
      expect(src.contains('browserExtensionReportedBuild'), isTrue,
          reason: 'version card must subscribe to the reported build');
      expect(src.contains('browser_extension_version_app'), isTrue,
          reason: 'version card must label the app bundled build');
      expect(src.contains('browser_extension_version_browser'), isTrue,
          reason: 'version card must label the browser-loaded build');
      expect(src.contains('browser_extension_version_mismatch'), isTrue,
          reason: 'version card must show the mismatch guidance');
      expect(
          src.contains(
              'build != null && reported != null && build != reported'),
          isTrue,
          reason: 'mismatch warning must require both builds known and unequal '
              '(never warn on missing report — old extensions)');
    });
  });
}
