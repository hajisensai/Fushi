import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1045 + BUG-1047 guard: keep the browser-extension connection lifecycle fixes wired.
///
/// ① 未连接：app 判「插件已连接」= 扩展最近 <window> 内打过本机 server，且该 last-seen 只在
///    app 内存里（重启即丢）。MV3 SW 空闲 ~30s 被回收、无常驻定时器 → 不查词就 ~120s 后误判
///    「未连接」，app 重启后一直「未连接」。扩展改用 chrome.alarms 每 60s 心跳打
///    /api/extension/status 刷新 last-seen；app 侧时间窗放宽到 150s 留一次丢包余量。
/// ② 需刷新浏览器：自更新 chrome.runtime.reload() 会让所有已打开页的 content script 上下文
///    失效，用户必须手动刷新才恢复。reload 前置 fushiReinjectPending，reload 后由新 SW
///    把 content script 重新注入已打开网页（需 scripting 权限 + 放宽 host_permissions）。
///
/// flutter test cwd is the hibiki package root. background.js / manifest.json 的两镜像
/// 字节一致由 browser_extension_dict_media_mirror_guard_test.dart 守卫，这里只锁行为存在性。
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  group('BUG-1045 heartbeat keeps app-side connection status live', () {
    mirrors.forEach((String name, String root) {
      test('[$name] manifest declares alarms permission', () {
        final String src = File('$root/manifest.json').readAsStringSync();
        expect(src.contains('"alarms"'), isTrue,
            reason: '$root manifest.json must request the alarms permission '
                'for the connection heartbeat');
      });

      test('[$name] background registers a periodic heartbeat alarm', () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(src.contains("chrome.alarms.create('fushiHeartbeat'"), isTrue,
            reason:
                '$root background.js must create the fushiHeartbeat alarm');
        expect(src.contains('periodInMinutes: 1'), isTrue,
            reason: '$root background.js heartbeat must fire ~every 60s '
                '(< the 150s app-side seen window)');
        expect(src.contains('chrome.alarms.onAlarm.addListener'), isTrue,
            reason: '$root background.js must handle the heartbeat alarm');
        // 心跳复用 checkVersionOnStartup —— 既刷 last-seen 又顺带比对版本。
        expect(
            src.contains(
                "if (alarm && alarm.name === 'fushiHeartbeat') checkVersionOnStartup();"),
            isTrue,
            reason:
                '$root background.js heartbeat must ping the server (refresh '
                'last-seen) via checkVersionOnStartup');
      });
    });

    test('app-side seen window widened past a single heartbeat period', () {
      final String src =
          File('lib/src/pages/implementations/browser_extension_page.dart')
              .readAsStringSync();
      expect(src.contains('Duration(seconds: 150)'), isTrue,
          reason:
              'browser_extension_page.dart _seenWindow must widen to 150s so a '
              'single missed 60s heartbeat does not flip the status to '
              '"未连接" (BUG-1045)');
    });
  });

  group('BUG-1047 reload re-injects content scripts into open tabs', () {
    mirrors.forEach((String name, String root) {
      test('[$name] manifest grants scripting + broad host access', () {
        final String src = File('$root/manifest.json').readAsStringSync();
        expect(src.contains('"scripting"'), isTrue,
            reason: '$root manifest.json must request the scripting permission '
                'to re-inject content scripts after a self-reload');
        // executeScript into arbitrary already-open tabs needs host access to
        // http/https origins (loopback-only host_permissions is not enough).
        expect(src.contains('"http://*/*"'), isTrue,
            reason:
                '$root manifest.json host_permissions must cover http://*/* '
                'for post-reload re-injection');
        expect(src.contains('"https://*/*"'), isTrue,
            reason:
                '$root manifest.json host_permissions must cover https://*/* '
                'for post-reload re-injection');
      });

      test('[$name] self-reload flags a pending re-injection', () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(src.contains('fushiReinjectPending: true'), isTrue,
            reason:
                '$root background.js maybeSelfReload must set fushiReinjectPending '
                'before chrome.runtime.reload() so the new SW knows to re-inject');
        // 标记必须在 reload 之前落盘。
        final int flag = src.indexOf('fushiReinjectPending: true');
        final int reload = src.indexOf('chrome.runtime.reload();');
        expect(flag >= 0 && reload > flag, isTrue,
            reason: '$root background.js must persist the pending flag before '
                'calling chrome.runtime.reload()');
      });

      test('[$name] background re-injects open tabs on the next startup', () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(src.contains('async function reinjectOpenTabs()'), isTrue,
            reason: '$root background.js must define reinjectOpenTabs()');
        expect(src.contains('maybeReinjectAfterReload();'), isTrue,
            reason:
                '$root background.js must run maybeReinjectAfterReload() at startup');
        expect(src.contains('chrome.scripting.executeScript'), isTrue,
            reason:
                '$root background.js must re-inject via chrome.scripting.executeScript');
        // 探测已存活的 content script，避免重复注入导致重复监听。
        expect(src.contains('window.__fushiExtension'), isTrue,
            reason:
                '$root background.js must probe window.__fushiExtension to skip '
                'tabs whose content script is still alive');
        // 只对 reload 前置标记生效（不是每次 SW 冷启动都全量重注入）。
        expect(
            src.contains("chrome.storage.local.get(['fushiReinjectPending'])"),
            isTrue,
            reason:
                '$root background.js must gate re-injection on the pending flag');
      });
    });
  });
}
