import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';

void main() {
  test('Aa more opens lyrics despite a remembered lookup tab', () {
    final List<ReaderSettingsTab> tabs = readerSettingsTabs(
      lyricsMode: true,
      listeningEnabled: true,
    );
    expect(
      readerSettingsInitialTab(
        tabs,
        remembered: 'lookup',
        lyricsMode: true,
        requested: 'lyrics',
      ),
      ReaderSettingsTab.lyrics,
    );
    // 普通入口沿用查词页记忆，定向打开不篡改共享会话记忆。
    expect(
      readerSettingsInitialTab(tabs, remembered: 'lookup', lyricsMode: true),
      ReaderSettingsTab.lookup,
    );
  });

  test('unavailable or unknown target preserves the valid remembered tab', () {
    final List<ReaderSettingsTab> tabs = readerSettingsTabs(
      lyricsMode: false,
      listeningEnabled: false,
    );
    for (final String requested in <String>['lyrics', 'unknown']) {
      expect(
        readerSettingsInitialTab(
          tabs,
          remembered: 'behavior',
          lyricsMode: false,
          requested: requested,
        ),
        ReaderSettingsTab.gestures,
      );
    }
  });
}
