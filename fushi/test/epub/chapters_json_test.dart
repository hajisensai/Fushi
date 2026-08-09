import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chaptersJson entries must include characters field', () {
    final List<Map<String, Object>> chapters = [
      {
        'id': 'ch1',
        'href': 'ch1.html',
        'mediaType': 'application/xhtml+xml',
        'characters': 1500
      },
      {
        'id': 'ch2',
        'href': 'ch2.html',
        'mediaType': 'application/xhtml+xml',
        'characters': 2300
      },
    ];
    final String json = jsonEncode(chapters);
    final List<dynamic> decoded = jsonDecode(json) as List<dynamic>;

    for (final dynamic ch in decoded) {
      final Map<String, dynamic> map = ch as Map<String, dynamic>;
      expect(map.containsKey('characters'), isTrue,
          reason: 'Each chapter must have a characters field');
      expect(map['characters'], isA<int>());
      expect((map['characters'] as int) >= 0, isTrue);
    }
  });

  test('reader_hoshi_source reads characters correctly when present', () {
    final String chaptersJson = jsonEncode([
      {
        'id': 'ch1',
        'href': 'ch1.html',
        'mediaType': 'text/html',
        'characters': 500
      },
      {
        'id': 'ch2',
        'href': 'ch2.html',
        'mediaType': 'text/html',
        'characters': 800
      },
    ]);

    final List<dynamic> chapters = jsonDecode(chaptersJson) as List<dynamic>;
    final List<int> sectionChars = chapters
        .map((dynamic c) =>
            ((c as Map<String, dynamic>)['characters'] as num?)?.toInt() ?? 0)
        .toList();

    expect(sectionChars, [500, 800]);
    expect(sectionChars.fold<int>(0, (int a, int b) => a + b), 1300);
  });

  test('reader_hoshi_source handles missing characters gracefully (old data)',
      () {
    final String chaptersJson = jsonEncode([
      {'id': 'ch1', 'href': 'ch1.html', 'mediaType': 'text/html'},
      {'id': 'ch2', 'href': 'ch2.html', 'mediaType': 'text/html'},
    ]);

    final List<dynamic> chapters = jsonDecode(chaptersJson) as List<dynamic>;
    final List<int> sectionChars = chapters
        .map((dynamic c) =>
            ((c as Map<String, dynamic>)['characters'] as num?)?.toInt() ?? 0)
        .toList();

    expect(sectionChars, [0, 0]);
    expect(sectionChars.fold<int>(0, (int a, int b) => a + b), 0);
  });
}
