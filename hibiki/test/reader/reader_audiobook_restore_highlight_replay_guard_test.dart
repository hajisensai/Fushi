import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

void main() {
  late String readerSource;
  late String controllerSource;

  setUpAll(() {
    readerSource = readReaderPageSource();
    controllerSource = File(
      '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();
  });

  test('section restore completion replays unchanged current cue highlight',
      () {
    final String restore = _functionSource(
      controllerSource,
      'void notifySectionRestoreCompleted({',
      'void cancelChapterTransition()',
    );
    expect(
      restore,
      contains('_updateCurrentCue(_player.position.inMilliseconds, '
          'forceNotify: success)'),
      reason: 'after reader restore, the same current cue must notify again so '
          'the WebView can replay highlight after cue maps are rebuilt',
    );

    final String update = _functionSource(
      controllerSource,
      'void _updateCurrentCue(int posMs, {bool forceNotify = false})',
      'bool get shouldRevealCurrentCue',
    );
    final int sameCueIndex =
        update.indexOf('if (chapterIdx == _currentCueIndex)');
    final int forceNotifyIndex =
        update.indexOf('if (forceNotify)', sameCueIndex);
    final int returnIndex = update.indexOf('return;', sameCueIndex);
    expect(sameCueIndex, isNonNegative);
    expect(forceNotifyIndex, greaterThan(sameCueIndex));
    expect(forceNotifyIndex, lessThan(returnIndex),
        reason: 'same-cue restore replay must happen before the unchanged-cue '
            'early return');
    expect(update.substring(forceNotifyIndex, returnIndex),
        contains('notifyListeners()'));
  });

  test('follow audio controls reveal only, not whether cue is highlighted', () {
    final String onCueChanged = _functionSource(
      readerSource,
      'void _onCueChanged() {',
      'Future<void> _handleCueCrossChapter',
    );

    expect(onCueChanged, contains('controller.shouldRevealCurrentCue'));
    expect(
      onCueChanged,
      contains(
          'AudiobookBridge.highlight(_controller!, cue: cue, reveal: reveal)'),
      reason:
          'highlight must be called even when follow audio makes reveal false',
    );
    expect(
      onCueChanged,
      isNot(contains('if (controller.shouldRevealCurrentCue) {\n'
          '      AudiobookBridge.highlight')),
      reason: 'follow audio must not gate the highlight call itself',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
