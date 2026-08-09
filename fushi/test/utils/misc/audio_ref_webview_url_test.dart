import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';

/// Unit coverage for the unified word-audio play path: word audio is played by
/// the popup's own HTML5 <audio> element on every surface (in-app InAppWebView,
/// app-external overlay WebView2, browser extension), so [resolveWordAudioWebViewUrl]
/// must hand back a URL <audio> can load directly with no per-WebView custom
/// scheme or native file handler — remote http(s) pass-through, local file →
/// base64 `data:` URL. See [audioRefToWebViewUrl] / [audioMimeForPath].
void main() {
  group('audioRefToWebViewUrl', () {
    test('null / empty ref resolves to null', () async {
      expect(await audioRefToWebViewUrl(null), isNull);
      expect(await audioRefToWebViewUrl(''), isNull);
    });

    test('remote http(s) refs pass through unchanged so <audio> streams them',
        () async {
      expect(
        await audioRefToWebViewUrl('https://example.com/a.mp3'),
        'https://example.com/a.mp3',
      );
      expect(
        await audioRefToWebViewUrl('http://host/audio/file?id=42&token=abc'),
        'http://host/audio/file?id=42&token=abc',
      );
    });

    test('a local file becomes a base64 data: URL with the right MIME',
        () async {
      final Directory dir = await Directory.systemTemp.createTemp('hibiki_wa');
      addTearDown(() => dir.delete(recursive: true));
      final List<int> bytes = <int>[1, 2, 3, 4, 5, 250, 128, 0];
      final File mp3 = File('${dir.path}/word.mp3')..writeAsBytesSync(bytes);

      final String? url = await audioRefToWebViewUrl(mp3.path);
      expect(url, 'data:audio/mpeg;base64,${base64Encode(bytes)}');
    });

    test('a file:// URI ref is decoded to a path then base64-encoded',
        () async {
      final Directory dir = await Directory.systemTemp.createTemp('hibiki_wa');
      addTearDown(() => dir.delete(recursive: true));
      final List<int> bytes = <int>[9, 8, 7];
      final File opus = File('${dir.path}/word.opus')..writeAsBytesSync(bytes);

      final String? url = await audioRefToWebViewUrl(opus.uri.toString());
      expect(url, 'data:audio/ogg;base64,${base64Encode(bytes)}');
    });

    test('a missing local file resolves to null (no broken data: URL)',
        () async {
      final Directory dir = await Directory.systemTemp.createTemp('hibiki_wa');
      addTearDown(() => dir.delete(recursive: true));
      expect(await audioRefToWebViewUrl('${dir.path}/nope.mp3'), isNull);
    });
  });

  group('audioMimeForPath', () {
    test('maps the formats the local-audio libraries emit', () {
      expect(audioMimeForPath('a.mp3'), 'audio/mpeg');
      expect(audioMimeForPath('a.opus'), 'audio/ogg');
      expect(audioMimeForPath('a.ogg'), 'audio/ogg');
      expect(audioMimeForPath('a.m4a'), 'audio/mp4');
      expect(audioMimeForPath('a.aac'), 'audio/mp4');
      expect(audioMimeForPath('a.wav'), 'audio/wav');
      expect(audioMimeForPath('a.flac'), 'audio/flac');
      expect(audioMimeForPath('a.webm'), 'audio/webm');
    });

    test('is case-insensitive on the extension', () {
      expect(audioMimeForPath('WORD.MP3'), 'audio/mpeg');
      expect(audioMimeForPath('WORD.Opus'), 'audio/ogg');
    });

    test(
        'unknown extensions fall back to audio/mpeg (dominant word-audio '
        'format)', () {
      expect(audioMimeForPath('a.xyz'), 'audio/mpeg');
      expect(audioMimeForPath('noext'), 'audio/mpeg');
    });
  });
}
