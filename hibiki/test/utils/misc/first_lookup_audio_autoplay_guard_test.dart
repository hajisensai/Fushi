import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// BUG-1093 源码接线守卫：「本次启动/本 document 第一次查词自动发音没声音」的
/// 三条根因链一旦有人改回去立刻红。
///
/// 根因（Windows 专属组合）：
///  1. Windows fork 不解析 `mediaPlaybackRequiresUserGesture`，也没人给 WebView2
///     传 autoplay 浏览器参数 → Chromium autoplay 策略在 document 尚无 user
///     activation 时静默 reject 首次 `audio.play()`（user activation 是 per-document
///     sticky 的：热槽弹窗 document 常驻 → 只有第一次哑，点过一次就永远正常）。
///  2. `playWordAudioUrl` 曾无条件 `return true`（evaluateJavascript 不 await JS
///     Promise）→ Dart 兜底永不触发、零日志，autoplay 拦截直接表现为彻底静音。
///  3. BUG-1015 的 media_kit 预热修在旁路上（in-app 自动发音已走 WebView <audio>）。
void main() {
  group('BUG-1093 first-lookup audio autoplay wiring', () {
    test('Windows fork allows media autoplay on the default environment', () {
      final String forkWebView = _read(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/'
        'in_app_webview.cpp',
      );
      expect(
        forkWebView,
        contains('--autoplay-policy=no-user-gesture-required'),
        reason: 'WebView2 has no per-view mediaPlaybackRequiresUserGesture; '
            'the default environment must allow autoplay or the first '
            'auto-read per popup document is silently rejected (BUG-1093)',
      );
    });

    test('app-external overlay environment allows media autoplay', () {
      final String overlay = _read('windows/runner/global_lookup_window.cpp');
      expect(
        overlay,
        contains('--autoplay-policy=no-user-gesture-required'),
        reason: 'the overlay WebView2 environment must mirror the in-app '
            'fork autoplay policy (BUG-1093)',
      );
    });

    test('playWordAudioUrl reports the real JS audio.play() outcome', () {
      final String popupWebView =
          _read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(
        popupWebView,
        contains("handlerName: 'wordAudioPlayed'"),
        reason: 'popup.js must report the real audio.play() result back over '
            'the wordAudioPlayed bridge (BUG-1093)',
      );
      expect(
        popupWebView,
        contains('_pendingWordAudioPlays'),
        reason: 'playWordAudioUrl must await the bridged result instead of '
            'unconditionally returning true (BUG-1093)',
      );
      expect(
        popupWebView,
        contains('completer.future.timeout'),
        reason: 'a lost bridge reply must time out to false so the Dart '
            'fallback still fires (BUG-1093)',
      );
    });

    test('auto-read falls back to the Dart player on WebView failure', () {
      final String playback =
          _read('lib/src/utils/misc/lookup_audio_playback.dart');
      expect(
        playback,
        contains('logDiagnostic'),
        reason: 'a WebView play failure must be visible in the error log — '
            'this exact silence cost a mis-rooted fix in BUG-1015',
      );
      expect(
        playback,
        contains('await TtsChannel.instance.playAudioRef('),
        reason: 'the fallback must reuse the single resolved ref (resolve '
            'exactly once: no second DB open / remote request / cooldown hit)',
      );
    });
  });
}
