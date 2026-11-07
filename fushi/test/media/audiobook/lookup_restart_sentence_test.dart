import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lookup_resume_hold.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

/// 「查词后从句首重播」：查词暂停后关弹窗，从被查词所在句的句首重播，而不是原地续播。
///
/// 判据 [lookupRestartCue] 是纯函数，直接测；阅读器接线（`_clearLookupState`）是
/// 整页 WebView 状态机，用源码守卫咬住两条不能退化的约束：
/// 1. 恢复必须经 [lookupRestartCue] 决定，关掉开关时仍是原地 `play()`；
/// 2. 重播走「`skipToCue` 再 `play()`」，不走 `playCueAndContinue`——后者的 Future
///    在起播前就完成，会让查词按住（`lookupResumeHoldReleased`）提前撤掉。
void main() {
  AudioCue cue(int i) => AudioCue()
    ..sentenceIndex = i
    ..text = 's$i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900;

  group('lookupRestartCue', () {
    test('off: resume in place', () {
      expect(
        lookupRestartCue(
          restartEnabled: false,
          alreadyPlaying: false,
          lookupCue: cue(2),
          currentCue: cue(3),
        ),
        isNull,
      );
    });

    test(
      'on: replays the looked-up sentence, even if playback moved past it',
      () {
        final AudioCue looked = cue(2);
        expect(
          lookupRestartCue(
            restartEnabled: true,
            alreadyPlaying: false,
            lookupCue: looked,
            currentCue: cue(3),
          ),
          same(looked),
        );
      },
    );

    test('on, looked-up sentence unknown: replays the paused sentence', () {
      final AudioCue current = cue(3);
      expect(
        lookupRestartCue(
          restartEnabled: true,
          alreadyPlaying: false,
          lookupCue: null,
          currentCue: current,
        ),
        same(current),
      );
    });

    test('on, no sentence at all: resume in place', () {
      expect(
        lookupRestartCue(
          restartEnabled: true,
          alreadyPlaying: false,
          lookupCue: null,
          currentCue: null,
        ),
        isNull,
      );
    });

    test('on, user already resumed inside the popup: do not jump again', () {
      expect(
        lookupRestartCue(
          restartEnabled: true,
          alreadyPlaying: true,
          lookupCue: cue(2),
          currentCue: cue(5),
        ),
        isNull,
      );
    });
  });

  group('reader wiring', () {
    final String lookup = File(
      'lib/src/pages/implementations/reader_fushi/lookup.part.dart',
    ).readAsStringSync();

    test('popup close decides the resume point through lookupRestartCue', () {
      final String body = maskComments(
        methodBody(lookup, 'void _clearLookupState()'),
      );
      expect(body, contains('lookupRestartCue('));
      expect(body, contains('restartSentenceAfterLookup'));
      expect(body, contains('ctrl.play()'), reason: '开关关闭时仍原地续播');
      expect(body, contains('_resumeLookupFromSentence('));
      expect(body, contains('lookupResumeHoldReleased('));
    });

    test('restart seeks then calls play(), not playCueAndContinue', () {
      final String body = maskComments(
        methodBody(lookup, 'Future<void> _resumeLookupFromSentence('),
      );
      final int seek = body.indexOf('ctrl.skipToCue(');
      final int play = body.indexOf('ctrl.play()');
      expect(seek, greaterThanOrEqualTo(0));
      expect(play, greaterThan(seek), reason: '先定位到句首再起播');
      expect(body, isNot(contains('playCueAndContinue')));
    });

    test(
      'the looked-up sentence is remembered only while paused for lookup',
      () {
        final String body = maskComments(
          methodBody(
            lookup,
            'Future<void> _handleTextSelected(ReaderSelectionData data)',
          ),
        );
        final RegExp remember = RegExp(
          r'if \(_pausedForLookup\) _lookupRestartCue = _lookupCue;',
        );
        // 正文与歌词两条分支各记一次。
        expect(remember.allMatches(body).length, 2);
      },
    );
  });
}
