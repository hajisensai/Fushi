// BUG-3311（反馈 #D5hTCEYMmT）：Android 视频页查词自动发音时，弹窗 WebView 的 <audio>
// 让 Chromium AudioFocusDelegate 以 GAIN_TRANSIENT_MAY_DUCK 申请系统音频焦点，联想 ZUI
// 据此把 app 自己正在播的视频压低数秒。修复：Android 主引擎上单词音频交原生
// MediaPlayer（不申请焦点）。本文件钉住：
//  ① `data:` / http URL → 原生可播 ref 的转换（行为测试）；
//  ② 四个接线点（主入口声明、自动发音分流、弹窗开关注入、弹窗原生桥）不被悄悄拆掉。
//  ③（PR #2105 审查）`image://` 词典媒体（sound:// 链接）同样能交原生播放、缓存目录
//     有上限、原生 playUrl 只在真的 start 后才答 true、词典样式预览注册了新桥。
// popup.js 一侧的分流行为由 tools/browser-extension/word-audio.test.js 真执行钉住。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    test(
      'image:// dictionary media (sound:// links) resolves to its bytes',
      () async {
        final List<String> asked = <String>[];
        Uint8List? loader(String dictionary, String path) {
          asked.add('$dictionary|$path');
          return path == 'snd/a.spx'
              ? Uint8List.fromList(<int>[9, 8, 7])
              : null;
        }

        // popup.js rewriteDictionaryMediaPath 的产物（encodeURIComponent 编码）。
        final String? path = await webViewWordAudioUrlToPlayableRef(
          'image://?dictionary=${Uri.encodeComponent('辞書 MDX')}'
          '&path=${Uri.encodeComponent('snd/a.spx')}',
          cacheDir: dir,
          loadDictionaryMedia: loader,
        );
        expect(asked, <String>['辞書 MDX|snd/a.spx']);
        expect(path, isNotNull);
        expect(path, endsWith('.spx'));
        expect(File(path!).readAsBytesSync(), <int>[9, 8, 7]);

        // 词典里取不到 / 参数缺失 → null（popup.js 回落 <audio>）。
        expect(
          await webViewWordAudioUrlToPlayableRef(
            'image://?dictionary=d&path=missing.mp3',
            cacheDir: dir,
            loadDictionaryMedia: loader,
          ),
          isNull,
        );
        expect(
          await webViewWordAudioUrlToPlayableRef(
            'image://?path=snd%2Fa.spx',
            cacheDir: dir,
            loadDictionaryMedia: loader,
          ),
          isNull,
        );
      },
    );

    test('cache directory is capped, evicting the oldest by mtime', () async {
      // 预置 4 个旧文件，mtime 显式错开（不依赖文件系统时间戳精度）。
      final DateTime base = DateTime(2020);
      for (int i = 0; i < 4; i++) {
        File('${dir.path}${Platform.pathSeparator}old$i.mp3')
          ..writeAsBytesSync(<int>[i])
          ..setLastModifiedSync(base.add(Duration(minutes: i)));
      }
      final String? path = await webViewWordAudioUrlToPlayableRef(
        'data:audio/mpeg;base64,${base64Encode(<int>[42, 43])}',
        cacheDir: dir,
        maxCacheFiles: 3,
      );
      final Set<String> left = dir
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .toSet();
      expect(left.length, 3);
      expect(left, contains(File(path!).uri.pathSegments.last));
      // 最旧的两个被淘汰，较新的两个留下。
      expect(left, containsAll(<String>['old2.mp3', 'old3.mp3']));
      expect(left, isNot(contains('old0.mp3')));
      expect(left, isNot(contains('old1.mp3')));
    });

    test(
      'reusing a cached clip refreshes its mtime so it is not evicted',
      () async {
        final String url =
            'data:audio/mpeg;base64,${base64Encode(<int>[1, 1])}';
        final String? path = await webViewWordAudioUrlToPlayableRef(
          url,
          cacheDir: dir,
          maxCacheFiles: 2,
        );
        final DateTime ancient = DateTime(2000);
        File(path!).setLastModifiedSync(ancient);
        File('${dir.path}${Platform.pathSeparator}newer.mp3')
          ..writeAsBytesSync(<int>[5])
          ..setLastModifiedSync(DateTime(2010));
        File('${dir.path}${Platform.pathSeparator}newest.mp3')
          ..writeAsBytesSync(<int>[6])
          ..setLastModifiedSync(DateTime(2011));

        // 再播同一段：复用 + 续命，它不能因为 mtime 最旧被删掉。
        expect(
          await webViewWordAudioUrlToPlayableRef(
            url,
            cacheDir: dir,
            maxCacheFiles: 2,
          ),
          path,
        );
        expect(File(path).existsSync(), isTrue);
        expect(File(path).lastModifiedSync().isAfter(ancient), isTrue);
        expect(
          File('${dir.path}${Platform.pathSeparator}newer.mp3').existsSync(),
          isFalse,
        );
        expect(
          File('${dir.path}${Platform.pathSeparator}newest.mp3').existsSync(),
          isTrue,
        );
      },
    );
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

    test('dictionary style preview answers the native play bridge', () {
      // BUG-1918：预览跑同一份 popup.js，未注册的 handler 名会让插件回 null 答复。
      final String src = _read(
        'lib/src/pages/implementations/dict_style_preview.dart',
      );
      expect(src, contains("  'playWordAudioNative',"));
    });

    test('sound:// glossary links go through the same playWordAudio entry', () {
      // 与 ♪ 同一入口 → Android 主引擎上同样交宿主原生播放器（宿主按 image:// 取字节），
      // 不另起一路 <audio> 与原生 MediaPlayer 叠播。
      final String js = _read('assets/popup/popup.js');
      final int start = js.indexOf('function handleGlossaryAnchorClick(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = js.indexOf('\nfunction ', start + 1);
      final String body = js.substring(start, end);
      expect(
        body,
        contains('rewriteDictionaryMediaPath(soundPath, soundDict)'),
      );
      expect(body, contains('playWordAudio(soundUrl)'));
      expect(body, isNot(contains('new Audio(')));
    });
  });

  group('native playUrl answers only once playback really started', () {
    // PR #2105 审查：startPlayback 以前在 prepareAsync() 之后立刻 result.success(true)，
    // 远端源 404 / 断网 / 编码不支持全被当成成功，弹窗既不回落也不提示。
    final String java = _read(
      'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
    );
    final String flat = java.replaceAll(RegExp(r'\s+'), ' ');
    final int start = flat.indexOf('private void startPlayback(');
    final int end = flat.indexOf('private void finishPendingPlay(');

    test('startPlayback never answers true straight after prepareAsync', () {
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String body = flat.substring(start, end);
      expect(
        body,
        isNot(contains('result.success(true)')),
        reason: '答复必须经 finishPendingPlay，且 true 只能出现在 start() 之后',
      );
      expect(body, contains('pendingPlayResult = result;'));
      expect(
        body,
        contains('mp.prepareAsync(); } else {'),
        reason: 'async 分支 prepareAsync 之后不得立即答复',
      );
    });

    test('onPrepared answers true after start, onError answers false', () {
      final String body = flat.substring(start, end);
      expect(body, contains('p.start(); finishPendingPlay(true);'));
      final int onError = body.indexOf('setOnErrorListener');
      expect(onError, greaterThanOrEqualTo(0));
      expect(body.substring(onError), contains('finishPendingPlay(false);'));
    });

    test('a superseding play / stop answers the pending call false', () {
      final String body = flat.substring(start, end);
      expect(
        body.indexOf('finishPendingPlay(false); pendingPlayResult = result;'),
        greaterThanOrEqualTo(0),
        reason: '新播放先给被取代的上一次答 false，再登记自己的 result',
      );
      final int stop = flat.indexOf('private void handleStop(');
      final int stopEnd = flat.indexOf('private void handlePlayUrl(');
      expect(
        flat.substring(stop, stopEnd),
        contains('finishPendingPlay(false);'),
      );
    });

    test('finishPendingPlay answers at most once', () {
      expect(
        flat,
        contains(
          'MethodChannel.Result pending = pendingPlayResult; '
          'pendingPlayResult = null; '
          'if (pending != null) pending.success(started);',
        ),
      );
    });
  });
}
