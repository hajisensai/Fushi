import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/audiobook/audio_file_sort.dart';

void main() {
  group('compareAudioFilePath', () {
    test('sorts numbered local audio files naturally', () {
      final paths = <String>[
        r'C:\books\track10.mp3',
        r'C:\books\track2.mp3',
        r'C:\books\track1.mp3',
      ]..sort(compareAudioFilePath);

      expect(paths.map((p) => p.split(r'\').last), [
        'track1.mp3',
        'track2.mp3',
        'track10.mp3',
      ]);
    });
  });
}
