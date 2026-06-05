import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard: the reader page must wire the non-left mouse button to
/// the seek-to-clicked-sentence path (JS mousedown → onPointerSeek →
/// resolveMouse gate → cueIdAtPoint → playCueAndContinue). Prevents a refactor
/// from silently dropping the middle-click seek or its binding gate.
void main() {
  final src = File('lib/src/pages/implementations/reader_hibiki_page.dart')
      .readAsStringSync();

  test('reader page reports non-left mouse button via onPointerSeek', () {
    expect(src.contains("'mousedown'"), isTrue);
    expect(src.contains("callHandler('onPointerSeek'"), isTrue);
    expect(src.contains("handlerName: 'onPointerSeek'"), isTrue);
  });

  test('onPointerSeek is gated by the configurable mouse binding', () {
    expect(src.contains('isSeekToClickedSentenceButton'), isTrue);
  });

  test('reader seek path uses cueIdAtPoint reverse lookup and plays the cue',
      () {
    expect(src.contains('cueIdAtPoint'), isTrue);
    expect(src.contains('cueForPointerPayload'), isTrue);
    expect(src.contains('playCueAndContinue'), isTrue);
  });

  test('lyrics seek path resolves the cue via cueForLyricsPointer', () {
    expect(src.contains('cueForLyricsPointer'), isTrue);
  });
}
