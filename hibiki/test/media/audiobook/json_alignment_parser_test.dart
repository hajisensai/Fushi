import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';

void main() {
  group('JsonAlignmentParser.parseString', () {
    test('parses basic alignment JSON', () {
      final json = jsonEncode({
        'bookUid': 'reader/book.epub',
        'audio': ['ch01.mp3'],
        'cues': [
          {
            'chapter': 'ch01.xhtml',
            'i': 0,
            'selector': '#p1',
            'start': 0,
            'end': 4230,
            'file': 0,
            'text': '吾輩は猫である。',
          },
          {
            'chapter': 'ch01.xhtml',
            'i': 1,
            'selector': '#p2',
            'start': 4230,
            'end': 8000,
            'file': 0,
            'text': '名前はまだ無い。',
          },
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'override/uid',
      );

      expect(cues, hasLength(2));
      expect(cues[0].bookUid, 'override/uid');
      expect(cues[0].chapterHref, 'ch01.xhtml');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].textFragmentId, '#p1');
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 4230);
      expect(cues[0].audioFileIndex, 0);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].startMs, 4230);
    });

    test('handles multi-file audio index', () {
      final json = jsonEncode({
        'audio': ['f0.mp3', 'f1.mp3'],
        'cues': [
          {
            'chapter': 'ch.xhtml',
            'i': 0,
            'selector': '#s1',
            'start': 100,
            'end': 200,
            'file': 1,
            'text': 'test',
          },
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues.single.audioFileIndex, 1);
    });

    test('missing optional fields default to safe values', () {
      final json = jsonEncode({
        'cues': [
          <String, dynamic>{},
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, hasLength(1));
      expect(cues[0].chapterHref, '');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].textFragmentId, '');
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 0);
      expect(cues[0].audioFileIndex, 0);
      expect(cues[0].text, '');
    });

    test('empty cues array returns empty list', () {
      final json = jsonEncode({'cues': <dynamic>[]});

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, isEmpty);
    });

    test('missing cues key returns empty list', () {
      final json = jsonEncode({
        'audio': ['a.mp3']
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, isEmpty);
    });
  });
}
