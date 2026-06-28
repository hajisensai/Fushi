import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// TODO-948/952: unit tests for the pure field-mapping diagnostic helpers used
/// by the mining "no sentence / unmapped field" toast. These answer "does any
/// Anki field consume {sentence} / {sasayaki-audio}?" purely from the persisted
/// [AnkiSettings.fieldMappings] (Anki field name -> handlebar template), with no
/// rendering and no runtime data — the honest "why is the field empty" signal.
void main() {
  group('AnkiHandlebarOptions.anyFieldConsumesToken', () {
    test('bare token in a field value matches', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Sentence': '{sentence}'},
          '{sentence}',
        ),
        isTrue,
      );
    });

    test('token embedded inside a larger HTML template matches', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Front': '<div>{expression}</div><span>{sentence}</span>'},
          '{sentence}',
        ),
        isTrue,
      );
    });

    test('no field consuming the token returns false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Expression': '{expression}', 'Reading': '{reading}'},
          '{sentence}',
        ),
        isFalse,
      );
    });

    test('empty mappings return false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken({}, '{sentence}'),
        isFalse,
      );
    });

    test('fields mapped to literal "-" (no token) return false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Front': '-', 'Back': '-'},
          '{sentence}',
        ),
        isFalse,
      );
    });

    test('matches {sasayaki-audio} for the sentence-audio diagnostic', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'SentenceAudio': '{sasayaki-audio}'},
          '{sasayaki-audio}',
        ),
        isTrue,
      );
      expect(
        AnkiHandlebarOptions.anyFieldConsumesToken(
          {'Word': '{audio}'},
          '{sasayaki-audio}',
        ),
        isFalse,
      );
    });
  });

  group('AnkiHandlebarOptions.anyFieldConsumesSentence', () {
    test('{sentence} counts as consuming the sentence', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence({'S': '{sentence}'}),
        isTrue,
      );
    });

    test('{cue-sentence} also counts (audiobook variant)', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence({'S': '{cue-sentence}'}),
        isTrue,
      );
    });

    test('neither {sentence} nor {cue-sentence} mapped returns false', () {
      expect(
        AnkiHandlebarOptions.anyFieldConsumesSentence(
          {'Expression': '{expression}', 'Glossary': '{glossary}'},
        ),
        isFalse,
      );
    });

    test('empty mappings return false (no field to receive the sentence)', () {
      expect(AnkiHandlebarOptions.anyFieldConsumesSentence({}), isFalse);
    });
  });
}
