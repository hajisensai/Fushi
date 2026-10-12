// BUG-3311（反馈 #D5hTCEYMmT）：Android 视频页查词自动发音时，弹窗 WebView 的 <audio>
// 让 Chromium AudioFocusDelegate 以 GAIN_TRANSIENT_MAY_DUCK 申请系统音频焦点，联想 ZUI
// 据此把 app 自己正在播的视频压低数秒。修复：Android 主引擎上单词音频交原生
// MediaPlayer（不申请焦点）。本文件钉住：
//  ① `data:` / http URL → 原生可播 ref 的转换（行为测试）；
//  ② 四个接线点（主入口声明、自动发音分流、弹窗开关注入、弹窗原生桥）不被悄悄拆掉。
// popup.js 一侧的分流行为由 tools/browser-extension/word-audio.test.js 真执行钉住。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('webViewWordAudioUrlToPlayableRef', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('word_audio_ref_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('http(s) URL passes through untouched', () async {
      expect(
        await webViewWordAudioUrlToPlayableRef(
          'https://h/a.mp3',
          cacheDir: dir,
        ),
        'https://h/a.mp3',
      );
      expect(
        await webViewWordAudioUrlToPlayableRef('http://h/a', cacheDir: dir),
        'http://h/a',
      );
    });

    test(
      'data: URL round-trips the exact bytes into a content-addressed file',
      () async {
        final List<int> bytes = List<int>.generate(300, (int i) => i % 256);
        final String url = 'data:audio/ogg;base64,${base64Encode(bytes)}';
        final String? path = await webViewWordAudioUrlToPlayableRef(
          url,
          cacheDir: dir,
        );
        expect(path, isNotNull);
        expect(path, endsWith('.opus'));
        expect(File(path!).readAsBytesSync(), bytes);
        // 同一段音频复用同一文件（不覆写正在播放的文件、不无限堆临时文件）。
        expect(
          await webViewWordAudioUrlToPlayableRef(url, cacheDir: dir),
          path,
        );
        final String? other = await webViewWordAudioUrlToPlayableRef(
          'data:audio/mpeg;base64,${base64Encode(<int>[1, 2, 3])}',
          cacheDir: dir,
        );
        expect(other, isNot(path));
        expect(other, endsWith('.mp3'));
      },
    );

    test('unknown shapes and empty payloads are refused', () async {
      expect(
        await webViewWordAudioUrlToPlayableRef('/sdcard/a.mp3', cacheDir: dir),
        isNull,
      );
      expect(
        await webViewWordAudioUrlToPlayableRef(
          'data:audio/mpeg;base64,',
          cacheDir: dir,
        ),
        isNull,
      );
    });
  });

  test('non-Android hosts never route word audio natively', () {
    TtsChannel.markHostPlaybackRegistered();
    expect(lookupWordAudioPlaysNatively, Platform.isAndroid);
  });

  group('wiring guards', () {
    test('main() declares the native player (only the main engine has it)', () {
      expect(
        _read('lib/main.dart'),
        contains('TtsChannel.markHostPlaybackRegistered();'),
      );
      for (final String entry in <String>[
        'lib/popup_main.dart',
        'lib/floating_dict_main.dart',
      ]) {
        expect(
          _read(entry),
          isNot(contains('markHostPlaybackRegistered')),
          reason: '$entry 的引擎没注册 TtsChannelHandler，不能声明原生播放',
        );
      }
    });

    test('auto-read skips the WebView <audio> when routing natively', () {
      final String src = _read('lib/src/utils/misc/lookup_audio_playback.dart');
      expect(
        src,
        contains('if (playInWebView != null && !lookupWordAudioPlaysNatively)'),
      );
    });

    test('popup head injects the routing switch popup.js reads', () {
      expect(
        _read('lib/src/pages/implementations/popup_settings_injection.dart'),
        contains(
          r'window.__fushiWordAudioViaHost = $lookupWordAudioPlaysNatively;',
        ),
      );
      expect(
        _read('assets/popup/popup.js'),
        contains('window.__fushiWordAudioViaHost === true'),
      );
    });

    test('popup WebView registers the native play bridge', () {
      final String src = _read(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );
      expect(src, contains("handlerName: 'playWordAudioNative'"));
      expect(src, contains('return playWordAudioUrlNatively(url);'));
    });
  });
}
