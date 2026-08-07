import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-854 M1a wiring guards (source scan).
///
/// M1a-1 autoRead: the Windows global lookup overlay must auto-pronounce the
/// looked-up word per the user's `autoReadOnLookup` preference, reusing the SAME
/// dedupe coordinator the in-app popup uses (LookupAutoReadCoordinator) and the
/// overlay's existing two-step audio bridge (resolveLookupAudioUrl ->
/// TtsChannel.playAudioRef). It must NOT fall back to playLookupAudio (that path
/// bypasses the overlay's own bridge). A refactor that drops the coordinator or
/// reintroduces playLookupAudio in the controller would silently regress.
///
/// M1a-2 swipe-close: the top-pull dismiss JS must drive both touch (mobile) and
/// pointer/mouse (desktop WebView2 — incl. the global overlay), live in ONE
/// shared source of truth, and the overlay must gate the resulting
/// `topPullReleased` on the user's enableSwipeToClose preference. (TODO-867 P3c
/// retired buildOverlayRenderScript: the overlay's injection site for this JS
/// migrates from the single-frame render body to the host in a later P3c commit;
/// the shared source of truth + the controller gate are unchanged.)
void main() {
  String read(String p) => File(p).readAsStringSync();

  // BUG-1210 — 自动朗读的实现搬进共享 `overlay_auto_read.dart`（app 外两个表面
  // 共用，剪贴板面板此前整条路径没接线）。本组守的意图一字未改，只是实现细节现在
  // 落在共享文件里：接线（controller）与实现（shared）分开扫。
  group('M1a-1 autoRead wiring (global lookup controller)', () {
    late String src;
    late String shared;
    setUpAll(() {
      src = read('lib/src/lookup/global_lookup_controller.dart');
      shared = read('lib/src/lookup/overlay_auto_read.dart');
    });

    test('uses the shared LookupAutoReadCoordinator', () {
      expect(
        shared.contains(
            "import 'package:fushi/src/utils/misc/lookup_auto_read_coordinator.dart';"),
        isTrue,
        reason: 'must import the shared dedupe coordinator',
      );
      expect(
          shared.contains('LookupAutoReadCoordinator.instance.runAutomatic('),
          isTrue);
      // 控制器仍须真的接上这条线（否则共享实现形同虚设）。
      expect(src.contains('OverlayAutoRead('), isTrue,
          reason: 'the controller must wire up the shared implementation');
      expect(src.contains('_autoRead.autoReadFirstEntry('), isTrue);
    });

    test('autoRead is gated on the autoReadOnLookup preference', () {
      expect(shared.contains('ReaderHibikiSource.instance.autoReadOnLookup'),
          isTrue);
    });

    test('play step goes through the unified fast path (BUG-1127)', () {
      // BUG-1127 — the overlay auto-read joined the SAME unified contract the
      // in-app popup uses since 9855c3e4f: autoReadWordUnified resolves the ref
      // once, prefers the popup's own HTML5 <audio> (playInWebView), and falls
      // back to the Dart player on a REPORTED failure. The controller must not
      // re-grow its own resolve + playAudioRef fork (the pre-BUG-1127 slow
      // path: libmpv stop→load→play per play, silent failures).
      expect(shared.contains('autoReadWordUnified('), isTrue);
      expect(shared.contains('playInWebView: playWordAudioUrl'), isTrue);
      for (final String s in <String>[src, shared]) {
        expect(
          s.contains('TtsChannel.instance.playAudioRef('),
          isFalse,
          reason: 'the Dart fallback lives INSIDE autoReadWordUnified with the '
              'already-resolved ref; a direct playAudioRef here would re-fork '
              'the overlay off the unified path (BUG-1127 regression)',
        );
        // Must not bypass the unified helper via the all-in-one shortcut.
        expect(
          s.contains('playLookupAudio('),
          isFalse,
          reason: 'global lookup must reuse autoReadWordUnified, not the '
              'playLookupAudio shortcut that skips the WebView fast path',
        );
      }
    });

    test('BUG-1127: WebView play reports the real audio.play() outcome', () {
      // Token + Completer + timeout, mirroring the in-app wordAudioPlayed
      // contract (BUG-1093): the Dart side must consume a REAL result — no
      // fire-and-forget (silent swallow) and no unconditional fallback (double
      // playback).
      expect(shared.contains("handler != 'wordAudioPlayed'"), isTrue,
          reason: 'the shared handler must still dispatch on wordAudioPlayed');
      expect(src.contains('_autoRead.maybeHandleWordAudioPlayed('), isTrue,
          reason:
              'the controller must route the report into the shared handler');
      expect(shared.contains('_pendingWordAudioPlays'), isTrue);
      expect(shared.contains('completer.future.timeout'), isTrue);
      // The play script must target the STABLE root frame (always warm after
      // prewarm; TODO-1095) and be gated on webview readiness — the native
      // render channel caches scripts last-wins while the surface is not
      // ready, so an ungated play script would clobber a pending stack render.
      expect(shared.contains('buildPlayWordAudioScript('), isTrue);
      expect(shared.contains('kGlobalLookupRootFrameId'), isTrue);
      expect(shared.contains('_isWebViewReady()'), isTrue);
    });

    test('autoRead fires on both first lookup and nested re-lookup', () {
      expect(
        '_autoReadFirstEntry('.allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: 'one delegating wrapper + two call sites '
            '(_onHotKey + _lookupNested)',
      );
    });
  });

  group('M1a-2 swipe-close JS (pointer/mouse for desktop WebView2)', () {
    test('shared JS source of truth carries both touch and pointer paths', () {
      final String js = read('lib/src/reader/popup_swipe_close_script.dart');
      // Touch (mobile) path retained.
      expect(js.contains("addEventListener('touchstart'"), isTrue);
      expect(js.contains("addEventListener('touchmove'"), isTrue);
      // Pointer/mouse (desktop WebView2) path added.
      expect(js.contains("addEventListener('pointerdown'"), isTrue);
      expect(js.contains("addEventListener('pointermove'"), isTrue);
      expect(js.contains("addEventListener('pointerup'"), isTrue);
      // No double-fire: pointer handlers skip pointerType 'touch'.
      expect(js.contains("e.pointerType === 'touch'"), isTrue);
      // Still reports through the same bridge.
      expect(js.contains("callHandler('topPullReleased')"), isTrue);
    });

    test('in-app popup webview reuses the shared constant (single truth)', () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(
          src.contains(
              "import 'package:fushi/src/reader/popup_swipe_close_script.dart';"),
          isTrue);
      expect(
          src.contains('_topPullReleaseJs = kPopupTopPullReleaseJs'), isTrue);
    });

    test('top-pull swipe JS migrated off the retired single-frame render path',
        () {
      // TODO-867 P3c: buildOverlayRenderScript (the single-frame TOP-LEVEL
      // direct-render path) is RETIRED — the top document is now the bare iframe
      // host, so the swipe JS no longer belongs in global_lookup_render.dart's
      // single-frame body (it migrates to the host in a later P3c commit). The
      // controller still gates topPullReleased on the user's preference (next
      // test), so the bridge contract is intact; only the injection site moved.
      final String src = read('lib/src/lookup/global_lookup_render.dart');
      expect(src.contains('String buildOverlayRenderScript('), isFalse,
          reason: 'the retired single-frame render entry must be gone');
      // The shared swipe-close source of truth itself is unchanged (locked by
      // the JS-source-of-truth test above), and the in-app popup still uses it.
      final String shared =
          read('lib/src/reader/popup_swipe_close_script.dart');
      expect(shared.contains("callHandler('topPullReleased')"), isTrue,
          reason:
              'the single shared swipe source must still exist for in-app + '
              'the future host re-wiring');
    });

    test('overlay gates topPullReleased on enableSwipeToClose preference', () {
      final String src = read('lib/src/lookup/global_lookup_controller.dart');
      expect(src.contains("handler == 'topPullReleased'"), isTrue);
      expect(src.contains('ReaderHibikiSource.instance.enableSwipeToClose'),
          isTrue);
    });
  });
}
