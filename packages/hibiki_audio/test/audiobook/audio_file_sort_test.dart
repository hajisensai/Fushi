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

    test('sorts full-width numbered chapters by value, not code unit', () {
      // Naive code-unit order would put 第１０話 before 第２話 because '１' < '２'.
      final paths = <String>[
        '/audio/第１０話.mp3',
        '/audio/第２話.mp3',
        '/audio/第０１話.mp3',
      ]..sort(compareAudioFilePath);

      expect(paths.map((p) => p.split('/').last), [
        '第０１話.mp3',
        '第２話.mp3',
        '第１０話.mp3',
      ]);
    });

    test('zero-padded and unpadded numbers sort by numeric value', () {
      final paths = <String>[
        '/audio/ep10.mp3',
        '/audio/ep2.mp3',
        '/audio/ep01.mp3',
      ]..sort(compareAudioFilePath);

      expect(paths.map((p) => p.split('/').last), [
        'ep01.mp3',
        'ep2.mp3',
        'ep10.mp3',
      ]);
    });

    test('compares by file name across differing directory prefixes', () {
      // Multi-select across folders: directory prefix must not reorder files.
      final paths = <String>[
        '/zzz/track10.mp3',
        '/aaa/track2.mp3',
        '/mmm/track1.mp3',
      ]..sort(compareAudioFilePath);

      expect(paths.map((p) => p.split('/').last), [
        'track1.mp3',
        'track2.mp3',
        'track10.mp3',
      ]);
    });

    test('mixed full-width and half-width numbers interleave by value', () {
      final paths = <String>[
        '/audio/第10話.mp3',
        '/audio/第２話.mp3',
        '/audio/第1話.mp3',
      ]..sort(compareAudioFilePath);

      expect(paths.map((p) => p.split('/').last), [
        '第1話.mp3',
        '第２話.mp3',
        '第10話.mp3',
      ]);
    });
  });
}
