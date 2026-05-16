import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_rematch.dart';

void main() {
  group('SasayakiRematch.supportedFormats', () {
    test('contains srt, lrc, vtt, ass', () {
      expect(SasayakiRematch.supportedFormats, containsAll(['srt', 'lrc', 'vtt', 'ass']));
    });

    test('does not contain smil or json', () {
      expect(SasayakiRematch.supportedFormats.contains('smil'), isFalse);
      expect(SasayakiRematch.supportedFormats.contains('json'), isFalse);
    });
  });

  group('SasayakiRematch.nonMatcherFormats', () {
    test('contains smil and json', () {
      expect(SasayakiRematch.nonMatcherFormats, containsAll(['smil', 'json']));
    });
  });

  group('SasayakiRematch.isEligible', () {
    Audiobook _makeAb({String format = '', String path = ''}) {
      return Audiobook()
        ..bookUid = 'test'
        ..alignmentFormat = format
        ..alignmentPath = path;
    }

    test('SRT format is eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'srt', path: 'a.srt')), isTrue);
    });

    test('LRC format is eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'lrc', path: 'a.lrc')), isTrue);
    });

    test('VTT format is eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'vtt', path: 'a.vtt')), isTrue);
    });

    test('ASS format is eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'ass', path: 'a.ass')), isTrue);
    });

    test('SMIL format is not eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'smil', path: 'a.smil')), isFalse);
    });

    test('JSON format is not eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'json', path: 'a.json')), isFalse);
    });

    test('SMIL extension overrides unknown format', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: '', path: 'align.smil')), isFalse);
    });

    test('JSON extension overrides unknown format', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: '', path: 'align.json')), isFalse);
    });

    test('case insensitive format check', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'SMIL', path: 'a.txt')), isFalse);
      expect(SasayakiRematch.isEligible(_makeAb(format: 'JSON', path: 'a.txt')), isFalse);
    });

    test('empty format and path is eligible (not non-matcher)', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: '', path: '')), isTrue);
    });

    test('unknown format with non-excluded extension is eligible', () {
      expect(SasayakiRematch.isEligible(_makeAb(format: 'custom', path: 'a.txt')), isTrue);
    });
  });

  group('SasayakiWindowSlider constants', () {
    test('min/max/step/divisions are consistent', () {
      expect(SasayakiWindowSlider.minWindow, 50);
      expect(SasayakiWindowSlider.maxWindow, 1000);
      expect(SasayakiWindowSlider.step, 25);
      expect(
        SasayakiWindowSlider.divisions,
        (SasayakiWindowSlider.maxWindow - SasayakiWindowSlider.minWindow) ~/
            SasayakiWindowSlider.step,
      );
    });
  });
}
