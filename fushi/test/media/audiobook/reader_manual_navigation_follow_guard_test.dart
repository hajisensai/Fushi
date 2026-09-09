import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

void main() {
  test('manual reader chapter navigation suppresses same-cue auto-follow', () {
    final String controllerSource = File(
            '../packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart')
        .readAsStringSync();
    final String readerSource = readReaderPageSource();

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
        r'Future<void> _navigateToChapter\(\s*int index,\s*\{[\s\S]*?double progress = 0\.0,[\s\S]*?bool manual = false,[\s\S]*?\}\) async \{',
      )),
      reason:
          'The chapter navigation API must keep a manual flag even if additional restore-position parameters are added.',
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
        // `manual: true` 后面既可能是尾逗号（多行实参）也可能直接收 `)`（单行）。
        // 原判据只认前者，于是 dart format 把这处调用收成一行之后就恒红——被钉死的
        // 是**格式**，不是行为。这里只放宽分隔符，progress: 0.99 与 manual: true
        // 两个真判据一字未动。
        r'_navigateToChapter\(\s*_currentChapter - 1,\s*progress: 0\.99,\s*manual: true\s*[,)]',
        multiLine: true,
      )),
      reason: 'Reverse chapter-edge page turns are user-initiated.',
    );
    // BUG-2385：目录点击与书内链接现在共用同一个落地口 _jumpToChapterAnchor，
    // 「用户发起」的判据随之搬进那个 helper —— 不变式没变（两条路径都 manual），
    // 变的是它写在哪里。这里钉住入口 + helper 内部两侧，避免哪一天 helper 悄悄
    // 把 manual 丢了。
    expect(
      readerSource,
      contains('await _jumpToChapterAnchor(link.chapterIndex, link.fragment);'),
      reason: 'Internal links must go through the shared anchor entry point.',
    );
    expect(
      readerSource,
      matches(RegExp(
        r'Future<void> _jumpToChapterAnchor\([\s\S]*?'
        r'_navigateToChapter\(index, manual: true\);[\s\S]*?'
        r'_jumpToFragmentInPlace\(fragment\);[\s\S]*?'
        r'_navigateToChapterWithFragment\(index, fragment, manual: true\);',
        multiLine: true,
      )),
      reason: 'Internal TOC/link jumps are user-initiated.',
    );
  });
}
