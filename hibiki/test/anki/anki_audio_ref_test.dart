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
