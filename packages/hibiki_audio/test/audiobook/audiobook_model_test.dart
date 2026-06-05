import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('Audiobook', () {
    test('keeps persisted audio paths in cue order', () {
      final audiobook = Audiobook()
        ..bookKey = 'book'
        ..audioPaths = <String>[
          r'C:\books\track10.mp3',
          r'C:\books\track2.mp3',
          r'C:\books\track1.mp3',
        ];

      expect(audiobook.audioPathsInCueOrder!.map((p) => p.split(r'\').last), [
        'track10.mp3',
        'track2.mp3',
        'track1.mp3',
      ]);
    });

    test('keeps Dolby container extensions in cue order', () {
      final audiobook = Audiobook()
        ..bookKey = 'book'
        ..audioPaths = <String>[
          r'C:\books\chapter2.eac3',
          r'C:\books\chapter1.ac3',
        ];

      expect(audiobook.audioPathsInCueOrder!.map((p) => p.split(r'\').last), [
        'chapter2.eac3',
        'chapter1.ac3',
      ]);
    });
  });

  group('AudioCue', () {
    test('validates audio file index against sorted audio paths', () {
      final audiobook = Audiobook()
        ..bookKey = 'book'
        ..audioPaths = <String>[
          r'C:\books\track10.mp3',
          r'C:\books\track2.mp3',
          r'C:\books\track1.mp3',
        ];
      final cue = AudioCue()
        ..bookKey = 'book'
        ..chapterHref = 'chapter'
        ..sentenceIndex = 0
        ..textFragmentId = 'cue'
        ..text = 'cue'
        ..startMs = 0
        ..endMs = 1000
        ..audioFileIndex = 2;

      final File? file = cue.resolveAudioFile(audiobook.audioFilesInCueOrder);

      expect(file?.path, r'C:\books\track1.mp3');
    });
  });
}
