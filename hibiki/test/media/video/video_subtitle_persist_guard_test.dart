import 'package:flutter_test/flutter_test.dart';
import '../../pages/video_hibiki_page_source_corpus.dart';

/// BUG-081 source guard: when the user manually loads/switches a subtitle for a
/// single video at runtime, the parsed cues must be persisted (repo.saveCues)
/// so re-opening the video restores them via `_loadSingle`'s `loadCues`. The
/// initial-import dialog already does this; the runtime path used to skip it.
/// Persisting is gated to single videos (`_episodes.isEmpty`) — playlists
/// intentionally re-parse each episode from disk.
///
/// media_kit cannot run headless, so this locks the call-site invariant rather
/// than driving a real player (the saveCues/loadCues DB round-trip itself is
/// covered by video_book_repository_test.dart).
void main() {
  final String src = readVideoHibikiSource();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test(
      '_selectSubtitleSource persists cues+source atomically for single videos',
      () {
    final String body = region(
      'Future<bool> _selectSubtitleSource(',
      'Future<void> _selectSubtitleOff(',
    );
    expect(body.contains('_episodes.isEmpty'), isTrue,
        reason: 'cue persistence must be gated to single videos');
    expect(body.contains('saveSubtitleSelection('), isTrue,
        reason: 'parsed cues + source must be saved atomically (W1) so re-open '
            'restores them consistently');
  });

  test('_selectSubtitleOff clears persisted cues for single videos', () {
    final String body = region(
      'Future<void> _selectSubtitleOff(',
      'Widget _subtitleJumpSidePanel(',
    );
    expect(body.contains('_episodes.isEmpty'), isTrue);
    expect(body.contains('saveSubtitleSelection('), isTrue,
        reason: 'turning subtitles off must clear DB cues, else they return');
  });
}
