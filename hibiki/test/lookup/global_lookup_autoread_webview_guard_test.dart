import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1127 wiring guards (source scan).
///
/// app 外查词自动发音统一到 WebView `<audio>` 快路径：浮窗控制器经
/// autoReadWordUnified（解析一次 ref）驱动 host 的 playWordAudioInFrame，在常驻
/// ROOT iframe 的 popup.js realm 里 `audio.play()`，真实结果经 wordAudioPlayed
/// 桥回报，失败/超时回落 Dart 播放器；静默失败不再占用 800ms 去重窗；
/// DesktopAudioPlayback 的 preempt 丢音必须留下诊断日志。任何一环被重构掉都会
/// 回到「app 外查词音频被吞/响应慢」（BUG-1127 的原始症状）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('BUG-1127 render script builder', () {
    late String src;
    setUpAll(() {
      src = read('lib/src/lookup/global_lookup_render.dart');
    });

    test('buildPlayWordAudioScript targets the host play entry, guarded', () {
      expect(src.contains('String buildPlayWordAudioScript('), isTrue);
      expect(
        src.contains('window.__globalLookupHost && '),
        isTrue,
        reason: 'host scripts must stay inert when the host is not installed',
      );
      expect(
        src.contains('window.__globalLookupHost.playWordAudioInFrame('),
        isTrue,
      );
    });

    test('url and frame id are JSON-encoded into the script', () {
      // A data: URL / arbitrary remote URL must be spliced as a JS string
      // literal, never raw-interpolated.
      final int fnStart = src.indexOf('String buildPlayWordAudioScript(');
      expect(fnStart, greaterThanOrEqualTo(0));
      final String fn = src.substring(fnStart);
      expect(fn.contains('jsonEncode(frameId)'), isTrue);
      expect(fn.contains('jsonEncode(url)'), isTrue);
    });
  });

  group('BUG-1127 host playWordAudioInFrame (global_lookup_host.js)', () {
    late String js;
    setUpAll(() {
      js = read('assets/popup/global_lookup_host.js');
    });

    test('defined and exported on the host API', () {
      expect(js.contains('function playWordAudioInFrame('), isTrue);
      expect(js.contains('playWordAudioInFrame: playWordAudioInFrame'), isTrue);
    });

    test('gates on a LOADED frame and reports false from the host realm', () {
      // A missing/unloaded frame must resolve the Dart completer immediately
      // (postToHost false) instead of leaving it to the 5s timeout.
      expect(js.contains('record?.loaded'), isTrue);
      expect(
        js.contains("postToHost('wordAudioPlayed', [token, false])"),
        isTrue,
      );
    });

    test('iframe realm plays via __hibikiPlayWordAudioUrl and reports back',
        () {
      // The eval body drives popup.js's own <audio> entry and posts the REAL
      // audio.play() outcome through the wrapped per-frame bridge.
      expect(js.contains('window.__hibikiPlayWordAudioUrl'), isTrue);
      expect(js.contains('handler: "wordAudioPlayed"'), isTrue);
      expect(
        js.contains('JSON.stringify(url)'),
        isTrue,
        reason: 'the url must be escaped as a JS string literal inside eval',
      );
    });
  });

  group('BUG-1127 popup.js auto-read entry', () {
    test('window.__hibikiPlayWordAudioUrl stays exported', () {
      final String js = read('assets/popup/popup.js');
      expect(
        js.contains('window.__hibikiPlayWordAudioUrl = playWordAudio'),
        isTrue,
        reason: 'the host-driven auto-read entry (shared with the in-app '
            'popup) must not be renamed/removed',
      );
    });
  });

  group('BUG-1127 unified helper reports the real outcome', () {
    late String src;
    setUpAll(() {
      src = read('lib/src/utils/misc/lookup_audio_playback.dart');
    });

    test('autoReadWordUnified returns whether playback actually started', () {
      expect(src.contains('Future<bool> autoReadWordUnified('), isTrue);
      expect(
        src.contains('return await TtsChannel.instance.playAudioRef('),
        isTrue,
        reason: 'the Dart fallback must propagate playAudioRef\'s real result '
            '(with the SAME already-resolved ref — never re-resolve)',
      );
    });
  });

  group('BUG-1127 dedupe window releases on silent failure', () {
    test('coordinator rolls back acceptedAt when play reports false', () {
      final String src =
          read('lib/src/utils/misc/lookup_auto_read_coordinator.dart');
      expect(src.contains('typedef LookupAutoReadPlayback = Future<bool>'),
          isTrue);
      expect(src.contains('if (!played)'), isTrue);
      // Behavior itself is covered by lookup_auto_read_coordinator_test.dart;
      // this pins the wiring so a refactor back to Future<void> fails loudly.
    });
  });

  group('BUG-1127 preempted playback is observable', () {
    test('both generation bail-outs log a diagnostic', () {
      final String src = read('lib/src/utils/misc/desktop_audio_playback.dart');
      expect(
        src.contains('preempted by stop() before load'),
        isTrue,
        reason: 'the pre-load preempt swallow must never be silent again',
      );
      expect(
        src.contains('preempted by stop() after load'),
        isTrue,
        reason: 'the post-load preempt swallow must never be silent again',
      );
    });
  });
}
