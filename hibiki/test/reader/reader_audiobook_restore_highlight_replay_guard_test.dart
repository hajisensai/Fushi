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

  test('TODO-718：cue 位置只在 reveal（权威驱动视图）时覆盖落库阅读位置，被动高亮不覆盖', () {
    // 真因：_onCueChanged 结尾**无条件** _syncPositionFromCurrentCue()，重开 / 暂停态把当前
    // cue 高亮上去（reveal=false）也会把恢复好的滚动位置覆盖成暂停中的音频 cue 位置（真机：
    // restore=244 被 cue ns=995 覆盖成 440、charOffset 退化成 -1）→ 每次重开回到那条固定 cue。
    final String onCueChanged = _functionSource(
      readerSource,
      'void _onCueChanged() {',
      'Future<void> _handleCueCrossChapter',
    );
    // 末尾的逐句 highlight 调用之后，位置同步必须被 `if (reveal)` 包住——而不是裸调用。
    final int hlIndex = onCueChanged.lastIndexOf('AudiobookBridge.highlight(');
    final String tail = onCueChanged.substring(hlIndex);
    final int syncIndex = tail.indexOf('_syncPositionFromCurrentCue()');
    expect(syncIndex, isNonNegative,
        reason: '末尾仍须有位置同步（reveal 为真时用 cue 落库，不回归 724）');
    final int guardIndex = tail.indexOf('if (reveal)');
    expect(guardIndex, isNonNegative,
        reason: 'cue 位置覆盖必须门控在 reveal 内（被动高亮不得覆盖用户滚动位置）');
    expect(guardIndex, lessThan(syncIndex),
        reason: 'if (reveal) 必须在 _syncPositionFromCurrentCue() 之前包住它');
    // 末尾的位置同步不得是脱离 reveal 门的裸调用。
    expect(tail, isNot(contains('    );\n    _syncPositionFromCurrentCue();')),
        reason: '位置同步不得在 highlight 之后裸调用（必须在 if (reveal) 块内）');
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
