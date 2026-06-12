import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('lookup audio volume wiring', () {
    test('all lookup playback paths pass the configured gain to TtsChannel',
        () {
      final Map<String, String> sources = <String, String>{
        'base source': _read('lib/src/pages/base_source_page.dart'),
        'dictionary page': _read(
          'lib/src/pages/implementations/dictionary_page_mixin.dart',
        ),
        'popup webview': _read(
          'lib/src/pages/implementations/dictionary_popup_webview.dart',
        ),
      };

      for (final MapEntry<String, String> entry in sources.entries) {
        expect(
          entry.value,
          contains('lookupAudioVolumeGain'),
          reason: '${entry.key} must read the lookup audio volume setting',
        );
        expect(
          entry.value,
          contains('playAudioRef('),
          reason: '${entry.key} must pass the configured volume to playback',
        );
        expect(
          entry.value,
          contains('volume: ReaderHibikiSource.instance.lookupAudioVolumeGain'),
          reason: '${entry.key} must pass the configured volume to playback',
        );
      }
    });

    test('TtsChannel forwards volume to platform playback', () {
      final String channel = _read('lib/src/utils/misc/tts_channel.dart');

      expect(channel, contains('Future<bool> playAudioRef('));
      expect(channel, contains('double volume = 1.0'));
      expect(channel, contains("'volume':"));
      expect(channel, contains('DesktopAudioPlayback.playUrl(url, volume:'));
      expect(
          channel, contains('DesktopAudioPlayback.playFile(filePath, volume:'));
    });

    test('Android and desktop audio backends apply volume before playback', () {
      final String desktop =
          _read('lib/src/utils/misc/desktop_audio_playback.dart');
      final String android = _read(
        'android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java',
      );

      expect(desktop, contains('_player.setVolume(volume.clamp(0.0, 1.0))'));
      expect(android, contains('mediaPlayer.setVolume(volume, volume)'));
    });

    test('only automatic lookup playback is routed through the dedupe gate',
        () {
      final String baseSource = _read('lib/src/pages/base_source_page.dart');
      final String dictionaryPage = _read(
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      );
      final String popupWebView = _read(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );

      expect(
        baseSource,
        contains('LookupAutoReadCoordinator.instance.runAutomatic'),
        reason: 'reader/source auto-read must use the shared dedupe gate',
      );
      expect(
        dictionaryPage,
        contains('LookupAutoReadCoordinator.instance.runAutomatic'),
        reason: 'dictionary/video auto-read must use the shared dedupe gate',
      );
      expect(
        popupWebView,
        isNot(contains('LookupAutoReadCoordinator')),
        reason: 'manual popup audio buttons must remain replayable',
      );
    });
  });
}
