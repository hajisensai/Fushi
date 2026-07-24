import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// Guards the Anki word-audio reference classifier. The repo media-store paths
/// (`AnkiConnectRepository._storeRemoteAudio` / `AnkiRepository._addRemoteAudio`)
/// used to branch on `file://` / `/` / `http` only, silently dropping Windows
/// drive-letter local paths so video/reader word pronunciation never reached
/// the card on Windows (sibling of BUG-046). Any non-URL ref is a local file.
void main() {
  group('AnkiAudioRef.classify', () {
    test('empty ref classifies as empty', () {
      expect(AnkiAudioRef.classify(''), AnkiAudioRefKind.empty);
    });

    test('http(s) URLs classify as remoteUrl', () {
      expect(
        AnkiAudioRef.classify('http://example.com/a.mp3'),
        AnkiAudioRefKind.remoteUrl,
      );
      expect(
        AnkiAudioRef.classify('https://example.com/a.mp3'),
        AnkiAudioRefKind.remoteUrl,
      );
    });

    test('Unix absolute path classifies as localFile', () {
      expect(
        AnkiAudioRef.classify('/data/user/0/app/cache/word.mp3'),
        AnkiAudioRefKind.localFile,
      );
    });

    test('file:// URI classifies as localFile', () {
      expect(
        AnkiAudioRef.classify('file:///C:/Users/me/Temp/word.mp3'),
        AnkiAudioRefKind.localFile,
      );
    });

    test('Windows drive-letter path (backslash) classifies as localFile', () {
      expect(
        AnkiAudioRef.classify(r'C:\Users\me\AppData\Local\Temp\word.mp3'),
        AnkiAudioRefKind.localFile,
      );
    });

    test('Windows drive-letter path (forward slash) classifies as localFile',
        () {
      expect(
        AnkiAudioRef.classify('C:/Users/me/AppData/Local/Temp/word.mp3'),
        AnkiAudioRefKind.localFile,
      );
    });

    // BUG-1050: the popup encodes a local-audio-library word pronunciation as a
    // `data:<mime>;base64,…` URI (audioRefToWebViewUrl) and reuses it verbatim
    // as the mine payload's audio field. It must classify as its own dataUri
    // kind — not localFile, where the repos treated it as a missing file and
    // silently dropped the word audio from video/immersion cards.
    test('data: URI classifies as dataUri', () {
      expect(
        AnkiAudioRef.classify(
            'data:audio/mpeg;base64,${base64Encode(const [1, 2, 3])}'),
        AnkiAudioRefKind.dataUri,
      );
    });
  });

  group('AnkiAudioRef.decodeDataUri', () {
    test('decodes bytes and derives extension from MIME', () {
      final List<int> raw = List<int>.generate(64, (int i) => i);
      final AnkiAudioData? data = AnkiAudioRef.decodeDataUri(
          'data:audio/mpeg;base64,${base64Encode(raw)}');
      expect(data, isNotNull);
      expect(data!.bytes, raw);
      expect(data.extension, 'mp3');
    });

    test('maps each producible MIME to the right extension', () {
      // Mirrors audioMimeForPath's output set (lookup_audio_playback.dart).
      const Map<String, String> mimeToExt = <String, String>{
        'audio/mpeg': 'mp3',
        'audio/ogg': 'ogg',
        'audio/mp4': 'm4a',
        'audio/aac': 'm4a',
        'audio/wav': 'wav',
        'audio/flac': 'flac',
        'audio/webm': 'webm',
      };
      final String payload = base64Encode(const <int>[9, 8, 7]);
      mimeToExt.forEach((String mime, String ext) {
        final AnkiAudioData? data =
            AnkiAudioRef.decodeDataUri('data:$mime;base64,$payload');
        expect(data, isNotNull, reason: mime);
        expect(data!.extension, ext, reason: mime);
      });
    });

    test('unknown MIME falls back to mp3', () {
      final AnkiAudioData? data = AnkiAudioRef.decodeDataUri(
          'data:audio/x-unknown;base64,${base64Encode(const [1])}');
      expect(data?.extension, 'mp3');
    });

    test('empty payload returns null (no broken media written)', () {
      expect(AnkiAudioRef.decodeDataUri('data:audio/mpeg;base64,'), isNull);
    });

    test('non-data: ref returns null', () {
      expect(AnkiAudioRef.decodeDataUri('https://example.com/a.mp3'), isNull);
      expect(AnkiAudioRef.decodeDataUri('/tmp/word.mp3'), isNull);
    });

    test('malformed data: URI returns null', () {
      expect(AnkiAudioRef.decodeDataUri('data:not-a-valid-uri'), isNull);
    });
  });

  group('AnkiAudioRef.localPath', () {
    test('bare Windows drive path is returned unchanged', () {
      const ref = r'C:\Users\me\AppData\Local\Temp\word.mp3';
      expect(AnkiAudioRef.localPath(ref), ref);
    });

    test('bare Unix path is returned unchanged', () {
      const ref = '/data/user/0/app/cache/word.mp3';
      expect(AnkiAudioRef.localPath(ref), ref);
    });

    test('file:// URI is decoded to a scheme-less filesystem path', () {
      final String path =
          AnkiAudioRef.localPath('file:///C:/Users/me/Temp/word.mp3');
      // Exact slash direction is platform-dependent (Uri.toFilePath); assert
      // the scheme is gone and the path still points at the same file.
      expect(path.startsWith('file://'), isFalse);
      expect(path.endsWith('word.mp3'), isTrue);
    });
  });
}
