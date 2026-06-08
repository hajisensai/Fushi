import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual reader chapter navigation suppresses same-cue auto-follow', () {
    final String controllerSource = File(
            '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart')
        .readAsStringSync();
    final String readerSource =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();

    expect(
      controllerSource,
      contains('AudioCue? _manualReaderOverrideCue;'),
      reason:
          'The controller should remember the cue that was current when the reader was manually moved.',
    );
    expect(
      controllerSource,
      contains('void noteManualReaderNavigation()'),
      reason:
          'Manual reader navigation needs a distinct API instead of only clearing the transition guard.',
    );
    expect(
      controllerSource,
      contains(
          'if (!bypassPlayGuard && _isManualReaderOverrideCue(cue)) return;'),
      reason:
          'The same cue must not immediately emit another cross-chapter request after a manual reader jump.',
    );
    expect(
      controllerSource,
      contains(
          '_manualReaderOverrideCue = null;\n    _forceNextReveal = true;'),
      reason:
          'Explicit snap/follow actions should resume normal audio-follow behavior.',
    );

    expect(
      readerSource,
      matches(RegExp(
        r'Future<void> _navigateToChapter\(\s*int index,\s*\{\s*double progress = 0\.0,\s*bool manual = false,',
        multiLine: true,
      )),
    );
    expect(
      readerSource,
      contains(
          'if (manual) {\n      _audiobookController?.noteManualReaderNavigation();\n    }'),
    );
    expect(
      readerSource,
      contains('_navigateToChapter(index, manual: true);'),
      reason:
          'TOC jumps are user-initiated and should not be hijacked by subtitle follow.',
    );
    expect(
      readerSource,
      contains('_navigateToChapter(_currentChapter + 1, manual: true);'),
      reason: 'Chapter-edge page turns are user-initiated.',
    );
    expect(
      readerSource,
      matches(RegExp(
        r'_navigateToChapter\(\s*_currentChapter - 1,\s*progress: 0\.99,\s*manual: true,',
        multiLine: true,
      )),
      reason: 'Reverse chapter-edge page turns are user-initiated.',
    );
    expect(
      readerSource,
      matches(RegExp(
        r'_navigateToChapterWithFragment\(\s*link\.chapterIndex,\s*link\.fragment,\s*manual: true,',
        multiLine: true,
      )),
      reason: 'Internal TOC/link jumps are user-initiated.',
    );
  });
}
