import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('lookup audio volume wiring', () {
    test(
        'auto-read routes through the unified WebView-first path with a '
        'volume-carrying Dart fallback', () {
      // 单词发音已统一：弹窗自己用 HTML5 <audio> 播（三端 + 扩展同一路径），不再回
      // Dart 交给 native/libmpv。自动发音走 autoReadWordUnified —— 优先驱动弹窗
      // <audio>，WebView 未就绪时回退 playLookupAudio（仍带 gain，Never break userspace）。
      final String playback =
          _read('lib/src/utils/misc/lookup_audio_playback.dart');
      // Dart 兜底仍把配置音量传进播放器。
      expect(playback, contains('playAudioRef('));
      expect(
        playback,
        contains('volume: ReaderFushiSource.instance.lookupAudioVolumeGain'),
        reason: 'the Dart fallback (playLookupAudio) must still pass the '
            'configured volume',
      );
      // 统一入口 + 兜底接线。BUG-1093 后解析只做一次：WebView 失败回落时直接用
      // 同一 ref 走 TtsChannel.playAudioRef，绝不重新解析（避免二次开库/远端请求）。
      expect(playback, contains('autoReadWordUnified('));
      expect(
        playback,
        contains('await audioRefToWebViewUrl(ref)'),
        reason: 'autoReadWordUnified must reuse the single resolved ref for '
            'the WebView play path',
      );
      expect(
        playback,
        contains('await TtsChannel.instance.playAudioRef('),
        reason: 'autoReadWordUnified must fall back to the Dart player with '
            'the SAME resolved ref when the WebView did not actually play '
            '(BUG-1093)',
      );

      // base/mixin 自动发音都经统一 helper（不再各自手抄 playLookupAudio + gain）。
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        expect(_read(path), contains('autoReadWordUnified('),
            reason: '$path auto-read must route through the unified helper');
      }
    });

    test(
        'manual + auto word audio applies the configured volume in the '
        'WebView <audio>', () {
      // 音量不再在 Dart 侧 playAudioRef 应用（弹窗不回 Dart 播），改注入
      // window.lookupAudioVolume（0..1，源自 lookupAudioVolumeGain），popup.js 设
      // audio.volume。
      final String injection =
          _read('lib/src/pages/implementations/popup_settings_injection.dart');
      expect(injection, contains('window.lookupAudioVolume'));
      expect(injection, contains('lookupAudioVolumeGain'));

      final String popupJs = _read('assets/popup/popup.js');
      expect(popupJs, contains('new Audio('),
          reason:
              'popup.js must play word audio with an HTML5 <audio> element');
      expect(popupJs, contains('audio.volume'),
          reason: 'popup.js must apply the injected lookup audio volume');
      expect(popupJs, contains('window.lookupAudioVolume'));

      // 旧的 Dart 往返已删：弹窗不再自己回 Dart 播音频。
      final String popupWebView =
          _read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(
        popupWebView,
        isNot(contains("handlerName: 'playWordAudio'")),
        reason: 'the playWordAudio Dart bridge must be removed (unified to '
            '<audio>)',
      );
      expect(
        popupWebView,
        isNot(contains('playAudioRef(')),
        reason: 'the popup must not round-trip word audio to a native/libmpv '
            'player',
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
        'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
      );

      expect(desktop, contains('_player.setVolume(volume.clamp(0.0, 1.0))'));
      // TODO-744 后改为复用单个 MediaPlayer，播放走 startPlayback(局部变量 mp)，
      // 音量仍在 prepare/start 之前应用。
      expect(android, contains('mp.setVolume(volume, volume)'),
          reason: 'Android must apply volume before prepare/start');
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
