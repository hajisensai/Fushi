import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for mpv/asbplayer-style volume feedback.
///
/// The real volume keys are owned by media_kit and platform input, so this
/// locks the video page invariant: volume changes must use a right-side HUD
/// with a recognizable volume icon and percentage progress. Non-volume OSDs
/// stay on the legacy top-left mpv-style channel.
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue);
    src = page.readAsStringSync();
  });

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('volume changes use a dedicated right-side HUD helper', () {
    expect(src.contains('void _showVolumeOsd(double volume)'), isTrue,
        reason: 'Volume adjustments need a dedicated visible OSD treatment.');
    expect(
        src.contains('final ValueNotifier<double?> _volumeHudNotifier'), isTrue,
        reason:
            'Volume HUD visibility/value must be independent from _osdNotifier.');
    expect(src.contains('Timer? _volumeHudTimer'), isTrue,
        reason: 'Volume HUD needs its own auto-hide timer.');

    final String adjust = region(
      'Future<void> _adjustVolume(double delta) async {',
      'Future<void> _toggleMute() async {',
    );
    expect(adjust.contains('_showVolumeOsd(next)'), isTrue);

    final String mute = region(
      'Future<void> _toggleMute() async {',
      'void _showVolumeOsd(double volume) {',
    );
    expect(mute.contains('_showVolumeOsd('), isTrue,
        reason: 'Mute/unmute should use the same volume visual language.');

    final String volumeHud = region(
      'void _showVolumeOsd(double volume) {',
      'void _onMediaKitVolumeChanged(double value) {',
    );
    expect(volumeHud.contains('_volumeHudNotifier.value'), isTrue,
        reason: 'Volume changes should drive the right-side HUD notifier.');
    expect(volumeHud.contains('_volumeHudTimer'), isTrue,
        reason: 'Volume HUD should auto-hide independently.');
    expect(volumeHud.contains('_showOsd('), isFalse,
        reason: 'Volume feedback must not reuse the top-left generic OSD.');
  });

  test('right volume HUD is screen-right and pointer transparent', () {
    final String indicator = region(
      'Widget _buildRightVolumeIndicator(double volume) {',
      'Widget _buildVolumeHudOverlay() {',
    );
    expect(indicator.contains('IgnorePointer'), isTrue,
        reason: 'Shared HUD indicator must never capture video pointers.');
    expect(indicator.contains('Alignment.centerRight'), isTrue,
        reason: 'Volume feedback belongs on the screen right.');
    expect(indicator.contains('_volumeIconFor(clamped)'), isTrue);
    expect(indicator.contains('LinearProgressIndicator'), isTrue,
        reason: 'Volume HUD should expose a percentage bar like a player OSD.');
    expect(indicator.contains("Text('\${clamped.round()}%')"), isTrue,
        reason: 'Volume HUD should show an explicit percentage.');

    final String overlay = region(
      'Widget _buildVolumeHudOverlay() {',
      'Widget _buildOsdOverlay() {',
    );
    expect(overlay.contains('Positioned.fill'), isTrue);
    expect(overlay.contains('IgnorePointer'), isTrue,
        reason: 'The page-level volume HUD must not steal subtitle/rail taps.');
    expect(overlay.contains('ValueListenableBuilder<double?>'), isTrue);
    expect(overlay.contains('valueListenable: _volumeHudNotifier'), isTrue);
    expect(overlay.contains('_buildRightVolumeIndicator(volume)'), isTrue);
  });

  test('generic OSD stays top-left and does not render volume HUD', () {
    final String osd = region(
      'Widget _buildOsdOverlay() {',
      'Widget _buildSideLockButton() {',
    );
    expect(osd.contains('Alignment.topLeft'), isTrue,
        reason: 'Non-volume mpv-style OSD remains top-left.');
    expect(osd.contains('valueListenable: _osdNotifier'), isTrue);
    expect(osd.contains('_volumeHudNotifier'), isFalse,
        reason: 'Generic OSD and right-side volume HUD must stay separate.');
  });
}
