import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

const String _series = 'collection:7';

TtsMediaVoiceScope _scope(String book, {String? series, String? language}) =>
    TtsMediaVoiceScope(bookKey: book, seriesKey: series, language: language);

String? _first(TtsMediaVoices voices, TtsMediaVoiceScope scope) {
  final List<({String presetId, TtsVoiceSource source})> c = voices
      .candidatesFor(scope);
  return c.isEmpty ? null : c.first.presetId;
}

void main() {
  group('ttsMediaVoiceLanguageKey', () {
    test('keeps only the primary language subtag', () {
      expect(ttsMediaVoiceLanguageKey('ja'), 'ja');
      expect(ttsMediaVoiceLanguageKey('ja-JP'), 'ja');
      expect(ttsMediaVoiceLanguageKey('zh-Hant-TW'), 'zh');
      expect(ttsMediaVoiceLanguageKey('zh_TW'), 'zh');
      expect(ttsMediaVoiceLanguageKey(' ZH '), 'zh');
    });

    test('unknown or malformed values become the empty key', () {
      expect(ttsMediaVoiceLanguageKey(null), '');
      expect(ttsMediaVoiceLanguageKey(''), '');
      expect(ttsMediaVoiceLanguageKey('und'), '');
      expect(ttsMediaVoiceLanguageKey('x'), '');
      expect(ttsMediaVoiceLanguageKey('12'), '');
    });
  });

  group('TtsMediaVoices', () {
    test('series voices are kept per language (JP and ZH editions in one '
        'collection do not overwrite each other)', () {
      final TtsMediaVoices voices = TtsMediaVoices();
      final TtsMediaVoiceScope jp1 = _scope(
        'bake-jp-1',
        series: _series,
        language: 'ja',
      );
      final TtsMediaVoiceScope jp2 = _scope(
        'bake-jp-2',
        series: _series,
        language: 'ja-JP',
      );
      final TtsMediaVoiceScope zh1 = _scope(
        'bake-zh-1',
        series: _series,
        language: 'zh-Hant',
      );
      final TtsMediaVoiceScope zh4 = _scope(
        'bake-zh-4',
        series: _series,
        language: 'zh-TW',
      );
      expect(voices.candidatesFor(jp1), isEmpty);

      voices.assign(zh1, 'unsloth-tw');
      expect(_first(voices, zh4), 'unsloth-tw', reason: '同系列同语言的新卷');
      expect(_first(voices, jp2), isNull, reason: '日文版不受影响');

      voices.assign(jp2, 'unsloth-jp');
      expect(_first(voices, jp1), 'unsloth-jp');
      expect(_first(voices, zh1), 'unsloth-tw');
      expect(voices.candidatesFor(jp1).single.source, TtsVoiceSource.series);
    });

    test('a book without a series keeps its own voice only', () {
      final TtsMediaVoices voices = TtsMediaVoices();
      voices.assign(_scope('three-body', language: 'zh'), 'unsloth-tw');
      expect(voices.books, <String, String>{'three-body': 'unsloth-tw'});
      expect(voices.series, isEmpty);
      expect(_first(voices, _scope('other-zh', language: 'zh')), isNull);
      expect(
        voices.candidatesFor(_scope('three-body')).single.source,
        TtsVoiceSource.book,
      );
    });

    test('book voice wins over the series voice; assigning to the series '
        'drops the book override so the series voice takes effect', () {
      final TtsMediaVoices voices = TtsMediaVoices(
        books: <String, String>{'v1': 'old'},
        series: <String, Map<String, String>>{
          _series: <String, String>{'ja': 'series-ja'},
        },
      );
      final TtsMediaVoiceScope v1 = _scope(
        'v1',
        series: _series,
        language: 'ja',
      );
      expect(
        voices
            .candidatesFor(v1)
            .map((({String presetId, TtsVoiceSource source}) c) => c.presetId),
        <String>['old', 'series-ja'],
      );
      voices.assign(v1, 'new');
      expect(voices.books, isEmpty);
      expect(_first(voices, v1), 'new');
    });

    test('books with an unknown language share one slot in the series', () {
      final TtsMediaVoices voices = TtsMediaVoices();
      voices.assign(_scope('a', series: _series), 'p');
      expect(
        _first(voices, _scope('b', series: _series, language: 'und')),
        'p',
      );
      expect(
        _first(voices, _scope('c', series: _series, language: 'ja')),
        isNull,
      );
    });

    test('clear removes the book and series+language voices only', () {
      final TtsMediaVoices voices = TtsMediaVoices(
        books: <String, String>{'v1': 'b'},
        series: <String, Map<String, String>>{
          _series: <String, String>{'ja': 'j', 'zh': 'z'},
        },
      );
      voices.clear(_scope('v1', series: _series, language: 'ja'));
      expect(voices.books, isEmpty);
      expect(voices.series, <String, Map<String, String>>{
        _series: <String, String>{'zh': 'z'},
      });
      voices.clear(_scope('v9', series: _series, language: 'zh'));
      expect(voices.series, isEmpty, reason: '系列空了整条删掉');
      expect(voices.isEmpty, isTrue);
    });

    test('forgetPreset drops every entry pointing at a deleted voice', () {
      final TtsMediaVoices voices = TtsMediaVoices(
        books: <String, String>{'a': 'gone', 'b': 'keep'},
        series: <String, Map<String, String>>{
          's1': <String, String>{'ja': 'gone'},
          's2': <String, String>{'ja': 'keep', 'zh': 'gone'},
        },
      );
      expect(voices.forgetPreset('gone'), isTrue);
      expect(voices.books, <String, String>{'b': 'keep'});
      expect(voices.series, <String, Map<String, String>>{
        's2': <String, String>{'ja': 'keep'},
      });
      expect(voices.forgetPreset('gone'), isFalse);
    });

    test('json round trip; bad input decodes to empty', () {
      final TtsMediaVoices voices = TtsMediaVoices(
        books: <String, String>{'a': 'p1'},
        series: <String, Map<String, String>>{
          _series: <String, String>{'ja': 'p2', '': 'p3'},
        },
      );
      final TtsMediaVoices back = TtsMediaVoices.decode(voices.encode());
      expect(back.books, voices.books);
      expect(back.series, voices.series);
      expect(TtsMediaVoices.decode('not json').isEmpty, isTrue);
      expect(TtsMediaVoices.decode('[1]').isEmpty, isTrue);
      final TtsMediaVoices partial = TtsMediaVoices.decode(
        '{"books":{"a":"p","b":3,"c":""},"series":{"s":{"ja":"p"},"t":{}}}',
      );
      expect(partial.books, <String, String>{'a': 'p'});
      expect(partial.series.keys, <String>['s']);
    });
  });

  group('TtsPresetStore media voices', () {
    test('persist, and deleting a preset forgets it', () async {
      final MemoryPrefStore prefs = MemoryPrefStore();
      final TtsPresetStore store = TtsPresetStore(prefs);
      expect(store.loadMediaVoices().isEmpty, isTrue);
      await store.saveMediaVoices(
        TtsMediaVoices()
          ..assign(_scope('v', series: _series, language: 'ja'), 'p1'),
      );
      expect(prefs.values.keys, contains(TtsPresetStore.mediaVoicesKey));
      expect(
        _first(
          store.loadMediaVoices(),
          _scope('w', series: _series, language: 'ja'),
        ),
        'p1',
      );
      await store.forgetMediaVoicePreset('p1');
      expect(store.loadMediaVoices().isEmpty, isTrue);
      expect(prefs.values[TtsPresetStore.mediaVoicesKey], '');
    });
  });
}
