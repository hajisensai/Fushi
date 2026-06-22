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
    // TODO-724：highlight 调用从单行扩成多行并新增 pauseEnabled(imagePauseSec>0) 形参，
    // 但「follow audio 只控制 reveal、不门控 highlight 调用本身」的契约不变——
    // highlight 仍以 `cue: cue` + `reveal: reveal` 无条件调用。守卫改断言这两个具名实参
    // 同时出现在 highlight( 调用里，不再钉死单行字面量。
    // _onCueChanged 里有多处 AudiobookBridge.highlight(（跨章清空高亮的裸调用在前），
    // 真正带 cue 的逐句高亮调用在最后——用 lastIndexOf 定位它。
    final int hlIndex = onCueChanged.lastIndexOf('AudiobookBridge.highlight(');
    expect(hlIndex, isNonNegative,
        reason: 'highlight must be called even when follow audio makes reveal '
            'false');
    final int hlEnd = (hlIndex + 200).clamp(0, onCueChanged.length);
    final String hlCall = onCueChanged.substring(hlIndex, hlEnd);
    expect(hlCall, contains('cue: cue'), reason: 'highlight 仍须传当前 cue');
    expect(hlCall, contains('reveal: reveal'),
        reason:
            'reveal 由 forceReveal||shouldRevealCurrentCue 决定，仍透传给 highlight');
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
