import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

DictionaryEntry _entry({
  String extra = '',
  double popularity = 0,
}) {
  return DictionaryEntry(
    word: '山',
    reading: 'やま',
    extra: extra,
    popularity: popularity,
  );
}

void main() {
  test('two frequency sources returns harmonic mean', () {
    final entry = _entry(
      extra: jsonEncode({
        'frequencies': [
          {
            'dictName': 'Freq A',
            'values': [
              {'value': 1000, 'display': '1000'}
            ],
          },
          {
            'dictName': 'Freq B',
            'values': [
              {'value': 3000, 'display': '3000 (rank)'}
            ],
          },
        ],
      }),
    );

    // Harmonic mean of 1000 and 3000 = 2 / (1/1000 + 1/3000) = 1500
    expect(FrequencyField.getFrequencyRank(entry: entry), '1500');
    expect(
      FrequencyField.getFrequenciesHtml(entry: entry),
      '<ul style="text-align: left;"><li>Freq A: 1000</li><li>Freq B: 3000 (rank)</li></ul>',
    );
  });

  test('empty extra returns empty string', () {
    expect(FrequencyField.getFrequencyRank(entry: _entry()), '');
    expect(FrequencyField.getFrequenciesHtml(entry: _entry()), '');
  });

  test('empty frequencies list returns empty string', () {
    final entry = _entry(extra: jsonEncode({'frequencies': []}));
    expect(FrequencyField.getFrequencyRank(entry: entry), '');
    expect(FrequencyField.getFrequenciesHtml(entry: entry), '');
  });

  test('single frequency source returns that value', () {
    final entry = _entry(
      extra: jsonEncode({
        'frequencies': [
          {
            'dictName': 'Solo',
            'values': [
              {'value': 500, 'display': '500'}
            ],
          },
        ],
      }),
    );
    expect(FrequencyField.getFrequencyRank(entry: entry), '500');
  });

  test('popularity non-zero takes precedence over extra', () {
    final entry = _entry(
      popularity: 42.0,
      extra: jsonEncode({
        'frequencies': [
          {
            'dictName': 'X',
            'values': [
              {'value': 999, 'display': '999'}
            ],
          },
        ],
      }),
    );
    expect(FrequencyField.getFrequencyRank(entry: entry), '42');
  });

  test('malformed extra JSON returns empty string', () {
    final entry = _entry(extra: 'not valid json{{{');
    expect(FrequencyField.getFrequencyRank(entry: entry), '');
  });

  test('extra with no frequencies key returns empty string', () {
    final entry = _entry(extra: jsonEncode({'other': 'data'}));
    expect(FrequencyField.getFrequencyRank(entry: entry), '');
  });

  test('frequency group with zero value is skipped', () {
    final entry = _entry(
      extra: jsonEncode({
        'frequencies': [
          {
            'dictName': 'Zero',
            'values': [
              {'value': 0, 'display': ''}
            ],
          },
        ],
      }),
    );
    expect(FrequencyField.getFrequencyRank(entry: entry), '');
  });

  test('duplicate dictName groups are deduplicated', () {
    final entry = _entry(
      extra: jsonEncode({
        'frequencies': [
          {
            'dictName': 'Same',
            'values': [
              {'value': 100, 'display': '100'}
            ],
          },
          {
            'dictName': 'Same',
            'values': [
              {'value': 900, 'display': '900'}
            ],
          },
        ],
      }),
    );
    // Only first "Same" group is used
    expect(FrequencyField.getFrequencyRank(entry: entry), '100');
  });
}
