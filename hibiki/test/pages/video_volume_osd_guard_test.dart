import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// Source guard for mpv/asbplayer-style volume and brightness feedback.
///
/// The real volume keys are owned by media_kit and platform input, so this
/// locks the video page invariant: volume and brightness changes must use the
/// Hibiki page-level level HUD for about 1.6s. Non-volume/brightness OSDs stay
/// on the legacy top-left mpv-style channel.
void main() {
  final File overlays = File('lib/src/media/video/video_volume_overlays.dart');

  late String src;
  late String overlaySrc;
  setUpAll(() {
    expect(overlays.existsSync(), isTrue);
    src = readVideoHibikiSource();
    overlaySrc = overlays.readAsStringSync();
  });

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('volume and brightness share the page-level level HUD channel', () {
    expect(src.contains('enum _VideoLevelHudKind'), isTrue);
    expect(src.contains('class _VideoLevelHudState'), isTrue);
    expect(src.contains('final ValueNotifier<_VideoLevelHudState?>'), isTrue,
        reason:
            'Level HUD visibility/value must be independent from _osdNotifier.');
    expect(src.contains('Timer? _levelHudTimer'), isTrue,
        reason: 'Level HUD needs its own auto-hide timer.');
    expect(src.contains('void _showVolumeOsd(double volume)'), isTrue);
    expect(src.contains('void _showBrightnessOsd(double brightness)'), isTrue);

    final String adjust = region(
      'Future<void> _adjustVolume(double delta) async {',
      'Future<void> _toggleMute() async {',
    );
    expect(adjust.contains('_applyUserVideoVolume(next)'), isTrue);

    final String mute = region(
      'Future<void> _toggleMute() async {',
      'void _showVolumeOsd(double volume) {',
    );
    expect(mute.contains('_applyUserVideoVolume('), isTrue,
        reason:
            'Mute/unmute should use the same volume visual language without persistence.');
    expect(mute.contains('persist: false'), isTrue,
        reason:
            'Mute/unmute should use the same volume visual language without persistence.');
    expect(mute.contains('applyToController: false'), isTrue,
        reason:
            'Mute/unmute should use the same volume visual language without persistence.');

    final String helper = region(
      'Future<void> _applyUserVideoVolume(',
      'void _queuePersistVideoVolume(double volume) {',
    );
    final int syncIndex = helper.indexOf('_syncVolumeDisplay(clamped);');
    final int hudIndex = helper.indexOf('_showVolumeOsd(clamped)');
    final int setVolumeIndex =
        helper.indexOf('await controller.setVolume(clamped);');
    expect(syncIndex, greaterThanOrEqualTo(0));
    expect(hudIndex, greaterThan(syncIndex),
        reason: 'HUD should show the target value after display sync');
    expect(setVolumeIndex, greaterThan(hudIndex),
        reason: 'HUD must appear before async media_kit volume work finishes');
    expect(helper.contains('_showVolumeOsd(clamped)'), isTrue,
        reason:
            'All real volume paths should drive the right-side HUD helper.');

    final String volumeHud = region(
      'void _showVolumeOsd(double volume) {',
      'void _showBrightnessOsd(double brightness) {',
    );
    expect(volumeHud.contains('_showLevelHud('), isTrue,
        reason: 'Volume changes should drive the page-level HUD helper.');
    expect(volumeHud.contains('_showOsd('), isFalse,
        reason: 'Volume feedback must not reuse the top-left generic OSD.');

    final String brightnessHud = region(
      'void _showBrightnessOsd(double brightness) {',
      'void _onMediaKitVolumeChanged(double value) {',
    );
    expect(brightnessHud.contains('_showLevelHud('), isTrue,
        reason: 'Brightness changes should drive the page-level HUD helper.');
    expect(brightnessHud.contains('_showOsd('), isFalse,
        reason: 'Brightness feedback must not reuse the top-left generic OSD.');
  });

  test('right volume HUD is screen-right and pointer transparent', () {
    final String indicator = region(
      'Widget _buildRightVolumeIndicator(double volume) {',
      'Widget _buildLevelHudOverlay() {',
    );
    expect(indicator.contains('IgnorePointer'), isTrue,
        reason: 'Shared HUD indicator must never capture video pointers.');
    expect(indicator.contains('Alignment.centerRight'), isTrue,
        reason: 'Volume feedback belongs on the screen right.');
    expect(indicator.contains('_volumeIconFor(clamped)'), isTrue);
    expect(indicator.contains('VideoLevelHudCard'), isTrue,
        reason: 'Volume HUD visible card should use the measurable helper.');
    expect(indicator.contains('frameKey: videoVolumeHudFrameKey'), isTrue,
        reason:
            'Volume HUD frame must be directly measurable in widget tests.');
    expect(overlaySrc.contains('LinearProgressIndicator'), isTrue,
        reason: 'Volume HUD should expose a percentage bar like a player OSD.');
    expect(overlaySrc.contains("'\${clamped.round()}%'"), isTrue,
        reason: 'Volume HUD should show an explicit percentage.');

    final String overlay = region(
      'Widget _buildLevelHudOverlay() {',
      'Widget _buildOsdOverlay() {',
    );
    expect(overlay.contains('Positioned.fill'), isTrue);
    expect(overlay.contains('IgnorePointer'), isTrue,
        reason: 'The page-level level HUD must not steal subtitle/rail taps.');
    expect(overlay.contains('ValueListenableBuilder<_VideoLevelHudState?>'),
        isTrue);
    expect(overlay.contains('valueListenable: _levelHudNotifier'), isTrue);
    expect(overlay.contains('_VideoLevelHudKind.rightVolume'), isTrue);
    expect(overlay.contains('_buildRightVolumeIndicator(hud.value)'), isTrue);
  });

  test('left brightness HUD is screen-left and pointer transparent', () {
    final String indicator = region(
      'Widget _buildLeftBrightnessIndicator(double brightness) {',
      'Widget _buildLevelHudOverlay() {',
    );
    expect(indicator.contains('IgnorePointer'), isTrue,
        reason: 'Brightness HUD must never capture video pointers.');
    expect(indicator.contains('Alignment.centerLeft'), isTrue,
        reason: 'Brightness feedback belongs on the screen left.');
    expect(indicator.contains('_brightnessIconFor(clamped)'), isTrue);
    expect(indicator.contains('VideoLevelHudCard'), isTrue,
        reason:
            'Brightness HUD visible card should use the measurable helper.');
    expect(indicator.contains('frameKey: videoBrightnessHudFrameKey'), isTrue,
        reason:
            'Brightness HUD frame must stay separate from the volume HUD frame.');
    expect(overlaySrc.contains('LinearProgressIndicator'), isTrue,
        reason:
            'Brightness HUD should expose a percentage bar like a player OSD.');
    expect(overlaySrc.contains("'\${clamped.round()}%'"), isTrue,
        reason: 'Brightness HUD should show an explicit percentage.');

    final String overlay = region(
      'Widget _buildLevelHudOverlay() {',
      'Widget _buildOsdOverlay() {',
    );
    expect(overlay.contains('_VideoLevelHudKind.leftBrightness'), isTrue);
    expect(
        overlay.contains('_buildLeftBrightnessIndicator(hud.value)'), isTrue);
  });

  test('brightness callback shows page-level HUD before setting brightness',
      () {
    final String callback = region(
      'void _onMediaKitBrightnessChanged(double value) {',
      'Future<void> _ensureEnterBrightness() async {',
    );
    expect(callback.contains('if (!_brightness.canControl) return;'), isTrue);
    expect(callback.contains('_showBrightnessOsd(clamped * 100.0)'), isTrue);
    expect(callback.contains('unawaited(_brightness.setBrightness(clamped))'),
        isTrue);
    final int showIndex =
        callback.indexOf('_showBrightnessOsd(clamped * 100.0)');
    final int setIndex =
        callback.indexOf('unawaited(_brightness.setBrightness(clamped))');
    expect(showIndex, lessThan(setIndex),
        reason: 'Brightness HUD must show the gesture target immediately.');
  });

  test('generic OSD stays top-left and does not render volume HUD', () {
    final String osd = region(
      'Widget _buildOsdOverlay() {',
      'IconData _volumeIconFor(double volume) {',
    );
    expect(osd.contains('Alignment.topLeft'), isTrue,
        reason: 'Non-volume mpv-style OSD remains top-left.');
    expect(osd.contains('valueListenable: _osdNotifier'), isTrue);
    expect(osd.contains('_levelHudNotifier'), isFalse,
        reason: 'Generic OSD and level HUD must stay separate.');
  });

  // TODO-563 (复核更正): the volume/brightness level HUD and mpv-style OSD are
  // rendered by the shared controls builder, not by the page Stack alone. The
  // fullscreen Video sets `controls: params.controls`, which routes through
  // _buildVideoControls -> VideoControlsFocusGate -> _buildVideoControlsInner;
  // that inner builder mounts _buildLevelHudOverlay()/_buildOsdOverlay() with no
  // fullscreen gating, and VideoControlsFocusGate only unmounts on the WINDOW
  // side (`fullscreenRouteActive && !inFullscreenRoute`). So fullscreen already
  // renders the HUD via the shared controls — the fullscreen route must NOT
  // re-mount the overlays itself, or they double-stack. Lock that invariant.
  test('fullscreen route does not re-mount the page-level HUD overlays', () {
    expect(
      src.contains('_fullscreenContentWithOverlays'),
      isFalse,
      reason:
          'Fullscreen HUD comes from the shared controls builder; a fullscreen '
          'overlay re-mount helper would double-stack the level HUD / OSD.',
    );

    // The fullscreen route builder returns the bare video/subtitle-panel content
    // without stacking _buildLevelHudOverlay()/_buildOsdOverlay() a second time.
    final String route = region(
      'Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {',
      'void _onVideoFullscreenRouteClosed() {',
    );
    expect(route.contains('_buildLevelHudOverlay()'), isFalse,
        reason: 'Fullscreen route must not re-mount the level HUD; the shared '
            'controls builder already renders it on the fullscreen side.');
    expect(route.contains('_buildOsdOverlay()'), isFalse,
        reason:
            'Fullscreen route must not re-mount the OSD; the shared controls '
            'builder already renders it on the fullscreen side.');

    // The shared controls inner builder is the single owner that mounts both
    // overlays with no fullscreen gating (window + fullscreen both render them).
    final String inner = region(
      'Widget _buildVideoControlsInner(',
      'Widget _buildLevelHudOverlay() {',
    );
    expect(inner.contains('_buildLevelHudOverlay()'), isTrue,
        reason: 'Shared controls inner builder owns the level HUD mount.');
    expect(inner.contains('_buildOsdOverlay()'), isTrue,
        reason: 'Shared controls inner builder owns the OSD mount.');
  });
}
