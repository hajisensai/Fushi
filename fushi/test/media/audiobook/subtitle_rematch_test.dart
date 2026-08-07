import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';

void main() {
  group('SubtitleRematch.supportedFormats', () {
    test('contains srt, lrc, vtt, ass', () {
      expect(SubtitleRematch.supportedFormats,
          containsAll(['srt', 'lrc', 'vtt', 'ass']));
    });

    test('does not contain smil or json', () {
      expect(SubtitleRematch.supportedFormats.contains('smil'), isFalse);
      expect(SubtitleRematch.supportedFormats.contains('json'), isFalse);
    });
  });

  group('SubtitleRematch.nonMatcherFormats', () {
    test('contains smil and json', () {
      expect(SubtitleRematch.nonMatcherFormats, containsAll(['smil', 'json']));
    });
  });

  group('SubtitleRematch.isEligible', () {
    Audiobook makeAb({String format = '', String path = ''}) {
      return Audiobook()
        ..bookKey = 'test-book'
        ..alignmentFormat = format
        ..alignmentPath = path;
    }

    test('SRT format is eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'srt', path: 'a.srt')),
          isTrue);
    });

    test('LRC format is eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'lrc', path: 'a.lrc')),
          isTrue);
    });

    test('VTT format is eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'vtt', path: 'a.vtt')),
          isTrue);
    });

    test('ASS format is eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'ass', path: 'a.ass')),
          isTrue);
    });

    test('SMIL format is not eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'smil', path: 'a.smil')),
          isFalse);
    });

    test('JSON format is not eligible', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'json', path: 'a.json')),
          isFalse);
    });

    test('SMIL extension overrides unknown format', () {
      expect(SubtitleRematch.isEligible(makeAb(format: '', path: 'align.smil')),
          isFalse);
    });

    test('JSON extension overrides unknown format', () {
      expect(SubtitleRematch.isEligible(makeAb(format: '', path: 'align.json')),
          isFalse);
    });

    test('case insensitive format check', () {
      expect(SubtitleRematch.isEligible(makeAb(format: 'SMIL', path: 'a.txt')),
          isFalse);
      expect(SubtitleRematch.isEligible(makeAb(format: 'JSON', path: 'a.txt')),
          isFalse);
    });

    test('empty format and path is eligible (not non-matcher)', () {
      expect(SubtitleRematch.isEligible(makeAb(format: '', path: '')), isTrue);
    });

    test('unknown format with non-excluded extension is eligible', () {
      expect(
          SubtitleRematch.isEligible(makeAb(format: 'custom', path: 'a.txt')),
          isTrue);
    });
  });

  group('SubtitleRematchWindowSlider constants', () {
    test('min/max/step/divisions are consistent', () {
      expect(SubtitleRematchWindowSlider.minWindow, 50);
      expect(SubtitleRematchWindowSlider.maxWindow, 1000);
      expect(SubtitleRematchWindowSlider.step, 25);
      expect(
        SubtitleRematchWindowSlider.divisions,
        (SubtitleRematchWindowSlider.maxWindow -
                SubtitleRematchWindowSlider.minWindow) ~/
            SubtitleRematchWindowSlider.step,
      );
    });
  });
}
