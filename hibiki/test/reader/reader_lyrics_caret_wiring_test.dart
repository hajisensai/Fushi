import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// Source-scan guard: the lyrics-mode focus caret stays wired into the reader
/// page. JS runtime behaviour is covered by device integration tests; this
/// keeps the Dart plumbing from silently regressing.
///
/// TODO-387: the `CaretSurface` enum moved into the shared
/// [DictionaryCaretController]; this guard now asserts the enum lives there and
/// that the reader re-exports it, while the lyrics-specific JS wiring stays in
/// the reader page.
void main() {
  final String src = readReaderPageSource();
  final String controller = File(
    'lib/src/shortcuts/dictionary_caret_controller.dart',
  ).readAsStringSync();

  test('CaretSurface (with a lyrics value) lives in the shared controller', () {
    expect(
      controller,
      contains('enum CaretSurface { none, reader, popup, lyrics }'),
    );
  });

  test('reader re-exports CaretSurface so its references still resolve', () {
    expect(
      src,
      contains(
        "export 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart'",
      ),
    );
    expect(src, contains('show CaretSurface;'));
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
