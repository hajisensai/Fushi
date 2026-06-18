import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for mpv/asbplayer-style volume and brightness feedback.
///
/// The real volume keys are owned by media_kit and platform input, so this
/// locks the video page invariant: volume and brightness changes must use the
/// Hibiki page-level level HUD for about 1.6s. Non-volume/brightness OSDs stay
/// on the legacy top-left mpv-style channel.
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
    expect(indicator.contains('LinearProgressIndicator'), isTrue,
        reason: 'Volume HUD should expose a percentage bar like a player OSD.');
    expect(indicator.contains("Text('\${clamped.round()}%')"), isTrue,
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
    expect(indicator.contains('LinearProgressIndicator'), isTrue,
        reason:
            'Brightness HUD should expose a percentage bar like a player OSD.');
    expect(indicator.contains("Text('\${clamped.round()}%')"), isTrue,
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
      'Widget _buildSideLockButton() {',
    );
    expect(osd.contains('Alignment.topLeft'), isTrue,
        reason: 'Non-volume mpv-style OSD remains top-left.');
    expect(osd.contains('valueListenable: _osdNotifier'), isTrue);
    expect(osd.contains('_levelHudNotifier'), isFalse,
        reason: 'Generic OSD and level HUD must stay separate.');
  });
}
