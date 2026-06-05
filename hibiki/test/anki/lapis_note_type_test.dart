import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('LapisNoteType authoritative schema', () {
    test('has the 22 official fields in order', () {
      expect(LapisNoteType.fields, <String>[
        'Expression',
        'ExpressionFurigana',
        'ExpressionReading',
        'ExpressionAudio',
        'SelectionText',
        'MainDefinition',
        'DefinitionPicture',
        'Sentence',
        'SentenceFurigana',
        'SentenceAudio',
        'Picture',
        'Glossary',
        'Hint',
        'IsWordAndSentenceCard',
        'IsClickCard',
        'IsSentenceCard',
        'IsAudioCard',
        'PitchPosition',
        'PitchCategories',
        'Frequency',
        'FreqSort',
        'MiscInfo',
      ]);
    });

    test('model and deck names', () {
      expect(LapisNoteType.modelName, 'Lapis');
      expect(LapisNoteType.deckName, 'Lapis');
      expect(LapisNoteType.cardName, 'Card 1');
    });

    test('templates are non-trivial vendored content', () {
      expect(LapisNoteType.front.length, greaterThan(500));
      expect(LapisNoteType.back.length, greaterThan(5000));
      expect(LapisNoteType.css.length, greaterThan(5000));
      expect(LapisNoteType.front, contains('id="lapis"'));
      expect(LapisNoteType.back, contains('Expression'));
    });

    test('template carries all schema fields', () {
      expect(LapisNoteType.template.name, 'Lapis');
      expect(LapisNoteType.template.fields, LapisNoteType.fields);
      expect(LapisNoteType.template.cardName, 'Card 1');
      expect(LapisNoteType.template.front, LapisNoteType.front);
      expect(LapisNoteType.template.back, LapisNoteType.back);
      expect(LapisNoteType.template.css, LapisNoteType.css);
    });

    test('default field mappings only reference real fields', () {
      for (final field in LapisNoteType.defaultFieldMappings.keys) {
        expect(LapisNoteType.fields, contains(field));
      }
      expect(LapisNoteType.defaultFieldMappings['Picture'], '{book-cover}');
      expect(LapisNoteType.defaultFieldMappings['SentenceAudio'],
          '{sasayaki-audio}');
      expect(LapisNoteType.defaultFieldMappings['IsWordAndSentenceCard'], 'x');
    });
  });
}
