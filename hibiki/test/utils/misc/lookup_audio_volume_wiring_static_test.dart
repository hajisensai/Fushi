import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('lookup audio volume wiring', () {
    test('all lookup playback paths pass the configured gain to TtsChannel',
        () {
      // 自动发音的 gain 接线收口在 playLookupAudio（lookup_audio_playback.dart）；
      // reader/source（base）与 dictionary/video（mixin）都转调它，不再各自手抄一份
      // playAudioRef + gain。popup webview 的手动发音按钮另走自己的路径（仍带 gain）。
      final String playback =
          _read('lib/src/utils/misc/lookup_audio_playback.dart');
      expect(playback, contains('lookupAudioVolumeGain'),
          reason: 'playLookupAudio must read the lookup audio volume setting');
      expect(playback, contains('playAudioRef('));
      expect(
        playback,
        contains('volume: ReaderHibikiSource.instance.lookupAudioVolumeGain'),
        reason: 'playLookupAudio must pass the configured volume to playback',
      );

      // base/mixin 经 playLookupAudio 转调（gain 接线随之统一到上面那一处）。
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        expect(_read(path), contains('playLookupAudio('),
            reason: '$path auto-read must route through playLookupAudio');
      }

      // popup webview 的手动发音按钮仍各自传 gain（不经 playLookupAudio）。
      final String popup =
          _read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(popup, contains('lookupAudioVolumeGain'));
      expect(popup, contains('playAudioRef('));
      expect(
        popup,
        contains('volume: ReaderHibikiSource.instance.lookupAudioVolumeGain'),
        reason: 'manual popup audio must still pass the configured volume',
      );
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
