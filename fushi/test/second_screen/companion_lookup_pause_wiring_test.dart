import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';
import '../pages/video_fushi_page_source_corpus.dart';

/// Pause on lookup with the dual-screen companion (reader audiobook, video).
///
/// Root cause of the user report: the pause sat only in each page's in-page
/// popup path, after the early `return` that hands the lookup to the
/// companion, and the resume hung off the popup closing. Now each page has
/// one pause entry and one release used by both its popup and the companion
/// (`CompanionContextRegistry.lookupOpened` / `lookupClosed` through the
/// claim). The reader (WebView) and the video page (media_kit) cannot run
/// headless, so their wiring is guarded here; the registry, bridge, hooks and
/// the music page have behaviour tests.
void main() {
  group('reader (audiobook view)', () {
    final String src = maskComments(readReaderPageSource());

    test('popup and companion share the "pause on lookup" entry', () {
      final String select = methodBody(
        src,
        'Future<void> _handleTextSelected(ReaderSelectionData data) async {',
      );
      final int routed = select.indexOf('_routeLookupToCompanion(data)');
      final int pause = select.indexOf('_pauseForLookup();');
      expect(routed, isNonNegative);
      expect(pause, greaterThan(routed), reason: 'popup path after routing');
      expect(select, isNot(contains('abc.pause()')), reason: 'no second copy');

      final String entry = methodBody(src, 'void _pauseForLookup() {');
      expect(entry, contains('ReaderFushiSource.instance.pauseOnLookup'));
      expect(entry, contains('_pausedForLookup = true'));

      final String opened = methodBody(src, 'void lookupOpened() {');
      expect(opened, contains('_state._pauseForLookup()'));
    });

    test('each surface resumes only when the other one is closed', () {
      final String popupClosed = methodBody(src, 'void _clearLookupState() {');
      expect(popupClosed, contains('_companion.lookupOpen'));
      expect(popupClosed, contains('_releaseLookupPause(resume: true)'));

      final String companionClosed = methodBody(
        src,
        'void _companionLookupClosed({required bool resume}) {',
      );
      expect(companionClosed, contains('dictionaryPopupShown'));
      expect(companionClosed, contains('_releaseLookupPause(resume: resume)'));

      final String release = methodBody(
        src,
        'void _releaseLookupPause({required bool resume}) {',
      );
      // The resume keeps the in-flight hold the lyrics overlay reads.
      expect(release, contains('_lookupResumeInFlight = true'));
      expect(release, contains('lookupResumeHoldReleased('));
    });
  });

  group('video', () {
    final String src = maskComments(readVideoFushiSource());

    test('popup, caret and companion share the pause entry', () {
      final String lookupAt = methodBody(src, 'Future<void> _lookupAt(');
      expect(
        lookupAt.indexOf('_pauseForLookup();'),
        greaterThan(lookupAt.indexOf('routeCompanionLookup(')),
      );
      final String caret = methodBody(
        src,
        'void _enterSubtitleCaret(VideoPlayerController controller) {',
      );
      expect(caret, contains('_pauseForLookup();'));
      final String opened = methodBody(src, 'void lookupOpened() {');
      expect(opened, contains('_state._pauseForLookup()'));
    });

    test('the companion lookup holds the pause against popup / caret '
        'closing; its close uses the same resume rule', () {
      final String caretEnd = methodBody(
        src,
        'void _finishSubtitleCaretSession({required bool resume}) {',
      );
      expect(caretEnd, contains('!_companionHook.lookupOpen'));
      final String closed = methodBody(
        src,
        'void _companionLookupClosed({required bool resume}) {',
      );
      expect(
        closed,
        contains('VideoFushiPage.shouldResumeAfterLookupDismiss('),
      );
      expect(closed, contains('caretHoldsPause: _videoCaretActive'));
      expect(closed, contains('if (resume)'));
      expect(closed, contains('resumePlayback()'));
    });
  });
}
