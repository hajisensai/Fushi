import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('reader exposes stable automation hooks for lyrics-mode device tests',
      () {
    final String source = readReaderPageSource();

    expect(source, contains('debugOpenQuickSettings'));
    expect(source, contains('debugToggleLyricsMode'));
    expect(source, contains('debugLyricsModeReady'));
    expect(source, contains('debugLyricsModeDiagnostics'));
    expect(source, contains("ValueKey<String>('hoshi_lyrics_ready')"));
    expect(source, contains("identifier: 'hibiki.reader.lyrics.ready'"));
    expect(source, contains('debugOpenQuickSettings = null'));
    expect(source, contains('debugToggleLyricsMode = null'));
    expect(source, contains('debugLyricsModeReady = null'));
    expect(source, contains('debugLyricsModeDiagnostics = null'));
  });

  test('settings and lyrics-mode controls expose native accessibility ids', () {
    final String readerSource = readReaderPageSource();
    final String quickSettingsSource =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String playBarSource =
        File('lib/src/media/audiobook/audiobook_play_bar.dart')
            .readAsStringSync();

    expect(
      readerSource,
      contains("identifier: 'hibiki.reader.bottom.settings'"),
      reason: 'XCUITest needs a stable id for the non-audiobook settings gear.',
    );
    expect(
      playBarSource,
      contains("semanticsIdentifier: 'hibiki.reader.audiobook.settings'"),
      reason: 'XCUITest needs a stable id for the audiobook settings gear.',
    );
    expect(playBarSource, contains('identifier: semanticsIdentifier'));
    expect(
      quickSettingsSource,
      contains("identifier: 'hibiki.reader.quick_settings.lyrics_toggle'"),
      reason: 'XCUITest/Appium need a stable id for the lyrics-mode action.',
    );
  });
}
