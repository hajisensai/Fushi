import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for video mining context.
///
/// media_kit cannot be driven in headless widget tests here, but the regression
/// is in the ownership of the mining cue: the user clicks a subtitle sentence,
/// then may spend time in the dictionary popup before pressing mine. The audio
/// clip and GIF must use that lookup cue, not whatever cue is current later.
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

  test('video mining caches the cue at subtitle lookup time', () {
    expect(src.contains('AudioCue? _lastLookupCue'), isTrue,
        reason:
            'Video mining needs the subtitle cue from the original lookup.');

    final String lookup = region(
      'Future<void> _lookupAt(',
      'void _onDismissBarrierTap(',
    );
    expect(lookup.contains('_lastLookupCue = controller.currentCue'), isTrue,
        reason: 'Tapping a subtitle character must snapshot the current cue.');
  });

  test('video mining exports media from the cached lookup cue', () {
    final String mine = region(
      'Future<bool> onMineEntry(Map<String, String> fields) async {',
      'void _showAudioTrackMenu(VideoPlayerController controller) {',
    );
    expect(
      mine,
      contains(
          'final AudioCue? cue = _lastLookupCue ?? controller.currentCue;'),
      reason: 'Mining after the popup opens must not drift to a later cue.',
    );
    expect(mine, contains('startMs: cue.startMs'));
    expect(mine, contains('endMs: cue.endMs'));
    expect(mine, contains('cueSentence: cue?.text'));
  });
}
