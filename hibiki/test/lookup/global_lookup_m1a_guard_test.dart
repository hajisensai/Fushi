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
/// shared source of truth, be injected into the bare overlay, and the overlay
/// must gate the resulting `topPullReleased` on the user's enableSwipeToClose
/// preference.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('M1a-1 autoRead wiring (global lookup controller)', () {
    late String src;
    setUpAll(() {
      src = read('lib/src/lookup/global_lookup_controller.dart');
    });

    test('uses the shared LookupAutoReadCoordinator', () {
      expect(
        src.contains(
            "import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';"),
        isTrue,
        reason: 'must import the shared dedupe coordinator',
      );
      expect(src.contains('LookupAutoReadCoordinator.instance.runAutomatic('),
          isTrue);
    });

    test('autoRead is gated on the autoReadOnLookup preference', () {
      expect(
          src.contains('ReaderHibikiSource.instance.autoReadOnLookup'), isTrue);
    });

    test('play step reuses the overlay audio bridge, not playLookupAudio', () {
      // The two-step overlay bridge: resolve the configured-source URL, then
      // play it through the overlay's own player.
      expect(src.contains('resolveLookupAudioUrl('), isTrue);
      expect(src.contains('TtsChannel.instance.playAudioRef('), isTrue);
      // Must not bypass the overlay bridge via the all-in-one helper.
      expect(
        src.contains('playLookupAudio('),
        isFalse,
        reason:
            'global lookup must reuse resolveLookupAudioUrl + playAudioRef, '
            'not the playLookupAudio shortcut that bypasses the overlay bridge',
      );
    });

    test('autoRead fires on both first lookup and nested re-lookup', () {
      expect(
        '_autoReadFirstEntry('.allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: 'one definition + two call sites (_onHotKey + _lookupNested)',
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
              "import 'package:hibiki/src/reader/popup_swipe_close_script.dart';"),
          isTrue);
      expect(
          src.contains('_topPullReleaseJs = kPopupTopPullReleaseJs'), isTrue);
    });

    test('bare overlay render script injects the shared swipe JS', () {
      final String src = read('lib/src/lookup/global_lookup_render.dart');
      expect(
          src.contains(
              "import 'package:hibiki/src/reader/popup_swipe_close_script.dart';"),
          isTrue);
      expect(src.contains('\$kPopupTopPullReleaseJs'), isTrue);
    });

    test('overlay gates topPullReleased on enableSwipeToClose preference', () {
      final String src = read('lib/src/lookup/global_lookup_controller.dart');
      expect(src.contains("handler == 'topPullReleased'"), isTrue);
      expect(src.contains('ReaderHibikiSource.instance.enableSwipeToClose'),
          isTrue);
    });
  });
}
