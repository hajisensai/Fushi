import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

void main() {
  test('reader exposes stable automation hooks for lyrics-mode device tests',
      () {
    final String source = readReaderPageSource();

    expect(source, contains('debugOpenQuickSettings'));
    expect(source, contains('debugToggleLyricsMode'));
    expect(source, contains('debugLyricsModeReady'));
    expect(source, contains("ValueKey<String>('fushi_lyrics_ready')"));
    expect(source, contains("identifier: 'hibiki.reader.lyrics.ready'"));
    expect(source, contains('debugOpenQuickSettings = null'));
    expect(source, contains('debugToggleLyricsMode = null'));
    expect(source, contains('debugLyricsModeReady = null'));
  });

  test('settings and lyrics-mode controls expose native accessibility ids', () {
    final String readerSource = readReaderPageSource();
    final String quickSettingsSource =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    final String playBarSource =
        File('lib/src/media/audiobook/audiobook_play_bar.dart')
            .readAsStringSync();

    // 2026-09-13 阅读器 chrome 重做后设置齿轮是 ReaderControlLayout 的一个 item，
    // 语义 id 经 ReaderHeaderAction.semanticsId → ReaderDesktopHeaderButton 落成
    // Semantics(identifier:)；两段合起来才是「真落地」，缺一段都只是字符串。
    expect(
      readerSource,
      contains("semanticsId: 'hibiki.reader.bottom.settings'"),
      reason: 'XCUITest needs a stable id for the non-audiobook settings gear.',
    );
    expect(
      File('lib/src/reader/reader_desktop_chrome.dart').readAsStringSync(),
      contains('Semantics(identifier: semanticsId'),
      reason: 'semanticsId 必须由 ReaderDesktopHeaderButton 真落成 Semantics 节点。',
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
