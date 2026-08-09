import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-939 fix: opening the video "字幕" (subtitle track) category must
/// NOT re-run the ffprobe enumeration (`_subtitleSourcesForMenu`) every time, and
/// the control-bar「字幕轨」button must NOT clear the already-enumerated tracks and
/// re-enumerate them on every open.
///
/// The regression had two owners each running the full ffprobe enumeration on
/// every open with no memoization:
///   1. `_showSubtitleSourceMenu` set `_subtitleMenuSources = []` + loading=true
///      then re-enumerated → already-listed tracks visibly disappeared, then a
///      LinearProgressIndicator spun ("之前有的字幕还会消失，要等加载").
///   2. `_ensureSubtitleMenuSourcesLoaded` (fired by the panel opening the
///      subtitle category) re-enumerated unconditionally → a track-less video
///      still spun the loading bar on every open ("字幕轨要加载，明明根本没有可加载
///      的地方").
///
/// The fix makes `_ensureSubtitleMenuSourcesLoaded` the single enumeration owner,
/// memoized by video path (`_subtitleMenuSourcesPath`), and reduces
/// `_showSubtitleSourceMenu` to purely opening the settings panel. A source-level
/// guard is the strongest landing layer: the enumeration lives on private methods
/// of the ~7300-line `_VideoFushiPageState`, which cannot be stood up in a widget
/// test without a controller + ffprobe + DB.
void main() {
  final String subtitleSrc =
      File('lib/src/pages/implementations/video_fushi/subtitle.part.dart')
          .readAsStringSync();
  final String pageSrc =
      File('lib/src/pages/implementations/video_fushi_page.dart')
          .readAsStringSync();

  String methodBody(String source, String signatureNeedle) {
    final int start = source.indexOf(signatureNeedle);
    expect(start, greaterThanOrEqualTo(0),
        reason: 'Method "$signatureNeedle" must exist.');
    // Stop at the next top-level method indentation (`\n  Future` / `\n  void` /
    // `\n  Widget` / `\n  String` / `\n  bool` / `\n  List`) after the start.
    final RegExp nextMethod = RegExp(
      r'\n  (Future|void|Widget|String|bool|List|int)\b',
    );
    final Match? next =
        nextMethod.firstMatch(source.substring(start + signatureNeedle.length));
    final int end = next == null
        ? source.length
        : start + signatureNeedle.length + next.start;
    return source.substring(start, end);
  }

  test('_subtitleMenuSourcesPath cache field is declared (BUG-939)', () {
    expect(pageSrc.contains('String? _subtitleMenuSourcesPath'), isTrue,
        reason:
            'The per-video enumeration cache key must exist so the subtitle '
            'menu does not re-run ffprobe on every open (BUG-939).');
  });

  test(
      '_ensureSubtitleMenuSourcesLoaded short-circuits on cached path '
      '(BUG-939)', () {
    final String body = methodBody(
        subtitleSrc, 'Future<void> _ensureSubtitleMenuSourcesLoaded(');
    expect(
      body.contains('_subtitleMenuSourcesPath == videoPath'),
      isTrue,
      reason:
          'Must short-circuit when the current video is already enumerated, '
          'otherwise every subtitle-category open re-runs ffprobe and spins the '
          'loading bar (BUG-939).',
    );
    // On success it must record the path so the short-circuit engages next time.
    expect(
      body.contains('_subtitleMenuSourcesPath = videoPath'),
      isTrue,
      reason: 'Must record the enumerated video path on success (BUG-939).',
    );
  });

  test('_showSubtitleSourceMenu no longer self-enumerates (BUG-939)', () {
    final String body =
        methodBody(subtitleSrc, 'Future<void> _showSubtitleSourceMenu(');
    // The control-bar button must delegate enumeration to
    // _ensureSubtitleMenuSourcesLoaded; it must not call the ffprobe enumerator
    // directly (that path cleared + re-enumerated on every open → flicker).
    expect(
      body.contains('_subtitleSourcesForMenu('),
      isFalse,
      reason:
          '_showSubtitleSourceMenu must not re-run the ffprobe enumeration; '
          'it delegates to _ensureSubtitleMenuSourcesLoaded (BUG-939).',
    );
    // And it must not set the loading flag true (which drew the spinner on every
    // open of an already-enumerated / track-less video).
    expect(
      body.contains('_subtitleMenuLoading = true'),
      isFalse,
      reason: '_showSubtitleSourceMenu must not force the loading spinner on '
          'every open (BUG-939).',
    );
  });
}
