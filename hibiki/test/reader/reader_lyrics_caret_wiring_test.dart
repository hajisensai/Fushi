import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard: the lyrics-mode focus caret stays wired into the reader
/// page. JS runtime behaviour is covered by device integration tests; this
/// keeps the Dart plumbing from silently regressing.
void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test('CaretSurface has a lyrics value', () {
    expect(src, contains('enum CaretSurface { none, reader, popup, lyrics }'));
  });

  test('lyrics page load injects the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.source()'));
    expect(src, contains('ReaderLyricsCaretScripts.initInvocation('));
  });

  test('enter/exit toggle the playback-follow suppression flag', () {
    expect(src, contains('window.__lyricsCaretActive = true;'));
    expect(src, contains('window.__lyricsCaretActive = false;'));
  });

  test('caret actions branch to the lyrics caret', () {
    expect(src, contains('ReaderLyricsCaretScripts.moveInvocation'));
    expect(src, contains('ReaderLyricsCaretScripts.lookupInvocation'));
    expect(src, contains('_caretOnLyrics'));
  });

  test('leaving lyrics mode resets the caret surface', () {
    expect(src, contains('if (_caretSurface == CaretSurface.lyrics)'));
  });
}
