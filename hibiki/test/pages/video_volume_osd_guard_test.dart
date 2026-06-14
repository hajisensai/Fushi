import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for mpv/asbplayer-style volume feedback.
///
/// The real volume keys are owned by media_kit and platform input, so this
/// locks the video page invariant: volume changes must show an OSD with a
/// recognizable volume icon and percentage progress, not just a text string.
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

  test('volume changes use a dedicated icon OSD helper', () {
    expect(src.contains('void _showVolumeOsd(double volume)'), isTrue,
        reason: 'Volume adjustments need a dedicated visible OSD treatment.');

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
  });

  test('OSD rendering supports icons and progress for volume', () {
    final int start = src.indexOf('Widget _buildOsdOverlay() {');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'missing Widget _buildOsdOverlay()');
    final String osd = src.substring(start);
    expect(osd.contains('Icon('), isTrue,
        reason: 'The OSD should render an icon when the message carries one.');
    expect(osd.contains('LinearProgressIndicator'), isTrue,
        reason: 'Volume OSD should expose a percentage bar like a player OSD.');
    expect(osd.contains('Icons.volume_up'), isTrue);
    expect(osd.contains('Icons.volume_down'), isTrue);
    expect(osd.contains('Icons.volume_off'), isTrue);
  });
}
