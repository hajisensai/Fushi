import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';

/// Guards BUG-046: a resolved local-audio path on Windows is an absolute
/// drive-letter path (`C:\…\local_audio.mp3`). The old play-dispatch code only
/// recognised `file://`, Unix `/…` and `http`, so it silently dropped Windows
/// paths → the dictionary "♪" button turned into "✕" with no sound. The
/// classification is now centralised in [TtsChannel.classifyAudioRef]; these
/// tests pin that a Windows path routes to file playback, not nowhere.
void main() {
  group('TtsChannel.classifyAudioRef', () {
    test('Windows drive-letter path → file (BUG-046 regression guard)', () {
      expect(
        TtsChannel.classifyAudioRef(
            r'C:\Users\wrds\AppData\Local\Temp\local_audio.mp3'),
        ResolvedAudioPlayback.file,
      );
      // forward-slash separators (how extractBlob builds the path) too.
      expect(
        TtsChannel.classifyAudioRef('C:/Users/wrds/AppData/Local/Temp/x.opus'),
        ResolvedAudioPlayback.file,
      );
    });

    test('Unix absolute path → file', () {
      expect(
        TtsChannel.classifyAudioRef('/data/user/0/app/cache/local_audio.mp3'),
        ResolvedAudioPlayback.file,
      );
    });

    test('file:// URI → file', () {
      expect(
        TtsChannel.classifyAudioRef('file:///tmp/local_audio.mp3'),
        ResolvedAudioPlayback.file,
      );
    });

    test('http / https URL → url', () {
      expect(
        TtsChannel.classifyAudioRef('http://localhost:8765/audio/x.mp3'),
        ResolvedAudioPlayback.url,
      );
      expect(
        TtsChannel.classifyAudioRef(
            'https://hoshi-reader.example.workers.dev/?term=%E6%97%A5'),
        ResolvedAudioPlayback.url,
      );
    });

    test('empty → none', () {
      expect(TtsChannel.classifyAudioRef(''), ResolvedAudioPlayback.none);
    });
  });
}
