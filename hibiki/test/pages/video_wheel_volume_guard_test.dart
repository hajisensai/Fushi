import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-1058: mouse-wheel over the video PICTURE adjusts volume (desktop).
///
/// The real wheel event is a [PointerSignalEvent] delivered by the platform, so
/// this locks the video page wiring/gating contract at the source level:
///   - the outer video-body Listener (the same one that owns onPointerUp for
///     tap-to-pause / double-tap) wires `onPointerSignal: _handleVideoWheelSignal`
///     so the wheel is caught over the whole picture, not only the volume chip;
///   - the handler only acts on a PointerScrollEvent (ignores other signals);
///   - gated to desktop (`_isDesktopVideoControls`) — mobile has no wheel;
///   - respects the immersive lock (`_immersiveAllowsFullControls`, same gate as
///     the keyboard volume keys);
///   - does NOT fire when a side panel is open, or when the pointer is over the
///     control-bar chrome (`_isVideoChromePointer`) — the bottom volume chip has
///     its own wheel Listener and lists/seek-bar own their scroll, so the
///     picture-level handler only serves the bare picture (no double-fire / no
///     stolen chrome scroll);
///   - delegates to the existing `_onVolumeWheel` -> `_adjustVolume` volume
///     channel, which already drives the right-side level HUD (OSD feedback).
///
/// PointerSignal does not enter the gesture arena, so this is orthogonal to the
/// long-press horizontal-drag seek (TODO-756) and single-tap pause — no conflict.
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('video-body Listener wires onPointerSignal to the wheel handler', () {
    // The picture-level Listener already owns onPointerUp: _handleVideoPointerUp;
    // the wheel signal must ride the SAME Listener so it covers the whole picture.
    final int pointerUp = src.indexOf('onPointerUp: _handleVideoPointerUp,');
    expect(pointerUp, greaterThanOrEqualTo(0));
    final int pointerSignal =
        src.indexOf('onPointerSignal: _handleVideoWheelSignal,', pointerUp);
    expect(pointerSignal, greaterThan(pointerUp),
        reason: 'the wheel handler must be wired on the same video-body '
            'Listener that owns tap-to-pause, right after onPointerUp');
    // and be reasonably adjacent (same Listener, not some far-away widget).
    expect(pointerSignal - pointerUp, lessThan(400),
        reason:
            'onPointerSignal should sit on the same Listener as onPointerUp');
  });

  test('_handleVideoWheelSignal gates and delegates to the volume channel', () {
    final String h = region(
      'void _handleVideoWheelSignal(PointerSignalEvent event) {',
      'bool _handleDoubleTapSeek(',
    );
    expect(h.contains('if (event is! PointerScrollEvent) return;'), isTrue,
        reason: 'only wheel scroll signals adjust volume');
    expect(h.contains('if (!_isDesktopVideoControls) return;'), isTrue,
        reason: 'wheel volume is desktop-only (mobile has no wheel)');
    expect(h.contains('if (!_immersiveAllowsFullControls) return;'), isTrue,
        reason: 'respect the immersive lock like the keyboard volume keys');
    expect(h.contains('if (_videoSidePanel.value != null) return;'), isTrue,
        reason: 'do not steal the wheel while a side panel is open');
    expect(h.contains('_isVideoChromePointer(controlsContext, event.position)'),
        isTrue,
        reason: 'wheel over control-bar chrome is left to the chrome '
            '(the bottom volume chip owns its own wheel Listener)');
    expect(
        h.contains('_onVolumeWheel(controller, event.scrollDelta.dy)'), isTrue,
        reason: 'delegate to the existing _onVolumeWheel -> _adjustVolume path '
            '(which drives the right-side level HUD / OSD feedback)');
  });

  test('the delegated wheel path drives the volume OSD feedback', () {
    // _onVolumeWheel -> _adjustVolume -> _applyUserVideoVolume -> _showVolumeOsd.
    final String wheel = region(
      'void _onVolumeWheel(VideoPlayerController controller, double scrollDeltaY) {',
      'void _syncVolumeDisplay(double volume) {',
    );
    expect(wheel.contains('_adjustVolume(delta)'), isTrue,
        reason: 'wheel adjusts through the shared _adjustVolume channel');
    expect(wheel.contains('_VideoHibikiPageState._volumeStep'), isTrue,
        reason:
            'wheel uses the shared _volumeStep, up-scroll increases volume');
  });
}
