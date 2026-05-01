import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';

void main() {
  test('frequency field reads hoshidicts frequency data from entry extra', () {
    final entry = DictionaryEntry(
      word: '山',
      reading: 'やま',
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

    expect(FrequencyField.getFrequencyRank(entry: entry), '1500');
    expect(
      FrequencyField.getFrequenciesHtml(entry: entry),
      '<ul style="text-align: left;"><li>Freq A: 1000</li><li>Freq B: 3000 (rank)</li></ul>',
    );
  });
}
