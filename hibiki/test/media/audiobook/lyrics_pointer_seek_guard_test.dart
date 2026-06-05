import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard: lyrics mode must wire a non-left mouse button to
/// onLyricsPointerSeek using the cue element's data-cue-index. Standard `click`
/// never fires for the middle button, so a dedicated `mousedown` listener is
/// required — this guard prevents it from being dropped.
void main() {
  test('lyrics html wires middle-button seek via data-cue-index', () {
    final src = File('lib/src/media/audiobook/lyrics_mode_html.dart')
        .readAsStringSync();
    expect(src.contains("'mousedown'"), isTrue);
    expect(src.contains("callHandler('onLyricsPointerSeek'"), isTrue);
    expect(src.contains('data-cue-index'), isTrue);
  });
}
